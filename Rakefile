# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'

# Core tests (without Rails)
Minitest::TestTask.create(:test_core) do |t|
  t.libs << 'test'
  t.test_globs = [ 'test/*_test.rb' ].reject { |f| f.include?('rails_') }
  t.verbose = true
end

# Rails integration tests (must be run from dummy app directory)
desc 'Run Rails integration tests'
task :test_rails do
  Dir.chdir('test/dummy') do
    system('bin/rails test ../../test/rails_*.rb')
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
