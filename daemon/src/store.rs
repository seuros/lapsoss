use std::{
    error::Error,
    fs::{File, OpenOptions},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path,
};

use lapsoss::{Config, Event};
use redb::{Database, Durability, ReadableTable, TableDefinition, WriteTransaction};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

use crate::{
    policy::{Group, Policy, State, digest, fingerprint},
    service::DestinationConfig,
};

pub type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
const DATA: TableDefinition<&str, &[u8]> = TableDefinition::new("state");
const EXPIRY: TableDefinition<(u64, &str), ()> = TableDefinition::new("expiry");

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct StorageConfig {
    pub path: String,
    pub max_receipts: usize,
    pub receipt_retention_seconds: u32,
    pub allow_destination_changes: bool,
    pub retry_failed_on_startup: bool,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            path: String::new(),
            max_receipts: 100_000,
            receipt_retention_seconds: 300,
            allow_destination_changes: false,
            retry_failed_on_startup: false,
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Ledger {
    clock: f64,
    receipts: usize,
}

#[derive(Default, Serialize, Deserialize)]
struct Destination {
    binding: String,
    policy: State,
    events: usize,
    bytes: usize,
    failed: usize,
    delivered: u64,
}

#[derive(Serialize, Deserialize)]
struct Timed<T> {
    expires: u64,
    value: T,
}

#[derive(Serialize, Deserialize)]
struct Receipt {
    digest: String,
    response: Value,
    jobs: usize,
}

#[derive(Serialize, Deserialize)]
struct Job {
    event: Event,
    bytes: usize,
    failed: bool,
}

pub struct Admission {
    pub response: Value,
    pub jobs: Vec<(String, String, Event)>,
}

pub struct Store {
    db: Database,
    config: StorageConfig,
    queue: Config,
    policies: Vec<(String, Policy, u32)>,
    pub clock: f64,
}

impl Store {
    pub fn open(
        config: &StorageConfig,
        queue: &Config,
        destinations: &[DestinationConfig],
    ) -> Result<Self> {
        if config.max_receipts == 0
            || config.max_receipts > 1_000_000
            || config.receipt_retention_seconds == 0
        {
            return Err("storage receipt limits must be positive; max_receipts <= 1000000".into());
        }
        let (db, initialized_file) = open_database(Path::new(&config.path))?;
        let tx = db.begin_write()?;
        tx.open_table(EXPIRY)?;
        match get::<u32>(&tx, "schema")? {
            Some(1) => {}
            Some(_) => return Err("unsupported storage schema; refusing to reset state".into()),
            None if !initialized_file => {
                put(&tx, "schema", &1_u32)?;
                put(&tx, "ledger", &Ledger::default())?;
            }
            None => return Err("storage schema is missing; refusing to reset state".into()),
        }
        let ledger: Ledger = get(&tx, "ledger")?.ok_or("missing storage ledger")?;
        if !ledger.clock.is_finite() || ledger.clock < 0.0 {
            return Err("invalid persisted clock".into());
        }
        milliseconds(ledger.clock)?;
        if ledger.receipts > 1_000_000 {
            return Err("invalid persisted receipt count".into());
        }
        let configured: Vec<_> = destinations
            .iter()
            .map(|entry| entry.adapter.name.as_str())
            .collect();
        for (key, value) in entries(&tx, "destination/")? {
            let name = key.trim_start_matches("destination/");
            let meta: Destination = serde_json::from_slice(&value)?;
            if !configured.contains(&name) {
                // Do not orphan durable jobs, counts, or budgets under new names.
                return Err(
                    "stored destinations must remain configured; migrate state explicitly".into(),
                );
            }
            if meta.policy.statistics.tracked_fingerprints > 65_536 || meta.failed > meta.events {
                return Err("invalid persisted destination counters".into());
            }
        }
        let mut policies = Vec::new();
        for entry in destinations {
            let name = &entry.adapter.name;
            let key = format!("destination/{name}");
            let binding = digest(&serde_json::to_vec(&entry.adapter)?);
            let mut meta: Destination = get(&tx, &key)?.unwrap_or_default();
            if meta.events > 0 && meta.binding != binding && !config.allow_destination_changes {
                return Err(
                    "pending or failed jobs require the original destination settings".into(),
                );
            }
            if meta.events > queue.max_events || meta.bytes > queue.max_bytes {
                return Err("queue limits cannot shrink below retained jobs".into());
            }
            meta.binding = binding;
            put(&tx, &key, &meta)?;
            policies.push((
                name.clone(),
                Policy::new(entry.policy.clone())?,
                entry.policy.retention_seconds,
            ));
        }
        if config.retry_failed_on_startup {
            for (key, bytes) in entries(&tx, "job/")? {
                let mut job: Job = serde_json::from_slice(&bytes)?;
                if job.failed {
                    let name = key.split('/').nth(1).ok_or("invalid job key")?;
                    let meta_key = format!("destination/{name}");
                    let mut meta: Destination =
                        get(&tx, &meta_key)?.ok_or("missing destination state")?;
                    meta.failed = meta.failed.checked_sub(1).ok_or("invalid failed count")?;
                    job.failed = false;
                    put(&tx, &key, &job)?;
                    put(&tx, &meta_key, &meta)?;
                }
            }
        }
        commit(tx)?;
        Ok(Self {
            db,
            config: config.clone(),
            queue: queue.clone(),
            policies,
            clock: ledger.clock,
        })
    }

    pub fn admit(&self, event: &Event, now: f64) -> Result<Admission> {
        let tx = self.db.begin_write()?;
        let mut ledger: Ledger = get(&tx, "ledger")?.ok_or("missing storage ledger")?;
        ledger.clock = now.max(ledger.clock);
        let now_ms = milliseconds(ledger.clock)?;
        cleanup(&tx, now_ms, &mut ledger)?;
        let receipt_key = format!("receipt/{}", event.id);
        let hash = digest(&serde_json::to_vec(event)?);
        if let Some(receipt) = get::<Timed<Receipt>>(&tx, &receipt_key)? {
            if receipt.expires > now_ms {
                let response = if receipt.value.digest == hash {
                    receipt.value.response
                } else {
                    json!({ "ok": false, "error": "event_id_conflict" })
                };
                put(&tx, "ledger", &ledger)?;
                commit(tx)?;
                return Ok(Admission {
                    response,
                    jobs: Vec::new(),
                });
            }
            expire(&tx, &receipt_key, receipt.expires, &mut ledger)?;
        }
        if ledger.receipts >= self.config.max_receipts {
            put(&tx, "ledger", &ledger)?;
            commit(tx)?;
            return Ok(Admission {
                response: json!({ "ok": false, "error": "receipt_capacity" }),
                jobs: Vec::new(),
            });
        }
        let admission = self.decide(&tx, event, &mut ledger)?;
        let expires = if admission.jobs.is_empty() {
            self.receipt_expiry(now_ms)
        } else {
            u64::MAX
        };
        timed(
            &tx,
            &receipt_key,
            expires,
            Receipt {
                digest: hash,
                response: admission.response.clone(),
                jobs: admission.jobs.len(),
            },
        )?;
        ledger.receipts += 1;
        put(&tx, "ledger", &ledger)?;
        commit(tx)?;
        Ok(admission)
    }

    fn decide(
        &self,
        tx: &WriteTransaction,
        event: &Event,
        ledger: &mut Ledger,
    ) -> Result<Admission> {
        let now_ms = milliseconds(ledger.clock)?;
        let mut jobs = Vec::new();
        let mut outcomes = Vec::new();
        for (name, policy, retention) in &self.policies {
            let meta_key = format!("destination/{name}");
            let group_key = format!("group/{name}/{}", fingerprint(event));
            let previous: Option<Timed<Group>> = get(tx, &group_key)?;
            if let Some(previous) = &previous
                && previous.expires <= now_ms
            {
                expire(tx, &group_key, previous.expires, ledger)?;
            }
            let mut meta: Destination = get(tx, &meta_key)?.ok_or("missing destination state")?;
            let mut group = previous
                .filter(|group| group.expires > now_ms)
                .map(|group| group.value);
            let mut representative = None;
            let outcome = policy.submit(
                event.clone(),
                ledger.clock,
                &mut meta.policy,
                &mut group,
                |event| {
                    let Ok(bytes) = serde_json::to_vec(&event) else {
                        return false;
                    };
                    if meta.events >= self.queue.max_events
                        || bytes.len() > self.queue.max_bytes.saturating_sub(meta.bytes)
                    {
                        return false;
                    }
                    representative = Some((event, bytes.len()));
                    true
                },
            );
            if let Some((event, bytes)) = representative {
                let job_key = format!("job/{name}/{}", event.id);
                put(
                    tx,
                    &job_key,
                    &Job {
                        event: event.clone(),
                        bytes,
                        failed: false,
                    },
                )?;
                meta.events += 1;
                meta.bytes += bytes;
                jobs.push((name.clone(), job_key, event));
            }
            if let Some(group) = group {
                timed(
                    tx,
                    &group_key,
                    now_ms.saturating_add(u64::from(*retention) * 1000),
                    group,
                )?;
            }
            put(tx, &meta_key, &meta)?;
            outcomes.push(json!({ "destination": name, "outcome": outcome }));
        }
        let response =
            json!({ "ok": true, "event_id": event.id, "durable": true, "destinations": outcomes });
        Ok(Admission { response, jobs })
    }

    pub fn pending(&self) -> Result<Vec<(String, String, Event)>> {
        let tx = self.db.begin_write()?;
        entries(&tx, "job/")?
            .into_iter()
            .filter_map(|(key, bytes)| {
                let parsed = serde_json::from_slice::<Job>(&bytes);
                match parsed {
                    Ok(job) if job.failed => None,
                    Ok(job) => Some(Ok((
                        key.split('/').nth(1).unwrap_or("").to_owned(),
                        key,
                        job.event,
                    ))),
                    Err(error) => Some(Err(error.into())),
                }
            })
            .collect()
    }

    pub fn complete(&self, results: &[(String, String, bool, bool)], now: f64) -> Result<()> {
        let tx = self.db.begin_write()?;
        let mut ledger: Ledger = get(&tx, "ledger")?.ok_or("missing storage ledger")?;
        ledger.clock = now.max(ledger.clock);
        for (name, key, success, abandoned) in results {
            if *abandoned {
                continue;
            } // Leave unfinished jobs replayable.
            let mut job: Job = get(&tx, key)?.ok_or("missing queued job")?;
            let meta_key = format!("destination/{name}");
            let mut meta: Destination = get(&tx, &meta_key)?.ok_or("missing destination state")?;
            if *success {
                tx.open_table(DATA)?.remove(key.as_str())?;
                meta.events = meta.events.checked_sub(1).ok_or("invalid queue count")?;
                meta.bytes = meta
                    .bytes
                    .checked_sub(job.bytes)
                    .ok_or("invalid queue bytes")?;
                meta.delivered = meta.delivered.saturating_add(1);
                let receipt_key = format!("receipt/{}", job.event.id);
                let mut receipt: Timed<Receipt> =
                    get(&tx, &receipt_key)?.ok_or("missing receipt")?;
                receipt.value.jobs = receipt
                    .value
                    .jobs
                    .checked_sub(1)
                    .ok_or("invalid receipt job count")?;
                let expires = if receipt.value.jobs == 0 {
                    self.receipt_expiry(milliseconds(ledger.clock)?)
                } else {
                    u64::MAX
                };
                timed(&tx, &receipt_key, expires, receipt.value)?;
            } else {
                job.failed = true;
                put(&tx, key, &job)?;
                meta.failed += 1;
            }
            put(&tx, &meta_key, &meta)?;
        }
        put(&tx, "ledger", &ledger)?;
        commit(tx)
    }

    pub fn statistics(&self) -> Result<Value> {
        let tx = self.db.begin_write()?;
        let mut destinations = Vec::new();
        for (name, _, _) in &self.policies {
            let meta: Destination =
                get(&tx, &format!("destination/{name}"))?.ok_or("missing destination state")?;
            destinations.push(json!({
                "name": name, "policy": meta.policy.statistics,
                "spool": { "pending": meta.events - meta.failed, "failed": meta.failed,
                    "bytes": meta.bytes, "delivered": meta.delivered }
            }));
        }
        let ledger: Ledger = get(&tx, "ledger")?.ok_or("missing storage ledger")?;
        Ok(
            json!({ "ok": true, "durable": true, "receipts": ledger.receipts, "destinations": destinations }),
        )
    }

    fn receipt_expiry(&self, now_ms: u64) -> u64 {
        now_ms.saturating_add(u64::from(self.config.receipt_retention_seconds) * 1000)
    }
}

fn open_database(path: &Path) -> Result<(Database, bool)> {
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or("storage.path requires a private parent directory")?;
    let directory = std::fs::symlink_metadata(parent)?;
    if !directory.is_dir() || directory.permissions().mode() & 0o077 != 0 {
        return Err("storage directory must be private (0700) and not a symlink".into());
    }
    let initialized = match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
                return Err("storage file must be private (0600) and not a symlink".into());
            }
            metadata.len() > 0
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => return Err(error.into()),
    };
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    let db = Database::builder()
        .set_cache_size(8 * 1024 * 1024)
        .create_file(file)?;
    File::open(parent)?.sync_all()?;
    Ok((db, initialized))
}

