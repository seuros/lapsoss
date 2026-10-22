#![allow(
    clippy::unwrap_used,
    reason = "test setup and assertions should fail immediately"
)]

use super::*;
use crate::{service::DestinationConfig, test_support::Directory};

fn configuration(directory: &Directory) -> StorageConfig {
    StorageConfig {
        path: directory.0.join("state.redb").to_str().unwrap().into(),
        ..StorageConfig::default()
    }
}

fn destinations() -> Vec<DestinationConfig> {
    serde_json::from_value(json!([
        { "adapter": { "name": "logger", "type": "logger" }, "policy": { "budget_events": 1 } }
    ]))
    .unwrap()
}

fn open_store(config: &StorageConfig) -> Store {
    open_store_with(config, &destinations())
}

fn open_store_with(config: &StorageConfig, destinations: &[DestinationConfig]) -> Store {
    Store::open(config, &Config::default(), destinations).unwrap()
}

#[test]
fn counts_budget_and_receipts_survive_reopening() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let event = Event::message("outage", "error");
    let response;
    {
        let store = open_store(&config);
        response = store.admit(&event, 0.0).unwrap().response;
        let second = Event::message("outage", "error");
        assert_eq!(
            store.admit(&second, 1.0).unwrap().response["destinations"][0]["outcome"]["decision"],
            "aggregate"
        );
    }
    let store = open_store(&config);
    assert_eq!(store.clock, 1.0);
    assert_eq!(store.admit(&event, 1.0).unwrap().response, response);
    let distinct = store
        .admit(&Event::message("another", "error"), 2.0)
        .unwrap();
    assert_eq!(
        distinct.response["destinations"][0]["outcome"]["reason"],
        "destination_budget"
    );
    let stats = store.statistics().unwrap();
    assert_eq!(stats["destinations"][0]["policy"]["received"], 3);
    assert_eq!(stats["destinations"][0]["policy"]["forwarded"], 1);
    assert_eq!(store.pending().unwrap().len(), 1);
}

#[test]
fn same_id_with_different_payload_is_rejected() {
    let directory = Directory::new();
    let store = open_store(&configuration(&directory));
    let mut event = Event::message("one", "error");
    store.admit(&event, 0.0).unwrap();
    event.message = Some("changed".into());
    assert_eq!(
        store.admit(&event, 1.0).unwrap().response["error"],
        "event_id_conflict"
    );
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["policy"]["received"],
        1
    );
}

#[test]
fn completed_jobs_are_removed_but_failures_are_retained() {
    let directory = Directory::new();
    let store = open_store(&configuration(&directory));
    let admission = store.admit(&Event::message("one", "error"), 0.0).unwrap();
    let (name, key, _) = &admission.jobs[0];
    store
        .complete(&[(name.clone(), key.clone(), false, false)], 1.0)
        .unwrap();
    assert!(store.pending().unwrap().is_empty());
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["spool"]["failed"],
        1
    );
    let admission = store.admit(&Event::message("two", "error"), 60.0).unwrap();
    let (name, key, _) = &admission.jobs[0];
    store
        .complete(&[(name.clone(), key.clone(), false, true)], 61.0)
        .unwrap();
    assert_eq!(store.pending().unwrap().len(), 1);
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 62.0)
        .unwrap();
    assert!(store.pending().unwrap().is_empty());
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["spool"]["delivered"],
        1
    );
}

