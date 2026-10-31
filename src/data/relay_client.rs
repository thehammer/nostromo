//! github-relay WebSocket subscriber.
//!
//! Connects to the github-relay service and forwards every GitHub event it
//! receives to each subscriber of a [`RelayHub`]: the Perri queue, and Mother's
//! PR tracker (`mother::notices::pr_state`). The relay delivers events within
//! ~3 seconds of the GitHub webhook firing, replacing the queue's poll-cycle
//! lag with near-real-time updates. The hub also carries a [`RelayStatus`]
//! (connected or not, and the organisation the relay covers).
//!
//! # The queue signal
//!
//! Events reach the queue as a typed [`QueueSignal`] rather than a payload-free
//! `()`, carrying the relay's full description of what happened — repo, PR
//! number, HEAD SHA, reviewer, review state, and so on.
//!
//! **This module makes no relevance judgements.** It parses and forwards; the
//! queue's classifier (`perri_queue_targeted::classify_event`) decides what
//! each event means, including that an unrecognised event type means nothing.
//! Keeping that decision in one place is the point: a filter here plus a
//! classifier there is two lists that can drift apart. The subscription itself
//! is still narrow — the relay only *sends* the nine queue-relevant types (see
//! the `subscribe` frame below).
//!
//! Fields the relay marks as hints — `draft`, `author`, `is_bot`, `ci_state` —
//! are for logging and cheap short-circuits only. Where a hint and a direct
//! GitHub read disagree, the read wins; `is_bot()` and `is_filtered()` in
//! `perri_queue_native` remain the single source of truth.
//!
//! # Reconnect behaviour
//!
//! The relay is at-most-once; it buffers nothing. On any disconnect the client:
//!   1. Reconnects with exponential backoff (1s → 2s → 4s … capped at 60s).
//!   2. Re-declares the subscription.
//!   3. Sends [`QueueSignal::Reconnected`], which is the one relay signal that
//!      still forces a **full** refresh — the queue has to reconcile whatever
//!      it missed, and there is no event describing that.
//!
//! A 401 on the initial handshake is non-retryable — the token is bad and the
//! loop exits permanently (no point burning CPU on a bad credential).

use std::time::Duration;

use anyhow::Result;
use chrono::{DateTime, Utc};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async_tls_with_config,
    tungstenite::{
        client::IntoClientRequest,
        http::header::{AUTHORIZATION, USER_AGENT},
        Message,
    },
};
use tracing::{debug, info, warn};

use crate::config::Config;

// ── public signal types ───────────────────────────────────────────────────────

/// One GitHub event, in the relay's canonical vocabulary.
///
/// Every field the relay's v1 contract defines is carried, whether or not the
/// queue reads it today — the wire format is cheaper to land once than to widen
/// twice. `org`, `base_ref` and `head_ref` are deliberately absent: the
/// subscription is single-org, and nothing needs the branch names.
///
/// See the module docs for the hint rule governing `draft` / `author` /
/// `is_bot` / `ci_state`.
#[derive(Debug, Clone, Default)]
pub struct RelayEvent {
    /// A value from the relay's closed vocabulary, e.g. `pr.merged`.
    pub event_type: String,
    /// Stable per-event identifier, for dedup.
    pub event_id: Option<String>,
    /// When the relay emitted the event.  Substituted with the receipt time if
    /// the relay omitted it or sent something unparseable, so ordering logic
    /// downstream always has a timestamp.
    pub delivered_at: Option<DateTime<Utc>>,
    /// `owner/name`.
    pub repo: Option<String>,
    /// PR number — present on `pr.*`, absent on `ci.completed`.
    pub number: Option<u64>,
    /// The commit the event pertains to.
    pub head_sha: Option<String>,
    /// Requested or submitting reviewer login.
    pub reviewer: Option<String>,
    /// `approved` | `changes_requested` | `commented`.
    pub review_state: Option<String>,
    /// `open` | `closed`.
    pub state: Option<String>,
    pub merged: Option<bool>,
    pub draft: Option<bool>,
    pub author: Option<String>,
    /// Relay-determined, not inferred by us.
    pub is_bot: Option<bool>,
    /// `pending` | `success` | `failure`.
    pub ci_state: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
    /// Check/suite name — present on `ci.completed`, absent on `pr.*`.
    pub name: Option<String>,
}

