# frozen_string_literal: true

module Lapsoss
  class Railtie < Rails::Railtie
    # Debug logging removed - will be handled by the configured logger
    config.lapsoss = ActiveSupport::OrderedOptions.new

    initializer "lapsoss.configure" do |_app|
      Lapsoss.configure do |config|
        # Use rails_app_version gem if available, otherwise fallback to Rails defaults
        config.environment ||= if Rails.application.respond_to?(:env)
                                 Rails.application.env
        else
                                 Rails.env
        end

        # Use Rails logger if available
        config.logger ||= Rails.logger

        # Set debug level in development
        config.debug = Rails.env.development?

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


    initializer "lapsoss.rails_error_subscriber" do |app|
      Rails.error.subscribe(Lapsoss::RailsErrorSubscriber.new)
    end

    initializer "lapsoss.controller_transaction" do
      ActiveSupport.on_load(:action_controller) do
        require "lapsoss/rails_controller_transaction"
        include Lapsoss::RailsControllerTransaction
      end
    end
  end
end
