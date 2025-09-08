# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/hash/indifferent_access"

module Lapsoss
  module Adapters
    module Concerns
      module LevelMapping
        extend ActiveSupport::Concern

        # Single source of truth for level mappings
        LEVEL_MAPPINGS = {
          sentry: {
            debug: "debug",
            info: "info",
            warn: "warning",
            warning: "warning",
            error: "error",
            fatal: "fatal"
          }.with_indifferent_access,

          rollbar: {
            debug: "debug",
            info: "info",
            warning: "warning",
            error: "error",
            fatal: "critical"
          }.with_indifferent_access,

          bugsnag: {
            debug: "info",
            info: "info",
            warning: "warning",
            error: "error",
            fatal: "error"
          }.with_indifferent_access,

          appsignal: {
            debug: "debug",
            info: "info",
            warning: "warning",
            error: "error",
            fatal: "error",
            critical: "error"
          }.with_indifferent_access
        }.freeze

        included do
          # Define which mapping this adapter uses
          class_attribute :level_mapping_type, default: :sentry
        end

        # Map level using the adapter's configured mapping
        def map_level(level)
          mapping = LEVEL_MAPPINGS[self.class.level_mapping_type]
          mapping[level] || mapping[:info]
        end

        # Map severity (alias for bugsnag compatibility)
        alias_method :map_severity, :map_level
      end
    end
  end
end
