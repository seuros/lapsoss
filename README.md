# Lapsoss — control errors before paid ingestion

Lapsoss captures application errors once and decides what deserves to reach
Sentry, Rollbar, or another vendor **before** those events consume ingestion.

```text
Rails / Puma / Sidekiq
          │ scrubbed events over a local Unix socket
          ▼
       lapsossd
  fingerprint → count → filter → budget
          │
          ▼
    vendor delivery
```

## Two gems, separate responsibilities

- **`lapsoss`**: pure-Ruby capture, Rails integration, context, and scrubbing.
  No native extension, Rust compiler, or vendor credentials in the client.
- **`lapsossd`**: a platform gem containing a standalone Rust executable.
  Shared aggregation across local workers, durable counts and event budgets,
  bounded delivery queues, and retries. Run it under your service supervisor.

The client requires Ruby 4.0+; Rails integration targets Rails 8.1+.
The daemon currently supports Unix systems. Platform binaries must be built
for each supported host; this branch does not imply they are already published.

## Application setup

```ruby
# Gemfile
gem "lapsoss"
```

```ruby
# config/initializers/lapsoss.rb
Lapsoss.configure do |config|
  config.daemon_socket = "/run/lapsoss/lapsossd.sock"
  config.daemon_timeout = 0.1 # seconds, including connection and admission ACK
  config.environment = Rails.env
  config.release = ENV["APP_RELEASE"]
  config.logger = Rails.logger
end
```

Vendor adapters and credentials belong in the **daemon configuration**, not
`config.use_sentry` in the application.

```ruby
Lapsoss.capture_exception(error)
Lapsoss.capture_message("Payment processing unavailable", level: :error)

Lapsoss.with_scope(tags: { component: "checkout" }) do
  Lapsoss.capture_exception(error)
end

Lapsoss.flush(timeout: 2)
```

Rails.error integration, breadcrumbs, before-send hooks, exclusion filters,
sampling, and scrubbing remain client-side. The daemon sees only events that
survive those client-side policies.

## Daemon setup

Create socket and durable state directories owned by the application's service
account, with mode `0700`. Socket and database files are restricted to `0600`.
Keep state on persistent storage, not `/run` or another temporary filesystem.

```json
{
  "socket": "/run/lapsoss/lapsossd.sock",
  "storage": { "path": "/var/lib/lapsoss/state.redb" },
  "destinations": [
    {
      "adapter": {
        "name": "sentry",
        "type": "sentry",
        "settings": { "dsn": "https://PUBLIC_KEY@example.com/PROJECT_ID" }
      },
      "policy": {
        "timed_summaries": true,
        "representative_interval_seconds": 60,
        "budget_events": 100,
        "budget_window_seconds": 60,
        "max_fingerprints": 4096,
        "retention_seconds": 3600,
        "excluded_exception_classes": ["ActionController::RoutingError"]
      }
    }
  ],
  "transport": { "max_retries": 0 }
}
```

```sh
lapsossd --config /etc/lapsossd.json
```

The first admitted occurrence is queued immediately. Duplicates are counted
without being forwarded until another representative is eligible. Every
destination has its own policy and budget.

Admission is acknowledged only after a durable transaction stores the decision,
counts, budget, and queued payloads. Unfinished jobs replay after restart without
spending another budget token. Optional timed summaries report pending counts
even when no further occurrence arrives; they spend the same destination budget.
Without `timed_summaries`, counts accompany the next eligible event.
Budgets limit logical admissions—not
billing or HTTP attempts; ambiguous vendor acknowledgements can cause duplicates.
See [daemon operations](docs/daemon.md) before deploying.

## Build and test from a checkout

```sh
bundle install
bundle exec rake build           # pure Ruby client gem
bundle exec rake daemon:build    # release executable + host platform daemon gem

cargo test -p lapsossd --locked
LAPSOSSD_TEST_BIN="$PWD/target/release/lapsossd" bundle exec rake test_daemon
```

Publishing is deliberately manual:

```sh
gem push pkg/lapsoss-2.0.0.gem
gem push pkg/lapsossd-0.1.0-<platform>.gem
```

Build each daemon platform gem on its target host. No installation-time
compilation or executable download is used.

## Rust embedders

The independent `lapsoss` Rust crate stays at `0.2.0` and supplies the shared
delivery core. See its [guide](ext/lapsoss_native/core/README.md).
The [legacy embedded Ruby guide](docs/embedded.md) is retained for source-checkout
compatibility; it is not the deployment path for the pure-Ruby gem.
