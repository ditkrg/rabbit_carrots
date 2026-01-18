require 'singleton'

module RabbitCarrots
  class Connection
    include ::Singleton

    attr_reader :connection

    def initialize
      @connection = Bunny.new(
        host: RabbitCarrots.configuration.rabbitmq_host,
        port: RabbitCarrots.configuration.rabbitmq_port,
        user: RabbitCarrots.configuration.rabbitmq_user,
        password: RabbitCarrots.configuration.rabbitmq_password,
        vhost: RabbitCarrots.configuration.rabbitmq_vhost,
        automatically_recover: RabbitCarrots.configuration.automatically_recover || true,
        network_recovery_interval: RabbitCarrots.configuration.network_recovery_interval || 5,
        recovery_attempts: RabbitCarrots.configuration.recovery_attempts || 5,
        recovery_attempts_exhausted: -> { Process.kill('TERM', Process.pid) }
      )

      @connection.start
    end

    def channel
      @channel ||= ConnectionPool.new do
        connection.create_channel
      end
    end
  end
end
