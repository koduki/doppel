require 'sinatra'
require 'sinatra/json'
require 'sinatra/reloader' if development?

set :port, 4568

get '/' do
  erb :index
end
