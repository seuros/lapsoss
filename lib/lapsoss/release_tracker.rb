# frozen_string_literal: true

require "digest"

module Lapsoss
  # Release and version tracking system
  class ReleaseTracker
    def initialize(configuration = {})
      @version_providers = configuration[:version_providers] || []
      @git_enabled = configuration[:git_enabled] != false
      @environment_enabled = configuration[:environment_enabled] != false
      @deployment_enabled = configuration[:deployment_enabled] != false
      @cache_duration = configuration[:cache_duration] || 300 # 5 minutes
      @cached_release_info = nil
      @cache_timestamp = nil

      # Auto-register rails_app_version provider if available
      add_rails_app_version_provider if defined?(Rails) && Rails.application.respond_to?(:version)
    end

    def get_release_info
      now = Time.zone.now

      # Return cached info if still valid
      if @cached_release_info && @cache_timestamp && (now - @cache_timestamp) < @cache_duration
        return @cached_release_info
      end

      # Build fresh release info
      release_info = {}

      # Add custom version providers
      @version_providers.each do |provider|
        if provider_info = provider.call
          release_info.merge!(provider_info)
        end
      rescue StandardError => e
        warn "Release provider failed: #{e.message}"
      end

      # Add Git information
      if @git_enabled && (git_info = detect_git_info)
        release_info.merge!(git_info)
      end

      # Add environment information
      if @environment_enabled && (env_info = detect_environment_info)
        release_info.merge!(env_info)
      end

      # Add deployment information
      if @deployment_enabled && (deployment_info = detect_deployment_info)
        release_info.merge!(deployment_info)
      end

      # Generate release ID if not provided
      release_info[:release_id] ||= generate_release_id(release_info)

      # Cache the result
      @cached_release_info = release_info
      @cache_timestamp = now

      release_info
    end

    def add_version_provider(&block)
      @version_providers << block
    end

    def clear_cache
      @cached_release_info = nil
      @cache_timestamp = nil
    end

    def add_rails_app_version_provider
      add_version_provider do
        if defined?(Rails) && Rails.application.respond_to?(:version)
          version = Rails.application.version
          {
            rails_app_version: version.to_s,
            rails_app_version_cache_key: version.to_cache_key,
            rails_app_environment: Rails.application.env
          }
        end
      end
    end

    private

    def detect_git_info
      return nil unless File.exist?(".git")

      git_info = {}

      begin
        # Get current commit SHA
        commit_sha = execute_git_command("rev-parse HEAD")
        git_info[:commit_sha] = commit_sha if commit_sha

        # Get short commit SHA
        short_sha = execute_git_command("rev-parse --short HEAD")
        git_info[:short_sha] = short_sha if short_sha

        # Get branch name
        branch = execute_git_command("rev-parse --abbrev-ref HEAD")
        git_info[:branch] = branch if branch && branch != "HEAD"

        # Get commit timestamp
        commit_timestamp = execute_git_command("log -1 --format=%ct")
        git_info[:commit_timestamp] = Time.zone.at(commit_timestamp.to_i) if commit_timestamp.present?

        # Get commit message
        commit_message = execute_git_command("log -1 --format=%s")
        git_info[:commit_message] = commit_message if commit_message

        # Get committer info
        committer = execute_git_command("log -1 --format=%cn")
        git_info[:committer] = committer if committer

        # Get tag if on a tag
        tag = execute_git_command("describe --exact-match --tags HEAD 2>/dev/null")
        git_info[:tag] = tag if tag.present?

        # Get latest tag
        latest_tag = execute_git_command("describe --tags --abbrev=0 2>/dev/null")
        git_info[:latest_tag] = latest_tag if latest_tag.present?

        # Get commits since latest tag
        if latest_tag
          commits_since_tag = execute_git_command("rev-list #{latest_tag}..HEAD --count")
          git_info[:commits_since_tag] = commits_since_tag.to_i if commits_since_tag
        end

        # Check if working directory is dirty
        git_status = execute_git_command("status --porcelain")
        git_info[:dirty] = !git_status.empty? if git_status

        # Get remote URL
        remote_url = execute_git_command("config --get remote.origin.url")
        git_info[:remote_url] = sanitize_remote_url(remote_url) if remote_url

        git_info
      rescue StandardError => e
        warn "Failed to detect Git info: #{e.message}"
        nil
      end
    end

    def detect_environment_info
      env_info = {}

      # Try rails_app_version first if available
      if defined?(Rails) && Rails.application.respond_to?(:version)
        env_info[:version] = Rails.application.version.to_s
        env_info[:app_version] = Rails.application.version.to_s

        # Add detailed version info
        version_obj = Rails.application.version
        env_info[:version_major] = version_obj.major
        env_info[:version_minor] = version_obj.minor
        env_info[:version_patch] = version_obj.patch
        env_info[:version_prerelease] = version_obj.prerelease? if version_obj.respond_to?(:prerelease?)
      else
        # Fallback to environment variables
        env_info[:app_version] = ENV["APP_VERSION"] if ENV["APP_VERSION"]
        env_info[:version] = ENV["VERSION"] if ENV["VERSION"]
      end

      # Environment detection
      env_info[:environment] = detect_environment

      # Application name
      env_info[:app_name] = ENV["APP_NAME"] if ENV["APP_NAME"]

      # Build information
      env_info[:build_number] = ENV["BUILD_NUMBER"] if ENV["BUILD_NUMBER"]
      env_info[:build_id] = ENV["BUILD_ID"] if ENV["BUILD_ID"]
      env_info[:build_url] = ENV["BUILD_URL"] if ENV["BUILD_URL"]

      # CI/CD information
      env_info[:ci] = detect_ci_info

      env_info.compact
    end

    def detect_deployment_info
      deployment_info = {}

      # Deployment timestamp
      if ENV["DEPLOYMENT_TIME"]
        deployment_info[:deployment_time] = parse_time(ENV["DEPLOYMENT_TIME"])
      elsif ENV["DEPLOYED_AT"]
        deployment_info[:deployment_time] = parse_time(ENV["DEPLOYED_AT"])
      end

      # Deployment ID
      deployment_info[:deployment_id] = ENV["DEPLOYMENT_ID"] if ENV["DEPLOYMENT_ID"]

      # Platform-specific detection
      deployment_info.merge!(detect_heroku_info)
      deployment_info.merge!(detect_aws_info)
      deployment_info.merge!(detect_gcp_info)
      deployment_info.merge!(detect_azure_info)
      deployment_info.merge!(detect_docker_info)
      deployment_info.merge!(detect_kubernetes_info)

      deployment_info.compact
    end

    def detect_environment
      # Try rails_app_version first if available
      return Rails.application.env if defined?(Rails) && Rails.application.respond_to?(:env)

      return ENV["RAILS_ENV"] if ENV["RAILS_ENV"]
      return ENV["RACK_ENV"] if ENV["RACK_ENV"]
      return ENV["NODE_ENV"] if ENV["NODE_ENV"]
      return ENV["ENVIRONMENT"] if ENV["ENVIRONMENT"]
      return ENV["ENV"] if ENV["ENV"]

      # Try to detect from Rails if available
      return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)

      # Default fallback
      "unknown"
    end

    def detect_ci_info
      ci_info = {}

      # GitHub Actions
      if ENV["GITHUB_ACTIONS"]
        ci_info[:provider] = "github_actions"
        ci_info[:run_id] = ENV.fetch("GITHUB_RUN_ID", nil)
        ci_info[:run_number] = ENV.fetch("GITHUB_RUN_NUMBER", nil)
        ci_info[:workflow] = ENV.fetch("GITHUB_WORKFLOW", nil)
        ci_info[:actor] = ENV.fetch("GITHUB_ACTOR", nil)
        ci_info[:repository] = ENV.fetch("GITHUB_REPOSITORY", nil)
        ci_info[:ref] = ENV.fetch("GITHUB_REF", nil)
        ci_info[:sha] = ENV.fetch("GITHUB_SHA", nil)
      end

      # GitLab CI
      if ENV["GITLAB_CI"]
        ci_info[:provider] = "gitlab_ci"
        ci_info[:pipeline_id] = ENV.fetch("CI_PIPELINE_ID", nil)
        ci_info[:job_id] = ENV.fetch("CI_JOB_ID", nil)
        ci_info[:job_name] = ENV.fetch("CI_JOB_NAME", nil)
        ci_info[:commit_sha] = ENV.fetch("CI_COMMIT_SHA", nil)
        ci_info[:commit_ref] = ENV.fetch("CI_COMMIT_REF_NAME", nil)
        ci_info[:project_url] = ENV.fetch("CI_PROJECT_URL", nil)
      end

      # Jenkins
      if ENV["JENKINS_URL"]
        ci_info[:provider] = "jenkins"
        ci_info[:build_number] = ENV.fetch("BUILD_NUMBER", nil)
        ci_info[:build_id] = ENV.fetch("BUILD_ID", nil)
        ci_info[:job_name] = ENV.fetch("JOB_NAME", nil)
        ci_info[:build_url] = ENV.fetch("BUILD_URL", nil)
        ci_info[:git_commit] = ENV.fetch("GIT_COMMIT", nil)
        ci_info[:git_branch] = ENV.fetch("GIT_BRANCH", nil)
      end

      # CircleCI
      if ENV["CIRCLECI"]
        ci_info[:provider] = "circleci"
        ci_info[:build_num] = ENV.fetch("CIRCLE_BUILD_NUM", nil)
        ci_info[:workflow_id] = ENV.fetch("CIRCLE_WORKFLOW_ID", nil)
        ci_info[:job] = ENV.fetch("CIRCLE_JOB", nil)
        ci_info[:project_reponame] = ENV.fetch("CIRCLE_PROJECT_REPONAME", nil)
        ci_info[:sha1] = ENV.fetch("CIRCLE_SHA1", nil)
        ci_info[:branch] = ENV.fetch("CIRCLE_BRANCH", nil)
      end

      # Travis CI
      if ENV["TRAVIS"]
        ci_info[:provider] = "travis"
        ci_info[:build_id] = ENV.fetch("TRAVIS_BUILD_ID", nil)
        ci_info[:build_number] = ENV.fetch("TRAVIS_BUILD_NUMBER", nil)
        ci_info[:job_id] = ENV.fetch("TRAVIS_JOB_ID", nil)
        ci_info[:commit] = ENV.fetch("TRAVIS_COMMIT", nil)
        ci_info[:branch] = ENV.fetch("TRAVIS_BRANCH", nil)
        ci_info[:tag] = ENV.fetch("TRAVIS_TAG", nil)
      end

      ci_info
    end

    def detect_heroku_info
      return {} unless ENV["HEROKU_APP_NAME"]

      {
        platform: "heroku",
        app_name: ENV.fetch("HEROKU_APP_NAME", nil),
        dyno: ENV.fetch("DYNO", nil),
        slug_commit: ENV.fetch("HEROKU_SLUG_COMMIT", nil),
        release_version: ENV.fetch("HEROKU_RELEASE_VERSION", nil),
        slug_description: ENV.fetch("HEROKU_SLUG_DESCRIPTION", nil)
      }
    end

    def detect_aws_info
      info = {}

      if ENV["AWS_EXECUTION_ENV"]
        info[:platform] = "aws"
        info[:execution_env] = ENV["AWS_EXECUTION_ENV"]
        info[:region] = ENV["AWS_REGION"] || ENV.fetch("AWS_DEFAULT_REGION", nil)
        info[:function_name] = ENV.fetch("AWS_LAMBDA_FUNCTION_NAME", nil)
        info[:function_version] = ENV.fetch("AWS_LAMBDA_FUNCTION_VERSION", nil)
      end

      # EC2 metadata (if available)
      if ENV["EC2_INSTANCE_ID"]
        info[:platform] = "aws_ec2"
        info[:instance_id] = ENV["EC2_INSTANCE_ID"]
        info[:instance_type] = ENV.fetch("EC2_INSTANCE_TYPE", nil)
        info[:availability_zone] = ENV.fetch("EC2_AVAILABILITY_ZONE", nil)
      end

      info
    end

    def detect_gcp_info
      info = {}

      if ENV["GOOGLE_CLOUD_PROJECT"]
        info[:platform] = "gcp"
        info[:project] = ENV["GOOGLE_CLOUD_PROJECT"]
        info[:region] = ENV.fetch("GOOGLE_CLOUD_REGION", nil)
        info[:function_name] = ENV.fetch("FUNCTION_NAME", nil)
        info[:function_signature_type] = ENV.fetch("FUNCTION_SIGNATURE_TYPE", nil)
      end

      # App Engine
      if ENV["GAE_APPLICATION"]
        info[:platform] = "gcp_app_engine"
        info[:application] = ENV["GAE_APPLICATION"]
        info[:service] = ENV.fetch("GAE_SERVICE", nil)
        info[:version] = ENV.fetch("GAE_VERSION", nil)
        info[:runtime] = ENV.fetch("GAE_RUNTIME", nil)
      end

      info
    end

    def detect_azure_info
      info = {}

      if ENV["WEBSITE_SITE_NAME"]
        info[:platform] = "azure"
        info[:site_name] = ENV["WEBSITE_SITE_NAME"]
        info[:resource_group] = ENV.fetch("WEBSITE_RESOURCE_GROUP", nil)
        info[:subscription_id] = ENV.fetch("WEBSITE_OWNER_NAME", nil)
        info[:sku] = ENV.fetch("WEBSITE_SKU", nil)
      end

      info
    end

    def detect_docker_info
      info = {}

      if ENV["DOCKER_CONTAINER_ID"] || File.exist?("/.dockerenv")
        info[:platform] = "docker"
        info[:container_id] = ENV["DOCKER_CONTAINER_ID"]
        info[:image] = ENV.fetch("DOCKER_IMAGE", nil)
        info[:tag] = ENV.fetch("DOCKER_TAG", nil)
      end

      info
    end

    def detect_kubernetes_info
      info = {}

      if ENV["KUBERNETES_SERVICE_HOST"]
        info[:platform] = "kubernetes"
        info[:namespace] = ENV.fetch("KUBERNETES_NAMESPACE", nil)
        info[:pod_name] = ENV.fetch("HOSTNAME", nil)
        info[:service_account] = ENV.fetch("KUBERNETES_SERVICE_ACCOUNT", nil)
        info[:cluster_name] = ENV.fetch("CLUSTER_NAME", nil)
        info[:node_name] = ENV.fetch("NODE_NAME", nil)
      end

      info
    end

    def execute_git_command(command)
      result = `git #{command} 2>/dev/null`.strip
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def sanitize_remote_url(url)
      # Remove credentials from Git URLs
      url.gsub(%r{://[^@/]+@}, "://")
    end

    def parse_time(time_str)
      return nil unless time_str

      # Try different time formats
      formats = [
        "%Y-%m-%dT%H:%M:%S%z",      # ISO 8601 with timezone
        "%Y-%m-%dT%H:%M:%SZ",       # ISO 8601 UTC
        "%Y-%m-%d %H:%M:%S %z",     # Standard format with timezone
        "%Y-%m-%d %H:%M:%S",        # Standard format without timezone
        "%s"                        # Unix timestamp
      ]

      formats.each do |format|
        return Time.strptime(time_str, format)
      rescue ArgumentError
        next
      end

      # Try parsing as integer (Unix timestamp)
      begin
        return Time.zone.at(time_str.to_i) if time_str.match?(/^\d+$/)
      rescue ArgumentError
        nil
      end

      nil
    end

    def generate_release_id(release_info)
      # Generate a unique release ID based on available information
      components = []

      # Prioritize version-like information
      components << release_info[:app_version] if release_info[:app_version]
      components << release_info[:version] if release_info[:version]
      components << release_info[:tag] if release_info[:tag]
      components << release_info[:short_sha] if release_info[:short_sha]
      components << release_info[:commit_sha] if release_info[:commit_sha] && components.empty?

      # Add environment if available
      components << release_info[:environment] if release_info[:environment]

      # Add deployment ID if available
      components << release_info[:deployment_id] if release_info[:deployment_id]

      # If we have components, join them
      if components.any?
        release_id = components.join("-")
        # Truncate if too long
        release_id.length > 64 ? release_id[0, 64] : release_id
      else
        # Generate hash from all available info
        info_string = release_info.to_s
        Digest::SHA256.hexdigest(info_string)[0, 8]
      end
    end
  end
end
