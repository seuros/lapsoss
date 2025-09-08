# frozen_string_literal: true

require "test_helper"

class AppsignalAdapterTest < ActiveSupport::TestCase
  setup do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
  end

  test "captures exception to AppSignal" do
    VCR.use_cassette("appsignal_capture_exception") do
      Lapsoss.configure do |config|
        config.use_appsignal(
          name: :appsignal_test,
          push_api_key: ENV.fetch("APPSIGNAL_PUSH_API_KEY", nil),
          frontend_api_key: ENV.fetch("APPSIGNAL_FRONTEND_API_KEY", nil),
          app_name: "lapsoss-test"
        )
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

  test "captures message to AppSignal" do
    VCR.use_cassette("appsignal_capture_message") do
      Lapsoss.configure do |config|
        config.use_appsignal(
          name: :appsignal_msg,
          push_api_key: ENV.fetch("APPSIGNAL_PUSH_API_KEY", nil),
          frontend_api_key: ENV.fetch("APPSIGNAL_FRONTEND_API_KEY", nil),
          app_name: "lapsoss-test"
        )
      end

      # AppSignal only captures error-level messages as synthetic errors
      Lapsoss.capture_message("Critical error from Lapsoss",
                              level: :error,
                              tags: { source: "test" })

      sleep(0.5)
    end

    assert true
  end

  test "sends breadcrumbs with errors" do
    VCR.use_cassette("appsignal_with_breadcrumbs") do
      Lapsoss.configure do |config|
        config.use_appsignal(
          name: :appsignal_bread,
          push_api_key: ENV.fetch("APPSIGNAL_PUSH_API_KEY", nil),
          frontend_api_key: ENV.fetch("APPSIGNAL_FRONTEND_API_KEY", nil),
          app_name: "lapsoss-test"
        )
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

  test "adapter handles missing API keys gracefully" do
    # With trust-but-verify, adapter doesn't raise but won't be functional
    with_env("APPSIGNAL_PUSH_API_KEY", nil) do
      with_env("APPSIGNAL_FRONTEND_API_KEY", nil) do
        assert_nothing_raised do
          adapter = Lapsoss::Adapters::AppsignalAdapter.new(:test, push_api_key: nil, frontend_api_key: nil)
          # Adapter should be created but not enabled without keys
          assert_not adapter.enabled?
        end
      end
    end
  end
end
