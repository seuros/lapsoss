# frozen_string_literal: true

require "zeitwerk"
require "json"
require "active_support"
require "active_support/concern"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/module/delegation"
require_relative "lapsoss/native"

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
      Thread.current[:lapsoss_configuration_candidate] || (@configuration ||= Configuration.new)
    end

    def configure
      candidate = configuration.dup
      previous_candidate = Thread.current[:lapsoss_configuration_candidate]
      Thread.current[:lapsoss_configuration_candidate] = candidate
      yield(candidate)
      candidate.validate!
      adapters = candidate.build_adapters
      specs = adapters.select { |adapter| adapter.enabled? || adapter.settings[:dsn].present? }
        .filter_map { |adapter| NativeAdapters.describe(adapter) }
      Native.validate(specs.to_json, NativeAdapters.transport(candidate).to_json)
      replacement = Client.new(candidate)
      if @client && !@client.flush(timeout: 2)
        raise Error, "Previous Lapsoss client did not drain; configuration was not replaced"
      end
      @client&.shutdown(timeout: 2)
      Registry.instance.replace!(adapters)
      @configuration = candidate
      @client = replacement
    ensure
      Thread.current[:lapsoss_configuration_candidate] = previous_candidate
    end

    def capture_exception(exception, **context)
      configuration.logger.debug "[LAPSOSS] capture_exception called for #{exception.class}"
      return unless client
      client.capture_exception(exception, **context)
    end

    def capture_message(message, level: :info, **context)
      client&.capture_message(message, level: level, **context)
    end

    # Rails.error-compatible methods for non-Rails environments

    # Handle errors and swallow them (like Rails.error.handle)
    def handle(error_class = StandardError, fallback: nil, **context)
      yield
    rescue error_class => e
      capture_exception(e, **context.merge(handled: true))
      fallback.respond_to?(:call) ? fallback.call : fallback
    end

    # Record errors and re-raise them (like Rails.error.record)
    def record(error_class = StandardError, **context)
      yield
    rescue error_class => e
      capture_exception(e, **context.merge(handled: false))
      raise
    end

    # Report an error manually (like Rails.error.report)
    def report(exception, handled: true, **context)
      capture_exception(exception, **context.merge(handled: handled))
    end

    # Suppress all event capture for the duration of the block (thread-local).
    # Breadcrumbs and scope still accumulate; only delivery is skipped.
    def silence
      previous = Current.silenced
      Current.silenced = true
      yield
    ensure
      Current.silenced = previous
    end

    def silenced?
      Current.silenced
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

    def call_error_handler(adapter:, event:, error:, handler: configuration.error_handler)
      return unless handler

      case handler.arity
      when 3
        handler.call(adapter, event, error)
      when 2
        handler.call(event, error)
      when 1, 0, -1
        handler.call(error)
      else
        handler.call(adapter, event, error)
      end
    rescue => handler_error
      configuration.logger&.error("[LAPSOSS] Error handler failed: #{handler_error.message}")
    end

    delegate :shutdown, to: :client
  end
end

at_exit do
  Lapsoss.client&.shutdown(timeout: 2)
rescue StandardError
  # Reporting must never replace an application's exit status.
  nil
end
