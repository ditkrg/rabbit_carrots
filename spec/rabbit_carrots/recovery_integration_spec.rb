# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'

class RecordingHandler
  class << self
    attr_accessor :payloads

    def handle!(_channel, _delivery_info, _properties, payload)
      (self.payloads ||= []) << payload
    end

    def reset!
      self.payloads = []
    end
  end
end

# Reproduces the production outage: a broker-initiated connection close triggers
# topology recovery, which replays the exchange declaration. A declaration that
# does not match the broker closes the channel and kills every consumer on it.
RSpec.describe 'automatic recovery', :integration do
  let(:exchange_name) { "rc-spec-#{SecureRandom.hex(4)}" }
  let(:queue_name) { "rc-spec-queue-#{SecureRandom.hex(4)}" }
  let(:routing_key) { 'rc-spec.things.updated' }
  let(:logger) { TestLogger.new }
  let(:core) { RabbitCarrots::Core.new(logger: logger) }

  let(:connection_options) do
    {
      host: ENV.fetch('RABBITMQ__HOST', 'localhost'),
      port: ENV.fetch('RABBITMQ__PORT', 5672).to_i,
      user: ENV.fetch('RABBITMQ__USERNAME', 'guest'),
      password: ENV.fetch('RABBITMQ__PASSWORD', 'guest'),
      vhost: ENV.fetch('RABBITMQ__VHOST', '/')
    }
  end

  # Durable, exactly as on staging.
  let!(:publisher) do
    conn = Bunny.new(**connection_options)
    conn.start
    conn
  rescue Bunny::TCPConnectionFailedForAllHosts
    raise "No broker on #{connection_options[:host]}:#{connection_options[:port]}."
  end
  let!(:publisher_exchange) { publisher.create_channel.topic(exchange_name, durable: true) }

  before do
    RecordingHandler.reset!
    reset_connection_singleton!

    RabbitCarrots.configure do |c|
      c.rabbitmq_host = connection_options[:host]
      c.rabbitmq_port = connection_options[:port]
      c.rabbitmq_user = connection_options[:user]
      c.rabbitmq_password = connection_options[:password]
      c.rabbitmq_vhost = connection_options[:vhost]
      c.rabbitmq_exchange_name = exchange_name
      c.network_recovery_interval = 1
      c.supervision_interval = 1
      c.startup_grace = 30
      c.unhealthy_grace = 60
      c.routing_key_mappings = [
        { routing_keys: [routing_key], queue: queue_name, handler: 'RecordingHandler' }
      ]
    end
  end

  after do
    core.request_shutdown
    @core_thread&.join(5)

    channel = publisher.create_channel
    channel.queue_delete(queue_name)
    channel.exchange_delete(exchange_name)
    publisher.close
    reset_connection_singleton!
  end

  def reset_connection_singleton!
    RabbitCarrots::Connection.instance_variable_set(:@singleton__instance__, nil)
  end

  def start_core!
    @healthy = nil
    @core_thread = Thread.new { @healthy = core.start }

    # A message published before the queue is bound is discarded by the broker.
    registered = wait_until { core.instance_variable_get(:@consumers).size == 1 }
    raise "consumer never subscribed: #{logger.messages.inspect}" unless registered
  end

  def publish(body)
    publisher_exchange.publish(body, routing_key: routing_key)
  end

  def wait_until(timeout: 45)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.1 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  # Bunny's reader loop sees the socket go away and starts the same recovery
  # path a broker-side connection.close triggers in production.
  def sever_connection!
    RabbitCarrots::Connection.instance.connection.instance_variable_get(:@transport).close
  end

  it 'keeps consuming after the connection is severed and recovered' do
    start_core!

    publish('before')
    expect(wait_until { RecordingHandler.payloads.include?('before') }).to be(true)

    sever_connection!

    publish('after')

    expect(wait_until { RecordingHandler.payloads.include?('after') }).to be(true)
    expect(core.send(:consumers_healthy?)).to be(true)
    expect(logger).not_to include('PRECONDITION_FAILED')
  end

  context 'when the declared durability does not match the broker' do
    # The old behaviour: a passive declaration recorded `durable: false`
    # against a durable exchange.
    before { RabbitCarrots.configuration.rabbitmq_exchange_durable = false }

    it 'refuses to start rather than consuming from a doomed channel' do
      @core_thread = Thread.new { @healthy = core.start }

      expect(wait_until { @healthy == false }).to be(true)
      expect(logger).to include('rabbitmq_exchange_durable')
    end
  end

  context 'when a channel is closed underneath a healthy-looking process' do
    before { RabbitCarrots.configuration.unhealthy_grace = 5 }

    it 'detects it and reports itself unhealthy instead of idling forever' do
      start_core!

      entry = core.instance_variable_get(:@consumers).first
      entry[:channel].close

      expect(wait_until { @healthy == false }).to be(true)
      expect(logger).to include("Channel for queue #{queue_name} is closed")
      expect(logger).to include('has not been consuming')
    end
  end
end
