# frozen_string_literal: true

module Lapsoss
  module Sampling
    class UniformSampler < Base
      def initialize(rate)
        @rate = rate
      end

      def sample?(_event, _hint = {})
        rand < @rate
      end
    end
  end
end
