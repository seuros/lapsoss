# frozen_string_literal: true

raise LoadError, "lapsoss requires CRuby 4.0+" unless RUBY_ENGINE == "ruby" && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")

begin
  require "lapsoss/lapsoss_native"
rescue LoadError => error
  raise LoadError, "lapsoss requires its native extension. Install a platform gem or run `bundle exec rake compile` " \
                   "with Rust installed. Original error: #{error.message}"
end
