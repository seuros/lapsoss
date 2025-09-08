# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class RailsParameterFilteringTest < ActiveSupport::TestCase
  test "uses Rails filter parameters when available" do
    # Create mock objects using Minitest::Mock
    app_config = Minitest::Mock.new
    app_config.expect(:filter_parameters, [ :password, :secret, /token/ ])

    app = Minitest::Mock.new
    app.expect(:config, app_config)

    rails_module = Module.new do
      def self.application
        app = Minitest::Mock.new
        config = Minitest::Mock.new
        config.expect(:filter_parameters, [ :password, :secret, /token/ ])
        app.expect(:config, config)
        app
      end

      def self.respond_to?(method)
        method == :application
      end
    end

    # Temporarily define Rails constant
    Object.const_set(:Rails, rails_module) unless defined?(Rails)

    # Create scrubber (should pick up Rails filter parameters)
    scrubber = Lapsoss::Scrubber.new

    data = {
      username: "john",
      password: "secret123",
      access_token: "abc123",
      api_secret: "def456",
      safe_field: "safe_value"
    }

    result = scrubber.scrub(data)

    # Rails parameter filter should handle password, secret, and *token patterns
    assert_equal "john", result[:username]
    assert_equal "safe_value", result[:safe_field]

    # These should be filtered by Rails parameter filter (if ActiveSupport::ParameterFilter is available)
    # or by our default filters as fallback
    assert_not_equal "secret123", result[:password]
    assert_not_equal "abc123", result[:access_token]
    assert_not_equal "def456", result[:api_secret]
  ensure
    # Clean up - remove Rails constant if we added it
    Object.send(:remove_const, :Rails) if defined?(Rails) && rails_module == Rails
  end

  test "falls back to default scrubbing when Rails is not available" do
    # Ensure Rails is not defined
    original_rails = Object.const_get(:Rails) if defined?(Rails)
    Object.send(:remove_const, :Rails) if defined?(Rails)

    scrubber = Lapsoss::Scrubber.new

    data = {
      username: "john",
      password: "secret123",
      api_key: "abc123",
      safe_field: "safe_value"
    }

    result = scrubber.scrub(data)

    assert_equal "john", result[:username]
    assert_equal "**SCRUBBED**", result[:password]
    assert_equal "**SCRUBBED**", result[:api_key]
    assert_equal "safe_value", result[:safe_field]
  ensure
    # Restore Rails constant if it existed
    Object.const_set(:Rails, original_rails) if original_rails
  end

  test "custom scrub_fields override Rails filter parameters" do
    # Mock Rails
    rails_module = Module.new do
      def self.application
        app = Minitest::Mock.new
        config = Minitest::Mock.new
        config.expect(:filter_parameters, [ :password ]) # Rails only filters password
        app.expect(:config, config)
        app
      end

      def self.respond_to?(method)
        method == :application
      end
    end

    Object.const_set(:Rails, rails_module) unless defined?(Rails)

    # Override with custom scrub fields
    scrubber = Lapsoss::Scrubber.new(scrub_fields: %w[custom_secret])

    data = {
      password: "should_not_be_scrubbed", # Not in custom scrub_fields
      custom_secret: "should_be_scrubbed" # In custom scrub_fields
    }

    result = scrubber.scrub(data)

    assert_equal "should_not_be_scrubbed", result[:password]
    assert_equal "**SCRUBBED**", result[:custom_secret]
  ensure
    Object.send(:remove_const, :Rails) if defined?(Rails) && rails_module == Rails
  end
end
