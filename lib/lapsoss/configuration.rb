# frozen_string_literal: true

require "logger"
require "active_support/configurable"

module Lapsoss
  class Configuration
    include Validators
    include ActiveSupport::Configurable

    attr_accessor :async, :logger, :enabled, :release, :debug,
                  :scrub_fields, :scrub_all, :whitelist_fields, :randomize_scrub_length,
                  :transport_jitter, :fingerprint_patterns,
                  :normalize_fingerprint_paths, :normalize_fingerprint_ids, :fingerprint_include_environment,
                  :backtrace_context_lines, :backtrace_in_app_patterns, :backtrace_exclude_patterns,
                  :backtrace_strip_load_path, :backtrace_max_frames, :backtrace_enable_code_context,
                  :enable_pipeline, :pipeline_builder, :sampling_strategy,
                  :skip_rails_cache_errors, :force_sync_http, :capture_request_context
    attr_reader :fingerprint_callback, :environment, :before_send, :sample_rate, :error_handler, :transport_timeout,
                :transport_max_retries, :transport_initial_backoff, :transport_max_backoff, :transport_backoff_multiplier, :transport_ssl_verify, :default_context, :adapter_configs

    def initialize
      @adapter_configs = {}
      @async = true
      @logger = Logger.new(nil) # Default null logger
      @environment = nil
      @enabled = true
      @release = nil
      @debug = false
      @before_send = nil
      @sample_rate = 1.0
      @default_context = {}
      @error_handler = nil
      @scrub_fields = nil # Will use defaults from Scrubber
      @scrub_all = false
      @whitelist_fields = []
      @randomize_scrub_length = false
      # Transport reliability settings
      @transport_timeout = 5
      @transport_max_retries = 3
      @transport_initial_backoff = 1.0
      @transport_max_backoff = 64.0
      @transport_backoff_multiplier = 2.0
      @transport_jitter = true
      @transport_ssl_verify = true
      # Fingerprinting settings
      @fingerprint_callback = nil
      @fingerprint_patterns = nil # Will use defaults from Fingerprinter
      @normalize_fingerprint_paths = true
      @normalize_fingerprint_ids = true
      @fingerprint_include_environment = false
      # Backtrace processing settings
      @backtrace_context_lines = 3
      @backtrace_in_app_patterns = []
      @backtrace_exclude_patterns = []
      @backtrace_strip_load_path = true
      @backtrace_max_frames = 100
      @backtrace_enable_code_context = true
      # Pipeline settings
      @enable_pipeline = true
      @pipeline_builder = nil
      @sampling_strategy = nil
      # Rails error filtering
      @skip_rails_cache_errors = true
      # HTTP client settings
      @force_sync_http = false
      # Capture request context in middleware
      @capture_request_context = true
    end

    # Register a named adapter configuration
    #
    # @param name [Symbol] Unique name for this adapter instance
    # @param type [Symbol] The adapter type (e.g., :sentry, :appsignal)
    # @param settings [Hash] Configuration settings for the adapter
    def register_adapter(name, type, **settings)
      @adapter_configs[name.to_sym] = {
        type: type&.to_sym,
        settings: settings
      }
    end

    # Convenience method for Sentry
    def use_sentry(name: :sentry, **settings)
      register_adapter(name, :sentry, **settings)
    end

    # Convenience method for Telebugs (Sentry-compatible)
    def use_telebugs(name: :telebugs, **settings)
      register_adapter(name, :telebugs, **settings)
    end

    # Convenience method for AppSignal
    def use_appsignal(name: :appsignal, **settings)
      register_adapter(name, :appsignal, **settings)
    end

    # Convenience method for Insight Hub
    def use_insight_hub(name: :insight_hub, **settings)
      register_adapter(name, :insight_hub, **settings)
    end

    # Backwards compatibility for Bugsnag
    def use_bugsnag(name: :bugsnag, **settings)
      register_adapter(name, :bugsnag, **settings)
    end

    # Convenience method for Rollbar
    def use_rollbar(name: :rollbar, **settings)
      register_adapter(name, :rollbar, **settings)
    end

    # Convenience method for Logger
    def use_logger(name: :logger, **settings)
      register_adapter(name, :logger, **settings)
    end

    # Apply configuration by registering all adapters
    def apply!
      Registry.instance.clear!

      @adapter_configs.each do |name, config|
        Registry.instance.register(
          name,
          config[:type],
          **config[:settings]
        )
      end
    end

    # Check if any adapters are configured
    def adapters_configured?
      !@adapter_configs.empty?
    end

    # Get configured adapter names
    def adapter_names
      @adapter_configs.keys
    end

    # Default tags setter/getter
    def default_tags=(tags)
      @default_context[:tags] = tags
    end

    def default_tags
      @default_context[:tags] ||= {}
    end

    # Default user setter/getter
    def default_user=(user)
      @default_context[:user] = user
    end

    def default_user
      @default_context[:user]
    end

    # Default extra context setter/getter
    def default_extra=(extra)
      @default_context[:extra] = extra
    end

    def default_extra
      @default_context[:extra] ||= {}
    end

    def clear!
      initialize
    end

    def debug?
      @debug
    end

    def async?
      @async
    end

    # Pipeline configuration
    def configure_pipeline
      @pipeline_builder = PipelineBuilder.new
      yield(@pipeline_builder) if block_given?
      @pipeline_builder
    end

    def pipeline
      @pipeline_builder&.pipeline
    end

    # Sampling configuration
    def configure_sampling(strategy = nil, &block)
      if strategy
        @sampling_strategy = strategy
      elsif block_given?
        @sampling_strategy = block
      end
    end

    def create_sampling_strategy
      case @sampling_strategy
      when Numeric
        Sampling::UniformSampler.new(@sampling_strategy)
      when Proc
        @sampling_strategy
      when nil
        Sampling::UniformSampler.new(@sample_rate)
      else
        @sampling_strategy
      end
    end

    # Validation and setter overrides
    def sample_rate=(value)
      validate_sample_rate!(value, "sample_rate") if value
      @sample_rate = value
    end

    def before_send=(value)
      validate_callable!(value, "before_send")
      @before_send = value
    end

    def error_handler=(value)
      validate_callable!(value, "error_handler")
      @error_handler = value
    end

    def environment=(value)
      validate_environment!(value, "environment") if value
      @environment = value&.to_s
    end

    def transport_timeout=(value)
      validate_timeout!(value, "transport_timeout") if value
      @transport_timeout = value
    end

    def transport_max_retries=(value)
      validate_retries!(value, "transport_max_retries") if value
      @transport_max_retries = value
    end

    def transport_initial_backoff=(value)
      validate_timeout!(value, "transport_initial_backoff") if value
      @transport_initial_backoff = value
    end

    def transport_max_backoff=(value)
      validate_timeout!(value, "transport_max_backoff") if value
      @transport_max_backoff = value
    end

    def transport_backoff_multiplier=(value)
      if value
        validate_type!(value, [ Numeric ], "transport_backoff_multiplier")
        validate_numeric_range!(value, 1.0..10.0, "transport_backoff_multiplier")
      end
      @transport_backoff_multiplier = value
    end

    def transport_ssl_verify=(value)
      validate_boolean!(value, "transport_ssl_verify") if value
      @transport_ssl_verify = value
    end

    def fingerprint_callback=(value)
      validate_callable!(value, "fingerprint_callback")
      @fingerprint_callback = value
    end

    # Configuration validation - just log warnings, don't fail
    def validate!
      # Check sample rate is between 0 and 1
      if @sample_rate && (@sample_rate < 0 || @sample_rate > 1)
        logger.warn "sample_rate should be between 0 and 1, got #{@sample_rate}"
      end

      # Check callables
      validate_callable!(@before_send, "before_send")
      validate_callable!(@error_handler, "error_handler")
      validate_callable!(@fingerprint_callback, "fingerprint_callback")

      # Log if environment looks unusual
      validate_environment!(@environment, "environment") if @environment

      # Just log if transport settings look unusual
      if @transport_timeout && @transport_timeout <= 0
        logger.warn "transport_timeout should be positive, got #{@transport_timeout}"
      end

      if @transport_max_retries && @transport_max_retries < 0
        logger.warn "transport_max_retries should be non-negative, got #{@transport_max_retries}"
      end

      if @transport_initial_backoff && @transport_max_backoff && @transport_initial_backoff > @transport_max_backoff
        logger.warn "transport_initial_backoff (#{@transport_initial_backoff}) should be less than transport_max_backoff (#{@transport_max_backoff})"
      end

      # Validate adapter configurations exist
      @adapter_configs.each do |name, config|
        if config[:type].blank?
          logger.warn "Adapter '#{name}' has no type specified"
        end
      end

      true
    end

    private

    # Adapter config validation moved to inline logging
  end
end
