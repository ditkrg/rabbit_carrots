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

      class PlaceholderError < Error; end
    end
  end
end
