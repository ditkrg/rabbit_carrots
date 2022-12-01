require 'singleton'

module RabbitCarrots
  class Connection
    include ::Singleton
    attr_reader :connection
  
    def initialize
      @connection = Bunny.new(
        host: self.configuration.rabbitmq_host,
        port: self.configuration.rabbitmq_port,
        user: self.configuration.rabbitmq_user,
        password: self.configuration.rabbitmq_password,
        vhost: self.configuration.rabbitmq_vhost
      )

      puts "Putting Config: #{self.configuration}"
      @connection.start
    end
  
    def channel
      @channel ||= ConnectionPool.new do
        connection.create_channel
      end
    end
  end  
end
