# frozen_string_literal: true

class ApplicationController < ActionController::Base
  def index
    render json: { message: "Lapsoss Dummy App", status: "ok" }
  end

  def error
    raise StandardError, "Test error for Lapsoss"
  end

  def health
    render json: { status: "healthy", timestamp: Time.current }
  end
end