/// What the relay tells the Perri queue.
///
/// `Event` is ~330 bytes against `Reconnected`'s zero, which clippy would
/// rather see boxed.  Not worth it: these arrive a few times a minute at most,
/// the unbounded channel heap-allocates the node either way, and
/// `Event(Box<RelayEvent>)` would put an indirection in front of every future
/// consumer to save stack that is never in a hot path.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone)]
pub enum QueueSignal {
    /// Connected and the subscription was acked.  The relay buffers nothing for
    /// an absent client, so the queue must do a **full** refresh to reconcile
    /// whatever it missed while disconnected.
    Reconnected,
    /// A GitHub event arrived.  Relevance is the queue's call, not ours.
    Event(RelayEvent),
}

// ── message shapes ────────────────────────────────────────────────────────────

/// Every message the relay sends is a JSON object with a "type" discriminator.
/// We only care about the `event` type; all others are silently ignored.
///
/// Every body field is `#[serde(default)]` and `Unknown` catches unrecognised
/// discriminators, so the relay can add to the vocabulary without breaking us.
///
/// Same size trade-off as [`QueueSignal`]: one short-lived stack value per
/// inbound websocket frame, immediately destructured.  Boxing individual
/// fields to flatten the variant sizes would cost readability and allocations
/// for nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RelayMsg {
    Ack {
        #[serde(default)]
        events: Vec<String>,
        /// The organisation the relay will send events for, if it says.
        #[serde(default)]
        org: Option<String>,
    },
    Event {
        event_type: String,
        #[serde(default)]
        event_id: Option<String>,
        /// RFC-3339; parsed after deserialisation.
        #[serde(default)]
        delivered_at: Option<String>,
        /// `owner/name`, present on every event.
        #[serde(default)]
        repo: Option<String>,
        /// PR number — present on `pr.*` events, absent on `ci.completed`.
        #[serde(default)]
        number: Option<u64>,
        #[serde(default)]
        head_sha: Option<String>,
        #[serde(default)]
        reviewer: Option<String>,
        #[serde(default)]
        review_state: Option<String>,
        #[serde(default)]
        state: Option<String>,
        #[serde(default)]
        merged: Option<bool>,
        #[serde(default)]
        draft: Option<bool>,
        #[serde(default)]
        author: Option<String>,
        #[serde(default)]
        is_bot: Option<bool>,
        #[serde(default)]
        ci_state: Option<String>,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        url: Option<String>,
        /// Check/suite name — present on `ci.completed`, absent on `pr.*`.
        #[serde(default)]
        name: Option<String>,
    },
    #[serde(other)]
    Unknown,
}

/// Parse the relay's `delivered_at`, falling back to the receipt time.
///
/// Deliberately not `perri_queue_native::parse_epoch` — that one only handles
/// the second-precision `…Z` / `+00:00` form and returns 0 on failure, which
/// would silently sort every event to the beginning of time.
fn parse_delivered_at(raw: Option<&str>) -> DateTime<Utc> {
    raw.and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(Utc::now)
}

// ── fan-out and status ────────────────────────────────────────────────────────

/// The organisation the subscribe frame asks for, until an ack says otherwise.
pub const DEFAULT_ORG: &str = "Carefeed";

/// What the subscriber knows about its own connection, shared with consumers
/// that need to know whether the relay is covering them right now.
#[derive(Debug, Default)]
pub struct RelayStatus {
    connected: std::sync::atomic::AtomicBool,
    org: std::sync::Mutex<Option<String>>,
}

impl RelayStatus {
    pub fn new() -> Self {
        Self::default()
    }

    /// True after the subscribe ack, false on close or error, and false for
    /// good once the subscriber is disabled (401 or close code 4001).
    pub fn connected(&self) -> bool {
        self.connected.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn set_connected(&self, connected: bool) {
        self.connected
            .store(connected, std::sync::atomic::Ordering::SeqCst);
    }

    /// The organisation whose events the relay sends: the ack's effective
    /// selection if it named one, else [`DEFAULT_ORG`].
    pub fn org(&self) -> String {
        self.org
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .unwrap_or_else(|| DEFAULT_ORG.to_owned())
    }

    pub fn set_org(&self, org: Option<String>) {
        *self.org.lock().unwrap_or_else(|e| e.into_inner()) = org;
    }
}

/// Where the subscriber publishes: every registered consumer gets every
/// signal, in order. Consumers register before [`spawn_with`].
#[derive(Clone, Default)]
pub struct RelayHub {
    subscribers: Vec<mpsc::UnboundedSender<QueueSignal>>,
    status: std::sync::Arc<RelayStatus>,
}

impl RelayHub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register an existing channel's sender.
    pub fn subscribe(&mut self, tx: mpsc::UnboundedSender<QueueSignal>) {
        self.subscribers.push(tx);
    }

