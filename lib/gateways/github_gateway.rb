require 'openssl'
require 'octokit'
require 'json'
require_relative '../services/chat_orchestrator'

class GithubGateway
  def initialize(access_token:, webhook_secret:)
    @client = Octokit::Client.new(access_token: access_token)
    @webhook_secret = webhook_secret
    @bot_login = @client.user.login
  end

  def handle_webhook(request)
    # 1. 署名の検証
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE_256']
    return [401, 'Unauthorized'] unless their_signature_header

    request.body.rewind
    payload_body = request.body.read
    signature = 'sha256=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @webhook_secret, payload_body)

    unless Rack::Utils.secure_compare(signature, their_signature_header)
      puts "Signature mismatch!"
      return [401, 'Unauthorized']
    end

    # 2. Webhookペイロードの処理
    payload = JSON.parse(payload_body)
    event_type = request.env['HTTP_X_GITHUB_EVENT']

    extracted_data = case event_type
                     when 'issue_comment'
                       extract_issue_comment_data(payload)
                     when 'pull_request_review_comment'
                       extract_pr_review_comment_data(payload)
                     else
                       nil
                     end

    return [200, 'Event ignored: Not a comment event or invalid payload'] if extracted_data.nil?
    
    # 自分自身のコメントには反応しない
    return [200, 'Ignoring own comment'] if extracted_data[:commenter] == @bot_login

    # 3. ChatOrchestratorに応答を依頼
    ChatOrchestrator.handle_message(extracted_data[:body], extracted_data[:session_id]) do |response_text|
      post_comment(extracted_data[:repo], extracted_data[:number], response_text)
    end

    [200, 'OK']
  rescue JSON::ParserError => e
    puts "Failed to parse webhook payload: #{e.message}"
    [400, 'Bad Request']
  rescue => e
    puts "An error occurred: #{e.message}"
    puts e.backtrace
    [500, 'Internal Server Error']
  end

  private

  def extract_issue_comment_data(payload)
    return nil unless payload['action'] == 'created' && payload.key?('issue') && payload.key?('comment')

    repo = payload['repository']['full_name']
    number = payload['issue']['number']
    
    session_id_prefix = payload['issue'].key?('pull_request') ? "github-pr" : "github-issue"
    session_id = "#{session_id_prefix}-#{repo}-#{number}"

    {
      repo: repo,
      number: number,
      body: payload['comment']['body'],
      commenter: payload['comment']['user']['login'],
      session_id: session_id
    }
  end

  def extract_pr_review_comment_data(payload)
    return nil unless payload['action'] == 'created' && payload.key?('pull_request') && payload.key?('comment')

    repo = payload['repository']['full_name']
    number = payload['pull_request']['number']
    session_id = "github-pr-#{repo}-#{number}"

    {
      repo: repo,
      number: number,
      body: payload['comment']['body'],
      commenter: payload['comment']['user']['login'],
      session_id: session_id
    }
  end

  def post_comment(repository, issue_number, text)
    @client.add_comment(repository, issue_number, text)
    puts "Posted comment to #{repository}##{issue_number}: #{text}"
  rescue => e
    puts "Failed to post comment: #{e.message}"
  end
end
