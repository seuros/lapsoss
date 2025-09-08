# frozen_string_literal: true

module Lapsoss
  # Configuration helper for exclusions
  module ExclusionConfiguration
    def self.configure_exclusions(config, preset: nil, **custom_config)
      exclusion_config = if preset
                           case preset
                           when Array
                             ExclusionPresets.combined(preset)
                           else
                             ExclusionPresets.send(preset)
                           end
      else
                           {}
      end

      # Merge custom configuration
      exclusion_config.merge!(custom_config)

      # Create exclusion filter
      exclusion_filter = ExclusionFilter.new(exclusion_config)

      # Add to configuration
      config.exclusion_filter = exclusion_filter

      exclusion_filter
    end
  end
end
