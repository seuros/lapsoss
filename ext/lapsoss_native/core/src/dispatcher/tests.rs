#![allow(clippy::unwrap_used)]

use super::*;
use crate::CaptureFuture;
use std::assert_matches;

// MOCKED: delivery timing and failure; the dispatcher itself is real.
struct TestAdapter {
    name: &'static str,
    delay: Duration,
    fail: bool,
}

impl Adapter for TestAdapter {
    fn name(&self) -> &str {
        self.name
    }
    fn capture<'a>(&'a self, _event: &'a Event) -> CaptureFuture<'a> {
        Box::pin(async move {
            tokio::time::sleep(self.delay).await;
            if self.fail {
                Err(crate::AdapterError::new("expected failure"))
            } else {
                Ok(())
            }
        })
    }
}

fn adapter(name: &'static str, delay: u64, fail: bool) -> Arc<dyn Adapter> {
    Arc::new(TestAdapter {
        name,
        delay: Duration::from_millis(delay),
        fail,
    })
}

#[tokio::test]
async fn fanout_and_failure_isolation() {
    let d = Dispatcher::new(
        Handle::current(),
        Config::default(),
        vec![adapter("good", 0, false), adapter("bad", 0, true)],
    )
    .unwrap();
    let result = d
        .submit(Event::message("test", "error"))
        .unwrap()
        .wait()
        .await
        .unwrap();
    assert_eq!(result.outcomes.len(), 2);
    assert_eq!(result.outcomes.iter().filter(|o| o.success).count(), 1);
    assert!(d.flush(Duration::from_secs(1)).await);
    assert_eq!(d.statistics().failed, 1);
}

#[tokio::test]
async fn acknowledged_capacity_covers_callbacks() {
    let d = Dispatcher::new(
        Handle::current(),
        Config {
            max_events: 1,
            acknowledge_completions: true,
            ..Config::default()
        },
        vec![],
    )
    .unwrap();
    let receipt = d.submit(Event::message("one", "info")).unwrap();
    let sequence = receipt.sequence;
    receipt.wait().await.unwrap();
    assert_matches!(
        d.submit(Event::message("two", "info")),
        Err(SubmitError::Full)
    );
    assert_eq!(d.take_completions().len(), 1);
    assert!(d.take_completions().is_empty());
    assert!(!d.flush(Duration::from_millis(1)).await);
    d.acknowledge(sequence);
    assert!(d.flush(Duration::from_millis(1)).await);
    assert!(d.submit(Event::message("two", "info")).is_ok());
    d.cancel();
}

#[tokio::test]
async fn overflow_and_shutdown_deadline() {
    let d = Dispatcher::new(
        Handle::current(),
        Config {
            max_events: 1,
            ..Config::default()
        },
        vec![adapter("slow", 10000, false)],
    )
    .unwrap();
    let receipt = d.submit(Event::message("one", "info")).unwrap();
    assert_matches!(
        d.submit(Event::message("two", "info")),
        Err(SubmitError::Full)
    );
    assert!(!d.shutdown(Duration::from_millis(1)).await);
    assert!(receipt.wait().await.unwrap().abandoned);
    assert_eq!(d.statistics().abandoned, 1);
    assert_matches!(
        d.submit(Event::message("three", "info")),
        Err(SubmitError::Closed)
    );
    assert!(d.shutdown(Duration::from_millis(1)).await);
}

#[tokio::test]
async fn bytes_and_names_are_validated() {
    for config in [
        Config {
            max_events: 0,
            ..Config::default()
        },
        Config {
            max_bytes: 0,
            ..Config::default()
        },
        Config {
            concurrency_per_adapter: 0,
            ..Config::default()
        },
        Config {
            concurrency_per_adapter: Semaphore::MAX_PERMITS.strict_add(1),
            ..Config::default()
        },
    ] {
        assert_matches!(config.validate(), Err(SubmitError::Configuration(_)));
        assert_matches!(
            Dispatcher::new(Handle::current(), config, vec![]).map(|_| ()),
            Err(SubmitError::Configuration(_))
        );
    }
    let d = Dispatcher::new(
        Handle::current(),
        Config {
            max_bytes: 1,
            ..Config::default()
        },
        vec![],
    )
    .unwrap();
    assert_matches!(
        d.submit(Event::message("oversize", "info")),
        Err(SubmitError::Full)
    );
    assert!(
        Dispatcher::new(
            Handle::current(),
            Config::default(),
            vec![adapter("same", 0, false), adapter("same", 0, false),]
        )
        .is_err()
    );
}

#[tokio::test]
async fn flush_watermark_does_not_wait_for_later_events() {
    let d = Dispatcher::new(
        Handle::current(),
        Config {
            acknowledge_completions: true,
            ..Config::default()
        },
        vec![],
    )
    .unwrap();
    let first = d.submit(Event::message("first", "info")).unwrap();
    let watermark = d.watermark();
    first.wait().await.unwrap();
    d.acknowledge(watermark);
    let later = d.submit(Event::message("later", "info")).unwrap();
    assert!(d.flush_through(watermark, Duration::from_millis(10)).await);
    let sequence = later.sequence;
    later.wait().await.unwrap();
    d.acknowledge(sequence);
}

#[tokio::test]
async fn shutdown_preserves_destinations_that_already_succeeded() {
    let d = Dispatcher::new(
        Handle::current(),
        Config::default(),
        vec![adapter("fast", 0, false), adapter("slow", 10000, false)],
    )
    .unwrap();
    let receipt = d.submit(Event::message("partial", "info")).unwrap();
    // Observe the recorded result, rather than relying on task scheduling.
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if d.inner
                .state()
                .records
                .values()
                .any(|r| !r.partial_outcomes.is_empty())
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(!d.shutdown(Duration::from_millis(1)).await);
    let completion = receipt.wait().await.unwrap();
    assert!(completion.abandoned);
    assert!(
        completion
            .outcomes
            .iter()
            .any(|o| o.adapter == "fast" && o.success)
    );
    assert!(
        completion
            .outcomes
            .iter()
            .any(|o| o.adapter == "slow" && !o.success)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn replacing_destinations_and_admission_share_one_snapshot() {
    let dispatcher = Dispatcher::new(
        Handle::current(),
        Config::default(),
        vec![adapter("original", 10, false)],
    )
    .unwrap();
    let original = dispatcher
        .submit(Event::message("before replacement", "info"))
        .unwrap();
    let receipts = std::thread::scope(|scope| {
        scope.spawn(|| {
            for index in 0u32..256 {
                let name = if index.is_multiple_of(2) {
                    "even"
                } else {
                    "odd"
                };
                dispatcher
                    .replace_adapters(vec![adapter(name, 0, false)])
                    .unwrap();
            }
        });
        (0..256)
            .map(|_| {
                dispatcher
                    .submit(Event::message("concurrent replacement", "info"))
                    .unwrap()
            })
            .collect::<Vec<_>>()
    });
    let completion = original.wait().await.unwrap();
    assert_eq!(completion.outcomes[0].adapter, "original");
    for receipt in receipts {
        let completion = receipt.wait().await.unwrap();
        assert_eq!(completion.outcomes.len(), 1);
        assert!(completion.outcomes[0].success);
    }
    assert!(dispatcher.shutdown(Duration::from_secs(2)).await);
}
