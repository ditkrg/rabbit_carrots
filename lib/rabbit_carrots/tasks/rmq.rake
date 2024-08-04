namespace :rabbit_carrots do
  desc 'Rake task for standalone RabbitCarrots mode'
  task eat: :environment do
    Rails.application.eager_load!

    logger = Logger.new(Rails.env.production? ? '/proc/self/fd/1' : $stdout)
    logger.level = Logger::INFO

    core_service = RabbitCarrots::Core.new(logger:)

    core_service.start(kill_to_restart_on_standard_error: true)
  end
end
