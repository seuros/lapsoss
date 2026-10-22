use redb::{ReadableDatabase, TableDefinition, WriteTransaction};

use super::{
    Delivery, Destination, Ledger, Result, Store, Timed, commit, enqueue, expire, get,
    milliseconds, put, timed,
};
use crate::policy::Group;

pub(super) const SCHEDULE: TableDefinition<(u64, &str), ()> = TableDefinition::new("summaries");

impl Store {
    /// Process a bounded due batch. With no work, do not write or sync the disk.
    pub fn summarize(&self, now: f64) -> Result<Vec<Delivery>> {
        let now_ms = milliseconds(now)?;
        let due = self
            .db
            .begin_read()?
            .open_table(SCHEDULE)?
            .range(..=(now_ms, "\u{10ffff}"))?
            .take(64)
            .map(|row| row.map(|(key, _)| key.value().1.to_owned()))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        if due.is_empty() {
            return Ok(Vec::new());
        }
        let tx = self.db.begin_write()?;
        let mut ledger: Ledger = get(&tx, "ledger")?.ok_or("missing storage ledger")?;
        ledger.clock = now.max(ledger.clock);
        let mut jobs = Vec::new();
        for key in due {
            let mut group: Timed<Group> = get(&tx, &key)?.ok_or("missing summary group")?;
            if group.expires <= now_ms {
                expire(&tx, &key, group.expires, &mut ledger)?;
                continue;
            }
            let name = key
                .strip_prefix("group/")
                .and_then(|key| key.split('/').next())
                .ok_or("invalid summary key")?;
            let (_, policy, _) = self
                .policies
                .iter()
                .find(|(entry, _, _)| entry == name)
                .ok_or("missing summary destination")?;
            let meta_key = format!("destination/{name}");
            let mut meta: Destination = get(&tx, &meta_key)?.ok_or("missing destination state")?;
            let mut representative = None;
            policy.summarize(ledger.clock, &mut meta.policy, &mut group.value, |event| {
                representative = self.stage(event, meta.events, meta.bytes);
                representative.is_some()
            });
            if let Some(job) = enqueue(&tx, name, &mut meta, representative, true)? {
                jobs.push(job);
            }
            save_group(&tx, &key, group.expires, group.value)?;
            put(&tx, &meta_key, &meta)?;
        }
        put(&tx, "ledger", &ledger)?;
        commit(tx)?;
        Ok(jobs)
    }
}

pub(super) fn unschedule(tx: &WriteTransaction, key: &str) -> Result<()> {
    if let Some(group) = get::<Timed<Group>>(tx, key)?
        && let Some(summary) = group.value.summary
    {
        tx.open_table(SCHEDULE)?
            .remove((milliseconds(summary.due)?.saturating_add(1), key))?;
    }
    Ok(())
}

pub(super) fn save_group(
    tx: &WriteTransaction,
    key: &str,
    expires: u64,
    group: Group,
) -> Result<()> {
    unschedule(tx, key)?;
    if group.pending > 0
        && let Some(summary) = &group.summary
    {
        tx.open_table(SCHEDULE)?
            .insert((milliseconds(summary.due)?.saturating_add(1), key), ())?;
    }
    timed(tx, key, expires, group)
}
