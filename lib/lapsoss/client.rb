# frozen_string_literal: true

require "concurrent"

module Lapsoss
  class Client
    def initialize(configuration)
      @configuration = configuration
      @delivery = configuration.daemon_socket ? DaemonDelivery.new(configuration) : Delivery.new(configuration)
    end

    def capture_exception(exception, level: :error, **context)
      capture_in_scope(:exception, level, context, exception: exception)
    end

    def capture_message(message, level: :info, **context)
      capture_in_scope(:message, level, context, message: message)
    end

    def add_breadcrumb(message, type: :default, **metadata)
      current_scope.add_breadcrumb(message, type: type, **metadata)
    end

    # Also used by Router's compatibility entry point; there is only one
    # processing/admission path, regardless of how an event was captured.
    def capture(event)
      return nil unless @configuration.enabled

      capture_event(event)
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
      @delivery.flush(timeout: timeout)
    end

    def shutdown(timeout: 2)
      @delivery.shutdown(timeout: timeout)
    end

    def statistics
      @delivery.statistics
    end

    private

    def capture_in_scope(type, level, context, **attributes)
      return nil unless @configuration.enabled

      extra_context = context.delete(:context)
      with_scope(context) do |scope|
        event = Event.build(
          type: type, level: level, **attributes,
          context: merge_context(scope_to_context(scope), extra_context),
          transaction: scope.transaction_name
        )
        capture_event(event)
      end
    end

    def capture_event(event)
      if Current.silenced
        @configuration.logger.debug("[LAPSOSS] Event dropped: capture silenced via Lapsoss.silence")
        return nil
      end

      @configuration.logger.debug("[LAPSOSS] capture_event called, async: #{@configuration.async}, executor: #{@executor.inspect}")

      # Apply pipeline processing if enabled
      if @configuration.enable_pipeline && @configuration.pipeline
        event = @configuration.pipeline.call(event)
        return nil unless event
      end

      if (filter = @configuration.exclusion_filter) && filter.should_exclude?(event)
        @configuration.logger.debug("[LAPSOSS] Event excluded by configured exclusion_filter")
        return nil
      end

      event = run_before_send(event)
      return nil unless event

      return nil unless sampled?(event)

      event = EventSnapshot.copy(event)
      @delivery.submit(event.scrubbed(configuration: @configuration))
    rescue Delivery::ForkError
      raise
    rescue StandardError => e
      handle_capture_error(e)
    end

    def run_before_send(event)
      return event unless @configuration.before_send

      @configuration.before_send.call(event)
    end

    def sampled?(event)
      strategy = @configuration.create_sampling_strategy
      strategy.respond_to?(:sample?) ? strategy.sample?(event) : strategy.call(event)
    end

    def scope_to_context(scope)
      defaults = @configuration.default_context
      {
        tags: (defaults[:tags] || {}).merge(scope.tags),
        user: (defaults[:user] || {}).merge(scope.user),
        extra: (defaults[:extra] || {}).merge(scope.extra),
        breadcrumbs: scope.breadcrumbs
      }.tap do |ctx|
        ctx[:environment] ||= @configuration.environment if @configuration.environment
      end
    end

    def merge_context(scope_context, extra_context)
      return scope_context unless extra_context

      merged = scope_context.dup
      merged[:context] = (scope_context[:context] || {}).merge(extra_context)
      merged
    end

    def handle_capture_error(error)
      @configuration.logger.error("Failed to capture event: #{error.message}")
    end
  end
end
