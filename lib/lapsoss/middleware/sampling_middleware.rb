# frozen_string_literal: true

module Lapsoss
  module Middleware
    class SamplingMiddleware < Base
      def initialize(app, sampler)
        super(app)
        @sampler = sampler
      end

      def call(event, hint = {})
        return nil unless @sampler.sample?(event, hint)

        @app.call(event, hint)
      end
    end
  end
end
