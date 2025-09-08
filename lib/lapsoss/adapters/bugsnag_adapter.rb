# frozen_string_literal: true

module Lapsoss
  module Adapters
    # Bugsnag adapter - backwards compatibility with InsightHub adapter
    # This allows users to configure with :bugsnag type but uses InsightHub implementation
    # The InsightHub adapter already checks for BUGSNAG_API_KEY environment variable
    class BugsnagAdapter < InsightHubAdapter
      # Inherits all functionality from InsightHubAdapter
    end
  end
end
