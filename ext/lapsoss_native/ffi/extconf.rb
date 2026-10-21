# frozen_string_literal: true

require "mkmf"
abort "lapsoss requires CRuby 4.0+" unless RUBY_ENGINE == "ruby" && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")
abort "lapsoss needs Cargo for source builds; install Rust or use a platform gem" unless find_executable("cargo")
require "rb_sys/mkmf"

create_rust_makefile("lapsoss/lapsoss_native") do |config|
  config.ext_dir = Pathname(__dir__).relative_path_from(Pathname(Dir.pwd)).to_s
end
