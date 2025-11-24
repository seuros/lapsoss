# frozen_string_literal: true

require "concurrent"

module Lapsoss
  class Client
    def initialize(configuration)
      @configuration = configuration
      # Note: We're using Thread.new directly for async mode instead of a thread pool
      # The Concurrent::FixedThreadPool had issues in Rails development mode
    end

    def capture_exception(exception, level: :error, **context)
      return nil unless @configuration.enabled

      extra_context = context.delete(:context)
      with_scope(context) do |scope|
        event = Event.build(
          type: :exception,
          level: level,
          exception: exception,
          context: merge_context(scope_to_context(scope), extra_context),
          transaction: scope.transaction_name
        )
        capture_event(event)
      end
    end

    def capture_message(message, level: :info, **context)
      return nil unless @configuration.enabled

      extra_context = context.delete(:context)
      with_scope(context) do |scope|
        event = Event.build(
          type: :message,
          level: level,
          message: message,
          context: merge_context(scope_to_context(scope), extra_context),
          transaction: scope.transaction_name
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
      @configuration.logger.debug("[LAPSOSS] Flush called with timeout: #{timeout}")
      # Give threads a moment to complete
      sleep(0.5) if @configuration.async

      # Flush individual adapters if they support it
      Registry.instance.active.each do |adapter|
        adapter.flush(timeout: timeout) if adapter.respond_to?(:flush)
      end
    end

    def shutdown
      Registry.instance.shutdown
    end

    private

    def capture_event(event)
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

      if @configuration.async
        @configuration.logger.debug("[LAPSOSS ASYNC] About to process event asynchronously")

        # Use Thread.new for now - the executor pool seems to have issues in Rails dev mode
        thread = Thread.new do
          begin
            @configuration.logger.debug("[LAPSOSS ASYNC] Background thread started")
            Router.process_event(event)
            @configuration.logger.debug("[LAPSOSS ASYNC] Background thread completed")
          rescue => e
            @configuration.logger.error("[LAPSOSS ASYNC ERROR] Failed in background: #{e.message}")
            @configuration.logger.error(e.backtrace.join("\n")) if @configuration.debug
          end
        end

        thread
      else
        @configuration.logger.debug("[LAPSOSS SYNC] Processing event synchronously")
        Router.process_event(event)
        nil
      end
    rescue StandardError => e
      handle_capture_error(e)
    end

    def run_before_send(event)
      return event unless @configuration.before_send

      @configuration.before_send.call(event)
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
