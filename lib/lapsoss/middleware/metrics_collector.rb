# frozen_string_literal: true

module Lapsoss
  module Middleware
    class MetricsCollector < Base
      def initialize(app, collector: nil)
        super(app)
        @collector = collector
        @metrics = {
          events_processed: 0,
          events_dropped: 0,
          events_by_type: Hash.new(0),
          events_by_level: Hash.new(0)
        }
        @mutex = Mutex.new
      end

      def call(event, hint = {})
        @mutex.synchronize do
          @metrics[:events_processed] += 1
          @metrics[:events_by_type][event.type] += 1
          @metrics[:events_by_level][event.level] += 1
        end

        result = @app.call(event, hint)

        if result.nil?
          @mutex.synchronize do
            @metrics[:events_dropped] += 1
          end
        end

        # Send to external collector if provided
        @collector&.call(@metrics.dup, event, hint)

        result
      end

      def metrics
        @mutex.synchronize { @metrics.dup }
      end
    end
  end
end
