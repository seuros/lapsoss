#!/usr/bin/env ruby
# frozen_string_literal: true

require 'benchmark'
require 'benchmark/memory'
require_relative '../lib/lapsoss'

# Benchmark backtrace processing performance
class BacktraceProcessingBenchmark
  def self.run
    new.run
  end

  def initialize
    @processor = Lapsoss::BacktraceProcessor.new
    @short_backtrace = generate_backtrace(10)
    @medium_backtrace = generate_backtrace(50)
    @long_backtrace = generate_backtrace(200)
    @deep_backtrace = generate_backtrace(1000)
  end

  def run
    puts 'Backtrace Processing Performance Benchmark'
    puts '=' * 50
    puts

    run_time_benchmarks
    puts
    run_memory_benchmarks
    puts
    run_cache_efficiency_test
  end

  private

  def generate_backtrace(depth)
    (1..depth).map do |i|
      if (i % 3).zero?
        "/gems/some-gem-#{i}/lib/file.rb:#{i}:in `method_#{i}'"
      elsif i.even?
        "/app/models/model_#{i}.rb:#{i}:in `process_#{i}'"
      else
        "/usr/lib/ruby/3.4.0/core_#{i}.rb:#{i}:in `call'"
      end
    end
  end

  def run_time_benchmarks
    puts 'Time Performance:'
    puts '-' * 30

    Benchmark.bm(25) do |x|
      x.report('Short trace (10 frames):') do
        1000.times { @processor.process(@short_backtrace) }
      end

      x.report('Medium trace (50 frames):') do
        200.times { @processor.process(@medium_backtrace) }
      end

      x.report('Long trace (200 frames):') do
        50.times { @processor.process(@long_backtrace) }
      end

      x.report('Deep trace (1000 frames):') do
        10.times { @processor.process(@deep_backtrace) }
      end

      # Test with filtering
      config = Lapsoss::Configuration.new
      config.backtrace_exclude_patterns = [ %r{/usr/lib/ruby} ]
      processor_with_filter = Lapsoss::BacktraceProcessor.new(config)

      x.report('With filtering:') do
        100.times { processor_with_filter.process(@medium_backtrace) }
      end

      # Test with frame limiting
      config = Lapsoss::Configuration.new
      config.backtrace_max_frames = 30
      processor_with_limit = Lapsoss::BacktraceProcessor.new(config)

      x.report('With frame limit (30):') do
        50.times { processor_with_limit.process(@long_backtrace) }
      end
    end
  end

  def run_memory_benchmarks
    puts 'Memory Usage:'
    puts '-' * 30

    if defined?(Benchmark::Memory)
      Benchmark.memory do |x|
        x.report('Short trace:') do
          @processor.process(@short_backtrace)
        end

        x.report('Medium trace:') do
          @processor.process(@medium_backtrace)
        end

        x.report('Long trace:') do
          @processor.process(@long_backtrace)
        end

        x.report('Deep trace:') do
          @processor.process(@deep_backtrace)
        end

        x.compare!
      end
    else
      puts "Install 'benchmark-memory' gem for memory benchmarks"
    end
  end

  def run_cache_efficiency_test
    puts 'File Cache Efficiency Test:'
    puts '-' * 30

    # Create a processor with code context enabled
    config = Lapsoss::Configuration.new
    config.backtrace_enable_code_context = true
    config.backtrace_context_lines = 5
    processor = Lapsoss::BacktraceProcessor.new(config)

    # Create temp files for testing
    require 'tempfile'
    temp_files = Array.new(10) do |i|
      file = Tempfile.new([ "test_#{i}", '.rb' ])
      file.write(<<~RUBY)
        class TestClass#{i}
          def method_one
            puts "Line 3"
            puts "Line 4"
            raise "Error on line 5" # This is line 5
            puts "Line 6"
            puts "Line 7"
          end
        end
      RUBY
      file.close
      file
    end

    # Generate backtrace with temp files
    backtrace_with_files = temp_files.map.with_index do |file, i|
      "#{file.path}:5:in `method_#{i}'"
    end

    # Benchmark with and without cache
    puts 'Processing with file reading:'
    time_with_cache = Benchmark.realtime do
      10.times { processor.process(backtrace_with_files) }
    end

    # Clear cache and process again
    processor.clear_cache!

    puts "First run (cold cache): #{(time_with_cache * 1000).round(2)}ms"

    # Run again with warm cache
    time_with_warm_cache = Benchmark.realtime do
      10.times { processor.process(backtrace_with_files) }
    end

    puts "Subsequent runs (warm cache): #{(time_with_warm_cache * 1000).round(2)}ms"
    puts "Cache speedup: #{(time_with_cache / time_with_warm_cache).round(2)}x"
  ensure
    temp_files&.each(&:unlink)
  end
end

# Run the benchmark
BacktraceProcessingBenchmark.run if __FILE__ == $PROGRAM_NAME
