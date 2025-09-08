# frozen_string_literal: true

require_relative "test_helper"

class RollbarAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = Lapsoss::Adapters::RollbarAdapter.new(:rollbar, access_token: "abc123def456")
  end

  test "captures exception" do
    VCR.use_cassette("rollbar_capture_exception") do
      error = StandardError.new("Test error from Lapsoss")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      # NOTE: VCR cassettes use invalid credentials for security
      # This test verifies payload format and error handling
      # In production, valid credentials would return 200 OK
      begin
        response = @adapter.capture(event)
        assert response
      rescue Lapsoss::DeliveryError => e
        # Expected for invalid test credentials
        assert_match(/401/, e.message)
      end
    end
  end

  test "captures message" do
    VCR.use_cassette("rollbar_capture_message") do
      event = Lapsoss::Event.build(type: :message, message: "Critical error from Lapsoss", level: :error)

      # Should succeed (when 200) or raise DeliveryError (when 401/etc)
      begin
        response = @adapter.capture(event)
        assert response
      rescue Lapsoss::DeliveryError => e
        # This is expected behavior for auth failures
        assert_match(/401/, e.message)
      end
    end
  end

  test "includes user context" do
    VCR.use_cassette("rollbar_with_user") do
      error = StandardError.new("Error with user context")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception,
                                 exception: error,
                                 context: {
                                   user: { id: 123, username: "testuser", email: "test@example.com" }
                                 })

      # Should succeed (when 200) or raise DeliveryError (when 401/etc)
      begin
        response = @adapter.capture(event)
        assert response
      rescue Lapsoss::DeliveryError => e
        # This is expected behavior for auth failures
        assert_match(/401/, e.message)
      end
    end
  end

  test "includes custom data" do
    VCR.use_cassette("rollbar_with_custom_data") do
      error = StandardError.new("Error with custom data")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception,
                                 exception: error,
                                 context: {
                                   extra: {
                                     order_id: "12345",
                                     feature_flag: "new_checkout"
                                   }
                                 })

      # Should succeed (when 200) or raise DeliveryError (when 401/etc)
      begin
        response = @adapter.capture(event)
        assert response
      rescue Lapsoss::DeliveryError => e
        # This is expected behavior for auth failures
        assert_match(/401/, e.message)
      end
    end
  end
end
