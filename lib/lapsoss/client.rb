# frozen_string_literal: true

require "concurrent"

module Lapsoss
  class Client
    def initialize(configuration)
      @configuration = configuration
      @executor = Concurrent::FixedThreadPool.new(5) if @configuration.async
    end

    def capture_exception(exception, **context)
      return unless @configuration.enabled

      with_scope(context) do |scope|
        event = Event.build(
          type: :exception,
          level: :error,
          exception: exception,
          context: scope_to_context(scope)
        )
        capture_event(event)
      end
    end

    def capture_message(message, level: :info, **context)
      return unless @configuration.enabled

      with_scope(context) do |scope|
        event = Event.build(
          type: :message,
          level: level,
          message: message,
          context: scope_to_context(scope)
        )
        capture_event(event)
      end
    end

    def add_breadcrumb(message, type: :default, **metadata)
      current_scope.add_breadcrumb(message, type: type, **metadata)
    end

    def with_scope(context = {})
      original_scope = current_scope

      # Create a merged scope with the new context
      merged_scope = MergedScope.new([ context ], original_scope)
      Current.scope = merged_scope

      yield(merged_scope)
    ensure
      Current.scope = original_scope
    end

    def current_scope
      Current.scope ||= Scope.new
    end

    def flush(timeout: 2)
      Registry.instance.flush(timeout: timeout)
    end

    def shutdown
      @executor&.shutdown
      Registry.instance.shutdown
    end

    private

    def capture_event(event)
      # Apply pipeline processing if enabled
      if @configuration.enable_pipeline && @configuration.pipeline
        event = @configuration.pipeline.call(event)
        return unless event
      end

      event = run_before_send(event)
      return unless event

      if @configuration.async
        @executor.post { Router.process_event(event) }
      else
        Router.process_event(event)
      end
    rescue StandardError => e
      handle_capture_error(e)
    end

    def run_before_send(event)
      return event unless @configuration.before_send

      @configuration.before_send.call(event)
    end

    def scope_to_context(scope)
      {
        tags: scope.tags,
        user: scope.user,
        extra: scope.extra,
        breadcrumbs: scope.breadcrumbs
      }
    end

    def handle_capture_error(error)
      @configuration.logger.error("Failed to capture event: #{error.message}")
    end
  end
end
