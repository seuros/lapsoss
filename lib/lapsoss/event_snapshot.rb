# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Lapsoss
  # Explicit conversion, not Event#to_json (which contains a live Exception).
  module EventSnapshot
    module_function

    def encode(event, configuration, id: SecureRandom.uuid)
      runtime = RuntimeContext.current
      data = {
        id: id, type: event.type, level: event.level, timestamp: event.timestamp.utc.iso8601(6),
        message: event.message, exception: exception_data(event.exception),
        frames: Array(event.backtrace_frames).map(&:to_h),
        context: event.context, environment: event.environment, release: configuration.release || runtime.release,
        fingerprint: event.fingerprint, transaction: event.transaction,
        runtime: {
          language: "ruby", sdk_version: VERSION, server_name: runtime.server_name,
          contexts: runtime.to_contexts, modules: runtime.modules,
          root: defined?(Rails) && Rails.respond_to?(:root) ? Rails.root.to_s : Dir.pwd,
          framework: defined?(Rails) ? "rails" : "ruby"
        }
      }
      JSON.generate(normalize(data, json: true))
    end

    def exception_data(exception, seen = {})
      return unless exception
      return if seen[exception.object_id] || seen.size >= 16

      seen[exception.object_id] = true
      {
        class: exception.class.name, message: exception.message,
        backtrace: exception.backtrace || [], cause: exception_data(exception.cause, seen)
      }
    end

    # The callback/plugin event must not share mutable scope hashes with callers.
    def copy(event)
      event.with(context: normalize(event.context), message: event.message&.dup,
        backtrace_frames: event.backtrace_frames&.dup)
    end

    # Never call arbitrary #as_json: Rails reporter context can contain request
    # objects with cyclic routes, controllers and Rack environments.
    def normalize(value, json: false, ancestors: {}, depth: 0)
      return "[Depth limit]" if depth > 32
      case value
      when Hash, Array
        return "[Circular]" if ancestors[value.object_id]
        ancestors[value.object_id] = true
        begin
          if value.is_a?(Hash)
            value.to_h do |key, child|
              [ json ? key.to_s : key, normalize(child, json: json, ancestors: ancestors, depth: depth + 1) ]
            end
          else
            value.map { |child| normalize(child, json: json, ancestors: ancestors, depth: depth + 1) }
          end
        ensure
          ancestors.delete(value.object_id)
        end
      when String
        value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      when Time
        json ? value.utc.iso8601(6) : value.dup
      when Symbol
        json ? value.to_s : value
      when Float
        value.finite? ? value : value.to_s
      when Integer, NilClass, TrueClass, FalseClass
        value
      else
        value.to_s
      end
    end
  end
end
