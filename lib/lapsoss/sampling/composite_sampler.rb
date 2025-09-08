# frozen_string_literal: true

module Lapsoss
  module Sampling
    class CompositeSampler < Base
      def initialize(app = nil, samplers: [], strategy: :all)
        @app = app
        @samplers = samplers
        @strategy = strategy
      end

      def sample?(event, hint = {})
        case @strategy
        when :all
          @samplers.all? { |sampler| sampler.sample?(event, hint) }
        when :any
          @samplers.any? { |sampler| sampler.sample?(event, hint) }
        when :first
          @samplers.first&.sample?(event, hint) || true
        else
          raise ArgumentError, "Unknown strategy: #{@strategy}"
        end
      end
    end
  end
end
