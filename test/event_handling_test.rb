# frozen_string_literal: true

require_relative "test_helper"

class EventHandlingTest < ActiveSupport::TestCase
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

  test "capture_exception keeps level and merges context" do
    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
    end

    Lapsoss::Registry.instance.register_adapter(@collector)

    error = StandardError.new("boom")
    Lapsoss.capture_exception(error, level: :warning, context: { request_id: "abc" }, tags: { source: "rails" })

    event = @collector.events.first
    assert_equal :warning, event.level
    assert_equal "abc", event.context[:context][:request_id]
    assert_equal "rails", event.context[:tags][:source]
  end

  test "exclusion filter prevents delivery" do
    filter = Lapsoss::ExclusionFilter.new(excluded_exceptions: [ArgumentError])

    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.exclusion_filter = filter
    end

    Lapsoss::Registry.instance.register_adapter(@collector)

    Lapsoss.capture_exception(ArgumentError.new("nope"))
    assert_empty @collector.events
  end

  test "error handler accepts three arguments for delivery failures" do
    calls = []
    handler = ->(adapter, event, error) { calls << [adapter, event, error] }

    failing_adapter = Class.new(Lapsoss::Adapters::Base) do
      include Lapsoss::Adapters::Concerns::EnvelopeBuilder
      include Lapsoss::Adapters::Concerns::HttpDelivery

      def initialize(name, settings = {})
        super
        @api_endpoint = "https://example.com"
        @api_path = "/"
      end

      def capture(event)
        deliver(event)
      end

      private

      def build_payload(_event)
        { ok: true }
      end

      def http_client
        @http_client ||= Class.new do
          def post(*)
            raise Lapsoss::DeliveryError, "boom"
          end
        end.new
      end
    end

    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.error_handler = handler
    end

    adapter = failing_adapter.new(:failing)
    Lapsoss::Registry.instance.register_adapter(adapter)

    Lapsoss.capture_message("trigger failure")

    assert_equal 1, calls.size
    called_adapter, called_event, called_error = calls.first
    assert_equal adapter, called_adapter
    assert_equal :message, called_event.type
    assert_kind_of Lapsoss::DeliveryError, called_error
  end
end
