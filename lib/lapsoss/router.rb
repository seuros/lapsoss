# frozen_string_literal: true

module Lapsoss
  class Router
    class << self
      # Compatibility entry point. Native dispatch and Ruby plugins are managed
      # by the client's single processing/admission path.
      #
      # @param event [Lapsoss::Event] The event to process.
      def process_event(event)
        Lapsoss.client&.capture(event)
      end
    end
  end
end
