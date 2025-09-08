# frozen_string_literal: true

module Lapsoss
  module Middleware
    class ConditionalFilter < Base
      def initialize(app, condition)
        super(app)
        @condition = condition
      end

      def call(event, hint = {})
        return nil unless @condition.call(event, hint)

        @app.call(event, hint)
      end
    end
  end
end
