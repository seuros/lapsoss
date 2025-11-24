# frozen_string_literal: true

module Lapsoss
  module Middleware
    # Drops events based on sampling strategy or rate.
    class SampleFilter < Base
      def initialize(app, sample_rate: 1.0, sample_callback: nil, sampler: nil)
        super(app)
        @sampler =
          sampler ||
          sample_callback ||
          Sampling::UniformSampler.new(sample_rate)
      end

      def call(event, hint = {})
        return nil unless sample?(event, hint)

        @app.call(event, hint)
      end

      private

      def sample?(event, hint)
        if @sampler.respond_to?(:sample?)
          @sampler.sample?(event, hint)
        else
          @sampler.call(event, hint)
        end
      end
    end
  end
end
