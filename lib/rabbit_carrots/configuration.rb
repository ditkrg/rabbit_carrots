module RabbitCarrots
  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  class Configuration
    attr_accessor :rabbitmq_host,
                  :rabbitmq_port,
                  :rabbitmq_user,
                  :rabbitmq_password,
                  :rabbitmq_vhost,
                  :routing_key_mappings,
                  :rabbitmq_exchange_name,
                  # Must match the exchange on the broker, or topology recovery
                  # is rejected and every consumer is lost. Defaults to true.
                  :rabbitmq_exchange_durable,
                  :automatically_recover,
                  :network_recovery_interval,
                  :recovery_attempts,
                  # Unacked messages allowed per consumer. Defaults to 10.
                  :prefetch,
                  # Seconds between supervisor health checks. Defaults to 5.
                  :supervision_interval,
                  # Seconds to wait for every consumer to subscribe at boot.
                  # Defaults to 60.
                  :startup_grace,
                  # Seconds the service may go without consuming before the
                  # supervisor gives up. Must outlast Bunny's recovery.
                  # Defaults to 60.
                  :unhealthy_grace

    def orm
      @orm ||= :activerecord
    end

    attr_writer :orm
  end
end
