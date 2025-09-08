# frozen_string_literal: true

require "active_support/json"

module Lapsoss
  module Adapters
    class InsightHubAdapter < Base
      API_URI = "https://notify.bugsnag.com"

      def initialize(name, settings = {})
        super
        @api_key = settings[:api_key] || ENV.fetch("INSIGHT_HUB_API_KEY", nil)

        if @api_key.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss::InsightHubAdapter] No API key provided, adapter disabled"
          @enabled = false
          return
        else
          validate_api_key!(@api_key, "Insight Hub API key", format: :alphanumeric)
        end

        @client = create_http_client(API_URI)
        @backtrace_processor = BacktraceProcessor.new
      end

      def capture(event)
        return unless enabled?

        payload = build_payload(event)
        return unless payload

        headers = default_headers(
          content_type: json_content_type,
          extra: {
            "Bugsnag-Api-Key" => @api_key,
            "Bugsnag-Payload-Version" => "5"
          }
        )

        response = @client.post("/", body: ActiveSupport::JSON.encode(payload), headers: headers)

        handle_response(response, event)
      rescue StandardError => e
        handle_delivery_error(e)
      end

      def capabilities
        super.merge(
          breadcrumbs: true,
          user_tracking: true,
          custom_context: true,
          release_tracking: true,
          sessions: true
        )
      end

      def validate!
        validate_settings!
        true
      end

      private

      def build_payload(event)
        {
          apiKey: @api_key,
          payloadVersion: "5",
          notifier: {
            name: "Lapsoss Ruby",
            version: Lapsoss::VERSION,
            url: "https://github.com/yourusername/lapsoss"
          },
          events: [ build_event(event) ]
        }
      end

      def build_event(event)
        {
          app: build_app_data(event),
          device: build_device_data,
          exceptions: build_exceptions(event),
          breadcrumbs: build_breadcrumbs(event),
          request: event.request_context,
          user: build_user_data(event),
          context: event.context[:custom]&.dig(:context) || "production",
          severity: map_severity(event.level),
          unhandled: event.context[:unhandled] || false,
          metaData: event.context[:custom] || {}
        }.compact
      end

      def build_exceptions(event)
        return [] unless event.type == :exception && event.exception

        [ {
          errorClass: event.exception_type,
          message: event.message,
          stacktrace: build_stacktrace(event.exception),
          type: "ruby"
        } ]
      end

      def build_stacktrace(exception)
        frames = @backtrace_processor.process_exception(exception, follow_cause: true)
        @backtrace_processor.format_frames(frames, :bugsnag)
      end

      def build_app_data(event)
        {
          id: event.context[:app]&.dig(:id),
          version: event.context[:release]&.dig(:version),
          releaseStage: @environment || "production",
          type: detect_app_type
        }.compact
      end

      def build_device_data
        {
          hostname: Socket.gethostname,
          osName: RUBY_PLATFORM,
          runtimeVersions: {
            ruby: RUBY_VERSION
          }
        }
      end

      def build_breadcrumbs(event)
        Breadcrumb.for_insight_hub(event.context[:breadcrumbs] || [])
      end

      def build_user_data(event)
        user = event.context[:user]
        return nil unless user

        {
          id: user[:id]&.to_s,
          name: user[:username] || user[:name],
          email: user[:email]
        }.compact
      end

      def map_severity(level)
        case level
        when :debug, :info then "info"
        when :warning then "warning"
        when :error, :fatal then "error"
        else "error"
        end
      end

      def detect_app_type
        return "rails" if defined?(Rails)
        return "rack" if defined?(Rack)

        "ruby"
      end

      def handle_response(response, _event)
        case response.status
        when 200
          true
        when 400
          body = begin
            ActiveSupport::JSON.decode(response.body)
          rescue
            {}
          end
          raise DeliveryError.new("Bad request: #{body['errors']&.join(', ')}", response: response)
        when 401
          raise DeliveryError.new("Unauthorized: Invalid API key", response: response)
        when 413
          raise DeliveryError.new("Payload too large", response: response)
        when 429
          raise DeliveryError.new("Rate limit exceeded", response: response)
        else
          raise DeliveryError.new("Unexpected response: #{response.status}", response: response)
        end
      end

      # No longer need strict validation
      def validate_settings!
        # Validation moved to initialize with logging
      end

      def handle_delivery_error(error, response = nil)
        message = "Insight Hub delivery failed: #{error.message}"
        raise DeliveryError.new(message, response: response, cause: error)
      end
    end
  end
end
