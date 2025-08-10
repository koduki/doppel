# lib/gateways/discord_gateway.rb
require 'discorb'

class DiscordGateway
  attr_writer :ai_client

  def initialize(token, channel_id, chat_state, ai_client)
    return unless token && !token.empty?

    @token = token
    @channel_id = channel_id
    @chat_state = chat_state
    @ai_client = ai_client
    
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

  def post_message(channel, message)
    channel.post(message).wait
  end

  def post_embed(channel, embed)
    channel.post(embeds: [embed]).wait
  end

  def get_designated_channel
    return nil unless @channel_id
    @client.fetch_channel(@channel_id).wait
  end

  def post_user_web_message(payload)
    channel = get_designated_channel
    return unless channel

    embed = Discorb::Embed.new("")
    embed.description = payload['text']
    embed.color = Discorb::Color.from_hex("#7289da")
    embed.author = Discorb::Embed::Author.new(payload['author'])
    embed.footer = Discorb::Embed::Footer.new("via Web UI")
    post_embed(channel, embed)
  end

  private

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
    
    # Start AI processing, passing the original message for reply context
    @ai_client.start_stream(payload, discord_message: message)
    true
  end
end