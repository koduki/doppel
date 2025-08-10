# lib/gateways/web_gateway.rb
require 'faye/websocket'
require 'json'

class WebGateway
  attr_writer :ai_client

  def initialize(chat_state, ai_client)
    @chat_state = chat_state
    @ai_client = ai_client
    @clients = []
  end

  def handle_request(request_env)
    if Faye::WebSocket.websocket?(request_env)
      ws = Faye::WebSocket.new(request_env, nil, {ping: 15})
      
      ws.on :open do |event|
        APP_LOGGER.info("[WEB_GW] WebSocket connection opened")
        @clients << ws
        ws.send({ type: 'history', payload: @chat_state.history }.to_json)
      end

      ws.on :message do |event|
        APP_LOGGER.info("[WEB_GW] Received message: #{event.data}")
        data = JSON.parse(event.data) rescue nil
        if data && data['type'] == 'user_message' && data['payload']
          @ai_client.start_stream(data['payload'])
        else
          APP_LOGGER.warn("[WEB_GW] Invalid message format: #{event.data}")
        end
      end

      ws.on :close do |event|
        APP_LOGGER.warn("[WEB_GW] WebSocket connection closed. Code: #{event.code}, Reason: #{event.reason}")
        @clients.delete(ws)
        ws = nil
      end

      ws.rack_response
    end
  end

  def broadcast(message)
    json_message = message.to_json
    APP_LOGGER.info("[WEB_GW] Broadcasting: #{json_message}")
    @clients.each { |c| c.send(json_message) }
  end
end
