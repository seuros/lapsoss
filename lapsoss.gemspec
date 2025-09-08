# frozen_string_literal: true

require_relative 'lib/lapsoss/version'

Gem::Specification.new do |spec|
  spec.name = 'lapsoss'
  spec.version = Lapsoss::VERSION
  spec.authors = [ 'Abdelkader Boudih' ]
  spec.email = [ 'terminale@gmail.com' ]

  spec.summary = 'Modern error reporting with pluggable adapters for Rails applications'
  spec.description = "Lapsoss provides a clean, adapter-based approach to error reporting that doesn't monkey patch your application. Send errors to any error tracking service or custom backend through a unified API."
  spec.homepage = 'https://github.com/seuros/lapsoss'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/seuros/lapsoss'
  spec.metadata['changelog_uri'] = 'https://github.com/seuros/lapsoss/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob('lib/**/*') + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = [ 'lib' ]

  # Runtime dependencies
  spec.add_dependency 'activesupport', '>= 7.2', '< 9.0'
  spec.add_dependency 'concurrent-ruby', '>= 1.3.1'
  spec.add_dependency 'faraday', '~> 2.0'
  spec.add_dependency 'faraday-retry', '~> 2.0'
  spec.add_dependency 'zeitwerk', '~> 2.6'

  # Optional async dependencies
  spec.add_dependency 'async-http-faraday', '~> 0.19', '>= 0.19.0'

  # Development dependencies
  spec.add_development_dependency 'dotenv', '~> 3.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rubocop', '~> 1.0'
  spec.add_development_dependency 'rubocop-rails-omakase', '~> 1.0'
  spec.add_development_dependency 'steep', '~> 1.0'
  spec.add_development_dependency 'vcr', '~> 6.0'
  spec.add_development_dependency 'webmock', '~> 3.18'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
