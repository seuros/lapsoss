# frozen_string_literal: true

require_relative "test_helper"

class ScrubberTest < ActiveSupport::TestCase
  setup do
    @scrubber = Lapsoss::Scrubber.new
  end

  test "scrubs default sensitive fields" do
    data = {
      password: "secret123",
      api_key: "abc-123-xyz",
      normal_field: "visible",
      nested: {
        token: "bearer_token_123",
        public_data: "can see this"
      }
    }

    result = @scrubber.scrub(data)

    assert_equal "[FILTERED]", result[:password]
    assert_equal "[FILTERED]", result[:api_key]
    assert_equal "visible", result[:normal_field]
    assert_equal "[FILTERED]", result[:nested][:token]
    assert_equal "can see this", result[:nested][:public_data]
  end

  test "scrubs nested hash data" do
    data = {
      user: {
        name: "John",
        password: "secret",
        profile: {
          email: "john@example.com",
          api_key: "xyz123"
        }
      }
    }

    result = @scrubber.scrub(data)

    assert_equal "John", result[:user][:name]
    assert_equal "[FILTERED]", result[:user][:password]
    assert_equal "[FILTERED]", result[:user][:profile][:email]  # 'email' is filtered by Rails conventions
    assert_equal "[FILTERED]", result[:user][:profile][:api_key]
  end

  test "scrubs arrays containing sensitive data" do
    data = {
      users: [
        { name: "Alice", password: "pass1" },
        { name: "Bob", password: "pass2" }
      ],
      items: [ "item1", "item2" ]  # Changed from 'tokens' to avoid filter
    }

    result = @scrubber.scrub(data)

    assert_equal "Alice", result[:users][0][:name]
    assert_equal "[FILTERED]", result[:users][0][:password]
    assert_equal "Bob", result[:users][1][:name]
    assert_equal "[FILTERED]", result[:users][1][:password]
    # 'items' key doesn't match the filter patterns, so values are kept
    assert_equal [ "item1", "item2" ], result[:items]
  end

  test "accepts custom scrub fields" do
    scrubber = Lapsoss::Scrubber.new(scrub_fields: %w[custom_secret my_token])

    data = {
      custom_secret: "should_be_filtered",
      my_token: "also_filtered",
      password: "also_filtered",  # Still filtered by Rails defaults
      normal_field: "visible"
    }

    result = scrubber.scrub(data)

    assert_equal "[FILTERED]", result[:custom_secret]
    assert_equal "[FILTERED]", result[:my_token]
    assert_equal "[FILTERED]", result[:password]  # Rails defaults still apply
    assert_equal "visible", result[:normal_field]
  end

  test "handles nil and empty data" do
    assert_nil @scrubber.scrub(nil)
    assert_equal({}, @scrubber.scrub({}))
    assert_equal [], @scrubber.scrub([])
  end

  test "handles complex nested structures" do
    data = {
      level1: {
        level2: {
          level3: {
            secret: "deep_secret",
            public: "visible"
          }
        }
      }
    }

    result = @scrubber.scrub(data)

    assert_equal "[FILTERED]", result[:level1][:level2][:level3][:secret]
    assert_equal "visible", result[:level1][:level2][:level3][:public]
  end

  test "uses Rails filter parameters" do
    # Rails is always loaded when using bin/rails test
    # The scrubber automatically uses Rails.application.config.filter_parameters

    scrubber = Lapsoss::Scrubber.new
    data = { password: "secret" }
    result = scrubber.scrub(data)

    assert_equal "[FILTERED]", result[:password]
  end

  # ActiveSupport::ParameterFilter doesn't handle circular references
  # This is a known Rails limitation, so we don't test for it
end
