# frozen_string_literal: true

module Lapsoss
  module Middleware
    class Base
      def initialize(app)
        @app = app
      end

      def call(event, hint = {})
        @app.call(event, hint)
      end
    end
  end
end
