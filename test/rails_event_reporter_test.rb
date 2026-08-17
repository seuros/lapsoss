# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsEventReporterTest < ActiveSupport::TestCase
  setup do
    skip "Rails.event structured event reporter requires Rails 8.1+" unless Rails.respond_to?(:event)

    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
    Lapsoss::Current.reset

    Lapsoss.configure do |config|
      config.async = false
      config.use_logger(name: :event_test, logger: Logger.new(nil))
    end
  end

  teardown do
    Lapsoss.configuration.clear!
    Lapsoss::Registry.instance.clear!
    Lapsoss::Current.reset
  end

  test "structured events are recorded as breadcrumbs" do
    Rails.event.notify("user.created", id: 123)

    crumb = Lapsoss.current_scope.breadcrumbs.last
    assert crumb, "Should have recorded a breadcrumb"
    assert_equal "user.created", crumb[:message]
    assert_equal :event, crumb[:type]
    assert_equal({ id: 123 }, crumb[:metadata][:payload])
    assert_match(/rails_event_reporter_test\.rb:\d+/, crumb[:metadata][:source])
  end

  test "event tags are included in breadcrumb metadata" do
    Rails.event.tagged(graphql: true) do
      Rails.event.notify("query.executed", operation: "getUser")
    end

    crumb = Lapsoss.current_scope.breadcrumbs.last
    assert_equal({ graphql: true }, crumb[:metadata][:tags])
  end

  test "event objects are serialized via their serialize method" do
    event_class = Class.new do
      def self.name = "OrderShippedEvent"

      def serialize
        { order_id: 42 }
      end
    end

    Rails.event.notify(event_class.new)

    crumb = Lapsoss.current_scope.breadcrumbs.last
    assert_equal "OrderShippedEvent", crumb[:message]
    assert_equal({ order_id: 42 }, crumb[:metadata][:payload])
  end

  test "capture_rails_events = false disables breadcrumb recording" do
    Lapsoss.configuration.capture_rails_events = false

    Rails.event.notify("ignored.event", foo: "bar")

    assert_empty Lapsoss.current_scope.breadcrumbs
  end

  test "rails_event_filter limits which events become breadcrumbs" do
    Lapsoss.configuration.rails_event_filter = ->(event) { event[:name] != "noisy.event" }

    Rails.event.notify("noisy.event")
    Rails.event.notify("useful.event")

    messages = Lapsoss.current_scope.breadcrumbs.map { |c| c[:message] }
    assert_includes messages, "useful.event"
    assert_not_includes messages, "noisy.event"
  end

  test "emit is a no-op when Lapsoss is not configured" do
    Lapsoss.instance_variable_set(:@client, nil)

    assert_nothing_raised do
      Rails.event.notify("unconfigured.event")
    end
  end
end
