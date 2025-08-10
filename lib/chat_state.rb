# lib/chat_state.rb
require 'thread'

class ChatState
  attr_reader :session_id

  def initialize(max_size: 50)
    @history = []
    @session_id = nil
    @mutex = Mutex.new
    @max_size = max_size
  end

  def add_message(message)
    @mutex.synchronize do
      @history << message
      @history.shift if @history.size > @max_size
    end
  end

  def history
    @mutex.synchronize { @history.dup }
  end

  def get_session_id
    @mutex.synchronize { @session_id }
  end

  def set_session_id(new_session_id)
    @mutex.synchronize { @session_id = new_session_id }
  end
end