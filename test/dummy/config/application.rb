# frozen_string_literal: true

require_relative "boot"

require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Require lapsoss explicitly
require "lapsoss"
require "lapsoss/railtie"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0

    # Add the parent test directory to the load path for test_helper
    config.before_initialize do
      $LOAD_PATH.unshift File.expand_path("../../../", __dir__) if Rails.env.test?
    end

    # Lapsoss configuration will be added here
  end
end
