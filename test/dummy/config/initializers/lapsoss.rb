# frozen_string_literal: true

# Lapsoss configuration for the dummy application
Lapsoss.configure do |config|
  # Enable async processing for better performance
  config.async = true

  # Always use logger adapter for testing
  config.use_logger(level: :info)

  # Configure sampling
  config.sample_rate = 1.0

  # Configure debug mode for development
  config.debug = Rails.env.development?

  # Configure Telebugs if DSN is available
  if ENV["TELEBUGS_DSN"].present?
    config.use_telebugs(
      name: :telebugs,
      dsn: ENV["TELEBUGS_DSN"]
    )
  end

  # Configure Sentry US if DSN is available
  if ENV["SENTRY_US_DSN"].present?
    config.use_sentry(
      name: :sentry_us,
      dsn: ENV["SENTRY_US_DSN"]
    )
  end

  # Configure Sentry EU if DSN is available
  if ENV["SENTRY_EU_DSN"].present?
    config.use_sentry(
      name: :sentry_eu,
      dsn: ENV["SENTRY_EU_DSN"]
    )
  end

  # DRb agent configuration (optional)
  # config.use_agent = true
  # config.agent_uri = 'druby://localhost:9000'
end
