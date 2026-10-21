# frozen_string_literal: true

require "socket"
require "io/wait"
require "json"
require "securerandom"
require "active_support/core_ext/numeric/bytes"

module Lapsoss
  # One bounded request/ack per connection. No inherited sockets or worker
  # threads, and never a direct-vendor fallback that could bypass the budget.
  class DaemonDelivery
    MAX_FRAME_BYTES = 1.megabyte

    def initialize(configuration)
      @configuration = configuration
      @closed = false
      reset_process_state
    end

    def submit(event)
      return nil if Thread.current[:lapsoss_daemon_delivery]

      reset_process_state
      id = SecureRandom.uuid
      encoded = EventSnapshot.encode(event, @configuration, id: id)
      request = %({"command":"submit","version":1,"event":#{encoded}})
      bounded(@configuration.daemon_timeout) do |deadline|
        return nil if @closed

        @started = true
        response = exchange(request, deadline)
        accepted = response["ok"] && response["event_id"] == id &&
          response.fetch("destinations", []).any? do |destination|
            %w[forward aggregate suppress].include?(destination.dig("outcome", "decision"))
          end
        raise DeliveryError, "Daemon rejected event admission" unless accepted

        @statistics_mutex.synchronize { @statistics[:accepted] += 1 }
        id
      end
    rescue StandardError => error
      notify_error(event, error)
      nil
    end

    # Covers earlier submissions on this client. This is a delivery watermark,
    # not a promise that aggregated events were sent or persisted.
    def flush(timeout: 2)
      bounded(timeout) { |deadline| flush_request(deadline) }
    rescue StandardError
      false
    end

    def shutdown(timeout: 2)
      @closed = true
      flush(timeout: timeout)
    end

    def statistics
      bounded(@configuration.daemon_timeout) do |deadline|
        local = @statistics_mutex.synchronize { @statistics.dup }
        local.merge(daemon: exchange(JSON.generate(command: "statistics", version: 1), deadline))
      end
    end

    private

    def bounded(timeout)
      timeout = Float(timeout)
      raise ArgumentError, "timeout must be finite and positive" unless timeout.finite? && timeout.positive?

      reset_process_state
      deadline = monotonic + timeout
      locked = false
      until (locked = @mutex.try_lock)
        raise DeliveryError, "Daemon client deadline exceeded" if monotonic >= deadline
        sleep [ [ 0.001, deadline - monotonic ].min, 0 ].max
      end
      yield deadline
    ensure
      @mutex.unlock if locked
    end

    def exchange(payload, deadline)
      raise DeliveryError, "Event exceeds daemon frame limit" if payload.bytesize > MAX_FRAME_BYTES

      socket = Socket.new(:UNIX, :STREAM, 0)
      status = socket.connect_nonblock(Socket.sockaddr_un(@configuration.daemon_socket), exception: false)
      wait(socket, status, deadline) if status.is_a?(Symbol)
      if status.is_a?(Symbol) && socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int != 0
        raise DeliveryError, "Cannot connect to daemon"
      end
      write_all(socket, [ payload.bytesize ].pack("N") + payload, deadline)
      length = read_exact(socket, 4, deadline).unpack1("N")
      raise DeliveryError, "Invalid daemon response size" unless length.between?(1, MAX_FRAME_BYTES)

      JSON.parse(read_exact(socket, length, deadline))
    ensure
      socket&.close
    end

    def write_all(socket, bytes, deadline)
      offset = 0
      while offset < bytes.bytesize
        raise DeliveryError, "Daemon client deadline exceeded" if monotonic >= deadline
        result = socket.write_nonblock(bytes.byteslice(offset..), exception: false)
        if result.is_a?(Symbol)
          wait(socket, result, deadline)
        else
          raise DeliveryError, "Daemon closed connection" if result.zero?
          offset += result
        end
      end
    end

    def read_exact(socket, length, deadline)
      bytes = +"".b
      while bytes.bytesize < length
        raise DeliveryError, "Daemon client deadline exceeded" if monotonic >= deadline
        result = socket.read_nonblock(length - bytes.bytesize, exception: false)
        if result.is_a?(Symbol)
          wait(socket, result, deadline)
        else
          raise DeliveryError, "Daemon closed connection" unless result
          bytes << result
        end
      end
      bytes
    end

    def wait(socket, status, deadline)
      remaining = deadline - monotonic
      ready = if remaining.positive?
        status == :wait_readable ? socket.wait_readable(remaining) : socket.wait_writable(remaining)
      end
      raise DeliveryError, "Daemon client deadline exceeded" unless ready
    end

    def flush_request(deadline)
      return true unless @started

      timeout_ms = [ [ ((deadline - monotonic) * 1000).floor, 1500 ].min, 0 ].max
      exchange(JSON.generate(command: "flush", version: 1, timeout_ms: timeout_ms), deadline)["ok"] == true
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def reset_process_state
      return if @pid == Process.pid

      @pid = Process.pid
      @mutex = Mutex.new
      @statistics_mutex = Mutex.new
      @statistics = { accepted: 0, rejected: 0 }
      @started = false
    end

    def notify_error(event, error)
      @statistics_mutex.synchronize { @statistics[:rejected] += 1 }
      previous = Thread.current[:lapsoss_daemon_delivery]
      Thread.current[:lapsoss_daemon_delivery] = true
      @configuration.logger&.error("[LAPSOSS] Daemon admission failed: #{error.class}")
      Lapsoss.call_error_handler(adapter: :daemon, event: event, error: error, handler: @configuration.error_handler)
    ensure
      Thread.current[:lapsoss_daemon_delivery] = previous
    end
  end
end
