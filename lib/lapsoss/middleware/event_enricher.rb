# frozen_string_literal: true

module Lapsoss
  module Middleware
    class EventEnricher < Base
      def initialize(app, enrichers: [])
        super(app)
        @enrichers = enrichers
      end

      def call(event, hint = {})
        @enrichers.each do |enricher|
          enricher.call(event, hint)
        end
        @app.call(event, hint)
      end
    end
  end
end
