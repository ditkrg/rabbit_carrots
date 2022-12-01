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
        vhost: RabbitCarrots.configuration.rabbitmq_vhost
      )

      puts "Putting Config: #{RabbitCarrots.configuration}"
      @connection.start
    end
  
    def channel
      @channel ||= ConnectionPool.new do
        connection.create_channel
      end
    end
  end  
end
