# RabbitCarrots

RabbitCarrots is a simple background task based on rake to handle the consumption of RabbitMQ message in Rails applications. It is an opinionated library that solves the consumption of messages among  microservices, given the following conditions:

1. RabbitMQ is used as an event bus for communication.
2. Messages are routed using a single exchange, multiple routing keys.
3. One routing key or more can be bound to a single queue. 
4. The app is a built with Ruby on Rails.

### Considerations

The gem adds a rake task to the project using the Railtie framework of Rails. Therefore, the task should be run as a separate process that is independent from the application server.

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add rabbit_carrots

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install rabbit_carrots

## Usage

Add the following to ```config/initializers/rabbit_carrots.rb```:

```ruby
RabbitCarrots.configure do |c|
  c.rabbitmq_host = ENV.fetch('RABBITMQ__HOST', nil)
  c.rabbitmq_port = ENV.fetch('RABBITMQ__PORT', nil)
  c.rabbitmq_user = ENV.fetch('RABBITMQ__USER', nil)
  c.rabbitmq_password = ENV.fetch('RABBITMQ__PASSWORD', nil)
  c.rabbitmq_vhost = ENV.fetch('RABBITMQ__VHOST', nil)
  c.event_bus_exchange_name = ENV.fetch('EVENTBUS__EXCHANGE_NAME', nil)
  c.routing_key_mappings =  [
    { routing_keys: ['RK1', 'RK2'], queue: 'QUEUE_NAME', handler: 'CLASS HANDLER IN STRING' },
    { routing_keys: ['RK1', 'RK2'], queue: 'QUEUE_NAME', handler: 'CLASS HANDLER IN STRING' }
  ]
end

```



Then run ```bundle exec rake rmq:subscriber```.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ditkrg/rabbit_carrots. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/rabbit_carrots/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the RabbitCarrots project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/rabbit_carrots/blob/master/CODE_OF_CONDUCT.md).
