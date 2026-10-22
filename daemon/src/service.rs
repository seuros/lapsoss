use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    sync::{Arc, mpsc},
    time::{Duration, Instant},
};

use lapsoss::{
    Adapter, AdapterConfig, Config, Dispatcher, Event, HttpAdapter, LoggerAdapter, SubmitError,
    TransportConfig,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::{runtime::Handle, sync::oneshot};

use crate::{
    policy::PolicyConfig,
    store::{Delivery, Result, StorageConfig, Store},
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DestinationConfig {
    pub adapter: AdapterConfig,
    #[serde(default)]
    pub policy: PolicyConfig,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DaemonConfig {
    pub socket: String,
    pub storage: StorageConfig,
    pub destinations: Vec<DestinationConfig>,
    #[serde(default)]
    pub queue: Config,
    #[serde(default)]
    pub transport: TransportConfig,
}

enum Request {
    Submit(Box<Event>),
    Statistics,
    Flush(Duration),
    Shutdown(Duration),
}

struct Command {
    request: Request,
    reply: oneshot::Sender<Value>,
}

/// One bounded mailbox and one storage thread. Socket deadlines never interrupt
/// a transaction, and timed-out clients cannot create unbounded blocking work.
#[derive(Clone)]
pub struct Service {
    sender: mpsc::SyncSender<Command>,
}

struct Destination {
    name: String,
    dispatcher: Dispatcher,
    waiting: VecDeque<(String, Event)>,
    inflight: BTreeMap<u64, String>,
}

struct Barrier {
    jobs: HashSet<String>,
    deadline: Instant,
    reply: oneshot::Sender<Value>,
}

struct Worker {
    store: Store,
    destinations: Vec<Destination>,
    origin: Instant,
    base: f64,
    healthy: bool,
    barriers: Vec<Barrier>,
    next_summary: Instant,
}

impl Service {
    /// # Errors
    /// Rejects invalid configuration, unsafe storage, or incompatible durable state.
    pub fn new(config: &DaemonConfig) -> Result<Self> {
        config.queue.validate()?;
        config.transport.validate()?;
        if config.destinations.is_empty() || config.destinations.len() > 16 {
            return Err("configure 1–16 destinations".into());
        }
        if config.queue.acknowledge_completions {
            return Err("completion acknowledgement is managed by the durable worker".into());
        }
        let mut destinations = Vec::new();
        for entry in &config.destinations {
            let name = &entry.adapter.name;
            if name.is_empty()
                || name.len() > 64
                || !name
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
            {
                return Err(
                    "destination names must be 1–64 ASCII letters, digits, underscores, or hyphens"
                        .into(),
                );
            }
            if destinations
                .iter()
                .any(|destination: &Destination| destination.name == *name)
            {
                return Err("destination names must be unique".into());
            }
            let adapter: Arc<dyn Adapter> = if entry.adapter.adapter_type == "logger" {
                Arc::new(LoggerAdapter::new(name))
            } else {
                Arc::new(HttpAdapter::new(
                    entry.adapter.clone(),
                    config.transport.clone(),
                )?)
            };
            let queue = Config {
                acknowledge_completions: true,
                ..config.queue.clone()
            };
            destinations.push(Destination {
                name: name.clone(),
                dispatcher: Dispatcher::new(Handle::current(), queue, vec![adapter])?,
                waiting: VecDeque::new(),
                inflight: BTreeMap::new(),
            });
        }
        let store = Store::open(&config.storage, &config.queue, &config.destinations)?;
        let base = store.clock;
        for (name, key, event) in store.pending()? {
            destinations
                .iter_mut()
                .find(|destination| destination.name == name)
                .ok_or("queued job has no configured destination")?
                .waiting
                .push_back((key, event));
        }
        let worker = Worker {
            store,
            destinations,
            base,
            origin: Instant::now(),
            healthy: true,
            barriers: Vec::new(),
            next_summary: Instant::now(),
        };
        let (sender, receiver) = mpsc::sync_channel(32);
        std::thread::Builder::new()
            .name("lapsossd-storage".into())
            .spawn(move || {
                let mut worker = worker;
                let reply = worker.run(&receiver);
                drop(worker); // Release the database lock before acknowledging shutdown.
                if let Some((reply, drained)) = reply {
                    drop(reply.send(json!({ "ok": drained })));
                }
            })?;
        Ok(Self { sender })
    }

    pub async fn submit(&self, event: Event) -> Value {
        self.request(Request::Submit(Box::new(event))).await
    }

    pub async fn statistics(&self) -> Value {
        self.request(Request::Statistics).await
    }

    pub async fn flush(&self, timeout: Duration) -> bool {
        self.request(Request::Flush(timeout)).await["ok"] == true
    }

    pub async fn shutdown(&self, timeout: Duration) -> bool {
        tokio::time::timeout(timeout, self.request(Request::Shutdown(timeout)))
            .await
            .is_ok_and(|response| response["ok"] == true)
    }

    async fn request(&self, request: Request) -> Value {
        let (reply, response) = oneshot::channel();
        if self.sender.try_send(Command { request, reply }).is_err() {
            return json!({ "ok": false, "error": "storage_busy" });
        }
        response
            .await
            .unwrap_or_else(|_| json!({ "ok": false, "error": "storage_unavailable" }))
    }
}

impl Worker {
    fn now(&self) -> f64 {
        self.base + self.origin.elapsed().as_secs_f64()
    }

    fn run(
        &mut self,
        receiver: &mpsc::Receiver<Command>,
    ) -> Option<(oneshot::Sender<Value>, bool)> {
        let mut closing: Option<(Instant, oneshot::Sender<Value>)> = None;
        loop {
            if self.healthy
                && let Err(error) = self.tick(true, closing.is_none())
            {
                self.healthy = false;
                eprintln!(
                    "lapsossd: durable storage failed: {error}; admission stopped until restart"
                );
            }
            if let Some((deadline, _)) = &closing
                && (!self.healthy || self.idle() || Instant::now() >= *deadline)
            {
                break;
            }
            match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(command) if command.reply.is_closed() => {}
                Ok(Command {
                    request: Request::Shutdown(timeout),
                    reply,
                }) => {
                    closing = Some((Instant::now() + timeout, reply));
                }
                Ok(Command {
                    request: Request::Flush(timeout),
                    reply,
                }) if self.healthy && closing.is_none() => {
                    let jobs = self
                        .destinations
                        .iter()
                        .flat_map(|destination| {
                            destination
                                .waiting
                                .iter()
                                .map(|(key, _)| key.clone())
                                .chain(destination.inflight.values().cloned())
                        })
                        .collect();
                    self.barriers.push(Barrier {
                        jobs,
                        deadline: Instant::now() + timeout,
                        reply,
                    });
                }
                Ok(Command { request, reply }) => {
                    let response = if !self.healthy || closing.is_some() {
                        Ok(json!({ "ok": false, "error": "storage_unavailable" }))
                    } else {
                        self.execute(request)
                    };
                    let response = response.unwrap_or_else(|error| {
                        self.healthy = false;
                        eprintln!(
                            "lapsossd: durable transaction failed: {error}; admission stopped until restart"
                        );
                        json!({ "ok": false, "error": "storage_unavailable" })
                    });
                    drop(reply.send(response));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        let drained = self.healthy && self.idle();
        for destination in &self.destinations {
            destination.dispatcher.cancel();
        }
        if self.healthy
            && let Err(error) = self.tick(false, false)
        {
            self.healthy = false;
            eprintln!(
                "lapsossd: shutdown checkpoint failed: {error}; unfinished jobs remain replayable"
            );
        }
        for barrier in self.barriers.drain(..) {
            drop(barrier.reply.send(json!({ "ok": false })));
        }
        closing.map(|(_, reply)| (reply, drained && self.healthy))
    }

    fn execute(&mut self, request: Request) -> Result<Value> {
        match request {
            Request::Submit(event) => {
                let admission = self.store.admit(&event, self.now())?;
                self.queue_jobs(admission.jobs)?;
                Ok(admission.response)
            }
            Request::Statistics => {
                let mut statistics = self.store.statistics()?;
                if let Some(destinations) = statistics["destinations"].as_array_mut() {
                    for (statistic, destination) in destinations.iter_mut().zip(&self.destinations)
                    {
                        statistic["delivery"] = json!(destination.dispatcher.statistics());
                    }
                }
                Ok(statistics)
            }
            Request::Flush(_) | Request::Shutdown(_) => Ok(json!({ "ok": false })),
        }
    }

    fn queue_jobs(&mut self, jobs: Vec<Delivery>) -> Result<()> {
        for (name, key, event) in jobs {
            self.destinations
                .iter_mut()
                .find(|destination| destination.name == name)
                .ok_or("missing committed destination")?
                .waiting
                .push_back((key, event));
        }
        Ok(())
    }

    fn tick(&mut self, dispatch: bool, generate_summaries: bool) -> Result<()> {
        let mut results = Vec::new();
        let mut acknowledgements = Vec::new();
        for (index, destination) in self.destinations.iter().enumerate() {
            for completion in destination.dispatcher.take_completions() {
                let key = destination
                    .inflight
                    .get(&completion.sequence)
                    .ok_or("untracked completion")?
                    .clone();
                results.push((
                    destination.name.clone(),
                    key,
                    completion.outcomes.iter().all(|outcome| outcome.success),
                    completion.abandoned,
                ));
                acknowledgements.push((index, completion.sequence));
            }
        }
        if !results.is_empty() {
            self.store.complete(&results, self.now())?;
            for ((_, key, _, abandoned), (index, sequence)) in results.iter().zip(acknowledgements)
            {
                self.destinations[index].dispatcher.acknowledge(sequence);
                self.destinations[index].inflight.remove(&sequence);
                if !abandoned {
                    for barrier in &mut self.barriers {
                        barrier.jobs.remove(key);
                    }
                }
            }
        }
        if generate_summaries && Instant::now() >= self.next_summary {
            self.next_summary = Instant::now() + Duration::from_millis(100);
            let jobs = self.store.summarize(self.now())?;
            self.queue_jobs(jobs)?;
        }
        for destination in &mut self.destinations {
            if !dispatch {
                continue;
            }
            while let Some((key, event)) = destination.waiting.front() {
                match destination.dispatcher.submit(event.clone()) {
                    Ok(receipt) => {
                        destination.inflight.insert(receipt.sequence, key.clone());
                        destination.waiting.pop_front();
                    }
                    Err(SubmitError::Full) => break,
                    Err(_) => return Err("dispatcher refused a durable job".into()),
                }
            }
        }
        // Return the original watermark result, not future submissions' state.
        let mut pending = Vec::new();
        for barrier in self.barriers.drain(..) {
            if barrier.reply.is_closed() {
                continue;
            }
            if barrier.jobs.is_empty() || Instant::now() >= barrier.deadline {
                drop(barrier.reply.send(json!({ "ok": barrier.jobs.is_empty() })));
            } else {
                pending.push(barrier);
            }
        }
        self.barriers = pending;
        Ok(())
    }

    fn idle(&self) -> bool {
        self.destinations
            .iter()
            .all(|destination| destination.waiting.is_empty() && destination.inflight.is_empty())
    }
}
