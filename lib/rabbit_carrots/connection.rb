require 'singleton'

module RabbitCarrots
  class Connection
    include ::Singleton
    attr_reader :connection
  
    def initialize
      @connection = Bunny.new(
        host: Configuration.rabbitmq_host,
        port: Configuration.rabbitmq_port,
        user: Configuration.rabbitmq_user,
        password: Configuration.rabbitmq_password,
        vhost: Configuration.rabbitmq_vhost
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
