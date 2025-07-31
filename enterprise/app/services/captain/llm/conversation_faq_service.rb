class Captain::Llm::ConversationFaqService < Llm::BaseOpenAiService
  DISTANCE_THRESHOLD = 0.3

  def initialize(assistant, conversation)
    super()
    @assistant = assistant
    @conversation = conversation
    @content = conversation.to_llm_text
  end

  # Generates and deduplicates FAQs from conversation content
  # Skips processing if there was no human interaction
  def generate_and_deduplicate
    return [] if no_human_interaction?

    new_faqs = generate
    return [] if new_faqs.empty?

    # Embedding/deduplication is disabled: save all new FAQs
    save_new_faqs(new_faqs)
    Rails.logger.info("FAQ deduplication is disabled; all new FAQs are saved.") if Rails.env.development?
  end

  private

  attr_reader :content, :conversation, :assistant

  def no_human_interaction?
    conversation.first_reply_created_at.nil?
  end

  # The deduplication methods are now unused and can be ignored

  def save_new_faqs(faqs)
    faqs.map do |faq|
      assistant.responses.create!(
        question: faq['question'],
        answer: faq['answer'],
        status: 'pending',
        documentable: conversation
      )
    end
  end

  def generate
    response = @client.chat(parameters: chat_parameters)
    parse_response(response)
  rescue OpenAI::Error => e
    Rails.logger.error "OpenAI API Error: #{e.message}"
    []
  end

  def chat_parameters
    account_language = @conversation.account.locale_english_name
    prompt = Captain::Llm::SystemPromptsService.conversation_faq_generator(account_language)

    {
      model: @model,
      response_format: { type: 'json_object' },
      messages: [
        {
          role: 'system',
          content: prompt
        },
        {
          role: 'user',
          content: content
        }
      ]
    }
  end

  def parse_response(response)
    content = response.dig('choices', 0, 'message', 'content')
    return [] if content.nil?

    JSON.parse(content.strip).fetch('faqs', [])
  rescue JSON::ParserError => e
    Rails.logger.error "Error in parsing GPT processed response: #{e.message}"
    []
  end
end
