require 'sinatra'
require 'sinatra/json'
# require 'faye/websocket' # This is handled by Bundler.require in config.ru
require 'base64'
require 'json'
require 'net/http'
require 'uri'
require 'websocket-client-simple'
require 'logger'
require 'securerandom'

# --- Sinatra App Setup ---
set :port, ENV.fetch('PORT', '8080').to_i
set :bind, '0.0.0.0'
set :sockets, []
set :message_history, []
set :history_max_size, 50
set :server, 'puma'

# --- Logging Setup ---
configure do
  disable :protection
  enable :logging
  use Rack::CommonLogger
  set :logging, true
end

APP_LOGGER = Logger.new($stdout)
APP_LOGGER.level = Logger.const_get(ENV.fetch('LOG_LEVEL', 'INFO').upcase) rescue Logger::INFO
APP_LOGGER.progname = 'app'

# --- Environment & Backend Config ---
DISCORD_CHANNEL_ID = ENV['DISCORD_CHANNEL_ID']
DISCORD_TOKEN = ENV['DISCORD_TOKEN']
APP_BACKEND_ORIGIN = ENV.fetch('APP_BACKEND_ORIGIN', 'http://localhost:3000/')
BACKEND_HTTP = ENV.fetch('BACKEND_HTTP', URI.join(APP_BACKEND_ORIGIN, 'api/chat').to_s)
BACKEND_WS = ENV.fetch('BACKEND_WS', URI.join(APP_BACKEND_ORIGIN.gsub(/^http/, 'ws'), '/').to_s)

configure do
  $stdout.puts "=" * 60
  $stdout.puts "Backend Configuration:"
  $stdout.puts "  BACKEND_HTTP: #{BACKEND_HTTP}"
  $stdout.puts "  BACKEND_WS: #{BACKEND_WS}"
  $stdout.puts "  DISCORD_CHANNEL_ID: #{DISCORD_CHANNEL_ID ? 'SET' : 'NOT SET'}"
  $stdout.puts "=" * 60
end

# --- Helper to add to history ---
def add_to_history(settings, message)
  # Only store user messages and final AI messages for cleaner history
  if message[:type] == 'user_message' || message[:type] == 'ai_end'
    settings.message_history << message
    if settings.message_history.size > settings.history_max_size
      settings.message_history.shift
    end
  end
end

# --- Routes ---
get '/' do
  if Faye::WebSocket.websocket?(request.env)
    ws = Faye::WebSocket.new(request.env, nil, {ping: 15})

    ws.on :open do |event|
      APP_LOGGER.info("[WS_HUB] WebSocket connection opened")
      settings.sockets << ws
      # Send history
      ws.send({ type: 'history', payload: settings.message_history }.to_json)
    end

    ws.on :message do |event|
      APP_LOGGER.info("[WS_HUB] Received message: #{event.data}")
      data = JSON.parse(event.data) rescue nil
      if data && data['type'] && data['payload']
        handle_message(data['type'], data['payload'])
      else
        APP_LOGGER.warn("[WS_HUB] Invalid message format: #{event.data}")
      end
    end

    ws.on :close do |event|
      APP_LOGGER.warn("[WS_HUB] WebSocket connection closed. Code: #{event.code}, Reason: #{event.reason}")
      settings.sockets.delete(ws)
      ws = nil
    end

    ws.rack_response
  else
    erb :index
  end
end

# --- Core Logic ---
def broadcast(settings, type, payload)
  message = { type: type, payload: payload }
  json_message = message.to_json
  
  add_to_history(settings, message)
  
  APP_LOGGER.info("[BROADCAST] #{json_message}")
  settings.sockets.each { |s| s.send(json_message) }
end

def handle_message(type, payload, discord_message = nil)
  case type
  when 'user_message'
    message_id = payload['id'] || SecureRandom.uuid
    full_payload = payload.merge('id' => message_id)
    broadcast(settings, 'user_message', full_payload)

    if payload['source'] == 'web' && CLIENT && DISCORD_CHANNEL_ID
      channel = CLIENT.fetch_channel(DISCORD_CHANNEL_ID).wait
      channel&.post("#{payload['author']}: #{payload['text']}")
    end

    start_backend_stream(payload['text'], message_id, discord_message)
  else
    APP_LOGGER.warn("[HANDLER] Unknown message type: #{type}")
  end
end

