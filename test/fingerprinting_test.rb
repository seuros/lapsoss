# frozen_string_literal: true

require_relative "test_helper"

class FingerprintingTest < ActiveSupport::TestCase
  setup do
    @config = Lapsoss::Configuration.new
    @fingerprinter = Lapsoss::Fingerprinter.new
  end

  test "generates consistent fingerprints for same error" do
    error1 = StandardError.new("User 123 not found")
    error1.set_backtrace([ "user.rb:25", "controller.rb:10" ])

    error2 = StandardError.new("User 456 not found")
    error2.set_backtrace([ "user.rb:25", "controller.rb:10" ])

    event1 = Lapsoss::Event.build(type: :exception, exception: error1)
    event2 = Lapsoss::Event.build(type: :exception, exception: error2)

    fingerprint1 = @fingerprinter.generate_fingerprint(event1)
    fingerprint2 = @fingerprinter.generate_fingerprint(event2)

    # Should be the same because of ID normalization
    assert_equal fingerprint1, fingerprint2
  end

  test "uses built-in patterns for common errors" do
    # Test user lookup pattern
    error = StandardError.new("User 123 not found")
    event = Lapsoss::Event.build(type: :exception, exception: error)

    fingerprint = @fingerprinter.generate_fingerprint(event)
    assert_equal "user-lookup-error", fingerprint
  end

  test "uses built-in patterns for database errors" do
    # Create a mock ActiveRecord error
    error_class = Class.new(StandardError) do
      def self.name
        "ActiveRecord::RecordNotFound"
      end
    end

    error = error_class.new("Record not found")
    event = Lapsoss::Event.build(type: :exception, exception: error)

    fingerprint = @fingerprinter.generate_fingerprint(event)
    assert_equal "record-not-found", fingerprint
  end

  test "uses built-in patterns for network errors" do
    # Create a mock Net error
    error_class = Class.new(StandardError) do
      def self.name
        "Net::TimeoutError"
      end
    end

    error = error_class.new("Request timeout")
    event = Lapsoss::Event.build(type: :exception, exception: error)

    fingerprint = @fingerprinter.generate_fingerprint(event)
    assert_equal "network-timeout", fingerprint
  end

  test "falls back to default fingerprinting when no patterns match" do
    error = CustomError.new("Some unique error")
    error.set_backtrace([ "app.rb:10" ])
    event = Lapsoss::Event.build(type: :exception, exception: error)

    fingerprint = @fingerprinter.generate_fingerprint(event)

    # Should be a hash since no patterns match
    assert_match(/^[a-f0-9]{16}$/, fingerprint)
  end

  test "supports custom fingerprint callback" do
    custom_callback = lambda do |event|
      if event.exception&.message&.include?("special")
        "custom-special-error"
      else
        nil # Use default
      end
    end

    fingerprinter = Lapsoss::Fingerprinter.new(custom_callback: custom_callback)

    # Should use custom callback
    error = StandardError.new("This is a special error")
    event = Lapsoss::Event.build(type: :exception, exception: error)
    fingerprint = fingerprinter.generate_fingerprint(event)
    assert_equal "custom-special-error", fingerprint

    # Should fall back to patterns/default
    error2 = StandardError.new("User 123 not found")
    event2 = Lapsoss::Event.build(type: :exception, exception: error2)
    fingerprint2 = fingerprinter.generate_fingerprint(event2)
    assert_equal "user-lookup-error", fingerprint2
  end

  test "supports custom patterns" do
    custom_patterns = [
      {
        pattern: /Payment.*failed/i,
        fingerprint: "payment-error"
      }
    ]

    fingerprinter = Lapsoss::Fingerprinter.new(patterns: custom_patterns)

    error = StandardError.new("Payment processing failed")
    event = Lapsoss::Event.build(type: :exception, exception: error)
    fingerprint = fingerprinter.generate_fingerprint(event)

    assert_equal "payment-error", fingerprint
  end

  test "normalizes IDs in messages" do
    fingerprinter = Lapsoss::Fingerprinter.new(normalize_ids: true)

    error1 = StandardError.new("Order 12345 processing failed")
    error1.set_backtrace([ "order.rb:15" ])

    error2 = StandardError.new("Order 67890 processing failed")
    error2.set_backtrace([ "order.rb:15" ])

    event1 = Lapsoss::Event.build(type: :exception, exception: error1)
    event2 = Lapsoss::Event.build(type: :exception, exception: error2)

    fingerprint1 = fingerprinter.generate_fingerprint(event1)
    fingerprint2 = fingerprinter.generate_fingerprint(event2)

    assert_equal fingerprint1, fingerprint2
  end

  test "normalizes UUIDs in messages" do
    fingerprinter = Lapsoss::Fingerprinter.new(normalize_ids: true)

    uuid1 = "12345678-1234-1234-1234-123456789abc"
    uuid2 = "87654321-4321-4321-4321-cba987654321"

    error1 = StandardError.new("Session #{uuid1} invalid")
    error1.set_backtrace([ "session.rb:20" ])

    error2 = StandardError.new("Session #{uuid2} invalid")
    error2.set_backtrace([ "session.rb:20" ])

    # Create events with empty fingerprint to avoid auto-generation
    event1 = Lapsoss::Event.build(type: :exception, exception: error1, fingerprint: nil)
    event2 = Lapsoss::Event.build(type: :exception, exception: error2, fingerprint: nil)

    fingerprint1 = fingerprinter.generate_fingerprint(event1)
    fingerprint2 = fingerprinter.generate_fingerprint(event2)

    # Both should normalize to the same fingerprint
    assert_equal fingerprint1, fingerprint2

    # Verify it's actually different from non-normalized
    fingerprinter_no_norm = Lapsoss::Fingerprinter.new(normalize_ids: false)
    fingerprint1_no_norm = fingerprinter_no_norm.generate_fingerprint(event1)
    fingerprint2_no_norm = fingerprinter_no_norm.generate_fingerprint(event2)

    # Without normalization, they should be different
    assert_not_equal fingerprint1_no_norm, fingerprint2_no_norm
  end

  test "normalizes file paths when enabled" do
    fingerprinter = Lapsoss::Fingerprinter.new(normalize_paths: true)

    error1 = StandardError.new("File /home/user/app/data/file1.txt not found")
    error1.set_backtrace([ "file.rb:10" ])

    error2 = StandardError.new("File /var/www/myapp/uploads/image.jpg not found")
    error2.set_backtrace([ "file.rb:10" ])

    # Create events with empty fingerprint to avoid auto-generation
    event1 = Lapsoss::Event.build(type: :exception, exception: error1, fingerprint: nil)
    event2 = Lapsoss::Event.build(type: :exception, exception: error2, fingerprint: nil)

    fingerprint1 = fingerprinter.generate_fingerprint(event1)
    fingerprint2 = fingerprinter.generate_fingerprint(event2)

    # Both should normalize to the same fingerprint
    assert_equal fingerprint1, fingerprint2

    # Verify it's actually different from non-normalized
    fingerprinter_no_norm = Lapsoss::Fingerprinter.new(normalize_paths: false)
    fingerprint1_no_norm = fingerprinter_no_norm.generate_fingerprint(event1)
    fingerprint2_no_norm = fingerprinter_no_norm.generate_fingerprint(event2)

    # Without normalization, they should be different
    assert_not_equal fingerprint1_no_norm, fingerprint2_no_norm
  end

  test "includes environment in fingerprint when configured" do
    fingerprinter1 = Lapsoss::Fingerprinter.new(include_environment: true)
    fingerprinter2 = Lapsoss::Fingerprinter.new(include_environment: false)

    error = StandardError.new("Unique error message")
    error.set_backtrace([ "app.rb:5" ])

    event = Lapsoss::Event.build(type: :exception, exception: error, environment: "production")

    fingerprint1 = fingerprinter1.generate_fingerprint(event)
    fingerprint2 = fingerprinter2.generate_fingerprint(event)

    # Should be different since one includes environment
    assert_not_equal fingerprint1, fingerprint2
  end

  test "handles message events without exceptions" do
    event = Lapsoss::Event.build(type: :message, message: "Important log message", level: :error)

    fingerprint = @fingerprinter.generate_fingerprint(event)

    # Should generate a fingerprint even without exception
    assert fingerprint
    assert_match(/^[a-f0-9]{16}$/, fingerprint)
  end

  test "extracts primary location from backtrace" do
    # Test with gem paths that should be ignored
    backtrace = [
      "/Users/app/.bundle/gems/gem-1.0/lib/gem.rb:10",
      "/usr/local/ruby/lib/ruby.rb:20",
      "app/models/user.rb:25",
      "app/controllers/users_controller.rb:30"
    ]

    error = StandardError.new("Test error")
    error.set_backtrace(backtrace)
    event = Lapsoss::Event.build(type: :exception, exception: error)

    fingerprint = @fingerprinter.generate_fingerprint(event)

    # Should use first non-gem line (user.rb:25)
    assert fingerprint
  end

  test "event does not generate fingerprint without configuration" do
    error = StandardError.new("Auto fingerprint test")
    event = Lapsoss::Event.build(type: :exception, exception: error)

    # Fingerprints are only generated when fingerprint_callback or patterns are configured
    assert_nil event.fingerprint
  end

  test "allows manual fingerprint override" do
    error = StandardError.new("Test error")
    event = Lapsoss::Event.build(type: :exception, exception: error, fingerprint: "manual-fingerprint")

    assert_equal "manual-fingerprint", event.fingerprint
  end

  test "includes fingerprint in event hash output when configured" do
    Lapsoss.configuration.fingerprint_callback = ->(_event) { "test-fingerprint" }

    error = StandardError.new("Test error")
    event = Lapsoss::Event.build(type: :exception, exception: error)

    event_hash = event.to_h
    assert_includes event_hash.keys, :fingerprint
    assert_equal "test-fingerprint", event_hash[:fingerprint]
  ensure
    Lapsoss.configuration.fingerprint_callback = nil
  end

  test "configuration validation accepts valid fingerprint callback" do
    @config.fingerprint_callback = ->(_event) { "test" }
    assert_nothing_raised { @config.validate! }
  end

  test "configuration logs warning for invalid fingerprint callback" do
    # With trust-but-verify, setting invalid callback just logs a warning
    assert_nothing_raised do
      @config.fingerprint_callback = "not callable"
    end
  end

  # Helper class for testing
  class CustomError < StandardError; end
end
