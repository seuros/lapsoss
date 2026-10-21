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
          first_line = peer.gets
          headers = {}
          while (line = peer.gets) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.downcase] = value.strip
          end
          body = peer.read(Integer(headers.fetch("content-length")))
          received << [ first_line, body ]
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

  private

  def with_daemon(destination)
    binary = ENV["LAPSOSSD_TEST_BIN"]
    skip "Set LAPSOSSD_TEST_BIN to a built lapsossd executable" unless binary

    Dir.mktmpdir("lapsoss-", "/tmp") do |directory|
      config = File.join(directory, "config.json")
      socket = File.join(directory, "daemon.sock")
      File.write(config, JSON.generate(
        socket: socket,
        destinations: [ destination ],
        transport: { max_retries: 0, timeout: 1 }
      ))
      Open3.popen2e(File.expand_path(binary), "--config", config) do |input, output, process|
        input.close
        begin
          Timeout.timeout(5) { assert_includes output.gets, "ready" }
          Lapsoss.configure do |configuration|
            configuration.daemon_socket = socket
            configuration.daemon_timeout = 1
          end
          yield
        ensure
          Lapsoss.instance_variable_set(:@client, nil)
          Process.kill("TERM", process.pid)
          unless process.join(7)
            Process.kill("KILL", process.pid)
            process.join
          end
        end
        assert process.value.success?
        refute File.exist?(socket)
      end
    end
  end
end
