//! Integration tests for the Mother broker IPC client.
//!
//! Stands up a fake broker on a temp Unix socket that speaks NDJSON, then
//! exercises the `BrokerClient` against it.
//!
//! Test scenarios:
//! - Handshake (hello → subscribe → snapshot).
//! - Command correlation (send cancel, ack matches by id).
//! - Out-of-order ack (ping + event interleaved before the ack).
//! - Failure ack (negative ack maps to `BrokerNack`).
//! - Reconnect (socket drop → Reconnecting → Connected → Reconnected event).
//! - Disconnected send (no listener → `Disconnected` immediately).
//! - Oversize line (> 8 MiB → generation disconnect, no crash).
//!
//! Note: unit-level tests for these scenarios also live inside
//! `src/mother/broker_client.rs`; this file exercises the same paths but
//! through the public API surface only.

use std::time::Duration;

use nostromo::mother::broker_client::{
    BrokerClient, BrokerConnState, BrokerEvent, BrokerSendError,
};
use nostromo::mother::protocol::{cmd_answer, cmd_cancel, cmd_retry};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;

// ── helpers ───────────────────────────────────────────────────────────────────

fn temp_sock() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "nostromo_broker_integ_{}.sock",
        uuid::Uuid::new_v4()
    ))
}

async fn fake_write(
    writer: &mut tokio::io::WriteHalf<tokio::net::UnixStream>,
    v: &serde_json::Value,
) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    writer.write_all(&bytes).await.unwrap();
}

async fn fake_read(
    reader: &mut BufReader<tokio::io::ReadHalf<tokio::net::UnixStream>>,
) -> serde_json::Value {
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).unwrap()
}

async fn send_hello(writer: &mut tokio::io::WriteHalf<tokio::net::UnixStream>, caps: &[&str]) {
    let caps_json: Vec<serde_json::Value> = caps.iter().map(|s| serde_json::json!(s)).collect();
    fake_write(
        writer,
        &serde_json::json!({
            "v": 1, "dir": "event", "t": "hello", "id": "h1", "ts": "2026-01-01T00:00:00.000Z",
            "data": { "protocol_version": 1, "capabilities": caps_json }
        }),
    )
    .await;
}

async fn read_subscribe(
    reader: &mut BufReader<tokio::io::ReadHalf<tokio::net::UnixStream>>,
) -> serde_json::Value {
    fake_read(reader).await
}

async fn send_snapshot(
    writer: &mut tokio::io::WriteHalf<tokio::net::UnixStream>,
    jobs: Vec<serde_json::Value>,
) {
    fake_write(
        writer,
        &serde_json::json!({
            "v": 1, "dir": "event", "t": "snapshot", "id": "s1", "ts": "2026-01-01T00:00:00.000Z",
            "data": { "sub": "queue", "jobs": jobs }
        }),
    )
    .await;
}

async fn send_ack_ok(
    writer: &mut tokio::io::WriteHalf<tokio::net::UnixStream>,
    cmd_id: &str,
    t: &str,
) {
    fake_write(
        writer,
        &serde_json::json!({
            "v": 1, "dir": "ack", "t": t, "id": cmd_id, "ts": "2026-01-01T00:00:00.000Z",
            "data": { "ok": true, "job": "job-1" }
        }),
    )
    .await;
}

async fn send_ack_err(
    writer: &mut tokio::io::WriteHalf<tokio::net::UnixStream>,
    cmd_id: &str,
    t: &str,
    code: &str,
    message: &str,
) {
    fake_write(
        writer,
        &serde_json::json!({
            "v": 1, "dir": "ack", "t": t, "id": cmd_id, "ts": "2026-01-01T00:00:00.000Z",
            "data": { "ok": false, "error": { "code": code, "message": message } }
        }),
    )
    .await;
}

/// Wait for a specific `BrokerConnState` on the watch receiver.
async fn wait_for_state(rx: &mut watch::Receiver<BrokerConnState>, target: BrokerConnState) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            rx.changed().await.expect("state watch closed");
            if *rx.borrow() == target {
                break;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for state {target:?}"));
}

