# frozen_string_literal: true

require "test_helper"

class SilenceTest < ActiveSupport::TestCase
  setup do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
    Lapsoss::Current.reset
  end

  test "silence suppresses capture within the block" do
    output = StringIO.new
    Lapsoss.configure do |config|
      config.async = false
      config.use_logger(logger: Logger.new(output))
    end

    Lapsoss.silence do
      Lapsoss.capture_exception(StandardError.new("muted error"))
      Lapsoss.capture_message("muted message")
    end

    assert_empty output.string

    Lapsoss.capture_exception(StandardError.new("loud error"))
    assert_includes output.string, "loud error"
  end

  test "silence restores previous state when the block raises" do
    assert_raises(RuntimeError) do
      Lapsoss.silence { raise "boom" }
    end

    assert_not Lapsoss.silenced?
  end

  test "silence is nestable" do
    Lapsoss.silence do
      Lapsoss.silence { assert Lapsoss.silenced? }
      assert Lapsoss.silenced?, "Inner block exit should not unsilence the outer block"
    end

    assert_not Lapsoss.silenced?
  end

  test "silence is thread-local" do
    Lapsoss.silence do
      other_thread_silenced = Thread.new { Lapsoss.silenced? }.value
      assert_not other_thread_silenced
    end
  end

  test "breadcrumbs still accumulate while silenced" do
    Lapsoss.configure do |config|
      config.async = false
      config.use_logger(logger: Logger.new(nil))
    end

    Lapsoss.silence do
      Lapsoss.add_breadcrumb("still recorded")
    end

    assert_equal [ "still recorded" ], Lapsoss.current_scope.breadcrumbs.map { |c| c[:message] }
  end
end
