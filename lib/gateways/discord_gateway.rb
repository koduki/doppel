# lib/gateways/discord_gateway.rb
require 'discorb'

class DiscordGateway
  attr_writer :chat_orchestrator

  def initialize(token, channel_id, chat_state, chat_orchestrator)
    return unless token && !token.empty?

    @token = token
    @channel_id = channel_id
    @chat_state = chat_state
    @chat_orchestrator = chat_orchestrator
    
    intents = Discorb::Intents.new(
      guilds: true,
      messages: true,
      message_content: true
    )
    @client = Discorb::Client.new(intents: intents)
    setup_events
  end

  def run
    return unless @client
    Thread.new do
      APP_LOGGER.info "[GW] Starting discorb gateway..."
      @client.run(@token)
    end
  end

  # --- Common Gateway Interface ---

  def broadcast_user_message(message)
    # Only post to Discord if the message originated from the web
    if message[:payload]['source'] == 'web'
      Thread.new do
        channel = get_designated_channel
        next unless channel

        embed = Discorb::Embed.new("")
        embed.description = message[:payload]['text']
        embed.color = Discorb::Color.from_hex("#7289da")
        embed.author = Discorb::Embed::Author.new(message[:payload]['author'])
        embed.footer = Discorb::Embed::Footer.new("via Web UI")
        post_embed(channel, embed)
      end
    end
  end

  def broadcast_ai_chunk(message)
    # Do nothing, as we don't stream to Discord
  end

  def broadcast_ai_end(message)
    Thread.new do
      # Post the final AI response to the appropriate channel
      target_channel = if message[:context] && message[:context][:discord_message]
        message[:context][:discord_message].channel
      else
        get_designated_channel
      end
      
      next unless target_channel
      full_text = message[:payload]['text']
      next if full_text.nil? || full_text.strip.empty?

      full_text.scan(/.{1,2000}/m).each do |chunk|
        post_message(target_channel, chunk)
      end
    end
  end

  def broadcast_error(message)
    # For now, we don't post errors to Discord to avoid spam.
    # This could be changed to log to a specific admin channel.
  end

  # --- Helper Methods ---

  def get_designated_channel
    return nil unless @channel_id
    @client.fetch_channel(@channel_id).wait
  end

  private

  def post_message(channel, message)
    channel.post(message).wait
  end

  def post_embed(channel, embed)
    channel.post(embeds: [embed]).wait
  end

  def setup_events
    @client.once :standby do
      APP_LOGGER.info "[GW] discorb logged in as #{@client.user}"
    end

    @client.on :message do |message|
      next if message.author.bot?
      handle_history_command(message) || handle_regular_message(message)
    end
  end

  def handle_history_command(message)
    return false unless message.content == '!history'
    
    APP_LOGGER.info "[GW] Received !history command"
    history_text = @chat_state.history.map do |msg|
      p = msg[:payload]
      case msg[:type]
      when 'user_message'
        "[#{p['source']}/#{p['author']}] #{p['text']}"
      when 'ai_end', 'ai_chunk'
        "\n[AI] #{p['text']}\n"
      else
        ''
      end
    end.join
    
    history_text = "No history yet." if history_text.empty?
    
    history_text.scan(/.{1,2000}/m).each do |chunk|
      message.channel.post("```\n#{chunk}\n```").wait
    end
    true
  end

  def handle_regular_message(message)
    is_target_channel = message.channel.id.to_s == @channel_id.to_s
    is_dm = message.channel.is_a?(Discorb::DMChannel)
    
    return false unless is_target_channel || is_dm

    APP_LOGGER.info "[GW] Received message from Discord: #{message.author.name}: #{message.content}" 
    
    payload = {
      'id' => message.id.to_s,
      'source' => 'discord',
      'author' => message.author.name,
      'text' => message.content
    }
    
    # Pass original message for reply context
    @chat_orchestrator.start_stream(payload, context: { discord_message: message })
    true
  end
end
