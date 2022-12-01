# frozen_string_literal: true

require_relative "rabbit_carrots/version"
require 'rabbit_carrots/connection'
require 'rabbit_carrots/configuration'
require 'rabbit_carrots/railtie' if defined?(Rails)


module RabbitCarrots
  class Error < StandardError; end
  module EventHandlers
    module Errors
      class IrrelevantMessage < StandardError
      end
  
      class NackMessage < StandardError
      end
  
      class NackAndRequeueMessage < StandardError
      end
    end
  end
  
end