#[test]
fn pending_jobs_pin_receipts_beyond_the_normal_retention() {
    let directory = Directory::new();
    let config = StorageConfig {
        receipt_retention_seconds: 1,
        max_receipts: 1,
        ..configuration(&directory)
    };
    let store = open_store(&config);
    let event = Event::message("one", "error");
    let admission = store.admit(&event, 0.0).unwrap();
    assert_eq!(
        store.admit(&event, 100.0).unwrap().response,
        admission.response
    );
    assert_eq!(
        store
            .admit(&Event::message("two", "error"), 100.0)
            .unwrap()
            .response["error"],
        "receipt_capacity"
    );
    let (name, key, _) = &admission.jobs[0];
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 100.0)
        .unwrap();
    assert!(
        store
            .admit(&Event::message("two", "error"), 102.0)
            .unwrap()
            .response["ok"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn queue_capacity_survives_reopening() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let queue = Config {
        max_events: 1,
        ..Config::default()
    };
    let store = Store::open(&config, &queue, &destinations()).unwrap();
    store.admit(&Event::message("one", "error"), 0.0).unwrap();
    assert_eq!(
        store
            .admit(&Event::message("two", "error"), 60.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["reason"],
        "delivery_queue_full"
    );
    drop(store);
    let store = Store::open(&config, &queue, &destinations()).unwrap();
    assert_eq!(
        store
            .admit(&Event::message("two", "error"), 61.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["reason"],
        "delivery_queue_full"
    );
}

#[test]
fn transaction_failure_does_not_partially_admit_to_one_destination() {
    let directory = Directory::new();
    let mut destinations = destinations();
    destinations.push(
        serde_json::from_value(json!({ "adapter": { "name": "second", "type": "logger" } }))
            .unwrap(),
    );
    let store = open_store_with(&configuration(&directory), &destinations);
    let tx = store.db.begin_write().unwrap();
    tx.open_table(DATA)
        .unwrap()
        .remove("destination/second")
        .unwrap();
    commit(tx).unwrap();
    assert!(store.admit(&Event::message("one", "error"), 0.0).is_err());
    assert!(store.pending().unwrap().is_empty());
    let tx = store.db.begin_write().unwrap();
    assert_eq!(
        get::<Destination>(&tx, "destination/logger")
            .unwrap()
            .unwrap()
            .policy
            .statistics
            .received,
        0
    );
    assert_eq!(get::<Ledger>(&tx, "ledger").unwrap().unwrap().receipts, 0);
}

#[test]
fn failed_jobs_require_explicit_redrive_without_spending_budget_again() {
    let directory = Directory::new();
    let mut config = configuration(&directory);
    let store = open_store(&config);
    let event = Event::message("one", "error");
    let admission = store.admit(&event, 0.0).unwrap();
    let (name, key, _) = &admission.jobs[0];
    store
        .complete(&[(name.clone(), key.clone(), false, false)], 1.0)
        .unwrap();
    drop(store);
    let store = open_store(&config);
    assert!(store.pending().unwrap().is_empty());
    drop(store);
    config.retry_failed_on_startup = true;
    let store = open_store(&config);
    assert_eq!(store.pending().unwrap()[0].2.id, event.id);
    assert_eq!(
        store.admit(&event, 2.0).unwrap().response,
        admission.response
    );
    let stats = store.statistics().unwrap();
    assert_eq!(stats["destinations"][0]["spool"]["failed"], 0);
    assert_eq!(stats["destinations"][0]["policy"]["received"], 1);
    assert_eq!(
        store
            .admit(&Event::message("two", "error"), 3.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["reason"],
        "destination_budget"
    );
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 4.0)
        .unwrap();
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["spool"]["delivered"],
        1
    );
}

#[test]
fn retained_jobs_fence_destination_settings_and_queue_limits() {
    let directory = Directory::new();
    let mut config = configuration(&directory);
    let mut destinations = destinations();
    let store = open_store_with(&config, &destinations);
    store.admit(&Event::message("one", "error"), 0.0).unwrap();
    store.admit(&Event::message("two", "error"), 60.0).unwrap();
    drop(store);
    let smaller = Config {
        max_events: 1,
        ..Config::default()
    };
    assert!(Store::open(&config, &smaller, &destinations).is_err());
    destinations[0]
        .adapter
        .settings
        .insert("rotated".into(), json!(true));
    assert!(Store::open(&config, &Config::default(), &destinations).is_err());
    config.allow_destination_changes = true;
    let store = open_store_with(&config, &destinations);
    assert_eq!(store.pending().unwrap().len(), 2);
    drop(store);
    destinations.clear();
    assert!(Store::open(&config, &Config::default(), &destinations).is_err());
}

#[test]
fn unsafe_paths_and_missing_ledger_fail_closed() {
    let directory = Directory::new();
    let config = configuration(&directory);
    std::os::unix::fs::symlink(directory.0.join("other"), &config.path).unwrap();
    assert!(Store::open(&config, &Config::default(), &destinations()).is_err());
    std::fs::remove_file(&config.path).unwrap();
    let store = open_store(&config);
    let tx = store.db.begin_write().unwrap();
    tx.open_table(DATA).unwrap().remove("ledger").unwrap();
    commit(tx).unwrap();
    drop(store);
    assert!(Store::open(&config, &Config::default(), &destinations()).is_err());
    std::fs::set_permissions(&config.path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(Store::open(&config, &Config::default(), &destinations()).is_err());
}

#[test]
fn expired_groups_free_capacity_and_storage_is_exclusive() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let destinations: Vec<DestinationConfig> = serde_json::from_value(json!([
        { "adapter": { "name": "logger", "type": "logger" },
          "policy": { "max_fingerprints": 1, "retention_seconds": 60 } }
    ]))
    .unwrap();
    let store = open_store_with(&config, &destinations);
    assert!(Store::open(&config, &Config::default(), &destinations).is_err());
    store.admit(&Event::message("one", "error"), 0.0).unwrap();
    assert_eq!(
        store
            .admit(&Event::message("two", "error"), 1.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["reason"],
        "fingerprint_capacity"
    );
    assert_eq!(
        store
            .admit(&Event::message("three", "error"), 60.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["decision"],
        "forward"
    );
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["policy"]["expired_groups"],
        1
    );
}

fn summary_destinations(budget: u32) -> Vec<DestinationConfig> {
    serde_json::from_value(json!([{
        "adapter": { "name": "logger", "type": "logger" },
        "policy": {
            "timed_summaries": true, "representative_interval_seconds": 2,
            "budget_events": budget, "retention_seconds": 120
        }
    }]))
    .unwrap()
}

#[test]
fn timed_summary_survives_restart_and_does_not_add_an_occurrence() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let destinations = summary_destinations(100);
    let store = open_store_with(&config, &destinations);
    let mut event = Event::message("outage", "error");
    event.context = json!({ "user": { "email": "private" }, "breadcrumbs": ["private"] });
    store.admit(&event, 0.0).unwrap();
    let duplicate = Event::message("outage", "error");
    store.admit(&duplicate, 1.0).unwrap();
    assert!(store.summarize(2.0).unwrap().is_empty());
    drop(store);
    let store = open_store_with(&config, &destinations);
    let jobs = store.summarize(3.0).unwrap();
    assert_eq!(jobs.len(), 1);
    let (name, key, summary) = &jobs[0];
    assert_ne!(summary.id, event.id);
    assert_ne!(summary.id, duplicate.id);
    assert_eq!(summary.extra()["lapsossd"]["summary"], true);
    assert_eq!(summary.extra()["lapsossd"]["occurrences"], 2);
    assert_eq!(
        summary.extra()["lapsossd"]["suppressed_since_previous_forward"],
        1
    );
    assert_eq!(
        summary.extra()["lapsossd"]["example_event_id"],
        event.id.to_string()
    );
    assert!(summary.context["user"].is_null());
    assert!(summary.context["breadcrumbs"].is_null());
    assert!(summary.frames.is_empty());
    assert!(store.summarize(100.0).unwrap().is_empty());
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 100.0)
        .unwrap();
    let statistics = store.statistics().unwrap();
    assert_eq!(statistics["destinations"][0]["policy"]["received"], 2);
    assert_eq!(statistics["destinations"][0]["policy"]["forwarded"], 2);
    assert_eq!(statistics["destinations"][0]["policy"]["summaries"], 1);
    assert_eq!(statistics["receipts"], 2); // Internal summaries need no client receipt.
    drop(store);
    let store = open_store_with(&config, &destinations);
    assert_eq!(store.pending().unwrap().len(), 1); // Only the original job remains.
    assert!(store.summarize(110.0).unwrap().is_empty());
}

#[test]
fn timed_summary_waits_for_the_shared_budget_without_losing_counts() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let store = open_store_with(&config, &summary_destinations(1));
    store
        .admit(&Event::message("outage", "error"), 0.0)
        .unwrap();
    store
        .admit(&Event::message("outage", "error"), 1.0)
        .unwrap();
    assert!(store.summarize(3.0).unwrap().is_empty());
    assert!(store.summarize(59.0).unwrap().is_empty());
    let jobs = store.summarize(60.1).unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(
        jobs[0].2.extra()["lapsossd"]["suppressed_since_previous_forward"],
        1
    );
    assert_eq!(
        store
            .admit(&Event::message("different", "error"), 61.0)
            .unwrap()
            .response["destinations"][0]["outcome"]["reason"],
        "destination_budget"
    );
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["policy"]["budget_limited"],
        1
    );
}

