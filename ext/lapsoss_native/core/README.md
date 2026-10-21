# lapsoss

Vendor-neutral, bounded, in-process error delivery. No Ruby dependency.
The caller supplies and owns a Tokio runtime.

```rust,no_run
use std::sync::Arc;
use std::time::Duration;
use lapsoss::{AdapterConfig, Config, Dispatcher, Event, HttpAdapter, TransportConfig};

# async fn example() -> Result<(), Box<dyn std::error::Error>> {
let adapter = HttpAdapter::new(
    AdapterConfig::new("errors", "sentry")
        .setting("dsn", "https://public@example.com/123"),
    TransportConfig::default(),
)?;
let dispatcher = Dispatcher::new(
    tokio::runtime::Handle::current(),
    Config::default(),
    vec![Arc::new(adapter)],
)?;
let receipt = dispatcher.submit(Event::message("hello", "info"))?;
let completion = receipt.wait().await?;
assert!(completion.outcomes.iter().all(|outcome| outcome.success));
assert!(dispatcher.shutdown(Duration::from_secs(2)).await);
# Ok(())
# }
```

Submission means admission, not successful delivery. Capacity covers queued,
in-flight and retrying events. By default completions release capacity
automatically. Bridges can opt into acknowledged completions: poll them and
acknowledge only after their language-owned callbacks have completed.

`flush` is a watermark barrier, not a sleep. It includes work accepted before
the call and does not wait for subsequent submissions. Shutdown stops admission,
drains, and cancels remaining tasks at its deadline. Events live only in memory.

HTTP delivery uses Rama, verifies TLS certificates by default, and never follows
redirects. Retries use `chrono-machines` exponential backoff with optional full
jitter; `max_retries` accepts 0–254 additional attempts. Invalid transport
settings are rejected before delivery.

`LoggerAdapter` emits `tracing` events. The embedding application owns subscriber
configuration, just as it owns the Tokio runtime.

This crate consolidates reusable ideas and protocol code from `lapsoss-rs`.
The blackbox, persistence, socket relay and Axum integration are not included.
