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
                  :automatically_recover,
                  :network_recovery_interval,
                  :recovery_attempts
  end
end
