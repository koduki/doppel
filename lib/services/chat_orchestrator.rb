# lib/services/chat_orchestrator.rb
require 'websocket-client-simple'
require 'net/http'
require 'uri'
require 'securerandom'
require 'json'
require 'thread'

class ChatOrchestrator
  def initialize(backend_ws_url, backend_http_url, chat_state, responders)
    @backend_ws_url = backend_ws_url
    @backend_http_url = backend_http_url
    @chat_state = chat_state
    @responders = responders
    @job_queue = Queue.new
    run_worker
  end

  def start_stream(payload, context: {})
    message_id = payload['id'] || SecureRandom.uuid
    full_payload = payload.merge('id' => message_id)
    
    user_message = { type: 'user_message', payload: full_payload, context: context }
    @chat_state.add_message(user_message)
    @responders.each { |r| r.broadcast_user_message(user_message) }

    # Add the job to the queue instead of creating a new thread directly
    @job_queue.push({
      prompt: full_payload['text'],
      message_id: message_id,
      context: context
    })
  end

  private

  def run_worker
    Thread.new do
      loop do
        job = @job_queue.pop # This will block until a job is available
        process_in_backend(job[:prompt], job[:message_id], job[:context])
      end
    end
  end

  def process_in_backend(prompt, message_id, context)
    session_id = create_session
    return unless session_id

    this = self
    ws = WebSocket::Client::Simple.connect(@backend_ws_url)
    APP_LOGGER.info("[ORCHESTRATOR] WS connecting to #{@backend_ws_url} for session #{session_id}")
    
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
        this.send(:handle_stream_chunk, msg, message_id, full_ai_response, context)
      when 'stream_end'
        this.send(:handle_stream_end, message_id, full_ai_response, context)
        ws.close
      when 'error'
        this.send(:handle_error, message_id, msg['error'], context)
        ws.close
      end
    end

    ws.on :error do |e|
      this.send(:handle_error, message_id, "Backend WebSocket connection error: #{e}", context)
    end
  end

  def handle_stream_chunk(msg, message_id, full_ai_response, context)
    if msg.dig('data', 'type') == 'content'
      chunk = msg.dig('data', 'data')
      if chunk && !chunk.empty?
        full_ai_response << chunk
        message = { type: 'ai_chunk', payload: { 'id' => message_id, 'text' => chunk }, context: context }
        @chat_state.add_message(message)
        @responders.each { |r| r.broadcast_ai_chunk(message) }
      end
    end
  end

  def handle_stream_end(message_id, full_ai_response, context)
    APP_LOGGER.debug("[ORCHESTRATOR] Stream ended. Full response: '#{full_ai_response}'")
    message = { type: 'ai_end', payload: { 'id' => message_id, 'text' => full_ai_response }, context: context }
    @chat_state.add_message(message)
    @responders.each { |r| r.broadcast_ai_end(message) }
  end

  def handle_error(message_id, error_message, context)
    APP_LOGGER.error("[ORCHESTRATOR] Error: #{error_message}")
    message = { type: 'error', payload: { 'id' => message_id, 'message' => error_message }, context: context }
    @responders.each { |r| r.broadcast_error(message) }
  end

  def create_session
    uri = URI.parse(@backend_http_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    req = Net::HTTP::Post.new(uri.request_uri)
    
    begin
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        APP_LOGGER.error("[ORCHESTRATOR] Session creation failed: #{res.code} #{res.body}")
        return nil
      end
      JSON.parse(res.body)['sessionId']
    rescue => e
      APP_LOGGER.error("[ORCHESTRATOR] Session creation exception: #{e.message}")
      nil
    end
  end
end
