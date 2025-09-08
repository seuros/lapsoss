# frozen_string_literal: true

require "json"

module Lapsoss
  # Built-in release providers for common scenarios
  class ReleaseProviders
    def self.from_file(file_path)
      lambda do
        return nil unless File.exist?(file_path)

        content = File.read(file_path).strip
        return nil if content.empty?

        # Try to parse as JSON first
        begin
          JSON.parse(content)
        rescue JSON::ParserError
          # Treat as plain text version
          { version: content }
        end
      end
    end

    def self.from_ruby_constant(constant_name)
      lambda do
        constant = Object.const_get(constant_name)
        { version: constant.to_s }
      rescue NameError
        nil
      end
    end

    def self.from_gemfile_lock
      lambda do
        return nil unless File.exist?("Gemfile.lock")

        content = File.read("Gemfile.lock")

        # Extract gems with versions
        gems = {}
        content.scan(/^\s{4}(\w+)\s+\(([^)]+)\)/).each do |name, version|
          gems[name] = version
        end

        { gems: gems }
      end
    end

    def self.from_package_json
      lambda do
        return nil unless File.exist?("package.json")

        begin
          package_info = JSON.parse(File.read("package.json"))
          {
            version: package_info["version"],
            name: package_info["name"],
            dependencies: package_info["dependencies"]&.keys
          }.compact
        rescue JSON::ParserError
          nil
        end
      end
    end

    def self.from_rails_application
      lambda do
        return nil unless defined?(Rails) && Rails.respond_to?(:application)

        app = Rails.application
        return nil unless app

        info = {
          rails_version: Rails.version,
          environment: Rails.env,
          root: Rails.root.to_s
        }

        # Get application version if defined
        info[:app_version] = app.class.version if app.class.respond_to?(:version)

        # Get application name
        info[:app_name] = app.class.name if app.class.respond_to?(:name)

        info
      end
    end

    def self.from_capistrano
      lambda do
        # Check for Capistrano deployment files
        %w[REVISION current/REVISION].each do |file|
          next unless File.exist?(file)

          revision = File.read(file).strip
          next if revision.empty?

          return {
            revision: revision,
            deployed_at: File.mtime(file),
            deployment_method: "capistrano"
          }
        end

        nil
      end
    end
  end
end