def start_backend_stream(prompt, message_id, discord_message = nil)
  session_id = create_session
  return unless session_id

  captured_settings = settings # Capture settings

  ws = WebSocket::Client::Simple.connect(BACKEND_WS)
  APP_LOGGER.info("[BACKEND] WS connecting to #{BACKEND_WS} for session #{session_id}")
  
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
      if msg.dig('data', 'type') == 'content'
        chunk = msg.dig('data', 'data')
        if chunk && !chunk.empty?
          full_ai_response << chunk
          broadcast(captured_settings, 'ai_chunk', { 'id' => message_id, 'text' => chunk })
        end
      end
    when 'stream_end'
      broadcast(captured_settings, 'ai_end', { 'id' => message_id, 'text' => full_ai_response })
      
      # If the response is not empty, post it to Discord
      if full_ai_response && !full_ai_response.empty?
        post_to_discord = nil
        
        if discord_message
          # If it's a reply to a Discord message, post to the same channel
          post_to_discord = ->(chunk) { discord_message.channel.post(chunk).wait }
          APP_LOGGER.info("[DISCORD] Replying to Discord message #{discord_message.id}")
        elsif CLIENT && DISCORD_CHANNEL_ID
          # Otherwise, if it's from the web, post to the designated channel
          channel = CLIENT.fetch_channel(DISCORD_CHANNEL_ID).wait
          if channel
            post_to_discord = ->(chunk) { channel.post(chunk).wait }
            APP_LOGGER.info("[DISCORD] Posting Web response to channel #{DISCORD_CHANNEL_ID}")
          else
            APP_LOGGER.warn("[DISCORD] Could not find channel with ID #{DISCORD_CHANNEL_ID}")
          end
        end

        if post_to_discord
          # Split into multiple messages if too long
          full_ai_response.scan(/.{1,2000}/m).each do |chunk|
            post_to_discord.call(chunk)
          end
        end
      end
      
      ws.close
    when 'error'
      broadcast(captured_settings, 'error', { 'id' => message_id, 'message' => msg['error'] })
      ws.close
    end
  end

  ws.on :error do |e|
    APP_LOGGER.error("[BACKEND] WS error: #{e}")
    broadcast(captured_settings, 'error', { 'id' => message_id, 'message' => 'Backend WebSocket connection error' })
  end
end

def create_session
  uri = URI.parse(BACKEND_HTTP)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  req = Net::HTTP::Post.new(uri.request_uri)
  
  begin
    res = http.request(req)
    unless res.is_a?(Net::HTTPSuccess)
      APP_LOGGER.error("[BACKEND] Session creation failed: #{res.code} #{res.body}")
      return nil
    end
    JSON.parse(res.body)['sessionId']
  rescue => e
    APP_LOGGER.error("[BACKEND] Session creation exception: #{e.message}")
    nil
  end
end

# --- Discord Gateway ---
if DISCORD_TOKEN && !DISCORD_TOKEN.empty?
  require "discorb"

  intents = Discorb::Intents.new(
    guilds: true,
    messages: true,
    message_content: true
  )
  CLIENT = Discorb::Client.new(intents: intents)

  CLIENT.once :standby do
    APP_LOGGER.info "[GW] discorb logged in as #{CLIENT.user}"
  end

  CLIENT.on :message do |message|
    next if message.author.bot?

    if message.content == '!history'
      APP_LOGGER.info "[GW] Received !history command"
      history_text = settings.message_history.map do |msg|
        p = msg[:payload]
        case msg[:type]
        when 'user_message'
          "[#{p['source']}/#{p['author']}] #{p['text']}"
        when 'ai_end'
          "\n[AI] #{p['text']}\n"
        else
          ''
        end
      end.join
      
      history_text = "No history yet." if history_text.empty?
      
      # Split into multiple messages if too long
      history_text.scan(/.{1,2000}/m).each do |chunk|
        message.channel.post("```\n#{chunk}\n```").wait
      end
      next
    end

    is_target_channel = message.channel.id.to_s == DISCORD_CHANNEL_ID.to_s
    is_dm = message.channel.is_a?(Discorb::DMChannel)
    
    next unless is_target_channel || is_dm

    APP_LOGGER.info "[GW] Received message from Discord: #{message.author.name}: #{message.content}"
    
    handle_message('user_message', {
      'id' => message.id.to_s,
      'source' => 'discord',
      'author' => message.author.name,
      'text' => message.content
    }, message)
  end

  Thread.new do
    APP_LOGGER.info "[GW] Starting discorb gateway..."
    CLIENT.run(DISCORD_TOKEN)
  end
else
  CLIENT = nil
  APP_LOGGER.warn "[GW] DISCORD_TOKEN or DISCORD_CHANNEL_ID is not set. Discord Gateway is disabled."
end

# --- Global Error Handler ---
error do
  e = env['sinatra.error']
  APP_LOGGER.error("[ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  status 500
  json error: e.message
end
