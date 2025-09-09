# frozen_string_literal: true

require_relative "sentry_adapter"

module Lapsoss
  module Adapters
    # Telebugs adapter - uses Sentry protocol with Telebugs endpoints
    # Telebugs is compatible with Sentry's API, so we inherit from SentryAdapter
    class TelebugsAdapter < SentryAdapter
      def initialize(name = :telebugs, settings = {})
        super(name, settings)
      end

      private

      # Override to parse Telebugs DSN format
      def parse_dsn(dsn_string)
        uri = URI.parse(dsn_string)
        {
          public_key: uri.user,
          project_id: uri.path.split("/").last,
          host: uri.host,
          path: uri.path
        }
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
        self.class.api_endpoint = "#{uri.scheme}://#{uri.host}#{port}"
        self.class.api_path = build_api_path(uri)
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
