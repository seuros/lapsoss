# The SDK Bloat Story: Why Lapsoss Exists

## The Problem: Feature Creep in Error Tracking SDKs

Modern error tracking SDKs have evolved far beyond their original purpose. What started as simple error reporting tools have become massive, all-encompassing monitoring platforms. This research examines the last 10 releases of major Ruby error tracking SDKs to prove this point.

## The Evidence: What's Actually Being Added


**Security Features Nobody Asked For:**
- SQL injection detection auto-patching
- SSRF (Server-Side Request Forgery) detection for HTTP clients
- API Security monitoring (now enabled BY DEFAULT!)
- Attacker fingerprinting for authentication systems

**Performance Overhead Features:**
- Heap profiling (requires significant memory overhead)
- GVL profiling (enabled by default on Ruby 3.2+)
- Runtime metrics correlation

- 5+ security monitoring features (premium tier)
- 3+ profiling features (performance overhead)
- Multiple new integrations (Karafka, OpenSearch)

### 🟢 Sentry (5 releases: v5.21.0 - v5.26.0)

**Feature Bloat:**
- Structured logging system (duplicates existing logging gems)
- Multi-threaded profiling with Vernier
- Cache instrumentation
- Queue instrumentation with "detailed metrics"

**The Proof:** Recent Sentry updates focused on:
- Building their own logging system (why?)
- Adding profiling (premium feature)
- Re-instrumenting things Rails already instruments

**The Double Instrumentation Absurdity:**
It's like the IRS asking you to file your tax return when they already know exactly how much you owe them. Rails already provides ActiveSupport::Notifications for everything, but these SDKs ignore it and add their own instrumentation on top of instrumentation.

**The Recursive Monitoring Nightmare:**
What happens when a junior developer accidentally installs multiple error tracking gems?

```ruby
# Gemfile disaster waiting to happen
gem 'sentry-ruby'
gem 'appsignal'
gem 'airbrake'
```

Instead of all listening to the same Rails data stream, each SDK:
- Monkey-patches the same methods
- Instruments the other SDKs' instrumentation
- Creates a recursive loop of monitoring

**The Reality:**
```ruby
# What you think happens:
Rails → Instrumentation → Error Tracker

# What actually happens (gems load alphabetically!):
Rails → Rails Instrumentation
  ↓
  ├→ Airbrake loads first, patches everything
  ├→ AppSignal loads second, patches Airbrake's patches
  ├→ Bugsnag loads third, patches both above
  └→ Sentry loads last, RULES THEM ALL (patches everyone's patches)

# Result: Sentry wins by alphabetical order!
# The last to load becomes the outer wrapper
# Everyone else is trapped inside Sentry's instrumentation
# Sentry is now monitoring all the other monitors...
```

**The Middleware Passport Control Hell:**
Your simple HTTP request now has to pass through multiple passport controls:

```ruby
# Making a simple API call with multiple SDKs installed:
HTTP.get("https://api.example.com/users")
  ↓
  Airbrake Faraday Middleware (Passport Control #1)
  ↓
  AppSignal Faraday Middleware (Passport Control #2)
  ↓
  Bugsnag Faraday Middleware (Passport Control #3)
  ↓
  ↓
  Sentry Faraday Middleware (Final Passport Control)
  ↓
  Your actual HTTP request finally happens
  ↓
  Response comes back through ALL 5 checkpoints again!
```

Each SDK adds its own middleware to the stack. It's like traveling through 5 different countries just to make one API call - each one checking your papers, stamping your passport, and adding their own "telemetry data."

Instead of cooperating and listening to Rails' existing event stream, they're all fighting to patch the same methods, potentially instrumenting each other's instrumentation code. It's a circus of redundancy where your request needs 5 different visas just to leave the country.

### 🟠 AppSignal (10 releases: v4.5.8 - v4.5.17)

**Incremental Complexity:**
- NGINX metrics server configuration
- Active Job queue time metrics
- "Enhanced debug logging for ignored errors"

**The Proof:** Even AppSignal's modest updates show the pattern:
- Metrics that require additional infrastructure (NGINX)
- Queue monitoring (overlap with APM tools)
- Debug features that increase log volume

### ⚪ Airbrake (sparse releases over 2+ years)

**The Exception That Proves the Rule:**
- Minimal updates
- Focus on compatibility
- Result: Losing market share to feature-rich competitors

## The Real Cost of This Bloat

### 0. **The Size Problem**
Let's start with the actual gem sizes (unpacked):

**Unpacked library sizes:**
- **AppSignal**: 1.2MB
- **Sentry**: 556K (and growing with each release)
- **Bugsnag**: 396K
- **Airbrake**: 208K (staying lean but losing market share)
- **Lapsoss**: 256KB (what error tracking should be!)

But here's the real kicker: **Lapsoss includes adapters for ALL of them!** You get Sentry, AppSignal, Rollbar, and Insight Hub support in one 256KB package - versus installing each vendor's individual SDK.


### 1. **Forced Premium Features**
```ruby
# What you want:
Sentry.capture_exception(error)

# What you get:
- API Security monitoring running on EVERY request
- Heap profiling consuming memory
- SQL injection detection patching ActiveRecord
- Attacker fingerprinting tracking your users
```

### 2. **Update Fatigue**
Look at the release frequency:
- **Sentry**: 5 releases in 8 months
- **AppSignal**: 10 releases in 3 months

Each update brings:
- New features you didn't ask for
- Potential breaking changes
- Security patches for features you don't use
- Increased bundle size

