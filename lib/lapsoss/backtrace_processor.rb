# frozen_string_literal: true

require "set"
require "active_support/cache"
require "active_support/core_ext/numeric/time"

module Lapsoss
  class BacktraceProcessor
    DEFAULT_CONFIG = {
      context_lines: 3,
      max_frames: 100,
      enable_code_context: true,
      strip_load_path: true,
      in_app_patterns: [],
      exclude_patterns: [
        # Common test/debug patterns to exclude
        /rspec/,
        /minitest/,
        /test-unit/,
        /cucumber/,
        /pry/,
        /byebug/,
        /debug/,
        /<internal:/,
        /kernel_require\.rb/
      ],
      dedupe_frames: true,
      include_gems_in_context: false
    }.freeze

    attr_reader :config

    def initialize(config = {})
      # Handle different config formats for backward compatibility
      config_hash = if config.respond_to?(:backtrace_context_lines)
                      # Configuration object passed
                      {
                        context_lines: config.backtrace_context_lines,
                        max_frames: config.backtrace_max_frames,
                        enable_code_context: config.backtrace_enable_code_context,
                        in_app_patterns: config.backtrace_in_app_patterns,
                        exclude_patterns: config.backtrace_exclude_patterns,
                        strip_load_path: config.backtrace_strip_load_path
                      }
      else
                      # Hash passed
                      config
      end

      @config = DEFAULT_CONFIG.merge(config_hash)
      @file_cache = ActiveSupport::Cache::MemoryStore.new(
        size: (@config[:file_cache_size] || 100) * 1024 * 1024, # Convert to bytes
        expires_in: 1.hour
      )
    end

    def process_backtrace(backtrace)
      return [] unless backtrace&.any?

      # Parse all frames
      frames = parse_frames(backtrace)

      # Apply filtering
      frames = filter_frames(frames)

      # Limit frame count
      frames = limit_frames(frames)

      # Add code context if enabled
      add_code_context(frames) if @config[:enable_code_context]

      # Deduplicate if enabled
      frames = dedupe_frames(frames) if @config[:dedupe_frames]

      frames
    end

    # Backward compatibility alias
    alias process process_backtrace

    def process_exception_backtrace(exception, follow_cause: false)
      return [] unless exception&.backtrace

      frames = process_backtrace(exception.backtrace)

      # Wrap frames with exception-specific context
      frames = frames.map.with_index do |frame, index|
        ExceptionBacktraceFrame.new(
          frame,
          exception_class: exception.class.name,
          is_crash_frame: index.zero?
        )
      end

      # Follow exception causes if requested
      if follow_cause && exception.respond_to?(:cause) && exception.cause
        cause_frames = process_exception_backtrace(exception.cause, follow_cause: true)
        frames.concat(cause_frames)
      end

      frames
    end

    # Backward compatibility aliases
    alias process_exception process_exception_backtrace

    def clear_cache!
      @file_cache.clear
    end

    def to_hash_array(frames)
      frames.map(&:to_h)
    end

    def format_frames(frames, format = :sentry)
      case format
      when :sentry
        to_sentry_format(frames)
      when :rollbar
        to_rollbar_format(frames)
      when :bugsnag
        to_bugsnag_format(frames)
      else
        to_sentry_format(frames)
      end
    end

    def to_sentry_format(frames)
      frames.map do |frame|
        data = {
          filename: frame.filename,
          lineno: frame.line_number,
          function: frame.function || frame.method_name,
          module: frame.module_name,
          in_app: frame.in_app
        }.compact

        # Add code context for Sentry
        if frame.code_context
          data[:pre_context] = frame.code_context[:pre_context]
          data[:context_line] = frame.code_context[:context_line]
          data[:post_context] = frame.code_context[:post_context]
        end

        data
      end.reverse # Sentry expects oldest frame first
    end

    def to_rollbar_format(frames)
      frames.map do |frame|
        {
          filename: frame.filename,
          lineno: frame.line_number,
          method: frame.function || frame.method_name,
          code: frame.code_context&.dig(:context_line)
        }.compact
      end
    end

    def to_bugsnag_format(frames)
      frames.map do |frame|
        data = {
          file: frame.filename,
          lineNumber: frame.line_number,
          method: frame.function || frame.method_name,
          inProject: frame.in_app
        }.compact

        # Add code context for Bugsnag/Insight Hub
        if frame.code_context
          data[:code] = {
            frame.code_context[:line_number] => frame.code_context[:context_line]
          }
        end

        data
      end
    end

    def stats
      {
        file_cache: {
          # ActiveSupport::Cache::MemoryStore doesn't expose detailed stats
          # but we can provide basic info
          type: "ActiveSupport::Cache::MemoryStore",
          configured_size: @file_cache.options[:size]
        },
        config: @config,
        load_paths: @load_paths
      }
    end

    def clear_cache
      @file_cache.clear
    end

    # Get code context around a specific line number using ActiveSupport::Cache
    def get_code_context(filename, line_number, context_lines = 3)
      return nil unless filename && File.exist?(filename)
      return nil if File.size(filename) > (@config[:max_file_size] || (1024 * 1024))

      lines = @file_cache.fetch(filename) do
        read_file_safely(filename)
      end

      return nil unless lines

      # Convert to 0-based index
      line_index = line_number - 1
      return nil if line_index.negative? || line_index >= lines.length

      # Calculate context range
      start_line = [ 0, line_index - context_lines ].max
      end_line = [ lines.length - 1, line_index + context_lines ].min

      {
        pre_context: lines[start_line...line_index],
        context_line: lines[line_index],
        post_context: lines[(line_index + 1)..end_line],
        line_number: line_number,
        start_line: start_line + 1,
        end_line: end_line + 1
      }
    rescue StandardError
      # Return nil on any file read error
      nil
    end

    private

    def read_file_safely(filename)
      File.readlines(filename, chomp: true)
    rescue StandardError
      []
    end

    def parse_frames(backtrace)
      load_paths = determine_load_paths
      frames = backtrace.map do |line|
        BacktraceFrameFactory.from_raw_line(
          line,
          in_app_patterns: @config[:in_app_patterns],
          exclude_patterns: @config[:exclude_patterns],
          load_paths: load_paths
        )
      end

      # Filter out invalid frames
      frames.select(&:valid?)
    end

    def filter_frames(frames)
      # Remove excluded frames
      frames = frames.reject { |frame| frame.excluded?(@config[:exclude_patterns]) }

      # Filter gems if configured
      unless @config[:include_gems_in_context]
        # Keep app frames and a limited number of library frames for context, but preserve order
        library_count = 0
        frames = frames.select do |frame|
          if frame.app_frame?
            true
          elsif frame.library_frame? && library_count < 10
            library_count += 1
            true
          else
            false
          end
        end
      end

      frames
    end

    def limit_frames(frames)
      max_frames = @config[:max_frames]
      return frames if frames.length <= max_frames

      # Use head/tail splitting algorithm for better debugging context
      # Keep 70% from the head (most recent frames) and 30% from the tail (original cause)
      head_count = (max_frames * 0.7).round
      tail_count = max_frames - head_count

      # Get head frames (most recent)
      head_frames = frames.first(head_count)

      # Get tail frames (original cause)
      tail_frames = if tail_count.positive?
                      frames.last(tail_count)
      else
                      []
      end

      head_frames + tail_frames
    end

    def add_code_context(frames)
      # Only add context to app frames and a few library frames for performance
      context_frames = frames.select(&:app_frame?)
      context_frames += frames.select(&:library_frame?).first(3)

      context_frames.each_with_index do |frame, _index|
        updated_frame = frame.add_code_context(self, @config[:context_lines])
        frames[frames.index(frame)] = updated_frame if updated_frame
      end
    end

    def dedupe_frames(frames)
      seen = Set.new
      frames.select do |frame|
        # Create a key based on filename, line, and method
        key = [ frame.filename, frame.line_number, frame.function ].join(":")

        if seen.include?(key)
          false
        else
          seen.add(key)
          true
        end
      end
    end

    def determine_load_paths
      paths = []

      # Add Ruby load paths
      paths.concat($LOAD_PATH) if @config[:strip_load_path]

      # Add common Rails paths if in Rails
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        paths << Rails.root.to_s
        paths << Rails.root.join("app").to_s
        paths << Rails.root.join("lib").to_s
        paths << Rails.root.join("config").to_s
      end

      # Add current working directory
      paths << Dir.pwd

      # Add gem paths
      paths.concat(Gem.path.map { File.join(_1, "gems") }) if defined?(Gem)

      # Sort by length (longest first) for better matching
      paths.uniq.sort_by(&:length).reverse
    end
  end
end
