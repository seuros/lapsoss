# frozen_string_literal: true

require "logger"

module Lapsoss
  module Adapters
    class LoggerAdapter < Base
      def initialize(name, settings = {})
        @logger = settings[:logger] || Logger.new($stdout)
        super
      end

      def capabilities
        super.merge(
          breadcrumbs: true
        )
      end

      def capture(event)
        case event.type
        when :exception
          @logger.error(format_exception(event.exception, event.context))
        when :message
          logger_level = map_level(event.level)
          @logger.send(logger_level, format_message(event.message, event.context))
        else
          @logger.info("[LAPSOSS] Unhandled event type: #{event.type.inspect} | Event: #{event.to_h.inspect}")
        end

        # Log breadcrumbs if present in the event context
        return unless event.context[:breadcrumbs]&.any?

        event.context[:breadcrumbs].each do |breadcrumb|
          breadcrumb_msg = "[BREADCRUMB] [#{breadcrumb[:type].upcase}] #{breadcrumb[:message]}"
          breadcrumb_msg += " | #{breadcrumb[:metadata].inspect}" unless breadcrumb[:metadata].empty?
          @logger.debug(breadcrumb_msg)
        end
      end

      private

      def format_exception(exception, context)
        message = "[LAPSOSS] Exception: #{exception.class}: #{exception.message}"
        message += "\n#{exception.backtrace.first(10).join("\n")}" if exception.backtrace
        message += "\nContext: #{context.inspect}" unless context.empty?
        message
      end

      def format_message(message, context)
        msg = "[LAPSOSS] #{message}"
        msg += " | Context: #{context.inspect}" unless context.empty?
        msg
      end

      def map_level(level)
        case level
        when :debug then :debug
        when :info then :info
        when :warn, :warning then :warn
        when :error then :error
        when :fatal then :fatal
        else :info
        end
      end
    end
  end
end
