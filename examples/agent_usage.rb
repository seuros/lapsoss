# frozen_string_literal: true

require_relative '../lib/lapsoss'

# DRb Agent setup for multi-process applications
# Consolidates HTTP connections and provides better resource efficiency

# First, start the agent process:
# $ lapsoss agent start

# Then configure your application to use the agent:
Lapsoss.configure do |config|
  # Enable DRb agent
  config.use_agent = true
  config.agent_uri = 'druby://localhost:9000'
  config.agent_fallback = true # Fall back to direct dispatch if agent unavailable

  # Configure adapters (handled by agent process)
  config.use_sentry(dsn: ENV['SENTRY_DSN']) if ENV['SENTRY_DSN']
  config.use_rollbar(access_token: ENV['ROLLBAR_ACCESS_TOKEN']) if ENV['ROLLBAR_ACCESS_TOKEN']
end

# Usage is exactly the same - the agent handles the complexity
begin
  raise 'Test error for agent'
rescue StandardError => e
  Lapsoss.capture_exception(e)
end

# Benefits:
# - 20 Falcon processes → 1 agent with 3 HTTP clients instead of 60
# - Centralized rate limiting and retry logic
# - Better behavior towards external services
# - Automatic fallback if agent is unavailable
