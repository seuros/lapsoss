use std::{
    collections::{BTreeMap, HashSet},
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use serde::{Deserialize, Serialize};
use tokio::{
    runtime::Handle,
    sync::{Notify, Semaphore, oneshot},
    task::{AbortHandle, JoinSet},
};
use uuid::Uuid;

use crate::{Adapter, Event};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub max_events: usize,
    pub max_bytes: usize,
    pub concurrency_per_adapter: usize,
    /// Language bridges keep capacity reserved until their callbacks finish.
    pub acknowledge_completions: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_events: 1000,
            max_bytes: 10 * 1024 * 1024,
            concurrency_per_adapter: 4,
            acknowledge_completions: false,
        }
    }
}

impl Config {
    /// Validate queue capacities before constructing any worker state.
    ///
    /// # Errors
    /// Returns a configuration error for zero capacities or an unsupported
    /// semaphore size.
    pub fn validate(&self) -> Result<(), SubmitError> {
        (self.max_events > 0
            && self.max_bytes > 0
            && self.concurrency_per_adapter > 0
            && self.concurrency_per_adapter <= Semaphore::MAX_PERMITS)
            .ok_or_else(|| {
                SubmitError::Configuration(
                    "capacities must be positive and concurrency within semaphore limits".into(),
                )
            })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeliveryOutcome {
    pub adapter: String,
    pub success: bool,
    pub error: Option<String>,
    pub status: Option<u16>,
    pub log: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Completion {
    pub sequence: u64,
    pub event_id: Uuid,
    pub outcomes: Vec<DeliveryOutcome>,
    pub abandoned: bool,
}

#[derive(Debug)]
pub struct Receipt {
    pub sequence: u64,
    pub event_id: Uuid,
    receiver: oneshot::Receiver<Completion>,
}

impl Receipt {
    /// Wait for every selected destination to reach a terminal outcome.
    ///
    /// # Errors
    /// Returns a receive error if the runtime drops the dispatcher task.
    pub async fn wait(self) -> Result<Completion, oneshot::error::RecvError> {
        self.receiver.await
    }
}

#[derive(Clone, Debug, thiserror::Error)]
pub enum SubmitError {
    #[error("Dispatcher is closed")]
    Closed,
    #[error("Dispatcher capacity exhausted")]
    Full,
    #[error("Invalid dispatcher configuration: {0}")]
    Configuration(String),
    #[error("Event is not serializable")]
    InvalidEvent,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Statistics {
    pub outstanding_events: usize,
    pub outstanding_bytes: usize,
    pub accepted: u64,
    pub rejected: u64,
    pub delivered: u64,
    pub failed: u64,
    pub abandoned: u64,
}

struct Record {
    bytes: usize,
    event_id: Uuid,
    destinations: Vec<String>,
    partial_outcomes: Vec<DeliveryOutcome>,
    abort: Option<AbortHandle>,
    completion: Option<Completion>,
    completion_taken: bool,
    sender: Option<oneshot::Sender<Completion>>,
}

#[derive(Default)]
struct State {
    closed: bool,
    sequence: u64,
    records: BTreeMap<u64, Record>,
    stats: Statistics,
}

struct Destination {
    adapter: Arc<dyn Adapter>,
    permits: Arc<Semaphore>,
}

struct Inner {
    config: Config,
    runtime: Handle,
    destinations: Mutex<Vec<Destination>>,
    state: Mutex<State>,
    changed: Notify,
}

impl Inner {
    fn destinations(&self) -> MutexGuard<'_, Vec<Destination>> {
        // Like state(), no user code runs while this registry is locked.
        self.destinations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // No user code executes under this lock. Recover for deterministic
        // shutdown rather than panicking in a foreign-language destructor.
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn finish(&self, completion: &Completion) {
        let mut state = self.state();
        let Some(record) = state.records.get_mut(&completion.sequence) else {
            return;
        };
        if record.completion.is_some() {
            return;
        }
        if let Some(sender) = record.sender.take() {
            // A caller may deliberately discard its receipt.
            drop(sender.send(completion.clone()));
        }
        record.abort = None;
        record.completion = Some(completion.clone());
        for outcome in &completion.outcomes {
            if outcome.success {
                state.stats.delivered = state.stats.delivered.strict_add(1);
            } else {
                state.stats.failed = state.stats.failed.strict_add(1);
            }
        }
        if completion.abandoned {
            state.stats.abandoned = state.stats.abandoned.strict_add(1);
        }
        if !self.config.acknowledge_completions {
            remove_record(&mut state, completion.sequence);
        }
        drop(state);
        self.changed.notify_waiters();
    }
}

fn remove_record(state: &mut State, sequence: u64) {
    if let Some(record) = state.records.remove(&sequence) {
        state.stats.outstanding_events = state.stats.outstanding_events.strict_sub(1);
        state.stats.outstanding_bytes = state.stats.outstanding_bytes.strict_sub(record.bytes);
    }
}

/// Instance-based dispatcher. All instances are independent; no global runtime
/// or global client is installed. Keep the supplied runtime alive until shutdown.
#[derive(Clone)]
pub struct Dispatcher {
    inner: Arc<Inner>,
}

impl Dispatcher {
    /// # Errors
    /// Rejects invalid capacities and empty or duplicate destination names.
    pub fn new(
        runtime: Handle,
        config: Config,
        adapters: Vec<Arc<dyn Adapter>>,
    ) -> Result<Self, SubmitError> {
        config.validate()?;
        let mut names = HashSet::new();
        for adapter in &adapters {
            if adapter.name().is_empty() || !names.insert(adapter.name().to_owned()) {
                return Err(SubmitError::Configuration(
                    "adapter names must be nonempty and unique".into(),
                ));
            }
        }
        let destinations = adapters
            .into_iter()
            .map(|adapter| Destination {
                adapter,
                permits: Arc::new(Semaphore::new(config.concurrency_per_adapter)),
            })
            .collect();
        Ok(Self {
            inner: Arc::new(Inner {
                config,
                runtime,
                destinations: Mutex::new(destinations),
                state: Mutex::new(State::default()),
                changed: Notify::new(),
            }),
        })
    }

    /// Submit to every registered destination.
    ///
    /// # Errors
    /// Rejects closed dispatchers, exhausted capacity and invalid events.
    pub fn submit(&self, event: Event) -> Result<Receipt, SubmitError> {
        self.submit_selected(event, None)
    }

    /// Atomically replace destination definitions. Accepted jobs retain their
    /// captured adapters; future jobs use the new definitions.
    ///
    /// # Errors
    /// Rejects empty or duplicate destination names.
    pub fn replace_adapters(&self, adapters: Vec<Arc<dyn Adapter>>) -> Result<(), SubmitError> {
        let mut names = HashSet::new();
        if adapters
            .iter()
            .any(|a| a.name().is_empty() || !names.insert(a.name().to_owned()))
        {
            return Err(SubmitError::Configuration(
                "adapter names must be nonempty and unique".into(),
            ));
        }
        let mut destinations = self.inner.destinations();
        let updated = adapters
            .into_iter()
            .map(|adapter| {
                let permits = destinations
                    .iter()
                    .find(|d| d.adapter.name() == adapter.name())
                    .map_or_else(
                        || Arc::new(Semaphore::new(self.inner.config.concurrency_per_adapter)),
                        |d| Arc::clone(&d.permits),
                    );
                Destination { adapter, permits }
            })
            .collect();
        *destinations = updated;
        drop(destinations);
        Ok(())
    }

    /// Select among registered destinations, allowing a language bridge to
    /// snapshot enabled adapters at capture time. An empty list still admits an
    /// event, reserving capacity for language-side custom adapter work.
    ///
    /// # Errors
    /// Rejects unknown destinations, closed dispatchers, exhausted capacity and
    /// events that cannot be serialized.
    pub fn submit_to(&self, event: Event, names: &[String]) -> Result<Receipt, SubmitError> {
        self.submit_selected(event, Some(names))
    }

    fn submit_selected(
        &self,
        event: Event,
        selection: Option<&[String]>,
    ) -> Result<Receipt, SubmitError> {
        let definitions = self.inner.destinations();
        if let Some(names) = selection
            && names
                .iter()
                .any(|name| !definitions.iter().any(|d| d.adapter.name() == name))
        {
            return Err(SubmitError::Configuration("unknown destination".into()));
        }
        let destinations = definitions
            .iter()
            .filter(|d| {
                selection.is_none_or(|names| names.iter().any(|name| name == d.adapter.name()))
            })
            .map(|d| Destination {
                adapter: Arc::clone(&d.adapter),
                permits: Arc::clone(&d.permits),
            })
            .collect::<Vec<_>>();
        drop(definitions);
        let names = destinations
            .iter()
            .map(|d| d.adapter.name().to_owned())
            .collect();
        let bytes = serde_json::to_vec(&event)
            .map_err(|_| SubmitError::InvalidEvent)?
            .len();
        let mut state = self.inner.state();
        if state.closed {
            return Err(SubmitError::Closed);
        }
        if state.stats.outstanding_events >= self.inner.config.max_events
            || bytes
                > self
                    .inner
                    .config
                    .max_bytes
                    .saturating_sub(state.stats.outstanding_bytes)
        {
            state.stats.rejected = state.stats.rejected.strict_add(1);
            return Err(SubmitError::Full);
        }
        state.sequence = state.sequence.strict_add(1);
        let sequence = state.sequence;
        let event_id = event.id;
        let (sender, receiver) = oneshot::channel();
        state.records.insert(
            sequence,
            Record {
                bytes,
                event_id,
                destinations: names,
                partial_outcomes: Vec::new(),
                abort: None,
                completion: None,
                completion_taken: false,
                sender: Some(sender),
            },
        );
        state.stats.outstanding_events = state.stats.outstanding_events.strict_add(1);
        state.stats.outstanding_bytes = state.stats.outstanding_bytes.strict_add(bytes);
        state.stats.accepted = state.stats.accepted.strict_add(1);
        let inner = Arc::clone(&self.inner);
        let event = Arc::new(event);
        let task = self
            .inner
            .runtime
            .spawn(deliver(inner, event, sequence, destinations));
        if let Some(record) = state.records.get_mut(&sequence) {
            record.abort = Some(task.abort_handle());
        }
        drop(task);
        drop(state);
        Ok(Receipt {
            sequence,
            event_id,
            receiver,
        })
    }

    /// Return each completion at most once. In acknowledged mode, capacity is
    /// held until `acknowledge` is called, including while callbacks execute.
    #[must_use]
    pub fn take_completions(&self) -> Vec<Completion> {
        let mut state = self.inner.state();
        state
            .records
            .values_mut()
            .filter_map(|record| {
                if record.completion_taken {
                    return None;
                }
                let completion = record.completion.clone()?;
                record.completion_taken = true;
                Some(completion)
            })
            .collect()
    }

    pub fn acknowledge(&self, sequence: u64) {
        let mut state = self.inner.state();
        if state
            .records
            .get(&sequence)
            .is_some_and(|r| r.completion.is_some())
        {
            remove_record(&mut state, sequence);
        }
        drop(state);
        self.inner.changed.notify_waiters();
    }

    #[must_use]
    pub fn watermark(&self) -> u64 {
        self.inner.state().sequence
    }

    #[must_use]
    pub fn is_settled(&self, watermark: u64) -> bool {
        self.inner
            .state()
            .records
            .range(..=watermark)
            .next()
            .is_none()
    }

    #[must_use]
    pub fn statistics(&self) -> Statistics {
        self.inner.state().stats.clone()
    }

    pub fn close(&self) {
        self.inner.state().closed = true;
    }

    pub async fn flush(&self, timeout: Duration) -> bool {
        self.flush_through(self.watermark(), timeout).await
    }

    pub async fn flush_through(&self, watermark: u64, timeout: Duration) -> bool {
        tokio::time::timeout(timeout, async {
            loop {
                let notified = self.inner.changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.is_settled(watermark) {
                    return;
                }
                notified.await;
            }
        })
        .await
        .is_ok()
    }

    /// Cancel unfinished tasks and produce explicit abandoned outcomes.
    pub fn cancel(&self) {
        self.close();
        let pending = {
            let state = self.inner.state();
            state
                .records
                .iter()
                .filter(|(_, r)| r.completion.is_none())
                .map(|(sequence, r)| {
                    if let Some(abort) = &r.abort {
                        abort.abort();
                    }
                    let mut outcomes = r.partial_outcomes.clone();
                    for name in &r.destinations {
                        if !outcomes.iter().any(|o| &o.adapter == name) {
                            outcomes.push(DeliveryOutcome {
                                adapter: name.clone(),
                                success: false,
                                error: Some("Delivery abandoned at shutdown".into()),
                                status: None,
                                log: None,
                            });
                        }
                    }
                    Completion {
                        sequence: *sequence,
                        event_id: r.event_id,
                        abandoned: true,
                        outcomes,
                    }
                })
                .collect::<Vec<_>>()
        };
        for completion in pending {
            self.inner.finish(&completion);
        }
    }

    pub async fn shutdown(&self, timeout: Duration) -> bool {
        self.close();
        let settled = self.flush(timeout).await;
        if !settled {
            self.cancel();
        }
        settled
    }
}

async fn deliver(
    inner: Arc<Inner>,
    event: Arc<Event>,
    sequence: u64,
    destinations: Vec<Destination>,
) {
    let mut tasks = JoinSet::new();
    for Destination { adapter, permits } in destinations {
        let event = Arc::clone(&event);
        let name = adapter.name().to_owned();
        tasks.spawn(async move {
            let result = match permits.acquire_owned().await {
                Ok(_permit) => adapter.capture(&event).await,
                Err(_) => Err(crate::AdapterError::new("Destination closed")),
            };
            DeliveryOutcome {
                adapter: name,
                success: result.is_ok(),
                error: result.as_ref().err().map(|e| e.message.clone()),
                status: result.as_ref().err().and_then(|e| e.status),
                log: adapter.log_output(&event),
            }
        });
    }
    let mut outcomes = Vec::new();
    while let Some(result) = tasks.join_next().await {
        // Panicking adapters are resolved below by their missing destination.
        if let Ok(outcome) = result {
            if let Some(record) = inner.state().records.get_mut(&sequence) {
                record.partial_outcomes.push(outcome.clone());
            }
            outcomes.push(outcome);
        }
    }
    let names = {
        let state = inner.state();
        state
            .records
            .get(&sequence)
            .map(|r| r.destinations.clone())
            .unwrap_or_default()
    };
    for name in names {
        if !outcomes.iter().any(|o| o.adapter == name) {
            outcomes.push(DeliveryOutcome {
                adapter: name,
                success: false,
                error: Some("Adapter task terminated".into()),
                status: None,
                log: None,
            });
        }
    }
    inner.finish(&Completion {
        sequence,
        event_id: event.id,
        outcomes,
        abandoned: false,
    });
}

#[cfg(test)]
mod tests;
