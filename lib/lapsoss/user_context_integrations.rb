# frozen_string_literal: true

module Lapsoss
  # Integration with popular authentication gems
  module UserContextIntegrations
    def self.setup_devise_integration
      return unless defined?(Devise)

      # Add middleware to capture user context
      Rails.application.config.middleware.use(UserContextMiddleware) if defined?(Rails)
    end

    def self.setup_clearance_integration
      return unless defined?(Clearance)

      # Clearance integration
      return unless defined?(Rails)

      Rails.application.config.middleware.use(UserContextMiddleware) do |middleware|
        middleware.user_provider = lambda do |request|
          request.env[:clearance].current_user if request.env[:clearance]
        end
      end
    end

    def self.setup_authlogic_integration
      return unless defined?(Authlogic)

      # Authlogic integration
      return unless defined?(Rails)

      Rails.application.config.middleware.use(UserContextMiddleware) do |middleware|
        middleware.user_provider = lambda do |_request|
          UserSession.find&.user if defined?(UserSession)
        end
      end
    end
  end
end
