# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/lapsoss/backtrace_frame_factory"

class BacktraceProcessingTest < ActiveSupport::TestCase
  setup do
    @processor = Lapsoss::BacktraceProcessor.new
    @sample_backtrace = [
      "/app/models/user.rb:25:in `find_user'",
      "/app/controllers/users_controller.rb:15:in `show'",
      "/gems/rails-8.0.4/actionpack/lib/action_controller.rb:200:in `call'",
      "/ruby/lib/ruby/3.4.0/kernel.rb:150:in `require'",
      "block in rescue in /app/services/user_service.rb:45:in `process'"
    ]
  end

  test "processes backtrace frames correctly" do
    frames = @processor.process_backtrace(@sample_backtrace)

    assert_equal 5, frames.length

    # Check first frame (app code)
    first_frame = frames[0]
    assert_equal "/app/models/user.rb", first_frame.filename
    assert_equal 25, first_frame.line_number
    assert_equal "find_user", first_frame.method_name
    assert first_frame.in_app

    # Find the gem frame by examining all frames
    gem_frame = frames.find { |f| f.filename.include?("/gems/") }
    assert_not_nil gem_frame, "Should have a gem frame"
    assert_equal "/gems/rails-8.0.4/actionpack/lib/action_controller.rb", gem_frame.filename
    assert_equal 200, gem_frame.line_number
    assert_equal "call", gem_frame.method_name
    assert_not gem_frame.in_app
  end

  test "filters out excluded patterns" do
    config = {
      exclude_patterns: [ /rspec/, /test/ ]
    }
    processor = Lapsoss::BacktraceProcessor.new(config)

    backtrace = [
      "/app/models/user.rb:25:in `find_user'",
      "/gems/rspec/lib/rspec.rb:100:in `run'",
      "/app/test/user_test.rb:50:in `test_user'"
    ]

    frames = processor.process_backtrace(backtrace)

    # Should only have the app frame, excluding rspec and test frames
    assert_equal 1, frames.length
    assert_equal "/app/models/user.rb", frames[0].filename
  end

  test "limits frame count when configured" do
    config = { max_frames: 2 }
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process_backtrace(@sample_backtrace)

    assert_equal 2, frames.length
  end

  test "prefers app frames over library frames" do
    config = { max_frames: 3 }
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process_backtrace(@sample_backtrace)

    assert_equal 3, frames.length
    # Should include both app frames and one library frame
    app_frames = frames.select(&:in_app)
    assert app_frames.length >= 2
  end

  test "adds code context when enabled" do
    # Create a temporary file for testing
    test_file = "/tmp/test_backtrace_file.rb"
    File.write(test_file, "line 1\nline 2\nTEST LINE\nline 4\nline 5\n")

    backtrace = [ "#{test_file}:3:in `test_method'" ]
    frames = @processor.process_backtrace(backtrace)

    assert_equal 1, frames.length
    frame = frames[0]

    # Should have code context
    assert_not_nil frame.code_context
    assert_equal "TEST LINE", frame.code_context[:context_line]
    assert_equal [ "line 1", "line 2" ], frame.code_context[:pre_context]
    assert_equal [ "line 4", "line 5" ], frame.code_context[:post_context]
  ensure
    FileUtils.rm_f(test_file)
  end

  test "handles exception backtrace processing" do
    raise StandardError, "Test error"
  rescue StandardError => e
    frames = @processor.process_exception_backtrace(e)

    assert frames.any?

    # First frame should be marked as crash frame
    assert frames[0].crash_frame?
    assert_equal "StandardError", frames[0].exception_class
  end

  test "converts to different adapter formats" do
    frames = @processor.process_backtrace(@sample_backtrace)

    # Test Sentry format
    sentry_format = @processor.to_sentry_format(frames)
    assert sentry_format.is_a?(Array)
    assert_includes sentry_format[0].keys, :filename
    assert_includes sentry_format[0].keys, :lineno
    assert_includes sentry_format[0].keys, :function

    # Test Rollbar format
    rollbar_format = @processor.to_rollbar_format(frames)
    assert rollbar_format.is_a?(Array)
    assert_includes rollbar_format[0].keys, :filename
    assert_includes rollbar_format[0].keys, :lineno
    assert_includes rollbar_format[0].keys, :method

    # Test Bugsnag format
    bugsnag_format = @processor.to_bugsnag_format(frames)
    assert bugsnag_format.is_a?(Array)
    assert_includes bugsnag_format[0].keys, :file
    assert_includes bugsnag_format[0].keys, :lineNumber
    assert_includes bugsnag_format[0].keys, :method
  end

  test "deduplicates identical frames when enabled" do
    duplicate_backtrace = [
      "/app/models/user.rb:25:in `find_user'",
      "/app/models/user.rb:25:in `find_user'", # Duplicate
      "/app/controllers/users_controller.rb:15:in `show'"
    ]

    config = { dedupe_frames: true }
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process_backtrace(duplicate_backtrace)

    assert_equal 2, frames.length # Should remove duplicate
  end

  test "disables deduplication when configured" do
    duplicate_backtrace = [
      "/app/models/user.rb:25:in `find_user'",
      "/app/models/user.rb:25:in `find_user'", # Duplicate
      "/app/controllers/users_controller.rb:15:in `show'"
    ]

    config = { dedupe_frames: false }
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process_backtrace(duplicate_backtrace)

    assert_equal 3, frames.length # Should keep duplicate
  end
