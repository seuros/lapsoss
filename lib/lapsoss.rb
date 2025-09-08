# frozen_string_literal: true

require "zeitwerk"
require "active_support/core_ext/module/delegation"

loader = Zeitwerk::Loader.for_gem
loader.do_not_eager_load("#{__dir__}/lapsoss/adapters")
loader.setup

require_relative "lapsoss/railtie" if defined?(Rails::Railtie)

module Lapsoss
  class Error < StandardError; end

  class DeliveryError < Error
    attr_reader :response, :cause

    def initialize(message, response: nil, cause: nil)
      super(message)
      @response = response
      @cause = cause
    end
  end

  class << self
    attr_reader :client

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      configuration.validate!
      configuration.apply!
      @client = Client.new(configuration)
    end

    def capture_exception(exception, **context)
      client.capture_exception(exception, **context)
    end

    def capture_message(message, level: :info, **context)
      client.capture_message(message, level: level, **context)
    end

    def add_breadcrumb(message, type: :default, **metadata)
      client.add_breadcrumb(message, type: type, **metadata)
    end

    def with_scope(context = {}, &)
      client.with_scope(context, &)
    end

    delegate :current_scope, to: :client

    def flush(timeout: 2)
      client.flush(timeout: timeout)
    end

    delegate :shutdown, to: :client
  end
end
