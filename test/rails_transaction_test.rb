# frozen_string_literal: true

require_relative "test_helper"
require "action_controller"
require "ostruct"

class RailsTransactionTest < ActiveSupport::TestCase
  setup do
    # Clear registry before each test
    Lapsoss::Registry.instance.clear!
    # Reset configuration
    Lapsoss.instance_variable_set(:@configuration, nil)
    # Clear thread-local state
    Lapsoss::Current.reset
  end

  test "captures transaction name from scope" do
    # Configure Lapsoss with mock adapter
    captured_events = []

    # Create a proper mock adapter class
    mock_adapter_class = Class.new(Lapsoss::Adapters::Base) do
      attr_reader :captured_events

      def initialize(name, settings = {})
        super
        @captured_events = []
      end

      def capture(event)
        @captured_events << event
        true
      end

      def enabled?
        true
      end
    end

    # Create an instance of the mock adapter
    mock_adapter = mock_adapter_class.new(:mock, {})

    Lapsoss.configure do |config|
      config.enabled = true
      config.async = false  # Disable async for testing
    end

    Lapsoss::Registry.instance.register_adapter(mock_adapter)

    # Set transaction in scope
    Lapsoss::Current.scope.set_transaction_name("TestController#show", source: :view)

    # Capture an exception
    begin
      raise StandardError, "Test error with transaction"
    rescue StandardError => e
      Lapsoss.capture_exception(e)
    end

    # Verify transaction was captured
    captured_events = mock_adapter.captured_events
    assert_equal 1, captured_events.length, "Expected 1 captured event, got #{captured_events.length}"

    event = captured_events.first
    assert_equal "TestController#show", event.transaction, "Transaction name should be captured"
    assert_equal :exception, event.type
    assert_equal "Test error with transaction", event.message
  end

  test "transaction is included in Sentry envelope" do
    http = NativeHTTP.new

    # Configure with Sentry adapter
    Lapsoss.configure do |config|
      config.async = false  # Disable async for testing
      config.use_sentry(name: :sentry_test, dsn: http.url.sub("://", "://key@") + "/456")
    end

    # Set transaction in scope
    Lapsoss::Current.scope.set_transaction_name("UsersController#index", source: :view)

    # Capture an exception
    begin
      raise StandardError, "Error with transaction context"
    rescue StandardError => e
      Lapsoss.capture_exception(e)
    end

    # Verify transaction was included in Sentry payload
    assert Lapsoss.flush
    payload = JSON.parse(http.next_request[:body].lines[2])

    assert_equal "UsersController#index", payload["transaction"]
    assert_equal "ruby", payload["platform"]
    assert payload["exception"]
  ensure
    Lapsoss.client&.shutdown
    http&.close
  end
end
