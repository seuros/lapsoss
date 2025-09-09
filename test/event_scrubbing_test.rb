# frozen_string_literal: true

require_relative "test_helper"

class EventScrubbingTest < ActiveSupport::TestCase
  setup do
    Lapsoss.configuration.clear!
  end

  test "event scrubs sensitive data by default" do
    event = Lapsoss::Event.build(
      type: :exception,
      context: {
        user: {
          username: "john",
          password: "secret123",
          email: "john@example.com"
        },
        extra: {
          api_key: "abc123",
          debug_info: "safe data"
        }
      }
    )

    result = event.scrubbed.to_h

    assert_equal "john", result[:context][:user][:username]
    assert_equal "[FILTERED]", result[:context][:user][:password]
    assert_equal "[FILTERED]", result[:context][:user][:email]  # 'email' is filtered by Rails conventions
    assert_equal "[FILTERED]", result[:context][:extra][:api_key]
    assert_equal "safe data", result[:context][:extra][:debug_info]
  end

  test "event respects custom scrub configuration" do
    Lapsoss.configure do |config|
      config.scrub_fields = %w[custom_secret special_field]
    end

    event = Lapsoss::Event.build(
      type: :message,
      context: {
        regular_field: "not_scrubbed",
        custom_secret: "should_be_scrubbed",
        special_field: "also_scrubbed",
        password: "also_scrubbed"  # Rails defaults still apply
      }
    )

    result = event.scrubbed.to_h

    assert_equal "not_scrubbed", result[:context][:regular_field]
    assert_equal "[FILTERED]", result[:context][:custom_secret]
    assert_equal "[FILTERED]", result[:context][:special_field]
    assert_equal "[FILTERED]", result[:context][:password]  # Rails defaults still apply
  end

  test "event handles custom scrub fields" do
    Lapsoss.configure do |config|
      # Use custom fields that ActiveSupport::ParameterFilter can handle
      config.scrub_fields = %w[username sensitive_data]
    end

    event = Lapsoss::Event.build(
      type: :message,
      message: "Test message",
      context: {
        username: "john",
        safe_field: "keep_this",
        sensitive_data: "scrub_this"
      }
    )

    result = event.scrubbed.to_h

    assert_equal "Test message", result[:message]
    assert_equal "[FILTERED]", result[:context][:username]  # In custom list
    assert_equal "keep_this", result[:context][:safe_field]
    assert_equal "[FILTERED]", result[:context][:sensitive_data]  # In custom list
  end

  test "event preserves exception data while scrubbing context" do
    error = StandardError.new("Test error")
    error.set_backtrace(%w[line1 line2])

    event = Lapsoss::Event.build(
      type: :exception,
      exception: error,
      context: {
        password: "secret",
        request_id: "safe_id"
      }
    )

    result = event.scrubbed.to_h

    assert_equal StandardError, result[:exception].class
    assert_equal "Test error", result[:exception].message
    assert result[:exception].respond_to?(:backtrace)
    assert_equal "[FILTERED]", result[:context][:password]
    assert_equal "safe_id", result[:context][:request_id]
  end
end
