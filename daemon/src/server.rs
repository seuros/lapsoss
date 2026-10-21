use std::{
    io,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use lapsoss::Event;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    task::JoinSet,
};

use crate::{policy::valid_event, service::Service};

pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Submit { version: u8, event: Box<Event> },
    Statistics { version: u8 },
    Flush { version: u8, timeout_ms: u32 },
}

/// Bind in a directory private to the service account. Existing paths are never
/// unlinked: a second daemon must not steal a running instance's socket.
pub struct Server {
    listener: UnixListener,
    path: PathBuf,
}

impl Server {
    /// # Errors
    /// Rejects unsafe parent directories or an existing socket path.
    pub fn bind(path: &Path) -> io::Result<Self> {
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| io::Error::other("socket must have a private parent directory"))?;
        let metadata = std::fs::symlink_metadata(parent)?;
        if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::other(
                "socket directory must be private (0700) and not a symlink",
            ));
        }
        let listener = UnixListener::bind(path)?;
        if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
            std::fs::remove_file(path)?;
            return Err(error);
        }
        Ok(Self {
            listener,
            path: path.into(),
        })
    }

    /// # Errors
    /// Returns listener failures. Shutdown cancels clients before draining delivery.
    pub async fn run(
        &self,
        service: Service,
        shutdown: impl std::future::Future<Output = ()>,
    ) -> io::Result<()> {
        let permits = Arc::new(Semaphore::new(32));
        let mut clients = JoinSet::new();
        tokio::pin!(shutdown);
        loop {
            tokio::select! {
                () = &mut shutdown => break,
                Some(result) = clients.join_next(), if !clients.is_empty() => {
                    if result.is_err() {
                        eprintln!("lapsossd: client task failed");
                    }
                }
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted?;
                    let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
                        drop(stream);
                        continue;
                    };
                    let service = service.clone();
                    clients.spawn(async move {
                        let _permit = permit;
                        // A fixed deadline bounds slow readers, writers, and flushes.
                        if tokio::time::timeout(IO_TIMEOUT, handle(stream, service)).await.is_err() {
                            eprintln!("lapsossd: client deadline exceeded");
                        }
                    });
                }
            }
        }
        clients.abort_all();
        while clients.join_next().await.is_some() {}
        if !service.shutdown(Duration::from_secs(5)).await {
            eprintln!("lapsossd: shutdown timed out; unfinished jobs remain durable");
        }
        Ok(())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path) {
            eprintln!("lapsossd: socket cleanup failed: {error}");
        }
    }
}

async fn handle(mut stream: UnixStream, service: Service) -> io::Result<()> {
    let length = usize::try_from(stream.read_u32().await?).map_err(io::Error::other)?;
    if length == 0 || length > MAX_FRAME_BYTES {
        return write_response(
            &mut stream,
            &json!({ "ok": false, "error": "invalid_frame_size" }),
        )
        .await;
    }
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await?;
    let response = match serde_json::from_slice::<Request>(&bytes) {
        Ok(Request::Submit { version: 1, event }) if valid_event(&event) => {
            service.submit(*event).await
        }
        Ok(Request::Statistics { version: 1 }) => service.statistics().await,
        Ok(Request::Flush {
            version: 1,
            timeout_ms,
        }) if timeout_ms <= 1500 => {
            json!({ "ok": service.flush(Duration::from_millis(u64::from(timeout_ms))).await })
        }
        _ => json!({ "ok": false, "error": "invalid_request" }),
    };
    write_response(&mut stream, &response).await
}

async fn write_response(stream: &mut UnixStream, response: &Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(response)?;
    stream
        .write_u32(u32::try_from(bytes.len()).map_err(io::Error::other)?)
        .await?;
    stream.write_all(&bytes).await
}

#[cfg(test)]
mod tests;
