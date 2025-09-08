# frozen_string_literal: true

module Lapsoss
  module Sampling
    # Factory for creating common sampling configurations
    class SamplingFactory
      def self.create_production_sampling
        CompositeSampler.new(
          samplers: [
            # Rate limit to prevent overwhelming
            RateLimiter.new(max_events_per_second: 50),

            # Different rates for different exception types
            ExceptionTypeSampler.new(rates: {
                                       # Critical errors - always sample
                                       SecurityError => 1.0,
                                       SystemStackError => 1.0,
                                       NoMemoryError => 1.0,

                                       # Common errors - sample less
                                       ArgumentError => 0.1,
                                       TypeError => 0.1,

                                       # Network errors - medium sampling
                                       /timeout/i => 0.3,
                                       /connection/i => 0.3,

                                       # Default for unknown errors
                                       default: 0.5
                                     }),

            # Lower sampling during business hours
            TimeBasedSampler.new(schedule: {
                                   business_hours: 0.3,
                                   weekends: 0.8,
                                   default: 0.5
                                 })
          ],
          strategy: :all
        )
      end

      def self.create_development_sampling
        UniformSampler.new(1.0) # Sample everything in development
      end

      def self.create_user_focused_sampling
        CompositeSampler.new(
          samplers: [
            # Higher sampling for internal users
            UserBasedSampler.new(rates: {
                                   internal: 1.0,
                                   premium: 0.8,
                                   beta: 0.9,
                                   default: 0.1
                                 }),

            # Consistent sampling based on user ID
            ConsistentHashSampler.new(
              rate: 0.1,
              key_extractor: ->(event, _hint) { event.context.dig(:user, :id) }
            )
          ],
          strategy: :any
        )
      end
    end
  end
end
