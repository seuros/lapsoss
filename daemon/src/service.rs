use std::{error::Error, sync::Arc, time::Duration};

use lapsoss::{
    Adapter, AdapterConfig, Config, Dispatcher, Event, HttpAdapter, LoggerAdapter, TransportConfig,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::runtime::Handle;

use crate::policy::{Policy, PolicyConfig};

/// One daemon serves one trusted application/project. Vendor credentials are
/// configured here, never supplied by event producers over the socket.
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
    pub destinations: Vec<DestinationConfig>,
    #[serde(default)]
    pub queue: Config,
    #[serde(default)]
    pub transport: TransportConfig,
}

struct Destination {
    name: String,
    policy: Policy,
    dispatcher: Dispatcher,
}

pub struct Service {
    destinations: Vec<Destination>,
}

impl Service {
    /// # Errors
    /// Rejects invalid destinations, policies, or queue configuration.
    pub fn new(config: &DaemonConfig) -> Result<Self, Box<dyn Error>> {
        config.queue.validate()?;
        config.transport.validate()?;
        if config.destinations.is_empty() || config.destinations.len() > 16 {
            return Err("configure 1–16 destinations".into());
        }
        if config.queue.acknowledge_completions {
            return Err("daemon queues must automatically release completions".into());
        }
        let mut destinations = Vec::new();
        for entry in &config.destinations {
            let name = entry.adapter.name.clone();
            if destinations
                .iter()
                .any(|destination: &Destination| destination.name == name)
            {
                return Err("destination names must be unique".into());
            }
            let adapter: Arc<dyn Adapter> = if entry.adapter.adapter_type == "logger" {
                Arc::new(LoggerAdapter::new(&name))
            } else {
                Arc::new(HttpAdapter::new(
                    entry.adapter.clone(),
                    config.transport.clone(),
                )?)
            };
            destinations.push(Destination {
                name,
                policy: Policy::new(entry.policy.clone())?,
                dispatcher: Dispatcher::new(
                    Handle::current(),
                    config.queue.clone(),
                    vec![adapter],
                )?,
            });
        }
        Ok(Self { destinations })
    }

    pub fn submit(&mut self, event: &Event, now: f64) -> Value {
        let outcomes: Vec<_> = self
            .destinations
            .iter_mut()
            .map(|destination| {
                let outcome = destination
                    .policy
                    .submit(event.clone(), now, |representative| {
                        destination.dispatcher.submit(representative).is_ok()
                    });
                json!({ "destination": destination.name, "outcome": outcome })
            })
            .collect();
        json!({ "ok": true, "event_id": event.id, "destinations": outcomes })
    }

    #[must_use]
    pub fn statistics(&self) -> Value {
        json!({
            "ok": true,
            "destinations": self.destinations.iter().map(|destination| json!({
                "name": destination.name,
                "policy": destination.policy.statistics(),
                "delivery": destination.dispatcher.statistics(),
            })).collect::<Vec<_>>()
        })
    }

    #[must_use]
    pub fn dispatchers(&self) -> Vec<Dispatcher> {
        self.destinations
            .iter()
            .map(|destination| destination.dispatcher.clone())
            .collect()
    }
}

pub async fn flush(dispatchers: Vec<Dispatcher>, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    for dispatcher in dispatchers {
        if !dispatcher
            .flush(deadline.saturating_duration_since(tokio::time::Instant::now()))
            .await
        {
            return false;
        }
    }
    true
}
