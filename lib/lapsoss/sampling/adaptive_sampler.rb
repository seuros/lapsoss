# frozen_string_literal: true

module Lapsoss
  module Sampling
    class AdaptiveSampler < Base
      def initialize(target_rate: 1.0, adjustment_period: 60)
        @target_rate = target_rate
        @adjustment_period = adjustment_period
        @current_rate = target_rate
        @events_count = 0
        @last_adjustment = Time.zone.now
        @mutex = Mutex.new
      end

      def sample?(_event, _hint = {})
        @mutex.synchronize do
          @events_count += 1

          # Adjust rate periodically
          now = Time.zone.now
          if now - @last_adjustment > @adjustment_period
            adjust_rate
            @last_adjustment = now
            @events_count = 0
          end
        end

        @current_rate > rand
      end

      attr_reader :current_rate

      private

      def adjust_rate
        # Simple adaptive logic - can be enhanced based on system metrics
        # For now, just ensure we don't drift too far from target
        if @events_count > 100 # High volume
          @current_rate = [ @current_rate * 0.9, @target_rate * 0.1 ].max
        elsif @events_count < 10 # Low volume
          @current_rate = [ @current_rate * 1.1, @target_rate ].min
        end
      end
    end
  end
end
