# frozen_string_literal: true

module Lapsoss
  module Middleware
    class ReleaseTracker < Base
      def initialize(app, release: nil)
        super(app)
        @release = release
      end

      def call(event, hint = {})
        if release = detect_release
          event.context[:release] = release
        end
        @app.call(event, hint)
      end

      private

      def detect_release
        # Use configured release
        return @release.call if @release.respond_to?(:call)
        return @release if @release.present?

        # Use rails_app_version gem if available
        Rails.application.version.to_s if defined?(Rails) && Rails.application.respond_to?(:version)
      end
    end
  end
end
