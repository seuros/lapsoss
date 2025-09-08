# frozen_string_literal: true

require "yaml"

namespace :cassettes do
  desc "Sanitize VCR cassettes by scrubbing sensitive data"
  task :sanitize do
    dir = File.expand_path("../../test/cassettes", __dir__)
    files = Dir[File.join(dir, "*.yml")]
    puts "Sanitizing #{files.size} cassette(s) in #{dir}..."

    email_re = /\b[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\b/i
    hostname_key_re = /"hostname":"[^"]+"/
    home_path_re = Regexp.new(Regexp.escape(Dir.home))
    api_key_pairs = [
      [ /"apiKey":"[^"]+"/, '"apiKey":"<INSIGHT_HUB_API_KEY>"' ],
      [ /"access_token":"[^"]+"/, '"access_token":"<ROLLBAR_ACCESS_TOKEN>"' ],
      [ /api_key=[^&]+/, "api_key=<APPSIGNAL_FRONTEND_API_KEY>" ]
    ]

    header_key_map = {
      "X-Rollbar-Access-Token" => "<ROLLBAR_ACCESS_TOKEN>",
      "Bugsnag-Api-Key" => "<INSIGHT_HUB_API_KEY>",
      "Authorization" => "<AUTHORIZATION>"
    }

    files.each do |file|
      content = File.read(file)

      # Replace patterns in raw content safely
      content = content.gsub(email_re, "<EMAIL>")
      content = content.gsub(hostname_key_re, '"hostname":"<HOSTNAME>"')
      content = content.gsub(home_path_re, "/home/user")
      api_key_pairs.each { |(re, rep)| content = content.gsub(re, rep) }

      # Normalize User-Agent references to avoid machine leakage
      content = content.gsub(/User-Agent:\n\s+-\s+.+/, "User-Agent:\n  - lapsoss/x.y.z") rescue nil

      # Rewrite known header values
      header_key_map.each do |hdr, placeholder|
        content = content.gsub(/#{hdr}:(?:\n\s+-\s+.*)/, "#{hdr}:\n  - \"#{placeholder}\"")
      end

      File.write(file, content)
      puts "  scrubbed: #{File.basename(file)}"
    end

    puts "Done."
  end
end
