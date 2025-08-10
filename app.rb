# app.rb
require 'sinatra'
require 'sinatra/json'
require 'logger'

# --- Load Components ---
require_relative 'lib/chat_state'
require_relative 'lib/gateways/web_gateway'
require_relative 'lib/gateways/discord_gateway'
require_relative 'lib/services/chat_orchestrator'

# --- Sinatra App Setup ---
set :port, ENV.fetch('PORT', '8080').to_i
set :bind, '0.0.0.0'
set :server, 'puma'
set :views, File.dirname(__FILE__) + '/views'


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

# --- Component Initialization & Dependency Injection ---
chat_state = ChatState.new

# Gateways are our responders. They listen for events.
web_gateway = WebGateway.new(chat_state, nil) # ai_client is set later
discord_gateway = DiscordGateway.new(DISCORD_TOKEN, DISCORD_CHANNEL_ID, chat_state, nil) # ai_client is set later
responders = [web_gateway, discord_gateway].compact # Use compact to remove nil if discord_gateway isn't configured

# The AI client orchestrates the interaction.
chat_orchestrator = ChatOrchestrator.new(BACKEND_WS, BACKEND_HTTP, chat_state, responders)

# Inject the orchestrator back into the gateways so they can initiate streams.
web_gateway.chat_orchestrator = chat_orchestrator
discord_gateway.chat_orchestrator = chat_orchestrator if discord_gateway


# --- Start Services ---
discord_gateway.run if discord_gateway

# --- Routes ---
get '/' do
  if Faye::WebSocket.websocket?(request.env)
    web_gateway.handle_request(request.env)
  else
    erb :index
  end
end

# --- Global Error Handler ---
error do
  e = env['sinatra.error']
  APP_LOGGER.error("[ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  status 500
  json error: e.message
end