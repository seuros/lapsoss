# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require 'rb_sys/extensiontask'

GEMSPEC = Gem::Specification.load('lapsoss.gemspec')
NATIVE_PLATFORMS = %w[x86_64-linux aarch64-linux x86_64-linux-musl arm64-darwin x86_64-darwin].freeze
RbSys::ExtensionTask.new('lapsoss_native', GEMSPEC) do |extension|
  extension.lib_dir = 'lib/lapsoss'
  extension.cross_compile = true
  extension.cross_platform = NATIVE_PLATFORMS
end

host_binary = "lib/lapsoss/lapsoss_native.#{RbConfig::CONFIG['DLEXT']}"
Rake::Task[host_binary].clear if ENV['RUBY_TARGET'] && Rake::Task.task_defined?(host_binary)

# Core tests (without Rails)
Minitest::TestTask.create(:test_core) do |t|
  t.libs << 'test'
  t.test_globs = Dir['test/*_test.rb'].reject { |f| f.include?('rails_') }
  t.verbose = true
end
task test_core: :compile

# Rails integration tests (must be run from dummy app directory)
desc 'Run Rails integration tests'
task :test_rails do
  Dir.chdir('test/dummy') do
    sh 'bin/rails test ../../test/rails_*.rb'
  end
end
task test_rails: :compile

namespace :platforms do
  desc 'Cross-compile platform gems (Docker required)'
  task :build do
    NATIVE_PLATFORMS.each do |platform|
      sh 'bundle', 'exec', 'rb-sys-dock', '--platform', platform, '--ruby-versions', '4.0', '--mount-toolchains', '--build'
    end
  end
end

# All tests (combine core and rails)
desc 'Run all tests'
task :test do
  # Run core tests first
  Rake::Task['test_core'].invoke

  # Then run Rails tests
  Rake::Task['test_rails'].invoke
end

task default: :test
