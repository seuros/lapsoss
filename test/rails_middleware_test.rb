# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsMiddlewareTest < ActionDispatch::IntegrationTest
  test "middleware captures exceptions during request processing" do
    test_adapter = TestAdapter.new

    with_lapsoss_configured do
      # Register our test adapter
      Lapsoss::Registry.instance.register_adapter(test_adapter)

      # Make a request that will raise an exception
      # In test environment, Rails re-raises the exception after capturing
      assert_raises(StandardError) do
        get "/error"
      end

      # Verify the exception was captured by the middleware
      assert_equal 1, test_adapter.captured_events.size

      event = test_adapter.captured_events.first
      assert event, "Expected event to be captured"
      assert_equal "StandardError", event.exception_type
      assert_equal "Test error for Lapsoss", event.message
      assert event.backtrace.any?, "Expected backtrace to be present"

      # Verify request context is included
      assert event.request_context, "Expected request context to be present"
      assert_equal "GET", event.request_context[:method]
      assert_equal "/error", event.request_context[:path]
    end
  end

  test "middleware adds request context to scope" do
    test_adapter = TestAdapter.new

    with_lapsoss_configured do
      Lapsoss::Registry.instance.register_adapter(test_adapter)

      # Make request that triggers error
      assert_raises(StandardError) do
        get "/error"
      end

      event = test_adapter.last_event
      assert event, "Expected event to be captured"
      assert event.request_context, "Expected event to have request context"
      assert_equal "GET", event.request_context[:method]
      assert_equal "/error", event.request_context[:path]
      # user_agent can be nil in test environment
      assert_not_nil event.request_context[:url]
      assert event.request_context[:request_id].present?
    end
  end

  test "middleware handles successful requests without interfering" do
    test_adapter = TestAdapter.new

    with_lapsoss_configured do
      Lapsoss::Registry.instance.register_adapter(test_adapter)

      # Make successful request
      get "/health"
      assert_response :success

      # No events should be captured for successful requests
      assert_empty test_adapter.events
    end
  end

  test "middleware preserves scope isolation between requests" do
    test_adapter = TestAdapter.new

    with_lapsoss_configured do
      Lapsoss::Registry.instance.register_adapter(test_adapter)

      # First request
      assert_raises(StandardError) do
        get "/error"
      end
      first_event = test_adapter.events[0]
      assert first_event, "Expected first event to be captured"

      # Second request
      assert_raises(StandardError) do
        get "/error"
      end
      second_event = test_adapter.events[1]
      assert second_event, "Expected second event to be captured"

      # Both should have different request IDs
      assert first_event.request_context, "Expected first event to have request context"
      assert second_event.request_context, "Expected second event to have request context"
      assert_not_equal(
        first_event.request_context[:request_id],
        second_event.request_context[:request_id]
      )

      # Both should have the same path but different contexts
      assert_equal "/error", first_event.request_context[:path]
      assert_equal "/error", second_event.request_context[:path]
    end
  end
end
