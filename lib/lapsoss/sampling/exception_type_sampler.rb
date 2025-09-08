# frozen_string_literal: true

module Lapsoss
  module Sampling
    class ExceptionTypeSampler < Base
      def initialize(rates: {})
        @rates = rates
        @default_rate = rates.fetch(:default, 1.0)
      end

      def sample?(event, _hint = {})
        return @default_rate > rand unless event.exception

        exception_class = event.exception.class
        rate = find_rate_for_exception(exception_class)
        rate > rand
      end

      private

      def find_rate_for_exception(exception_class)
        # Check exact class match first
        return @rates[exception_class] if @rates.key?(exception_class)

        # Check inheritance hierarchy
        @rates.each do |klass, rate|
          return rate if klass.is_a?(Class) && exception_class <= klass
        end

        # Check string/regex patterns
        @rates.each do |pattern, rate|
          case pattern
          when String
            return rate if exception_class.name.include?(pattern)
          when Regexp
            return rate if exception_class.name.match?(pattern)
          end
        end

        @default_rate
      end
    end
  end
end
