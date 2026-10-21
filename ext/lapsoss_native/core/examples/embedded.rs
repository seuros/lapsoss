//! Run with `cargo run -p lapsoss --example embedded`. No Ruby is involved.
use std::{sync::Arc, time::Duration};

use lapsoss::{Config, Dispatcher, Event, LoggerAdapter};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let dispatcher = Dispatcher::new(
        tokio::runtime::Handle::current(),
        Config::default(),
        vec![Arc::new(LoggerAdapter::new("console"))],
    )?;
    let completion = dispatcher
        .submit(Event::message("embedded Rust dispatch", "info"))?
        .wait()
        .await?;
    if !completion.outcomes.iter().all(|o| o.success) {
        anyhow::bail!("delivery failed");
    }
    if !dispatcher.shutdown(Duration::from_secs(2)).await {
        anyhow::bail!("shutdown deadline exceeded");
    }
    Ok(())
}
