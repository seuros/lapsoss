# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/notifications"
require "active_support/core_ext/numeric/bytes"

module Lapsoss
  module Adapters
    module Concerns
      module HttpDelivery
        extend ActiveSupport::Concern

        included do
          class_attribute :api_endpoint, instance_writer: false
          class_attribute :api_path, default: "/", instance_writer: false

          # Memoized git info using AS
          mattr_accessor :git_info_cache, default: {}
        end

        # Unified HTTP delivery with instrumentation
        def deliver(event)
          return unless enabled?

          payload = build_payload(event)
          return if payload.blank?

          body, compressed = serialize_payload(payload)
          headers = build_delivery_headers(compressed: compressed)

          ActiveSupport::Notifications.instrument("deliver.lapsoss",
            adapter: self.class.name,
            event_type: event.type,
            compressed: compressed,
            size: body.bytesize
          ) do
            response = http_client.post(api_path, body: body, headers: headers)
            handle_response(response)
          end
        rescue => error
          handle_delivery_error(error)
        end

        # Common headers for all adapters
        def build_delivery_headers(compressed: false, content_type: "application/json")
          {
            "User-Agent" => user_agent,
            "Content-Type" => content_type,
            "Content-Encoding" => ("gzip" if compressed),
            "X-Lapsoss-Version" => Lapsoss::VERSION
          }.merge(adapter_specific_headers).compact_blank
        end

        # Override for adapter-specific headers
        def adapter_specific_headers
          {}
        end

        # Git info with AS memoization
        def git_branch
          self.class.git_info_cache[:branch] ||= begin
            `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip.presence
          rescue
            nil
          end
        end

        def git_sha
          self.class.git_info_cache[:sha] ||= begin
            `git rev-parse HEAD 2>/dev/null`.strip.presence
          rescue
            nil
          end
        end

        # Common response handling
        def handle_response(response)
          code = response.respond_to?(:status) ? response.status.to_i : response.code.to_i
          case code
          when 200..299
            ActiveSupport::Notifications.instrument("success.lapsoss",
              adapter: self.class.name,
              response_code: code
            )
            true
          when 429
            raise DeliveryError.new("Rate limit exceeded", response: response)
          when 401, 403
            raise DeliveryError.new("Authentication failed", response: response)
          when 400..499
            handle_client_error(response)
          else
            raise DeliveryError.new("Server error: #{code}", response: response)
          end
        end

        def handle_client_error(response)
          body = ActiveSupport::JSON.decode(response.body) rescue {}
          message = body["message"].presence || body["error"].presence || "Bad request"
          raise DeliveryError.new("Client error: #{message}", response: response)
        end

        def handle_delivery_error(error)
          ActiveSupport::Notifications.instrument("error.lapsoss",
            adapter: self.class.name,
            error: error.class.name,
            message: error.message
          )

          Lapsoss.configuration.logger&.error("[#{self.class.name}] Delivery failed: #{error.message}")
          Lapsoss.configuration.error_handler&.call(error)

          raise error if error.is_a?(DeliveryError)
          raise DeliveryError.new("Delivery failed: #{error.message}", cause: error)
        end

        private

        def http_client
          @http_client ||= create_http_client(api_endpoint)
        end

        def user_agent
          "Lapsoss/#{Lapsoss::VERSION} Ruby/#{RUBY_VERSION} Rails/#{Rails.version if defined?(Rails)}"
        end
      end
    end
  end
end
