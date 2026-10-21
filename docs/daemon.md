# lapsossd: filtering before ingestion

## Scope of this first implementation

One daemon serves **one trusted application/project on one host**, shared by
its Ruby workers. It is not a remote or multi-tenant ingestion server. Use
separate daemon instances, socket directories, and configurations to isolate
projects. Multiple daemons do not coordinate budgets.

The implementation reuses `throttle-machines` for destination event budgets and
the `lapsoss` Rust delivery core, which uses `chrono-machines` for retry backoff.
Disk persistence, autonomous summary timers, distributed quotas, and
behavior-tree policy configuration are not implemented yet.

## Configuration

See the [README](../README.md) for a complete configuration. JSON is read from
the file passed to `--config`; there is no environment interpolation. Restrict
the configuration file to the service account (`0600`), since adapter settings
contain vendor credentials. The socket protocol cannot change adapters,
credentials, or daemon policies.

Each destination contains an `adapter` and optional `policy`.
Supported HTTP protocols are the same as the shared Rust core: Sentry/Telebugs,
Rollbar, AppSignal, Insight Hub/Bugsnag, OpenObserve, and OTLP.
The `logger` adapter writes locally instead of making HTTP requests.

Policy defaults:

| Setting | Default | Meaning |
|---|---:|---|
| `representative_interval_seconds` | 60 | Minimum interval between queued representatives of a fingerprint |
| `budget_events` | 100 | Maximum queued representatives per destination window |
| `budget_window_seconds` | 60 | Monotonic fixed-window duration |
| `max_fingerprints` | 4096 | Hard cap on tracked groups per destination (maximum 65536) |
| `retention_seconds` | 3600 | Idle retention; must cover the representative interval |
| `excluded_exception_classes` | `[]` | Exact exception class names to suppress |

The optional `queue` object accepts `max_events` (1000), `max_bytes` (10485760),
and `concurrency_per_adapter` (4), **per destination**. Completion
acknowledgement must remain automatic. A daemon accepts 1–16 named destinations.

The optional `transport` object accepts the shared core's timeout, retry, jitter,
backoff, and TLS settings. TLS verification is on by default. Explicitly set
`"max_retries": 0` if you do not want automatic retry attempts; the shared core's
default is three retries.

### Budget semantics

A budget token is consumed only when a representative enters its delivery queue.
Duplicate suppression, explicit exclusions, and queue rejection do not consume
tokens. Each destination makes its decision independently.

These are **logical event budgets**, not hard billing guarantees:

- Fixed windows permit bursts on either side of a boundary.
- HTTP retry attempts are not separately charged against this policy budget.
- A vendor can accept a request whose response is lost; retries can then create
  duplicate ingestion.
- Restarting the daemon resets its in-memory budgets.
- Running two daemons gives two independent budgets.
- New fingerprints are also subject to the budget; there is no hidden bypass.

## Grouping and aggregation

The daemon combines environment, release, and the event's explicit fingerprint.
When no fingerprint is supplied, exceptions with structured frames group by
exception class plus the first ten frame locations/functions. Other events
fall back to type, exception class, and exact message.

This does not attempt fuzzy grouping. Applications can use the client's existing
fingerprinting hooks to normalize changing identifiers.

Every tracked occurrence increments a group counter, including occurrences that
cannot currently be forwarded because a destination budget is exhausted.
Incoming events produce one of:

- `forward`: a representative was **queued**, not necessarily delivered.
- `aggregate`: the occurrence was counted; reason is `duplicate` or
  `destination_budget`.
- `suppress`: explicitly excluded; counted in the exclusion total without
  allocating a fingerprint group.
- `reject`: fingerprint capacity or delivery queue capacity was exhausted.

The next queued representative carries `extra.lapsossd`:

```json
{
  "occurrences": 1001,
  "occurrences_since_previous_forward": 1000,
  "suppressed_since_previous_forward": 999
}
```

**There is no background replay or autonomous summary yet.** Suppressed
payloads are not stored. If no later occurrence arrives, no summary event is
sent. Idle groups expire during ingress sweeps, at most once a minute.
Expiry removes their individual counts; cumulative daemon statistics remain.

