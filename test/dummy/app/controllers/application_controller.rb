# frozen_string_literal: true

class ApplicationController < ActionController::Base
  def index
    render json: { message: "Lapsoss Dummy App", status: "ok" }
  end

  def error
    # Debug: Log active adapters
    Rails.logger.info "[LAPSOSS DEBUG] Active adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"
    Rails.logger.info "[LAPSOSS DEBUG] Async mode: #{Lapsoss.configuration.async}"

    # Check Telebugs specifically
    telebugs = Lapsoss::Registry.instance[:telebugs]
    if telebugs
      Rails.logger.info "[LAPSOSS DEBUG] Telebugs adapter found: enabled=#{telebugs.enabled?}"
    else
      Rails.logger.warn "[LAPSOSS DEBUG] Telebugs adapter NOT found!"
    end

    raise StandardError, "Test error for Lapsoss at #{Time.now}"
  end

  def health
    render json: { status: "healthy", timestamp: Time.current }
  end

  def test_async_direct
    # Test async capture directly without middleware
    Rails.logger.info "[LAPSOSS TEST] Testing direct async capture"
    begin
      raise StandardError, "Direct async test at #{Time.now}"
    rescue => e
      result = Lapsoss.capture_exception(e)
      Rails.logger.info "[LAPSOSS TEST] Direct capture result: #{result.inspect}"

      # Try to flush
      Rails.logger.info "[LAPSOSS TEST] Flushing..."
      Lapsoss.flush(timeout: 5)
      Rails.logger.info "[LAPSOSS TEST] Flush complete"
    end

    render plain: "Direct async test complete - check logs and Telebugs"
  end

  def test_sync_error
    # Force synchronous mode for testing
    was_async = Lapsoss.configuration.async
    Lapsoss.configuration.instance_variable_set(:@async, false)

    Rails.logger.info "[LAPSOSS SYNC TEST] Testing with async=false"

    begin
      raise StandardError, "Sync test error at #{Time.now}"
    rescue => e
      results = Lapsoss.capture_exception(e)
      Rails.logger.info "[LAPSOSS SYNC TEST] Capture returned: #{results.inspect}"

      # Check if Telebugs actually sent the request
      if results.is_a?(Array)
        results.each do |adapter|
          Rails.logger.info "[LAPSOSS SYNC TEST] Adapter #{adapter.name} returned"
        end
      end
    ensure
      Lapsoss.configuration.instance_variable_set(:@async, was_async)
    end

    render json: {
      message: "Error captured in sync mode",
      adapters: Lapsoss::Registry.instance.active.map(&:name)
    }
  end
end
