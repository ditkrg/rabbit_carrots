module RabbitCarrots
  class Core
    attr_reader :logger

    @database_agnostic_not_null_violation = nil
    @database_agnostic_connection_not_established = nil
    @database_agnostic_record_invalid = nil

    class << self
      attr_accessor :database_agnostic_not_null_violation, :database_agnostic_connection_not_established, :database_agnostic_record_invalid
    end

    def initialize(logger: nil)
      @logger = create_logger_adapter(logger || Logger.new(Rails.env.production? ? '/proc/self/fd/1' : $stdout))
      @threads = []
      @running = true
      @shutdown_requested = false
    end

    def start(kill_to_restart_on_standard_error: false)
      self.class.database_agnostic_not_null_violation = RabbitCarrots.configuration.orm == :activerecord ? ActiveRecord::NotNullViolation : RabbitCarrots::EventHandlers::Errors::PlaceholderError
      self.class.database_agnostic_connection_not_established = RabbitCarrots.configuration.orm == :activerecord ? ActiveRecord::ConnectionNotEstablished : ::Mongo::Error::SocketError
      self.class.database_agnostic_record_invalid = RabbitCarrots.configuration.orm == :activerecord ? ActiveRecord::RecordInvalid : ::Mongoid::Errors::Validations

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
        logger.error 'Shutting down Rabbit Carrots service...'
      end
      @shutdown_requested = true
      @threads.each(&:kill)
      stop
    end

    def stop
      # Workaround to a known issue with Signal Traps and logs
      Thread.start do
        logger.error 'Stoppig the Rabbit Carrots service...'
      end
      @running = false
    end

    def run_task(queue_name:, handler_class:, routing_keys:, queue_arguments: {}, kill_to_restart_on_standard_error: false)
      RabbitCarrots::Connection.instance.channel.with do |channel|
        exchange = channel.topic(RabbitCarrots.configuration.rabbitmq_exchange_name, durable: true)

        logger.info "Listening on QUEUE: #{queue_name} for ROUTING KEYS: #{routing_keys}"
        queue = channel.queue(queue_name, durable: true, arguments: queue_arguments)

        routing_keys.map(&:strip).each { |k| queue.bind(exchange, routing_key: k) }

        queue.subscribe(block: false, manual_ack: true, prefetch: 10) do |delivery_info, properties, payload|
          break if @shutdown_requested

          logger.info "Received from queue: #{queue_name}, Routing Keys: #{routing_keys}"
          handler_class.handle!(channel, delivery_info, properties, payload)
          channel.ack(delivery_info.delivery_tag, false)
        rescue RabbitCarrots::EventHandlers::Errors::NackMessage, JSON::ParserError => _e
          logger.warn "Nacked message: #{payload}"
          channel.nack(delivery_info.delivery_tag, false, false)
        rescue RabbitCarrots::EventHandlers::Errors::NackAndRequeueMessage => _e
          logger.warn "Nacked and Requeued message: #{payload}"
          channel.nack(delivery_info.delivery_tag, false, true)
        rescue self.class.database_agnostic_not_null_violation, self.class.database_agnostic_record_invalid => e
          logger.warn "Null constraint or Invalid violation: #{payload}. Error: #{e.message}"
          channel.ack(delivery_info.delivery_tag, false)
        rescue self.class.database_agnostic_connection_not_established => e
          logger.warn "Error connection not established to the database: #{payload}. Error: #{e.message}"
          sleep 3
          channel.nack(delivery_info.delivery_tag, false, true)
        rescue StandardError => e
          logger.error "Error handling message: #{payload}. Error: #{e.message}"
          sleep 3
          channel.nack(delivery_info.delivery_tag, false, true)
          Process.kill('SIGTERM', Process.pid) if kill_to_restart_on_standard_error
        end
      end
    rescue StandardError => e
      logger.error "Bunny session error: #{e.message}"
      request_shutdown
    end

    private

    def create_logger_adapter(logger)
      return logger if logger.respond_to?(:info) && logger.respond_to?(:error) && logger.respond_to?(:warn)

      adapter = Object.new
      def adapter.info(msg)
        @logger.write("[INFO] #{msg}\n")
      end

      def adapter.error(msg)
        @logger.write("[ERROR] #{msg}\n")
      end

      def adapter.warn(msg)
        @logger.write("[WARN] #{msg}\n")
      end

      adapter.instance_variable_set(:@logger, logger)
      adapter
    end
  end
end
