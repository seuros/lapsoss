# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lapsoss"

require "active_support"
require "active_support/test_case"
require "active_support/testing/autorun"
require "dotenv/load"
require "vcr"
require "webmock"

# Configure VCR
VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock
  config.default_cassette_options = {
    record: ENV["VCR_RECORD_MODE"]&.to_sym || :new_episodes,
    match_requests_on: %i[method uri body]
  }

  # Filter sensitive data
  config.filter_sensitive_data("<SENTRY_US_DSN>") { ENV["SENTRY_US_DSN"] || "https://key@us.sentry.io/123" }
  config.filter_sensitive_data("<SENTRY_EU_DSN>") { ENV["SENTRY_EU_DSN"] || "https://key@eu.sentry.io/456" }
  config.filter_sensitive_data("<TELEBUGS_DSN>") { ENV["TELEBUGS_DSN"] || "https://key@telebugs.com/123" }
  config.filter_sensitive_data("<APPSIGNAL_FRONTEND_API_KEY>") { ENV["APPSIGNAL_FRONTEND_API_KEY"] || "test-api-key" }
  config.filter_sensitive_data("<INSIGHT_HUB_API_KEY>") { ENV["INSIGHT_HUB_API_KEY"] || "test-api-key" }
  config.filter_sensitive_data("<BUGSNAG_API_KEY>") { ENV["BUGSNAG_API_KEY"] || "test-api-key" }
  config.filter_sensitive_data("<ROLLBAR_ACCESS_TOKEN>") { ENV["ROLLBAR_ACCESS_TOKEN"] || "test-token" }
  config.filter_sensitive_data("<OPENOBSERVE_ENDPOINT>") { ENV["OPENOBSERVE_ENDPOINT"] || "http://localhost:5080" }
  config.filter_sensitive_data("<OPENOBSERVE_USERNAME>") { ENV["OPENOBSERVE_USERNAME"] || "seuros@example.com" }
  config.filter_sensitive_data("<OPENOBSERVE_PASSWORD>") { ENV["OPENOBSERVE_PASSWORD"] || "ShipItFast!" }
  config.filter_sensitive_data("<AUTHORIZATION>") { ENV["AUTHORIZATION"] }
  config.filter_sensitive_data("<COOKIE>") { ENV["HTTP_COOKIE"] }

  # Filter local paths in stack traces
  config.filter_sensitive_data("/path/to/ruby") { RbConfig::CONFIG["rubylibdir"].split("/lib/ruby").first }
  config.filter_sensitive_data("/path/to/project") { File.expand_path("../..", __dir__) }
  config.filter_sensitive_data("/home/user") { Dir.home }

  # Filter Sentry auth headers and AppSignal API keys in URLs
  config.before_record do |interaction|
    # Filter Sentry organization and project IDs from URLs
    if interaction.request.uri.match?(%r{https://o\d+\.ingest\.(us|eu)\.sentry\.io/api/\d+/envelope/})
      interaction.request.uri = interaction.request.uri.gsub(
        %r{https://o\d+\.ingest\.(us|eu)\.sentry\.io/api/\d+/envelope/},
        'https://o<ORG_ID>.ingest.\1.sentry.io/api/<PROJECT_ID>/envelope/'
      )
    end

    # Filter Telebugs project IDs and API keys from URLs
    if interaction.request.uri.match?(%r{telebugs\.com/api/v1/sentry_errors})
      interaction.request.uri = interaction.request.uri.gsub(
        %r{https://[^/]+\.telebugs\.com/api/v1/sentry_errors/api/\d+/envelope/},
        "https://lapsoss.telebugs.com/api/v1/sentry_errors/api/<PROJECT_ID>/envelope/"
      )
    end

    # Normalize/remove auth-like headers
    %w[Authorization X-Api-Key X-API-Key X-Auth-Token X-Access-Token X-Rollbar-Access-Token Bugsnag-Api-Key].each do |hdr|
      if interaction.request.headers[hdr]
        interaction.request.headers[hdr] = [ "<#{hdr.upcase.gsub('-', '_')}>" ]
      end
    end

    # Filter User-Agent to avoid version changes
    if interaction.request.headers["User-Agent"]
      user_agent = interaction.request.headers["User-Agent"].first
      # Replace version numbers with placeholder
      filtered_agent = user_agent.gsub(/lapsoss\/[\d.]+/, "lapsoss/<VERSION>")
      interaction.request.headers["User-Agent"] = [ filtered_agent ]
    end

    # Filter X-Lapsoss-Version header
    if interaction.request.headers["X-Lapsoss-Version"]
      interaction.request.headers["X-Lapsoss-Version"] = [ "<VERSION>" ]
    end

    if interaction.request.headers["X-Sentry-Auth"]
      # Filter out version number to avoid cassette changes on version bumps
      interaction.request.headers["X-Sentry-Auth"] = [ "Sentry sentry_version=7, sentry_client=lapsoss/<VERSION>, sentry_key=<FILTERED>" ]
    end

    # Filter Telebugs client header
    if interaction.request.headers["X-Telebugs-Client"]
      interaction.request.headers["X-Telebugs-Client"] = [ "lapsoss/<VERSION>" ]
    end

    # Filter AppSignal API keys from query parameters
    if interaction.request.uri.include?("appsignal-endpoint.net")
      interaction.request.uri = interaction.request.uri.gsub(/api_key=[^&]+/, "api_key=<APPSIGNAL_FRONTEND_API_KEY>")
    end

    # Filter Rollbar access tokens from headers
    if interaction.request.headers["X-Rollbar-Access-Token"]
      interaction.request.headers["X-Rollbar-Access-Token"] = [ "<ROLLBAR_ACCESS_TOKEN>" ]
    end

    # Filter tokens from request bodies
    if interaction.request.body.is_a?(String)
      # Filter Rollbar access tokens in JSON payloads (if present)
      interaction.request.body = interaction.request.body.gsub(
        /"access_token":"[^"]+",?/,
        ""
      )
      # Filter Insight Hub API keys in JSON payloads
      interaction.request.body = interaction.request.body.gsub(
        /"apiKey":"[^"]+"/,
        '"apiKey":"<INSIGHT_HUB_API_KEY>"'
      )

      # Replace email addresses
      interaction.request.body = interaction.request.body.gsub(/\b[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\b/i, "<EMAIL>")
      # Replace hostnames keys
      interaction.request.body = interaction.request.body.gsub(/"hostname":"[^"]+"/, '"hostname":"<HOSTNAME>"')
      # Replace potential home directories
      home = Regexp.escape(Dir.home)
      interaction.request.body = interaction.request.body.gsub(/#{home}/, "/home/user")
    end

    # Scrub response bodies where applicable
    if interaction.response.body.is_a?(String)
      body = interaction.response.body
      body = body.gsub(/\b[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\b/i, "<EMAIL>")
      body = body.gsub(/"hostname":"[^"]+"/, '"hostname":"<HOSTNAME>"')
      interaction.response.body = body
    end

    # Drop Set-Cookie from responses
    interaction.response.headers.delete("Set-Cookie")
  end
end

class ActiveSupport::TestCase
  setup do
    # Clear registry before each test
    Lapsoss::Registry.instance.clear!
    # Reset configuration
    Lapsoss.instance_variable_set(:@configuration, nil)
    # Clear thread-local state
    Lapsoss::Current.reset
  end

  def with_env(key, value)
    old_value = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    ENV[key] = old_value
  end
end