#[test]
fn full_queue_defers_summary_without_spending_budget_or_clearing_pending() {
    let directory = Directory::new();
    let queue = Config {
        max_events: 1,
        ..Config::default()
    };
    let store = Store::open(&configuration(&directory), &queue, &summary_destinations(2)).unwrap();
    let original = store
        .admit(&Event::message("outage", "error"), 0.0)
        .unwrap();
    store
        .admit(&Event::message("outage", "error"), 1.0)
        .unwrap();
    assert!(store.summarize(3.0).unwrap().is_empty());
    let (name, key, _) = &original.jobs[0];
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 3.0)
        .unwrap();
    let jobs = store.summarize(4.1).unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(
        jobs[0].2.extra()["lapsossd"]["suppressed_since_previous_forward"],
        1
    );
    let policy = &store.statistics().unwrap()["destinations"][0]["policy"];
    assert_eq!(policy["received"], 2);
    assert_eq!(policy["forwarded"], 2);
    assert_eq!(policy["queue_rejected"], 0);
}

#[test]
fn live_representative_cancels_a_pending_summary() {
    let directory = Directory::new();
    let store = open_store_with(&configuration(&directory), &summary_destinations(100));
    store
        .admit(&Event::message("outage", "error"), 0.0)
        .unwrap();
    store
        .admit(&Event::message("outage", "error"), 1.0)
        .unwrap();
    let result = store
        .admit(&Event::message("outage", "error"), 2.0)
        .unwrap();
    assert_eq!(result.jobs.len(), 1);
    assert_eq!(
        result.jobs[0].2.extra()["lapsossd"]["suppressed_since_previous_forward"],
        1
    );
    assert!(store.summarize(3.0).unwrap().is_empty());
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["policy"]["summaries"],
        0
    );
}

