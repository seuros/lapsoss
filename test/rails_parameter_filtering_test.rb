# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsParameterFilteringTest < ActiveSupport::TestCase
  test "uses Rails filter parameters by default" do
    # Rails.application.config.filter_parameters is already set in the dummy app
    scrubber = Lapsoss::Scrubber.new

    data = {
      username: "john",
      password: "secret123",
      api_key: "xyz-456",
      safe_field: "visible"
    }

    result = scrubber.scrub(data)

    assert_equal "john", result[:username]
    assert_equal "[FILTERED]", result[:password]  # Filtered by Rails default
    assert_equal "[FILTERED]", result[:api_key]   # Filtered by Rails default
    assert_equal "visible", result[:safe_field]
  end

  test "can append custom scrub fields" do
    scrubber = Lapsoss::Scrubber.new(scrub_fields: %w[custom_secret my_token])

    data = {
      password: "filtered",  # Filtered by Rails defaults
      custom_secret: "filtered",  # Filtered by custom fields
      my_token: "also_filtered",  # Filtered by custom fields
      normal_field: "visible"
    }

    result = scrubber.scrub(data)

    assert_equal "[FILTERED]", result[:password]  # Rails defaults still apply
    assert_equal "[FILTERED]", result[:custom_secret]
    assert_equal "[FILTERED]", result[:my_token]
    assert_equal "visible", result[:normal_field]
  end

  test "scrubs nested data with Rails parameters" do
    scrubber = Lapsoss::Scrubber.new

    data = {
      user: {
        name: "Alice",
        password: "secret",
        profile: {
          token: "bearer_xyz",
          public_info: "visible"
        }
      }
    }

    result = scrubber.scrub(data)

    assert_equal "Alice", result[:user][:name]
    assert_equal "[FILTERED]", result[:user][:password]
    assert_equal "[FILTERED]", result[:user][:profile][:token]
    assert_equal "visible", result[:user][:profile][:public_info]
  end
end
