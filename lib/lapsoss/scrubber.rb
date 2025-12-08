# frozen_string_literal: true

require "active_support/parameter_filter"

module Lapsoss
  class Scrubber
    # Match Rails conventions - these are only used when Rails is not available
    # Rails uses partial matching, so 'passw' matches 'password'
    DEFAULT_SCRUB_FIELDS = %i[
      passw email secret token _key crypt salt certificate otp ssn cvv cvc
    ].freeze

    MASK = "[FILTERED]"

    def initialize(config = {})
      @scrub_all = !!config[:scrub_all]
      @whitelist_fields = Array(config[:whitelist_fields]).map(&:to_s)
      @randomize_scrub_length = !!config[:randomize_scrub_length]

      # Combine: Rails filter parameters + custom fields (if provided)
      base_params = if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
                      Rails.application.config.filter_parameters.presence || DEFAULT_SCRUB_FIELDS
      else
                      DEFAULT_SCRUB_FIELDS
      end

      filter_params = if config[:scrub_fields]
                        Array(base_params) + Array(config[:scrub_fields])
      else
                        base_params
      end

      @filter = ActiveSupport::ParameterFilter.new(filter_params, mask: MASK)
    end

    def scrub(data)
      return data if data.nil?

      if @scrub_all
        deep_scrub_all(data)
      else
        filtered = @filter.filter(data)
        filtered = restore_whitelisted_values(data, filtered) if @whitelist_fields.any?
        @randomize_scrub_length ? randomize_masks(filtered) : filtered
      end
    end

    private

    def deep_scrub_all(value)
      case value
      when Hash
        value.each_with_object(value.class.new) do |(key, val), result|
          if whitelisted?(key)
            result[key] = val
          else
            result[key] = structure_preserving_mask(val)
          end
        end
      when Array
        value.map { |item| deep_scrub_all(item) }
      else
        mask_value(value)
      end
    end

    def structure_preserving_mask(value)
      case value
      when Hash, Array
        deep_scrub_all(value)
      else
        mask_value(value)
      end
    end

    def mask_value(value)
      @randomize_scrub_length ? random_mask(value) : MASK
    end

    def random_mask(value)
      length = [ [ value.to_s.length, 3 ].max, 32 ].min
      "*" * length
    end

    def whitelisted?(key)
      @whitelist_fields.include?(key.to_s)
    end

    def restore_whitelisted_values(original, filtered)
      case filtered
      when Hash
        filtered.each_with_object(filtered.class.new) do |(key, val), result|
          if whitelisted?(key)
            result[key] = original.is_a?(Hash) ? original[key] : original
          else
            next_original = original.is_a?(Hash) ? original[key] : nil
            result[key] = restore_whitelisted_values(next_original, val)
          end
        end
      when Array
        filtered.each_with_index.map do |val, idx|
          next_original = original.is_a?(Array) ? original[idx] : nil
          restore_whitelisted_values(next_original, val)
        end
      else
        filtered
      end
    end

    def randomize_masks(value)
      case value
      when Hash
        value.transform_values { |v| randomize_masks(v) }
      when Array
        value.map { |v| randomize_masks(v) }
      when String
        value == MASK ? random_mask(value) : value
      else
        value
      end
    end
  end
end
