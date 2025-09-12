# frozen_string_literal: true

module Lapsoss
  module RailsControllerTransaction
    extend ActiveSupport::Concern

    included do
      around_action :lapsoss_capture_transaction
    end

    private

    def lapsoss_capture_transaction
      if Lapsoss.client
        transaction_name = "#{self.class.name}##{action_name}"

        # Set the transaction name in the current scope
        Lapsoss::Current.scope.set_transaction_name(transaction_name, source: :view)

        # Add breadcrumb for the action
        Lapsoss::Current.scope.add_breadcrumb(
          "Processing #{transaction_name}",
          type: :navigation,
          controller: self.class.name,
          action: action_name,
          params: request.filtered_parameters
        )
      end

      yield
    end
  end
end
