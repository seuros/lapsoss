#![allow(clippy::unwrap_used, reason = "test setup should fail immediately")]

use super::*;
use std::collections::HashMap;

// A tiny in-memory host for testing policy independently of disk I/O.
struct Policy {
    engine: super::Policy,
    state: State,
    groups: HashMap<String, (f64, Group)>,
    retention: f64,
}

impl Policy {
    fn new(config: PolicyConfig) -> Result<Self, &'static str> {
        let retention = f64::from(config.retention_seconds);
        Ok(Self {
            engine: super::Policy::new(config)?,
            state: State::default(),
            groups: HashMap::new(),
            retention,
        })
    }

    fn submit(&mut self, event: Event, now: f64, forward: impl FnOnce(Event) -> bool) -> Outcome {
        let before = self.groups.len();
        self.groups
            .retain(|_, (seen, _)| now - *seen < self.retention);
        self.state.statistics.expired_groups += u64::try_from(before - self.groups.len()).unwrap();
        self.state.statistics.tracked_fingerprints = self.groups.len();
        let key = fingerprint(&event);
        let mut group = self.groups.remove(&key).map(|(_, group)| group);
        let outcome = self
            .engine
            .submit(event, now, &mut self.state, &mut group, forward);
        if let Some(group) = group {
            self.groups.insert(key, (now, group));
        }
        outcome
    }

    fn statistics(&self) -> Statistics {
        self.state.statistics.clone()
    }
}

fn policy() -> Policy {
    Policy::new(PolicyConfig::default()).unwrap()
}

#[test]
fn first_occurrence_is_forwarded_and_duplicates_are_counted() {
    let mut policy = policy();
    let event = Event::message("database unavailable", "error");
    assert_eq!(
        policy.submit(event.clone(), 0.0, |_| true).decision,
        Decision::Forward
    );
    for count in 2..=1000 {
        let result = policy.submit(event.clone(), 1.0, |_| panic!("duplicate was forwarded"));
        assert_eq!(result.decision, Decision::Aggregate);
        assert_eq!(result.occurrences, count);
    }
    let result = policy.submit(event, 60.0, |representative| {
        assert_eq!(representative.extra()["lapsossd"]["occurrences"], 1001);
        assert_eq!(
            representative.extra()["lapsossd"]["suppressed_since_previous_forward"],
            999
        );
        true
    });
    assert_eq!(result.decision, Decision::Forward);
    assert_eq!(policy.statistics().forwarded, 2);
    assert_eq!(policy.statistics().aggregated, 999);
}

#[test]
fn budget_limits_distinct_fingerprints_without_losing_counts() {
    let mut policy = Policy::new(PolicyConfig {
        budget_events: 1,
        ..PolicyConfig::default()
    })
    .unwrap();
    assert_eq!(
        policy
            .submit(Event::message("one", "error"), 0.0, |_| true)
            .decision,
        Decision::Forward
    );
    let event = Event::message("two", "error");
    let result = policy.submit(event.clone(), 1.0, |_| panic!("budget exceeded"));
    assert_eq!(result.reason, "destination_budget");
    let result = policy.submit(event, 60.0, |_| true);
    assert_eq!(result.decision, Decision::Forward);
    assert_eq!(result.occurrences, 2);
}

#[test]
fn failed_queue_admission_does_not_consume_budget_or_suppress_next_event() {
    let mut policy = Policy::new(PolicyConfig {
        budget_events: 1,
        ..PolicyConfig::default()
    })
    .unwrap();
    let event = Event::message("one", "error");
    assert_eq!(
        policy.submit(event.clone(), 0.0, |_| false).decision,
        Decision::Reject
    );
    assert_eq!(
        policy.submit(event, 0.1, |_| true).decision,
        Decision::Forward
    );
}

#[test]
fn environments_and_releases_have_independent_groups() {
    let mut policy = policy();
    let mut event = Event::message("one", "error");
    event.fingerprint = json!(["custom"]);
    assert_eq!(
        policy.submit(event.clone(), 0.0, |_| true).decision,
        Decision::Forward
    );
    event.environment = Some("production".into());
    assert_eq!(
        policy.submit(event.clone(), 1.0, |_| true).decision,
        Decision::Forward
    );
    event.release = Some("v2".into());
    assert_eq!(
        policy.submit(event, 2.0, |_| true).decision,
        Decision::Forward
    );
}

#[test]
fn capacity_is_bounded_and_idle_groups_expire() {
    let mut policy = Policy::new(PolicyConfig {
        max_fingerprints: 1,
        retention_seconds: 60,
        ..PolicyConfig::default()
    })
    .unwrap();
    policy.submit(Event::message("one", "error"), 0.0, |_| true);
    assert_eq!(
        policy
            .submit(Event::message("two", "error"), 1.0, |_| true)
            .reason,
        "fingerprint_capacity"
    );
    assert_eq!(policy.statistics().tracked_fingerprints, 1);
    assert_eq!(
        policy
            .submit(Event::message("two", "error"), 60.0, |_| true)
            .decision,
        Decision::Forward
    );
    assert_eq!(policy.statistics().expired_groups, 1);
}

#[test]
fn exclusion_is_terminal_and_allocates_no_group() {
    let mut policy = Policy::new(PolicyConfig {
        excluded_exception_classes: vec!["Noise".into()],
        ..PolicyConfig::default()
    })
    .unwrap();
    let mut event = Event::message("ignored", "error");
    event.exception = Some(lapsoss::Exception {
        class: "Noise".into(),
        ..Default::default()
    });
    assert_eq!(
        policy
            .submit(event, 0.0, |_| panic!("excluded event forwarded"))
            .decision,
        Decision::Suppress
    );
    assert_eq!(policy.statistics().tracked_fingerprints, 0);
    assert_eq!(policy.statistics().excluded, 1);
}

#[test]
fn invalid_configuration_is_rejected() {
    assert!(
        Policy::new(PolicyConfig {
            budget_events: 0,
            ..PolicyConfig::default()
        })
        .is_err()
    );
    assert!(
        Policy::new(PolicyConfig {
            max_fingerprints: 0,
            ..PolicyConfig::default()
        })
        .is_err()
    );
    assert!(
        Policy::new(PolicyConfig {
            retention_seconds: 1,
            ..PolicyConfig::default()
        })
        .is_err()
    );
}

#[test]
fn invalid_context_or_time_is_rejected_without_allocating_state() {
    let mut policy = policy();
    let mut event = Event::message("bad", "error");
    event.context = json!([]);
    assert_eq!(
        policy
            .submit(event, 0.0, |_| panic!("invalid event forwarded"))
            .decision,
        Decision::Reject
    );
    assert_eq!(
        policy
            .submit(Event::message("bad", "error"), f64::NAN, |_| true)
            .decision,
        Decision::Reject
    );
    assert_eq!(policy.statistics().tracked_fingerprints, 0);
}
