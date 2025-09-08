# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "uri"

module Lapsoss
  module Adapters
    class SentryAdapter < Base
      include Concerns::LevelMapping
      include Concerns::EnvelopeBuilder
      include Concerns::HttpDelivery

      self.level_mapping_type = :sentry
      self.envelope_format = :sentry_envelope

      def initialize(name, settings = {})
        super

        if settings[:dsn].blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss::SentryAdapter] No DSN provided, adapter disabled"
          @enabled = false
          return
        end

        if validate_dsn!(settings[:dsn], "Sentry DSN")
          @dsn = parse_dsn(settings[:dsn])
          setup_endpoint
        else
          @enabled = false
        end
      end

      def capture(event)
        deliver(event.scrubbed)
      end

      def capabilities
        super.merge(
          code_context: true,
          breadcrumbs: true,
          data_scrubbing: true
        )
      end

      private

      def setup_endpoint
        uri = URI.parse(@settings[:dsn])
        self.class.api_endpoint = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        self.class.api_path = build_api_path(uri)
      end

      def build_api_path(uri)
        # Extract project ID from DSN path
        project_id = uri.path.split("/").last

        # Standard Sentry envelope endpoint
        "/api/#{project_id}/envelope/"
      end

      def parse_dsn(dsn_string)
        uri = URI.parse(dsn_string)
        {
          public_key: uri.user,
          project_id: uri.path.split("/").last
        }
      end

      # Build Sentry-specific payload format
      def build_payload(event)
        # Sentry uses envelope format with headers and items
        envelope_header = {
          event_id: event.fingerprint.presence || SecureRandom.uuid,
          sent_at: format_timestamp(event.timestamp),
          sdk: sdk_info
        }

        item_header = {
          type: event.type == :transaction ? "transaction" : "event",
          content_type: "application/json"
        }

        item_payload = build_envelope_wrapper(event)

        # Sentry envelope is newline-delimited JSON
        [
          ActiveSupport::JSON.encode(envelope_header),
          ActiveSupport::JSON.encode(item_header),
          ActiveSupport::JSON.encode(item_payload)
        ].join("\n")
      end

      # Override serialization for Sentry's envelope format
      def serialize_payload(envelope_string)
        # Sentry envelopes are already formatted, just compress if needed
        if envelope_string.bytesize >= compress_threshold
          [ ActiveSupport::Gzip.compress(envelope_string), true ]
        else
          [ envelope_string, false ]
        end
      end

      def adapter_specific_headers
        timestamp = Time.current.to_i
        {
          "X-Sentry-Auth" => [
            "Sentry sentry_version=7",
            "sentry_client=#{user_agent}",
            "sentry_timestamp=#{timestamp}",
            "sentry_key=#{@dsn[:public_key]}"
          ].join(", ")
        }
      end

      def build_delivery_headers(compressed: false, content_type: nil)
        super(compressed: compressed, content_type: "application/x-sentry-envelope")
      end

      # No longer need strict validation
      def validate_settings!
        # Validation moved to initialize with logging
      end
    end
  end
end
