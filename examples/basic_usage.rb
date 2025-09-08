# frozen_string_literal: true

require_relative '../lib/lapsoss'

# Basic error tracking setup
Lapsoss.configure do |config|
  config.use_logger
  config.async = true
end

# Capture an exception
begin
  1 / 0
rescue StandardError => e
  Lapsoss.capture_exception(e)
end

# Capture a message
Lapsoss.capture_message('Application started', level: :info)
