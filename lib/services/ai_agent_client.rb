# lib/services/ai_agent_client.rb
require 'websocket-client-simple'
require 'net/http'
require 'uri'
require 'securerandom'
require 'json'

class AIAgentClient
  def initialize(backend_ws_url, backend_http_url, chat_state, web_gateway, discord_gateway)
    @backend_ws_url = backend_ws_url
    @backend_http_url = backend_http_url
    @chat_state = chat_state
    @web_gateway = web_gateway
    @discord_gateway = discord_gateway
  end

  def start_stream(payload, discord_message: nil)
    message_id = payload['id'] || SecureRandom.uuid
    full_payload = payload.merge('id' => message_id)
    
    # Broadcast and save user message
    user_message = { type: 'user_message', payload: full_payload }
    @chat_state.add_message(user_message)
    @web_gateway.broadcast(user_message)

    # Post user's web message to Discord
    if payload['source'] == 'web' && @discord_gateway
      post_user_message_to_discord(full_payload)
    end

    # Start backend processing in a new thread to avoid blocking
    Thread.new do
      process_in_backend(full_payload['text'], message_id, discord_message)
    end
  end

  private

  def process_in_backend(prompt, message_id, discord_message)
    session_id = create_session
    return unless session_id

    this = self # Capture the AIAgentClient instance
    ws = WebSocket::Client::Simple.connect(@backend_ws_url)
    APP_LOGGER.info("[AI_CLIENT] WS connecting to #{@backend_ws_url} for session #{session_id}")
    
    full_ai_response = ""

    ws.on :open do
      ws.send({ type: 'init', sessionId: session_id }.to_json)
    end

    ws.on :message do |evt|
      msg = JSON.parse(evt.data) rescue nil
      next unless msg

      case msg['type']
      when 'ready'
        ws.send({ type: 'message', content: prompt }.to_json)
      when 'stream_chunk'
        this.send(:_internal_handle_chunk, msg, message_id, full_ai_response)
      when 'stream_end'
        this.send(:_internal_handle_end, message_id, full_ai_response, discord_message)
        ws.close
      when 'error'
        this.send(:_internal_handle_error, message_id, msg['error'])
        ws.close
      end
    end

    ws.on :error do |e|
      this.send(:_internal_handle_error, message_id, "Backend WebSocket connection error: #{e}")
    end
  end

  def _internal_handle_chunk(msg, message_id, full_ai_response)
    if msg.dig('data', 'type') == 'content'
      chunk = msg.dig('data', 'data')
      if chunk && !chunk.empty?
        full_ai_response << chunk
        message = { type: 'ai_chunk', payload: { 'id' => message_id, 'text' => chunk } }
        @chat_state.add_message(message)
        @web_gateway.broadcast(message)
      end
    end
  end

  def _internal_handle_end(message_id, full_ai_response, discord_message)
    APP_LOGGER.debug("[AI_CLIENT] Stream ended. Full response: '#{full_ai_response}'")
    message = { type: 'ai_end', payload: { 'id' => message_id, 'text' => full_ai_response } }
    @chat_state.add_message(message)
    @web_gateway.broadcast(message)

    if @discord_gateway && full_ai_response && !full_ai_response.empty?
      post_ai_response_to_discord(full_ai_response, discord_message)
    end
  end

  def _internal_handle_error(message_id, error_message)
    APP_LOGGER.error("[AI_CLIENT] Error: #{error_message}")
    message = { type: 'error', payload: { 'id' => message_id, 'message' => error_message } }
    @web_gateway.broadcast(message)
  end

  def post_user_message_to_discord(payload)
    @discord_gateway.post_user_web_message(payload)
  end

  def post_ai_response_to_discord(response, discord_message)
    if discord_message
      APP_LOGGER.info("[DISCORD] Replying to Discord message #{discord_message.id}")
      target_channel = discord_message.channel
    else
      APP_LOGGER.info("[DISCORD] Posting Web response to channel")
      # We ask the gateway to get the channel, as it knows the ID
      target_channel = @discord_gateway.get_designated_channel
    end
    
    return unless target_channel
    response.scan(/.{1,2000}/m).each do |chunk|
      @discord_gateway.post_message(target_channel, chunk)
    end
  end

  def create_session
    uri = URI.parse(@backend_http_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    req = Net::HTTP::Post.new(uri.request_uri)
    
    begin
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        APP_LOGGER.error("[AI_CLIENT] Session creation failed: #{res.code} #{res.body}")
        return nil
      end
      JSON.parse(res.body)['sessionId']
    rescue => e
      APP_LOGGER.error("[AI_CLIENT] Session creation exception: #{e.message}")
      nil
    end
  end
end