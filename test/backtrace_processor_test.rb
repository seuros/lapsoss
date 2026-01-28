# frozen_string_literal: true

require_relative "test_helper"
require "lapsoss/backtrace_processor"

class BacktraceProcessorTest < ActiveSupport::TestCase
  def setup
    @processor = Lapsoss::BacktraceProcessor.new
    @sample_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "/app/controllers/sessions_controller.rb:15:in `create'",
      "/gems/actionpack-8.0.4/lib/action_controller/base.rb:123:in `process_action'",
      "/gems/activesupport-8.0.4/lib/active_support/callbacks.rb:456:in `call'",
      "/usr/local/lib/ruby/3.4.0/monitor.rb:202:in `synchronize'",
      "app.rb:10"
    ]
  end

  test "process returns frame objects" do
    frames = @processor.process(@sample_backtrace)

    assert_equal 6, frames.length
    assert(frames.all?(Lapsoss::BacktraceFrame))
  end

  test "parses ruby backtrace format" do
    frames = @processor.process(@sample_backtrace)

    frame = frames.first
    assert_equal "/app/models/user.rb", frame.filename
    assert_equal 42, frame.line_number
    assert_equal "authenticate", frame.method_name
  end

  test "handles backtrace without method name" do
    frames = @processor.process(@sample_backtrace)

    last_frame = frames.last
    assert_equal "app.rb", last_frame.filename
    assert_equal 10, last_frame.line_number
    assert_equal "<main>", last_frame.method_name
  end

  test "handles java backtrace format" do
    java_backtrace = [
      "org.jruby.Ruby.runScript(Ruby.java:123)",
      "org.jruby.Ruby.runScript(Ruby.java)",
      "org.jruby.Main.run(Main.java:45)"
    ]

    frames = @processor.process(java_backtrace)

    assert_equal 3, frames.length
    frame = frames.first
    assert_equal "Ruby.java", frame.filename
    assert_equal 123, frame.line_number
    assert_equal "org.jruby.Ruby.runScript", frame.method_name
  end

  test "handles empty backtrace" do
    frames = @processor.process([])
    assert_equal [], frames
  end

  test "handles nil backtrace" do
    frames = @processor.process(nil)
    assert_equal [], frames
  end

  test "in app detection" do
    # Mock Bundler for testing
    bundler_module = Module.new do
      def self.bundle_path
        Pathname.new("/gems")
      end
    end

    stub_const("Bundler", bundler_module) do
      frames = @processor.process(@sample_backtrace)

      assert frames[0].in_app  # /app/models/user.rb
      assert frames[1].in_app  # /app/controllers/sessions_controller.rb
      refute frames[2].in_app # /gems/actionpack-8.0.4/...
      refute frames[3].in_app # /gems/activesupport-8.0.4/...
    end
  end

  test "custom in app patterns" do
    config = Lapsoss::Configuration.new
    config.backtrace_in_app_patterns = [ %r{/app/}, %r{/lib/} ]
    processor = Lapsoss::BacktraceProcessor.new(config)

    backtrace = [
      "/app/models/user.rb:1",
      "/lib/custom.rb:2",
      "/vendor/gems/foo.rb:3"
    ]

    frames = processor.process(backtrace)

    assert frames[0].in_app  # matches /app/
    assert frames[1].in_app  # matches /lib/
    refute frames[2].in_app # doesn't match patterns
  end

  test "strip load path" do
    original_load_path = $LOAD_PATH.dup
    $LOAD_PATH.unshift("/usr/local/lib/ruby/3.4.0")

    frames = @processor.process(@sample_backtrace)
    frame = frames.find { |f| f.raw.include?("monitor.rb") }

    assert_equal "monitor.rb", frame.filename
  ensure
    $LOAD_PATH.replace(original_load_path)
  end

  test "exclude patterns" do
    config = Lapsoss::Configuration.new
    config.backtrace_exclude_patterns = [ /monitor\.rb/, /callbacks\.rb/ ]
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process(@sample_backtrace)

    assert_equal 4, frames.length
    refute(frames.any? { |f| f.filename.include?("monitor.rb") })
    refute(frames.any? { |f| f.filename.include?("callbacks.rb") })
  end

  test "frame limiting" do
    config = Lapsoss::Configuration.new
    config.backtrace_max_frames = 3
    processor = Lapsoss::BacktraceProcessor.new(config)

    large_backtrace = (1..10).map { |i| "file#{i}.rb:#{i}:in `method#{i}'" }
    frames = processor.process(large_backtrace)

    assert_equal 3, frames.length
    # Should keep first 2 and last 1 (70% head, 30% tail)
    assert_equal "file1.rb", frames[0].filename
    assert_equal "file2.rb", frames[1].filename
    assert_equal "file10.rb", frames[2].filename
  end

  test "process exception" do
    exception = StandardError.new("Test error")
    exception.set_backtrace(@sample_backtrace)

    frames = @processor.process_exception(exception)

    assert_equal 6, frames.length
    assert_equal "/app/models/user.rb", frames.first.filename
  end

  test "process exception with cause" do
    cause = ArgumentError.new("Cause error")
    cause.set_backtrace([ "/lib/validator.rb:5:in `validate'" ])

    exception = StandardError.new("Main error")
    exception.set_backtrace([ "/app/service.rb:10:in `call'" ])
    # Mock the cause method
    exception.define_singleton_method(:cause) { cause }
    frames = @processor.process_exception(exception, follow_cause: true)

    assert_equal 2, frames.length
    assert_equal "/app/service.rb", frames[0].filename
    assert_equal "/lib/validator.rb", frames[1].filename
  end

  test "format frames sentry" do
    frames = @processor.process(@sample_backtrace[0..0])
    formatted = @processor.format_frames(frames, :sentry)

    assert_equal 1, formatted.length
    frame = formatted.first
    assert_equal "/app/models/user.rb", frame[:filename]
    assert_equal 42, frame[:lineno]
    assert_equal "authenticate", frame[:function] # Sentry uses 'function'
    assert frame[:in_app]
  end

  test "format frames rollbar" do
    frames = @processor.process(@sample_backtrace[0..0])
    formatted = @processor.format_frames(frames, :rollbar)

    assert_equal 1, formatted.length
    frame = formatted.first
    assert_equal "/app/models/user.rb", frame[:filename]
    assert_equal 42, frame[:lineno]
    assert_equal "authenticate", frame[:method] # Rollbar uses 'method'
  end

  test "format frames bugsnag" do
    frames = @processor.process(@sample_backtrace[0..0])
    formatted = @processor.format_frames(frames, :bugsnag)

    assert_equal 1, formatted.length
    frame = formatted.first
    assert_equal "/app/models/user.rb", frame[:file] # Bugsnag uses 'file'
    assert_equal 42, frame[:lineNumber] # Bugsnag uses camelCase
    assert_equal "authenticate", frame[:method]
    assert frame[:inProject] # Bugsnag uses 'inProject'
  end

  test "clear cache" do
    # Populate cache by processing a backtrace
    @processor.process(@sample_backtrace)

    # Ensure cache clearing doesn't raise errors
    assert_nothing_raised { @processor.clear_cache! }
  end

  test "handles eval backtrace" do
    eval_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "(eval):1:in `eval'",
      "/app/services/dynamic_service.rb:25:in `evaluate_code'",
      "(eval):5:in `block in <main>'"
    ]

    frames = @processor.process(eval_backtrace)

    assert_equal 4, frames.length
    # Check eval frame parsing
    eval_frame = frames[1]
    assert_equal "(eval)", eval_frame.filename
    assert_equal 1, eval_frame.line_number
    assert_equal "eval", eval_frame.method_name

    # Check complex eval frame
    complex_eval_frame = frames[3]
    assert_equal "(eval)", complex_eval_frame.filename
    assert_equal 5, complex_eval_frame.line_number
    assert_equal "block in <main>", complex_eval_frame.method_name
  end

  test "handles c extension backtrace" do
    c_extension_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "/gems/nokogiri-1.13.0/lib/nokogiri.rb:10:in `parse'",
      "/gems/nokogiri-1.13.0/lib/nokogiri.rb:10:in `parse_document'",
      "/usr/local/lib/ruby/3.4.0/x86_64-linux/nokogiri.so:15:in `native_parse'"
    ]

    frames = @processor.process(c_extension_backtrace)

    assert_equal 4, frames.length
    # Check C extension frame parsing
    c_frame = frames[3]
    assert_equal "/usr/local/lib/ruby/3.4.0/x86_64-linux/nokogiri.so", c_frame.filename
    assert_equal 15, c_frame.line_number
    assert_equal "native_parse", c_frame.method_name
    refute c_frame.in_app # C extensions should not be in_app
  end

  test "handles rails engine backtrace" do
    rails_engine_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "/engines/admin_engine/app/controllers/admin_controller.rb:15:in `index'",
      "/engines/admin_engine/lib/admin_engine/engine.rb:5:in `call'",
      "/gems/railties-8.0.4/lib/rails/engine.rb:123:in `call'"
    ]

    frames = @processor.process(rails_engine_backtrace)

    assert_equal 4, frames.length
    # Rails engine frames should be considered in_app
    engine_frame = frames[1]
    assert_equal "/engines/admin_engine/app/controllers/admin_controller.rb", engine_frame.filename
    assert engine_frame.in_app

    # Engine library frame should also be in_app
    engine_lib_frame = frames[2]
    assert_equal "/engines/admin_engine/lib/admin_engine/engine.rb", engine_lib_frame.filename
    assert engine_lib_frame.in_app
  end

  test "handles path based gem dependencies" do
    path_gem_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "/usr/src/my_local_gem/lib/my_gem.rb:10:in `process'",
      "/home/dev/projects/shared_lib/lib/shared.rb:5:in `helper'"
    ]

    # Configure custom in_app patterns for local development
    config = Lapsoss::Configuration.new
    config.backtrace_in_app_patterns = [ %r{/app/}, %r{/usr/src/my_local_gem}, %r{/home/dev/projects/shared_lib} ]
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process(path_gem_backtrace)

    assert_equal 3, frames.length
    assert frames.all?(&:in_app) # All should be considered in_app with custom patterns
  end

  test "handles very long backtrace" do
    # Test with a very long backtrace (stack overflow scenario)
    long_backtrace = (1..1000).map { |i| "/app/lib/recursive.rb:#{i}:in `recurse'" }

    config = Lapsoss::Configuration.new
    config.backtrace_max_frames = 50
    processor = Lapsoss::BacktraceProcessor.new(config)

    frames = processor.process(long_backtrace)

    assert_equal 50, frames.length
    # Should keep first 35 and last 15 (70% head, 30% tail)
    assert_equal 1, frames[0].line_number
    assert_equal 35, frames[34].line_number
    assert_equal 986, frames[35].line_number # Should jump to tail
    assert_equal 1000, frames[49].line_number
  end

  test "handles malformed backtrace lines" do
    malformed_backtrace = [
      "/app/models/user.rb:42:in `authenticate'",
      "invalid line format",
      "/app/controllers/sessions_controller.rb:15:in `create'",
      "",
      "/app/lib/helper.rb:abc:in `process'", # Invalid line number
      "/app/lib/helper.rb::in `process'", # Missing line number
      "/app/lib/helper.rb:10:in" # Missing method
    ]

    frames = @processor.process(malformed_backtrace)

    # Should gracefully handle malformed lines (deduplication may reduce count)
    assert_equal 6, frames.length

    # Check that valid lines are still processed correctly
    valid_frame = frames[0]
    assert_equal "/app/models/user.rb", valid_frame.filename
    assert_equal 42, valid_frame.line_number
    assert_equal "authenticate", valid_frame.method_name

    # Check that invalid line number defaults to 0
    invalid_lineno_frame = frames[4]
    assert_equal "/app/lib/helper.rb", invalid_lineno_frame.filename
    assert_equal 0, invalid_lineno_frame.line_number
    assert_equal "process", invalid_lineno_frame.method_name
  end

  private

  def stub_const(const_name, value)
    if Object.const_defined?(const_name)
      old_value = Object.const_get(const_name)
      Object.send(:remove_const, const_name)
    end
    Object.const_set(const_name, value)
    yield
  ensure
    Object.send(:remove_const, const_name) if Object.const_defined?(const_name)
    Object.const_set(const_name, old_value) if defined?(old_value)
  end
end
