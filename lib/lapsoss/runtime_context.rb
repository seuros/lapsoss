# frozen_string_literal: true

require "rbconfig"
require "socket"

module Lapsoss
  # Boot-time context collection using Data class
  RuntimeContext = Data.define(:os, :runtime, :modules, :server_name, :release) do
    def self.current
      @current ||= new(
        os: collect_os_context,
        runtime: collect_runtime_context,
        modules: collect_modules,
        server_name: collect_server_name,
        release: collect_release
      )
    end

    def self.collect_os_context
      {
        name: RbConfig::CONFIG["host_os"],
        version: `uname -r 2>/dev/null`.strip.presence,
        build: `uname -v 2>/dev/null`.strip.presence,
        kernel_version: `uname -a 2>/dev/null`.strip.presence,
        machine: RbConfig::CONFIG["host_cpu"]
      }.compact
    rescue
      { name: RbConfig::CONFIG["host_os"] }
    end

    def self.collect_runtime_context
      {
        name: "ruby",
        version: RUBY_DESCRIPTION
      }
    end

    def self.collect_modules
      return {} unless defined?(Bundler)

      Bundler.load.specs.each_with_object({}) do |spec, h|
        h[spec.name] = spec.version.to_s
      end
    rescue
      {}
    end

    def self.collect_server_name
      Socket.gethostname
    rescue
      "unknown"
    end

    def self.collect_release
      # Try to get from git if available
      if File.exist?(".git")
        `git rev-parse HEAD 2>/dev/null`.strip.presence
      end
    rescue
      nil
    end

    def to_contexts
      {
        os: os,
        runtime: runtime
      }
    end
  end
end
