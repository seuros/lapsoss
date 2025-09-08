# frozen_string_literal: true

module Lapsoss
  module Sampling
    class RateLimiter < Base
      def initialize(max_events_per_second: 10)
        @max_events_per_second = max_events_per_second
        @tokens = max_events_per_second
        @last_refill = Time.zone.now
        @mutex = Mutex.new
      end

      def sample?(_event, _hint = {})
        @mutex.synchronize do
          now = Time.zone.now
          time_passed = now - @last_refill

          # Refill tokens based on time passed
          @tokens = [ @tokens + (time_passed * @max_events_per_second), @max_events_per_second ].min
          @last_refill = now

          if @tokens >= 1
            @tokens -= 1
            true
          else
            false
          end
        end
      end
    end
  end
end
