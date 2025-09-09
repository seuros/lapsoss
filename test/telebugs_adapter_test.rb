# frozen_string_literal: true

require_relative "test_helper"
require "lapsoss/adapters/telebugs_adapter"

class TelebugsAdapterTest < ActiveSupport::TestCase
  # Example real Telebugs DSN format: https://60b737ab3a404c10818a13a6c25b9b9f@tests.telebugs.com/api/v1/sentry_errors/4

  setup do
    @adapter = Lapsoss::Adapters::TelebugsAdapter.new(
      :telebugs,
      dsn: "https://abc123@telebugs.example.com/api/v1/sentry_errors/42"
    )
  end

  test "adapter name" do
    assert_equal :telebugs, @adapter.name
  end

  test "inherits from sentry adapter" do
    assert_kind_of Lapsoss::Adapters::SentryAdapter, @adapter
  end

  test "configuration method" do
    config = Lapsoss::Configuration.new
    config.use_telebugs(dsn: "https://test@telebugs.io/123")

    assert config.adapter_configs[:telebugs]
    assert_equal :telebugs, config.adapter_configs[:telebugs][:type]
    assert_equal "https://test@telebugs.io/123", config.adapter_configs[:telebugs][:settings][:dsn]
  end

  test "telebugs dsn parsing" do
    adapter = Lapsoss::Adapters::TelebugsAdapter.new(:telebugs,
      dsn: "https://abc123@tests.telebugs.com/api/v1/sentry_errors/4")
    dsn = adapter.instance_variable_get(:@dsn)

    assert_equal "tests.telebugs.com", dsn[:host]
    assert_equal "abc123", dsn[:public_key]
    assert_equal "/api/v1/sentry_errors/4", dsn[:path]
  end

  test "telebugs endpoint format" do
    adapter = Lapsoss::Adapters::TelebugsAdapter.new(:telebugs,
      dsn: "https://key123@example.telebugs.com/api/v1/sentry_errors/99")

    api_endpoint = adapter.class.api_endpoint
    api_path = adapter.class.api_path

    assert_equal "https://example.telebugs.com", api_endpoint
    assert_equal "/api/v1/sentry_errors/api/99/envelope/", api_path

    # Full URL should be endpoint + path
    full_url = "#{api_endpoint}#{api_path}"
    assert_equal "https://example.telebugs.com/api/v1/sentry_errors/api/99/envelope/", full_url
  end

  test "liberation pattern" do
    # Create a test adapter that captures events
    test_adapter = Class.new(Lapsoss::Adapters::TelebugsAdapter) do
      attr_reader :captured_events

      def initialize(name = :telebugs, settings = {})
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
    end.new(:telebugs, dsn: "https://test@telebugs.io/123")

    # Configure Lapsoss
    Lapsoss.configure do |config|
      config.async = false
      config.debug = false
    end

    Lapsoss::Registry.instance.register_adapter(test_adapter)

    # Test the Liberation pattern with a lambda
    liberation_free = lambda do
      Lapsoss.handle do
        raise StandardError, "Breaking free with Telebugs!"
      end
    end

    # Should capture the error
    liberation_free.call

    assert_equal 1, test_adapter.captured_events.size
    assert_equal "StandardError", test_adapter.captured_events.first.exception_type
    assert_equal "Breaking free with Telebugs!", test_adapter.captured_events.first.message
  end
end
