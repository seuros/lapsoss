# frozen_string_literal: true

module Lapsoss
  # Predefined exclusion configurations for common use cases
  class ExclusionPresets
    def self.development
      {
        excluded_exceptions: [
          # Test-related exceptions
          "RSpec::Expectations::ExpectationNotMetError",
          "Minitest::Assertion",

          # Development tools
          "Pry::CommandError",
          "Byebug::CommandError"
        ],
        excluded_patterns: [
          /test/i,
          /spec/i,
          /debug/i,
          /development/i
        ],
        excluded_environments: %w[test]
      }
    end

    def self.production
      {
        excluded_exceptions: [
          # Common Rails exceptions that are usually not actionable
          "ActionController::RoutingError",
          "ActionController::UnknownFormat",
          "ActionController::BadRequest",
          "ActionController::ParameterMissing",

          # ActiveRecord exceptions for common user errors
          "ActiveRecord::RecordNotFound",
          "ActiveRecord::RecordInvalid",

          # Network timeouts that are expected
          "Net::ReadTimeout",
          "Net::OpenTimeout",
          "Timeout::Error"
        ],
        excluded_patterns: [
          # Bot and crawler patterns
          /bot/i,
          /crawler/i,
          /spider/i,
          /scraper/i,

          # Security scanning patterns
          /sql.*injection/i,
          /xss/i,
          /csrf/i,

          # Common attack patterns
          /\.php$/i,
          /\.asp$/i,
          /wp-admin/i,
          /wp-login/i
        ],
        excluded_messages: [
          # Common spam/attack messages
          "No route matches",
          "Invalid authenticity token",
          "Forbidden",
          "Unauthorized"
        ]
      }
    end

    def self.staging
      {
        excluded_exceptions: [
          # Test data related errors
          "ActiveRecord::RecordNotFound",
          "ArgumentError"
        ],
        excluded_patterns: [
          /test/i,
          /staging/i,
          /dummy/i,
          /fake/i
        ],
        excluded_environments: %w[test development]
      }
    end

    def self.security_focused
      {
        excluded_patterns: [
          # Exclude common security scanning attempts
          /\.php$/i,
          /\.asp$/i,
          /\.jsp$/i,
          /wp-admin/i,
          /wp-login/i,
          /phpmyadmin/i,
          /admin/i,
          /login\.php/i,
          /index\.php/i,

          # SQL injection attempts
          /union.*select/i,
          /insert.*into/i,
          /drop.*table/i,
          /delete.*from/i,

          # XSS attempts
          /<script/i,
          /javascript:/i,
          /onclick=/i,
          /onerror=/i
        ],
        excluded_messages: [
          "Invalid authenticity token",
          "Forbidden",
          "Unauthorized",
          "Access denied"
        ],
        custom_filters: [
          # Exclude requests from known bot user agents
          lambda do |event|
            user_agent = event.context.dig(:request, :headers, "User-Agent")
            return false unless user_agent

            bot_patterns = [
              /googlebot/i,
              /bingbot/i,
              /slurp/i,
              /crawler/i,
              /spider/i,
              /bot/i
            ]

            bot_patterns.any? { |pattern| user_agent.match?(pattern) }
          end
        ]
      }
    end

    def self.performance_focused
      {
        excluded_exceptions: [
          # Timeout exceptions that are expected under load
          "Net::ReadTimeout",
          "Net::OpenTimeout",
          "Timeout::Error",
          "Redis::TimeoutError",

          # Memory and resource limits
          "NoMemoryError",
          "SystemStackError"
        ],
        excluded_patterns: [
          /timeout/i,
          /memory/i,
          /resource/i,
          /limit/i
        ],
        custom_filters: [
          # Exclude high-frequency errors during peak times
          lambda do |event|
            now = Time.zone.now
            peak_hours = (9..17).cover?(now.hour) && (1..5).cover?(now.wday)

            if peak_hours
              # During peak hours, exclude common performance-related errors
              return true if event.exception.is_a?(Timeout::Error)
              return true if event.exception.message.match?(/timeout/i)
            end

            false
          end
        ]
      }
    end

    def self.user_error_focused
      {
        excluded_exceptions: [
          # User input validation errors
          "ActiveModel::ValidationError",
          "ActiveRecord::RecordInvalid",
          "ActionController::ParameterMissing",
          "ArgumentError",
          "TypeError"
        ],
        excluded_patterns: [
          /validation/i,
          /invalid/i,
          /missing/i,
          /required/i,
          /format/i
        ],
        custom_filters: [
          # Exclude errors from invalid user input
          lambda do |event|
            return false unless event.exception

            # Check if error is from user input validation
            message = event.exception.message.downcase
            validation_keywords = %w[invalid required missing format validation]

            validation_keywords.any? { |keyword| message.include?(keyword) }
          end
        ]
      }
    end

    def self.combined(presets)
      combined_config = {
        excluded_exceptions: [],
        excluded_patterns: [],
        excluded_messages: [],
        excluded_environments: [],
        custom_filters: []
      }

      presets.each do |preset|
        config = case preset
        when :development then development
        when :production then production
        when :staging then staging
        when :security_focused then security_focused
        when :performance_focused then performance_focused
        when :user_error_focused then user_error_focused
        when Hash then preset
        else raise ArgumentError, "Unknown preset: #{preset}"
        end

        combined_config[:excluded_exceptions].concat(config[:excluded_exceptions] || [])
        combined_config[:excluded_patterns].concat(config[:excluded_patterns] || [])
        combined_config[:excluded_messages].concat(config[:excluded_messages] || [])
        combined_config[:excluded_environments].concat(config[:excluded_environments] || [])
        combined_config[:custom_filters].concat(config[:custom_filters] || [])
      end

      # Remove duplicates
      combined_config[:excluded_exceptions].uniq!
      combined_config[:excluded_patterns].uniq!
      combined_config[:excluded_messages].uniq!
      combined_config[:excluded_environments].uniq!

      combined_config
    end
  end
end
