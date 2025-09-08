# frozen_string_literal: true

Rails.application.routes.draw do
  # Basic routes for testing Lapsoss
  root "application#index"

  # Test routes for error generation
  get "/error", to: "application#error"
  get "/health", to: "application#health"
end
