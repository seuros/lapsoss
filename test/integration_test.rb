# frozen_string_literal: true

require "test_helper"
require "vcr"

class IntegrationTest < Minitest::Test
  def setup
    Lapsoss::Registry.instance.clear!
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss.instance_variable_set(:@client, nil)
  end

  def teardown
    Lapsoss::Registry.instance.clear!
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss.instance_variable_set(:@client, nil)
  end

  def test_multi_provider_sync_dispatch
    # Configure with logger only for simpler test
    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)

      config.use_logger(name: :test_logger, level: :info)
    end

    # Verify adapter is registered
    registry = Lapsoss::Registry.instance
    assert_equal 1, registry.active.size
    assert_includes registry.active.map(&:name), :test_logger

    # Test exception capture
    exception = StandardError.new("Integration test error")

    # Capture should return nil in sync mode (no thread)
    result = Lapsoss.capture_exception(exception, tags: { test: "integration" })
    assert_nil result
  end

  def test_multi_provider_async_dispatch
    # Configure with async mode
    Lapsoss.configure do |config|
      config.async = true
      config.debug = true
      config.logger = Logger.new(StringIO.new)

      config.use_logger(name: :async_logger, level: :info)
      config.use_telebugs(
        name: :async_telebugs,
        dsn: "https://async@example.com/2"
      )
    end

    # Verify configuration
    assert_equal true, Lapsoss.configuration.async
    assert_equal 2, Lapsoss::Registry.instance.active.size

    # Test exception capture
    exception = StandardError.new("Async integration test error")

    VCR.use_cassette("integration_multi_provider_async") do
      result = Lapsoss.capture_exception(exception, tags: { mode: "async" })

      # Async mode should return a Thread
      assert_instance_of Thread, result

      # Wait for thread completion
      result.join if result.respond_to?(:join)
    end
  end

  def test_transaction_context_capture
    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)
      config.use_logger(name: :transaction_logger, level: :info)
    end

    # Test with transaction context
    Lapsoss.with_scope(transaction: "TestController#action") do |scope|
      scope.set_transaction_name("IntegrationTest#test_method", source: :view)

      exception = StandardError.new("Transaction test error")

      result = Lapsoss.capture_exception(exception, tags: { context: "transaction" })
      assert_nil result # sync mode returns nil
    end
  end

  def test_breadcrumbs_and_context
    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)
      config.use_logger(name: :breadcrumb_logger, level: :info)
    end

    # Add breadcrumbs
    Lapsoss.add_breadcrumb("User logged in", type: :user)
    Lapsoss.add_breadcrumb("Page loaded", type: :navigation, metadata: { url: "/test" })

    # Test with context
    Lapsoss.with_scope(
      tags: { feature: "breadcrumbs" },
      user: { id: 123, email: "test@example.com" },
      extra: { test_data: "integration" }
    ) do
      exception = StandardError.new("Context test error")
      result = Lapsoss.capture_exception(exception)
      assert_nil result
    end
  end

  def test_message_capture_multi_provider
    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)

      config.use_logger(name: :message_logger, level: :info)
      config.use_telebugs(
        name: :message_telebugs,
        dsn: "https://message@example.com/3"
      )
    end

    VCR.use_cassette("integration_message_multi_provider") do
      result = Lapsoss.capture_message(
        "Integration test message",
        level: :warning,
        tags: { type: "message_test" }
      )

      assert_nil result # sync mode
    end
  end

  def test_adapter_failure_resilience
    # Create a failing adapter for testing
    failing_adapter = Class.new(Lapsoss::Adapters::Base) do
      def capture(event)
        raise StandardError, "Simulated adapter failure"
      end
    end

    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)
      config.use_logger(name: :resilient_logger, level: :info)
    end

    # Register failing adapter directly
    Lapsoss::Registry.instance.register_adapter(failing_adapter.new(:failing))

    # Should not raise error despite failing adapter
    exception = StandardError.new("Resilience test error")
    result = nil

    # Should not raise error despite failing adapter
    result = Lapsoss.capture_exception(exception)

    assert_nil result
  end

  def test_real_telebugs_dispatch
    skip("Skipping real network test - set TELEBUGS_DSN to enable") unless ENV["TELEBUGS_DSN"]

    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(STDOUT)

      config.use_telebugs(
        name: :real_telebugs,
        dsn: ENV["TELEBUGS_DSN"]
      )
    end

    # Test real network request
    VCR.use_cassette("integration_real_telebugs", record: :once) do
      exception = StandardError.new("Real Telebugs integration test at #{Time.now}")
      result = Lapsoss.capture_exception(exception, tags: { test: "real_network" })
      assert_nil result
    end
  end

  def test_pipeline_processing_multi_provider
    processed_events = []

    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)
      config.enable_pipeline = true
      config.pipeline = ->(event) {
        processed_events << event
        event # return event to continue processing
      }

      config.use_logger(name: :pipeline_logger, level: :info)
      config.use_telebugs(
        name: :pipeline_telebugs,
        dsn: "https://pipeline@example.com/4"
      )
    end

    VCR.use_cassette("integration_pipeline_multi_provider") do
      exception = StandardError.new("Pipeline test error")
      result = Lapsoss.capture_exception(exception)

      assert_nil result
      assert_equal 1, processed_events.size
      assert_equal :exception, processed_events.first.type
    end
  end

  def test_before_send_filtering
    filtered_events = []

    Lapsoss.configure do |config|
      config.async = false
      config.debug = true
      config.logger = Logger.new(StringIO.new)
      config.before_send = ->(event) {
        filtered_events << event
        # Filter out events with "skip" tag
        event.tags[:skip] ? nil : event
      }

      config.use_logger(name: :filter_logger, level: :info)
    end

    # Event that should be sent
    exception1 = StandardError.new("Normal error")
    result1 = Lapsoss.capture_exception(exception1, tags: { normal: true })
    assert_nil result1
    assert_equal 1, filtered_events.size

    # Event that should be filtered out
    exception2 = StandardError.new("Skipped error")
    result2 = Lapsoss.capture_exception(exception2, tags: { skip: true })
    assert_nil result2
    assert_equal 2, filtered_events.size
  end
end
