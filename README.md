# Lapsoss - Vendor-Neutral Error Reporting for Rails

## The Problem We All Face

You're 6 months into production with Bugsnag. The CFO says "costs are too high, switch to Sentry."

The migration estimate? 3 months. Why? Because your entire codebase is littered with:
- `Bugsnag.notify(exception)`
- `Bugsnag.leave_breadcrumb("User clicked checkout")`
- Bugsnag-specific configuration
- Custom Bugsnag metadata patterns

**This is vendor lock-in through API pollution.**

## The Solution: Write Once, Deploy Anywhere

```ruby
# Your code never changes:
Lapsoss.capture_exception(e)

# Switch vendors in config, not code:
Lapsoss.configure do |config|
  # Monday: Using Bugsnag
  config.use_bugsnag(api_key: ENV['BUGSNAG_KEY'])

  # Tuesday: Add Sentry for comparison
  config.use_sentry(dsn: ENV['SENTRY_DSN'])

  # Wednesday: Drop Bugsnag, keep Sentry
  # Just remove the line. Zero code changes.
end
```

## Requirements

- Ruby 3.3+
- Rails 7.2+

## Installation

```ruby
gem 'lapsoss'
```

## Usage

```ruby
# Capture exceptions
Lapsoss.capture_exception(e)

# Capture messages
Lapsoss.capture_message("Payment processed", level: :info)

# Add context
Lapsoss.with_scope(user_id: current_user.id) do
  process_payment
end

# Add breadcrumbs
Lapsoss.add_breadcrumb("User clicked checkout", type: :navigation)
```

That's it. No 500-line examples needed.

## Built for Rails, Not Around It

Lapsoss integrates with Rails' native error reporting API introduced in Rails 7. No monkey-patching, no middleware gymnastics:

```ruby
# It just works with Rails.error:
Rails.error.handle(context: {user_id: current_user.id}) do
  risky_operation
end
# Automatically captured by whatever service you configured
```

## Zero-Downtime Vendor Migration

```ruby
# Step 1: Add Lapsoss alongside your current setup
gem 'lapsoss'
gem 'bugsnag' # Keep your existing gem for now

# Step 2: Configure dual reporting
Lapsoss.configure do |config|
  config.use_bugsnag(api_key: ENV['BUGSNAG_KEY'])
  config.use_sentry(dsn: ENV['SENTRY_DSN'])
end

# Step 3: Gradually replace Bugsnag calls
# Old: Bugsnag.notify(e)
# New: Lapsoss.capture_exception(e)

# Step 4: Remove bugsnag gem when ready
# Your app keeps running, now on Sentry
```

## Why Not Just Use Vendor SDKs?

**Vendor SDKs monkey-patch your application:**
- Sentry patches Net::HTTP, Redis, and 20+ other gems
- Each vendor races to patch the same methods
- Multiple SDKs = multiple layers of patches
- Your app behavior changes based on load order

**Lapsoss doesn't patch anything:**
- Pure Ruby implementation
- Uses Rails' error API
- Your app behavior remains unchanged
- No competing instrumentation

## Real-World Use Cases

### GDPR Compliance
```ruby
# Route EU data to EU servers, US data to US servers
config.use_sentry(name: :us, dsn: ENV['US_DSN'])
config.use_sentry(name: :eu, dsn: ENV['EU_DSN'])
```

### A/B Testing Error Services
```ruby
# Run both services, compare effectiveness
config.use_rollbar(name: :current, access_token: ENV['ROLLBAR_TOKEN'])
config.use_sentry(name: :candidate, dsn: ENV['SENTRY_DSN'])
```

### High Availability
```ruby
# Multiple providers for redundancy
config.use_sentry(name: :primary, dsn: ENV['PRIMARY_DSN'])
config.use_rollbar(name: :backup, access_token: ENV['BACKUP_TOKEN'])
```

## Yes, We Require ActiveSupport

This is a Rails gem for Rails applications. We use ActiveSupport because:
- You already have it (you're using Rails)
- It provides the exact utilities we need
- It's better than reimplementing Rails patterns poorly

If you need pure Ruby error tracking, use the vendor SDKs directly for now.

## Who This Is For

- Teams that have been burned by vendor lock-in
- Apps that need regional data compliance (GDPR)
- Developers who value clean, maintainable code
- Rails applications that embrace change

## Who This Is NOT For

- Pure Ruby libraries (use vendor SDKs)
- Teams happy with their current vendor forever
- Applications that need APM features
- Non-Rails applications

## Supported Adapters

All adapters are pure Ruby implementations with no external SDK dependencies:

- **Sentry** - Full error tracking support
- **Rollbar** - Complete error tracking with grouping
- **AppSignal** - Error tracking and deploy markers
- **Insight Hub** (formerly Bugsnag) - Error tracking with breadcrumbs

## Configuration

### Basic Setup

```ruby
# config/initializers/lapsoss.rb
Lapsoss.configure do |config|
  config.use_sentry(dsn: ENV["SENTRY_DSN"])
end
```

### Multi-Adapter Setup

```ruby
Lapsoss.configure do |config|
  # Named adapters for different purposes
  config.use_sentry(name: :errors, dsn: ENV['SENTRY_DSN'])
  config.use_rollbar(name: :business_events, access_token: ENV['ROLLBAR_TOKEN'])
  config.use_logger(name: :local_backup) # Local file backup
end
```

### Advanced Configuration

```ruby
Lapsoss.configure do |config|
  # Adapter setup
  config.use_sentry(dsn: ENV['SENTRY_DSN'])

  # Data scrubbing (uses Rails filter_parameters automatically)
  config.scrub_fields = %w[password credit_card ssn] # Or leave nil to use Rails defaults

  # Error filtering
  config.before_send = lambda do |event|
    # Return nil to prevent sending
    return nil if event.exception.is_a?(ActiveRecord::RecordNotFound)
    event
  end

  # Sampling
  config.sample_rate = Rails.env.production? ? 0.25 : 1.0

  # Performance
  config.async = true # Send errors in background
  config.transport_timeout = 10 # seconds
  config.transport_max_retries = 3
end
```

### Data Protection

Lapsoss automatically integrates with Rails' parameter filtering:

```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += [:password, :token]

# Lapsoss automatically uses these filters - no additional configuration needed!
```

### Custom Fingerprinting

Control how errors are grouped:

```ruby
config.fingerprint_callback = lambda do |event|
  case event.exception&.class&.name
  when "ActiveRecord::RecordNotFound"
    "record-not-found" # Group all together
  when "Stripe::CardError"
    "payment-failure"
  else
    nil # Use default fingerprinting
  end
end
```

### Transport Reliability

Built-in retry logic with exponential backoff:

```ruby
config.transport_max_retries = 3
config.transport_timeout = 10
config.transport_jitter = true # Prevent thundering herd
```

## Creating Custom Adapters

```ruby
class MyAdapter < Lapsoss::Adapters::Base
  def capture(event)
    # Send to your service
    HttpClient.post("/errors", event.to_h)
  end
end

Lapsoss::Registry.register(:my_service, MyAdapter)
```

## Contributing

1. Fork it
2. Create your feature branch
3. Add tests for your changes
4. Submit a pull request

## License

MIT License - Because good code should be free

---

Built for Rails developers who refuse to be locked in.
