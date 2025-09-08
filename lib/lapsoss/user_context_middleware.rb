# frozen_string_literal: true

module Lapsoss
  # Middleware to automatically capture user context
  class UserContextMiddleware
    def initialize(app, user_provider: nil)
      @app = app
      @user_provider = user_provider
    end

    def call(env)
      request = Rack::Request.new(env)

      # Capture user context
      user_context = extract_user_context(request)

      # Store in thread-local for access during request processing
      Thread.current[:lapsoss_user_context] = user_context

      @app.call(env)
    ensure
      Thread.current[:lapsoss_user_context] = nil
    end

    private

    def extract_user_context(request)
      if @user_provider
        user = @user_provider.call(request)
        return {} unless user

        context = {
          id: user.id,
          email: user.email,
          username: user.respond_to?(:username) ? user.username : nil
        }

        # Add role information if available
        context[:role] = user.role if user.respond_to?(:role)

        # Add plan information if available
        context[:plan] = user.plan if user.respond_to?(:plan)

        context.compact
      else
        {}
      end
    end
  end
end
