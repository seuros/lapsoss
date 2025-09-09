# frozen_string_literal: true

require_relative "test_helper"

class LapsossErrorMethodsTest < Minitest::Test
  def setup
    @captured_events = []
    @test_adapter = create_test_adapter(@captured_events)

    Lapsoss.configure do |config|
      config.async = false
      config.debug = false
    end

    Lapsoss::Registry.instance.register_adapter(@test_adapter)
  end

  def teardown
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss.instance_variable_set(:@client, nil)
    Lapsoss::Registry.instance.clear!
  end

  def test_handle_swallows_errors
    result = Lapsoss.handle do
      raise StandardError, "This should be swallowed"
    end

    assert_nil result
    assert_equal 1, @captured_events.size
    assert_equal "StandardError", @captured_events.first.exception_type
    assert_equal "This should be swallowed", @captured_events.first.message
  end

  def test_handle_with_fallback
    result = Lapsoss.handle(fallback: "fallback value") do
      raise StandardError, "Error occurred"
    end

    assert_equal "fallback value", result
    assert_equal 1, @captured_events.size
  end

  def test_handle_with_fallback_proc
    result = Lapsoss.handle(fallback: -> { "computed fallback" }) do
      raise StandardError, "Error occurred"
    end

    assert_equal "computed fallback", result
    assert_equal 1, @captured_events.size
  end

  def test_handle_with_specific_error_class
    result = Lapsoss.handle(ArgumentError) do
      raise ArgumentError, "Specific error"
    end

    assert_nil result
    assert_equal 1, @captured_events.size
    assert_equal "ArgumentError", @captured_events.first.exception_type
  end

  def test_handle_does_not_catch_other_errors
    assert_raises(RuntimeError) do
      Lapsoss.handle(ArgumentError) do
        raise RuntimeError, "Different error"
      end
    end

    assert_equal 0, @captured_events.size
  end

  def test_record_captures_and_reraises
    assert_raises(StandardError) do
      Lapsoss.record do
        raise StandardError, "This should be re-raised"
      end
    end

    assert_equal 1, @captured_events.size
    assert_equal "StandardError", @captured_events.first.exception_type
    assert_equal "This should be re-raised", @captured_events.first.message
  end

  def test_record_with_specific_error_class
    assert_raises(ArgumentError) do
      Lapsoss.record(ArgumentError) do
        raise ArgumentError, "Specific error"
      end
    end

    assert_equal 1, @captured_events.size
    assert_equal "ArgumentError", @captured_events.first.exception_type
  end

  def test_report_manual_exception
    error = StandardError.new("Manual error")
    Lapsoss.report(error)

    assert_equal 1, @captured_events.size
    assert_equal "StandardError", @captured_events.first.exception_type
    assert_equal "Manual error", @captured_events.first.message
  end

  def test_report_with_context
    error = StandardError.new("Error with context")
    Lapsoss.report(error, user_id: 123, action: "test")

    assert_equal 1, @captured_events.size
    # Context would be available in the event, but our test adapter doesn't capture it
  end

  def test_methods_work_without_rails_error
    # This test ensures our methods work independently of Rails.error
    # Even if Rails is loaded, we're using Lapsoss methods directly

    # Our methods work without Rails.error
    Lapsoss.handle { raise "Test" }
    assert_equal 1, @captured_events.size

    # These methods are available directly on Lapsoss
    assert_respond_to Lapsoss, :handle
    assert_respond_to Lapsoss, :record
    assert_respond_to Lapsoss, :report
  end

  private

  def create_test_adapter(captured_events)
    Class.new do
      def initialize(captured_events)
        @captured_events = captured_events
      end

      def capture(event)
        @captured_events << event
        event
      end

      def name
        :test
      end

      def enabled?
        true
      end
    end.new(captured_events)
  end
end