    /// Register a new consumer and return its receiver.
    pub fn channel(&mut self) -> mpsc::UnboundedReceiver<QueueSignal> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.subscribers.push(tx);
        rx
    }

    /// Send `signal` to every subscriber; one whose receiver is gone is skipped.
    fn publish(&self, signal: QueueSignal) {
        for tx in &self.subscribers {
            let _ = tx.send(signal.clone());
        }
    }

    /// The connection status the subscriber keeps current.
    pub fn status(&self) -> std::sync::Arc<RelayStatus> {
        std::sync::Arc::clone(&self.status)
    }
}

/// Is the subscriber wanted at all? Perri's queue and Mother's notices are
/// its only consumers: with both off nothing is spawned.
pub fn relay_wanted(perri_enabled: bool, notices_enabled: bool) -> bool {
    perri_enabled || notices_enabled
}

/// Like [`spawn`], publishing to every subscriber of `hub` and keeping its
/// status current, for an explicit `url` and `token`.
pub fn spawn_with(url: String, token: String, hub: RelayHub) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        run_loop(&url, &token, &hub).await;
        // A subscriber that ended (401, 4001) never reconnects.
        hub.status.set_connected(false);
    })
}

// ── public entry point ────────────────────────────────────────────────────────

/// Spawn a long-running task that maintains a WebSocket connection to the
/// github-relay and publishes a [`QueueSignal`] to every subscriber of `hub`
/// for each event it parses.  Returns immediately; the task runs for the
/// lifetime of the daemon.
///
/// Does nothing if `relay_url` or `relay_token` is absent from the config.
pub fn spawn(config: Config, hub: RelayHub) {
    let (url, token) = match (&config.relay_url, &config.relay_token) {
        (Some(u), Some(t)) => (u.clone(), t.clone()),
        _ => {
            debug!("github-relay: relay_url/relay_token not configured — subscriber disabled");
            return;
        }
    };
    spawn_with(url, token, hub);
}

// ── connection loop ───────────────────────────────────────────────────────────

async fn run_loop(url: &str, token: &str, hub: &RelayHub) {
    let mut backoff_secs: u64 = 1;

    loop {
        let outcome = connect_and_subscribe(url, token, hub).await;
        hub.status.set_connected(false);
        match outcome {
            Ok(()) => {
                // Normal close (server shutdown etc.) — reconnect.
                info!("github-relay: connection closed, reconnecting in {backoff_secs}s");
            }
            Err(RelayError::BadToken) => {
                warn!("github-relay: token rejected (401) — subscriber disabled; obtain a new token via https://github-relay.carefeed.com/auth/token");
                return; // non-retryable
            }
            Err(RelayError::Other(e)) => {
                warn!("github-relay: connection error ({e:#}), reconnecting in {backoff_secs}s");
            }
        }

        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(60);
    }
}

// ── per-connection logic ──────────────────────────────────────────────────────

#[derive(Debug)]
enum RelayError {
    BadToken,
    Other(anyhow::Error),
}

