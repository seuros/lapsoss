# frozen_string_literal: true

module Lapsoss
  # Only exact, unmodified built-ins enter Rust. Subclasses and singleton
  # overrides retain the documented Ruby customization path.
  module NativeAdapters
    TYPES = {
      "Lapsoss::Adapters::SentryAdapter" => :sentry,
      "Lapsoss::Adapters::TelebugsAdapter" => :telebugs,
      "Lapsoss::Adapters::RollbarAdapter" => :rollbar,
      "Lapsoss::Adapters::AppsignalAdapter" => :appsignal,
      "Lapsoss::Adapters::InsightHubAdapter" => :insight_hub,
      "Lapsoss::Adapters::BugsnagAdapter" => :bugsnag,
      "Lapsoss::Adapters::OpenobserveAdapter" => :openobserve,
      "Lapsoss::Adapters::OtlpAdapter" => :otlp,
      "Lapsoss::Adapters::LoggerAdapter" => :logger
    }.freeze

    module_function

    def describe(adapter)
      type = TYPES[adapter.class.name]
      return unless type
      return if adapter.singleton_methods.include?(:capture)

      settings = adapter.settings.reject { |key, _| key.to_sym == :logger }.dup
      case type
      when :rollbar
        settings[:access_token] ||= adapter.instance_variable_get(:@access_token)
      when :appsignal
        settings[:frontend_api_key] ||= adapter.instance_variable_get(:@frontend_api_key)
        settings[:push_api_key] ||= adapter.instance_variable_get(:@push_api_key)
        settings[:app_name] ||= adapter.instance_variable_get(:@app_name)
      when :insight_hub, :bugsnag
        settings[:api_key] ||= adapter.instance_variable_get(:@api_key)
      when :openobserve
        %i[endpoint username password org stream].each do |key|
          settings[key] ||= adapter.instance_variable_get(:"@#{key}")
        end
      when :otlp
        settings[:endpoint] ||= adapter.instance_variable_get(:@endpoint)
        settings[:service_name] ||= adapter.instance_variable_get(:@service_name)
        settings[:environment] ||= adapter.instance_variable_get(:@environment)
        settings[:headers] = adapter.instance_variable_get(:@headers)
      end
      { name: adapter.name.to_s, type: type, settings: settings }
    end

    def transport(configuration)
      %i[timeout max_retries initial_backoff max_backoff backoff_multiplier jitter ssl_verify].to_h do |key|
        [ key, configuration.public_send(:"transport_#{key}") ]
      end
    end
  end
end
