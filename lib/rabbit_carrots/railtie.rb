# lib/railtie.rb
require 'rabbit_carrots'

module RabbitCarrots
  class Railtie < Rails::Railtie
    railtie_name :rabbit_carrots

    rake_tasks do
      path = File.expand_path(__dir__)
      Dir.glob("#{path}/tasks/**/*.rake").each { |f| load f }
    end
  end
end
