module Captain::ChatHelper
  def request_chat_completion
    log_chat_completion_request

    response = @client.chat(
      parameters: {
        model: @model,
        messages: @messages,
        tools: @tool_registry&.registered_tools || [],
        response_format: { type: 'json_object' },
        temperature: @assistant&.config&.[]('temperature').to_f || 1
      }
    )

    handle_response(response)
  rescue StandardError => e
    Rails.logger.error "#{self.class.name} Assistant: #{@assistant.id}, Error in chat completion: #{e}"
    raise e
  end

  private

  def handle_response(response)
    Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }
    message = response.dig('choices', 0, 'message')
    if message['tool_calls']
      process_tool_calls(message['tool_calls'])
    else
      content = message['content']
      Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Raw content: #{content}" }
      cleaned_content = clean_json_content(content)
      Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Cleaned content: #{cleaned_content}" }
      message = JSON.parse(cleaned_content)
      persist_message(message, 'assistant')
      message
    end
  end

  def clean_json_content(content)
    # Remove markdown code blocks and extract JSON
    cleaned = content.strip
    
    # Handle various markdown formats
    # Remove ```json at the beginning
    cleaned = cleaned.gsub(/^```json\s*/i, '')
    # Remove ``` at the end
    cleaned = cleaned.gsub(/```\s*$/i, '')
    # Remove any remaining ``` markers
    cleaned = cleaned.gsub(/```/i, '')
    
    # Remove any leading/trailing whitespace and newlines
    cleaned = cleaned.strip
    
    # If the content still doesn't look like valid JSON, try to extract JSON from it
    unless cleaned.start_with?('{') || cleaned.start_with?('[')
      # Try to find JSON object in the content
      json_match = cleaned.match(/\{.*\}/m)
      cleaned = json_match[0] if json_match
    end
    
    cleaned
  end

  def process_tool_calls(tool_calls)
    append_tool_calls(tool_calls)
    tool_calls.each do |tool_call|
      process_tool_call(tool_call)
    end
    request_chat_completion
  end

  def process_tool_call(tool_call)
    arguments = JSON.parse(tool_call['function']['arguments'])
    function_name = tool_call['function']['name']
    tool_call_id = tool_call['id']

    if @tool_registry.respond_to?(function_name)
      execute_tool(function_name, arguments, tool_call_id)
    else
      process_invalid_tool_call(function_name, tool_call_id)
    end
  end

  def execute_tool(function_name, arguments, tool_call_id)
    persist_message(
      {
        content: I18n.t('captain.copilot.using_tool', function_name: function_name),
        function_name: function_name
      },
      'assistant_thinking'
    )
    result = @tool_registry.send(function_name, arguments)
    persist_message(
      {
        content: I18n.t('captain.copilot.completed_tool_call', function_name: function_name),
        function_name: function_name
      },
      'assistant_thinking'
    )
    append_tool_response(result, tool_call_id)
  end

  def append_tool_calls(tool_calls)
    @messages << {
      role: 'assistant',
      tool_calls: tool_calls
    }
  end

  def process_invalid_tool_call(function_name, tool_call_id)
    persist_message({ content: I18n.t('captain.copilot.invalid_tool_call'), function_name: function_name }, 'assistant_thinking')
    append_tool_response(I18n.t('captain.copilot.tool_not_available'), tool_call_id)
  end

  def append_tool_response(content, tool_call_id)
    @messages << {
      role: 'tool',
      tool_call_id: tool_call_id,
      content: content
    }
  end

  def log_chat_completion_request
    Rails.logger.info(
      "#{self.class.name} Assistant: #{@assistant.id}, Requesting chat completion
      for messages #{@messages} with #{@tool_registry&.registered_tools&.length || 0} tools
      "
    )
  end
end
