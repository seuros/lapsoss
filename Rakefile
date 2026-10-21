# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require 'rb_sys/extensiontask'
require 'fileutils'

GEMSPEC = Gem::Specification.load('lapsoss.gemspec')
# The published client is pure Ruby. Keep embedded-extension tasks available
# only for compatibility tests and embedders working from this checkout.
embedded_spec = GEMSPEC.dup
embedded_spec.extensions = [ 'ext/lapsoss_native/ffi/extconf.rb' ]
embedded_spec.metadata = GEMSPEC.metadata.merge(
  'cargo_crate_name' => 'lapsoss_native',
  'cargo_manifest_path' => 'ext/lapsoss_native/ffi/Cargo.toml'
)
RbSys::ExtensionTask.new('lapsoss_native', embedded_spec) do |extension|
  extension.lib_dir = 'lib/lapsoss'
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

desc 'Test the pure Ruby daemon client (no native extension required)'
task :test_daemon do
  ruby '-Ilib:test', 'test/daemon_delivery_test.rb'
  ruby '-Ilib:test', 'test/daemon_integration_test.rb'
  ruby '-Ilib:test', 'test/gem_packaging_test.rb'
end

namespace :daemon do
  desc 'Build the host lapsossd executable and its platform-specific gem'
  task :build do
    sh 'cargo', 'build', '-p', 'lapsossd', '--release', '--locked', '-j', '1'
    root = File.expand_path(__dir__)
    target = File.expand_path(ENV.fetch('CARGO_TARGET_DIR', 'target'), root)
    vendor = File.join(root, 'gems/lapsossd/vendor')
    FileUtils.mkdir_p(vendor)
    FileUtils.cp(File.join(target, 'release/lapsossd'), File.join(vendor, 'lapsossd'))
    FileUtils.chmod(0o755, File.join(vendor, 'lapsossd'))
    require_relative 'gems/lapsossd/lib/lapsossd/version'
    actual_version = IO.popen([ File.join(vendor, 'lapsossd'), '--version' ], &:read).strip
    unless actual_version == "lapsossd #{Lapsossd::VERSION}"
      raise "Daemon executable and gem versions differ: #{actual_version}"
    end
    FileUtils.mkdir_p(File.join(root, 'pkg'))
    Dir.chdir(File.join(root, 'gems/lapsossd')) do
      sh 'gem', 'build', 'lapsossd.gemspec'
      Dir.glob('lapsossd-*.gem').each { |gem| FileUtils.mv(gem, File.join(root, 'pkg')) }
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
