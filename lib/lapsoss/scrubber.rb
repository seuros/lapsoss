# frozen_string_literal: true

require "active_support/parameter_filter"

module Lapsoss
  class Scrubber
    # Match Rails conventions - these are only used when Rails is not available
    # Rails uses partial matching, so 'passw' matches 'password'
    DEFAULT_SCRUB_FIELDS = %i[
      passw email secret token _key crypt salt certificate otp ssn cvv cvc
    ].freeze

    def initialize(config = {})
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

      @filter = ActiveSupport::ParameterFilter.new(filter_params)
    end

    def scrub(data)
      return data if data.nil?
      @filter.filter(data)
    end
  end
end
