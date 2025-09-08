# frozen_string_literal: true

module Lapsoss
  module Middleware
    class ReleaseTracker < Base
      def initialize(app, release_provider: nil)
        super(app)
        @release_provider = release_provider
      end

      def call(event, hint = {})
        add_release_info(event, hint)
        @app.call(event, hint)
      end

      private

      def add_release_info(event, hint)
        release_info = @release_provider&.call(event, hint) || auto_detect_release

        event.context[:release] = release_info if release_info
      end

      def auto_detect_release
        release_info = {}

        # Try to detect Git information
        if git_info = detect_git_info
          release_info.merge!(git_info)
        end

        # Try to detect deployment info
        if deployment_info = detect_deployment_info
          release_info.merge!(deployment_info)
        end

        release_info.empty? ? nil : release_info
      end

      def detect_git_info
        return nil unless File.exist?(".git")

        begin
          # Get current commit SHA
          commit_sha = `git rev-parse HEAD`.strip
          return nil if commit_sha.empty?

          # Get branch name
          branch = `git rev-parse --abbrev-ref HEAD`.strip
          branch = nil if branch.empty? || branch == "HEAD"

          # Get commit timestamp
          commit_time = `git log -1 --format=%ct`.strip
          commit_timestamp = commit_time.empty? ? nil : Time.zone.at(commit_time.to_i)

          # Get tag if on a tag
          tag = `git describe --exact-match --tags HEAD 2>/dev/null`.strip
          tag = nil if tag.empty?

          {
            commit_sha: commit_sha,
            branch: branch,
            tag: tag,
            commit_timestamp: commit_timestamp
          }.compact
        rescue StandardError
          nil
        end
      end

      def detect_deployment_info
        info = {}

        # Check common deployment environment variables
        info[:deployment_id] = ENV["DEPLOYMENT_ID"] if ENV["DEPLOYMENT_ID"]
        info[:build_number] = ENV["BUILD_NUMBER"] if ENV["BUILD_NUMBER"]
        info[:deployment_time] = parse_deployment_time(ENV["DEPLOYMENT_TIME"]) if ENV["DEPLOYMENT_TIME"]

        # Check Heroku
        if ENV["HEROKU_APP_NAME"]
          info[:platform] = "heroku"
          info[:app_name] = ENV["HEROKU_APP_NAME"]
          info[:dyno] = ENV.fetch("DYNO", nil)
          info[:slug_commit] = ENV.fetch("HEROKU_SLUG_COMMIT", nil)
        end

        # Check AWS
        if ENV["AWS_EXECUTION_ENV"]
          info[:platform] = "aws"
          info[:execution_env] = ENV["AWS_EXECUTION_ENV"]
          info[:region] = ENV.fetch("AWS_REGION", nil)
        end

        # Check Docker
        if ENV["DOCKER_CONTAINER_ID"] || File.exist?("/.dockerenv")
          info[:platform] = "docker"
          info[:container_id] = ENV["DOCKER_CONTAINER_ID"]
        end

        # Check Kubernetes
        if ENV["KUBERNETES_SERVICE_HOST"]
          info[:platform] = "kubernetes"
          info[:namespace] = ENV.fetch("KUBERNETES_NAMESPACE", nil)
          info[:pod_name] = ENV.fetch("HOSTNAME", nil)
        end

        info.empty? ? nil : info
      end

      def parse_deployment_time(time_str)
        Time.zone.parse(time_str)
      rescue StandardError
        nil
      end
    end
  end
end
