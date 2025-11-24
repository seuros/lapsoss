# frozen_string_literal: true

require_relative "sentry_adapter"

module Lapsoss
  module Adapters
    # Telebugs adapter - uses Sentry protocol with Telebugs endpoints
    # Telebugs is compatible with Sentry's API, so we inherit from SentryAdapter
    class TelebugsAdapter < SentryAdapter
      def initialize(name = :telebugs, settings = {})
        debug_log "[TELEBUGS INIT] Initializing with settings: #{settings.inspect}"
        super(name, settings)
        debug_log "[TELEBUGS INIT] Initialization complete, enabled: #{@enabled}"
      end

      private

      # Override to parse Telebugs DSN format
      def parse_dsn(dsn_string)
        debug_log "[TELEBUGS DSN] Parsing DSN: #{dsn_string}"
        uri = URI.parse(dsn_string)
        parsed = {
          public_key: uri.user,
          project_id: uri.path.split("/").last,
          host: uri.host,
          path: uri.path
        }
        debug_log "[TELEBUGS DSN] Parsed: #{parsed.inspect}"
        parsed
      end

      # Override to build Telebugs-specific API path
      def build_api_path(uri)
        # Telebugs DSN: https://[key]@[host]/api/v1/sentry_errors/[project_id]
        # But needs to hit: /api/v1/sentry_errors/api/[project_id]/envelope/
        # Extract base path without project_id
        path_parts = uri.path.split("/")
        project_id = path_parts.last
        base_path = path_parts[0..-2].join("/")

        # Build the envelope path
        "#{base_path}/api/#{project_id}/envelope/"
      end

      # Override to setup Telebugs endpoint
      def setup_endpoint
        uri = URI.parse(@settings[:dsn])
        # For Telebug, we use the full URL without port (unless non-standard)
        port = (uri.port == 443 || uri.port == 80) ? "" : ":#{uri.port}"
        endpoint = "#{uri.scheme}://#{uri.host}#{port}"
        api_path = build_api_path(uri)

        debug_log "[TELEBUGS ENDPOINT] Setting endpoint: #{endpoint}"
        debug_log "[TELEBUGS ENDPOINT] Setting API path: #{api_path}"

        @api_endpoint = endpoint
        @api_path = api_path
      end

      public

      # Override capture to add debug logging
      def capture(event)
        debug_log "[TELEBUGS DEBUG] Capture called for event: #{event.type}"
        debug_log "[TELEBUGS DEBUG] DSN configured: #{@dsn.inspect}"
        debug_log "[TELEBUGS DEBUG] Endpoint: #{@api_endpoint}"
        debug_log "[TELEBUGS DEBUG] API Path: #{@api_path}"

        result = super(event)
        debug_log "[TELEBUGS DEBUG] Event sent successfully, response: #{result.inspect}"
        result
      rescue => e
        debug_log "[TELEBUGS ERROR] Failed to send: #{e.message}", :error
        debug_log "[TELEBUGS ERROR] Backtrace: #{e.backtrace.first(5).join("\n")}", :error
        raise
      end

      def debug_log(message, level = :info)
        return unless @debug

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.public_send(level, message)
        elsif @logger
          @logger.public_send(level, message)
        end
      end

      # Override headers builder to add Telebugs-specific headers
      def headers_for(envelope)
        base_headers = super(envelope)
        base_headers.merge(
          "X-Telebugs-Client" => "lapsoss/#{Lapsoss::VERSION}"
        )
      end
    end
  end
end
