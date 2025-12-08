# frozen_string_literal: true

require "active_support/concern"
require "securerandom"

module Lapsoss
  module Adapters
    module Concerns
      # Trace context utilities for OTLP and distributed tracing
      # Provides trace/span ID generation and timestamp formatting
      module TraceContext
        extend ActiveSupport::Concern

        # Generate a W3C Trace Context compliant trace ID (32 hex chars = 128 bits)
        # @return [String] 32 character hex string
        def generate_trace_id
          SecureRandom.hex(16)
        end

        # Generate a W3C Trace Context compliant span ID (16 hex chars = 64 bits)
        # @return [String] 16 character hex string
        def generate_span_id
          SecureRandom.hex(8)
        end

        # Convert time to nanoseconds since Unix epoch (OTLP format)
        # @param time [Time] The time to convert
        # @return [Integer] Nanoseconds since Unix epoch
        def timestamp_nanos(time)
          time ||= Time.current
          (time.to_f * 1_000_000_000).to_i
        end

        # Convert time to microseconds since Unix epoch (OpenObserve format)
        # @param time [Time] The time to convert
        # @return [Integer] Microseconds since Unix epoch
        def timestamp_micros(time)
          time ||= Time.current
          (time.to_f * 1_000_000).to_i
        end

        # Convert time to milliseconds since Unix epoch
        # @param time [Time] The time to convert
        # @return [Integer] Milliseconds since Unix epoch
        def timestamp_millis(time)
          time ||= Time.current
          (time.to_f * 1_000).to_i
        end
      end
    end
  end
end
