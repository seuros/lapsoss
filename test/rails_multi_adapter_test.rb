# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsMultiAdapterTest < ActionDispatch::IntegrationTest
  test "multiple adapters can be configured and work together" do
    adapter_logger = NamedTestAdapter.new("logger")
    adapter_sentry = NamedTestAdapter.new("sentry")
    adapter_rollbar = NamedTestAdapter.new("rollbar")

    with_lapsoss_configured do
      # Register multiple adapters
      Lapsoss::Registry.instance.register_adapter(adapter_logger)
      Lapsoss::Registry.instance.register_adapter(adapter_sentry)
      Lapsoss::Registry.instance.register_adapter(adapter_rollbar)

      # Trigger an error
      assert_raises(StandardError) do
        get "/error"
      end

      # All adapters should receive the event
      total_events = adapter_logger.event_count + adapter_sentry.event_count + adapter_rollbar.event_count
      assert_equal 3, total_events

      # Check each adapter received the event
      assert_equal 1, adapter_logger.event_count
      assert_equal 1, adapter_sentry.event_count
      assert_equal 1, adapter_rollbar.event_count

      # All events should be the same
      events = [ adapter_logger.last_event, adapter_sentry.last_event, adapter_rollbar.last_event ]
      assert(events.all? { |e| e.exception_type == "StandardError" })
      assert(events.all? { |e| e.message == "Test error for Lapsoss" })
    end
  end

  test "adapter failure doesn't affect other adapters" do
    failing_adapter = FailingTestAdapter.new
    successful_adapter = TestAdapter.new

    with_lapsoss_configured do
      Lapsoss::Registry.instance.register_adapter(failing_adapter)
      Lapsoss::Registry.instance.register_adapter(successful_adapter)

      # Trigger an error
      assert_raises(StandardError) do
        get "/error"
      end

      # The successful adapter should still receive the event
      assert_equal 1, successful_adapter.event_count
      assert_equal "StandardError", successful_adapter.last_event.exception_type
    end
  end

  test "adapters receive consistent event data" do
    adapters = []

    with_lapsoss_configured do
      # Create multiple adapters that capture events
      3.times do |i|
        adapter = NamedTestAdapter.new("adapter_#{i}")
        adapters << adapter
        Lapsoss::Registry.instance.register_adapter(adapter)
      end
      # Trigger an error
      assert_raises(StandardError) do
        get "/error"
      end

      # All adapters should receive identical event data
      total_events = adapters.sum(&:event_count)
      assert_equal 3, total_events

      events = adapters.map(&:last_event)

      # Check that all events have the same core data
      messages = events.map(&:message).uniq
      assert_equal 1, messages.size
      assert_equal "Test error for Lapsoss", messages.first

      exception_types = events.map(&:exception_type).uniq
      assert_equal 1, exception_types.size
      assert_equal "StandardError", exception_types.first

      # Check that all events are properly formed
      assert(events.all? { |e| e }, "All events should be present")
    end
  end

  test "adapters can be dynamically added and removed" do
    adapter1 = NamedTestAdapter.new("adapter1")
    adapter2 = NamedTestAdapter.new("adapter2")

    with_lapsoss_configured do
      # Start with one adapter
      Lapsoss::Registry.instance.register_adapter(adapter1)

      assert_raises(StandardError) do
        get "/error"
      end
      assert_equal 1, adapter1.event_count
      assert_equal 0, adapter2.event_count

      # Add second adapter
      Lapsoss::Registry.instance.register_adapter(adapter2)
      adapter1.clear!
      adapter2.clear!

      assert_raises(StandardError) do
        get "/error"
      end
      assert_equal 1, adapter1.event_count
      assert_equal 1, adapter2.event_count

      # Remove first adapter
      Lapsoss::Registry.instance.clear!
      Lapsoss::Registry.instance.register_adapter(adapter2)
      adapter2.clear!

      assert_raises(StandardError) do
        get "/error"
      end
      assert_equal 1, adapter2.event_count
      assert_equal "adapter2", adapter2.name.to_s
    end
  end
end
