# frozen_string_literal: true

class TestAdapter
  attr_reader :events

  def initialize
    @events = []
    @enabled = true
  end

  def name
    :test_adapter
  end

  def enabled?
    @enabled
  end

  def enable!
    @enabled = true
  end

  def disable!
    @enabled = false
  end

  def capture(event)
    return false unless enabled?

    @events << event
    true
  end

  def captured_events
    @events
  end

  def clear!
    @events.clear
  end

  def last_event
    @events.last
  end

  def event_count
    @events.size
  end
end
