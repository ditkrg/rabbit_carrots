# frozen_string_literal: true

require 'rabbit_carrots'
require 'json'
require 'logger'
require 'securerandom'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.filter_run_excluding(:integration) unless ENV['RABBITMQ__HOST']

  config.after do
    RabbitCarrots.configuration = nil
  end
end

class TestLogger
  attr_reader :messages

  def initialize
    @messages = []
  end

  def info(msg) = @messages << [:info, msg.to_s]
  def warn(msg) = @messages << [:warn, msg.to_s]
  def error(msg) = @messages << [:error, msg.to_s]

  def include?(text)
    @messages.any? { |(_level, msg)| msg.include?(text) }
  end
end
