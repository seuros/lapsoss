# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lapsoss
  module Adapters
    # OTLP adapter - sends errors via OpenTelemetry Protocol
    # Works with any OTLP-compatible backend: SigNoz, Jaeger, Tempo, Honeycomb, etc.
    # Docs: https://opentelemetry.io/docs/specs/otlp/
    class OtlpAdapter < Base
      include Concerns::HttpDelivery
      include Concerns::StacktraceBuilder
      include Concerns::TraceContext
      include Concerns::EnvelopeBuilder

      # OTLP status codes
      STATUS_CODE_UNSET = 0
      STATUS_CODE_OK = 1
      STATUS_CODE_ERROR = 2

      # OTLP span kinds
      SPAN_KIND_INTERNAL = 1

      DEFAULT_ENDPOINT = "http://localhost:4318"

      def initialize(name, settings = {})
        super

        @endpoint = settings[:endpoint].presence || ENV["OTLP_ENDPOINT"] || DEFAULT_ENDPOINT
        @headers = settings[:headers] || {}
        @service_name = settings[:service_name].presence || ENV["OTEL_SERVICE_NAME"] || "rails"
        @environment = settings[:environment].presence || ENV["OTEL_ENVIRONMENT"] || "production"

        # Support common auth patterns
        if (api_key = settings[:api_key].presence || ENV["OTLP_API_KEY"])
          @headers["Authorization"] = "Bearer #{api_key}"
        end

        if (signoz_key = settings[:signoz_api_key].presence || ENV["SIGNOZ_API_KEY"])
          @headers["signoz-access-token"] = signoz_key
        end

        setup_endpoint
      end

      def capture(event)
        deliver(event.scrubbed)
      end

      def capabilities
        super.merge(
          breadcrumbs: false,
          code_context: true,
          data_scrubbing: true
        )
      end

      private

      def setup_endpoint
        uri = URI.parse(@endpoint)
        @api_endpoint = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        @api_path = "/v1/traces"
      end

      def build_payload(event)
        {
          resourceSpans: [ build_resource_spans(event) ]
        }
      end

      def build_resource_spans(event)
        {
          resource: build_resource(event),
          scopeSpans: [ build_scope_spans(event) ]
        }
      end

      def build_resource(event)
        attributes = [
          { key: "service.name", value: { stringValue: @service_name } },
          { key: "deployment.environment", value: { stringValue: event.environment.presence || @environment } },
          { key: "telemetry.sdk.name", value: { stringValue: "lapsoss" } },
          { key: "telemetry.sdk.version", value: { stringValue: Lapsoss::VERSION } },
          { key: "telemetry.sdk.language", value: { stringValue: "ruby" } }
        ]

        # Add user context as resource attributes if available
        if event.user_context.present?
          event.user_context.each do |key, value|
            attributes << { key: "user.#{key}", value: attribute_value(value) }
          end
        end

        { attributes: attributes }
      end

      def build_scope_spans(event)
        {
          scope: {
            name: "lapsoss",
            version: Lapsoss::VERSION
          },
          spans: [ build_span(event) ]
        }
      end

      def build_span(event)
        now = timestamp_nanos(event.timestamp)
        span_name = event.type == :exception ? event.exception_type : "message"

        span = {
          traceId: generate_trace_id,
          spanId: generate_span_id,
          name: span_name,
          kind: SPAN_KIND_INTERNAL,
          startTimeUnixNano: now.to_s,
          endTimeUnixNano: now.to_s,
          status: build_status(event),
          attributes: build_span_attributes(event)
        }

        # Add exception event for exception types
        if event.type == :exception
          span[:events] = [ build_exception_event(event) ]
        end

        span
      end

      def build_status(event)
        if event.type == :exception || event.level == :error || event.level == :fatal
          { code: STATUS_CODE_ERROR, message: event.exception_message || event.message || "Error" }
        else
          { code: STATUS_CODE_OK }
        end
      end

      def build_span_attributes(event)
        attributes = []

        # Add tags
        event.tags&.each do |key, value|
          attributes << { key: key.to_s, value: attribute_value(value) }
        end

        # Add extra data
        event.extra&.each do |key, value|
          attributes << { key: "extra.#{key}", value: attribute_value(value) }
        end

        # Add request context
        if event.request_context.present?
          event.request_context.each do |key, value|
            attributes << { key: "http.#{key}", value: attribute_value(value) }
          end
        end

        # Add transaction name
        if event.transaction.present?
          attributes << { key: "transaction.name", value: { stringValue: event.transaction } }
        end

        # Add fingerprint
        if event.fingerprint.present?
          attributes << { key: "error.fingerprint", value: { stringValue: event.fingerprint } }
        end

        # Add message for message events
        if event.type == :message && event.message.present?
          attributes << { key: "message", value: { stringValue: event.message } }
        end

        attributes
      end

      def build_exception_event(event)
        attributes = [
          { key: "exception.type", value: { stringValue: event.exception_type } },
          { key: "exception.message", value: { stringValue: event.exception_message } }
        ]

        # Add stacktrace
        if event.has_backtrace?
          attributes << {
            key: "exception.stacktrace",
            value: { stringValue: build_stacktrace_string(event) }
          }
        end

        {
          name: "exception",
          timeUnixNano: timestamp_nanos(event.timestamp).to_s,
          attributes: attributes
        }
      end

      # Convert Ruby value to OTLP attribute value
      def attribute_value(value)
        case value
        when String
          { stringValue: value }
        when Integer
          { intValue: value.to_s }
        when Float
          { doubleValue: value }
        when TrueClass, FalseClass
          { boolValue: value }
        when Array
          { arrayValue: { values: value.map { |v| attribute_value(v) } } }
        else
          { stringValue: value.to_s }
        end
      end

      def serialize_payload(payload)
        json = ActiveSupport::JSON.encode(payload)

        if json.bytesize >= compress_threshold
          [ ActiveSupport::Gzip.compress(json), true ]
        else
          [ json, false ]
        end
      end

      def adapter_specific_headers
        @headers.dup
      end
    end
  end
end