fn get<T: DeserializeOwned>(tx: &WriteTransaction, key: &str) -> Result<Option<T>> {
    tx.open_table(DATA)?
        .get(key)?
        .map(|value| serde_json::from_slice(value.value()).map_err(Into::into))
        .transpose()
}

fn put<T: Serialize>(tx: &WriteTransaction, key: &str, value: &T) -> Result<()> {
    tx.open_table(DATA)?
        .insert(key, serde_json::to_vec(value)?.as_slice())?;
    Ok(())
}

fn entries(tx: &WriteTransaction, prefix: &str) -> Result<Vec<(String, Vec<u8>)>> {
    let table = tx.open_table(DATA)?;
    let mut rows = Vec::new();
    for row in table.range(prefix..)? {
        let (key, value) = row?;
        if !key.value().starts_with(prefix) {
            break;
        }
        rows.push((key.value().to_owned(), value.value().to_vec()));
    }
    Ok(rows)
}

fn timed<T: Serialize>(tx: &WriteTransaction, key: &str, expires: u64, value: T) -> Result<()> {
    if let Some(old) = get::<Timed<Value>>(tx, key)? {
        tx.open_table(EXPIRY)?.remove((old.expires, key))?;
    }
    put(tx, key, &Timed { expires, value })?;
    tx.open_table(EXPIRY)?.insert((expires, key), ())?;
    Ok(())
}