end

class BacktraceFrameTest < ActiveSupport::TestCase
  test "parses standard Ruby backtrace format" do
    line = "/app/models/user.rb:25:in `find_user'"
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(line)

    assert_equal "/app/models/user.rb", frame.filename
    assert_equal 25, frame.line_number
    assert_equal "find_user", frame.method_name
    assert frame.valid?
  end

  test "parses Ruby format without method" do
    line = "/app/models/user.rb:25"
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(line)

    assert_equal "/app/models/user.rb", frame.filename
    assert_equal 25, frame.line_number
    assert_equal "<main>", frame.method_name
    assert frame.valid?
  end

  test "parses block format" do
    line = "/app/models/user.rb:30:in `block in find_users'"
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(line)

    assert_equal "/app/models/user.rb", frame.filename
    assert_equal 30, frame.line_number
    assert_equal "block in find_users", frame.method_name
    assert_not_nil frame.block_info
    assert_equal "find_users", frame.block_info[:in_method]
  end

  test "identifies app vs library code" do
    app_frame = Lapsoss::BacktraceFrameFactory.from_raw_line("/app/models/user.rb:25:in `find_user'")
    gem_frame = Lapsoss::BacktraceFrameFactory.from_raw_line("/gems/rails/actionpack.rb:100:in `call'")

    assert app_frame.in_app
    assert_not gem_frame.in_app
  end

  test "respects custom in_app_patterns" do
    patterns = [ %r{/custom_lib/} ]
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(
      "/custom_lib/my_module.rb:10:in `method'",
      in_app_patterns: patterns
    )

    assert frame.in_app
  end

  test "excludes frames based on patterns" do
    patterns = [ /test/, /spec/ ]
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(
      "/app/test/user_test.rb:10:in `test_method'",
      exclude_patterns: patterns
    )

    assert frame.excluded?(patterns)
  end

  test "extracts module and function names" do
    # Class method
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line("/app/models/user.rb:25:in `User.find_by_email'")
    assert_equal "User", frame.module_name
    assert_equal "find_by_email", frame.function

    # Instance method
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line("/app/models/user.rb:25:in `User#full_name'")
    assert_equal "User", frame.module_name
    assert_equal "full_name", frame.function
  end

  test "handles relative filenames" do
    load_paths = [ "/app" ]
    frame = Lapsoss::BacktraceFrameFactory.from_raw_line(
      "/app/models/user.rb:25:in `find_user'",
      load_paths: load_paths
    )

    assert_equal "models/user.rb", frame.relative_filename(load_paths)
  end
end
