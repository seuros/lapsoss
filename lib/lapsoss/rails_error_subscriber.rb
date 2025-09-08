# frozen_string_literal: true

module Lapsoss
  class RailsErrorSubscriber
    def report(error, handled:, severity:, context:, source: nil)
      # Skip certain framework errors
      return if skip_error?(error, source)

      level = map_severity(severity)

      Lapsoss.capture_exception(
        error,
        level: level,
        tags: {
          handled: handled,
          source: source || "rails"
        },
        context: context
      )
    end

    private

    def skip_error?(error, source)
      # Skip Rails cache-related errors using Rails error reporter source
      # Avoid referencing backend-specific gems (e.g., Redis)
      return true if Lapsoss.configuration.skip_rails_cache_errors && source&.include?("cache")

      false
    end

    def map_severity(severity)
      case severity
      when :error then :error
      when :warning then :warning
      when :info then :info
      else :error
      end
    end
  end
end
