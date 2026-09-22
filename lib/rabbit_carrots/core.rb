module RabbitCarrots
  class Core # rubocop:disable Metrics/ClassLength
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
      @consumers = []
      @consumers_mutex = Mutex.new
      @running = true
      @shutdown_requested = false
      @healthy = true
    end

    # Returns true when the service shut down because it was asked to, false
    # when it shut down because it could no longer consume.
    def start(kill_to_restart_on_standard_error: false)
      activerecord = RabbitCarrots.configuration.orm == :activerecord

      self.class.database_agnostic_not_null_violation = activerecord ? error_class('ActiveRecord::NotNullViolation') : RabbitCarrots::EventHandlers::Errors::PlaceholderError
      self.class.database_agnostic_connection_not_established = error_class(activerecord ? 'ActiveRecord::ConnectionNotEstablished' : 'Mongo::Error::SocketError')
      self.class.database_agnostic_record_invalid = error_class(activerecord ? 'ActiveRecord::RecordInvalid' : 'Mongoid::Errors::Validations')

      channels = RabbitCarrots.configuration.routing_key_mappings.map do |mapping|
        { **mapping, handler: mapping[:handler].constantize }
      end

      @expected_consumers = channels.size
      @startup_deadline = monotonic_now + startup_grace

      channels.each do |channel|
        handler_class = channel[:handler]
        raise "#{handler_class.name} must respond to `handle!`" unless handler_class.respond_to?(:handle!)

        @threads << Thread.new do
          run_task(
            queue_name: channel[:queue],
            handler_class:,
            routing_keys: channel[:routing_keys],
            queue_arguments: channel[:arguments],
            exchange_name: channel[:exchange_name],
            kill_to_restart_on_standard_error:
          )
        end
      end

      Signal.trap('INT') { request_shutdown }
      Signal.trap('TERM') { request_shutdown }

      supervise

      @threads.each(&:join)

      @healthy
    rescue StandardError => e
      logger.error "Error starting Rabbit Carrots: #{e.message}"
      false
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

    def healthy?
      @healthy
    end

    def run_task(queue_name:, handler_class:, routing_keys:, queue_arguments: {}, exchange_name: nil, kill_to_restart_on_standard_error: false)
      channel = RabbitCarrots::Connection.instance.create_channel
      exchange_name ||= RabbitCarrots.configuration.rabbitmq_exchange_name
      exchange = declare_exchange(channel, exchange_name)

      logger.info "Listening on QUEUE: #{queue_name} for ROUTING KEYS: #{routing_keys}"
      queue = channel.queue(queue_name, durable: true, arguments: queue_arguments)

      routing_keys.map(&:strip).each { |k| queue.bind(exchange, routing_key: k) }

      consumer = queue.subscribe(block: false, manual_ack: true, prefetch:) do |delivery_info, properties, payload|
        next if @shutdown_requested

        begin
          logger.info "Received from queue: #{queue_name}, Routing Keys: #{routing_keys}"
          handler_class.handle!(channel, delivery_info, properties, payload)
          acknowledge(channel, delivery_info)
        rescue RabbitCarrots::EventHandlers::Errors::NackMessage, JSON::ParserError => _e
          payload = encode_payload(payload)
          logger.warn "Nacked message: #{payload}"
          reject(channel, delivery_info, requeue: false)
        rescue RabbitCarrots::EventHandlers::Errors::NackAndRequeueMessage => _e
          payload = encode_payload(payload)
          logger.warn "Nacked and Requeued message: #{payload}"
          reject(channel, delivery_info, requeue: true)
        rescue self.class.database_agnostic_not_null_violation, self.class.database_agnostic_record_invalid => e
          payload = encode_payload(payload)
          logger.warn "Null constraint or Invalid violation: #{payload}. Error: #{e.message}"
          acknowledge(channel, delivery_info)
        rescue self.class.database_agnostic_connection_not_established => e
          payload = encode_payload(payload)
          logger.warn "Error connection not established to the database: #{payload}. Error: #{e.message}"
          sleep 3
          reject(channel, delivery_info, requeue: true)
        rescue StandardError => e
          payload = encode_payload(payload)
          logger.error "Error handling message: #{payload}. Error: #{e.message}"
          sleep 3
          reject(channel, delivery_info, requeue: true)
          Process.kill('SIGTERM', Process.pid) if kill_to_restart_on_standard_error
        end
      end

      register_consumer(queue_name:, channel:, consumer:)
    rescue StandardError => e
      logger.error "Bunny session error: #{e.message}"
      @healthy = false
      request_shutdown
    end

    private

    # Falls back to a class that is never raised when the ORM is not loaded.
    def error_class(name)
      Object.const_get(name)
    rescue NameError
      RabbitCarrots::EventHandlers::Errors::PlaceholderError
    end

    # Don't declare passively; Bunny topology recovery replays options, causing durable/exchange mismatch errors.
    def declare_exchange(channel, exchange_name)
      channel.topic(exchange_name, durable: exchange_durable?)
    rescue Bunny::PreconditionFailed => e
      logger.error(
        "Exchange '#{exchange_name}' exists on the broker with a different durability than the one " \
        "declared here (durable: #{exchange_durable?}). Set `config.rabbitmq_exchange_durable` to " \
        "match the exchange. Error: #{e.message}"
      )
      raise
    end

    def exchange_durable?
      durable = RabbitCarrots.configuration.rabbitmq_exchange_durable
      durable.nil? ? true : durable # rubocop:disable Style/RedundantCondition
    end

    def prefetch
      RabbitCarrots.configuration.prefetch || 10
    end

    def supervision_interval
      RabbitCarrots.configuration.supervision_interval || 5
    end

    def startup_grace
      RabbitCarrots.configuration.startup_grace || 60
    end

    def unhealthy_grace
      RabbitCarrots.configuration.unhealthy_grace || 60
    end

    def register_consumer(queue_name:, channel:, consumer:)
      @consumers_mutex.synchronize do
        @consumers << { queue_name:, channel:, consumer: }
      end
    end

    # `subscribe` is non-blocking, so the consumer threads finish at boot and
    # every delivery happens on Bunny's threads, which this class does not own.
    # Without this loop, a channel closed by a failed recovery leaves the
    # process alive and idle forever.
    def supervise
      while @running
        if @shutdown_requested
          request_shutdown
          sleep 1
          break
        end

        if consumers_healthy?
          logger.info 'Rabbit Carrots recovered and is consuming again' if @degraded_since
          @degraded_since = nil
        else
          @degraded_since ||= monotonic_now
          degraded_for = monotonic_now - @degraded_since

          if degraded_for >= unhealthy_grace
            @healthy = false
            logger.error "Rabbit Carrots has not been consuming for #{degraded_for.round}s; shutting down so the process can be restarted"
            request_shutdown
            break
          end

          # A reconnect in progress is indistinguishable from a dead consumer.
          logger.warn "Rabbit Carrots is not consuming (#{degraded_for.round}s); waiting for recovery"
        end

        sleep supervision_interval
      end
    end

    def consumers_healthy?
      return false unless connection_open?

      registered = @consumers_mutex.synchronize { @consumers.dup }

      if registered.size < @expected_consumers.to_i
        return true if monotonic_now < @startup_deadline

        logger.warn "Only #{registered.size} of #{@expected_consumers} consumers registered within #{startup_grace}s"
        return false
      end

      registered.all? { |entry| consumer_alive?(entry) }
    end

    def consumer_alive?(entry)
      channel = entry[:channel]
      consumer = entry[:consumer]

      unless channel.open?
        logger.warn "Channel for queue #{entry[:queue_name]} is closed"
        return false
      end

      # Bunny can regenerate the tag when it recovers a consumer.
      return true if channel.consumers.key?(consumer.consumer_tag) || channel.consumers.value?(consumer)

      logger.warn "Consumer for queue #{entry[:queue_name]} is no longer registered on its channel"
      false
    rescue StandardError => e
      logger.warn "Could not determine consumer health for queue #{entry[:queue_name]}: #{e.message}"
      false
    end

    def connection_open?
      return true if RabbitCarrots::Connection.instance.open?

      logger.warn 'RabbitMQ connection is closed'
      false
    rescue StandardError => e
      logger.warn "Could not determine RabbitMQ connection health: #{e.message}"
      false
    end

    # Acking a closed channel raises, and so does the nack in the rescue that
    # follows; that second raise escapes into Bunny's work pool and takes the
    # consumer with it. The broker redelivers whatever was left unacked.
    def acknowledge(channel, delivery_info)
      return false unless channel.open?

      channel.ack(delivery_info.delivery_tag, false)
      true
    rescue StandardError => e
      logger.error "Failed to ack message on a closed or closing channel: #{e.message}"
      false
    end

    def reject(channel, delivery_info, requeue:)
      return false unless channel.open?

      channel.nack(delivery_info.delivery_tag, false, requeue)
      true
    rescue StandardError => e
      logger.error "Failed to nack message on a closed or closing channel: #{e.message}"
      false
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

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

    def encode_payload(payload)
      payload.encode(
        'UTF-8',
        invalid: :replace,
        undef: :replace,
        replace: ''
      )
    end
  end
end
