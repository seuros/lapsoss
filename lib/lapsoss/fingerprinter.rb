# frozen_string_literal: true

require "digest"

module Lapsoss
  class Fingerprinter
    # Base patterns that are always available
    BASE_PATTERNS = [
      # Generic error message normalization
      {
        pattern: /User \d+ (not found|invalid|missing)/i,
        fingerprint: "user-lookup-error"
      },
      {
        pattern: /Record \d+ (not found|invalid|missing)/i,
        fingerprint: "record-lookup-error"
      },

      # Network error patterns
      {
        pattern: /Net::(TimeoutError|ReadTimeout|OpenTimeout)/,
        fingerprint: "network-timeout"
      },
      {
        pattern: /Errno::(ECONNREFUSED|ECONNRESET|EHOSTUNREACH)/,
        fingerprint: "network-connection-error"
      },

      # Memory/Resource patterns
      {
        pattern: /NoMemoryError|SystemStackError/,
        fingerprint: "memory-resource-error"
      }
    ].freeze

    # ActiveRecord-specific patterns (only loaded if ActiveRecord is defined)
    ACTIVERECORD_PATTERNS = [
      {
        pattern: /ActiveRecord::RecordNotFound/,
        fingerprint: "record-not-found"
      },
      {
        pattern: /ActiveRecord::StatementInvalid.*timeout/i,
        fingerprint: "database-timeout"
      },
      {
        pattern: /ActiveRecord::ConnectionTimeoutError/,
        fingerprint: "database-connection-timeout"
      }
    ].freeze

    # Database adapter patterns (only loaded if adapters are defined)
    DATABASE_PATTERNS = [
      {
        pattern: /PG::ConnectionBad/,
        fingerprint: "postgres-connection-error",
        condition: -> { defined?(PG) }
      },
      {
        pattern: /Mysql2::Error/,
        fingerprint: "mysql-connection-error",
        condition: -> { defined?(Mysql2) }
      },
      {
        pattern: /SQLite3::BusyException/,
        fingerprint: "sqlite-busy-error",
        condition: -> { defined?(SQLite3) }
      }
    ].freeze

    def initialize(config = {})
      @custom_callback = config[:custom_callback]
      @patterns = build_patterns(config[:patterns])
      @normalize_ids = config.fetch(:normalize_ids, true)
      @include_environment = config.fetch(:include_environment, false)
    end

    def generate_fingerprint(event)
      # Try custom callback first
      if @custom_callback
        custom_result = @custom_callback.call(event)
        return custom_result if custom_result
      end

      # Try pattern matching
      pattern_result = match_patterns(event)
      return pattern_result if pattern_result

      # Fall back to default fingerprinting
      generate_default_fingerprint(event)
    end

    private

    def build_patterns(custom_patterns)
      return custom_patterns if custom_patterns

      patterns = BASE_PATTERNS.dup

      # Always include ActiveRecord patterns - they match on string names
      patterns.concat(ACTIVERECORD_PATTERNS)

      # Add database-specific patterns - they also match on string names
      DATABASE_PATTERNS.each do |pattern_config|
        # Skip the condition check - just match on error names
        patterns << pattern_config.except(:condition)
      end

      patterns
    end

    def match_patterns(event)
      full_error_text = build_error_text(event)

      @patterns.each do |pattern_config|
        pattern = pattern_config[:pattern]
        fingerprint = pattern_config[:fingerprint]

        case pattern
        in Regexp if pattern.match?(full_error_text)
          return fingerprint
        in String if full_error_text.include?(pattern)
          return fingerprint
        else
          # Continue to next pattern
        end
      end

      nil
    end

    def build_error_text(event)
      parts = []

      # Include exception class
      if event.exception
        parts << event.exception.class.name
        parts << event.exception.message if event.exception.message
      end

      # Include event message
      parts << event.message if event.message

      # Include first few backtrace lines for context
      parts.concat(event.exception.backtrace.first(3)) if event.exception&.backtrace

      parts.compact.join(" ")
    end

    def generate_default_fingerprint(event)
      components = []

      # Exception type
      if event.exception
        components << event.exception.class.name

        # Normalized message
        message = normalize_message(event.exception.message)
        components << message if message

        # Primary stack frame location
        primary_location = extract_primary_location(event.exception.backtrace)
        components << primary_location if primary_location
      elsif event.message
        components << "message"
        components << normalize_message(event.message)
      end

      # Include environment if configured
      components << event.environment if @include_environment && event.environment

      # Generate hash from components
      content = components.compact.join("|")
      Digest::SHA256.hexdigest(content)[0, 16] # Use first 16 chars for readability
    end

    def normalize_message(message)
      return nil unless message

      normalized = message.dup

      if @normalize_ids
        # Replace UUIDs first (before numeric IDs)
        normalized.gsub!(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, ":uuid")

        # Replace hex hashes with placeholder
        normalized.gsub!(/\b[0-9a-f]{32,}\b/i, ":hash")

        # Replace numeric IDs with placeholder (after UUIDs and hashes)
        normalized.gsub!(/\b\d{3,}\b/, ":id")

        # Replace timestamps
        normalized.gsub!(/\b\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}/, ":timestamp")
      end

      # Clean up extra whitespace
      normalized.strip.squeeze(" ")
    end

    def extract_primary_location(backtrace)
      return nil unless backtrace&.any?

      # Find first non-gem, non-framework line
      app_line = backtrace.find do |line|
        line.exclude?("/gems/") &&
          line.exclude?("/ruby/") &&
          line.exclude?("(eval)") &&
          !line.start_with?("[")
      end

      line_to_use = app_line || backtrace.first

      # Extract just filename:line_number
      if line_to_use =~ %r{([^/]+):(\d+)}
        "#{::Regexp.last_match(1)}:#{::Regexp.last_match(2)}"
      else
        line_to_use
      end
    end
  end
end
