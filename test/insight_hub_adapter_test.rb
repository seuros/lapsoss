# frozen_string_literal: true

require_relative "test_helper"

class InsightHubAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = Lapsoss::Adapters::InsightHubAdapter.new(:insight_hub, api_key: "abc123def456")
  end

  test "captures exception" do
    VCR.use_cassette("insight_hub_capture_exception") do
      error = StandardError.new("Test error from Lapsoss")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception, exception: error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "captures message" do
    VCR.use_cassette("insight_hub_capture_message") do
      event = Lapsoss::Event.build(type: :message, message: "Critical error from Lapsoss", level: :error)

      response = @adapter.capture(event)
      assert response
    end
  end

  test "includes breadcrumbs" do
    VCR.use_cassette("insight_hub_with_breadcrumbs") do
      error = RuntimeError.new("Error after breadcrumbs")
      error.set_backtrace([])

      event = Lapsoss::Event.build(type: :exception,
                                 exception: error,
                                 context: {
                                   breadcrumbs: [
                                     {
                                       timestamp: Time.zone.now,
                                       message: "User clicked button",
                                       type: "user",
                                       data: { button: "checkout" }
                                     }
                                   ]
                                 })

      response = @adapter.capture(event)
      assert response
    end
  end

  test "includes user and metadata" do
    VCR.use_cassette("insight_hub_with_metadata") do
      error = StandardError.new("Error with metadata")
      error.set_backtrace(caller)

      event = Lapsoss::Event.build(type: :exception,
                                 exception: error,
                                 context: {
                                   user: { id: 456, name: "Test User", email: "user@example.com" },
                                   extra: {
                                     feature_flags: %w[new_ui beta_feature],
                                     session_id: "abc123"
                                   }
                                 })

      response = @adapter.capture(event)
      assert response
    end
  end
end
