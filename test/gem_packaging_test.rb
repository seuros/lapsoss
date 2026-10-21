# frozen_string_literal: true

require "minitest/autorun"
require "rubygems/package"

class GemPackagingTest < Minitest::Test
  def test_client_has_no_native_extension_or_runtime_build_dependency
    spec = Gem::Specification.load(File.expand_path("../lapsoss.gemspec", __dir__))
    assert_empty spec.extensions
    assert_equal %w[activesupport concurrent-ruby zeitwerk], spec.runtime_dependencies.map(&:name).sort
    assert_empty spec.files.grep(%r{\A(?:test|ext|daemon)/|\.(?:rs|so|bundle)\z})
    assert_includes spec.files, "lib/lapsoss/daemon_delivery.rb"
  end

  def test_daemon_version_matches_its_gem_wrapper
    require_relative "../gems/lapsossd/lib/lapsossd/version"
    manifest = File.read(File.expand_path("../daemon/Cargo.toml", __dir__))
    assert_equal Lapsossd::VERSION, manifest.match(/^version = "([^"]+)"/)[1]
  end
end
