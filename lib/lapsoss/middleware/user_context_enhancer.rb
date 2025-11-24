# frozen_string_literal: true

module Lapsoss
  module Middleware
    # Adds user info to the event context using a callable provider.
    class UserContextEnhancer < Base
      def initialize(app, user_provider:, privacy_mode: false)
        super(app)
        @user_provider = user_provider
        @privacy_mode = privacy_mode
      end

      def call(event, hint = {})
        user_data = fetch_user(event, hint)
        return @app.call(event, hint) unless user_data

        merged_user = (event.context[:user] || {}).merge(user_data)
        merged_user = sanitize_for_privacy(merged_user) if @privacy_mode

        updated_context = event.context.merge(user: merged_user)
        @app.call(event.with(context: updated_context), hint)
      end

      private

      def fetch_user(event, hint)
        return nil unless @user_provider

        if @user_provider.respond_to?(:call)
          @user_provider.call(event, hint)
        elsif @user_provider.is_a?(Hash)
          @user_provider
        end
      rescue StandardError
        nil
      end

      def sanitize_for_privacy(user_hash)
        allowed_keys = %i[id uuid user_id]
        user_hash.slice(*allowed_keys)
      end
    end
  end
end
