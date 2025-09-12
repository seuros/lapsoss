class TestController < ApplicationController
  def error
    # Log current adapters
    Rails.logger.info "Active Lapsoss adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

    # Trigger an error
    raise StandardError, "Test error from controller at #{Time.now}"
  rescue => e
    # Capture and log result
    results = Lapsoss.capture_exception(e)
    Rails.logger.info "Lapsoss capture results: #{results.inspect}"

    # Re-raise to see Rails error page
    raise
  end

  def test_sync
    # Temporarily disable async to test
    was_async = Lapsoss.configuration.async
    Lapsoss.configuration.instance_variable_set(:@async, false)

    Rails.logger.info "Testing with async=false"
    Rails.logger.info "Active adapters: #{Lapsoss::Registry.instance.active.map(&:name).join(', ')}"

    begin
      raise StandardError, "Sync test error at #{Time.now}"
    rescue => e
      results = Lapsoss.capture_exception(e)
      Rails.logger.info "Capture results: #{results.inspect}"
      render json: {
        message: "Error captured",
        adapters: Lapsoss::Registry.instance.active.map(&:name),
        results: results.map(&:class).map(&:name)
      }
    ensure
      Lapsoss.configuration.instance_variable_set(:@async, was_async)
    end
  end

  def test_telebugs
    # Check if Telebugs is configured
    telebugs = Lapsoss::Registry.instance[:telebugs]

    render json: {
      telebugs_configured: !telebugs.nil?,
      telebugs_enabled: telebugs&.enabled?,
      all_adapters: Lapsoss::Registry.instance.all.map { |a| { name: a.name, enabled: a.enabled? } },
      async_mode: Lapsoss.configuration.async
    }
  end
end
