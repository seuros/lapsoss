use std::collections::HashMap;

use lapsoss::Event;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use throttle_machines::{
    fixed_window::{FixedWindow, FixedWindowParams, FixedWindowState},
    gate::Gate,
};

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct PolicyConfig {
    pub representative_interval_seconds: u32,
    pub budget_events: u32,
    pub budget_window_seconds: u32,
    pub max_fingerprints: usize,
    pub retention_seconds: u32,
    pub excluded_exception_classes: Vec<String>,
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            representative_interval_seconds: 60,
            budget_events: 100,
            budget_window_seconds: 60,
            max_fingerprints: 4096,
            retention_seconds: 3600,
            excluded_exception_classes: Vec::new(),
        }
    }
}

impl PolicyConfig {
    /// # Errors
    /// Rejects zero limits, oversized fingerprint tables, or short retention.
    pub const fn validate(&self) -> Result<(), &'static str> {
        if self.representative_interval_seconds == 0
            || self.budget_events == 0
            || self.budget_window_seconds == 0
            || self.max_fingerprints == 0
            || self.max_fingerprints > 65_536
            || self.retention_seconds < self.representative_interval_seconds
        {
            return Err(
                "policy limits must be positive; retention must cover the representative interval; max_fingerprints <= 65536",
            );
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Forward,
    Aggregate,
    Suppress,
    Reject,
}

#[derive(Debug, Serialize)]
pub struct Outcome {
    pub decision: Decision,
    pub reason: &'static str,
    pub occurrences: u64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Statistics {
    pub received: u64,
    pub forwarded: u64,
    pub aggregated: u64,
    pub excluded: u64,
    pub budget_limited: u64,
    pub capacity_rejected: u64,
    pub queue_rejected: u64,
    pub invalid_rejected: u64,
    pub expired_groups: u64,
    pub tracked_fingerprints: usize,
}

struct Group {
    occurrences: u64,
    pending: u64,
    last_seen: f64,
    last_forward: Option<f64>,
}

pub struct Policy {
    config: PolicyConfig,
    groups: HashMap<[u8; 32], Group>,
    budget: FixedWindowState,
    next_sweep: f64,
    statistics: Statistics,
}

impl Policy {
    /// Time must be elapsed monotonic seconds supplied by the host.
    ///
    /// # Errors
    /// Rejects invalid policy limits.
    pub fn new(config: PolicyConfig) -> Result<Self, &'static str> {
        config.validate()?;
        Ok(Self {
            config,
            groups: HashMap::new(),
            budget: FixedWindowState {
                count: 0,
                window_start: 0.0,
            },
            next_sweep: 0.0,
            statistics: Statistics::default(),
        })
    }

    #[must_use]
    pub fn statistics(&self) -> Statistics {
        Statistics {
            tracked_fingerprints: self.groups.len(),
            ..self.statistics.clone()
        }
    }

