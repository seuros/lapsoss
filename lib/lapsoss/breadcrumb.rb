# frozen_string_literal: true

module Lapsoss
  module Breadcrumb
    module_function

    # Canonical breadcrumb builder used by SDK
    # message: String, type: Symbol, metadata: Hash, timestamp: Time (UTC)
    def build(message, type: :default, metadata: {})
      {
        message: message.to_s,
        type: type.to_sym,
        metadata: metadata || {},
        timestamp: Time.now.utc
      }
    end

    # Normalize an incoming breadcrumb-like hash to the canonical structure
    def normalize(crumb)
      msg = crumb[:message] || crumb["message"]
      type = crumb[:type] || crumb["type"] || :default
      metadata = crumb[:metadata] || crumb["metadata"] || crumb[:data] || crumb["data"] || {}
      ts = crumb[:timestamp] || crumb["timestamp"]
      ts = ts.utc if ts.respond_to?(:utc)

      {
        message: msg.to_s,
        type: type.to_sym,
        metadata: metadata.is_a?(Hash) ? metadata : Hash(metadata),
        timestamp: ts || Time.now.utc
      }
    end

    # Adapter conversions
    def for_sentry(crumbs)
      crumbs.map do |c|
        c = normalize(c)
        {
          timestamp: c[:timestamp].utc.iso8601,
          message: c[:message],
          type: c[:type].to_s,
          data: c[:metadata]
        }
      end
    end

    def for_insight_hub(crumbs)
      crumbs.map do |c|
        c = normalize(c)
        {
          timestamp: c[:timestamp].utc.iso8601,
          name: c[:message],
          type: c[:type].to_s,
          metaData: c[:metadata]
        }
      end
    end
  end
end
