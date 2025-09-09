# Sampling Strategies

Lapsoss provides a simple sampling interface that allows you to control which errors are sent to your error tracking service. This helps manage costs and reduce noise in production environments.

## Built-in Samplers

### UniformSampler
Random sampling with a configurable rate (0.0 to 1.0):

```ruby
# In your initializer
Lapsoss.configure do |config|
  # Sample 50% of errors randomly
  config.sample_rate = 0.5
  
  # Or explicitly use UniformSampler
  config.sampling_strategy = Lapsoss::Sampling::UniformSampler.new(0.5)
end
```

### RateLimiter
Prevent overwhelming your error service with a maximum events per second:

```ruby
Lapsoss.configure do |config|
  # Maximum 10 errors per second
  config.sampling_strategy = Lapsoss::Sampling::RateLimiter.new(max_events_per_second: 10)
end
```

## Custom Sampling Strategies

You can implement your own sampling logic by creating a class with a `sample?` method:

### Time-Based Sampling
Sample differently based on time of day or day of week:

```ruby
class TimeBasedSampler < Lapsoss::Sampling::Base
  def initialize(business_hours: 0.3, after_hours: 0.8)
    @business_hours_rate = business_hours
    @after_hours_rate = after_hours
  end

  def sample?(_event, _hint = {})
    hour = Time.current.hour
    rate = (9..17).cover?(hour) ? @business_hours_rate : @after_hours_rate
    rate > rand
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = TimeBasedSampler.new(business_hours: 0.3, after_hours: 0.8)
end
```

### User-Based Sampling
Sample based on user attributes:

```ruby
class UserBasedSampler < Lapsoss::Sampling::Base
  def initialize(internal: 1.0, premium: 0.8, default: 0.1)
    @internal_rate = internal
    @premium_rate = premium
    @default_rate = default
  end

  def sample?(event, _hint = {})
    user = event.context[:user]
    return @default_rate > rand unless user

    rate = if user[:internal]
             @internal_rate
           elsif user[:premium]
             @premium_rate
           else
             @default_rate
           end
    
    rate > rand
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = UserBasedSampler.new
end
```

### Exception Type Sampling
Different sampling rates for different error types:

```ruby
class ExceptionTypeSampler < Lapsoss::Sampling::Base
  def initialize(rates = {})
    @rates = rates
    @default_rate = rates.fetch(:default, 1.0)
  end

  def sample?(event, _hint = {})
    return @default_rate > rand unless event.exception

    exception_name = event.exception.class.name
    rate = @rates.fetch(exception_name, @default_rate)
    rate > rand
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = ExceptionTypeSampler.new(
    'ActiveRecord::RecordNotFound' => 0.01,  # Sample 1% of 404s
    'Redis::TimeoutError' => 0.5,            # Sample 50% of Redis timeouts
    'NoMemoryError' => 1.0,                  # Always sample memory errors
    default: 0.1                             # Sample 10% of other errors
  )
end
```

### Health-Based Sampling
Adjust sampling based on application health:

```ruby
class HealthBasedSampler < Lapsoss::Sampling::Base
  def initialize(health_check:, healthy_rate: 0.1, unhealthy_rate: 1.0)
    @health_check = health_check
    @healthy_rate = healthy_rate
    @unhealthy_rate = unhealthy_rate
  end

  def sample?(event, hint = {})
    rate = @health_check.call ? @healthy_rate : @unhealthy_rate
    rate > rand
  end
end

Lapsoss.configure do |config|
  health_check = -> { Rails.cache.read('health_status') != 'degraded' }
  config.sampling_strategy = HealthBasedSampler.new(health_check: health_check)
end
```

### Composite Sampling
Combine multiple sampling strategies:

