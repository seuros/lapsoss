# frozen_string_literal: true

module Lapsoss
  class BacktraceFrameFactory
    # Backtrace line patterns for different Ruby implementations
    BACKTRACE_PATTERNS = [
      # Standard Ruby format: filename.rb:123:in `method_name'
      /^(?<filename>[^:]+):(?<line>\d+):in [`'](?<method>.*?)[`']$/,

      # Ruby format without method: filename.rb:123
      /^(?<filename>[^:]+):(?<line>\d+)$/,

      # JRuby format: filename.rb:123:in method_name
      /^(?<filename>[^:]+):(?<line>\d+):in (?<method>.*)$/,

      # Eval'd code: (eval):123:in `method_name'
      /^\(eval\):(?<line>\d+):in [`'](?<method>.*?)[`']$/,

      # Block format: filename.rb:123:in `block in method_name'
      /^(?<filename>[^:]+):(?<line>\d+):in [`']block (?<block_level>\(\d+\s+levels\)\s+)?in (?<method>.*?)[`']$/,

      # Native extension format: [native_gem] filename.c:123:in `method_name'
      /^\[(?<native_gem>[^\]]+)\]\s*(?<filename>[^:]+):(?<line>\d+):in [`'](?<method>.*?)[`']$/,

      # Java backtrace format: org.jruby.Ruby.runScript(Ruby.java:123)
      /^(?<method>[^(]+)\((?<filename>[^:)]+):(?<line>\d+)\)$/,

      # Java backtrace format without line number: org.jruby.Ruby.runScript(Ruby.java)
      /^(?<method>[^(]+)\((?<filename>[^:)]+)\)$/,

      # Malformed Ruby format with invalid line number: filename.rb:abc:in `method'
      /^(?<filename>[^:]+):(?<line>[^:]*):in [`'](?<method>.*?)[`']$/,

      # Malformed Ruby format with missing line number: filename.rb::in `method'
      /^(?<filename>[^:]+)::in [`'](?<method>.*?)[`']$/,

      # Malformed Ruby format with missing method: filename.rb:123:in
      /^(?<filename>[^:]+):(?<line>\d+):in$/
    ].freeze

    # Common paths that indicate library/gem code
    LIBRARY_INDICATORS = [
      "/gems/",
      "/.bundle/",
      "/vendor/",
      "/ruby/",
      "(eval)",
      "(irb)",
      "/lib/ruby/",
      "/rbenv/",
      "/rvm/",
      "/usr/lib/ruby",
      "/System/Library/Frameworks"
    ].freeze

    def self.from_raw_line(raw_line, in_app_patterns: [], exclude_patterns: [], load_paths: [])
      new(in_app_patterns: in_app_patterns, exclude_patterns: exclude_patterns, load_paths: load_paths)
        .create_frame(raw_line)
    end

    def initialize(in_app_patterns: [], exclude_patterns: [], load_paths: [])
      @in_app_patterns = Array(in_app_patterns)
      @exclude_patterns = Array(exclude_patterns)
      @load_paths = Array(load_paths)
    end

    def create_frame(raw_line)
      @raw_line = raw_line.to_s.strip
      parse_backtrace_line
    end

    private

    def parse_backtrace_line
      filename, line_number, method_name, function, module_name, block_info = parse_line_components

      in_app = determine_app_status(filename)

      # Keep both absolute and normalized paths
      absolute_path = filename
      normalized_filename = normalize_path(filename) if filename

      BacktraceFrame.new(
        filename: normalized_filename,
        absolute_path: absolute_path,
        line_number: line_number,
        method_name: method_name,
        in_app: in_app,
        raw_line: @raw_line,
        function: function,
        module_name: module_name,
        code_context: nil,
        block_info: block_info
      )
    end

    def parse_line_components
      BACKTRACE_PATTERNS.each do |pattern|
        match = @raw_line.match(pattern)
        next unless match

        filename = match[:filename]
        # Handle malformed line numbers - convert invalid numbers to 0
        line_number = if match.names.include?("line") && match[:line]
                        match[:line].match?(/^\d+$/) ? match[:line].to_i : 0
        end
        method_name = match.names.include?("method") ? match[:method] : nil
        match.names.include?("native_gem") ? match[:native_gem] : nil
        block_level = match.names.include?("block_level") ? match[:block_level] : nil

        # Set default method name for lines without methods (top-level execution)
        method_name = "<main>" if method_name.nil?

        function, module_name, block_info = process_method_info(method_name, block_level)

        return [ filename, line_number, method_name, function, module_name, block_info ]
      end

      # Fallback: treat entire line as filename if no pattern matches
      [ @raw_line, nil, "<main>", "<main>", nil, nil ]
    end

    def process_method_info(method_name, block_level)
      return [ nil, nil, nil ] unless method_name

      function = nil
      module_name = nil
      block_info = nil

      # Extract module/class and method information
      if method_name.include?(".")
        # Class method: Module.method
        parts = method_name.split(".", 2)
        module_name = parts[0] if parts[0] != method_name
        function = parts[1] || method_name
      elsif method_name.include?("#")
        # Instance method: Module#method
        parts = method_name.split("#", 2)
        module_name = parts[0] if parts[0] != method_name
        function = parts[1] || method_name
      elsif method_name.start_with?("block")
        # Block method: process specially
        function = method_name
        block_info = process_block_info(method_name, block_level)
      else
        function = method_name
      end

      # Clean up function name
      function = function&.strip
      module_name = module_name&.strip

      [ function, module_name, block_info ]
    end

    def process_block_info(method_name, block_level)
      return nil unless method_name&.include?("block")

      block_info = {
        type: :block,
        level: block_level,
        in_method: nil
      }

      # Extract the method that contains the block
      block_info[:in_method] = ::Regexp.last_match(1) if method_name =~ /block (?:\([^)]+\)\s+)?in (.+)/

      block_info
    end

    def determine_app_status(filename)
      return false unless filename

      # Check explicit patterns first
      if @in_app_patterns.any?
        return @in_app_patterns.any? do |pattern|
          case pattern
          when Regexp
            filename.match?(pattern)
          when String
            filename.include?(pattern)
          else
            false
          end
        end
      end

      # Default heuristics: check for library indicators
      in_app = LIBRARY_INDICATORS.none? { |indicator| filename.include?(indicator) }

      # Special cases
      in_app = false if filename.start_with?("(") && filename.end_with?(")") # Eval, irb, etc.

      in_app
    end

    def normalize_path(filename)
      return filename unless filename

      # Expand relative paths
      filename = File.expand_path(filename) if filename.start_with?("./")

      # Handle Windows paths on Unix systems (for cross-platform stack traces)
      filename = filename.tr("\\", "/") if filename.include?("\\") && filename.exclude?("/")

      # Strip load paths to make traces more readable
      return filename unless @load_paths.any?

      original = filename
      filename = make_relative_filename(filename)

      # Keep absolute path if relative didn't work well
      filename = original if filename.empty? || filename == "."

      filename
    end

    def make_relative_filename(filename)
      return filename unless filename && @load_paths.any?

      # Try to make path relative to load paths
      @load_paths.each do |load_path|
        if filename.start_with?(load_path)
          relative = filename.sub(%r{^#{Regexp.escape(load_path)}/?}, "")
          return relative unless relative.empty?
        end
      end

      filename
    end
  end
end
