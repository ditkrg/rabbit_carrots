# frozen_string_literal: true

require_relative 'lib/rabbit_carrots/version'

Gem::Specification.new do |spec|
  spec.name = 'rabbit_carrots'
  spec.version = RabbitCarrots::VERSION
  spec.authors = ['Brusk Awat']
  spec.email = ['broosk.edogawa@gmail.com']

  spec.summary = 'A simple RabbitMQ consumer task'
  spec.description = 'A background task based on rake to consume RabbitMQ messages'
  spec.homepage = 'https://github.com/ditkrg'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ditkrg/rabbit_carrots'
  spec.metadata['changelog_uri'] = 'https://github.com/ditkrg/rabbit_carrots'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Uncomment to register a new dependency of your gem
  spec.add_dependency 'bunny', '>= 2.19.0'
  spec.add_dependency 'connection_pool', '~> 2.3.0'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
  spec.metadata['rubygems_mfa_required'] = 'true'
end
