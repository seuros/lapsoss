# frozen_string_literal: true

require_relative '../lib/lapsoss'

# Multi-adapter setup for vendor migration
Lapsoss.configure do |config|
  # Logger for local backup
  config.use_logger

  # Sentry for production monitoring
  config.use_sentry(dsn: ENV['SENTRY_DSN']) if ENV['SENTRY_DSN']

  # Rollbar for alerts
  config.use_rollbar(access_token: ENV['ROLLBAR_ACCESS_TOKEN']) if ENV['ROLLBAR_ACCESS_TOKEN']
end

# All adapters receive this error
begin
  raise 'Multi-adapter test error'
rescue StandardError => e
  Lapsoss.capture_exception(e)
end
