# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "socket"

module Lapsoss
  module Adapters
    class RollbarAdapter < Base
      include Concerns::LevelMapping
      include Concerns::EnvelopeBuilder
      include Concerns::HttpDelivery

      self.level_mapping_type = :rollbar
      DEFAULT_API_ENDPOINT = "https://api.rollbar.com"
      DEFAULT_API_PATH = "/api/1/item/"

      def initialize(name, settings = {})
        super
        @api_endpoint = DEFAULT_API_ENDPOINT
        @api_path = DEFAULT_API_PATH
        @access_token = settings[:access_token].presence || ENV["ROLLBAR_ACCESS_TOKEN"]

        if @access_token.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss::RollbarAdapter] No access token provided, adapter disabled"
          @enabled = false
        else
          validate_api_key!(@access_token, "Rollbar access token", format: :alphanumeric)
        end
      end

      def capture(event)
        deliver(event.scrubbed)
      end

      def capabilities
        super.merge(
          breadcrumbs: true,
          user_tracking: true,
          custom_context: true,
          release_tracking: true
        )
      end

      private

      def build_payload(event)
        {
          access_token: @access_token,
          data: build_rollbar_data(event)
        }
      end

      def build_rollbar_data(event)
        {
          environment: event.environment.presence || @settings[:environment] || "production",
          body: build_rollbar_body(event),
          level: map_level(event.level),
          timestamp: event.timestamp.to_i,
          code_version: @settings[:release].presence || git_sha,
          platform: "ruby",
          language: "ruby",
          framework: detect_framework,
          server: {
            host: Socket.gethostname,
            root: Rails.root.to_s.presence || Dir.pwd,
            branch: git_branch,
            code_version: git_sha
          }.compact_blank,
          person: build_person_data(event),
          request: event.request_context,
          custom: event.extra
        }.compact_blank
      end

      def build_rollbar_body(event)
        case event.type
        in :exception if event.has_exception?
          {
            trace: {
              frames: format_backtrace_frames(event),
              exception: {
                class: event.exception_type,
                message: event.exception_message,
                description: event.exception.to_s
              }
            }
          }
        in :message
          {
            message: {
              body: event.message
            }
          }
        else
          { message: { body: event.message || "Unknown event" } }
        end
      end

      def format_backtrace_frames(event)
        return [] unless event.has_backtrace?

        # Rollbar expects frames in reverse order
        event.backtrace_frames.map do |frame|
          {
            filename: frame.filename,
            lineno: frame.lineno,
            method: frame.method_name,
            code: frame.code_context && frame.code_context[:context_line]
          }.compact_blank
        end.reverse
      end

      def build_person_data(event)
        user = event.user_context
        return nil if user.blank?

        {
          id: user[:id]&.to_s,
          username: user[:username],
          email: user[:email]
        }.compact_blank.presence
      end

      def detect_framework
        return "rails" if defined?(Rails)
        return "sinatra" if defined?(Sinatra)
        "ruby"
      end

      def adapter_specific_headers
        { "X-Rollbar-Access-Token" => @access_token }
      end

      # No longer need strict validation
      def validate_settings!
        # Validation moved to initialize with logging
      end
    end
  end
end
