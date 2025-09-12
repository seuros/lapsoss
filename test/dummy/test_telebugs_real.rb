#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to verify Telebugs actually receives events

require_relative "config/environment"
require "vcr"

# Configure VCR to record the actual HTTP request
VCR.configure do |config|
  config.cassette_library_dir = "tmp/vcr_cassettes"
  config.hook_into :webmock
  config.default_cassette_options = {
    record: :new_episodes,
    match_requests_on: %i[method uri]
  }
end

# Clear and reconfigure Lapsoss
Lapsoss::Registry.instance.clear!
Lapsoss.instance_variable_set(:@configuration, nil)
Lapsoss::Current.reset

Lapsoss.configure do |config|
  config.async = false  # Sync for testing
  config.enabled = true

  if ENV["TELEBUGS_DSN"]
    puts "Configuring Telebugs with DSN: #{ENV["TELEBUGS_DSN"]}"
    config.use_telebugs(
      name: :telebugs,
      dsn: ENV["TELEBUGS_DSN"]
    )
  end
end

puts "Active adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

# Record the HTTP request
VCR.use_cassette("telebugs_real_test") do
  begin
    raise StandardError, "Real test error for Telebugs at #{Time.now}"
  rescue => e
    result = Lapsoss.capture_exception(e)
    puts "Capture result types: #{result.map(&:class).join(', ')}"

    # Check if Telebugs adapter captured it
    telebugs_adapter = Lapsoss::Registry.instance[:telebugs]
    if telebugs_adapter
      puts "Telebugs adapter found and enabled: #{telebugs_adapter.enabled?}"
    else
      puts "Telebugs adapter not found!"
    end
  end
end

puts "Check tmp/vcr_cassettes/telebugs_real_test.yml for the recorded HTTP request"
