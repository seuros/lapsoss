# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Lapsoss
  module Validators
    extend ActiveSupport::Concern

    module_function

    def logger
      Lapsoss.configuration.logger
    end

    # Simple presence check using AS blank?
    def validate_presence!(value, name)
      return true if value.present?
      logger.warn "#{name} is missing or blank"
      false
    end

    # Check if callable
    def validate_callable!(value, name)
      return true if value.nil? || value.respond_to?(:call)
      logger.warn "#{name} should be callable but got #{value.class}"
      false
    end

    # DSN validation - just log issues
    def validate_dsn!(dsn_string, name = "DSN")
      return true if dsn_string.blank?

      uri = URI.parse(dsn_string)
      logger.warn "#{name} appears to be missing public key" if uri.user.blank?
      logger.warn "#{name} appears to be missing host" if uri.host.blank?
      true
    rescue URI::InvalidURIError => e
      logger.error "#{name} couldn't be parsed: #{e.message}"
      false
    end

    # Validate numeric ranges using AS Range#cover?
    def validate_sample_rate!(value, name)
      return true if value.nil?
      return true if (0..1).cover?(value)
      logger.warn "#{name} should be between 0 and 1, got #{value}"
      false
    end

    def validate_timeout!(value, name)
      return true if value.nil?
      return true if value.positive?
      logger.warn "#{name} should be positive, got #{value}"
      false
    end

    def validate_retries!(value, name)
      return true if value.nil?
      return true if value >= 0
      logger.warn "#{name} should be non-negative, got #{value}"
      false
    end

    # Environment validation using AS presence
    def validate_environment!(value, name = "environment")
      return true if value.blank?

      value_str = value.to_s.strip
      return true if value_str.present?

      logger.warn "#{name} should not be empty"
      false
    end

    # API key validation using AS blank?
    def validate_api_key!(value, name, format: nil)
      return false if value.blank? && logger.warn("#{name} is missing")

      # Optional format hints
      case format
      when :uuid
        logger.info "#{name} doesn't look like a UUID, but continuing anyway" unless value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      when :alphanumeric
        logger.info "#{name} contains special characters, but continuing anyway" unless value.match?(/\A[a-z0-9]+\z/i)
      end

      true
    end

    # URL validation
    def validate_url!(value, name)
      return true if value.nil?
      URI.parse(value)
      true
    rescue URI::InvalidURIError => e
      logger.warn "#{name} couldn't be parsed as URL: #{e.message}"
      false
    end
  end
end
