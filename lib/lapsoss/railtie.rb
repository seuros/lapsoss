# frozen_string_literal: true

module Lapsoss
  class Railtie < Rails::Railtie
    if ENV["DEBUG_LAPSOSS"]
      if Rails.logger.respond_to?(:tagged)
        Rails.logger.tagged("Lapsoss") { Rails.logger.debug "Railtie loaded" }
      else
        Rails.logger.debug "[Lapsoss] Railtie loaded"
      end
    end
    config.lapsoss = ActiveSupport::OrderedOptions.new

    initializer "lapsoss.configure" do |_app|
      Lapsoss.configure do |config|
        # Use rails_app_version gem if available, otherwise fallback to Rails defaults
        config.environment ||= if Rails.application.respond_to?(:env)
                                 Rails.application.env
        else
                                 Rails.env
        end

        # Use tagged logger for all Lapsoss logs
        config.logger ||= if Rails.logger.respond_to?(:tagged)
                            Rails.logger.tagged("Lapsoss")
        else
                            ActiveSupport::TaggedLogging.new(Rails.logger).tagged("Lapsoss")
        end

        config.release ||= if Rails.application.respond_to?(:version)
                             Rails.application.version.to_s
        else
                             Rails.application.config.try(:release)
        end

        # Set default tags
        config.default_tags = {
          rails_env: config.environment,
          rails_version: Rails.version
        }
      end
    end

    initializer "lapsoss.add_middleware" do |app|
      require "lapsoss/rails_middleware"

      # Use config.middleware to ensure it's added during initialization
      app.config.middleware.use Lapsoss::RailsMiddleware
    end

    initializer "lapsoss.rails_error_subscriber", after: "lapsoss.add_middleware" do |app|
      Rails.error.subscribe(Lapsoss::RailsErrorSubscriber.new)
    end
  end
end
