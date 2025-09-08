# frozen_string_literal: true

module Lapsoss
  module Sampling
    class HealthBasedSampler < Base
      def initialize(health_check:, high_rate: 1.0, low_rate: 0.1)
        @health_check = health_check
        @high_rate = high_rate
        @low_rate = low_rate
      end

      def sample?(_event, _hint = {})
        healthy = @health_check.call
        rate = healthy ? @high_rate : @low_rate
        rate > rand
      end
    end
  end
end
