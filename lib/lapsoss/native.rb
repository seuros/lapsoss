# frozen_string_literal: true

raise LoadError, "lapsoss requires CRuby 4.0+" unless RUBY_ENGINE == "ruby" && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")

begin
  require "lapsoss/lapsoss_native"
rescue LoadError => error
  raise LoadError, "Embedded delivery is only available in a source checkout with `bundle exec rake compile`. " \
                   "The lapsoss gem uses lapsossd; configure daemon_socket instead. Original error: #{error.message}"
end
