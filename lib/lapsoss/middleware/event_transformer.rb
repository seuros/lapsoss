# frozen_string_literal: true

module Lapsoss
  module Middleware
    class EventTransformer < Base
      def initialize(app, transformer)
        super(app)
        @transformer = transformer
      end

      def call(event, hint = {})
        transformed_event = @transformer.call(event, hint)
        return nil unless transformed_event

        @app.call(transformed_event, hint)
      end
    end
  end
end
