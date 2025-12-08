# frozen_string_literal: true

require_relative "test_helper"

class OtlpAdapterTest < ActiveSupport::TestCase
  # OTLP payloads contain dynamic trace IDs and timestamps, so we match only on method/uri
  VCR_OPTIONS = { match_requests_on: %i[method uri] }.freeze

  setup do
    @adapter = Lapsoss::Adapters::OtlpAdapter.new(:otlp,
      endpoint: ENV["OTLP_ENDPOINT"] || "http://localhost:4318",
      service_name: "lapsoss-test"
    )
  end

  test "captures exception to OTLP endpoint" do
    VCR.use_cassette("otlp_capture_exception", VCR_OPTIONS) do
      error = StandardError.new("Test error from Lapsoss")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures message to OTLP endpoint" do
    VCR.use_cassette("otlp_capture_message", VCR_OPTIONS) do
      event = Lapsoss::Event.build(type: :message, message: "Info message from Lapsoss", level: :info)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures exception with user context" do
    VCR.use_cassette("otlp_with_user", VCR_OPTIONS) do
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
    VCR.use_cassette("otlp_with_tags", VCR_OPTIONS) do
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
    VCR.use_cassette("otlp_with_code_context", VCR_OPTIONS) do
      error = NoMethodError.new("undefined method `foo' for nil:NilClass")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "uses default endpoint when not specified" do
    adapter = Lapsoss::Adapters::OtlpAdapter.new(:otlp, {})

    assert adapter.enabled?
    # Default endpoint is localhost:4318
  end

  test "supports custom headers" do
    VCR.use_cassette("otlp_with_headers", VCR_OPTIONS) do
      adapter = Lapsoss::Adapters::OtlpAdapter.new(:otlp,
        endpoint: ENV["OTLP_ENDPOINT"] || "http://localhost:4318",
        headers: { "X-Custom-Header" => "custom-value" }
      )

      error = StandardError.new("Error with custom headers")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = adapter.capture(event)
      assert response
    end
  end

  test "supports api_key authentication" do
    VCR.use_cassette("otlp_with_api_key", VCR_OPTIONS) do
      adapter = Lapsoss::Adapters::OtlpAdapter.new(:otlp,
        endpoint: ENV["OTLP_ENDPOINT"] || "http://localhost:4318",
        api_key: "test-api-key"
      )

      error = StandardError.new("Error with API key")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = adapter.capture(event)
      assert response
    end
  end

  test "configuration helper use_otlp registers adapter" do
    Lapsoss.configure do |config|
      config.use_otlp(
        endpoint: "http://localhost:4318",
        service_name: "test-service"
      )
    end
    Lapsoss.configuration.apply!

    adapter = Lapsoss::Registry.instance[:otlp]
    assert_not_nil adapter
    assert_kind_of Lapsoss::Adapters::OtlpAdapter, adapter
  end

  test "configuration helper use_signoz registers OTLP adapter" do
    Lapsoss.configure do |config|
      config.use_signoz(
        signoz_api_key: "test-key"
      )
    end
    Lapsoss.configuration.apply!

    adapter = Lapsoss::Registry.instance[:signoz]
    assert_not_nil adapter
    assert_kind_of Lapsoss::Adapters::OtlpAdapter, adapter
  end

  test "configuration helper use_jaeger registers OTLP adapter" do
    Lapsoss.configure do |config|
      config.use_jaeger(
        endpoint: "http://jaeger:4318"
      )
    end
    Lapsoss.configuration.apply!

    adapter = Lapsoss::Registry.instance[:jaeger]
    assert_not_nil adapter
    assert_kind_of Lapsoss::Adapters::OtlpAdapter, adapter
  end

  test "builds valid OTLP payload structure" do
    error = StandardError.new("Test error")
    error.set_backtrace(caller)

    event = Lapsoss::Event.build(type: :exception, exception: error)
    payload = @adapter.send(:build_payload, event.scrubbed)

    assert payload.key?(:resourceSpans)
    assert_equal 1, payload[:resourceSpans].size

    resource_span = payload[:resourceSpans].first
    assert resource_span.key?(:resource)
    assert resource_span.key?(:scopeSpans)

    # Check resource attributes
    resource = resource_span[:resource]
    service_attr = resource[:attributes].find { |a| a[:key] == "service.name" }
    assert_not_nil service_attr
    assert_equal "lapsoss-test", service_attr[:value][:stringValue]

    # Check scope spans
    scope_span = resource_span[:scopeSpans].first
    assert_equal "lapsoss", scope_span[:scope][:name]

    # Check span
    span = scope_span[:spans].first
    assert span.key?(:traceId)
    assert span.key?(:spanId)
    assert_equal "StandardError", span[:name]
    assert_equal 2, span[:status][:code] # STATUS_CODE_ERROR

    # Check exception event
    assert span.key?(:events)
    exception_event = span[:events].first
    assert_equal "exception", exception_event[:name]

    type_attr = exception_event[:attributes].find { |a| a[:key] == "exception.type" }
    assert_equal "StandardError", type_attr[:value][:stringValue]
  end
end
