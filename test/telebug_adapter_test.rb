# frozen_string_literal: true

require_relative "test_helper"
require "lapsoss/adapters/telebug_adapter"

class TelebugAdapterTest < ActiveSupport::TestCase
  # Example real Telebug DSN format: https://60b737ab3a404c10818a13a6c25b9b9f@tests.telebugs.com/api/v1/sentry_errors/4

  setup do
    @adapter = Lapsoss::Adapters::TelebugAdapter.new(
      :telebug,
      dsn: "https://abc123@telebug.example.com/api/v1/sentry_errors/42"
    )
  end

  test "adapter name" do
    assert_equal :telebug, @adapter.name
  end

  test "inherits from sentry adapter" do
    assert_kind_of Lapsoss::Adapters::SentryAdapter, @adapter
  end

  test "configuration method" do
    config = Lapsoss::Configuration.new
    config.use_telebug(dsn: "https://test@telebug.io/123")

    assert config.adapter_configs[:telebug]
    assert_equal :telebug, config.adapter_configs[:telebug][:type]
    assert_equal "https://test@telebug.io/123", config.adapter_configs[:telebug][:settings][:dsn]
  end

  test "telebug dsn parsing" do
    adapter = Lapsoss::Adapters::TelebugAdapter.new(:telebug,
      dsn: "https://abc123@tests.telebugs.com/api/v1/sentry_errors/4")
    dsn = adapter.instance_variable_get(:@dsn)

    assert_equal "tests.telebugs.com", dsn[:host]
    assert_equal "abc123", dsn[:public_key]
    assert_equal "/api/v1/sentry_errors/4", dsn[:path]
  end

  test "telebug endpoint format" do
    adapter = Lapsoss::Adapters::TelebugAdapter.new(:telebug,
      dsn: "https://key123@example.telebugs.com/api/v1/sentry_errors/99")

    api_endpoint = adapter.class.api_endpoint
    api_path = adapter.class.api_path

    assert_equal "https://example.telebugs.com", api_endpoint
    assert_equal "/api/v1/sentry_errors/99", api_path

    # Full URL should be endpoint + path
    full_url = "#{api_endpoint}#{api_path}"
    assert_equal "https://example.telebugs.com/api/v1/sentry_errors/99", full_url
  end

  test "liberation pattern" do
    # Create a test adapter that captures events
    test_adapter = Class.new(Lapsoss::Adapters::TelebugAdapter) do
      attr_reader :captured_events

      def initialize(name = :telebug, settings = {})
        super(name, settings)
        @captured_events = []
      end

      def capture(event)
        @captured_events << event
        event
      end

      private

      def send_to_service(payload)
        # Don't actually send to network in tests
        { success: true }
      end
    end.new(:telebug, dsn: "https://test@telebug.io/123")

    # Configure Lapsoss
    Lapsoss.configure do |config|
      config.async = false
      config.debug = false
    end

    Lapsoss::Registry.instance.register_adapter(test_adapter)

    # Test the Liberation pattern with a lambda
    liberation_free = lambda do
      Lapsoss.handle do
        raise StandardError, "Breaking free with Telebug!"
      end
    end

    # Should capture the error
    liberation_free.call

    assert_equal 1, test_adapter.captured_events.size
    assert_equal "StandardError", test_adapter.captured_events.first.exception_type
    assert_equal "Breaking free with Telebug!", test_adapter.captured_events.first.message
  end
end
