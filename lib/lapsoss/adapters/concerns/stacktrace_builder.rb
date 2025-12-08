# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/object/blank"

module Lapsoss
  module Adapters
    module Concerns
      # Shared stacktrace building logic for adapters
      # Provides consistent frame formatting across Sentry, OpenObserve, OTLP, etc.
      module StacktraceBuilder
        extend ActiveSupport::Concern

        # Build frames from event backtrace
        # @param event [Lapsoss::Event] The event with backtrace_frames
        # @param reverse [Boolean] Reverse frame order (Sentry expects oldest-to-newest)
        # @return [Array<Hash>] Array of formatted frame hashes
        def build_frames(event, reverse: false)
          return [] unless event.has_backtrace?

          frames = event.backtrace_frames.map { |frame| build_frame(frame) }
          reverse ? frames.reverse : frames
        end

        # Build a single frame hash from a BacktraceFrame
        # @param frame [Lapsoss::BacktraceFrame] The frame to format
        # @return [Hash] Formatted frame hash
        def build_frame(frame)
          frame_hash = {
            filename: frame.filename,
            abs_path: frame.absolute_path || frame.filename,
            function: frame.method_name || frame.function,
            lineno: frame.line_number,
            in_app: frame.in_app
          }

          add_code_context(frame_hash, frame) if frame.code_context.present?

          frame_hash.compact
        end

        # Build raw stacktrace string for logging/simple formats
        # @param event [Lapsoss::Event] The event with backtrace_frames
        # @return [Array<String>] Array of formatted frame strings
        def build_raw_stacktrace(event)
          return [] unless event.has_backtrace?

          event.backtrace_frames.map do |frame|
            "#{frame.absolute_path || frame.filename}:#{frame.line_number} in `#{frame.method_name}`"
          end
        end

        # Build stacktrace as single string (for OTLP exception.stacktrace)
        # @param event [Lapsoss::Event] The event with backtrace_frames
        # @return [String] Newline-separated stacktrace
        def build_stacktrace_string(event)
          build_raw_stacktrace(event).join("\n")
        end

        private

        def add_code_context(frame_hash, frame)
          frame_hash[:pre_context] = frame.code_context[:pre_context]
          frame_hash[:context_line] = frame.code_context[:context_line]
          frame_hash[:post_context] = frame.code_context[:post_context]
        end
      end
    end
  end
end
