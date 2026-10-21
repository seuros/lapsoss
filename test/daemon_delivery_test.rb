# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "timeout"
require "lapsoss"

class DaemonDeliveryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("lapsoss-", "/tmp")
    @socket = File.join(@directory, "daemon.sock")
    @configuration = Lapsoss::Configuration.new
    @configuration.daemon_socket = @socket
    @configuration.daemon_timeout = 0.05
    @delivery = Lapsoss::DaemonDelivery.new(@configuration)
  end

  def teardown
    @server&.close
    @worker&.join(1)
    FileUtils.remove_entry(@directory)
  end

  def test_snapshot_and_acknowledged_admission
    received = Queue.new
    serve do |request|
      received << request
      admission(request, "aggregate")
    end
    event = Lapsoss::Event.build(type: :message, level: :error, message: "outage")
    id = @delivery.submit(event)
    assert_match(/\A[0-9a-f-]{36}\z/, id)
    request = received.pop
    assert_equal 1, request["version"]
    assert_equal "submit", request["command"]
    assert_equal "outage", request.dig("event", "message")
    assert_equal id, request.dig("event", "id")
  end

  def test_unavailable_daemon_reports_error_without_direct_delivery
    errors = []
    @configuration.error_handler = ->(error) { errors << error }
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
    assert_equal 1, errors.size
  end

  def test_all_destinations_rejected_does_not_claim_admission
    serve { |request| admission(request, "reject") }
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
  end

  def test_submission_has_a_bounded_deadline
    serve { |_request| sleep 0.15; { ok: true } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.12
  end

  def test_invalid_response_length_is_rejected_before_allocation
    @server = UNIXServer.new(@socket)
    @worker = Thread.new do
      peer = @server.accept
      begin
        length = peer.read(4).unpack1("N")
        peer.read(length)
        peer.write([ Lapsoss::DaemonDelivery::MAX_FRAME_BYTES + 1 ].pack("N"))
      ensure
        peer.close
      end
    end
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
  end

  def test_closed_client_never_submits
    assert @delivery.shutdown(timeout: 0.1)
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
  end

  def test_unused_client_can_flush_without_a_daemon
    assert @delivery.flush
    assert @delivery.shutdown
  end

  def test_fork_does_not_inherit_a_locked_client
    serve { |request| admission(request, "forward") }
    mutex = @delivery.instance_variable_get(:@mutex)
    mutex.lock
    pid = fork do
      id = @delivery.submit(Lapsoss::Event.build(type: :message, message: "child"))
      exit!(id ? 0 : 1)
    end
    _, status = Process.wait2(pid)
    assert status.success?
  ensure
    mutex&.unlock if mutex&.owned?
  end

  def test_configuration_prevents_credentials_in_client
    @configuration.use_sentry(dsn: "https://public@example.com/123")
    assert_raises(ArgumentError) { @configuration.validate! }
    @configuration = Lapsoss::Configuration.new
    @configuration.daemon_socket = "relative.sock"
    assert_raises(ArgumentError) { @configuration.validate! }
  end

  def test_error_handler_cannot_recursively_submit
    @configuration.error_handler = ->(_error) { @delivery.submit(Lapsoss::Event.build(type: :message, message: "recursive")) }
    assert_nil @delivery.submit(Lapsoss::Event.build(type: :message, message: "one"))
  end

  private

  def admission(request, decision)
    { ok: true, event_id: request.dig("event", "id"), destinations: [ { outcome: { decision: decision } } ] }
  end

  def serve(&response)
    @server = UNIXServer.new(@socket)
    @worker = Thread.new do
      peer = @server.accept
      begin
        length = peer.read(4).unpack1("N")
        request = JSON.parse(peer.read(length))
        bytes = JSON.generate(response.call(request))
        peer.write([ bytes.bytesize ].pack("N") + bytes)
      rescue Errno::EPIPE
        # A deadline test deliberately closes the client before the response.
      ensure
        peer.close
      end
    end
  end
end
