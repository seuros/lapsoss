# frozen_string_literal: true

require_relative "rails_test_helper"
require "json"

class SentryCodeContextTest < ActionDispatch::IntegrationTest
  setup do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
  end

  test "captures code context from dummy app controller" do
    captured_payloads = []

    # Mock the HTTP client to capture the actual payload
    mock_http_client = Class.new do
      attr_reader :captured_payloads

      def initialize(captured_payloads)
        @captured_payloads = captured_payloads
      end

      def post(path, body:, headers:)
        # Parse the envelope format
        lines = body.split("\n")

        # Sentry envelope format:
        # Line 0: Envelope header (JSON)
        # Line 1: Item header (JSON)
        # Line 2: Item payload (JSON event)
        if lines.size >= 3
          event_json = lines[2]
          @captured_payloads << JSON.parse(event_json)
        end

        # Return a successful response
        OpenStruct.new(status: 200, code: 200, body: '{"id":"test"}')
      end
    end

    # Configure Lapsoss with a test Sentry DSN
    Lapsoss.configure do |config|
      config.async = false # Synchronous for testing
      config.debug = true
      config.capture_request_context = true
      config.backtrace_enable_code_context = true
      config.backtrace_context_lines = 3
      config.use_sentry(
        name: :sentry_test,
        dsn: "https://test@sentry.io/123456"
      )
      config.apply! # Apply the configuration
    end

    # Get the adapter and replace its HTTP client
    adapter = Lapsoss::Registry.instance[:sentry_test]
    assert adapter, "Adapter should be registered"

    mock_client = mock_http_client.new(captured_payloads)
    adapter.instance_variable_set(:@http_client, mock_client)

    # Trigger an error from the dummy app controller
    # The middleware should capture it
    assert_raises(StandardError) do
      get "/error"
    end

    # Wait briefly for processing
    sleep(0.2)

    # Verify the payload was captured
    assert_equal 1, captured_payloads.size, "Expected one event to be captured"

    event = captured_payloads.first
    assert event, "Event should not be nil"

    # Check the exception details
    exception_values = event.dig("exception", "values")
    assert exception_values, "Should have exception values"
    assert_equal 1, exception_values.size

    exception = exception_values.first
    assert_equal "StandardError", exception["type"]
    assert_equal "Test error for Lapsoss", exception["value"]

    # Check the stacktrace
    stacktrace = exception.dig("stacktrace", "frames")
    assert stacktrace, "Should have stacktrace frames"
    assert stacktrace.size > 0, "Should have at least one frame"

    # Find the frame from application_controller.rb
    app_controller_frame = stacktrace.find do |frame|
      frame["filename"]&.include?("application_controller.rb")
    end

    assert app_controller_frame, "Should have a frame from application_controller.rb"

    # Verify the frame has the expected line number
    assert_equal 9, app_controller_frame["lineno"], "Error should be on line 9"
    assert app_controller_frame["function"].include?("error"), "Function should include 'error'"

    # **CRITICAL**: Verify code context is present
    assert app_controller_frame["context_line"], "Should have context_line"
    assert_match(/raise StandardError/, app_controller_frame["context_line"],
                 "Context line should contain the raise statement")

    assert app_controller_frame["pre_context"], "Should have pre_context"
    assert app_controller_frame["pre_context"].is_a?(Array), "pre_context should be an array"
    assert app_controller_frame["pre_context"].size > 0, "pre_context should not be empty"

    assert app_controller_frame["post_context"], "Should have post_context"
    assert app_controller_frame["post_context"].is_a?(Array), "post_context should be an array"
    assert app_controller_frame["post_context"].size > 0, "post_context should not be empty"

    # Verify the actual content matches what we expect from the file
    # Line 9 is: raise StandardError, "Test error for Lapsoss"
    # Pre-context should include lines 6-8
    # Post-context should include lines 10-12

    # Check that pre_context includes the method definition
    pre_context_joined = app_controller_frame["pre_context"].join("\n")
    assert pre_context_joined.include?("def error"),
           "pre_context should include the method definition"

    # Check that post_context includes the end statement
    post_context_joined = app_controller_frame["post_context"].join("\n")
    assert post_context_joined.include?("end"),
           "post_context should include the end statement"

    # Success - code context was captured!
  end

  test "captures code context with proper formatting" do
    skip "Test needs updating for new architecture"
    captured_payload = nil

    # Create a custom controller with more complex code
    test_controller_path = Rails.root.join("app", "controllers", "test_error_controller.rb")

    # Temporarily create a test controller
    File.write(test_controller_path, <<~RUBY)
      # frozen_string_literal: true

      class TestErrorController < ApplicationController
        def complex_error
          # This is a comment before the error
          user_id = params[:user_id]
          data = { user: user_id, timestamp: Time.current }
      #{'    '}
          # Intentionally raise an error here
          raise ArgumentError, "Complex test error with data: \#{data.inspect}"
      #{'    '}
          # This code is unreachable
          render json: { status: "ok" }
        end
      end
    RUBY

    begin
      # Add route temporarily
      Rails.application.routes.draw do
        root "application#index"
        get "/error", to: "application#error"
        get "/health", to: "application#health"
        get "/complex_error", to: "test_error#complex_error"
      end

      # Reload the controller
      load test_controller_path

      # Mock HTTP client setup (same as before)
      mock_http_client = Class.new do
        def initialize(captured_payload_ref)
          @captured_payload_ref = captured_payload_ref
        end

        def post(path, body:, headers:)
          lines = body.split("\n")
          if lines.size >= 2
            event_json = lines[1]
            @captured_payload_ref.replace([ JSON.parse(event_json) ])
          end
          OpenStruct.new(status: 200, code: 200, body: '{"id":"test"}')
        end
      end

      # Configure Lapsoss
      Lapsoss.configure do |config|
        config.async = false
        config.debug = false # Less noise
        config.backtrace_enable_code_context = true
        config.backtrace_context_lines = 5 # More context lines
        config.use_sentry(
          name: :sentry_test,
          dsn: "https://test@sentry.io/123456"
        )
      end

      adapter = Lapsoss::Registry.instance[:sentry_test]
      captured_payload = []
      adapter.instance_variable_set(:@http_client, mock_http_client.new(captured_payload))

      # Trigger the complex error
      begin
        get "/complex_error", params: { user_id: 42 }
      rescue ArgumentError => e
        # Expected
        assert e.message.include?("Complex test error")
      end

      sleep(0.1)

      # Verify the payload
      assert_equal 1, captured_payload.size
      event = captured_payload.first

      exception = event.dig("exception", "values", 0)
      stacktrace = exception.dig("stacktrace", "frames")

      # Find the test controller frame
      test_frame = stacktrace.find { |f| f["filename"]&.include?("test_error_controller.rb") }
      assert test_frame, "Should have frame from test_error_controller.rb"

      # Verify we have 5 lines of context on each side
      assert_equal 5, test_frame["pre_context"].size, "Should have 5 lines of pre_context"
      assert_equal 5, test_frame["post_context"].size, "Should have 5 lines of post_context"

      # Verify the actual error line
      assert_match(/raise ArgumentError/, test_frame["context_line"])

      # Verify pre_context includes the data setup
      pre_context = test_frame["pre_context"].join("\n")
      assert pre_context.include?("user_id = params[:user_id]")
      assert pre_context.include?("data = { user:")

      puts "\n✅ Extended code context captured successfully"

    ensure
      # Clean up the test controller
      File.delete(test_controller_path) if File.exist?(test_controller_path)

      # Restore original routes
      Rails.application.routes.draw do
        root "application#index"
        get "/error", to: "application#error"
        get "/health", to: "application#health"
      end
    end
  end
end
