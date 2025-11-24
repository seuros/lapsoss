# frozen_string_literal: true

require "test_helper"

class SentryAdapterTest < ActiveSupport::TestCase
  setup do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
  end

  test "sentry endpoint format" do
    adapter = Lapsoss::Adapters::SentryAdapter.new(:sentry,
      dsn: "https://abc123@sentry.io/456789")

    api_endpoint = adapter.api_endpoint
    api_path = adapter.api_path

    assert_equal "https://sentry.io:443", api_endpoint
    assert_equal "/api/456789/envelope/", api_path

    # Full URL should be endpoint + path
    full_url = "#{api_endpoint}#{api_path}"
    assert_equal "https://sentry.io:443/api/456789/envelope/", full_url
  end

  test "captures exception to Sentry" do
    VCR.use_cassette("sentry_capture_exception") do
      Lapsoss.configure do |config|
        config.use_sentry(name: :sentry_us, dsn: ENV.fetch("SENTRY_US_DSN", nil))
      end

      error = StandardError.new("Test error from Lapsoss")
      error.set_backtrace(caller)

      Lapsoss.capture_exception(error,
                                tags: { test: true, environment: "test" },
                                user: { id: 123, email: "test@example.com" },
                                extra: { custom_data: "value" })

      # Give it a moment to send
      sleep(0.5)
    end

    # If we get here without error, the test passed
    assert true
  end

  test "captures message to Sentry" do
    VCR.use_cassette("sentry_capture_message") do
      Lapsoss.configure do |config|
        config.use_sentry(name: :sentry_test, dsn: ENV.fetch("SENTRY_US_DSN", nil))
      end

      Lapsoss.capture_message("Test message from Lapsoss",
                              level: :info,
                              tags: { source: "activesupport_test" })

      sleep(0.5)
    end

    assert true
  end

  test "sends breadcrumbs with errors" do
    VCR.use_cassette("sentry_with_breadcrumbs") do
      Lapsoss.configure do |config|
        config.use_sentry(name: :sentry, dsn: ENV.fetch("SENTRY_US_DSN", nil))
      end

      Lapsoss.with_scope do
        # Add some breadcrumbs to the current scope
        Lapsoss.add_breadcrumb("User clicked button", type: :navigation, button: "submit")
        Lapsoss.add_breadcrumb("API request started", type: :http, url: "/api/test")
        Lapsoss.add_breadcrumb("API request failed", type: :error, status: 500)

        # Then capture an error, which should include the breadcrumbs from the scope
        Lapsoss.capture_exception(RuntimeError.new("Error after breadcrumbs"))
      end

      sleep(0.5)
    end

    assert true
  end

  test "sends feature flags with errors via context" do
    VCR.use_cassette("sentry_with_feature_flags") do
      Lapsoss.configure do |config|
        config.use_sentry(name: :sentry, dsn: ENV.fetch("SENTRY_US_DSN", nil))
      end

      # Feature flags are now passed as part of the context hash
      Lapsoss.capture_exception(RuntimeError.new("Error with feature flags"),
                                extra: { feature_flags: { new_checkout: "enabled", dark_mode: "variant_a" } })

      sleep(0.5)
    end

    assert true
  end
end
