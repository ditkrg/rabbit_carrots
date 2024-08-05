# frozen_string_literal: true

require_relative 'rabbit_carrots/version'
require 'rabbit_carrots/errors'
require 'rabbit_carrots/connection'
require 'rabbit_carrots/configuration'
require 'rabbit_carrots/railtie' if defined?(Rails)
require 'rabbit_carrots/core'

module RabbitCarrots
end
