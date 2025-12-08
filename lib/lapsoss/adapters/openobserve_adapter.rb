# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "base64"

module Lapsoss
  module Adapters
    # OpenObserve adapter - sends errors as structured JSON logs
    # OpenObserve is an observability platform that accepts logs via simple JSON API
    # Docs: https://openobserve.ai/docs/ingestion/
    class OpenobserveAdapter < Base
      include Concerns::LevelMapping
      include Concerns::HttpDelivery

      self.level_mapping_type = :openobserve

      DEFAULT_STREAM = "errors"
      DEFAULT_ORG = "default"

      def initialize(name, settings = {})
        super

        @endpoint = settings[:endpoint].presence || ENV["OPENOBSERVE_ENDPOINT"]
        @username = settings[:username].presence || ENV["OPENOBSERVE_USERNAME"]
        @password = settings[:password].presence || ENV["OPENOBSERVE_PASSWORD"]
        @org = settings[:org].presence || ENV["OPENOBSERVE_ORG"] || DEFAULT_ORG
        @stream = settings[:stream].presence || ENV["OPENOBSERVE_STREAM"] || DEFAULT_STREAM

        if @endpoint.blank? || @username.blank? || @password.blank?
          Lapsoss.configuration.logger&.warn "[Lapsoss::OpenobserveAdapter] Missing endpoint, username or password - adapter disabled"
          @enabled = false
          return
        end

        setup_endpoint
      end

      def capture(event)
        deliver(event.scrubbed)
      end

      def capabilities
        super.merge(
          breadcrumbs: false,
          code_context: true,
          data_scrubbing: true
        )
      end

      private

      def setup_endpoint
        uri = URI.parse(@endpoint)
        @api_endpoint = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        @api_path = "/api/#{@org}/#{@stream}/_json"
      end

      def build_payload(event)
        # OpenObserve expects JSON array of log entries
        [ build_log_entry(event) ]
      end

      def build_log_entry(event)
        entry = {
          _timestamp: timestamp_microseconds(event.timestamp),
          level: map_level(event.level),
          logger: "lapsoss",
          environment: event.environment.presence || "production",
          service: @settings[:service_name].presence || "rails"
        }

        case event.type
        when :exception
          entry.merge!(build_exception_entry(event))
        when :message
          entry[:message] = event.message
        else
          entry[:message] = event.message || "Unknown event"
        end

        # Add optional context
        entry[:user] = event.user_context if event.user_context.present?
        entry[:tags] = event.tags if event.tags.present?
        entry[:extra] = event.extra if event.extra.present?
        entry[:request] = event.request_context if event.request_context.present?
        entry[:transaction] = event.transaction if event.transaction.present?
        entry[:fingerprint] = event.fingerprint if event.fingerprint.present?

        entry.compact_blank
      end

      def build_exception_entry(event)
        entry = {
          message: "#{event.exception_type}: #{event.exception_message}",
          exception_type: event.exception_type,
          exception_message: event.exception_message
        }

        if event.has_backtrace?
          entry[:stacktrace] = format_stacktrace(event)
          entry[:stacktrace_raw] = event.backtrace_frames.map do |frame|
            "#{frame.absolute_path || frame.filename}:#{frame.line_number} in `#{frame.method_name}`"
          end
        end

        entry
      end

      def format_stacktrace(event)
        event.backtrace_frames.map do |frame|
          frame_entry = {
            filename: frame.filename,
            abs_path: frame.absolute_path || frame.filename,
            function: frame.method_name || frame.function,
            lineno: frame.line_number,
            in_app: frame.in_app
          }

          if frame.code_context.present?
            frame_entry[:context_line] = frame.code_context[:context_line]
            frame_entry[:pre_context] = frame.code_context[:pre_context]
            frame_entry[:post_context] = frame.code_context[:post_context]
          end

          frame_entry.compact
        end
      end

      def timestamp_microseconds(time)
        # OpenObserve expects _timestamp in microseconds
        (time.to_f * 1_000_000).to_i
      end

      def serialize_payload(payload)
        json = ActiveSupport::JSON.encode(payload)

        if json.bytesize >= compress_threshold
          [ ActiveSupport::Gzip.compress(json), true ]
        else
          [ json, false ]
        end
      end

      def compress_threshold
        @settings[:compress_threshold] || 1024
      end

      def adapter_specific_headers
        credentials = Base64.strict_encode64("#{@username}:#{@password}")
        {
          "Authorization" => "Basic #{credentials}"
        }
      end
    end
  end
end