#[test]
fn disabling_summaries_or_excluding_the_class_removes_pending_timers() {
    for disable in [true, false] {
        let directory = Directory::new();
        let config = configuration(&directory);
        let mut destinations = summary_destinations(100);
        let store = open_store_with(&config, &destinations);
        for now in [0.0, 1.0] {
            let mut event = Event::message("outage", "error");
            event.exception = Some(lapsoss::Exception {
                class: "Noise".into(),
                ..Default::default()
            });
            store.admit(&event, now).unwrap();
        }
        drop(store);
        if disable {
            destinations[0].policy.timed_summaries = false;
        } else {
            destinations[0]
                .policy
                .excluded_exception_classes
                .push("Noise".into());
        }
        let store = open_store_with(&config, &destinations);
        assert!(store.summarize(3.0).unwrap().is_empty());
        assert!(store.summarize(4.0).unwrap().is_empty());
        assert_eq!(
            store.statistics().unwrap()["destinations"][0]["policy"]["received"],
            2
        );
        assert_eq!(store.pending().unwrap().len(), 1);
    }
}

#[test]
fn expiry_removes_scheduled_work_and_bounds_blocked_summaries() {
    let directory = Directory::new();
    let mut destinations = summary_destinations(1);
    destinations[0].policy.retention_seconds = 10;
    let store = open_store_with(&configuration(&directory), &destinations);
    store
        .admit(&Event::message("outage", "error"), 0.0)
        .unwrap();
    store
        .admit(&Event::message("outage", "error"), 1.0)
        .unwrap();
    assert!(store.summarize(3.0).unwrap().is_empty()); // Budget reopens after retention.
    assert!(store.summarize(61.0).unwrap().is_empty());
    assert_eq!(
        store.statistics().unwrap()["destinations"][0]["policy"]["tracked_fingerprints"],
        0
    );
    assert!(store.summarize(62.0).unwrap().is_empty());
}

