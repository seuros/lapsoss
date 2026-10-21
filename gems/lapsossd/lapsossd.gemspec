# frozen_string_literal: true

require_relative 'lib/lapsossd/version'

Gem::Specification.new do |spec|
  spec.name = 'lapsossd'
  spec.version = Lapsossd::VERSION
  spec.authors = [ 'Abdelkader Boudih' ]
  spec.summary = 'Precompiled local error aggregation and delivery daemon for Lapsoss'
  spec.homepage = 'https://github.com/seuros/lapsoss'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'
  spec.platform = Gem::Platform.local
  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.files = Dir.chdir(__dir__) { Dir['lib/**/*.rb', 'exe/lapsossd', 'vendor/lapsossd', 'README.md', 'LICENSE.txt'] }
  spec.bindir = 'exe'
  spec.executables = [ 'lapsossd' ]
  spec.require_paths = [ 'lib' ]
  # Platform gems must contain a real executable; never publish an empty shell
  # or fall back to compiling/downloading during installation.
  binary = File.join(__dir__, 'vendor/lapsossd')
  raise 'Run `bundle exec rake daemon:build` from the repository root first' unless File.executable?(binary)
end
