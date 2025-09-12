#!/usr/bin/env ruby
# frozen_string_literal: true

# Load environment variables first
require "dotenv"
Dotenv.load

require_relative "config/environment"

puts "=" * 60
puts "Debugging Telebugs Adapter Issue"
puts "=" * 60

# Check what's registered
puts "\nRegistry Debug:"
registry = Lapsoss::Registry.instance
puts "  All adapters: #{registry.instance_variable_get(:@adapters).keys}"
puts "  Active adapters: #{registry.active.map(&:name)}"

# Check telebugs specifically
telebugs = registry[:telebugs]
if telebugs
  puts "\nTelebugs Adapter Debug:"
  puts "  Class: #{telebugs.class}"
  puts "  Name: #{telebugs.name}"
  puts "  Enabled: #{telebugs.enabled?}"
  puts "  Settings: #{telebugs.instance_variable_get(:@settings)}"
  puts "  DSN parsed: #{telebugs.instance_variable_get(:@dsn)}"
  puts "  Endpoint: #{telebugs.class.api_endpoint}"
  puts "  API Path: #{telebugs.class.api_path}"
else
  puts "\n❌ Telebugs adapter NOT found in registry!"
end

puts "\n" + "=" * 40
puts "Testing Direct Telebugs Capture"
puts "=" * 40

begin
  raise StandardError, "Debug test error at #{Time.now}"
rescue => e
  puts "\nCapturing exception directly to test telebugs..."

  # Test the telebugs adapter directly
  if telebugs&.enabled?
    puts "Calling telebugs.capture directly..."
    begin
      result = telebugs.capture(Lapsoss::Event.build(
        type: :exception,
        level: :error,
        exception: e,
        context: {},
        transaction: "DebugTest#direct_capture"
      ))
      puts "Direct capture result: #{result.inspect}"
    rescue => capture_error
      puts "Direct capture failed: #{capture_error.message}"
      puts capture_error.backtrace.first(3).join("\n")
    end
  end

  # Test through Lapsoss client
  puts "\nTesting through Lapsoss.capture_exception..."
  result = Lapsoss.capture_exception(e)
  puts "Client capture result: #{result.inspect}"

  # Wait for async thread to complete
  puts "Waiting 3 seconds for async processing..."
  sleep 3
  puts "Should see Telebugs debug logs above if capture was called"
end

puts "\n" + "=" * 60
puts "Debug Complete"
puts "=" * 60
