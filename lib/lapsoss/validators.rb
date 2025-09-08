# frozen_string_literal: true

module Lapsoss
  module Validators
    class ValidationError < StandardError; end

    module_function

    # Simple presence check - just ensure it's not blank
    def validate_presence!(value, name)
      return unless value.blank?

      Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} is missing or blank"
      false
    end

    # Check if callable, log warning if not
    def validate_callable!(value, name)
      return true if value.nil? || value.respond_to?(:call)

      Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be callable but got #{value.class}"
      false
    end

    # Just log DSN issues, don't fail
    def validate_dsn!(dsn_string, name = "DSN")
      return true if dsn_string.blank?

      begin
        uri = URI.parse(dsn_string)

        if uri.user.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} appears to be missing public key"
        end

        if uri.host.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} appears to be missing host"
        end

        true
      rescue URI::InvalidURIError => e
        Lapsoss.configuration.logger&.error "[Lapsoss] #{name} couldn't be parsed: #{e.message}"
        false
      end
    end

    # Validate sample rate is between 0 and 1
    def validate_sample_rate!(value, name)
      return true if value.nil?

      if value < 0 || value > 1
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be between 0 and 1, got #{value}"
      end
      true
    end

    # Validate timeout values
    def validate_timeout!(value, name)
      return true if value.nil?

      if value <= 0
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be positive, got #{value}"
      end
      true
    end

    # Validate retry count
    def validate_retries!(value, name)
      return true if value.nil?

      if value < 0
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be non-negative, got #{value}"
      end
      true
    end

    # Validate environment string
    def validate_environment!(value, name)
      return true if value.nil?

      if value.to_s.strip.empty?
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should not be empty"
      end
      true
    end

    # Validate type
    def validate_type!(value, expected_types, name)
      return true if value.nil?

      unless expected_types.any? { |type| value.is_a?(type) }
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be one of #{expected_types.join(', ')}, got #{value.class}"
      end
      true
    end

    # Validate numeric range
    def validate_numeric_range!(value, range, name)
      return true if value.nil?

      unless range.include?(value)
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be within #{range}, got #{value}"
      end
      true
    end

    # Validate boolean
    def validate_boolean!(value, name)
      return true if value.nil?

      unless [ true, false ].include?(value)
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} should be true or false, got #{value}"
      end
      true
    end

    # Just check presence, don't validate format
    def validate_api_key!(value, name, format: nil)
      if value.blank?
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} is missing"
        return false
      end

      # Optional format hint for logging only
      case format
      when :uuid
        unless value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
          Lapsoss.configuration.logger&.info "[Lapsoss] #{name} doesn't look like a UUID, but continuing anyway"
        end
      when :alphanumeric
        unless value.match?(/\A[a-z0-9]+\z/i)
          Lapsoss.configuration.logger&.info "[Lapsoss] #{name} contains special characters, but continuing anyway"
        end
      end

      true
    end

    # Environment validation - just log if unusual
    def validate_environment!(value, name = "environment")
      return true if value.blank?

      common_envs = %w[development test staging production]
      unless common_envs.include?(value.to_s.downcase)
        Lapsoss.configuration.logger&.info "[Lapsoss] #{name} '#{value}' is non-standard (expected one of: #{common_envs.join(', ')})"
      end

      true
    end

    # URL validation - just check parsability
    def validate_url!(value, name)
      return true if value.nil?

      begin
        URI.parse(value)
        true
      rescue URI::InvalidURIError => e
        Lapsoss.configuration.logger&.warn "[Lapsoss] #{name} couldn't be parsed as URL: #{e.message}"
        false
      end
    end
  end
end
