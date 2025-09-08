# Backtrace Processing

Lapsoss provides advanced backtrace processing capabilities that enhance error reports across all supported error tracking services. This document covers the configuration options and features available for backtrace processing.

## Overview

The backtrace processor provides:

- **Consistent Processing**: Unified backtrace handling across all adapters (Sentry, Rollbar, Bugsnag/Insight Hub, etc.)
- **Code Context Extraction**: Include source code snippets around error locations
- **Smart Filtering**: Remove noise from framework internals and focus on application code
- **Performance Optimization**: File caching and efficient frame processing
- **Flexible Configuration**: Extensive options to customize processing behavior

## Configuration

### Basic Configuration

```ruby
Lapsoss.configure do |config|
  # Number of context lines to include (before and after)
  config.backtrace_context_lines = 3
  
  # Strip Ruby load paths for cleaner filenames
  config.backtrace_strip_load_path = true
  
  # Maximum frames to process (prevents memory issues)
  config.backtrace_max_frames = 100
  
  # Enable code context extraction
  config.backtrace_enable_code_context = true
end
```

### Advanced Configuration

#### In-App Detection

Identify which code belongs to your application vs third-party libraries:

```ruby
config.backtrace_in_app_patterns = [
  %r{^/app/},              # Rails app directory
  %r{^app/},               # Relative app paths
  %r{^lib/},               # Custom lib directory
  %r{/my_company/}         # Company-specific code
]
```

#### Filtering Patterns

Exclude noisy framework internals from backtraces:

```ruby
config.backtrace_exclude_patterns = [
  %r{/ruby/gems/.*/rack-},                    # Rack internals
  %r{/activesupport-.*/notifications},        # AS notifications
  %r{/ruby/\d+\.\d+\.\d+/.*/monitor\.rb},    # Ruby monitor
  %r{/newrelic_rpm/},                         # Monitoring gems
]
```

## Features

### Code Context

When enabled, the processor extracts source code context around each frame:

```ruby
# Given an error at line 42:
{
  pre_context: [
    "39: def process_payment(amount)",
    "40:   validate_amount(amount)",
    "41:   "
  ],
  context_line: "42:   charge_card(amount)",
  post_context: [
    "43:   send_receipt",
    "44: end",
    "45:"
  ]
}
```

### Frame Information

Each processed frame includes:

- `filename`: The file path (normalized based on configuration)
- `lineno`: Line number where the error occurred
- `method`: Method name or `<main>` for top-level code
- `in_app`: Boolean indicating if this is application code
- `pre_context`: Lines before the error (if context enabled)
- `context_line`: The exact line with the error
- `post_context`: Lines after the error

### Performance Features

#### File Caching

The processor uses an LRU (Least Recently Used) cache for file reads:

- Default cache size: 50 files
- Default TTL: 5 minutes
- Thread-safe implementation
- Automatic cache eviction

#### Frame Limiting

For very deep stack traces (e.g., stack overflow errors):

```ruby
config.backtrace_max_frames = 50  # Limit to 50 frames
```

When limited, the processor prioritizes frames intelligently:
- **App frames first**: All application code frames are preserved when possible
- **Recent frames prioritized**: If app frames exceed the limit, the most recent ones are kept
- **Context preservation**: Some library frames are included for debugging context

The algorithm works as follows:
1. If total frames ≤ max_frames: all frames are kept
2. If app frames ≥ max_frames: only the first (most recent) max_frames app frames are kept
3. Otherwise: all app frames + remaining slots filled with library frames from the top

### Multi-Format Support

The processor can format frames for different services:

```ruby
processor = Lapsoss::BacktraceProcessor.new

# Process the backtrace
frames = processor.process(exception.backtrace)

# Format for specific adapters
sentry_frames = processor.format_frames(frames, :sentry)
rollbar_frames = processor.format_frames(frames, :rollbar)
bugsnag_frames = processor.format_frames(frames, :bugsnag)
```

## Direct Usage

While the backtrace processor is automatically used by adapters, you can also use it directly:

```ruby
# Create a processor instance
processor = Lapsoss::BacktraceProcessor.new

# Process an exception
frames = processor.process_exception(exception)

# Process with options
frames = processor.process_exception(exception, 
  follow_cause: true,    # Follow exception cause chain
  skip_context: false    # Include code context
)

# Access frame details
frames.each do |frame|
  puts "#{frame.filename}:#{frame.lineno} in #{frame.method}"
  puts "  Application code: #{frame.in_app}"
  
  if frame.has_context?
    puts "  Context: #{frame.context_line}"
  end
end
```

## Performance Considerations

1. **Code Context Impact**: Extracting code context requires file I/O. Disable for better performance:
   ```ruby
   config.backtrace_enable_code_context = false
   ```

2. **Large Backtraces**: Deep recursion can create huge backtraces. Use frame limiting:
   ```ruby
   config.backtrace_max_frames = 50
   ```

3. **Filtering**: Exclude patterns are applied during processing. More patterns = more processing time.

4. **Cache Tuning**: Adjust cache size based on your application:
   ```ruby
   # In initializer or custom code
   cache = Lapsoss::FileCache.new(
     max_size: 100,  # More files cached
     ttl: 600        # 10 minute TTL
   )
   ```

## Adapter-Specific Notes

### Sentry
- Frames are reversed (most recent first)
- Uses `function` key instead of `method`
- Supports full code context

### Rollbar
- Frames are reversed (most recent first)
- Code context uses different format
- Supports exception cause chains

### Bugsnag/Insight Hub
- Uses camelCase keys (`lineNumber`, `inProject`)
- Single string for code context
- Automatic in-project detection

## Examples

### Rails Configuration

```ruby
# config/initializers/lapsoss.rb
Lapsoss.configure do |config|
  # Rails-specific patterns
  config.backtrace_in_app_patterns = [
    %r{^/app/},
    %r{^/lib/},
    Rails.root.to_s
  ]
  
  # Exclude Rails internals
  config.backtrace_exclude_patterns = [
    %r{/actionpack-},
    %r{/activerecord-},
    %r{/activesupport-},
    %r{/railties-}
  ]
  
  # Production optimizations
  if Rails.env.production?
    config.backtrace_context_lines = 0  # Disable for performance
    config.backtrace_max_frames = 30    # Limit frames
  end
end
```

### Custom Error Handler

```ruby
class ApplicationController < ActionController::Base
  rescue_from StandardError do |exception|
    # Process backtrace with custom options
    processor = Lapsoss::BacktraceProcessor.new
    frames = processor.process_exception(exception, follow_cause: true)
    
    # Log application frames only
    app_frames = frames.select(&:application_frame?)
    Rails.logger.error "Error in application code:"
    app_frames.each do |frame|
      Rails.logger.error "  #{frame}"
    end
    
    # Send to error tracking
    Lapsoss.capture_exception(exception)
    
    # Render error page
    render_error_page
  end
end
```

## Troubleshooting

### Missing Code Context

If code context is not appearing:

1. Verify files exist and are readable
2. Check `backtrace_enable_code_context` is true
3. Ensure `backtrace_context_lines` > 0
4. Check file permissions

### Performance Issues

If backtrace processing is slow:

1. Reduce `backtrace_context_lines` or disable context
2. Add more `backtrace_exclude_patterns`
3. Lower `backtrace_max_frames`
4. Monitor file cache hit rate

### Incorrect In-App Detection

If frames are incorrectly marked as library code:

1. Add custom `backtrace_in_app_patterns`
2. Check Bundler/Gem path detection
3. Use absolute paths in patterns