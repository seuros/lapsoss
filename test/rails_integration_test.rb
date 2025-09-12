# frozen_string_literal: true

require_relative "rails_test_helper"
require "minitest/mock"

class RailsIntegrationTest < ActionDispatch::IntegrationTest
  test "dummy app loads successfully" do
    get "/"
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Lapsoss Dummy App", json_response["message"]
    assert_equal "ok", json_response["status"]
  end

  test "health endpoint works" do
    get "/health"
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "healthy", json_response["status"]
    assert json_response["timestamp"].present?
  end

  test "error endpoint raises and captures exception" do
    captured_events = []

    # Create a mock adapter that captures events
    mock_adapter = Class.new do
      def initialize(captured_events)
        @captured_events = captured_events
      end

      def capture(event)
        @captured_events << event
        event
      end

      def name
        :test_logger
      end

      def enabled?
        true
      end
    end.new(captured_events)

    # Configure Lapsoss first, then register the mock adapter
    Lapsoss.configure do |config|
      config.async = false # Synchronous for testing
      config.debug = true
      config.capture_request_context = true
    end

    # Replace the logger adapter with our mocked version
    Lapsoss::Registry.instance.clear!
    Lapsoss::Registry.instance.register_adapter(mock_adapter)

    begin
      # This should raise an exception that gets captured by Rails.error subscriber
      assert_raises(StandardError) do
        get "/error"
      end

      # Verify the event was captured via Rails.error subscriber
      assert_equal 1, captured_events.size

      event = captured_events.first
      assert_equal "StandardError", event.exception_type
      assert_equal "Test error for Lapsoss", event.message
      assert(event.backtrace.any? { |frame| frame.include?("application_controller.rb") })
    ensure
      # Clean up Lapsoss state
      Lapsoss.instance_variable_set(:@configuration, nil)
      Lapsoss.instance_variable_set(:@client, nil)
      Lapsoss::Registry.instance.clear!
    end
  end

  test "lapsoss rails error subscriber is active" do
    # Check if our error subscriber is registered with Rails.error
    subscribers = Rails.error.instance_variable_get(:@subscribers)
    lapsoss_subscriber = subscribers.find { |s| s.is_a?(Lapsoss::RailsErrorSubscriber) }

    assert lapsoss_subscriber, "Expected Lapsoss::RailsErrorSubscriber to be registered with Rails.error"
  end

  test "lapsoss configuration is loaded" do
    # Verify that Lapsoss is configured
    assert Lapsoss.configuration.present?
    assert_equal false, Lapsoss.configuration.debug? # Should be false in test environment
    assert_equal 1.0, Lapsoss.configuration.sample_rate
  end
end
