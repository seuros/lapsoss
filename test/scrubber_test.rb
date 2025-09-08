# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class ScrubberTest < ActiveSupport::TestCase
  setup do
    @scrubber = Lapsoss::Scrubber.new
  end

  test "scrubs default sensitive fields" do
    data = {
      username: "john_doe",
      password: "secret123",
      api_key: "abc123def456",
      normal_field: "safe_value"
    }

    result = @scrubber.scrub(data)

    assert_equal "john_doe", result[:username]
    assert_equal "**SCRUBBED**", result[:password]
    assert_equal "**SCRUBBED**", result[:api_key]
    assert_equal "safe_value", result[:normal_field]
  end

  test "scrubs nested hash data" do
    data = {
      user: {
        name: "John",
        password: "secret",
        profile: {
          email: "john@example.com",
          access_token: "token123"
        }
      }
    }

    result = @scrubber.scrub(data)

    assert_equal "John", result[:user][:name]
    assert_equal "**SCRUBBED**", result[:user][:password]
    assert_equal "john@example.com", result[:user][:profile][:email]
    assert_equal "**SCRUBBED**", result[:user][:profile][:access_token]
  end

  test "scrubs array data" do
    data = {
      users: [
        { name: "John", password: "secret1" },
        { name: "Jane", password: "secret2" }
      ]
    }

    result = @scrubber.scrub(data)

    assert_equal "John", result[:users][0][:name]
    assert_equal "**SCRUBBED**", result[:users][0][:password]
    assert_equal "Jane", result[:users][1][:name]
    assert_equal "**SCRUBBED**", result[:users][1][:password]
  end

  test "respects custom scrub fields" do
    scrubber = Lapsoss::Scrubber.new(scrub_fields: %w[custom_secret])

    data = {
      password: "should_not_be_scrubbed",
      custom_secret: "should_be_scrubbed"
    }

    result = scrubber.scrub(data)

    assert_equal "should_not_be_scrubbed", result[:password]
    assert_equal "**SCRUBBED**", result[:custom_secret]
  end

  test "respects whitelist fields" do
    scrubber = Lapsoss::Scrubber.new(
      scrub_fields: %w[password secret],
      whitelist_fields: %w[debug_password]
    )

    data = {
      password: "should_be_scrubbed",
      secret: "should_be_scrubbed",
      debug_password: "should_not_be_scrubbed"
    }

    result = scrubber.scrub(data)

    assert_equal "**SCRUBBED**", result[:password]
    assert_equal "**SCRUBBED**", result[:secret]
    assert_equal "should_not_be_scrubbed", result[:debug_password]
  end

  test "scrub_all mode scrubs everything except whitelisted" do
    scrubber = Lapsoss::Scrubber.new(
      scrub_all: true,
      whitelist_fields: %w[safe_field]
    )

    data = {
      username: "john",
      password: "secret",
      safe_field: "keep_this"
    }

    result = scrubber.scrub(data)

    assert_equal "**SCRUBBED**", result[:username]
    assert_equal "**SCRUBBED**", result[:password]
    assert_equal "keep_this", result[:safe_field]
  end

  test "handles file attachments" do
    # Create a mock object that behaves like an uploaded file
    attachment = Class.new do
      def class
        Class.new do
          def name
            "ActionDispatch::Http::UploadedFile"
          end
        end.new
      end

      def content_type
        "image/png"
      end

      def original_filename
        "test.png"
      end

      def size
        1024
      end

      def is_a?(_klass)
        false
      end

      def respond_to?(method)
        %i[class content_type original_filename size].include?(method)
      end
    end.new

    data = { file: attachment }
    result = @scrubber.scrub(data)

    expected = {
      __attachment__: true,
      content_type: "image/png",
      original_filename: "test.png",
      size: 1024
    }

    assert_equal expected, result[:file]
  end

  test "randomize scrub length when enabled" do
    scrubber = Lapsoss::Scrubber.new(randomize_scrub_length: true)

    data = { password: "secret" }
    result = scrubber.scrub(data)

    # Should be between 6-12 asterisks
    scrubbed_value = result[:password]
    assert_match(/^\*{6,12}$/, scrubbed_value)
  end

  test "handles circular references" do
    data = { name: "test" }
    data[:self_ref] = data

    result = @scrubber.scrub(data)

    assert_equal "test", result[:name]
    # Should not cause infinite loop
    assert result[:self_ref].is_a?(Hash)
  end
end
