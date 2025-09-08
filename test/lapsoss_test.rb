# frozen_string_literal: true

require "test_helper"

class LapsossTest < ActiveSupport::TestCase
  setup do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
    Thread.current[:lapsoss_scope] = nil # Ensure scope is clean for each test
  end

  test "has a version number" do
    assert_not_nil ::Lapsoss::VERSION
  end

  test "can configure with single adapter using multi-adapter pattern" do
    Lapsoss.configure do |config|
      config.use_logger(name: :default, logger: Logger.new(nil))
    end

    assert_not_nil Lapsoss.client
    assert_equal :default, Lapsoss::Registry.instance[:default].name
  end

  test "can configure with multiple adapters" do
    Lapsoss.configure do |config|
      config.use_logger(name: :primary, logger: Logger.new(nil))
      config.use_logger(name: :backup, logger: Logger.new(nil))
    end

    assert_not_nil Lapsoss.client
    assert_equal 2, Lapsoss::Registry.instance.all.size
    assert_equal %i[primary backup].sort, Lapsoss::Registry.instance.names.sort
  end

  test "capture_exception uses the configured adapters" do
    output = StringIO.new
    Lapsoss.configure do |config|
      config.use_logger(logger: Logger.new(output))
    end

    Lapsoss.capture_exception(StandardError.new("Test Exception"))
    sleep 0.1 # Give async thread time to execute

    assert_includes output.string, "Test Exception"
  end

  test "capture_message uses the configured adapters" do
    output = StringIO.new
    Lapsoss.configure do |config|
      config.use_logger(logger: Logger.new(output))
    end

    Lapsoss.capture_message("Test Message")
    sleep 0.1 # Give async thread time to execute

    assert_includes output.string, "Test Message"
  end

  test "add_breadcrumb adds to the current scope" do
    Lapsoss.configure do |config|
      config.use_logger(logger: Logger.new(nil))
    end

    Lapsoss.add_breadcrumb("User logged in", type: :user_action)

    scope = Lapsoss.current_scope
    assert_equal 1, scope.breadcrumbs.size
    assert_equal "User logged in", scope.breadcrumbs.first[:message]
  end

  test "with_scope applies context and clears it" do
    Lapsoss.configure do |config|
      config.use_logger(logger: Logger.new(nil))
    end

    Lapsoss.with_scope(tags: { request_id: "123" }, user: { id: 1 }) do |scope|
      assert_equal "123", scope.tags[:request_id]
      assert_equal 1, scope.user[:id]
      Lapsoss.add_breadcrumb("Inside scope")
    end

    # After with_scope, the scope should be cleared for the current thread
    assert_empty Lapsoss.current_scope.tags
    assert_empty Lapsoss.current_scope.user
    assert_empty Lapsoss.current_scope.breadcrumbs
  end

  test "multi-adapter dispatch works" do
    output1 = StringIO.new
    output2 = StringIO.new

    Lapsoss.configure do |config|
      config.use_logger(name: :logger1, logger: Logger.new(output1))
      config.use_logger(name: :logger2, logger: Logger.new(output2))
    end

    Lapsoss.capture_message("Multi-adapter test")

    sleep 0.1 # Give async threads time to execute

    assert_includes output1.string, "Multi-adapter test"
    assert_includes output2.string, "Multi-adapter test"
  end

  test "can disable and enable adapters" do
    Lapsoss.configure do |config|
      config.use_logger(name: :test_logger, logger: Logger.new(nil))
    end

    adapter = Lapsoss::Registry.instance[:test_logger]
    assert adapter.enabled?

    adapter.disable!
    assert_not adapter.enabled?

    adapter.enable!
    assert adapter.enabled?
  end

  test "before_send callback works" do
    output = StringIO.new
    Lapsoss.configure do |config|
      config.use_logger(logger: Logger.new(output))
      config.before_send = lambda { |event|
        event.context[:filtered] = true
        event
      }
    end

    Lapsoss.capture_message("Test message for before_send")
    sleep 0.1

    assert_includes output.string, "filtered: true"
  end

  test "error handler is called on adapter failure" do
    handler_called = false
    error_info = nil

    Lapsoss.configure do |config|
      config.use_logger(name: :failing_logger)
      config.logger = Logger.new(StringIO.new) # Add a logger for error reporting
      config.error_handler = lambda { |adapter, event, error|
        handler_called = true
        error_info = { adapter: adapter.name, event_type: event.type, error_class: error.class }
      }
    end

    # Force an error by making the logger fail in the adapter's capture method
    failing_adapter = Lapsoss::Registry.instance[:failing_logger]
    def failing_adapter.capture(_event)
      raise "Simulated adapter error"
    end

    Lapsoss.capture_message("This will fail")

    sleep 0.2 # Give the async thread time to execute and call the error handler

    assert handler_called, "Error handler was not called."
    assert_equal :failing_logger, error_info[:adapter]
    assert_equal :message, error_info[:event_type]
    assert_equal RuntimeError, error_info[:error_class]
  end
end
