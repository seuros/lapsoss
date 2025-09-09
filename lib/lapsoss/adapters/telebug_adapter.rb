# frozen_string_literal: true

require_relative "sentry_adapter"

module Lapsoss
  module Adapters
    # Telebug adapter - uses Sentry protocol with Telebug endpoints
    # Telebug is compatible with Sentry's API, so we inherit from SentryAdapter
    class TelebugAdapter < SentryAdapter
      def initialize(name = :telebug, settings = {})
        super(name, settings)
      end

      private

      # Override to parse Telebug DSN format
      def parse_dsn(dsn_string)
        uri = URI.parse(dsn_string)
        {
          public_key: uri.user,
          project_id: uri.path.split("/").last,
          host: uri.host,
          path: uri.path
        }
      end

      # Override to build Telebug-specific API path
      def build_api_path(uri)
        # Telebug uses: https://[key]@[host]/api/v1/sentry_errors/[project_id]
        # The path is already complete: /api/v1/sentry_errors/4
        # Unlike Sentry which needs /api/[project_id]/envelope/
        uri.path
      end

      # Override to setup Telebug endpoint
      def setup_endpoint
        uri = URI.parse(@settings[:dsn])
        # For Telebug, we use the full URL without port (unless non-standard)
        port = (uri.port == 443 || uri.port == 80) ? "" : ":#{uri.port}"
        self.class.api_endpoint = "#{uri.scheme}://#{uri.host}#{port}"
        self.class.api_path = build_api_path(uri)
      end

      # Override headers builder to add Telebug-specific headers
      def headers_for(envelope)
        base_headers = super(envelope)
        base_headers.merge(
          "X-Telebug-Client" => "lapsoss/#{Lapsoss::VERSION}"
        )
      end

      # Override user agent for Telebug
      def user_agent
        "lapsoss-telebug/#{Lapsoss::VERSION}"
      end
    end
  end
end
