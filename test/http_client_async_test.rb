# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class HttpClientAsyncTest < ActiveSupport::TestCase
  def setup
    super
    Lapsoss.configure do |config|
      config.debug = true
      config.use_logger
    end
  end

  test "detects no fiber scheduler and uses sync adapter" do
    # No fiber scheduler running
    assert_nil Fiber.current_scheduler

    client = Lapsoss::HttpClient.new("https://example.com")
    adapter = client.send(:detect_optimal_adapter)

    # Should use sync adapter when no fiber scheduler
    assert_equal Faraday.default_adapter, adapter
  end

  test "force_sync_http config overrides async detection" do
    Lapsoss.configure do |config|
      config.force_sync_http = true
    end

    # Even if we had a fiber scheduler, force_sync should override
    client = Lapsoss::HttpClient.new("https://example.com")
    adapter = client.send(:detect_optimal_adapter)

    assert_equal Faraday.default_adapter, adapter
  end

  test "async adapter is available" do
    client = Lapsoss::HttpClient.new("https://example.com")

    # Should be available since we added it as dependency
    assert client.send(:async_adapter_available?)
  end

  test "detects fiber scheduler when present" do
    # Mock fiber scheduler being present
    mock_scheduler = Object.new

    # Use Minitest stub instead of define_singleton_method
    Fiber.stub :current_scheduler, mock_scheduler do
      client = Lapsoss::HttpClient.new("https://example.com")

      # Should detect scheduler
      assert client.send(:fiber_scheduler_active?)

      # Should use async adapter when scheduler present and gem available
      adapter = client.send(:detect_optimal_adapter)
      assert_equal :async_http, adapter
    end
  end

  test "logs adapter selection in debug mode" do
    io = StringIO.new
    logger = Logger.new(io)

    Lapsoss.configure do |config|
      config.debug = true
      config.logger = logger
    end

    client = Lapsoss::HttpClient.new("https://example.com")
    client.send(:detect_optimal_adapter)

    log_output = io.string
    assert_includes log_output, "[Lapsoss::HttpClient] Using sync HTTP adapter"
    assert_includes log_output, "fiber_scheduler: false"
    assert_includes log_output, "async_available: true"
    assert_includes log_output, "force_sync: false"
  end
end
