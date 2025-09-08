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

  # DRb agent configuration (optional)
  # config.use_agent = true
  # config.agent_uri = 'druby://localhost:9000'
end