```ruby
class CompositeSampler < Lapsoss::Sampling::Base
  def initialize(samplers, strategy: :all)
    @samplers = samplers
    @strategy = strategy
  end

  def sample?(event, hint = {})
    case @strategy
    when :all
      @samplers.all? { |s| s.sample?(event, hint) }
    when :any
      @samplers.any? { |s| s.sample?(event, hint) }
    when :first
      @samplers.first&.sample?(event, hint) || true
    end
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = CompositeSampler.new(
    [
      Lapsoss::Sampling::RateLimiter.new(max_events_per_second: 50),
      ExceptionTypeSampler.new('ActiveRecord::RecordNotFound' => 0.01),
      TimeBasedSampler.new
    ],
    strategy: :all  # All samplers must agree to send the event
  )
end
```

## Using a Proc

For simple custom logic, you can use a Proc:

```ruby
Lapsoss.configure do |config|
  config.sampling_strategy = ->(event, hint) {
    # Skip all ActiveRecord::RecordNotFound errors
    return false if event.exception&.class&.name == 'ActiveRecord::RecordNotFound'
    
    # Sample 10% of everything else
    0.1 > rand
  }
end
```

## Adaptive Sampling

Dynamically adjust sampling rate based on volume:

```ruby
class AdaptiveSampler < Lapsoss::Sampling::Base
  def initialize(target_rate: 1.0, adjustment_period: 60)
    @target_rate = target_rate
    @adjustment_period = adjustment_period
    @current_rate = target_rate
    @events_count = 0
    @last_adjustment = Time.now
    @mutex = Mutex.new
  end

  def sample?(_event, _hint = {})
    @mutex.synchronize do
      @events_count += 1

      now = Time.now
      if now - @last_adjustment > @adjustment_period
        adjust_rate
        @last_adjustment = now
        @events_count = 0
      end
    end

    @current_rate > rand
  end

  private

  def adjust_rate
    if @events_count > 100  # High volume
      @current_rate = [@current_rate * 0.9, @target_rate * 0.1].max
    elsif @events_count < 10  # Low volume
      @current_rate = [@current_rate * 1.1, @target_rate].min
    end
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = AdaptiveSampler.new(target_rate: 0.5)
end
```

## Consistent Hash Sampling

Sample consistently based on a hash of event attributes (useful for debugging specific issues):

```ruby
class ConsistentHashSampler < Lapsoss::Sampling::Base
  def initialize(rate: 0.1, key: :fingerprint)
    @rate = rate
    @key = key
    @threshold = (rate * 0xFFFFFFFF).to_i
  end

  def sample?(event, _hint = {})
    value = event.send(@key) || event.message
    return @rate > rand unless value

    hash_value = Digest::MD5.hexdigest(value.to_s)[0, 8].to_i(16)
    hash_value <= @threshold
  end
end

Lapsoss.configure do |config|
  # Consistently sample 10% of errors based on their fingerprint
  config.sampling_strategy = ConsistentHashSampler.new(rate: 0.1)
end
```

## Testing Sampling

In your tests, you might want to disable sampling:

```ruby
# In test environment
Lapsoss.configure do |config|
  config.sample_rate = 1.0  # Always sample in tests
  
  # Or use a test-specific sampler
  config.sampling_strategy = ->(event, hint) { true }
end
```

## Best Practices

1. **Start Conservative**: Begin with lower sampling rates and increase as needed
2. **Monitor Impact**: Track how sampling affects your error visibility
3. **Critical Errors**: Always sample critical errors (security, data loss, etc.)
4. **Gradual Rollout**: Test new sampling strategies in staging first
5. **Document Decisions**: Comment why specific rates were chosen

## Performance Considerations

- Sampling decisions should be fast (< 1ms)
- Avoid database queries or network calls in samplers
- Use caching for expensive computations
- Consider thread safety for stateful samplers

## Debugging Sampling

To debug why events are being sampled or not:

```ruby
class DebugSampler < Lapsoss::Sampling::Base
  def initialize(wrapped_sampler, logger: Rails.logger)
    @sampler = wrapped_sampler
    @logger = logger
  end

  def sample?(event, hint = {})
    result = @sampler.sample?(event, hint)
    @logger.debug "Sampling decision: #{result} for #{event.exception&.class}"
    result
  end
end

Lapsoss.configure do |config|
  config.sampling_strategy = DebugSampler.new(
    Lapsoss::Sampling::UniformSampler.new(0.5)
  )
end
```