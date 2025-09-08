# frozen_string_literal: true

require "json"
require "socket"

module Lapsoss
  module Adapters
    class AppsignalAdapter < Base
      PUSH_API_URI = "https://push.appsignal.com"
      ERRORS_API_URI = "https://appsignal-endpoint.net"

      def initialize(name, settings = {})
        super
        @push_api_key = settings[:push_api_key] || ENV.fetch("APPSIGNAL_PUSH_API_KEY", nil)
        @frontend_api_key = settings[:frontend_api_key] || ENV.fetch("APPSIGNAL_FRONTEND_API_KEY", nil)
        @app_name = settings[:app_name] || ENV.fetch("APPSIGNAL_APP_NAME", nil)
        @environment = Lapsoss.configuration.environment

        # Just log if keys look unusual but don't fail
        if @push_api_key.present?
          validate_api_key!(@push_api_key, "AppSignal push API key", format: :uuid)
        end

        if @frontend_api_key.present?
          validate_api_key!(@frontend_api_key, "AppSignal frontend API key", format: :uuid)
        end

        if @push_api_key.blank? && @frontend_api_key.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss::AppsignalAdapter] No API keys provided, adapter disabled"
          @enabled = false
          return
        end

        @push_client = create_http_client(PUSH_API_URI) if @push_api_key
        @errors_client = create_http_client(ERRORS_API_URI) if @frontend_api_key
      end

      def capture(event)
        return unless enabled? && @errors_client

        payload = build_error_payload(event)
        return unless payload

        path = "/errors?api_key=#{@frontend_api_key}"
        headers = default_headers(content_type: json_content_type)

        begin
          @errors_client.post(path, body: ActiveSupport::JSON.encode(payload), headers: headers)
        rescue DeliveryError => e
          # Log the error and potentially notify error handler
          Lapsoss.configuration.logger&.error("[Lapsoss::AppsignalAdapter] Failed to deliver event: #{e.message}")
          Lapsoss.configuration.error_handler&.call(e)

          # Re-raise to let the caller know delivery failed
          raise
        end
      end

      def shutdown
        @push_client&.shutdown
        @errors_client&.shutdown
        super
      end

      private

      def build_error_payload(event)
        case event.type
        when :exception
          build_exception_payload(event)
        when :message
          build_message_payload(event)
        end
      end

      def build_exception_payload(event)
        {
          timestamp: event.timestamp.to_i,
          namespace: event.context[:namespace] || "backend",
          error: {
            name: event.exception.class.name,
            message: event.exception.message,
            backtrace: event.exception.backtrace || []
          },
          tags: stringify_hash(event.context[:tags]),
          params: stringify_hash(event.context[:params]),
          environment: build_environment_context(event),
          breadcrumbs: event.context[:breadcrumbs]
        }
      end

      def build_message_payload(event)
        # AppSignal's Error API expects exception-like structure
        # Instead of creating fake exceptions, we'll structure the message properly
        # but clearly indicate it's a log message, not an exception

        unless %i[error fatal critical].include?(event.level)
          # Log when messages are dropped due to level filtering
          Lapsoss.configuration.logger&.debug(
            "[Lapsoss::AppsignalAdapter] Dropping message with level '#{event.level}' - " \
            "AppSignal only supports :error, :fatal, and :critical levels for messages"
          )
          return nil
        end

        {
          action: event.context[:action] || "log_message",
          path: event.context[:path] || "/",
          exception: {
            # AppSignal requires exception format for messages - this isn't a real exception
            # but rather a way to send structured log messages through their error API
            name: "LogMessage", # Clear indication this is a log message
            message: event.message,
            backtrace: [] # No fake backtrace for log messages
          },
          tags: stringify_hash(event.context[:tags]),
          params: stringify_hash(event.context[:params]),
          environment: build_environment_context(event),
          breadcrumbs: event.context[:breadcrumbs]
        }
      end

      def build_environment_context(event)
        {
          "hostname" => Socket.gethostname,
          "app_name" => @app_name,
          "environment" => @environment
        }.merge(stringify_hash(event.context[:environment] || {}))
      end

      def stringify_hash(hash)
        (hash || {}).transform_keys(&:to_s).transform_values(&:to_s)
      end

      # No longer need strict validation
      def validate_settings!
        # Validation moved to initialize with logging
      end
    end
  end
end
