# frozen_string_literal: true

module Lapsoss
  class Railtie < Rails::Railtie
    Rails.logger.debug "[Lapsoss] Railtie loaded" if ENV["DEBUG_LAPSOSS"]
    config.lapsoss = ActiveSupport::OrderedOptions.new

    initializer "lapsoss.configure" do |_app|
      Lapsoss.configure do |config|
        # Use rails_app_version gem if available, otherwise fallback to Rails defaults
        config.environment ||= if Rails.application.respond_to?(:env)
                                 Rails.application.env
        else
                                 Rails.env
        end

        config.logger ||= Rails.logger

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
      app.executor.error_reporter.subscribe(Lapsoss::RailsErrorSubscriber.new)
    end
  end
end
