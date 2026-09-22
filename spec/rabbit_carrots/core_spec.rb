# frozen_string_literal: true

RSpec.describe RabbitCarrots::Core do
  subject(:core) { described_class.new(logger: TestLogger.new) }

  let(:logger) { core.logger }
  let(:exchange) { instance_double(Bunny::Exchange) }
  let(:consumer) { instance_double(Bunny::Consumer, consumer_tag: 'tag-1') }
  let(:queue) { instance_double(Bunny::Queue, bind: true, subscribe: consumer) }
  let(:channel) do
    instance_double(Bunny::Channel, topic: exchange, queue: queue, open?: true, consumers: { 'tag-1' => consumer })
  end
  let(:connection) { instance_double(RabbitCarrots::Connection, open?: true) }

  before do
    RabbitCarrots.configure do |c|
      c.rabbitmq_exchange_name = 'myaccount'
      c.routing_key_mappings = []
    end

    allow(connection).to receive(:create_channel).and_return(channel)
    allow(RabbitCarrots::Connection).to receive(:instance).and_return(connection)
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  def run_task(**overrides)
    core.run_task(
      queue_name: 'a.queue',
      handler_class: handler_class,
      routing_keys: ['a.routing.key'],
      **overrides
    )
  end

  let(:handler_class) do
    Class.new do
      def self.handle!(*); end
    end
  end

  describe 'exchange declaration' do
    # Regression: a passive declaration records `durable: false`, which Bunny
    # replays during recovery, and the broker then closes the channel.
    it 'declares the exchange as durable by default' do
      run_task

      expect(channel).to have_received(:topic).with('myaccount', durable: true)
    end

    it 'never declares the exchange passively' do
      run_task

      expect(channel).not_to have_received(:topic).with(anything, hash_including(passive: true))
      expect(channel).not_to have_received(:topic).with(anything, hash_including(durable: false))
    end

    it 'honours a non-durable exchange when configured' do
      RabbitCarrots.configuration.rabbitmq_exchange_durable = false

      run_task

      expect(channel).to have_received(:topic).with('myaccount', durable: false)
    end

    it 'explains the mismatch and marks itself unhealthy when the broker rejects the declaration' do
      allow(channel).to receive(:topic).and_raise(
        Bunny::PreconditionFailed.new("PRECONDITION_FAILED - inequivalent arg 'durable'", channel, false)
      )

      run_task

      expect(logger).to include('rabbitmq_exchange_durable')
      expect(core).not_to be_healthy
    end

    it 'uses the per-mapping exchange when one is given' do
      run_task(exchange_name: 'other-exchange')

      expect(channel).to have_received(:topic).with('other-exchange', durable: true)
    end
  end

  describe 'acking on a channel that has gone away' do
    let(:delivery_info) { instance_double(Bunny::DeliveryInfo, delivery_tag: 1) }

    it 'does not ack a closed channel' do
      allow(channel).to receive(:open?).and_return(false)
      allow(channel).to receive(:ack)

      expect(core.send(:acknowledge, channel, delivery_info)).to be(false)
      expect(channel).not_to have_received(:ack)
    end

    it 'does not nack a closed channel' do
      allow(channel).to receive(:open?).and_return(false)
      allow(channel).to receive(:nack)

      expect(core.send(:reject, channel, delivery_info, requeue: true)).to be(false)
      expect(channel).not_to have_received(:nack)
    end

    # The old code nacked from inside the rescue that handled the failed ack,
    # and that second raise killed the consumer.
    it 'swallows a raise from ack rather than letting it reach the work pool' do
      allow(channel).to receive(:ack).and_raise(Bunny::ChannelAlreadyClosed.new('closed', channel))

      expect { core.send(:acknowledge, channel, delivery_info) }.not_to raise_error
      expect(logger).to include('Failed to ack')
    end

    it 'swallows a raise from nack rather than letting it reach the work pool' do
      allow(channel).to receive(:nack).and_raise(Bunny::ChannelAlreadyClosed.new('closed', channel))

      expect { core.send(:reject, channel, delivery_info, requeue: false) }.not_to raise_error
      expect(logger).to include('Failed to nack')
    end
  end

  describe 'supervision' do
    before do
      core.instance_variable_set(:@expected_consumers, 1)
      core.instance_variable_set(:@startup_deadline, 0)
      run_task
    end

    it 'is healthy while the connection, channel and consumer are all up' do
      expect(core.send(:consumers_healthy?)).to be(true)
    end

    it 'is unhealthy when the channel was closed by a failed recovery' do
      allow(channel).to receive(:open?).and_return(false)

      expect(core.send(:consumers_healthy?)).to be(false)
      expect(logger).to include('Channel for queue a.queue is closed')
    end

    it 'is unhealthy when the consumer is no longer registered on its channel' do
      allow(channel).to receive(:consumers).and_return({})

      expect(core.send(:consumers_healthy?)).to be(false)
      expect(logger).to include('no longer registered')
    end

    it 'is unhealthy when the connection is gone' do
      allow(connection).to receive(:open?).and_return(false)

      expect(core.send(:consumers_healthy?)).to be(false)
    end

    it 'tolerates a consumer tag regenerated by recovery' do
      allow(consumer).to receive(:consumer_tag).and_return('tag-after-recovery')
      allow(channel).to receive(:consumers).and_return({ 'tag-1' => consumer })

      expect(core.send(:consumers_healthy?)).to be(true)
    end

    it 'is unhealthy when a consumer never subscribed and the grace period elapsed' do
      core.instance_variable_set(:@expected_consumers, 2)

      expect(core.send(:consumers_healthy?)).to be(false)
      expect(logger).to include('Only 1 of 2 consumers registered')
    end

    it 'is patient while consumers are still subscribing' do
      core.instance_variable_set(:@expected_consumers, 2)
      core.instance_variable_set(:@startup_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)

      expect(core.send(:consumers_healthy?)).to be(true)
    end
  end

  describe 'tolerating a reconnect in progress' do
    before do
      RabbitCarrots.configuration.supervision_interval = 0
      RabbitCarrots.configuration.unhealthy_grace = grace
      core.instance_variable_set(:@expected_consumers, 1)
      core.instance_variable_set(:@startup_deadline, 0)
      run_task
      allow(connection).to receive(:open?).and_return(false)
    end

    context 'when the outage is shorter than the grace period' do
      let(:grace) { 60 }

      it 'waits for recovery instead of shutting down' do
        supervisor = Thread.new { core.send(:supervise) }

        expect(wait_for { logger.include?('waiting for recovery') }).to be(true)

        allow(connection).to receive(:open?).and_return(true)

        expect(wait_for { logger.include?('recovered and is consuming again') }).to be(true)

        core.stop
        supervisor.join(2)

        expect(core).to be_healthy
      end
    end

    context 'when the outage outlasts the grace period' do
      let(:grace) { 0 }

      it 'gives up so the process can be restarted' do
        core.send(:supervise)

        expect(core).not_to be_healthy
        expect(logger).to include('has not been consuming')
      end
    end
  end

  describe 'prefetch' do
    it 'defaults to 10' do
      run_task

      expect(queue).to have_received(:subscribe).with(hash_including(prefetch: 10))
    end

    it 'is configurable' do
      RabbitCarrots.configuration.prefetch = 1

      run_task

      expect(queue).to have_received(:subscribe).with(hash_including(prefetch: 1))
    end
  end
end
