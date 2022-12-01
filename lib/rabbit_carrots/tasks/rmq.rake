require 'bunny'

namespace :rmq do
  desc 'Listener for Queue'
  task subscriber: :environment do
    Rails.application.eager_load!

    channels = RabbitCarrots::Configuration.routing_key_mappings.map do |mapping|
      # This will be supplied in initializer. At that time, the Handler will not be available to be loaded and will throw Uninitialized Constant
      { **mapping, handler_class: mapping[:handler_class].constantize }
    end

    Rails.logger = Logger.new($stdout)

    # Run RMQ Subscriber for each channel
    channels.each do |channel|
      handler_class = channel[:handler]

      raise "#{handler_class.name} must respond to `handle!`" unless handler_class.respond_to?(:handle!)

      run_task(queue_name: channel[:queue], handler_class:, routing_keys: channel[:routing_keys])
    end

    # Infinite loop to keep the process running
    loop do
      sleep 1
    end
  end
end

def run_task(queue_name:, handler_class:, routing_keys:)
  RabbitConnection.instance.channel.with do |channel|
    exchange = channel.topic(RabbitCarrots::Configuration.event_bus_exchange_name, durable: true)

    Rails.logger.info "Listening on QUEUE: #{queue_name} for ROUTING KEYS: #{routing_keys}"
    queue = channel.queue(queue_name, durable: true)

    routing_keys.map(&:strip).each { |k| queue.bind(exchange, routing_key: k) }

    queue.subscribe(block: false, manual_ack: true, prefetch: 10) do |delivery_info, properties, payload|
      Rails.logger.info "Received from queue: #{queue_name}, Routing Keys: #{routing_keys}"
      handler_class.handle!(channel, delivery_info, properties, payload)
      channel.ack(delivery_info.delivery_tag, false)
    rescue EventHandlers::Errors::NackMessage, JSON::ParserError => _e
      Rails.logger.info "Nacked message: #{payload}"
      channel.nack(delivery_info.delivery_tag, false, false)
    rescue EventHandlers::Errors::NackAndRequeueMessage => _e
      Rails.logger.info "Nacked and Requeued message: #{payload}"
      channel.nack(delivery_info.delivery_tag, false, true)
    rescue StandardError => e
      Rails.logger.error "Error handling message: #{payload}. Error: #{e.message}"
      channel.nack(delivery_info.delivery_tag, false, true)
    end

    Rails.logger.info 'RUN TASK ENDED'
  end
end
