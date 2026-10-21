# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "timeout"
require "lapsoss"

class DaemonIntegrationTest < Minitest::Test
  def setup
    Lapsoss.client&.shutdown(timeout: 0.1)
    Lapsoss.instance_variable_set(:@client, nil)
    Lapsoss.instance_variable_set(:@configuration, nil)
    Lapsoss::Registry.instance.clear!
    Lapsoss::Current.reset
  end

  def teardown
    Lapsoss.client&.shutdown(timeout: 0.1)
    Lapsoss.instance_variable_set(:@client, nil)
    Lapsoss.instance_variable_set(:@configuration, nil)
  end

  def test_ruby_client_through_real_daemon
    with_daemon(adapter: { name: "local", type: "logger" }, policy: { budget_events: 1 }) do
      10.times { assert Lapsoss.capture_message("repeated outage", level: :error) }
      assert Lapsoss.capture_message("different outage", level: :error)
      assert Lapsoss.flush
      stats = Lapsoss.client.statistics.dig(:daemon, "destinations", 0)
      assert_equal 11, stats.dig("policy", "received")
      assert_equal 1, stats.dig("policy", "forwarded")
      assert_equal 9, stats.dig("policy", "aggregated")
      assert_equal 1, stats.dig("policy", "budget_limited")
      assert_equal 1, stats.dig("delivery", "delivered")
      assert Lapsoss.shutdown
    end
  end

  def test_duplicates_do_not_reach_vendor_http_ingestion
    skip "Set LAPSOSSD_TEST_BIN to a built lapsossd executable" unless ENV["LAPSOSSD_TEST_BIN"]

    vendor = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    worker = Thread.new do
      peer = vendor.accept
      begin
        Timeout.timeout(3) do
          received << read_vendor_request(peer)
          peer.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        end
      ensure
        peer.close
      end
    end
    destination = {
      adapter: { name: "sentry", type: "sentry", settings: {
        dsn: "http://fixture@127.0.0.1:#{vendor.addr[1]}/123", compress_threshold: 1_000_000
      } },
      policy: { budget_events: 1 }
    }
    with_daemon(destination) do
      100.times { assert Lapsoss.capture_message("same outage", level: :error) }
      assert Lapsoss.flush
      stats = Lapsoss.client.statistics.dig(:daemon, "destinations", 0)
      assert_equal 1, stats.dig("delivery", "delivered")
      assert_equal 0, stats.dig("delivery", "failed")
      assert_equal 99, stats.dig("policy", "aggregated")
      assert_equal 1, received.size
      first_line, body = received.pop
      assert_includes first_line, "/api/123/envelope/"
      assert_includes body, "same outage"
    end
  ensure
    vendor&.close
    worker&.join(4)
  end

  def test_crash_recovery_preserves_acknowledged_event_counts_and_budget
    skip "Set LAPSOSSD_TEST_BIN to a built lapsossd executable" unless ENV["LAPSOSSD_TEST_BIN"]

    vendor = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    release = Queue.new
    worker = Thread.new do
      2.times do |attempt|
        peer = vendor.accept
        begin
          received << Timeout.timeout(5) { read_vendor_request(peer) }
          release.pop if attempt.zero? # Crash while vendor acknowledgement is ambiguous.
          peer.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        rescue Errno::EPIPE, Errno::ECONNRESET
          raise unless attempt.zero? || vendor.closed?
        ensure
          peer.close
        end
      end
    rescue IOError, Errno::EBADF
      raise unless vendor.closed?
    end
    Dir.mktmpdir("lapsoss-", "/tmp") do |directory|
      socket = File.join(directory, "daemon.sock")
      config = File.join(directory, "config.json")
      File.write(config, JSON.generate(
        socket: socket, storage: { path: File.join(directory, "state.redb") },
        destinations: [ {
          adapter: { name: "vendor", type: "sentry", settings: {
            dsn: "http://fixture@127.0.0.1:#{vendor.addr[1]}/123"
          } },
          policy: { budget_events: 1 }
        } ],
        transport: { max_retries: 0, timeout: 5 }
      ))
      event = Lapsoss::Event.build(type: :message, level: :error, message: "durable outage")
      payload = JSON.generate(command: "submit", version: 1,
        event: JSON.parse(Lapsoss::EventSnapshot.encode(event, Lapsoss.configuration)))
      begin
        daemon = start_daemon(config)
        acknowledged = request(socket, payload)
        assert acknowledged["durable"]
        first = Timeout.timeout(5) { received.pop }
        stop_daemon(daemon, "KILL")
        daemon = nil
        assert File.exist?(socket), "SIGKILL should leave a stale socket"
        File.unlink(socket) # Only after wait confirms the old process has exited.
        release << true

        daemon = start_daemon(config)
        assert_equal acknowledged, request(socket, payload)
        different = JSON.parse(payload)
        different["event"]["id"] = SecureRandom.uuid
        different["event"]["message"] = "distinct outage"
        assert_equal "destination_budget",
          request(socket, JSON.generate(different)).dig("destinations", 0, "outcome", "reason")
        assert request(socket, JSON.generate(command: "flush", version: 1, timeout_ms: 1500))["ok"]
        second = Timeout.timeout(5) { received.pop }
        id = JSON.parse(payload).dig("event", "id").delete("-")
        assert_includes first.last, id
        assert_includes second.last, id
        stats = request(socket, JSON.generate(command: "statistics", version: 1)).dig("destinations", 0)
        assert_equal 2, stats.dig("policy", "received")
        assert_equal 1, stats.dig("policy", "forwarded")
        assert_equal 1, stats.dig("spool", "delivered")
        assert_equal 0, stats.dig("spool", "pending")
        stop_daemon(daemon)
        daemon = start_daemon(config)
        assert request(socket, JSON.generate(command: "flush", version: 1, timeout_ms: 1000))["ok"]
        assert_nil IO.select([ vendor ], nil, nil, 0.1), "Durably completed jobs must not replay"
      ensure
        stop_daemon(daemon)
      end
    end
  ensure
    release&.push(true)
    vendor&.close
    worker&.join(5)
  end

  private

  def read_vendor_request(peer)
    first_line = peer.gets
    headers = {}
    while (line = peer.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip
    end
    [ first_line, peer.read(Integer(headers.fetch("content-length"))) ]
  end

  def request(socket, payload)
    Timeout.timeout(5) do
      UNIXSocket.open(socket) do |peer|
        peer.write([ payload.bytesize ].pack("N") + payload)
        JSON.parse(peer.read(peer.read(4).unpack1("N")))
      end
    end
  end

  def start_daemon(config)
    input, output, process = Open3.popen2e(File.expand_path(ENV.fetch("LAPSOSSD_TEST_BIN")), "--config", config)
    input.close
    Timeout.timeout(5) { assert_includes output.gets, "ready" }
    [ output, process ]
  rescue Exception # Also clean up when a readiness assertion fails.
    stop_daemon([ output, process ]) if process
    raise
  end

  def stop_daemon(daemon, signal = "TERM")
    return unless daemon

    output, process = daemon
    Process.kill(signal, process.pid) if process.alive?
    unless process.join(7)
      Process.kill("KILL", process.pid)
      process.join
    end
    output.close unless output.closed?
  rescue Errno::ESRCH
    process.join
    output.close unless output.closed?
  end

  def with_daemon(destination)
    binary = ENV["LAPSOSSD_TEST_BIN"]
    skip "Set LAPSOSSD_TEST_BIN to a built lapsossd executable" unless binary

    Dir.mktmpdir("lapsoss-", "/tmp") do |directory|
      config = File.join(directory, "config.json")
      socket = File.join(directory, "daemon.sock")
      File.write(config, JSON.generate(
        socket: socket,
        storage: { path: File.join(directory, "state.redb") },
        destinations: [ destination ],
        transport: { max_retries: 0, timeout: 1 }
      ))
      daemon = start_daemon(config)
      begin
        Lapsoss.configure do |configuration|
          configuration.daemon_socket = socket
          configuration.daemon_timeout = 1
        end
        yield
      ensure
        Lapsoss.instance_variable_set(:@client, nil)
        stop_daemon(daemon)
      end
      assert daemon.last.value.success?
      refute File.exist?(socket)
    end
  end
end
