# frozen_string_literal: true

require "digest"

module Lapsoss
  module Sampling
    class ConsistentHashSampler < Base
      def initialize(rate:, key_extractor: nil)
        @rate = rate
        @key_extractor = key_extractor || method(:default_key_extractor)
        @threshold = (rate * 0xFFFFFFFF).to_i
      end

      def sample?(event, hint = {})
        key = @key_extractor.call(event, hint)
        return @rate > rand unless key

        hash_value = Digest::MD5.hexdigest(key.to_s)[0, 8].to_i(16)
        hash_value <= @threshold
      end

      private

      def default_key_extractor(event, _hint)
        # Use fingerprint for consistent sampling
        event.fingerprint
      end
    end
  end
end