async fn connect_and_subscribe(url: &str, token: &str, hub: &RelayHub) -> Result<(), RelayError> {
    // Build the WebSocket request with the Authorization header.
    let mut request = url
        .into_client_request()
        .map_err(|e| RelayError::Other(e.into()))?;
    request.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {token}").parse().map_err(
            |e: tokio_tungstenite::tungstenite::http::header::InvalidHeaderValue| {
                RelayError::Other(e.into())
            },
        )?,
    );
    request.headers_mut().insert(
        USER_AGENT,
        "nostromd/0.1 github-relay-subscriber"
            .parse()
            .unwrap_or_else(|_| "nostromd".parse().unwrap()),
    );

    let (mut ws, response) = connect_async_tls_with_config(request, None, false, None)
        .await
        .map_err(|e| {
            // tokio-tungstenite surfaces HTTP errors as HandshakeError; check for 401.
            let msg = e.to_string();
            if msg.contains("401") {
                RelayError::BadToken
            } else {
                RelayError::Other(e.into())
            }
        })?;

    info!("github-relay: connected (HTTP {})", response.status());

    // Declare subscription — org-wide, default event subset.
    let sub = serde_json::json!({ "type": "subscribe", "org": "Carefeed" });
    ws.send(Message::Text(sub.to_string()))
        .await
        .map_err(|e| RelayError::Other(e.into()))?;

    // Event loop.
    while let Some(msg) = ws.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                match serde_json::from_str::<RelayMsg>(&text) {
                    Ok(RelayMsg::Ack { events, org }) => {
                        info!("github-relay: subscribed, effective events={events:?}");
                        hub.status.set_org(org.filter(|o| !o.trim().is_empty()));
                        hub.status.set_connected(true);
                        // Re-fetch on (re)connect to fill any gap during the outage.
                        hub.publish(QueueSignal::Reconnected);
                    }
                    Ok(RelayMsg::Event {
                        event_type,
                        event_id,
                        delivered_at,
                        repo,
                        number,
                        head_sha,
                        reviewer,
                        review_state,
                        state,
                        merged,
                        draft,
                        author,
                        is_bot,
                        ci_state,
                        title,
                        url,
                        name,
                    }) => {
                        let repo_label = repo.as_deref().unwrap_or("?");
                        // PR events carry `number`; ci.completed carries `name`
                        // (the check/suite name) instead — show whichever applies.
                        let detail = match (number, name.clone()) {
                            (Some(n), _) => format!("#{n}"),
                            (None, Some(n)) => n,
                            (None, None) => "?".to_string(),
                        };
                        info!("github-relay: event {event_type} {repo_label} {detail}");
                        // Every parsed event is forwarded.  Deciding what an
                        // event *means* — including that an unrecognised type
                        // means nothing — belongs to the queue's classifier
                        // (`perri_queue_targeted::classify_event`) so it lives
                        // in one place instead of two that can drift.  The cost
                        // of forwarding is an in-process channel send.
                        hub.publish(QueueSignal::Event(RelayEvent {
                            event_type,
                            event_id,
                            delivered_at: Some(parse_delivered_at(delivered_at.as_deref())),
                            repo,
                            number,
                            head_sha,
                            reviewer,
                            review_state,
                            state,
                            merged,
                            draft,
                            author,
                            is_bot,
                            ci_state,
                            title,
                            url,
                            name,
                        }));
                    }
                    Ok(RelayMsg::Unknown) | Err(_) => {
                        // Unknown message type or parse error — ignore per protocol.
                    }
                }
            }
            Ok(Message::Close(frame)) => {
                let code = frame.as_ref().map(|f| f.code.into()).unwrap_or(0u16);
                if code == 4001 {
                    // Token revoked — non-retryable close code.
                    warn!("github-relay: token revoked (close code 4001) — subscriber disabled");
                    return Err(RelayError::BadToken);
                }
                info!("github-relay: server closed (code {code})");
                return Ok(());
            }
            Ok(Message::Ping(_) | Message::Pong(_) | Message::Binary(_) | Message::Frame(_)) => {
                // Ping/pong handled by tungstenite automatically; ignore others.
            }
            Err(e) => {
                return Err(RelayError::Other(e.into()));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    //! The hub and the status, against a fake relay on 127.0.0.1. Nothing
    //! here sleeps or has a time limit: a test waits for a signal or a
    //! condition. The reconnect test runs on paused time so the client's
    //! one-second back-off passes at once.

    use super::*;

    use std::io::Write;
    use std::sync::{Arc, Mutex};

    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::handshake::server::{
        ErrorResponse, Request, Response as HandshakeResponse,
    };
    use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;
    use tokio_tungstenite::{accept_async, accept_hdr_async};

    // ── the fake relay ──

    enum Cmd {
        Send(String),
        Close,
        CloseWith(u16),
    }

    struct FakeRelay {
        url: String,
        /// The first frame of each connection (the client's `subscribe`).
        subscribes: mpsc::UnboundedReceiver<String>,
        cmds: mpsc::UnboundedSender<Cmd>,
    }

    impl FakeRelay {
        fn send(&self, frame: &str) {
            let _ = self.cmds.send(Cmd::Send(frame.to_owned()));
        }
        fn close(&self) {
            let _ = self.cmds.send(Cmd::Close);
        }
        fn close_with(&self, code: u16) {
            let _ = self.cmds.send(Cmd::CloseWith(code));
        }
    }

    /// Accepts connections one after another; for each, reports the client's
    /// first frame, then does what it is told until told to close.
    async fn fake_relay() -> FakeRelay {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sub_tx, subscribes) = mpsc::unbounded_channel();
        let (cmds, mut cmd_rx) = mpsc::unbounded_channel::<Cmd>();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let Ok(mut ws) = accept_async(stream).await else {
                    continue;
                };
                if let Some(Ok(Message::Text(frame))) = ws.next().await {
                    let _ = sub_tx.send(frame);
                }
                loop {
                    match cmd_rx.recv().await {
                        Some(Cmd::Send(text)) => {
                            let _ = ws.send(Message::Text(text)).await;
                        }
                        Some(Cmd::Close) => {
                            let _ = ws.close(None).await;
                            break;
                        }
                        Some(Cmd::CloseWith(code)) => {
                            let _ = ws
                                .send(Message::Close(Some(CloseFrame {
                                    code: CloseCode::from(code),
                                    reason: "".into(),
                                })))
                                .await;
                            let _ = ws.flush().await;
                            break;
                        }
                        None => return,
                    }
                }
            }
        });
        FakeRelay {
            url: format!("ws://{addr}/subscribe"),
            subscribes,
            cmds,
        }
    }

    /// A relay that answers every handshake with HTTP 401.
    #[allow(clippy::result_large_err)] // the handshake callback's `ErrorResponse` is fixed by tungstenite
    async fn rejecting_relay() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let _ = accept_hdr_async(
                    stream,
                    |_: &Request,
                     _: HandshakeResponse|
                     -> Result<HandshakeResponse, ErrorResponse> {
                        Err(tokio_tungstenite::tungstenite::http::Response::builder()
                            .status(401)
                            .body(None)
                            .unwrap())
                    },
                )
                .await;
            }
        });
        format!("ws://{addr}/subscribe")
    }

    const ACK: &str = r#"{"type":"ack","events":["pr.merged","pr.closed"]}"#;
    const ACK_ACME: &str = r#"{"type":"ack","events":["pr.merged"],"org":"Acme"}"#;
    const MERGED: &str = r#"{"type":"event","event_type":"pr.merged","repo":"Carefeed/app","number":7,"merged":true}"#;
    const CI: &str =
        r#"{"type":"event","event_type":"ci.completed","repo":"Carefeed/app","name":"build"}"#;

    /// Wait until `cond` holds (a condition, not a time).
    async fn until(mut cond: impl FnMut() -> bool) {
        while !cond() {
            tokio::task::yield_now().await;
        }
    }

    async fn expect_reconnected(rx: &mut mpsc::UnboundedReceiver<QueueSignal>) {
        match rx.recv().await {
            Some(QueueSignal::Reconnected) => {}
            other => panic!("expected Reconnected, got {other:?}"),
        }
    }

    async fn expect_event(
        rx: &mut mpsc::UnboundedReceiver<QueueSignal>,
        event_type: &str,
        repo: &str,
        number: Option<u64>,
    ) {
        match rx.recv().await {
            Some(QueueSignal::Event(e)) => {
                assert_eq!(e.event_type, event_type);
                assert_eq!(e.repo.as_deref(), Some(repo));
                assert_eq!(e.number, number);
            }
            other => panic!("expected the {event_type} event, got {other:?}"),
        }
    }

    // ── fan-out ──

    #[tokio::test]
    async fn every_subscriber_gets_the_reconnect_and_every_event_in_order() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut a = hub.channel();
        let mut b = hub.channel();
        let (tx, mut c) = mpsc::unbounded_channel();
        hub.subscribe(tx);
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);

        let subscribe: serde_json::Value =
            serde_json::from_str(&relay.subscribes.recv().await.expect("a subscribe frame"))
                .expect("JSON");
        assert_eq!(subscribe["type"], "subscribe");
        assert_eq!(subscribe["org"], "Carefeed");

        relay.send(ACK);
        relay.send(MERGED);
        relay.send(CI);
        for rx in [&mut a, &mut b, &mut c] {
            expect_reconnected(rx).await;
            expect_event(rx, "pr.merged", "Carefeed/app", Some(7)).await;
            expect_event(rx, "ci.completed", "Carefeed/app", None).await;
        }
    }

    #[tokio::test]
    async fn a_subscriber_that_went_away_does_not_starve_the_others() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let gone = hub.channel();
        let mut kept = hub.channel();
        drop(gone);
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);
        relay.subscribes.recv().await.expect("a subscribe frame");
        relay.send(ACK);
        relay.send(MERGED);
        expect_reconnected(&mut kept).await;
        expect_event(&mut kept, "pr.merged", "Carefeed/app", Some(7)).await;
    }

    // ── status ──

    #[tokio::test]
    async fn the_status_is_down_before_the_ack_up_after_it_and_down_when_the_server_closes() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        assert!(!status.connected(), "not connected before anything");
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);

        relay.subscribes.recv().await.expect("a subscribe frame");
        assert!(!status.connected(), "subscribed but not acked");

        relay.send(ACK);
        expect_reconnected(&mut rx).await;
        assert!(
            status.connected(),
            "acked: up by the time Reconnected is seen"
        );

        relay.close();
        until(|| !status.connected()).await;
        assert!(!status.connected());
    }

    #[tokio::test(start_paused = true)]
    async fn after_a_close_the_client_reconnects_and_signals_again() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);

        relay.subscribes.recv().await.expect("the first subscribe");
        relay.send(ACK);
        expect_reconnected(&mut rx).await;
        relay.close();

        // The back-off runs on paused time; the client comes back.
        relay.subscribes.recv().await.expect("a second subscribe");
        relay.send(ACK);
        relay.send(MERGED);
        expect_reconnected(&mut rx).await;
        assert!(status.connected(), "up again");
        expect_event(&mut rx, "pr.merged", "Carefeed/app", Some(7)).await;
    }

    #[tokio::test]
    async fn the_org_is_carefeed_unless_the_ack_names_another() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        assert_eq!(status.org(), "Carefeed");
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);
        relay.subscribes.recv().await.expect("a subscribe frame");
        relay.send(ACK);
        expect_reconnected(&mut rx).await;
        assert_eq!(status.org(), "Carefeed", "an ack without an org");

        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        let _task = spawn_with(relay.url.clone(), "tok".into(), hub);
        relay.subscribes.recv().await.expect("a subscribe frame");
        relay.send(ACK_ACME);
        expect_reconnected(&mut rx).await;
        assert_eq!(status.org(), "Acme", "the ack's effective org");
    }

    // ── a refused token ends it ──

    #[tokio::test]
    async fn an_http_401_ends_the_subscriber_with_the_relay_never_connected() {
        let url = rejecting_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        let task = spawn_with(url, "bad".into(), hub);
        task.await.expect("the task ends cleanly");
        assert!(!status.connected());
        assert!(rx.recv().await.is_none(), "nothing was published");
    }

    #[tokio::test]
    async fn a_close_with_code_4001_ends_the_subscriber() {
        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let status = hub.status();
        let task = spawn_with(relay.url.clone(), "revoked".into(), hub);
        relay.subscribes.recv().await.expect("a subscribe frame");
        relay.close_with(4001);
        task.await.expect("the task ends cleanly");
        assert!(!status.connected());
        assert!(rx.recv().await.is_none(), "nothing was published");
    }

    // ── what is wanted ──

    #[test]
    fn the_subscriber_is_wanted_when_perri_or_notices_use_it() {
        assert!(relay_wanted(true, true));
        assert!(relay_wanted(true, false));
        assert!(relay_wanted(false, true));
        assert!(!relay_wanted(false, false));
    }

    // ── the token never reaches the log ──

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Write for Captured {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn the_token_is_never_logged() {
        let captured = Captured::default();
        let writer = captured.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);
        tracing::trace!("relay-canary-capture-check");

        let mut relay = fake_relay().await;
        let mut hub = RelayHub::new();
        let mut rx = hub.channel();
        let _task = spawn_with(relay.url.clone(), "SECRET-TOKEN-123".into(), hub);
        relay.subscribes.recv().await.expect("a subscribe frame");
        relay.send(ACK);
        relay.send(MERGED);
        expect_reconnected(&mut rx).await;
        expect_event(&mut rx, "pr.merged", "Carefeed/app", Some(7)).await;
        relay.close_with(4001);
        _task.await.expect("ends");

        let logged = String::from_utf8_lossy(&captured.0.lock().unwrap()).into_owned();
        assert!(logged.contains("relay-canary-capture-check"), "{logged}");
        assert!(!logged.contains("SECRET-TOKEN"), "{logged}");
    }
}
