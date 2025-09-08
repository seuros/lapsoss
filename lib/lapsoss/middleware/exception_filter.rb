# frozen_string_literal: true

module Lapsoss
  module Middleware
    class ExceptionFilter < Base
      def initialize(app, excluded_exceptions: [], excluded_patterns: [])
        super(app)
        @excluded_exceptions = Array(excluded_exceptions)
        @excluded_patterns = Array(excluded_patterns)
      end

      def call(event, hint = {})
        return nil if should_exclude?(event)

        @app.call(event, hint)
      end

      private

      def should_exclude?(event)
        return false unless event.exception

        exception_class = event.exception.class
        exception_message = event.exception.message

        # Check exact class matches
        return true if @excluded_exceptions.any? { |klass| exception_class <= klass }

        # Check pattern matches
        @excluded_patterns.any? do |pattern|
          case pattern
          when Regexp
            exception_message&.match?(pattern) || exception_class.name.match?(pattern)
          when String
            exception_message&.include?(pattern) || exception_class.name.include?(pattern)
          else
            false
          end
        end
      end
    end
  end
end