#[test]
fn summary_batches_are_bounded_and_examples_do_not_retain_large_context() {
    let directory = Directory::new();
    let store = open_store_with(&configuration(&directory), &summary_destinations(1000));
    for now in [0.0, 1.0] {
        for index in 0..66 {
            let mut event = Event::message(format!("{index}:{}", "x".repeat(10_000)), "error");
            event.context = json!({ "extra": { "large": "y".repeat(10_000) } });
            store.admit(&event, now).unwrap();
        }
    }
    let first = store.summarize(3.0).unwrap();
    assert_eq!(first.len(), 64);
    assert_eq!(store.summarize(3.0).unwrap().len(), 2);
    assert!(store.summarize(4.0).unwrap().is_empty());
    assert!(serde_json::to_vec(&first[0].2).unwrap().len() < 5000);
}

#[test]
fn storage_starts_at_schema_one_and_refuses_unknown_versions() {
    let directory = Directory::new();
    let config = configuration(&directory);
    let store = open_store(&config);
    let tx = store.db.begin_write().unwrap();
    assert_eq!(get::<u32>(&tx, "schema").unwrap(), Some(1));
    put(&tx, "schema", &2_u32).unwrap();
    commit(tx).unwrap();
    drop(store);
    assert!(Store::open(&config, &Config::default(), &destinations()).is_err());
}

#[test]
fn queued_summaries_replay_and_redrive_without_client_receipts() {
    let directory = Directory::new();
    let mut config = configuration(&directory);
    let destinations = summary_destinations(100);
    let store = open_store_with(&config, &destinations);
    store
        .admit(&Event::message("outage", "error"), 0.0)
        .unwrap();
    store
        .admit(&Event::message("outage", "error"), 1.0)
        .unwrap();
    let jobs = store.summarize(3.0).unwrap();
    let (name, key, event) = &jobs[0];
    drop(store);
    let store = open_store_with(&config, &destinations);
    assert!(
        store
            .pending()
            .unwrap()
            .iter()
            .any(|(_, _, queued)| queued.id == event.id)
    );
    assert!(store.summarize(4.0).unwrap().is_empty());
    store
        .complete(&[(name.clone(), key.clone(), false, false)], 4.0)
        .unwrap();
    drop(store);
    config.retry_failed_on_startup = true;
    let store = open_store_with(&config, &destinations);
    assert!(
        store
            .pending()
            .unwrap()
            .iter()
            .any(|(_, _, queued)| queued.id == event.id)
    );
    store
        .complete(&[(name.clone(), key.clone(), true, false)], 5.0)
        .unwrap();
    let statistics = store.statistics().unwrap();
    assert_eq!(statistics["destinations"][0]["policy"]["received"], 2);
    assert_eq!(statistics["destinations"][0]["policy"]["summaries"], 1);
    assert_eq!(statistics["destinations"][0]["spool"]["failed"], 0);
    assert_eq!(statistics["receipts"], 2);
}
