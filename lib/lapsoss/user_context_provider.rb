# frozen_string_literal: true

module Lapsoss
  # User context provider that integrates with various authentication systems
  class UserContextProvider
    def initialize(providers: {})
      @providers = providers
    end

    def get_user_context(event, hint = {})
      context = {}

      # Try each provider in order
      @providers.each do |name, provider|
        if provider_context = provider.call(event, hint)
          context.merge!(provider_context)
        end
      rescue StandardError => e
        # Log provider error but don't fail
        warn "User context provider #{name} failed: #{e.message}"
      end

      context
    end

    # Built-in providers for common authentication systems
    def self.devise_provider
      lambda do |_event, hint|
        return {} unless defined?(Devise) && defined?(Warden)

        # Try to get user from Warden (used by Devise)
        if request = hint[:request]
          user = request.env["warden"]&.user
          return {} unless user

          {
            id: user.id,
            email: user.email,
            username: user.respond_to?(:username) ? user.username : nil,
            created_at: user.created_at,
            role: user.respond_to?(:role) ? user.role : nil
          }.compact
        end

        {}
      end
    end

    def self.omniauth_provider
      lambda do |_event, hint|
        return {} unless defined?(OmniAuth)

        if (request = hint[:request]) && (auth_info = request.env["omniauth.auth"])
          {
            provider: auth_info["provider"],
            uid: auth_info["uid"],
            name: auth_info.dig("info", "name"),
            email: auth_info.dig("info", "email"),
            username: auth_info.dig("info", "nickname")
          }.compact
        end

        {}
      end
    end

    def self.session_provider
      lambda do |_event, hint|
        return {} unless hint[:request]

        request = hint[:request]
        session = begin
          request.session
        rescue StandardError
          {}
        end

        {
          session_id: session[:session_id] || session["session_id"],
          user_id: session[:user_id] || session["user_id"],
          csrf_token: session[:_csrf_token] || session["_csrf_token"]
        }.compact
      end
    end

    def self.thread_local_provider
      lambda do |_event, _hint|
        # Get user from thread-local storage
        Thread.current[:current_user] || {}
      end
    end
  end
end
