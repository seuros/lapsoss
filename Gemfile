# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in lapsoss.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"
gem "falcon"

gem "minitest", "~> 5.16"
gem "webmock", "~> 3.18"
gem "cgi" # Required for Ruby 4.0+ (removed from stdlib)
gem "ostruct" # Required for Ruby 4.0+ (removed from stdlib)
gem "tsort" # Required for Ruby 4.1+ (will be removed from stdlib)

# Rails dependencies for integration testing
# Allow CI to pin a specific Rails version via RAILS_VERSION
rails_version = ENV["RAILS_VERSION"]
if rails_version == "edge"
  gem "actionpack", github: "rails/rails", branch: "main"
  gem "railties", github: "rails/rails", branch: "main"
  gem "activesupport", github: "rails/rails", branch: "main"
elsif rails_version && !rails_version.empty?
  gem "actionpack", rails_version
  gem "railties", rails_version
else
  gem "actionpack", "~> 8.0"
  gem "railties", "~> 8.0"
end
