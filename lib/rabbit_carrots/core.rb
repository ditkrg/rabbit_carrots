module RabbitCarrots
  class Core
    attr_reader :logger

    DatabaseAgonsticNotNullViolation = defined?(ActiveRecord) ? ActiveRecord::NotNullViolation : RabbitCarrots::EventHandlers::Errors::PlaceholderError
    DatabaseAgonsticConnectionNotEstablished = defined?(ActiveRecord) ? ActiveRecord::ConnectionNotEstablished : Mongo::Error::SocketError
    DatabaseAgnosticRecordInvalid = defined?(ActiveRecord) ? ActiveRecord::RecordInvalid : Mongoid::Errors::Validations

    def initialize(logger: nil)
      @logger = logger || Logger.new(Rails.env.production? ? '/proc/self/fd/1' : $stdout)
      @threads = []
      @running = true
      @shutdown_requested = false
    end

    def start(kill_to_restart_on_standard_error: false)
      channels = RabbitCarrots.configuration.routing_key_mappings.map do |mapping|
        { **mapping, handler: mapping[:handler].constantize }
      end

      channels.each do |channel|
        handler_class = channel[:handler]
        raise "#{handler_class.name} must respond to `handle!`" unless handler_class.respond_to?(:handle!)

        @threads << Thread.new do
          run_task(
            queue_name: channel[:queue],
            handler_class:,
            routing_keys: channel[:routing_keys],
            queue_arguments: channel[:arguments],
            kill_to_restart_on_standard_error:
          )
        end
      end

      Signal.trap('INT') { request_shutdown }
      Signal.trap('TERM') { request_shutdown }

      while @running
        if @shutdown_requested
          request_shutdown
          sleep 1
          break
        end
        sleep 1
      end

      @threads.each(&:join)
    rescue StandardError => e
      logger.error "Error starting Rabbit Carrots: #{e.message}"
    end

    def request_shutdown
      # Workaround to a known issue with Signal Traps and logs
      Thread.start do
        logger.log 'Shutting down Rabbit Carrots service...'
      end
      @shutdown_requested = true
      @threads.each(&:kill)
      stop
    end

    def stop
      # Workaround to a known issue with Signal Traps and logs
      Thread.start do
        logger.log 'Stoppig the Rabbit Carrots service...'
      end
      @running = false
    end

    def run_task(queue_name:, handler_class:, routing_keys:, queue_arguments: {}, kill_to_restart_on_standard_error: false)
      RabbitCarrots::Connection.instance.channel.with do |channel|
        exchange = channel.topic(RabbitCarrots.configuration.rabbitmq_exchange_name, durable: true)

        logger.log "Listening on QUEUE: #{queue_name} for ROUTING KEYS: #{routing_keys}"
        queue = channel.queue(queue_name, durable: true, arguments: queue_arguments)

        routing_keys.map(&:strip).each { |k| queue.bind(exchange, routing_key: k) }

        queue.subscribe(block: false, manual_ack: true, prefetch: 10) do |delivery_info, properties, payload|
          break if @shutdown_requested

          logger.log "Received from queue: #{queue_name}, Routing Keys: #{routing_keys}"
          handler_class.handle!(channel, delivery_info, properties, payload)
          channel.ack(delivery_info.delivery_tag, false)
        rescue RabbitCarrots::EventHandlers::Errors::NackMessage, JSON::ParserError => _e
          logger.log "Nacked message: #{payload}"
          channel.nack(delivery_info.delivery_tag, false, false)
        rescue RabbitCarrots::EventHandlers::Errors::NackAndRequeueMessage => _e
          logger.log "Nacked and Requeued message: #{payload}"
          channel.nack(delivery_info.delivery_tag, false, true)
        rescue DatabaseAgonsticNotNullViolation, DatabaseAgnosticRecordInvalid => e
          logger.log "Null constraint or Invalid violation: #{payload}. Error: #{e.message}"
          channel.ack(delivery_info.delivery_tag, false)
        rescue DatabaseAgonsticConnectionNotEstablished => e
          logger.log "Error connection not established to the database: #{payload}. Error: #{e.message}"
          sleep 3
          channel.nack(delivery_info.delivery_tag, false, true)
        rescue StandardError => e
          logger.log "Error handling message: #{payload}. Error: #{e.message}"
          sleep 3
          channel.nack(delivery_info.delivery_tag, false, true)
          Process.kill('SIGTERM', Process.pid) if kill_to_restart_on_standard_error
        end

        logger.log "Ending task for queue: #{queue_name}"
      end
    rescue StandardError => e
      logger.error "Bunny session error: #{e.message}"
      request_shutdown
    end
  end
end