    /// Commit budget and representative state only after queue admission.
    /// Suppression is terminal policy success, never a delivery failure.
    pub fn submit(
        &mut self,
        mut event: Event,
        now: f64,
        forward: impl FnOnce(Event) -> bool,
    ) -> Outcome {
        self.statistics.received = self.statistics.received.saturating_add(1);
        if !valid_event(&event) || !now.is_finite() || now < 0.0 {
            self.statistics.invalid_rejected = self.statistics.invalid_rejected.saturating_add(1);
            return outcome(Decision::Reject, "invalid_event", 0);
        }
        if self.config.excluded_exception_classes.iter().any(|class| {
            event
                .exception
                .as_ref()
                .is_some_and(|exception| exception.class == *class)
        }) {
            self.statistics.excluded = self.statistics.excluded.saturating_add(1);
            return outcome(Decision::Suppress, "excluded_exception", 1);
        }

        // Sweep at most once per minute, including under identity-spray load.
        if now >= self.next_sweep {
            let before = self.groups.len();
            let retention = f64::from(self.config.retention_seconds);
            self.groups
                .retain(|_, group| now - group.last_seen < retention);
            self.statistics.expired_groups = self
                .statistics
                .expired_groups
                .saturating_add(u64::try_from(before - self.groups.len()).unwrap_or(u64::MAX));
            self.next_sweep = now + 60.0;
        }

        let key = fingerprint(&event);
        if !self.groups.contains_key(&key) && self.groups.len() >= self.config.max_fingerprints {
            self.statistics.capacity_rejected = self.statistics.capacity_rejected.saturating_add(1);
            return outcome(Decision::Reject, "fingerprint_capacity", 0);
        }
        let group = self.groups.entry(key).or_insert(Group {
            occurrences: 0,
            pending: 0,
            last_seen: now,
            last_forward: None,
        });
        group.occurrences = group.occurrences.saturating_add(1);
        group.pending = group.pending.saturating_add(1);
        group.last_seen = now;
        if group
            .last_forward
            .is_some_and(|last| now - last < f64::from(self.config.representative_interval_seconds))
        {
            self.statistics.aggregated = self.statistics.aggregated.saturating_add(1);
            return outcome(Decision::Aggregate, "duplicate", group.occurrences);
        }

        let budget = FixedWindow::check(
            self.budget,
            now,
            FixedWindowParams {
                limit: u64::from(self.config.budget_events),
                window_size: f64::from(self.config.budget_window_seconds),
            },
        );
        if !budget.allowed {
            self.statistics.budget_limited = self.statistics.budget_limited.saturating_add(1);
            return outcome(Decision::Aggregate, "destination_budget", group.occurrences);
        }

        // Ingress validates object-shaped context and extra before this point.
        if event.context.get("extra").is_none_or(Value::is_null) {
            event.context["extra"] = json!({});
        }
        event.context["extra"]["lapsossd"] = json!({
            "occurrences": group.occurrences,
            "occurrences_since_previous_forward": group.pending,
            "suppressed_since_previous_forward": group.pending.saturating_sub(1),
        });
        if !forward(event) {
            self.statistics.queue_rejected = self.statistics.queue_rejected.saturating_add(1);
            return outcome(Decision::Reject, "delivery_queue_full", group.occurrences);
        }
        self.budget = budget.state;
        group.last_forward = Some(now);
        group.pending = 0;
        self.statistics.forwarded = self.statistics.forwarded.saturating_add(1);
        outcome(Decision::Forward, "representative", group.occurrences)
    }
}

pub(crate) fn valid_event(event: &Event) -> bool {
    !event.id.is_nil()
        && matches!(event.event_type.as_str(), "exception" | "message")
        && event.context.is_object()
        && event
            .context
            .get("extra")
            .is_none_or(|extra| extra.is_null() || extra.is_object())
}

const fn outcome(decision: Decision, reason: &'static str, occurrences: u64) -> Outcome {
    Outcome {
        decision,
        reason,
        occurrences,
    }
}

fn fingerprint(event: &Event) -> [u8; 32] {
    // Hash bounded input rather than retaining arbitrary caller-controlled keys.
    // Environment and release isolate deployments even with explicit grouping.
    let grouping = if !event.fingerprint.is_null() && event.fingerprint != json!([]) {
        event.fingerprint.clone()
    } else if event.exception.is_some() && !event.frames.is_empty() {
        json!([
            event.exception_type(),
            event
                .frames
                .iter()
                .take(10)
                .map(|frame| {
                    (
                        &frame.filename,
                        frame.line_number,
                        &frame.method_name,
                        &frame.function,
                    )
                })
                .collect::<Vec<_>>()
        ])
    } else {
        json!([
            event.event_type,
            event.exception_type(),
            event.exception_message()
        ])
    };
    let identity = json!([event.environment, event.release, grouping]);
    Sha256::digest(identity.to_string().as_bytes()).into()
}

#[cfg(test)]
mod tests;
