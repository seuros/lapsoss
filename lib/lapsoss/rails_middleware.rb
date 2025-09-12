# frozen_string_literal: true

module Lapsoss
  class RailsMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      Lapsoss::Current.with_clean_scope do
        # Add request context to current scope
        if Lapsoss.configuration.capture_request_context
          Rails.logger.tagged("Lapsoss") { Rails.logger.debug "Adding request context" } if Rails.env.test?
          add_request_context(env)
        end

        begin
          @app.call(env)
        rescue Exception => e
          Rails.logger.info "[LAPSOSS MIDDLEWARE] Capturing exception: #{e.class} - #{e.message}"
          # Capture the exception
          result = Lapsoss.capture_exception(e)
          Rails.logger.info "[LAPSOSS MIDDLEWARE] Capture result: #{result.inspect}"
          # Re-raise the exception to maintain Rails error handling
          raise
        end
      end
    end

    private

    def add_request_context(env)
      request = Rack::Request.new(env)

      return unless Lapsoss::Current.scope

      Lapsoss::Current.scope.set_context("request", {
                                           method: request.request_method,
                                           url: request.url,
                                           path: request.path,
                                           query_string: request.query_string,
                                           headers: extract_headers(env),
                                           ip: request.ip,
                                           user_agent: request.user_agent,
                                           referer: request.referer,
                                           request_id: env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
                                         })

      # Add user context if available
      return unless env["warden"]&.user

      user = env["warden"].user
      Lapsoss::Current.scope.set_user(
        id: user.id,
        email: user.respond_to?(:email) ? user.email : nil
      )
    end

    def extract_headers(env)
      headers = {}

      env.each do |key, value|
        if key.start_with?("HTTP_") && FILTERED_HEADERS.exclude?(key)
          header_name = key.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-")
          headers[header_name] = value
        end
      end

      headers
    end

    FILTERED_HEADERS = %w[
      HTTP_AUTHORIZATION
      HTTP_COOKIE
      HTTP_X_API_KEY
      HTTP_X_AUTH_TOKEN
    ].freeze
  end
end