/// Drain events, returning the first matching `BrokerEvent` or panicking.
macro_rules! expect_event {
    ($rx:expr, $pat:pat, $timeout_ms:expr) => {{
        let ev = tokio::time::timeout(Duration::from_millis($timeout_ms), async {
            loop {
                match $rx.recv().await {
                    Ok(e) => break e,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        panic!("broadcast channel closed")
                    }
                }
            }
        })
        .await
        .expect("timed out waiting for event");
        assert!(matches!(ev, $pat), "unexpected event: {ev:?}");
        ev
    }};
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// Client connects, receives hello, sends subscribe with correct payload,
/// receives snapshot, and surfaces the job list.
#[tokio::test]
async fn handshake_subscribe_snapshot() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);

        send_hello(&mut w, &["state", "await", "current_activity"]).await;

        // Read subscribe command and assert its shape.
        let sub = read_subscribe(&mut reader).await;
        assert_eq!(sub["v"], 1);
        assert_eq!(sub["dir"], "cmd");
        assert_eq!(sub["t"], "subscribe");
        assert_eq!(sub["data"]["sub"], "queue");
        assert_eq!(sub["data"]["jobs"][0], "all");
        let cats: Vec<&str> = sub["data"]["categories"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert!(cats.contains(&"state"));
        assert!(cats.contains(&"await"));
        assert!(cats.contains(&"current_activity"));

        send_snapshot(
            &mut w,
            vec![serde_json::json!({
                "id": "job-abc", "state": "running", "title": "Test",
                "repo": "", "isolation": ""
            })],
        )
        .await;

        tokio::time::sleep(Duration::from_millis(200)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(10),
        Duration::from_millis(50),
    );
    let mut events = client.subscribe();
    let mut state_rx = client.connection_state();

    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;

    expect_event!(events, BrokerEvent::Hello { .. }, 2000);

    let snap = expect_event!(events, BrokerEvent::Snapshot { .. }, 2000);
    if let BrokerEvent::Snapshot { jobs, .. } = snap {
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].id, "job-abc");
        assert_eq!(jobs[0].state, "running");
    }

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// `cancel` command correlates by id: ack with matching id resolves Ok.
#[tokio::test]
async fn cancel_command_correlates_by_id() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);
        send_hello(&mut w, &["state"]).await;
        let _sub = read_subscribe(&mut reader).await;
        send_snapshot(&mut w, vec![]).await;

        let cmd = fake_read(&mut reader).await;
        assert_eq!(cmd["t"], "cancel");
        let id = cmd["id"].as_str().unwrap().to_string();
        send_ack_ok(&mut w, &id, "cancel").await;

        tokio::time::sleep(Duration::from_millis(200)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(10),
        Duration::from_millis(50),
    );
    let mut state_rx = client.connection_state();
    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = client.send_command(cmd_cancel("job-1")).await;
    assert!(result.is_ok(), "cancel should return Ok; got {result:?}");

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// Ack arrives after a ping and unrelated event — still correlates by id.
#[tokio::test]
async fn answer_command_out_of_order_ack() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake =
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (r, mut w) = tokio::io::split(stream);
            let mut reader = BufReader::new(r);
            send_hello(&mut w, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut w, vec![]).await;

            let cmd = fake_read(&mut reader).await;
            let id = cmd["id"].as_str().unwrap().to_string();

            // Noise before the ack.
            fake_write(&mut w, &serde_json::json!({
            "v": 1, "dir": "event", "t": "ping", "id": "p1", "ts": "2026-01-01T00:00:00.000Z",
            "data": {}
        })).await;
            fake_write(&mut w, &serde_json::json!({
            "v": 1, "dir": "event", "t": "running", "id": "e1", "ts": "2026-01-01T00:00:00.000Z",
            "data": { "job": "other", "category": "state" }
        })).await;

            send_ack_ok(&mut w, &id, "answer").await;

            tokio::time::sleep(Duration::from_millis(200)).await;
        });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(10),
        Duration::from_millis(50),
    );
    let mut state_rx = client.connection_state();
    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = client.send_command(cmd_answer("job-1", "yes")).await;
    assert!(
        result.is_ok(),
        "answer should return Ok despite out-of-order ack; got {result:?}"
    );

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// Negative ack maps to `BrokerSendError::BrokerNack`.
#[tokio::test]
async fn failure_ack_surfaces_error() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);
        send_hello(&mut w, &["state"]).await;
        let _sub = read_subscribe(&mut reader).await;
        send_snapshot(&mut w, vec![]).await;

        let cmd = fake_read(&mut reader).await;
        let id = cmd["id"].as_str().unwrap().to_string();
        send_ack_err(&mut w, &id, "cancel", "no_such_job", "job not found").await;

        tokio::time::sleep(Duration::from_millis(200)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(10),
        Duration::from_millis(50),
    );
    let mut state_rx = client.connection_state();
    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = client.send_command(cmd_cancel("job-x")).await;
    match result {
        Err(BrokerSendError::BrokerNack { code, .. }) => {
            assert_eq!(code, nostromo::mother::protocol::BrokerErrorCode::NoSuchJob);
        }
        other => panic!("expected BrokerNack(no_such_job), got {other:?}"),
    }

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// `retry` command correlates and resolves Ok.
#[tokio::test]
async fn retry_command_ok() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);
        send_hello(&mut w, &["state"]).await;
        let _sub = read_subscribe(&mut reader).await;
        send_snapshot(&mut w, vec![]).await;

        let cmd = fake_read(&mut reader).await;
        assert_eq!(cmd["t"], "retry");
        assert_eq!(cmd["data"]["job"], "job-failed");
        let id = cmd["id"].as_str().unwrap().to_string();
        send_ack_ok(&mut w, &id, "retry").await;

        tokio::time::sleep(Duration::from_millis(200)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(10),
        Duration::from_millis(50),
    );
    let mut state_rx = client.connection_state();
    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = client.send_command(cmd_retry("job-failed")).await;
    assert!(result.is_ok(), "retry should return Ok; got {result:?}");

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// Socket drop → Reconnecting → Connected, re-subscribes, emits Reconnected.
#[tokio::test]
async fn reconnect_after_disconnect() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();
    let (gen1_tx, gen1_rx) = tokio::sync::oneshot::channel::<()>();

    let fake = tokio::spawn(async move {
        // Gen 1: handshake then drop.
        {
            let (stream, _) = listener.accept().await.unwrap();
            let (r, mut w) = tokio::io::split(stream);
            let mut reader = BufReader::new(r);
            send_hello(&mut w, &["state"]).await;
            let _sub = read_subscribe(&mut reader).await;
            send_snapshot(&mut w, vec![]).await;
        }
        let _ = gen1_tx.send(());

        // Gen 2: complete handshake, stay alive.
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);
        send_hello(&mut w, &["state"]).await;
        let sub = read_subscribe(&mut reader).await;
        assert_eq!(sub["t"], "subscribe", "gen2 client re-sent subscribe");
        send_snapshot(&mut w, vec![]).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(20),
        Duration::from_millis(100),
    );
    let mut state_rx = client.connection_state();
    let mut events = client.subscribe();

    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;
    gen1_rx.await.unwrap();

    // Wait for Reconnecting.
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            state_rx.changed().await.unwrap();
            if matches!(*state_rx.borrow(), BrokerConnState::Reconnecting { .. }) {
                break;
            }
        }
    })
    .await
    .expect("timed out waiting for Reconnecting");

    // Wait for reconnect.
    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;

    // Verify Reconnected event was broadcast.
    let mut found = false;
    for _ in 0..50 {
        match events.try_recv() {
            Ok(BrokerEvent::Reconnected) => {
                found = true;
                break;
            }
            Ok(_) => {}
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
    }
    assert!(found, "BrokerEvent::Reconnected should have been emitted");

    // A command issued while disconnected (during the reconnect window) returns Disconnected.
    // We can't reliably test that in this integration test since timing is non-deterministic.
    // The unit test in broker_client.rs covers it.

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}

