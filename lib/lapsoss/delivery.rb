# frozen_string_literal: true

require "json"
require "thread"
require "active_support/notifications"

module Lapsoss
  # Ruby-owned completion and plugin workers. Native jobs own no Ruby values.
  # Pending entries root callbacks' events/adapters until acknowledgement.
  class Delivery
    class ForkError < Lapsoss::Error; end

    def initialize(configuration)
      @configuration = configuration
      @pid = Process.pid
      @mutex = Mutex.new
      @pending = {}
      @closed = false
      @retire_allowed = false
      @engine = nil
      @statistics = {
        outstanding_events: 0, outstanding_bytes: 0, accepted: 0,
        rejected: 0, delivered: 0, failed: 0, abandoned: 0
      }
      @plugin_queue = SizedQueue.new(configuration.queue_max_events)
    end

    def submit(event)
      check_pid!
      return nil if callback_thread? # Do not recursively report delivery errors.

      adapters = Registry.instance.active
      return nil if adapters.empty?

      snapshot = EventSnapshot.copy(event)
      id = SecureRandom.uuid
      json = EventSnapshot.encode(snapshot, @configuration, id: id)
      start(adapters)
      native, plugins = adapters.partition { |adapter| NativeAdapters.describe(adapter) }
      sequence = @mutex.synchronize do
        return nil if @closed
        number = @engine.submit(json, native.map { |adapter| adapter.name.to_s }.to_json)
        next unless number

        @pending[number] = {
          event: snapshot, adapters: adapters.to_h { |adapter| [ adapter.name.to_s, adapter ] },
          plugins_done: plugins.empty?, completion: nil, processing: false
        }
        number
      end
      return rejected(snapshot, adapters) unless sequence
      if plugins.any?
        if @configuration.async
          @plugin_queue.push([ sequence, plugins ], true)
        else
          run_plugins(sequence, plugins)
        end
      end
      wait_for(sequence, nil) unless @configuration.async
      id
    end

    def flush(timeout: 2)
      check_pid!
      return false if callback_thread?
      return true unless @engine

      watermark = @mutex.synchronize { @engine&.watermark }
      return true unless watermark
      deadline = monotonic + Float(timeout)
      return false unless wait_for(watermark, timeout, through: true)
      return true if @retire_allowed

      control_plugins(:flush, deadline)
    end

    def shutdown(timeout: 2)
      check_pid!
      return false if callback_thread?
      deadline = monotonic + Float(timeout)
      if @closed
        settled = !@engine || wait_for(@engine.watermark, timeout, through: true)
        return settled && join_workers(deadline)
      end

      @mutex.synchronize do
        @closed = true
        @engine&.close
      end
      unless @engine
        return join_workers(deadline)
      end

      settled = flush(timeout: timeout)
      settled &&= control_plugins(:shutdown, deadline)
      unless settled
        @engine.cancel
        # Running user Ruby code cannot safely be interrupted. Retain its
        # bounded state until it returns; do not Thread#kill application code.
      end
      @retire_allowed = true
      settled && join_workers(deadline)
    end

    def statistics
      check_pid!
      @engine ? JSON.parse(@engine.statistics).transform_keys(&:to_sym) : @statistics
    end

    def started?
      check_pid!
      !@engine.nil?
    end

    private

    def check_pid!
      return if @pid == Process.pid
      unless @engine || @retiring
        @pid = Process.pid
        @mutex = Mutex.new
        return
      end
      # A configured but never-started client is safe to replace after fork.
      raise ForkError, "Lapsoss dispatcher inherited across fork; shutdown before fork and configure again afterward"
    end

    def callback_thread?
      Thread.current[:lapsoss_delivery] == self
    end

    def start(adapters)
      @mutex.synchronize do
        return if @closed

        specs = adapters.filter_map { |adapter| NativeAdapters.describe(adapter) }
        encoded = specs.to_json
        if @engine
          if @native_specs != encoded
            @engine.replace_adapters(encoded, NativeAdapters.transport(@configuration).to_json)
            @native_specs = encoded
          end
          return
        end
        @engine = Native::Engine.new({
          max_events: @configuration.queue_max_events, max_bytes: @configuration.queue_max_bytes,
          concurrency_per_adapter: @configuration.delivery_concurrency
        }.to_json, encoded, NativeAdapters.transport(@configuration).to_json)
        @native_specs = encoded
        @completion_worker = Thread.new { completion_loop }
        @completion_worker.name = "lapsoss-completions"
        @plugin_worker = Thread.new do
          while (job = @plugin_queue.pop)
            if job.first == :control
              run_control(*job.drop(1))
            else
              run_plugins(*job)
            end
          end
        end
        @plugin_worker.name = "lapsoss-plugins"
      end
    end

    def rejected(event, adapters)
      with_callback_guard do
        error = DeliveryError.new("Lapsoss queue capacity exhausted")
        adapters.each { |adapter| notify_error(adapter, event, error) }
      end
      nil
    end

    def run_plugins(sequence, adapters)
      event = @mutex.synchronize { @pending[sequence]&.fetch(:event) }
      return unless event

      with_callback_guard do
        adapters.each do |adapter|
          adapter.capture(event)
        rescue StandardError => error
          handled = error.instance_variable_defined?(:@lapsoss_error_handled) && error.instance_variable_get(:@lapsoss_error_handled)
          notify_error(adapter, event, error) unless handled
        end
      end
    ensure
      @mutex.synchronize { @pending[sequence][:plugins_done] = true if @pending[sequence] }
    end

    def completion_loop
      loop do
        completions = JSON.parse(@engine.poll)
        ready = @mutex.synchronize do
          completions.each do |completion|
            @pending[completion["sequence"]][:completion] = completion if @pending[completion["sequence"]]
          end
          @pending.filter_map do |sequence, entry|
            next if entry[:processing] || !entry[:plugins_done] || !entry[:completion]

            entry[:processing] = true
            [ sequence, entry ]
          end
        end
        ready.each { |sequence, entry| complete(sequence, entry) }
        break if @mutex.synchronize { @closed && @retire_allowed && @pending.empty? }

        sleep 0.005
      end
    rescue StandardError => error
      @configuration.logger&.error("[LAPSOSS] Completion worker failed: #{error.message}")
    ensure
      stop_if_settled
    end

    def complete(sequence, entry)
      with_callback_guard do
        entry[:completion]["outcomes"].each do |outcome|
          adapter = entry[:adapters][outcome["adapter"]]
          next unless adapter

          details = { adapter: adapter.class.name, event_type: entry[:event].type, event_id: entry[:completion]["event_id"] }
          ActiveSupport::Notifications.instrument("deliver.lapsoss", **details)
          if outcome["success"]
            if outcome["log"]
              logger = adapter.settings[:logger] || adapter.instance_variable_get(:@logger) || @configuration.logger
              level = entry[:event].type == :exception ? :error : entry[:event].level
              level = :warn if level == :warning
              level = :error unless %i[debug info warn error fatal].include?(level)
              logger&.public_send(level, outcome["log"])
            end
            ActiveSupport::Notifications.instrument("success.lapsoss", **details)
          else
            response = Struct.new(:status).new(outcome["status"]) if outcome["status"]
            notify_error(adapter, entry[:event], DeliveryError.new(outcome["error"], response: response))
          end
        rescue StandardError => error
          notify_error(adapter, entry[:event], error)
        end
      end
    ensure
      @engine.acknowledge(sequence)
      @mutex.synchronize { @pending.delete(sequence) }
    end

    def with_callback_guard
      previous = Thread.current[:lapsoss_delivery]
      Thread.current[:lapsoss_delivery] = self
      yield
    ensure
      Thread.current[:lapsoss_delivery] = previous
    end

    def notify_error(adapter, event, error)
      ActiveSupport::Notifications.instrument("error.lapsoss", adapter: adapter.name, error: error.class.name, message: error.message)
      @configuration.logger&.error("[LAPSOSS] Adapter '#{adapter.name}': #{error.message}")
      Lapsoss.call_error_handler(adapter: adapter, event: event, error: error, handler: @configuration.error_handler)
    rescue StandardError
      # Instrumentation and reporting must not recursively break error capture.
      nil
    end

    def wait_for(sequence, timeout, through: false)
      deadline = monotonic + Float(timeout) if timeout
      loop do
        settled = @mutex.synchronize do
          through ? @pending.keys.none? { |key| key <= sequence } : !@pending.key?(sequence)
        end
        return true if settled
        return false if deadline && monotonic >= deadline

        sleep 0.005 # Releases the GVL while native jobs and Ruby callbacks run.
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def control_plugins(operation, deadline)
      adapters = Registry.instance.all.reject { |adapter| NativeAdapters.describe(adapter) }
      return true if adapters.empty?
      return false unless @plugin_worker&.alive?

      response = Queue.new
      @plugin_queue.push([ :control, operation, adapters, response, deadline ], true)
      loop do
        return response.pop(true) unless response.empty?
        return false if monotonic >= deadline

        sleep 0.005
      end
    rescue ThreadError, ClosedQueueError
      false
    end

    def run_control(operation, adapters, response, deadline)
      success = true
      with_callback_guard do
        adapters.each do |adapter|
          if monotonic >= deadline
            success = false
            break
          end
          result = if operation == :flush
            adapter.flush(timeout: [ deadline - monotonic, 0 ].max) if adapter.respond_to?(:flush)
          else
            adapter.shutdown if adapter.respond_to?(:shutdown)
          end
          success = false if operation == :flush && result == false
        rescue StandardError => error
          success = false
          notify_error(adapter, nil, error)
        end
      end
      response << success
    end

    def stop_if_settled
      engine = @mutex.synchronize do
        return unless @closed && @retire_allowed && @pending.empty? && @engine

        @statistics = JSON.parse(@engine.statistics).transform_keys(&:to_sym)
        @retiring = true
        old = @engine
        @engine = nil
        old
      end
      @plugin_queue.close
      engine.dispose
      sleep 0.005 until engine.disposed?
      @retiring = false
    end

    def join_workers(deadline)
      [ @completion_worker, @plugin_worker ].compact.all? do |worker|
        remaining = [ deadline - monotonic, 0 ].max
        !worker.alive? || !!worker.join(remaining)
      end
    end
  end
end
