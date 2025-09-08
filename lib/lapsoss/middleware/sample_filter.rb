# frozen_string_literal: true

module Lapsoss
  module Middleware
    class SampleFilter < Base
      def initialize(app, sample_rate: 1.0, sample_callback: nil)
        super(app)
        @sample_rate = sample_rate
        @sample_callback = sample_callback
      end

      def call(event, hint = {})
        # Apply custom sampling logic first
        return nil if @sample_callback && !@sample_callback.call(event, hint)

        # Apply rate-based sampling
        return nil if (@sample_rate < 1.0) && (rand > @sample_rate)

        @app.call(event, hint)
      end
    end
  end
end
