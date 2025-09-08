# frozen_string_literal: true

module Lapsoss
  module Adapters
    class Base
      include Validators

      USER_AGENT = "lapsoss/#{Lapsoss::VERSION}".freeze
      JSON_CONTENT_TYPE = "application/json; charset=UTF-8".freeze

      attr_reader :name, :settings

      def initialize(name, settings = {})
        @name = name
        @settings = settings
        @enabled = true
        configure_sdk
      end

      def enabled?
        @enabled
      end

      def enable!
        @enabled = true
      end

      def disable!
        @enabled = false
      end

      def capabilities
        {
          errors: true,
          performance: false,
          sessions: false,
          feature_flags: false,
          check_ins: false,
          breadcrumbs: false,
          deployments: false,
          metrics: false,
          profiling: false,
          security: false,
          code_context: false,
          data_scrubbing: false
        }
      end

      def supports?(capability)
        capabilities[capability] == true
      end

      def capture(event)
        raise NotImplementedError, "#{self.class.name} must implement #capture"
      end

      def flush(timeout: 2)
        # Optional implementation for flushing pending events
      end

      def shutdown
        @enabled = false
      end

      private

      def configure_sdk
        # Override in subclass to configure vendor SDK
      end

      def create_http_client(uri, custom_config = {})
        config = Lapsoss.configuration

        transport_config = {
          timeout: config.transport_timeout,
          max_retries: config.transport_max_retries,
          initial_backoff: config.transport_initial_backoff,
          max_backoff: config.transport_max_backoff,
          backoff_multiplier: config.transport_backoff_multiplier,
          jitter: config.transport_jitter,
          ssl_verify: config.transport_ssl_verify
        }.merge(custom_config)

        HttpClient.new(uri, transport_config)
      end

      def user_agent
        USER_AGENT
      end

      def json_content_type
        JSON_CONTENT_TYPE
      end

      def default_headers(content_type: nil, gzip: false, extra: {})
        headers = { "User-Agent" => user_agent }
        headers["Content-Type"] = content_type if content_type
        headers["Content-Encoding"] = "gzip" if gzip
        headers.merge!(extra) if extra && !extra.empty?
        headers
      end
    end
  end
end
