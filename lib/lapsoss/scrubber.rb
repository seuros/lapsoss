# frozen_string_literal: true

require "active_support/parameter_filter"

module Lapsoss
  class Scrubber
    DEFAULT_SCRUB_FIELDS = %w[
      password passwd pwd secret token key api_key access_token
      authorization auth_token session_token csrf_token
      credit_card cc_number card_number ssn social_security_number
      phone mobile email_address
    ].freeze

    PROTECTED_EVENT_FIELDS = %w[
      type timestamp level message exception environment context
    ].freeze

    ATTACHMENT_CLASSES = %w[
      ActionDispatch::Http::UploadedFile
      Rack::Multipart::UploadedFile
      Tempfile
    ].freeze

    def initialize(config = {})
      @rails_parameter_filter = rails_parameter_filter

      # Only use custom scrubbing if Rails parameter filter is not available
      return if @rails_parameter_filter

      @scrub_fields = Array(config[:scrub_fields] || DEFAULT_SCRUB_FIELDS)
      @scrub_all = config[:scrub_all] || false
      @whitelist_fields = Array(config[:whitelist_fields] || [])
      @randomize_scrub_length = config[:randomize_scrub_length] || false
      @scrub_value = config[:scrub_value] || "**SCRUBBED**"
    end

    def scrub(data)
      return data if data.nil?

      # If Rails parameter filter is available, use it exclusively
      return @rails_parameter_filter.filter(data) if @rails_parameter_filter

      # Fallback to custom scrubbing logic only if Rails filter is not available
      @scrubbed_objects = {}.compare_by_identity
      scrub_recursive(data)
    end

    private

    def scrub_recursive(data)
      return data if @scrubbed_objects.key?(data)

      @scrubbed_objects[data] = true

      case data
      in Hash => hash
        scrub_hash(hash)
      in Array => array
        scrub_array(array)
      else
        scrub_value(data)
      end
    end

    def scrub_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        key_string = key.to_s.downcase

        result[key] = if should_scrub_field?(key_string)
                        generate_scrub_value(value)
        else
                        case value
                        in Hash => h
                          scrub_recursive(h)
                        in Array => a
                          scrub_array(a)
                        else
                          scrub_value(value)
                        end
        end
      end
    end

    def scrub_array(array)
      array.map do |item|
        scrub_recursive(item)
      end
    end

    def scrub_value(value)
      if attachment_value?(value)
        scrub_attachment(value)
      else
        value
      end
    end

    def should_scrub_field?(field_name)
      return false if whitelisted_field?(field_name)
      return false if protected_event_field?(field_name)
      return true if @scrub_all

      @scrub_fields.any? { |pattern| field_matches_pattern?(field_name, pattern) }
    end

    def field_matches_pattern?(field_name, pattern)
      case pattern
      in Regexp => regex
        regex.match?(field_name)
      else
        field_name.include?(pattern.to_s.downcase)
      end
    end

    def whitelisted_field?(field_name)
      @whitelist_fields.any? { |pattern| field_matches_pattern?(field_name, pattern) }
    end

    def protected_event_field?(field_name)
      PROTECTED_EVENT_FIELDS.include?(field_name.to_s)
    end

    def whitelisted_value?(_value)
      # Basic implementation - could be extended
      false
    end

    def attachment_value?(value)
      return false unless value.respond_to?(:class)

      ATTACHMENT_CLASSES.include?(value.class.name)
    end

    def scrub_attachment(attachment)
      {
        __attachment__: true,
        content_type: safe_call(attachment, :content_type),
        original_filename: safe_call(attachment, :original_filename),
        size: safe_call(attachment, :size) || safe_call(attachment, :tempfile, :size)
      }
    rescue StandardError => e
      { __attachment__: true, error: "Failed to extract attachment info: #{e.message}" }
    end

    def safe_call(object, *methods)
      methods.reduce(object) do |obj, method|
        obj.respond_to?(method) ? obj.public_send(method) : nil
      end
    end

    def generate_scrub_value(_original_value)
      if @randomize_scrub_length
        "*" * rand(6..12)
      else
        @scrub_value
      end
    end

    def rails_parameter_filter
      return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      return nil unless defined?(ActiveSupport::ParameterFilter)

      filter_params = Rails.application.config.filter_parameters
      return nil if filter_params.empty?

      ActiveSupport::ParameterFilter.new(filter_params)
    rescue StandardError
      # Fallback silently if Rails config is not available
      nil
    end
  end
end
