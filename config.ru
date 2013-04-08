# encoding: UTF-8
require './bangpharma.rb'

log = File.new("logs/sinatra.log", "a")
STDOUT.reopen(log)
STDERR.reopen(log)

run Sinatra::Application
