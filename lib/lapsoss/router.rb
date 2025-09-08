# frozen_string_literal: true

module Lapsoss
  class Router
    class << self
      # Processes an event by dispatching it to all active adapters.
      # The actual dispatch (sync/async) is handled by the Client.
      #
      # @param event [Lapsoss::Event] The event to process.
      def process_event(event)
        Registry.instance.active.each do |adapter|
          adapter.capture(event)
        rescue StandardError => e
          handle_adapter_error(adapter, event, e)
        end
      end

      private

      # Handle adapter errors gracefully
      def handle_adapter_error(adapter, event, error)
        return unless Lapsoss.configuration.logger

        Lapsoss.configuration.logger.error(
          "[Lapsoss] Adapter '#{adapter.name}' failed to capture event (type: #{event.type}): #{error.message}"
        )

        # Call error handler if configured
        handler = Lapsoss.configuration.error_handler
        handler&.call(adapter, event, error)
      end
    end
  end
end
