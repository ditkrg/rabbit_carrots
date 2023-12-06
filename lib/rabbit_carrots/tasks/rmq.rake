require 'bunny'

namespace :rabbit_carrots do
  desc 'Listener for Queue'
  task eat: :environment do
    Rails.application.eager_load!

    # rubocop:disable Lint/ConstantDefinitionInBlock
    DatabaseAgonsticNotNullViolation = defined?(ActiveRecord) ? ActiveRecord::NotNullViolation : RabbitCarrots::EventHandlers::Errors::PlaceholderError
    DatabaseAgonsticConnectionNotEstablished = defined?(ActiveRecord) ? ActiveRecord::ConnectionNotEstablished : Mongo::Error::SocketError
    DatabaseAgnosticRecordInvalid = defined?(ActiveRecord) ? ActiveRecord::RecordInvalid : Mongoid::Errors::Validations
    # rubocop:enable Lint/ConstantDefinitionInBlock

    channels = RabbitCarrots.configuration.routing_key_mappings.map do |mapping|
      # This will be supplied in initializer. At that time, the Handler will not be available to be loaded and will throw Uninitialized Constant
      { **mapping, handler: mapping[:handler].constantize }
    end

    Rails.logger = Logger.new(Rails.env.production? ? '/proc/self/fd/1' : $stdout)

    # Run RMQ Subscriber for each channel
    channels.each do |channel|
      handler_class = channel[:handler]

      raise "#{handler_class.name} must respond to `handle!`" unless handler_class.respond_to?(:handle!)

      run_task(queue_name: channel[:queue], handler_class:, routing_keys: channel[:routing_keys], queue_arguments: channel[:arguments])
    end

    # Infinite loop to keep the process running
    loop do
      sleep 1
    end
  end
end

def run_task(queue_name:, handler_class:, routing_keys:, queue_arguments: {})
  RabbitCarrots::Connection.instance.channel.with do |channel|
    exchange = channel.topic(RabbitCarrots.configuration.event_bus_exchange_name, durable: true)

    Rails.logger.info "Listening on QUEUE: #{queue_name} for ROUTING KEYS: #{routing_keys}"
    queue = channel.queue(queue_name, durable: true, arguments: queue_arguments)

    routing_keys.map(&:strip).each { |k| queue.bind(exchange, routing_key: k) }

    queue.subscribe(block: false, manual_ack: true, prefetch: 10) do |delivery_info, properties, payload|
      Rails.logger.info "Received from queue: #{queue_name}, Routing Keys: #{routing_keys}"
      handler_class.handle!(channel, delivery_info, properties, payload)
      channel.ack(delivery_info.delivery_tag, false)
    rescue RabbitCarrots::EventHandlers::Errors::NackMessage, JSON::ParserError => _e
      Rails.logger.info "Nacked message: #{payload}"
      channel.nack(delivery_info.delivery_tag, false, false)
    rescue RabbitCarrots::EventHandlers::Errors::NackAndRequeueMessage => _e
      Rails.logger.info "Nacked and Requeued message: #{payload}"
      channel.nack(delivery_info.delivery_tag, false, true)
    rescue DatabaseAgonsticNotNullViolation, DatabaseAgnosticRecordInvalid => e
      # on null constraint violation, we want to ack the message
      Rails.logger.error "Null constraint or Invalid violation: #{payload}. Error: #{e.message}"
      channel.ack(delivery_info.delivery_tag, false)
    rescue DatabaseAgonsticConnectionNotEstablished => e
      # on connection not established, we want to requeue the message and sleep for 3 seconds
      Rails.logger.error "Error connection not established to the database: #{payload}. Error: #{e.message}"
      # delay for 3 seconds before requeuing
      sleep 3
      channel.nack(delivery_info.delivery_tag, false, true)
    rescue StandardError => e
      Rails.logger.error "Error handling message: #{payload}. Error: #{e.message}"
      # requeue the message then kill the container
      sleep 3
      channel.nack(delivery_info.delivery_tag, false, true)
      # kill the container with sigterm
      Process.kill('SIGTERM', Process.pid)
    end

    Rails.logger.info 'RUN TASK ENDED'
  end
end
