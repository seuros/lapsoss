#!/usr/bin/env ruby
# Test script to verify Telebugs receives events

require_relative "config/environment"

# Configure with both logger and Telebugs
Lapsoss.configure do |config|
  config.async = false  # Sync for testing
  config.use_logger(level: :info)

  if ENV["TELEBUGS_DSN"]
    config.use_telebugs(
      name: :telebugs,
      dsn: ENV["TELEBUGS_DSN"]
    )
  end
end

puts "Registered adapters: #{Lapsoss::Registry.instance.all.map(&:name).join(', ')}"
puts "Active adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

# Check each adapter's enabled status
Lapsoss::Registry.instance.all.each do |adapter|
  puts "Adapter #{adapter.name}: enabled=#{adapter.enabled?}"
end

# Test capturing an exception
begin
  raise StandardError, "Test error for multi-provider dispatch"
rescue => e
  result = Lapsoss.capture_exception(e)
  puts "Capture result: #{result.inspect}"
end

puts "Test completed"
