# frozen_string_literal: true

module Lapsoss
  # Subscribes to Rails' structured event reporter (Rails.event, Rails 8.1+)
  # and records emitted events as Lapsoss breadcrumbs, giving error reports an
  # automatic activity trail without any monkey-patching.
  class RailsEventSubscriber
    def emit(event)
      return unless Lapsoss.client

      Lapsoss.add_breadcrumb(event[:name], type: :event, **breadcrumb_metadata(event))
    end

    private

    def breadcrumb_metadata(event)
      metadata = {}
      payload = serialize_payload(event[:payload])
      metadata[:payload] = payload if payload
      metadata[:tags] = event[:tags] if event[:tags].present?
      metadata[:context] = event[:context] if event[:context].present?

      if (location = event[:source_location])
        metadata[:source] = "#{location[:filepath]}:#{location[:lineno]}"
      end

      metadata
    end

    # Payloads are either hashes or arbitrary event objects, which Rails passes
    # through as-is and expects subscribers to serialize.
    def serialize_payload(payload)
      case payload
      when nil, Hash
        payload
      else
        payload.respond_to?(:serialize) ? payload.serialize : payload.inspect
      end
    end
  end
end
