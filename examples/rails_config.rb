# frozen_string_literal: true

# config/initializers/lapsoss.rb

Lapsoss.configure do |config|
  # Use environment-based adapter selection
  if Rails.env.production?
    config.use_sentry(dsn: ENV.fetch('SENTRY_DSN', nil))
  else
    config.use_logger
  end

  # Async processing for better performance
  config.async = true

  # Sample rate (1.0 = 100%, 0.1 = 10%)
  config.sample_rate = 1.0
end
