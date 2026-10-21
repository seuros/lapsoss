#![allow(
    clippy::unwrap_used,
    reason = "test setup and protocol assertions should fail immediately"
)]

use super::*;
use crate::{service::DaemonConfig, test_support::Directory};

async fn request(path: &Path, value: Value) -> Value {
    let mut stream = UnixStream::connect(path).await.unwrap();
    write_response(&mut stream, &value).await.unwrap();
    let length = stream.read_u32().await.unwrap() as usize;
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn wire_protocol_aggregates_across_connections_and_isolates_destinations() {
    let directory = Directory::new();
    let socket = directory.0.join("daemon.sock");
    let config: DaemonConfig = serde_json::from_value(json!({
        "socket": socket,
        "storage": { "path": directory.0.join("state.redb") },
        "destinations": [
            { "adapter": { "name": "one", "type": "logger" } },
            { "adapter": { "name": "two", "type": "logger" }, "policy": { "budget_events": 1 } }
        ]
    }))
    .unwrap();
    let service = Service::new(&config).unwrap();
    let server = Server::bind(&socket).unwrap();
    assert_eq!(
        std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(Server::bind(&socket).is_err());
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let runner = tokio::spawn(async move {
        server
            .run(service, async {
                stopped.await.unwrap();
            })
            .await
    });
    let event = Event::message("outage", "error");
    let command = json!({ "command": "submit", "version": 1, "event": event });
    let acknowledged = request(&socket, command.clone()).await;
    assert_eq!(
        acknowledged["destinations"][0]["outcome"]["decision"],
        "forward"
    );
    assert_eq!(request(&socket, command).await, acknowledged);
    assert_eq!(
        request(
            &socket,
            json!({
                "command": "submit", "version": 1, "event": Event::message("outage", "error")
            })
        )
        .await["destinations"][0]["outcome"]["decision"],
        "aggregate"
    );
    let result = request(
        &socket,
        json!({
            "command": "submit", "version": 1, "event": Event::message("new", "error")
        }),
    )
    .await;
    assert_eq!(result["destinations"][0]["outcome"]["decision"], "forward");
    assert_eq!(
        result["destinations"][1]["outcome"]["reason"],
        "destination_budget"
    );
    let stats = request(&socket, json!({ "command": "statistics", "version": 1 })).await;
    assert_eq!(stats["destinations"][0]["policy"]["received"], 3);
    assert_eq!(stats["destinations"][0]["policy"]["aggregated"], 1);
    assert_eq!(
        request(
            &socket,
            json!({ "command": "flush", "version": 1, "timeout_ms": 1000 })
        )
        .await["ok"],
        true
    );
    assert_eq!(
        request(&socket, json!({ "command": "statistics", "version": 2 })).await["ok"],
        false
    );
    let mut bad_event = Event::message("bad", "error");
    bad_event.context = json!([]);
    assert_eq!(
        request(
            &socket,
            json!({ "command": "submit", "version": 1, "event": bad_event })
        )
        .await["ok"],
        false
    );
    let mut stream = UnixStream::connect(&socket).await.unwrap();
    stream
        .write_u32(u32::try_from(MAX_FRAME_BYTES + 1).unwrap())
        .await
        .unwrap();
    assert!(stream.read_u32().await.unwrap() < 1024);
    stop.send(()).unwrap();
    runner.await.unwrap().unwrap();
    assert!(!socket.exists());
}

#[tokio::test]
async fn refuses_public_socket_directory() {
    let directory = Directory::new();
    std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Server::bind(&directory.0.join("daemon.sock")).is_err());
}
