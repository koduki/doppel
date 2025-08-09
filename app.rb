require 'sinatra'
require 'sinatra/json'
require 'sinatra/reloader' if development?
require 'ed25519'
require 'base64'
require 'json'
require 'net/http'
require 'uri'
require 'websocket-client-simple'

set :port, ENV.fetch('PORT', '8080').to_i
set :bind, '0.0.0.0'

# Host Authorization を無効化（Cloud Runのrun.appドメインを許可するため）
configure do
  disable :protection
end

# 接続先を環境変数から指定できるようにする
APP_BACKEND_ORIGIN = ENV.fetch('APP_BACKEND_ORIGIN', 'http://34.68.145.5/')

def to_ws_url(origin)
  uri = URI(origin)
  uri.scheme = (uri.scheme == 'https') ? 'wss' : 'ws'
  uri.to_s
end

BACKEND_HTTP = ENV.fetch('BACKEND_HTTP', URI.join(APP_BACKEND_ORIGIN, 'api/chat').to_s)
BACKEND_WS   = ENV.fetch('BACKEND_WS', to_ws_url(APP_BACKEND_ORIGIN))

DISCORD_PUBLIC_KEY = ENV['DISCORD_PUBLIC_KEY']
DISCORD_APP_ID     = ENV['DISCORD_APP_ID']
DISCORD_TOKEN      = ENV['DISCORD_TOKEN']

get '/' do
  erb :index, locals: { backend_http: BACKEND_HTTP, backend_ws: BACKEND_WS, app_env: ENV.fetch('APP_ENV', 'development') }
end

# Discord HTTP Interactions entrypoint for Cloud Run
post '/interactions' do
  request.body.rewind
  raw_body = request.body.read
  timestamp = request.env['HTTP_X_SIGNATURE_TIMESTAMP']
  signature = request.env['HTTP_X_SIGNATURE_ED25519']

  halt 401, 'Bad request signature' unless valid_discord_signature?(timestamp, raw_body, signature)

  interaction = JSON.parse(raw_body)

  # PING -> PONG
  if interaction['type'] == 1
    content_type :json
    return JSON.generate({ type: 1 })
  end

  # Application Command or Message Component
  # まずACK (type 5) で遅延レスポンス
  token = interaction['token']
  app_id = DISCORD_APP_ID
  # DiscordはACK(type 5)で遅延レスポンスを期待するため、即時200 with {type:5} を返す
  Thread.new do
    begin
      user_prompt = extract_prompt(interaction)
      response_text = fetch_response_via_backend(user_prompt)
      edit_original_response(token, app_id, response_text)
    rescue => e
      edit_original_response(token, app_id, "エラーが発生しました: #{e.message}")
    end
  end

  status 200
  content_type :json
  JSON.generate({ type: 5 })
end

# ブラウザからはHTTPS同一オリジンでSSEに接続し、バックエンド(HTTP/WS)の結果を中継する
get '/stream' do
  content_type 'text/event-stream'
  headers 'Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no'

  prompt = params['prompt'].to_s

  stream do |out|
    begin
      session_id = create_session
      ws = WebSocket::Client::Simple.connect(BACKEND_WS)

      sent_message = false

      ws.on(:open) do
        ws.send({ type: 'init', sessionId: session_id }.to_json)
      end

      ws.on(:message) do |evt|
        msg = JSON.parse(evt.data) rescue nil
        next unless msg
        case msg['type']
        when 'ready'
          unless sent_message
            ws.send({ type: 'message', content: prompt }.to_json)
            sent_message = true
          end
        when 'stream_chunk'
          if msg.dig('data', 'type') == 'content'
            out << "data: #{msg.dig('data', 'data')}\n\n"
          end
        when 'stream_end'
          out << "event: end\ndata: done\n\n"
          out.close
          ws.close
        when 'error'
          out << "event: error\ndata: #{msg['error']}\n\n"
          out.close
          ws.close
        end
      end

      # タイムアウト保護
      Thread.new do
        sleep 30
        begin
          out << "event: end\ndata: timeout\n\n"
          out.close
          ws.close
        rescue
        end
      end
    rescue => e
      out << "event: error\ndata: #{e.message}\n\n"
      out.close
    end
  end
end

helpers do
  def valid_discord_signature?(timestamp, body, signature)
    return false if DISCORD_PUBLIC_KEY.to_s.strip.empty?
    verify_key = Ed25519::VerifyKey.new([DISCORD_PUBLIC_KEY].pack('H*'))
    message = timestamp + body
    begin
      verify_key.verify([signature].pack('H*'), message)
      true
    rescue Ed25519::VerifyError
      false
    end
  end

  def extract_prompt(interaction)
    # スラッシュコマンドのオプションやメッセージ内容からテキストを抽出
    if interaction['data'] && interaction['data']['options']&.any?
      first = interaction['data']['options'].first
      first['value'].to_s
    elsif interaction['data'] && interaction['data']['name']
      interaction['data']['name'].to_s
    else
      'こんにちは'
    end
  end

  def fetch_response_via_backend(prompt)
    # 1) セッション作成 (HTTP)
    session_id = create_session

    # 2) WS接続してストリーミングを受信
    collected = String.new
    ws = WebSocket::Client::Simple.connect(BACKEND_WS)

    ready = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    ws.on(:open) do
      ws.send({ type: 'init', sessionId: session_id }.to_json)
    end

    ws.on(:message) do |evt|
      msg = JSON.parse(evt.data) rescue nil
      next unless msg
      case msg['type']
      when 'ready'
        ready = true
        ws.send({ type: 'message', content: prompt }.to_json)
      when 'stream_chunk'
        if msg.dig('data', 'type') == 'content'
          collected << msg.dig('data', 'data').to_s
        end
      when 'stream_end'
        mutex.synchronize { cond.signal }
      when 'error'
        collected << "\n[Error] #{msg['error']}"
        mutex.synchronize { cond.signal }
      end
    end

    # タイムアウト
    Thread.new do
      sleep 20
      mutex.synchronize { cond.signal }
    end

    mutex.synchronize { cond.wait(mutex) }
    ws.close

    collected.empty? ? '応答がありませんでした。' : collected
  end

  def create_session
    uri = URI.parse(BACKEND_HTTP)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'

    req = Net::HTTP::Post.new(uri.request_uri)
    res = http.request(req)

    raise "セッション作成に失敗しました (#{res.code})" unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    body['sessionId'] || raise('sessionId が取得できませんでした')
  end

  def edit_original_response(token, app_id, content)
    uri = URI("https://discord.com/api/v10/webhooks/#{app_id}/#{token}/messages/@original")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Patch.new(uri.request_uri, { 'Content-Type' => 'application/json' })
    req.body = { content: content }.to_json
    res = http.request(req)

    unless res.is_a?(Net::HTTPSuccess)
      warn "Discord edit message failed: #{res.code} #{res.body}"
    end
  end
end