fn cleanup(tx: &WriteTransaction, now_ms: u64, ledger: &mut Ledger) -> Result<()> {
    let expired = tx
        .open_table(EXPIRY)?
        .range(..=(now_ms, "\u{10ffff}"))?
        .take(256)
        .map(|entry| entry.map(|(key, _)| (key.value().0, key.value().1.to_owned())))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    for (time, key) in expired {
        expire(tx, &key, time, ledger)?;
    }
    Ok(())
}

fn expire(tx: &WriteTransaction, key: &str, time: u64, ledger: &mut Ledger) -> Result<()> {
    tx.open_table(EXPIRY)?.remove((time, key))?;
    tx.open_table(DATA)?.remove(key)?;
    if key.starts_with("receipt/") {
        ledger.receipts = ledger
            .receipts
            .checked_sub(1)
            .ok_or("invalid receipt count")?;
    } else if let Some(name) = key
        .strip_prefix("group/")
        .and_then(|key| key.split('/').next())
    {
        let meta_key = format!("destination/{name}");
        let mut meta: Destination = get(tx, &meta_key)?.ok_or("missing destination state")?;
        meta.policy.statistics.tracked_fingerprints = meta
            .policy
            .statistics
            .tracked_fingerprints
            .checked_sub(1)
            .ok_or("invalid group count")?;
        meta.policy.statistics.expired_groups =
            meta.policy.statistics.expired_groups.saturating_add(1);
        put(tx, &meta_key, &meta)?;
    }
    Ok(())
}

fn commit(mut tx: WriteTransaction) -> Result<()> {
    tx.set_durability(Durability::Immediate)?;
    tx.commit()?;
    Ok(())
}

fn milliseconds(seconds: f64) -> Result<u64> {
    let duration = std::time::Duration::try_from_secs_f64(seconds)?;
    Ok(u64::try_from(duration.as_millis())?)
}

#[cfg(test)]
mod tests;
