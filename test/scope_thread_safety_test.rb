# frozen_string_literal: true

require_relative "test_helper"

class ScopeThreadSafetyTest < ActiveSupport::TestCase
  setup do
    @configuration = Lapsoss::Configuration.new
    @configuration.enabled = true
    @configuration.async = false # Use synchronous mode for testing
    @configuration.use_sentry(dsn: "https://key@sentry.io/123456")
    @configuration.validate!
    @configuration.apply!
    @client = Lapsoss::Client.new(@configuration)
  end

  teardown do
    # Clean up thread local storage
    Thread.current[:lapsoss_scope] = nil
  end

  test "scope isolation between threads" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create multiple threads that each work with their own scope
    threads = Array.new(10) do |i|
      Thread.new do
        # Each thread should have its own isolated scope
        @client.add_breadcrumb("thread-#{i}-breadcrumb-1", type: :navigation)
        @client.current_scope.tags["thread_id"] = i
        @client.current_scope.user["id"] = "user-#{i}"
        @client.current_scope.extra["data"] = "thread-#{i}-data"

        # Add more breadcrumbs to test array operations
        @client.add_breadcrumb("thread-#{i}-breadcrumb-2", type: :user)
        @client.add_breadcrumb("thread-#{i}-breadcrumb-3", type: :system)

        # Capture the current scope state
        scope = @client.current_scope
        results[i] = {
          breadcrumbs: scope.breadcrumbs.map { |b| b[:message] },
          tags: scope.tags.dup,
          user: scope.user.dup,
          extra: scope.extra.dup
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    # Wait for all threads to complete
    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify each thread had isolated scope
    assert_equal 10, results.size

    10.times do |i|
      result = results[i]
      assert_not_nil result, "Thread #{i} result missing"

      # Check breadcrumbs are thread-specific
      expected_breadcrumbs = [
        "thread-#{i}-breadcrumb-1",
        "thread-#{i}-breadcrumb-2",
        "thread-#{i}-breadcrumb-3"
      ]
      assert_equal expected_breadcrumbs, result[:breadcrumbs]

      # Check tags are thread-specific
      assert_equal({ "thread_id" => i }, result[:tags])

      # Check user is thread-specific
      assert_equal({ "id" => "user-#{i}" }, result[:user])

      # Check extra is thread-specific
      assert_equal({ "data" => "thread-#{i}-data" }, result[:extra])
    end
  end

  test "concurrent breadcrumb addition" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create multiple threads that all add breadcrumbs to the same scope
    # Each thread operates on its own scope, so no conflicts should occur
    threads = Array.new(20) do |i|
      Thread.new do
        # Each thread adds multiple breadcrumbs rapidly
        5.times do |j|
          @client.add_breadcrumb("thread-#{i}-breadcrumb-#{j}", type: :custom)
        end

        # Capture final breadcrumb count
        scope = @client.current_scope
        results[i] = {
          breadcrumb_count: scope.breadcrumbs.length,
          breadcrumbs: scope.breadcrumbs.map { |b| b[:message] }
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify each thread has exactly 5 breadcrumbs (since they're isolated)
    20.times do |i|
      result = results[i]
      assert_not_nil result, "Thread #{i} result missing"
      assert_equal 5, result[:breadcrumb_count], "Thread #{i} breadcrumb count"

      # Verify breadcrumbs are thread-specific
      expected_breadcrumbs = Array.new(5) { |j| "thread-#{i}-breadcrumb-#{j}" }
      assert_equal expected_breadcrumbs, result[:breadcrumbs]
    end
  end

  test "breadcrumb size limiting under concurrent access" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create threads that add more breadcrumbs than the limit (20)
    threads = Array.new(5) do |i|
      Thread.new do
        # Each thread adds 25 breadcrumbs (more than the 20 limit)
        25.times do |j|
          @client.add_breadcrumb("thread-#{i}-breadcrumb-#{j}", type: :custom)
        end

        scope = @client.current_scope
        results[i] = {
          breadcrumb_count: scope.breadcrumbs.length,
          first_breadcrumb: scope.breadcrumbs.first[:message],
          last_breadcrumb: scope.breadcrumbs.last[:message]
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify each thread's breadcrumbs are limited to 20
    5.times do |i|
      result = results[i]
      assert_not_nil result, "Thread #{i} result missing"
      assert_equal 20, result[:breadcrumb_count], "Thread #{i} should have exactly 20 breadcrumbs"

      # Verify oldest breadcrumbs were removed (first 5 should be missing)
      assert_equal "thread-#{i}-breadcrumb-5", result[:first_breadcrumb]
      assert_equal "thread-#{i}-breadcrumb-24", result[:last_breadcrumb]
    end
  end

  test "scope nesting with concurrent access" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Test nested scopes in multiple threads
    threads = Array.new(8) do |i|
      Thread.new do
        # Set up initial scope
        @client.current_scope.tags["initial"] = "thread-#{i}"

        # Create nested scope
        @client.with_scope(tags: { "nested" => "level-1" }) do |scope1|
          scope1.tags["level1"] = "thread-#{i}-level1"

          # Create deeper nested scope
          @client.with_scope(tags: { "nested" => "level-2" }) do |scope2|
            scope2.tags["level2"] = "thread-#{i}-level2"

            # Capture nested scope state
            results["#{i}-nested"] = {
              tags: scope2.tags.dup,
              user: scope2.user.dup,
              extra: scope2.extra.dup
            }
          end

          # Capture level1 scope state after nested scope closed
          results["#{i}-level1"] = {
            tags: scope1.tags.dup,
            user: scope1.user.dup,
            extra: scope1.extra.dup
          }
        end

        # Capture final scope state after all nesting closed
        final_scope = @client.current_scope
        results["#{i}-final"] = {
          tags: final_scope.tags.dup,
          user: final_scope.user.dup,
          extra: final_scope.extra.dup
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify nested scopes worked correctly for each thread
    8.times do |i|
      # Check nested scope had all merged tags
      nested_result = results["#{i}-nested"]
      assert_not_nil nested_result
      expected_nested_tags = {
        "initial" => "thread-#{i}",
        "nested" => "level-2",
        "level1" => "thread-#{i}-level1",
        "level2" => "thread-#{i}-level2"
      }
      assert_equal expected_nested_tags, nested_result[:tags]

      # Check level1 scope after nested scope closed
      level1_result = results["#{i}-level1"]
      assert_not_nil level1_result
      expected_level1_tags = {
        "initial" => "thread-#{i}",
        "nested" => "level-1",
        "level1" => "thread-#{i}-level1"
      }
      assert_equal expected_level1_tags, level1_result[:tags]

      # Check final scope after all nesting closed
      final_result = results["#{i}-final"]
      assert_not_nil final_result
      expected_final_tags = { "initial" => "thread-#{i}" }
      assert_equal expected_final_tags, final_result[:tags]
    end
  end

  test "concurrent scope clearing" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create threads that build up scope data then clear it
    threads = Array.new(10) do |i|
      Thread.new do
        # Build up scope data
        5.times do |j|
          @client.add_breadcrumb("breadcrumb-#{j}", type: :custom)
        end
        @client.current_scope.tags["thread"] = i
        @client.current_scope.user["id"] = "user-#{i}"
        @client.current_scope.extra["data"] = "extra-#{i}"

        # Capture state before clearing
        scope = @client.current_scope
        results["#{i}-before"] = {
          breadcrumb_count: scope.breadcrumbs.length,
          tags: scope.tags.dup,
          user: scope.user.dup,
          extra: scope.extra.dup
        }

        # Clear the scope
        scope.clear

        # Capture state after clearing
        results["#{i}-after"] = {
          breadcrumb_count: scope.breadcrumbs.length,
          tags: scope.tags.dup,
          user: scope.user.dup,
          extra: scope.extra.dup
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify clearing worked correctly for each thread
    10.times do |i|
      # Check state before clearing
      before_result = results["#{i}-before"]
      assert_not_nil before_result
      assert_equal 5, before_result[:breadcrumb_count]
      assert_equal({ "thread" => i }, before_result[:tags])
      assert_equal({ "id" => "user-#{i}" }, before_result[:user])
      assert_equal({ "data" => "extra-#{i}" }, before_result[:extra])

      # Check state after clearing
      after_result = results["#{i}-after"]
      assert_not_nil after_result
      assert_equal 0, after_result[:breadcrumb_count]
      assert_equal({}, after_result[:tags])
      assert_equal({}, after_result[:user])
      assert_equal({}, after_result[:extra])
    end
  end

  test "concurrent context application" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create threads that apply contexts simultaneously
    threads = Array.new(12) do |i|
      Thread.new do
        scope = @client.current_scope

        # Apply multiple contexts rapidly
        5.times do |j|
          context = {
            tags: { "iteration" => j, "thread" => i },
            user: { "iteration" => j, "id" => "user-#{i}" },
            extra: { "iteration" => j, "data" => "thread-#{i}-data" }
          }
          scope.apply_context(context)
        end

        # Capture final state
        results[i] = {
          tags: scope.tags.dup,
          user: scope.user.dup,
          extra: scope.extra.dup
        }
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify final state for each thread
    12.times do |i|
      result = results[i]
      assert_not_nil result, "Thread #{i} result missing"

      # Last iteration should have won for each field
      expected_tags = { "iteration" => 4, "thread" => i }
      expected_user = { "iteration" => 4, "id" => "user-#{i}" }
      expected_extra = { "iteration" => 4, "data" => "thread-#{i}-data" }

      assert_equal expected_tags, result[:tags]
      assert_equal expected_user, result[:user]
      assert_equal expected_extra, result[:extra]
    end
  end

  test "scope behavior with exception capture" do
    results = Concurrent::Hash.new
    errors = Concurrent::Array.new

    # Create threads that capture exceptions with different scope states
    threads = Array.new(6) do |i|
      Thread.new do
        # Set up thread-specific scope
        @client.add_breadcrumb("setup-breadcrumb", type: :setup)
        @client.current_scope.tags["thread"] = i
        @client.current_scope.user["id"] = "user-#{i}"

        # Capture exception with scope context
        begin
          raise StandardError, "Test error from thread #{i}"
        rescue StandardError => e
          # This would normally send to adapters, but we'll just capture the context
          @client.with_scope(tags: { "error_context" => "thread-#{i}" }) do |scope|
            results[i] = {
              exception: e.message,
              breadcrumb_count: scope.breadcrumbs.length,
              tags: scope.tags.dup,
              user: scope.user.dup,
              extra: scope.extra.dup
            }
          end
        end
      rescue StandardError => e
        errors << { thread: i, error: e.message }
      end
    end

    threads.each(&:join)

    # Verify no errors occurred
    assert_empty errors, "Thread errors: #{errors.to_a.inspect}"

    # Verify exception capture worked correctly for each thread
    6.times do |i|
      result = results[i]
      assert_not_nil result, "Thread #{i} result missing"

      assert_equal "Test error from thread #{i}", result[:exception]
      assert_equal 1, result[:breadcrumb_count]

      # Check that scope context was properly merged
      expected_tags = { "thread" => i, "error_context" => "thread-#{i}" }
      assert_equal expected_tags, result[:tags]
      assert_equal({ "id" => "user-#{i}" }, result[:user])
    end
  end
end
