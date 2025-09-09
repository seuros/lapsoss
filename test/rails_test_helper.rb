# frozen_string_literal: true

# Rails test helper for integration testing
require_relative "test_helper"

# Set up Rails environment
ENV["RAILS_ENV"] = "test"

# Load the dummy application
require_relative "dummy/config/environment"

# Configure Rails for testing
Rails.application.config.eager_load = false
Rails.application.config.cache_classes = true
Rails.application.config.active_support.test_order = :random

# Load Rails test helpers
require "rails/test_help"

class ActionDispatch::IntegrationTest
  setup do
    # Clear Lapsoss state before each test
    Lapsoss::Registry.instance.clear!
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss::Current.reset

    # Temporarily disable Rails error subscriber to avoid double capture
    @original_subscribers = Rails.error.instance_variable_get(:@subscribers).dup
    Rails.error.instance_variable_get(:@subscribers).reject! { |s| s.is_a?(Lapsoss::RailsErrorSubscriber) }
  end

  teardown do
    # Restore original subscribers
    if @original_subscribers
      Rails.error.instance_variable_set(:@subscribers, @original_subscribers)
    end
  end
end

class ActiveSupport::TestCase
  # Add Rails-specific test helpers here

  def with_lapsoss_configured
    Lapsoss.configure do |config|
      # Don't register any adapters by default
      # Tests will register their own adapters
      config.async = false # Synchronous for testing
      config.debug = true
      config.capture_request_context = true
      config.logger = ActiveSupport::TaggedLogging.new(Rails.logger).tagged("Lapsoss") # Ensure logger is set for tests
    end

    yield
  ensure
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss::Registry.instance.clear!
  end
end
