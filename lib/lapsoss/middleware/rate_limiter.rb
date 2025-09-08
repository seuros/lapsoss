# frozen_string_literal: true

module Lapsoss
  module Middleware
    class RateLimiter < Base
      def initialize(app, max_events: 100, time_window: 60)
        super(app)
        @max_events = max_events
        @time_window = time_window
        @events = []
        @mutex = Mutex.new
      end

      def call(event, hint = {})
        @mutex.synchronize do
          now = Time.zone.now
          # Remove old events outside time window
          @events.reject! { |timestamp| now - timestamp > @time_window }

          # Check if we're over the limit
          return nil if @events.length >= @max_events

          # Add current event
          @events << now
        end

        @app.call(event, hint)
      end
    end
  end
end