### 3. **The Subscription Trap**
These "features" often require paid tiers:
- Sentry's profiling: Business tier
- AppSignal's custom metrics: Higher plans

You're downloading code for features you can't even use without paying more!

### 4. **Performance Impact**
> "GVL profiling enabled by default on Ruby 3.2+"

Translation: They're now profiling your app by default, consuming CPU cycles for a feature you probably don't need.

### 5. **Dependency Hell**
Modern SDK dependencies:
```ruby
# Sentry requires:
- concurrent-ruby
- faraday
- sawyer
- various patches and integrations

- msgpack
- debase-ruby_core_source
- numerous native extensions
```

## The Lapsoss Alternative: Universal Adapter Architecture

Instead of 5MB+ SDKs with features for every possible use case, Lapsoss provides a **universal adapter architecture**:

### The Real Innovation: One Interface, All Vendors

```ruby
# Instead of this vendor lock-in nightmare:
gem 'sentry-ruby'    # 556KB for one vendor
gem 'appsignal'      # 1.2MB for another vendor

# You get this:
gem 'lapsoss'        # 256KB with adapters for ALL vendors!

# Same API, switch vendors instantly:
Lapsoss.configure do |config|
  config.use_sentry(dsn: ENV['SENTRY_DSN'])
  config.use_appsignal(api_key: ENV['APPSIGNAL_KEY'])
end
```

### The OSS Standard Vision

**If the industry adopted an open standard for error tracking protocols**, we could strip down all vendor SDKs to essentially one unified interface:

```ruby
# The future with an OSS standard:
gem 'error-tracking-standard'  # ~100KB universal protocol
gem 'sentry-adapter'           # ~5KB vendor-specific transport
gem 'appsignal-adapter'        # ~5KB vendor-specific transport

# Total: ~115KB vs current 6.7MB+ for all three vendors!
```

Vendors could focus on their **value-added services** (dashboards, alerting, analytics) while the community maintains a **standardized, bloat-free error reporting layer**.

Instead of 50MB+ SDKs with features for every possible use case, Lapsoss provides:

```ruby
# What you actually need:
- Exception capture ✓
- Context/user data ✓
- Breadcrumbs ✓
- Clean HTTP transport ✓

# What you DON'T get:
- SQL injection detection you didn't enable
- Profilers running by default
- Security monitoring you're not paying for
- 47 different integrations
```

## The Verdict

The evidence is clear: Modern error tracking SDKs have abandoned their core mission. They've become:

1. **Marketing vehicles** for premium features
2. **Resource hogs** with default-enabled profiling
3. **Security risks** with overly broad instrumentation
4. **Update nightmares** with constant feature additions

**Every update notification is a reminder**: You're maintaining code for features designed to upsell you, not serve your actual needs.

## Why This Matters

When your error tracking SDK:
- Updates 10 times in 3 months
- Adds "API Security by default"
- Includes heap profiling "improvements"
- Patches SQL injection detection

Ask yourself: **Is this still an error tracker, or is it malware with good intentions?**

## The Lapsoss Solution: Back to Basics

**Lapsoss is NOT here to replace these vendors.** We're here to offer what they abandoned: simple, focused error tracking.

### The Truth About the Industry

These companies realized a hard truth: **Error tracking alone is not a profitable business.** So they pivoted:
- Sentry → Full observability platform
- AppSignal → APM and metrics suite
- Bugsnag → Stability monitoring platform

They moved away from their original mission because error tracking doesn't generate enough revenue for venture-backed growth.

### What Lapsoss Offers

**A vendor-neutral error reporting layer** where:
- Each provider can maintain their own adapter
- Focus remains strictly on error reporting
- No APM bloat
- No telemetry overhead
- No security monitoring you didn't ask for

**Currently shipping with 4 adapters:**
- **Sentry** - Pure Ruby implementation for error tracking
- **AppSignal** - Support for errors, deploy markers, and check-ins
- **Rollbar** - Complete error tracking with grouping and person tracking
- **Insight Hub** (formerly Bugsnag) - Error tracking with breadcrumbs and session support

More adapters can be easily added - we welcome contributions from the community and vendors!

**Want APM?** Use a dedicated APM gem or OpenTelemetry.
**Need security monitoring?** Use a security-focused solution.
**Want metrics?** Use Prometheus or similar.

### The Philosophy

```ruby
# Traditional SDK approach:
gem 'appsignal'    # 1.2MB of instrumentation layers
gem 'sentry-ruby'  # 556K of growing complexity

# Lapsoss approach:
gem 'lapsoss'      # 256KB - Just error tracking!
# Then pick what you ACTUALLY need:
gem 'opentelemetry-ruby'  # If you want APM
gem 'prometheus-client'   # If you want metrics
```

Error tracking should be a focused tool, not a Swiss Army knife with 47 blades you'll never use. Let each tool do one thing well, following the Unix philosophy.

### For Vendors

We invite error tracking vendors to build Lapsoss adapters. You can:
- Focus on your value-added services (APM, security, etc.)
- Let Lapsoss handle basic error transport
- Stop maintaining bloated SDKs
- Reduce your support burden

Lapsoss exists because sometimes you just want to track errors. Not profile your heap. Not detect SQL injections. Not fingerprint attackers. Just. Track. Errors.

---

*This document based on actual release notes from:*
- Sentry-ruby: v5.21.0 through v5.26.0
- AppSignal: v4.5.8 through v4.5.17
- Airbrake: v5.2.1 through v6.2.2

*Research conducted July 2025*
