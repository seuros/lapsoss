# frozen_string_literal: true

module Lapsoss
  # Optional concern to add controller and action context to Rails.error
  # Include this in ApplicationController or specific controllers to get more detailed context
  #
  # Example:
  #   class ApplicationController < ActionController::Base
  #     include Lapsoss::RailsControllerContext
  #   end
  module RailsControllerContext
    extend ActiveSupport::Concern

    included do
      prepend_before_action :set_lapsoss_controller_context
    end

    private

    def set_lapsoss_controller_context
      # Set context in Lapsoss scope if available
      Lapsoss::Current.scope&.set_context("controller", {
        controller: controller_name,
        action: action_name,
        controller_class: self.class.name
      })

      # Set context in Rails.error for ecosystem-wide availability
      Rails.error.set_context(
        controller: controller_name,
        action: action_name,
        controller_class: self.class.name
      )
    end
  end
end
