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

# 定数定義後にバックエンド設定をログ出力
configure do
  $stdout.puts "=" * 60
  $stdout.puts "Backend Configuration:"
  $stdout.puts "  APP_BACKEND_ORIGIN: #{APP_BACKEND_ORIGIN}"
  $stdout.puts "  BACKEND_HTTP: #{BACKEND_HTTP}"
  $stdout.puts "  BACKEND_WS: #{BACKEND_WS}"
  $stdout.puts "  SSE_TIMEOUT_SEC: #{SSE_TIMEOUT_SEC}"
  $stdout.puts "  DISCORD_WAIT_TIMEOUT_SEC: #{DISCORD_WAIT_TIMEOUT_SEC}"
  $stdout.puts "=" * 60
end

get '/' do
  erb :index, locals: { backend_http: BACKEND_HTTP, backend_ws: BACKEND_WS, app_env: ENV.fetch('APP_ENV', 'development') }
end

# Discord HTTP Interactions entrypoint for Cloud Run
post '/interactions' do
  request.body.rewind
  raw_body = request.body.read
  ts  = request.env['HTTP_X_SIGNATURE_TIMESTAMP']
  sig = request.env['HTTP_X_SIGNATURE_ED25519']

  logger.info("[INT] ts.len=#{ts&.length} sig.len=#{sig&.length} body.len=#{raw_body.bytesize} pk.len=#{DISCORD_PUBLIC_KEY&.length}")
  halt 401, 'Bad request signature' unless valid_discord_signature?(ts, raw_body, sig)

  payload = JSON.parse(raw_body) rescue {}
  itype = payload['type']

  # PING -> PONG
  if itype == 1
    content_type :json
    return JSON.dump(type: 1)
  end

  # スラッシュコマンド（APPLICATION_COMMAND）
  if itype == 2
    token  = payload['token']
    app_id = DISCORD_APP_ID

    # まずはACK（3秒以内に即返す）
    content_type :json
    Thread.new do
      begin
        user_prompt   = extract_prompt(payload)
        response_text = fetch_response_via_backend(user_prompt)
        edit_original_response(token, app_id, response_text)
      rescue => e
        logger.error "[INT] worker error: #{e.class}: #{e.message}"
        edit_original_response(token, app_id, "エラー: #{e.message}")
      end
    end

    # エフェメラルにしたいなら flags: 64 を付ける
    return JSON.dump(type: 5)  # or JSON.dump(type: 5, data: { flags: 64 })
  end

  # それ以外（ボタン等）は未対応なら204
  status 204
end

