# frozen_string_literal: true

require_relative "test_helper"

class PipelineMiddlewareTest < ActiveSupport::TestCase
  class CollectingAdapter < Lapsoss::Adapters::Base
    attr_reader :events

    def initialize(name, settings = {})
      super
      @events = []
    end

    def capture(event)
      @events << event
    end
  end

  setup do
    Lapsoss.configuration.clear!
    @collector = CollectingAdapter.new(:collector)
  end

  test "sample filter drops events" do
    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.configure_pipeline do |pipeline|
        pipeline.sample(rate: 0.0)
      end
    end

    Lapsoss::Registry.instance.register_adapter(@collector)

    Lapsoss.capture_message("hello")
    assert_empty @collector.events
  end

  test "user context enhancer merges provider data" do
    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.configure_pipeline do |pipeline|
        pipeline.enhance_user_context(
          provider: ->(_event, _hint) { { id: 42, email: "user@example.com" } },
          privacy_mode: true
        )
      end
    end

    Lapsoss::Registry.instance.register_adapter(@collector)

    Lapsoss.capture_message("with user", context: {}, user: { role: "admin" })

    assert_equal 1, @collector.events.size
    user = @collector.events.first.context[:user]
    assert_equal 42, user[:id]
    refute_includes user.keys, :role
    refute_includes user.keys, :email
  end
end
