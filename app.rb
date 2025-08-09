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
  enable :logging
  
  # Rack::Loggerを使用してロガーを設定（Rack 3.2でdeprecated予定のため将来見直し）
  use Rack::Logger
  
  # LOG_LEVEL=DEBUG の場合のみ詳細ログ（存在しない場合はtrueでアクセスログのみ）
  set :logging, true
end

# タイムアウト関連の環境変数（デフォルトは既存値を維持）
SSE_TIMEOUT_SEC = Integer(ENV.fetch('SSE_TIMEOUT_SEC', '30'))
DISCORD_WAIT_TIMEOUT_SEC = Integer(ENV.fetch('DISCORD_WAIT_TIMEOUT_SEC', '20'))
HTTP_OPEN_TIMEOUT_SEC = ENV['HTTP_OPEN_TIMEOUT_SEC']&.strip
HTTP_READ_TIMEOUT_SEC = ENV['HTTP_READ_TIMEOUT_SEC']&.strip

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
  logger.info("[SSE] /stream start prompt=#{prompt.inspect}")

  stream do |out|
    begin
      # まず初期イベントを送ってヘッダをフラッシュ
      out << ":ok\n\n"

      session_id = create_session
      logger.info("[SSE] session created id=#{session_id}")
      ws = WebSocket::Client::Simple.connect(BACKEND_WS)
      logger.info("[SSE] WS connecting to #{BACKEND_WS}")

      sent_message = false

      ws.on(:open) do
        logger.info('[WS] open')
        ws.send({ type: 'init', sessionId: session_id }.to_json)
      end

      ws.on(:error) do |e|
        logger.error("[WS] error #{e}")
      end

      ws.on(:close) do |e|
        logger.info("[WS] close #{e}")
      end

      ws.on(:message) do |evt|
        logger.debug("[WS] message raw=#{evt.data}")
        msg = JSON.parse(evt.data) rescue nil
        unless msg
          logger.warn('[WS] non-JSON message ignored')
          next
        end
        case msg['type']
        when 'ready'
          logger.info('[WS] ready received')
          unless sent_message
            ws.send({ type: 'message', content: prompt }.to_json)
            sent_message = true
            logger.info('[WS] message sent')
          end
        when 'stream_chunk'
          if msg.dig('data', 'type') == 'content'
            chunk = msg.dig('data', 'data')
            out << "data: #{chunk}\n\n"
          end
        when 'stream_end'
          logger.info('[WS] stream_end')
          out << "event: end\ndata: done\n\n"
          out.close
          ws.close
        when 'error'
          err = msg['error']
          logger.error("[WS] backend error: #{err}")
          out << "event: backend_error\ndata: #{err}\n\n"
          out.close
          ws.close
        else
          logger.debug("[WS] ignored type=#{msg['type']}")
        end
      end

      # タイムアウト保護（環境変数で調整可能）
      Thread.new do
        sleep SSE_TIMEOUT_SEC
        begin
          logger.warn("[SSE] timeout #{SSE_TIMEOUT_SEC}s reached")
          out << "event: end\ndata: timeout\n\n"
          out.close
          ws.close
        rescue => te
          logger.error("[SSE] timeout cleanup error: #{te}")
        end
      end
    rescue => e
      logger.error("[SSE] exception: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
      out << "event: error\ndata: #{e.message}\n\n"
      out.close
    end
  end
end

# グローバルエラーハンドラ
error do
  e = env['sinatra.error']
  logger.error("[ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  status 500
  content_type :json
  { error: e.message }.to_json
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
    logger.info("[DISCORD] fetch_response_via_backend start")
    # 1) セッション作成 (HTTP)
    session_id = create_session
    logger.info("[DISCORD] session id=#{session_id}")

    # 2) WS接続してストリーミングを受信
    collected = String.new
    ws = WebSocket::Client::Simple.connect(BACKEND_WS)
    logger.info("[DISCORD] WS connect to #{BACKEND_WS}")

    ready = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    ws.on(:open) do
      logger.info('[DISCORD] WS open')
      ws.send({ type: 'init', sessionId: session_id }.to_json)
    end

    ws.on(:message) do |evt|
      logger.debug("[DISCORD] message raw=#{evt.data}")
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

    # タイムアウト（環境変数で調整可能）
    Thread.new do
      sleep DISCORD_WAIT_TIMEOUT_SEC
      logger.warn("[DISCORD] timeout #{DISCORD_WAIT_TIMEOUT_SEC}s reached")
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

    # HTTPの接続/読み込みタイムアウト（環境変数で設定があれば適用）
    http.open_timeout = Integer(HTTP_OPEN_TIMEOUT_SEC) if HTTP_OPEN_TIMEOUT_SEC && !HTTP_OPEN_TIMEOUT_SEC.empty?
    http.read_timeout = Integer(HTTP_READ_TIMEOUT_SEC) if HTTP_READ_TIMEOUT_SEC && !HTTP_READ_TIMEOUT_SEC.empty?

    req = Net::HTTP::Post.new(uri.request_uri)
    res = http.request(req)

    unless res.is_a?(Net::HTTPSuccess)
      logger.error("[BACKEND] session failed code=#{res.code} body=#{res.body}")
      raise "セッション作成に失敗しました (#{res.code})"
    end

    body = JSON.parse(res.body)
    sid = body['sessionId']
    unless sid
      logger.error("[BACKEND] session ok but sessionId missing body=#{res.body}")
      raise 'sessionId が取得できませんでした'
    end
    sid
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
