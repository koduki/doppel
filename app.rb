require 'sinatra'
require 'sinatra/json'
require 'sinatra/reloader' if development?
require 'sinatra-websocket'
require 'ed25519'
require 'base64'
require 'json'
require 'net/http'
require 'uri'
require 'websocket-client-simple'
require 'logger'

set :port, ENV.fetch('PORT', '8080').to_i
set :bind, '0.0.0.0'
set :sockets, []

# Host Authorization を無効化（Cloud Runのrun.appドメインを許可するため）
configure do
  disable :protection
  enable :logging
  
  # Rack::Loggerを使用してロガーを設定（Rack 3.2でdeprecated予定のため将来見直し）
  use Rack::CommonLogger
  
  # LOG_LEVEL=DEBUG の場合のみ詳細ログ（存在しない場合はtrueでアクセスログのみ）
  set :logging, true
end

# リクエストスコープ外でも使えるアプリ共通ロガー
APP_LOGGER = Logger.new($stdout)
case ENV.fetch('LOG_LEVEL', 'INFO').to_s.upcase
when 'DEBUG'
  APP_LOGGER.level = Logger::DEBUG
when 'INFO'
  APP_LOGGER.level = Logger::INFO
when 'WARN', 'WARNING'
  APP_LOGGER.level = Logger::WARN
when 'ERROR'
  APP_LOGGER.level = Logger::ERROR
else
  APP_LOGGER.level = Logger::INFO
end
APP_LOGGER.progname = 'app'

# タイムアウト関連の環境変数（デフォルトは既存値を維持）
SSE_TIMEOUT_SEC = Integer(ENV.fetch('SSE_TIMEOUT_SEC', '30'))
DISCORD_WAIT_TIMEOUT_SEC = Integer(ENV.fetch('DISCORD_WAIT_TIMEOUT_SEC', '20'))
HTTP_OPEN_TIMEOUT_SEC = ENV['HTTP_OPEN_TIMEOUT_SEC']&.strip
HTTP_READ_TIMEOUT_SEC = ENV['HTTP_READ_TIMEOUT_SEC']&.strip

# 接続先を環境変数から指定できるようにする
APP_BACKEND_ORIGIN = ENV.fetch('APP_BACKEND_ORIGIN', 'http://localhost:3000/')

def to_ws_url(origin)
  uri = URI(origin)
  uri.scheme = (uri.scheme == 'https') ? 'wss' : 'ws'
  uri.to_s
end

