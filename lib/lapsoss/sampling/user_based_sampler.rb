# frozen_string_literal: true

module Lapsoss
  module Sampling
    class UserBasedSampler < Base
      def initialize(rates: {})
        @rates = rates
        @default_rate = rates.fetch(:default, 1.0)
      end

      def sample?(event, _hint = {})
        user = event.context[:user]
        return @default_rate > rand unless user

        rate = find_rate_for_user(user)
        rate > rand
      end

      private

      def find_rate_for_user(user)
        # Check specific user ID
        user_id = user[:id] || user["id"]
        return @rates[user_id] if user_id && @rates.key?(user_id)

        # Check user segments
        @rates.each do |segment, rate|
          case segment
          when :internal, "internal"
            return rate if user[:internal] || user["internal"]
          when :premium, "premium"
            return rate if user[:premium] || user["premium"]
          when :beta, "beta"
            return rate if user[:beta] || user["beta"]
          end
        end

        @default_rate
      end
    end
  end
end
