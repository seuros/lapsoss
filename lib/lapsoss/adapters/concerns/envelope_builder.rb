# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/object/blank"
require "active_support/json"
require "active_support/core_ext/numeric/bytes"
require "active_support/gzip"
require "securerandom"

module Lapsoss
  module Adapters
    module Concerns
      module EnvelopeBuilder
        extend ActiveSupport::Concern

        GZIP_THRESHOLD = 30.kilobytes

        included do
          class_attribute :envelope_format, default: :json
          class_attribute :compress_threshold, default: GZIP_THRESHOLD
        end

        # Build envelope with common structure
        def build_envelope_wrapper(event)
          envelope = {
            id: event.fingerprint.presence || SecureRandom.uuid,
            timestamp: format_timestamp(event.timestamp),
            environment: event.environment.presence || "production",
            level: map_level(event.level),
            platform: "ruby",
            sdk: sdk_info
          }

          # Add event-specific data
          envelope.merge!(build_event_data(event))

          # Add context data
          envelope.merge!(
            tags: event.tags.presence,
            user: event.user_context.presence,
            extra: event.extra.presence,
            breadcrumbs: format_breadcrumbs(event.breadcrumbs)
          ).compact_blank
        end

        # Format timestamp using AS helpers
        def format_timestamp(time)
          time = Time.current if time.blank?
          time.in_time_zone("UTC").iso8601
        end

        # Format breadcrumbs consistently
        def format_breadcrumbs(breadcrumbs)
          return nil if breadcrumbs.blank?

          breadcrumbs.map do |crumb|
            {
              timestamp: format_timestamp(crumb[:timestamp]),
              type: crumb[:type].presence || "default",
              message: crumb[:message],
              data: crumb.except(:timestamp, :type, :message).presence
            }.compact_blank
          end
        end

        # SDK info for all adapters
        def sdk_info
          {
            name: "lapsoss",
            version: Lapsoss::VERSION,
            packages: [ {
              name: "lapsoss-ruby",
              version: Lapsoss::VERSION
            } ]
          }
        end

        # Serialize and optionally compress
        def serialize_payload(data, compress: :auto)
          json = ActiveSupport::JSON.encode(data)

          should_compress = case compress
          when :auto then json.bytesize >= compress_threshold
          when true then true
          else false
          end

          if should_compress
            [ ActiveSupport::Gzip.compress(json), true ]
          else
            [ json, false ]
          end
        end

        private

        # Override in adapter for specific event data
        def build_event_data(event)
          case event.type
          in :exception
            build_exception_data(event)
          in :message
            build_message_data(event)
          else
            {}
          end
        end

        def build_exception_data(event)
          {
            exception: {
              type: event.exception_type,
              message: event.exception_message,
              backtrace: event.backtrace_frames&.map(&:to_h)
            }.compact_blank
          }
        end

        def build_message_data(event)
          {
            message: event.message
          }
        end
      end
    end
  end
end
