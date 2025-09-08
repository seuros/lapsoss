# frozen_string_literal: true

module Lapsoss
  BacktraceFrame = Data.define(
    :filename,
    :line_number,
    :method_name,
    :in_app,
    :raw_line,
    :function,
    :module_name,
    :code_context,
    :block_info
  ) do
    # Backward compatibility aliases
    alias_method :lineno, :line_number
    alias_method :raw, :raw_line

    def to_h
      {
        filename: filename,
        line_number: line_number,
        method: method_name,
        function: function,
        module: module_name,
        in_app: in_app,
        code_context: code_context,
        raw: raw_line
      }.compact
    end

    def add_code_context(processor, context_lines = 3)
      return unless filename && line_number && File.exist?(filename)

      with(code_context: processor.get_code_context(filename, line_number, context_lines))
    end

    def valid?
      filename && (line_number.nil? || line_number >= 0)
    end

    def library_frame?
      !in_app
    end

    def app_frame?
      in_app
    end

    def excluded?(exclude_patterns = [])
      return false if exclude_patterns.empty?

      exclude_patterns.any? do |pattern|
        case pattern
        when Regexp
          raw_line.match?(pattern)
        when String
          raw_line.include?(pattern)
        else
          false
        end
      end
    end

    def relative_filename(load_paths = [])
      return filename unless filename && load_paths.any?

      # Try to make path relative to load paths
      load_paths.each do |load_path|
        if filename.start_with?(load_path)
          relative = filename.sub(%r{^#{Regexp.escape(load_path)}/?}, "")
          return relative unless relative.empty?
        end
      end

      filename
    end
  end
end
