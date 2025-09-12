#!/usr/bin/env ruby
# frozen_string_literal: true

# Load environment variables first
require "dotenv"
Dotenv.load

require_relative "config/environment"

puts "=" * 60
puts "Final Lapsoss Test - Multi-Provider Dispatch"
puts "=" * 60

# Verify configuration
puts "\nConfiguration:"
puts "  Async mode: #{Lapsoss.configuration.async}"
puts "  Debug mode: #{Lapsoss.configuration.debug}"
puts "  Registered adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

# Check Telebugs specifically
telebugs = Lapsoss::Registry.instance[:telebugs]
if telebugs
  puts "  Telebugs: REGISTERED ✓"
  puts "    - DSN configured: #{telebugs.instance_variable_get(:@dsn).present? ? 'Yes' : 'No'}"
else
  puts "  Telebugs: NOT REGISTERED ✗"
end

puts "\n" + "=" * 40
puts "Testing Exception Capture"
puts "=" * 40

begin
  raise StandardError, "Final test error at #{Time.now}"
rescue => e
  puts "\nCapturing exception..."
  result = Lapsoss.capture_exception(e, tags: { test: "final" })
  puts "Capture result: #{result.class.name}"

  # Give async threads time to complete
  puts "Waiting for async processing..."
  sleep 2
end

puts "\n" + "=" * 60
puts "Test Complete!"
puts "You should see:"
puts "  1. Error logged to console (logger adapter)"
puts "  2. Error sent to Telebugs (check dashboard)"
puts "=" * 60
