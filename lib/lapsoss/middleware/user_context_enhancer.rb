# frozen_string_literal: true

module Lapsoss
  module Middleware
    class UserContextEnhancer < Base
      def initialize(app, user_provider: nil, privacy_mode: false)
        super(app)
        @user_provider = user_provider
        @privacy_mode = privacy_mode
      end

      def call(event, hint = {})
        enhance_user_context(event, hint)
        @app.call(event, hint)
      end

      private

      def enhance_user_context(event, hint)
        # Get user from provider if available
        user_data = @user_provider&.call(event, hint) || {}

        # Merge with existing user context
        existing_user = event.context[:user] || {}
        enhanced_user = existing_user.merge(user_data)

        # Apply privacy filtering if enabled
        enhanced_user = apply_privacy_filtering(enhanced_user) if @privacy_mode

        event.context[:user] = enhanced_user unless enhanced_user.empty?
      end

      def apply_privacy_filtering(user_data)
        # Remove sensitive fields in privacy mode
        sensitive_fields = %i[email phone address ssn credit_card]
        filtered = user_data.dup

        sensitive_fields.each do |field|
          filtered[field] = "[FILTERED]" if filtered.key?(field)
        end

        filtered
      end
    end
  end
end
