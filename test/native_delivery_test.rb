# frozen_string_literal: true

require_relative "test_helper"
require "zlib"
require "stringio"

class NativeDeliveryTest < ActiveSupport::TestCase
  setup do
    @servers = []
  end

  teardown do
    Lapsoss.client&.shutdown(timeout: 1)
    @servers.each(&:close)
  end

  def server(**options)
    NativeHTTP.new(**options).tap { |http| @servers << http }
  end

  def configure_sentry(http, **options)
    Lapsoss.configure do |config|
      config.async = options.fetch(:async, true)
      config.transport_max_retries = options.fetch(:retries, 0)
      config.transport_initial_backoff = 0.01
      config.transport_max_backoff = 0.02
      config.transport_jitter = false
      config.transport_backoff_multiplier = 2.0
      config.transport_ssl_verify = options.fetch(:ssl_verify, true)
      config.queue_max_events = options.fetch(:capacity, 1000)
      config.queue_max_bytes = options.fetch(:bytes, 10 * 1024 * 1024)
      config.error_handler = options[:handler]
      config.use_sentry(dsn: http.url.sub("://", "://public@") + "/123")
    end
  end

  test "native transport snapshots and scrubs context before returning an event ID" do
    http = server
    configure_sentry(http)
    metadata = { nested: [ "original" ], password: "secret" }
    id = Lapsoss.capture_message("hello", extra: metadata)
    assert_match(/\A[0-9a-f-]{36}\z/, id)
    metadata[:nested] << "mutated"
    GC.start
    GC.compact
    assert Lapsoss.flush
    request = http.next_request
    assert_equal "/api/123/envelope/", request[:path]
    lines = request[:body].lines.map { |line| JSON.parse(line) }
    assert_equal id.delete("-"), lines[0]["event_id"]
    assert_equal lines[0]["event_id"], lines[2]["event_id"]
    assert_equal [ "original" ], lines[2]["extra"]["nested"]
    assert_equal "[FILTERED]", lines[2]["extra"]["password"]
    assert_equal 0, Lapsoss.client.statistics[:outstanding_events]
  end

  test "retries transient failures but not successful destinations" do
    http = server(statuses: [ 503, 200 ])
    other = server
    configure_sentry(http, retries: 2)
    Lapsoss.configure do |config|
      config.use_sentry(name: :backup, dsn: other.url.sub("://", "://other@") + "/456")
    end
    assert Lapsoss.capture_message("retry me")
    assert Lapsoss.flush
    assert_equal "/api/123/envelope/", http.next_request[:path]
    assert_equal "/api/123/envelope/", http.next_request[:path]
    assert_equal "/api/456/envelope/", other.next_request[:path]
    assert other.requests.empty?
  end

  test "terminal failures invoke Ruby error handlers exactly once and reject reentrancy" do
    http = server(statuses: [ 401 ])
    calls = []
    configure_sentry(http, handler: ->(adapter, event, error) {
      calls << [ adapter.name, event.message, error.response.status, Thread.current.name ]
      assert_equal false, Lapsoss.flush(timeout: 0.01)
      assert_nil Lapsoss.capture_message("recursive reporting")
    })
    assert Lapsoss.capture_message("rejected by vendor")
    assert Lapsoss.flush
    assert_equal [ [ :sentry, "rejected by vendor", 401, "lapsoss-completions" ] ], calls
    assert_equal 1, Lapsoss.client.statistics[:failed]
    http.next_request
    assert http.requests.empty?
  end

  test "native HTTP never follows redirects carrying credentials" do
    destination = server
    http = server(statuses: [ 302 ], headers: { "Location" => destination.url + "/stolen" })
    calls = []
    configure_sentry(http, retries: 2, handler: ->(_adapter, _event, error) { calls << error.response.status })
    assert Lapsoss.capture_message("do not redirect")
    assert Lapsoss.flush
    assert_equal [ 302 ], calls
    http.next_request
    assert http.requests.empty?
    assert destination.requests.empty?
  end

  test "TLS verifies certificates by default and permits explicit opt out" do
    [ true, false ].each do |verify|
      http = server(tls: true)
      errors = []
      configure_sentry(http, ssl_verify: verify, handler: ->(error) { errors << error.message })
      assert Lapsoss.capture_message("TLS boundary")
      assert Lapsoss.flush
      if verify
        assert_equal [ "HTTP transport failure" ], errors
        assert http.requests.empty?
      else
        assert_empty errors
        assert_equal "/api/123/envelope/", http.next_request[:path]
      end
      assert Lapsoss.shutdown
    end
  end

  test "queue overflow is nonblocking and flush observes a real deadline" do
    http = server(delay: 0.2)
    calls = []
    configure_sentry(http, capacity: 1, handler: ->(error) { calls << error.message })
    assert Lapsoss.capture_message("accepted")
    assert_nil Lapsoss.capture_message("full")
    assert_not Lapsoss.flush(timeout: 0.01)
    assert Lapsoss.flush(timeout: 2)
    assert_equal [ "Lapsoss queue capacity exhausted" ], calls
    assert_equal 1, Lapsoss.client.statistics[:rejected]
  end

  test "oversized events are rejected before delivery" do
    http = server
    configure_sentry(http, bytes: 1)
    assert_nil Lapsoss.capture_message("too large")
    assert Lapsoss.flush
    assert http.requests.empty?
  end

  test "429 Retry-After remains part of the flush barrier" do
    http = server(statuses: [ 429, 200 ], headers: { "Retry-After" => "1" })
    configure_sentry(http, retries: 1)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert Lapsoss.capture_message("rate limited")
    assert_not Lapsoss.flush(timeout: 0.05)
    assert Lapsoss.flush(timeout: 2)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :>=, 0.9
    assert_equal 2, http.requests.size
  end

  test "custom adapter lifecycle runs on a managed Ruby thread" do
    operations = []
    plugin = Class.new(Lapsoss::Adapters::Base) do
      define_method(:capture) { |_event| operations << [ :capture, Thread.current.name ] }
      define_method(:flush) { |timeout:| operations << [ :flush, Thread.current.name ]; true }
      define_method(:shutdown) { operations << [ :shutdown, Thread.current.name ]; true }
    end.new(:plugin)
    Lapsoss.configure { |_config| }
    Lapsoss::Registry.instance.register_adapter(plugin)
    assert Lapsoss.capture_message("buffered plugin")
    assert Lapsoss.flush
    assert Lapsoss.shutdown
    assert_equal %i[capture flush flush shutdown], operations.map(&:first)
    assert operations.all? { |_, thread| thread == "lapsoss-plugins" }
    delivery = Lapsoss.client.instance_variable_get(:@delivery)
    assert_not delivery.instance_variable_get(:@plugin_worker).alive?
    assert_not delivery.instance_variable_get(:@completion_worker).alive?
  end

  test "concurrent captures use bounded workers and settle every receipt" do
    output = StringIO.new
    Lapsoss.configure { |config| config.use_logger(logger: Logger.new(output)) }
    threads_before = Thread.list.size
    ids = 8.times.map do
      Thread.new { 20.times.map { |index| Lapsoss.capture_message("concurrent #{index}") } }
    end.flat_map(&:value)
    GC.start
    assert_equal 160, ids.compact.uniq.size
    assert Lapsoss.flush
    assert_equal 160, Lapsoss.client.statistics[:delivered]
    assert_operator Thread.list.size, :<=, threads_before + 2
    assert Lapsoss.shutdown
  end

  test "normalization contains cyclic context and does not traverse arbitrary as_json" do
    object = Object.new
    def object.as_json(*) = raise("must not serialize framework internals")
    context = { object: object }
    context[:self] = context
    result = Lapsoss::EventSnapshot.normalize(context, json: true)
    assert_equal "[Circular]", result["self"]
    assert_kind_of String, result["object"]
    assert JSON.generate(result)
  end

  test "shutdown cancels native retries at its deadline" do
    http = server(delay: 0.2)
    configure_sentry(http)
    assert Lapsoss.capture_message("pending")
    assert_not Lapsoss.shutdown(timeout: 0.01)
    assert_nil Lapsoss.capture_message("closed")
    assert Lapsoss.flush(timeout: 1)
    assert_equal 1, Lapsoss.client.statistics[:abandoned]
    assert Lapsoss.shutdown
  end

  test "custom plugins and callbacks remain part of the flush barrier" do
    entered = Queue.new
    release = Queue.new
    collector = Class.new(Lapsoss::Adapters::Base) do
      define_method(:capture) do |event|
        entered << event.message
        release.pop
      end
    end.new(:plugin)
    Lapsoss.configure { |config| config.queue_max_events = 1 }
    Lapsoss::Registry.instance.register_adapter(collector)
    assert Lapsoss.capture_message("plugin")
    assert_equal "plugin", Timeout.timeout(2) { entered.pop }
    assert_not Lapsoss.flush(timeout: 0.01)
    assert_nil Lapsoss.capture_message("overflow while plugin runs")
    release << true
    assert Lapsoss.flush
  ensure
    release << true
  end

  test "configuration stays lazy and invalid replacement preserves the client" do
    http = server
    configure_sentry(http)
    delivery = Lapsoss.client.instance_variable_get(:@delivery)
    assert_not delivery.started?
    client = Lapsoss.client
    assert_raises(RuntimeError) do
      Lapsoss.configure { |config| config.use_sentry(dsn: "https://localhost/123") }
    end
    assert_same client, Lapsoss.client
    [
      ->(config) { config.transport_ssl_verify = "false" },
      ->(config) { config.transport_backoff_multiplier = Float::NAN },
      ->(config) { config.transport_backoff_multiplier = 0.5 }
    ].each do |invalid|
      assert_raises(ArgumentError) { Lapsoss.configure(&invalid) }
      assert_same client, Lapsoss.client
    end
    assert Lapsoss.capture_message("still works")
    assert Lapsoss.flush
  end

  test "native destinations can be added and enabled after startup" do
    first = server
    second = server
    configure_sentry(first)
    Lapsoss.capture_message("first")
    assert Lapsoss.flush
    adapter = Lapsoss::Registry.instance.register(:second, :sentry,
      dsn: second.url.sub("://", "://key@") + "/2")
    adapter.disable!
    Lapsoss.capture_message("disabled")
    assert Lapsoss.flush
    assert second.requests.empty?
    adapter.enable!
    Lapsoss.capture_message("enabled")
    assert Lapsoss.flush
    assert_equal "/api/2/envelope/", second.next_request[:path]
  end

  test "shared fixture traverses the native bridge with every protocol" do
    fixture = File.read(File.expand_path("../ext/lapsoss_native/core/fixtures/event.json", __dir__))
    transport = { max_retries: 0 }.to_json
    %w[sentry telebugs rollbar appsignal insight_hub bugsnag openobserve otlp].each do |type|
      http = server
      settings = {
        endpoint: http.url, dsn: http.url.sub("://", "://key@") + "/123",
        access_token: "token", frontend_api_key: "key", api_key: "key", username: "u", password: "p",
        compress_threshold: 1
      }
      native = Lapsoss::Native::Engine.new("{}", [ { name: type, type: type, settings: settings } ].to_json, transport)
      sequence = native.submit(fixture, [ type ].to_json)
      request = http.next_request
      assert_equal "gzip", request[:headers]["content-encoding"], type
      body = Zlib::GzipReader.new(StringIO.new(request[:body])).read
      payload = JSON.parse(type == "sentry" || type == "telebugs" ? body.lines[2] : body)
      assert_includes body, "payment failed", type
      if type == "sentry" || type == "telebugs"
        assert_equal "payments", payload["fingerprint"][0]
        assert_equal 42, payload["exception"]["values"][0]["stacktrace"]["frames"][0]["lineno"]
      end
      completion = Timeout.timeout(2) do
        loop do
          result = JSON.parse(native.poll)
          break result.first unless result.empty?
          sleep 0.005
        end
      end
      assert completion["outcomes"].first["success"], type
      native.acknowledge(sequence)
    ensure
      native&.dispose
    end
  end

  test "forking an active client fails clearly without touching inherited locks" do
    skip unless Process.respond_to?(:fork)
    http = server
    configure_sentry(http)
    Lapsoss.capture_message("parent")
    assert Lapsoss.flush
    read, write = IO.pipe
    pid = fork do
      read.close
      begin
        delivery = Lapsoss.client.instance_variable_get(:@delivery)
        delivery.flush
        write.write("unsafe")
      rescue Lapsoss::Delivery::ForkError
        write.write("guarded")
      ensure
        write.close
        exit! 0
      end
    end
    write.close
    assert_equal "guarded", Timeout.timeout(3) { read.read }
    Process.wait(pid)
  ensure
    read&.close
  end

  test "configuration before fork permits lazy startup in a child" do
    skip unless Process.respond_to?(:fork)
    Lapsoss.configure { |config| config.use_logger(logger: Logger.new(nil)) }
    read, write = IO.pipe
    pid = fork do
      read.close
      success = Lapsoss.capture_message("child") && Lapsoss.flush && Lapsoss.shutdown
      write.write(success ? "ok" : "failed")
      write.close
      exit! 0
    end
    write.close
    assert_equal "ok", Timeout.timeout(3) { read.read }
    Process.wait(pid)
    assert_not Lapsoss.client.instance_variable_get(:@delivery).started?
  ensure
    read&.close
  end
end
