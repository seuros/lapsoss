use std::{path::Path, process::ExitCode};

use lapsossd::{
    server::Server,
    service::{DaemonConfig, Service},
};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("lapsossd: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [flag] if flag == "--version" => {
            println!("lapsossd {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        [flag] if flag == "--help" => {
            println!(
                "Usage: lapsossd --config PATH.json\nRun in the foreground under your service supervisor."
            );
            return Ok(());
        }
        [flag, _] if flag == "--config" => {}
        _ => return Err("usage: lapsossd --config PATH.json".into()),
    }
    let config: DaemonConfig = serde_json::from_reader(std::fs::File::open(&args[1])?)?;
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .with_max_level(tracing::Level::INFO)
        .try_init()
        .map_err(|_| "cannot initialize daemon logging")?;
    let service = Service::new(&config)?;
    let server = Server::bind(Path::new(&config.socket))?;
    // Register both handlers before announcing readiness.
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    eprintln!("lapsossd: ready");
    server
        .run(service, async {
            tokio::select! {
                _ = terminate.recv() => {}
                _ = interrupt.recv() => {}
            }
        })
        .await?;
    Ok(())
}
