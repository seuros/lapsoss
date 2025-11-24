# frozen_string_literal: true

require_relative "test_helper"

class AdapterEndpointIsolationTest < ActiveSupport::TestCase
  test "sentry adapters keep separate endpoints" do
    Lapsoss.configure do |config|
      config.async = false
      config.logger = Logger.new(StringIO.new)
      config.use_sentry(name: :us, dsn: "https://key@us.sentry.io/123")
      config.use_sentry(name: :eu, dsn: "https://key@eu.sentry.io/456")
    end

    us = Lapsoss::Registry.instance[:us]
    eu = Lapsoss::Registry.instance[:eu]

    assert_equal "https://us.sentry.io:443", us.api_endpoint
    assert_equal "https://eu.sentry.io:443", eu.api_endpoint
  end
end
