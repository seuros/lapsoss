# frozen_string_literal: true

require_relative "test_helper"

class OpenobserveAdapterTest < ActiveSupport::TestCase
  # OpenObserve payloads contain dynamic timestamps and trace IDs, so we match only on method/uri
  VCR_OPTIONS = { match_requests_on: %i[method uri] }.freeze

  setup do
    @adapter = Lapsoss::Adapters::OpenobserveAdapter.new(:openobserve,
      endpoint: ENV["OPENOBSERVE_ENDPOINT"] || "http://localhost:5080",
      username: ENV["OPENOBSERVE_USERNAME"] || "seuros@example.com",
      password: ENV["OPENOBSERVE_PASSWORD"] || "ShipItFast!",
      org: "default",
      stream: "errors"
    )
  end

  test "captures exception to OpenObserve" do
    VCR.use_cassette("openobserve_capture_exception", VCR_OPTIONS) do
      error = StandardError.new("Test error from Lapsoss")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures message to OpenObserve" do
    VCR.use_cassette("openobserve_capture_message", VCR_OPTIONS) do
      event = Lapsoss::Event.build(type: :message, message: "Info message from Lapsoss", level: :info)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures exception with user context" do
    VCR.use_cassette("openobserve_with_user", VCR_OPTIONS) do
      error = RuntimeError.new("Error with user context")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception,
                                   exception: error,
                                   context: {
                                     user: { id: 123, username: "testuser", email: "test@example.com" }
                                   })

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures exception with tags and extra data" do
    VCR.use_cassette("openobserve_with_tags", VCR_OPTIONS) do
      error = ArgumentError.new("Error with tags")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception,
                                   exception: error,
                                   context: {
                                     tags: { feature: "checkout", version: "2.0" },
                                     extra: { order_id: "12345", user_tier: "premium" }
                                   })

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures exception with code context" do
    VCR.use_cassette("openobserve_with_code_context", VCR_OPTIONS) do
      error = NoMethodError.new("undefined method `foo' for nil:NilClass")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "disabled when missing credentials" do
    adapter = Lapsoss::Adapters::OpenobserveAdapter.new(:openobserve, {})

    refute adapter.enabled?
  end

  test "disabled when missing endpoint" do
    adapter = Lapsoss::Adapters::OpenobserveAdapter.new(:openobserve,
      username: "test",
      password: "test"
    )

    refute adapter.enabled?
  end

  test "uses environment variables when settings not provided" do
    with_env("OPENOBSERVE_ENDPOINT", "http://test.example.com:5080") do
      with_env("OPENOBSERVE_USERNAME", "envuser@example.com") do
        with_env("OPENOBSERVE_PASSWORD", "EnvPass123") do
          adapter = Lapsoss::Adapters::OpenobserveAdapter.new(:openobserve, {})

          assert adapter.enabled?
        end
      end
    end
  end

  test "configuration helper registers adapter" do
    Lapsoss.configure do |config|
      config.use_openobserve(
        endpoint: "http://localhost:5080",
        username: "test@example.com",
        password: "TestPass123"
      )
    end
    Lapsoss.configuration.apply!

    adapter = Lapsoss::Registry.instance[:openobserve]
    assert_not_nil adapter
    assert_kind_of Lapsoss::Adapters::OpenobserveAdapter, adapter
  end

  test "supports custom org and stream" do
    VCR.use_cassette("openobserve_custom_stream", VCR_OPTIONS) do
      adapter = Lapsoss::Adapters::OpenobserveAdapter.new(:openobserve,
        endpoint: ENV["OPENOBSERVE_ENDPOINT"] || "http://localhost:5080",
        username: ENV["OPENOBSERVE_USERNAME"] || "seuros@example.com",
        password: ENV["OPENOBSERVE_PASSWORD"] || "ShipItFast!",
        org: "default",
        stream: "app_errors"
      )

      error = StandardError.new("Error to custom stream")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = adapter.capture(event)
      assert response
    end
  end
end
