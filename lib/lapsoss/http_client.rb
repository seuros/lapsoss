# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"
require "zlib"

module Lapsoss
  # HTTP client wrapper using Faraday with retry logic
  class HttpClient
    USER_AGENT = "lapsoss/#{Lapsoss::VERSION}".freeze

    def initialize(base_url, config = {})
      @base_url = base_url
      @config = config
      @connection = build_connection
    end

    def post(path, body:, headers: {})
      response = @connection.post(path) do |req|
        req.body = body
        req.headers.merge!(headers)
      end

      unless response.success?
        raise DeliveryError.new(
          "HTTP #{response.status}: #{response.reason_phrase}",
          response: response
        )
      end

      response
    rescue Faraday::Error => e
      raise DeliveryError.new(
        "Network error: #{e.message}",
        cause: e
      )
    end

    def shutdown
      # Faraday connections don't need explicit shutdown
    end

    private

    def build_connection
      Faraday.new(@base_url) do |conn|
        # Configure retry middleware
        conn.request :retry, retry_options

        # Configure timeouts
        conn.options.timeout = @config[:timeout] || 5
        conn.options.open_timeout = @config[:timeout] || 5

        # Configure SSL
        conn.ssl.verify = @config[:ssl_verify] if @config.key?(:ssl_verify)

        # Set user agent
        conn.headers["User-Agent"] = USER_AGENT

        # Auto-detect and use appropriate adapter
        conn.adapter detect_optimal_adapter
      end
    end

    def detect_optimal_adapter
      if fiber_scheduler_active? && async_adapter_available? && !force_sync_mode?
        log_adapter_selection(:async)
        :async_http
      else
        log_adapter_selection(:sync)
        Faraday.default_adapter
      end
    end

    def fiber_scheduler_active?
      Fiber.current_scheduler != nil
    end

    def async_adapter_available?
      require "async/http/faraday"
      true
    rescue LoadError
      false
    end

    def force_sync_mode?
      Lapsoss.configuration.force_sync_http
    end

    def log_adapter_selection(adapter_type)
      return unless Lapsoss.configuration.debug?

      Lapsoss.configuration.logger&.debug(
        "[Lapsoss::HttpClient] Using #{adapter_type} HTTP adapter " \
        "(fiber_scheduler: #{fiber_scheduler_active?}, " \
        "async_available: #{async_adapter_available?}, " \
        "force_sync: #{force_sync_mode?})"
      )
    end

    def retry_options
      {
        max: @config[:max_retries] || 3,
        interval: @config[:initial_backoff] || 1.0,
        max_interval: @config[:max_backoff] || 64.0,
        backoff_factor: @config[:backoff_multiplier] || 2.0,
        retry_statuses: [ 408, 429, 500, 502, 503, 504 ],
        methods: [ :post ]
      }
    end
  end
end
