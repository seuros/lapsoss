# Community TODO - Help Wanted! 🚀

We need your help to make Lapsoss support more error tracking services! If you have experience with any of these services, please consider contributing an adapter.

## Missing Adapters - Community Help Needed

### High Priority Services

**Airbrake** - Popular error tracking service
- [ ] Create `Lapsoss::Adapters::AirbrakeAdapter`
- [ ] Support for error grouping and context
- [ ] Documentation and examples
- Looking for someone with Airbrake experience!

**Honeybadger** - Developer-focused error tracking
- [ ] Create `Lapsoss::Adapters::HoneybadgerAdapter`  
- [ ] Support for deployment tracking
- [ ] Context and breadcrumb support
- Looking for someone with Honeybadger experience!

**Raygun** - Application monitoring platform
- [ ] Create `Lapsoss::Adapters::RaygunAdapter`
- [ ] Error tracking with user context
- [ ] Performance monitoring integration (optional)
- Looking for someone with Raygun experience!


**AWS X-Ray** - AWS distributed tracing and error tracking
- [ ] Create `Lapsoss::Adapters::XRayAdapter`
- [ ] Error tracking with distributed tracing context
- [ ] AWS service integration (Lambda, ECS, etc.)
- [ ] Segment and annotation support
- Looking for someone with AWS X-Ray experience!

### Medium Priority Services



**New Relic** - Application performance monitoring with error tracking
- [ ] Create `Lapsoss::Adapters::NewRelicAdapter`
- [ ] Error tracking with APM context
- [ ] Custom attributes and events
- Looking for someone with New Relic experience!

**DataDog** - Infrastructure monitoring with error tracking
- [ ] Create `Lapsoss::Adapters::DataDogAdapter`
- [ ] Error tracking with logs and metrics correlation
- [ ] Custom tags and service mapping
- Looking for someone with DataDog experience!

## How to Contribute an Adapter

### 1. Check Existing Patterns

Look at existing adapters for reference:
- `lib/lapsoss/adapters/sentry_adapter.rb` - HTTP-based with JSON
- `lib/lapsoss/adapters/rollbar_adapter.rb` - Custom API integration
- `lib/lapsoss/adapters/appsignal_adapter.rb` - Service with authentication

### 2. Adapter Structure

```ruby
# lib/lapsoss/adapters/your_service_adapter.rb
module Lapsoss
  module Adapters
    class YourServiceAdapter < Base
      def initialize(name = :your_service, settings = {})
        super(name, settings)
        @api_key = settings[:api_key]
        @endpoint = settings[:endpoint] || "https://api.yourservice.com"
        # ... other initialization
      end

      def capture(event)
        # Transform Lapsoss event to your service's format
        payload = build_payload(event)
        
        # Send to your service
        send_to_service(payload)
      rescue => e
        handle_delivery_error(e)
        false
      end

      private

      def build_payload(event)
        # Transform the event to your service's expected format
        # See event.rb for available fields
      end

      def send_to_service(payload)
        # HTTP request or SDK call to your service
      end
    end
  end
end
```

### 3. Configuration Helper

```ruby
# lib/lapsoss/configuration.rb (add method)
def use_your_service(name: :your_service, **settings)
  adapter = Adapters::YourServiceAdapter.new(name, settings)
  Registry.instance.register_adapter(adapter)
end
```

### 4. Tests

Create comprehensive tests:
- `test/your_service_adapter_test.rb`
- Test error handling, network failures, invalid responses
- Use VCR for HTTP interactions
- Test with both sync and async modes

### 5. Documentation

- Add examples to README.md
- Document configuration options
- Include any special setup requirements

## What We Provide

- **Event Structure**: Rich event objects with exception, context, breadcrumbs, user data
- **HTTP Client**: Built-in HTTP client with retries and timeout handling
- **Testing Framework**: VCR integration for reliable HTTP tests
- **Configuration System**: Consistent configuration patterns
- **Error Handling**: Standard error handling and logging patterns

## Adapter Requirements

### Must Have
- [ ] Inherit from `Lapsoss::Adapters::Base`
- [ ] Handle network failures gracefully
- [ ] Support both sync and async modes
- [ ] Include comprehensive tests
- [ ] Support standard event fields (exception, message, context, user, breadcrumbs)

### Nice to Have
- [ ] Custom fingerprinting support
- [ ] Service-specific features (deployments, releases, etc.)
- [ ] Advanced error grouping
- [ ] Performance monitoring integration

## Getting Started

1. **Fork the repository**
2. **Pick a service you use** - You'll need an account to test with
3. **Study their API documentation** - Understand their error submission format
4. **Look at existing adapters** - Use them as templates
5. **Start with basic error capture** - Get the fundamentals working first
6. **Add tests and documentation** - Make it production-ready
7. **Submit a pull request** - We'll help review and refine

## Questions?

- Open an issue with the "adapter-request" label
- Tag `@seuros` for questions about adapter architecture
- Check existing adapters for patterns and examples

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Credited in the adapter file
- Mentioned in release notes
- Added to the README as a maintainer of that adapter

Let's make Lapsoss the ultimate vendor-neutral error tracking solution! 🎯

---

**Current Maintainer**: @seuros  
**Looking for Co-maintainers**: Especially for services we don't personally use