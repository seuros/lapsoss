# frozen_string_literal: true

require "active_support/all"

module Lapsoss
  class Current < ActiveSupport::CurrentAttributes
    attribute :scope, default: -> { Scope.new }

    def self.with_clean_scope
      previous_scope = scope
      self.scope = Scope.new
      yield
    ensure
      self.scope = previous_scope
    end
  end
end
