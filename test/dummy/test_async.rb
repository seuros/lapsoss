#!/usr/bin/env ruby
# frozen_string_literal: true

# Load environment variables first
require "dotenv"
Dotenv.load

require_relative "config/environment"

puts "=" * 60
puts "Testing Lapsoss Async Mode"
puts "=" * 60

# Verify configuration
puts "\nConfiguration:"
puts "  Async: #{Lapsoss.configuration.async}"
puts "  Adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

# Test 1: Sync mode
puts "\n" + "=" * 40
puts "TEST 1: Synchronous Mode"
puts "=" * 40

original_async = Lapsoss.configuration.instance_variable_get(:@async)
Lapsoss.configuration.instance_variable_set(:@async, false)

begin
  raise StandardError, "Sync test error at #{Time.now}"
rescue => e
  puts "Capturing sync exception..."
  result = Lapsoss.capture_exception(e)
  puts "Result: #{result.inspect}"
end

Lapsoss.configuration.instance_variable_set(:@async, original_async)

# Give time for any output
sleep 1

# Test 2: Async with direct Thread
puts "\n" + "=" * 40
puts "TEST 2: Async Mode with Direct Thread"
puts "=" * 40

begin
  raise StandardError, "Async test error at #{Time.now}"
rescue => e
  puts "Capturing async exception..."
  result = Lapsoss.capture_exception(e)
  puts "Result: #{result.inspect}"

  puts "Waiting for async processing..."
  sleep 2

  puts "Flushing..."
  Lapsoss.flush(timeout: 5)
end

puts "\n" + "=" * 60
puts "Test Complete"
puts "Check Telebugs dashboard for events"
puts "=" * 60