If queued delivery ultimately fails, it appears in delivery statistics; policy
admission state is not rolled back. A later event can become a representative
after the interval. This is not an at-least-once persistent queue.

## Ruby client behavior

```ruby
Lapsoss.configure do |config|
  config.daemon_socket = "/run/lapsoss/lapsossd.sock"
  config.daemon_timeout = 0.1
end
```

`LAPSOSS_SOCKET` supplies the default path; otherwise it is
`/run/lapsoss/lapsossd.sock`. Vendor adapters must not be configured in the
daemon client.

Capture scrubs and serializes the event, then waits for a bounded local
admission acknowledgement. This is not an unbounded background send, and
`config.async` does not change this admission protocol. The configured deadline
includes client serialization-lock wait and socket I/O, but not event creation,
hooks, scrubbing, or JSON encoding.

Capture returns an event ID if any destination forwards, aggregates, or
intentionally suppresses the event. It returns `nil` on communication failure
or when every destination rejects it. Failures call the configured error handler
with `adapter: :daemon` and do **not** fall back to direct vendor delivery.
Automatic reconnect/replay is intentionally absent: a lost ACK is ambiguous.

`flush` covers earlier admissions serialized through that client and waits for
the daemon's current delivery watermark. It does not emit suppressed events or
prove vendor success. Its daemon-side wait is capped at 1.5 seconds.
`shutdown` closes only the Ruby client, not the shared daemon.

The client owns no persistent socket or worker threads. A post-fork request
uses a fresh socket and synchronization primitive.

```ruby
Lapsoss.client.statistics
# { accepted: ..., rejected: ..., daemon: {
#   "ok" => true, "destinations" => [
#     { "name" => "sentry", "policy" => {...}, "delivery" => {...} }
#   ]
# } }
```

Policy statistics distinguish received, forwarded, duplicate aggregation,
exclusions, budget limiting, fingerprint-capacity rejection, queue rejection,
and expired groups. Delivery statistics separately track outstanding, delivered,
failed, and abandoned jobs.

## Socket security and operations

Create the socket's parent directory with mode `0700`, owned by the service
account. The daemon refuses public or symlink parent directories and creates
the socket with mode `0600`. Run the daemon and application as the same user.
An existing socket path is never removed on startup: inspect a stale socket and
remove it manually only after confirming no daemon is listening.

Run in the foreground under systemd or another supervisor. SIGTERM and SIGINT
stop acceptance, cancel incomplete socket requests, and allow up to five
seconds for existing delivery jobs to drain. The socket is removed on clean
exit; a crash or SIGKILL may leave it behind.

Socket requests/responses use a four-byte unsigned big-endian JSON byte length,
followed by UTF-8 JSON. The maximum request is 1 MiB. Version 1 commands:

```json
{ "version": 1, "command": "submit", "event": { "...": "shared Rust Event schema" } }
{ "version": 1, "command": "statistics" }
{ "version": 1, "command": "flush", "timeout_ms": 1000 }
```

One command is processed per connection. Unknown commands, unsupported versions,
invalid events, and oversized frames are rejected. There are at most 32 active
connection handlers, each with a two-second deadline. No TCP listener or remote
control/shutdown API is exposed.

## Packaging and release

`bundle exec rake build` packages only the Ruby client and documentation.
Its runtime dependencies are ActiveSupport, concurrent-ruby, and Zeitwerk;
legacy HTTP/async libraries and `rb_sys` are development-only dependencies.
`bundle exec rake daemon:build` builds a release executable for the current
host, then embeds it in a platform-specific `lapsossd` gem. Both installs need
no Rust toolchain.

Build and test separately on each OS/architecture. The native artifact workflow
builds host binaries and attaches gems to an existing GitHub release; it does
not publish to RubyGems. Musl and Windows builds are not currently provided.
Keep `daemon/Cargo.toml` and `gems/lapsossd/lib/lapsossd/version.rb` aligned.

Neither gem is published automatically:

```sh
gem push pkg/lapsoss-2.0.0.gem
gem push pkg/lapsossd-0.1.0-<platform>.gem
```
