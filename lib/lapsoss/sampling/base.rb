# frozen_string_literal: true

module Lapsoss
  module Sampling
    class Base
      def sample?(_event, _hint = {})
        true
      end
    end
  end
end
