# lib/chat_state.rb
require 'thread'

class ChatState
  def initialize(max_size: 50)
    @history = []
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
end