/// No broker listening → send_command immediately returns Disconnected.
#[tokio::test]
async fn no_broker_returns_disconnected() {
    let sock = temp_sock();
    // No listener.

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(500),
        Duration::from_millis(500),
    );

    let result = client.send_command(cmd_cancel("j")).await;
    assert!(
        matches!(result, Err(BrokerSendError::Disconnected)),
        "expected Disconnected, got {result:?}"
    );
}

/// Oversize line (> 8 MiB) causes generation disconnect without crashing.
#[tokio::test]
async fn oversize_line_disconnects_without_crash() {
    let sock = temp_sock();
    let listener = UnixListener::bind(&sock).unwrap();

    let fake = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (r, mut w) = tokio::io::split(stream);
        let mut reader = BufReader::new(r);
        send_hello(&mut w, &["state"]).await;
        let _sub = read_subscribe(&mut reader).await;

        // Write a line > 8 MiB.
        let big = vec![b'x'; 8 * 1024 * 1024 + 1];
        w.write_all(&big).await.unwrap();
        w.write_all(b"\n").await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
    });

    let client = BrokerClient::new_with_backoff(
        sock.clone(),
        Duration::from_millis(20),
        Duration::from_millis(100),
    );
    let mut state_rx = client.connection_state();

    wait_for_state(&mut state_rx, BrokerConnState::Connected).await;

    // After the oversize line, the generation should end and the client reconnect.
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            state_rx.changed().await.unwrap();
            if matches!(
                *state_rx.borrow(),
                BrokerConnState::Reconnecting { .. } | BrokerConnState::Connecting
            ) {
                break;
            }
        }
    })
    .await
    .expect("expected disconnect after oversize line — client hung");

    fake.await.unwrap();
    let _ = std::fs::remove_file(&sock);
}
