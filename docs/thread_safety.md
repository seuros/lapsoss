# Thread Safety in Lapsoss

This document describes the thread safety guarantees and considerations when using Lapsoss in multi-threaded environments.

## Overview

Lapsoss is designed to be thread-safe and can be used safely in multi-threaded applications including web servers, background job processors, and concurrent Ruby applications.

## Thread Safety Guarantees

### Scope Management

**Thread-Local Isolation**: Each thread maintains its own isolated scope using Ruby's thread-local storage (`Thread.current[:lapsoss_scope]`). This ensures that:

- Breadcrumbs added in one thread don't affect other threads
- Tags, user context, and extra data are isolated per thread
- Scope nesting works correctly within each thread without cross-thread interference

```ruby
# Thread A
Lapsoss.add_breadcrumb("User logged in", type: :user)
Lapsoss.current_scope.tags["user_id"] = 123

# Thread B (completely isolated)
Lapsoss.add_breadcrumb("Processing payment", type: :transaction)
Lapsoss.current_scope.tags["transaction_id"] = 456
```

**Scope Nesting**: The `with_scope` method creates properly isolated nested scopes that:

- Inherit context from the parent scope
- Allow local modifications without affecting the parent
- Restore the original scope when the block exits

```ruby
# Safe in multi-threaded environments
Lapsoss.current_scope.tags["global"] = "value"

Lapsoss.with_scope(tags: { "local" => "nested" }) do
  # This scope inherits "global" and adds "local"
  Lapsoss.capture_exception(exception)
end
# Original scope is restored
```

### HTTP Client Thread Safety

**Faraday-Based HTTP Client**: Lapsoss uses Faraday with built-in retry middleware for HTTP communication. Faraday provides thread-safe connection management:

```ruby
# Thread-safe Faraday connection
def build_connection
  Faraday.new(@base_url) do |conn|
    conn.request :retry, retry_options
    conn.options.timeout = @config[:timeout] || 5
    # Faraday handles connection pooling and thread safety internally
  end
end
```

**Built-in Safety**: Faraday's connection pooling and adapter system provides thread safety without requiring explicit mutex synchronization. Each HTTP request is handled independently with proper connection management.

### Registry and Adapter Management

**Adapter Registration**: The adapter registry uses mutex synchronization for thread-safe adapter registration and lookup:

```ruby
# Thread-safe adapter management
@mutex = Mutex.new

def register(name, type, **settings)
  @mutex.synchronize do
    # Safe registration logic
  end
end
```

## Usage Patterns

### Web Applications

Lapsoss is safe to use in web applications where each request is handled by a separate thread:

```ruby
# Each request thread has isolated scope
class ApplicationController < ActionController::Base
  before_action :set_user_context
  
  private
  
  def set_user_context
    Lapsoss.current_scope.user = {
      id: current_user.id,
      email: current_user.email
    }
  end
end
```

### Background Jobs

Background job processors can safely use Lapsoss with proper scoping:

```ruby
class ProcessPaymentJob
  def perform(payment_id)
    Lapsoss.with_scope(tags: { job: "process_payment", payment_id: payment_id }) do
      # Job processing logic
      # Any exceptions will include the job context
    end
  end
end
```

### Concurrent Processing

When processing items concurrently, each thread maintains its own scope:

```ruby
# Safe concurrent processing
items.each_with_index do |item, index|
  Thread.new do
    Lapsoss.with_scope(tags: { item_id: item.id, thread_index: index }) do
      begin
        process_item(item)
      rescue => e
        Lapsoss.capture_exception(e)
      end
    end
  end
end
```

## Performance Considerations

### Minimal Locking

Lapsoss uses minimal locking to ensure thread safety:

- **Scope access**: Thread-local storage requires no locking
- **HTTP connections**: Faraday handles connection pooling and thread safety internally
- **Registry operations**: Single global mutex for registration only

### Async Processing

When `async: true` is configured, event processing happens in background threads:

```ruby
Lapsoss.configure do |config|
  config.async = true  # Events processed in background thread pool
end
```

## Testing Thread Safety

Lapsoss includes comprehensive thread safety tests in `test/test_scope_thread_safety.rb` that verify:

- Scope isolation between threads
- Concurrent breadcrumb addition
- Breadcrumb size limiting under concurrent access
- Scope nesting with concurrent access
- Concurrent scope clearing
- Concurrent context application
- Exception capture with scope context

These tests use multiple threads performing concurrent operations to verify thread safety guarantees.

## Best Practices

### 1. Use Scoped Context

Always use scoped context for request-specific or job-specific data:

```ruby
# Good: Scoped context
Lapsoss.with_scope(tags: { request_id: request.id }) do
  # Request processing
end

# Avoid: Global scope modification
Lapsoss.current_scope.tags["request_id"] = request.id
```

### 2. Avoid Shared State

Don't share scope objects between threads:

```ruby
# Bad: Sharing scope between threads
scope = Lapsoss.current_scope
threads = items.map do |item|
  Thread.new do
    scope.tags["item"] = item.id  # Race condition!
  end
end

# Good: Each thread has its own scope
threads = items.map do |item|
  Thread.new do
    Lapsoss.with_scope(tags: { item_id: item.id }) do
      # Thread-safe processing
    end
  end
end
```

### 3. Proper Exception Handling

Ensure exceptions are captured within the appropriate scope:

```ruby
# Good: Exception captured with proper scope context
Lapsoss.with_scope(tags: { operation: "user_creation" }) do
  begin
    create_user(params)
  rescue => e
    Lapsoss.capture_exception(e)  # Includes operation context
  end
end
```

### 4. Configure Appropriate Thread Pool Size

When using async processing, configure the thread pool size based on your application's needs:

```ruby
Lapsoss.configure do |config|
  config.async = true
  # Thread pool size is automatically managed
end
```

## Memory Management

### Thread-Local Storage Cleanup

Thread-local storage is automatically cleaned up when threads exit. For long-running threads, you may want to periodically clear scope data:

```ruby
# In long-running background threads
loop do
  Lapsoss.current_scope.clear  # Clear accumulated data
  # Process next batch
end
```

### Breadcrumb Limiting

Breadcrumbs are automatically limited to 20 entries per scope to prevent memory leaks:

```ruby
# Automatic breadcrumb limiting
100.times do |i|
  Lapsoss.add_breadcrumb("Operation #{i}")
end
# Only the last 20 breadcrumbs are kept
```

## Debugging Thread Safety Issues

If you encounter thread safety issues:

1. **Enable debug logging**: Set `config.debug = true` to see detailed operation logs
2. **Use synchronous mode**: Set `config.async = false` for easier debugging
3. **Check scope isolation**: Verify that each thread has its own scope context
4. **Monitor memory usage**: Watch for memory leaks in long-running threads

## Conclusion

Lapsoss provides robust thread safety guarantees through:

- Thread-local scope isolation
- Minimal, strategic use of mutexes
- Comprehensive testing
- Clear usage patterns and best practices

By following the guidelines in this document, you can safely use Lapsoss in any multi-threaded Ruby application.