# ブラウザからはHTTPS同一オリジンでSSEに接続し、バックエンド(HTTP/WS)の結果を中継する
get '/stream' do
  content_type 'text/event-stream'
  headers 'Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no', 'Connection' => 'keep-alive'

  prompt = params['prompt'].to_s
  logger.info("[SSE] /stream start prompt=#{prompt.inspect}")

  stream(:keep_open) do |out|
    begin
      # 初期イベント送信
      out << "retry: 10000\n\n"
      out << ":connected\n\n"
      logger.info("[SSE] Initial headers sent")

      state_mutex = Mutex.new
      chunk_count = 0

      start_backend_stream(
        prompt,
        timeout_sec: SSE_TIMEOUT_SEC,
        app_logger: logger,
        on_chunk: ->(chunk) {
          state_mutex.synchronize do
            unless out.closed?
              chunk_count += 1
              logger.info("[SSE] Sending chunk ##{chunk_count}: #{chunk.inspect[0..100]}")
              out << "data: #{chunk}\n\n"
              out.flush if out.respond_to?(:flush)
            end
          end
        },
        on_end: -> {
          state_mutex.synchronize do
            unless out.closed?
              logger.info("[WS] stream_end - Total chunks sent: #{chunk_count}")
              out << "event: end\ndata: done\n\n"
              out.close
            end
          end
        },
        on_error: ->(err) {
          state_mutex.synchronize do
            unless out.closed?
              logger.error("[WS] backend error: #{err}")
              out << "event: backend_error\ndata: #{err}\n\n"
              out.close
            end
          end
        }
      )
    rescue => e
      logger.error("[SSE] exception: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
      out << "event: error\ndata: #{e.message}\n\n" unless out.closed?
      out.close unless out.closed?
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
    return false if timestamp.to_s.empty? || signature.to_s.empty? || body.nil?

    verify_key = Ed25519::VerifyKey.new([DISCORD_PUBLIC_KEY].pack('H*'))
    verify_key.verify([signature].pack('H*'), timestamp + body)
    true
  rescue Ed25519::VerifyError, ArgumentError => e
    logger.warn "[INT] verify failed: #{e.class}: #{e.message}"
    false
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

  # 共通化: バックエンド(HTTP/WS)と会話ストリームを開始し、与えられたコールバックで処理する
  def start_backend_stream(prompt, timeout_sec:, app_logger:, on_chunk:, on_end:, on_error:)
    session_id = create_session
    app_logger.info("[BACKEND] session created id=#{session_id}")

    ws = WebSocket::Client::Simple.connect(BACKEND_WS)
    app_logger.info("[BACKEND] WS connecting to #{BACKEND_WS}")

    state_mutex = Mutex.new
    finished = false
    sent_message = false

    ws.on(:open) do
      app_logger.info('[WS] open')
      ws.send({ type: 'init', sessionId: session_id }.to_json)
    end

    ws.on(:error) do |e|
      state_mutex.synchronize do
        unless finished
          app_logger.error("[WS] error #{e}")
        end
      end
    end

    ws.on(:close) do |e|
      state_mutex.synchronize do
        if finished
          app_logger.debug("[WS] close after finished #{e}")
        else
          app_logger.info("[WS] close #{e}")
        end
      end
    end

    ws.on(:message) do |evt|
      app_logger.info("[WS] message raw=#{evt.data}")
      msg = JSON.parse(evt.data) rescue nil
      unless msg
        app_logger.warn('[WS] non-JSON message ignored')
        next
      end
      app_logger.info("[WS] message type=#{msg['type']}")

      case msg['type']
      when 'ready'
        app_logger.info('[WS] ready received')
        unless sent_message
          ws.send({ type: 'message', content: prompt }.to_json)
          sent_message = true
          app_logger.info("[WS] message sent: #{prompt.inspect}")
        end
      when 'stream_chunk'
        if msg.dig('data', 'type') == 'content'
          chunk = msg.dig('data', 'data')
          if chunk && !chunk.empty?
            state_mutex.synchronize do
              unless finished
                on_chunk.call(chunk)
              end
            end
          else
            app_logger.info('[WS] Empty chunk ignored')
          end
        else
          app_logger.info("[WS] stream_chunk but not content type: #{msg.dig('data', 'type')}")
        end
      when 'stream_end'
        should_close = false
        state_mutex.synchronize do
          unless finished
            finished = true
            should_close = true
          end
        end
        if should_close
          app_logger.info('[WS] stream_end')
          on_end.call
          ws.close
        end
      when 'error'
        err = msg['error']
        should_close = false
        state_mutex.synchronize do
          unless finished
            finished = true
            should_close = true
          end
        end
        if should_close
          app_logger.error("[WS] backend error: #{err}")
          on_error.call(err)
          ws.close
        end
      else
        app_logger.info("[WS] unknown message type=#{msg['type']}, data=#{msg['data'].inspect}")
      end
    end

    timeout_thread = Thread.new do
      sleep timeout_sec
      should_close = false
      state_mutex.synchronize do
        unless finished
          finished = true
          should_close = true
        end
      end
      if should_close
        begin
          app_logger.error("[BACKEND] timeout #{timeout_sec}s reached (prompt=#{prompt.inspect})")
          on_error.call('timeout')
          ws.close
        rescue => te
          app_logger.error("[BACKEND] timeout cleanup error: #{te}")
        end
      end
    end

    { ws: ws, timeout_thread: timeout_thread }
  end

  def fetch_response_via_backend(prompt)
    logger.info('[DISCORD] fetch_response_via_backend start')

    collected = String.new
    mutex = Mutex.new
    cond = ConditionVariable.new
    done = false

    controller = start_backend_stream(
      prompt,
      timeout_sec: DISCORD_WAIT_TIMEOUT_SEC,
      app_logger: logger,
      on_chunk: ->(chunk) {
        logger.info("[DISCORD] chunk content: #{chunk.to_s.inspect[0..100]}")
        collected << chunk.to_s
      },
      on_end: -> {
        logger.info("[DISCORD] stream_end received, collected: #{collected.length} chars")
        mutex.synchronize { done = true; cond.signal }
      },
      on_error: ->(err) {
        logger.error("[DISCORD] error: #{err}")
        collected << "\n[Error] #{err}"
        mutex.synchronize { done = true; cond.signal }
      }
    )

    mutex.synchronize { cond.wait(mutex) unless done }

    controller[:timeout_thread]&.kill
    controller[:ws]&.close

    collected.empty? ? '応答がありませんでした。' : collected
  end

  def create_session
    uri = URI.parse(BACKEND_HTTP)
    logger.info("[create_session] Connecting to #{uri}")
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
    logger.info("[create_session] Session created: #{sid}")
    sid
  end

  def edit_original_response(token, app_id, content)
    uri = URI("https://discord.com/api/v10/webhooks/#{app_id}/#{token}/messages/@original")
    http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
    req = Net::HTTP::Patch.new(uri.request_uri, { 'Content-Type' => 'application/json' })
    req.body = { content: content }.to_json
    res = http.request(req)
    logger.info "[INT] edit original: #{res.code} #{res.body}"
    res.is_a?(Net::HTTPSuccess)
  end

end
