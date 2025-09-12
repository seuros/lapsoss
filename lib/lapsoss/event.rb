# frozen_string_literal: true

require "active_support/core_ext/hash"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "active_support/json"

module Lapsoss
  # Immutable event structure using Ruby 3.3 Data class
  Event = Data.define(
    :type,           # :exception, :message, :transaction
    :level,          # :debug, :info, :warning, :error, :fatal
    :timestamp,
    :message,
    :exception,
    :context,
    :environment,
    :fingerprint,
    :backtrace_frames,
    :transaction     # Controller#action or task name where event occurred
  ) do
    # Factory method with smart defaults
    def self.build(type:, level: :info, **attributes)
      timestamp = attributes[:timestamp] || Time.now
      environment = attributes[:environment].presence || Lapsoss.configuration.environment
      context = attributes[:context] || {}

      # Process exception if present
      exception = attributes[:exception]
      message = attributes[:message].presence || exception&.message
      backtrace_frames = process_backtrace(exception) if exception

      # Generate fingerprint
      fingerprint = attributes.fetch(:fingerprint) {
        generate_fingerprint(type, message, exception, environment)
      }

      new(
        type: type,
        level: level,
        timestamp: timestamp,
        message: message,
        exception: exception,
        context: context,
        environment: environment,
        fingerprint: fingerprint,
        backtrace_frames: backtrace_frames,
        transaction: attributes[:transaction]
      )
    end

    # ActiveSupport::JSON serialization
    def as_json(options = nil)
      to_h.compact_blank.as_json(options)
    end

    def to_json(options = nil)
      ActiveSupport::JSON.encode(as_json(options))
    end

    # Helper methods
    def exception_type = exception&.class&.name

    def exception_message = exception&.message

    def has_exception? = exception.present?

    def has_backtrace? = backtrace_frames.present?

    def backtrace = exception&.backtrace

    def request_context = context.dig(:extra, :request) || context.dig(:extra, "request")

    def user_context = context[:user]

    def tags = context[:tags] || {}

    def extra = context[:extra] || {}

    def breadcrumbs = context[:breadcrumbs] || []

    # Apply data scrubbing
    def scrubbed
      scrubber = Scrubber.new(
        scrub_fields: Lapsoss.configuration.scrub_fields,
        scrub_all: Lapsoss.configuration.scrub_all,
        whitelist_fields: Lapsoss.configuration.whitelist_fields,
        randomize_scrub_length: Lapsoss.configuration.randomize_scrub_length
      )

      with(context: scrubber.scrub(context))
    end

    private

    def self.process_backtrace(exception)
      return nil unless exception&.backtrace.present?

      config = Lapsoss.configuration
      processor = BacktraceProcessor.new(config)
      processor.process_exception_backtrace(exception)
    end

    def self.generate_fingerprint(type, message, exception, environment)
      return nil unless Lapsoss.configuration.fingerprint_callback ||
                       Lapsoss.configuration.fingerprint_patterns.present?

      fingerprinter = Fingerprinter.new(
        custom_callback: Lapsoss.configuration.fingerprint_callback,
        patterns: Lapsoss.configuration.fingerprint_patterns,
        normalize_paths: Lapsoss.configuration.normalize_fingerprint_paths,
        normalize_ids: Lapsoss.configuration.normalize_fingerprint_ids,
        include_environment: Lapsoss.configuration.fingerprint_include_environment
      )

      # Create a temporary event-like object for fingerprinting
      temp_event = Struct.new(:type, :message, :exception, :environment).new(
        type,
        message,
        exception,
        environment
      )

      fingerprinter.generate_fingerprint(temp_event)
    end
  end
end