BACKEND_HTTP = ENV.fetch('BACKEND_HTTP', URI.join(APP_BACKEND_ORIGIN, 'api/chat').to_s)
BACKEND_WS   = ENV.fetch('BACKEND_WS', to_ws_url(APP_BACKEND_ORIGIN))

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
  APP_LOGGER.error("[ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
  status 500
  content_type :json
  { error: e.message }.to_json
end

# --- Helper methods (moved to top-level for global access) ---

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

def create_session
  uri = URI.parse(BACKEND_HTTP)
  APP_LOGGER.info("[create_session] Connecting to #{uri}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'

  # HTTPの接続/読み込みタイムアウト（環境変数で設定があれば適用）
  http.open_timeout = Integer(HTTP_OPEN_TIMEOUT_SEC) if HTTP_OPEN_TIMEOUT_SEC && !HTTP_OPEN_TIMEOUT_SEC.empty?
  http.read_timeout = Integer(HTTP_READ_TIMEOUT_SEC) if HTTP_READ_TIMEOUT_SEC && !HTTP_READ_TIMEOUT_SEC.empty?

  req = Net::HTTP::Post.new(uri.request_uri)
  res = http.request(req)

  unless res.is_a?(Net::HTTPSuccess)
    APP_LOGGER.error("[BACKEND] session failed code=#{res.code} body=#{res.body}")
    raise "セッション作成に失敗しました (#{res.code})"
  end

  body = JSON.parse(res.body)
  sid = body['sessionId']
  unless sid
    APP_LOGGER.error("[BACKEND] session ok but sessionId missing body=#{res.body}")
    raise 'sessionId が取得できませんでした'
  end
  APP_LOGGER.info("[create_session] Session created: #{sid}")
  sid
end


# --- Discord Gateway (discorb) を同居起動 ---------------------------------
if DISCORD_TOKEN && !DISCORD_TOKEN.empty?
  require "discorb"

  # 利用するインテントを明示的に指定 (discorb v0.20.0)
  intents = Discorb::Intents.new(
    guilds: true,          # サーバー情報の取得に必要
    messages: true,        # サーバー/DMでのメッセージ受信に必要
    message_content: true, # メッセージ内容の取得に必要 (特権)
    members: true          # サーバーメンバー情報の取得に必要 (特権)
  )

  CLIENT = Discorb::Client.new(intents: intents)

  # メンション表記を本文から除去
  def strip_bot_mention(client, content)
    bot_id = client.user.id
    content.gsub(/<@!?#{bot_id}>\s*/, "").strip
  end

  # 受けテキストをチャットAPIにストリーム連携→Discord側に段階編集で反映
  def stream_reply_via_backend_dsc(message, text, timeout: DISCORD_WAIT_TIMEOUT_SEC, logger:)
    # プレースホルダを送信し、完了を待ってメッセージオブジェクトを取得
    msg = message.channel.post("…").wait
    buffer = +""
    last_edit = Time.now

    start_backend_stream(
      text,
      timeout_sec: timeout,
      app_logger: logger,
      on_chunk: ->(chunk) {
        buffer << chunk.to_s
        # レート制限対策：1秒おき or 200文字ごとに控えめに編集
        if (Time.now - last_edit) >= 1 || buffer.length >= 200
          begin
            # 元チャンネル経由でメッセージを編集
            message.channel.edit_message(msg, buffer).wait
          rescue => e
            logger.warn "[GW] edit failed: #{e.class}: #{e.message}"
            # もし edit が失敗したら控えめに追記投稿（最小限のフォールバック）
            begin
              msg = message.channel.post(buffer).wait
            rescue => e2
              logger.error "[GW] post fallback failed: #{e2.class}: #{e2.message}"
            end
          ensure
            last_edit = Time.now
          end
        end
      },
      on_end: -> {
        begin
          # 元チャンネル経由で最終編集
          final_content = buffer.empty? ? "(empty)" : buffer
          message.channel.edit_message(msg, final_content).wait
        rescue => e
          logger.warn "[GW] final edit failed: #{e.class}: #{e.message}"
          message.channel.post(buffer.empty? ? "(empty)" : buffer).wait rescue nil
        end
      },
      on_error: ->(err) {
        begin
          # 元チャンネル経由でエラーメッセージを編集
          message.channel.edit_message(msg, "エラー: #{err}").wait
        rescue
          message.channel.post("エラー: #{err}").wait rescue nil
        end
      }
    )
  end

  CLIENT.once :standby do
    APP_LOGGER.info "[GW] discorb logged in as #{CLIENT.user}"
  end

  # 反応条件：DM か、Botがメンションされたメッセージのみ
  CLIENT.on :message do |message|
    begin
      next if message.author.bot?
      is_dm = message.channel.is_a?(Discorb::DMChannel)
      
      # ライブラリの自動解析に頼らず、メッセージ本文にBotへのメンションが含まれるかを手動で確認
      mentioned = !!(message.content =~ /<@!?#{CLIENT.user.id}>/)

      APP_LOGGER.info "[GW] message received: author=#{message.author.name}, dm=#{is_dm}, mentioned=#{mentioned}, content=#{message.content.inspect}"
      next unless is_dm || mentioned

      text = mentioned ? strip_bot_mention(CLIENT, message.content) : message.content
      text = "こんにちは" if text.strip.empty?

      stream_reply_via_backend_dsc(message, text, logger: APP_LOGGER)
    rescue => e
      APP_LOGGER.error "[GW] handler error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
      message.channel.post("ごめん、内部エラー: #{e.message}").wait rescue nil
    end
  end

  # Sinatra と同居するため別スレッドで Async ループを起動
  Thread.new do
    APP_LOGGER.info "[GW] starting discorb gateway..."
    CLIENT.run(DISCORD_TOKEN)
  end
else
  puts "[GW] DISCORD_TOKEN 未設定のため、discorb Gateway は起動しません"
end