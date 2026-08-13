//! github-relay WebSocket subscriber.
//!
//! Connects to the github-relay service and triggers an immediate Perri queue
//! refresh whenever a relevant GitHub event arrives (PR lifecycle, CI completion).
//! The relay delivers events within ~3 seconds of the GitHub webhook firing,
//! replacing the queue's poll-cycle lag with near-real-time updates.
//!
//! # The queue signal
//!
//! Events reach the queue as a typed [`QueueSignal`] rather than a payload-free
//! `()`, carrying the relay's full description of what happened — repo, PR
//! number, HEAD SHA, reviewer, review state, and so on.
//!
//! **Today the queue ignores the payload and does a full refresh for every
//! signal**, exactly as it did when the signal was a bare `()`. The payload is
//! carried now so the wire format lands once; making each event drive a
//! *targeted* update is follow-up work
//! (`.claude/plans/targeted-relay-refresh-engine.md`).
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
//!   3. Sends a refresh signal so the queue re-fetches from GitHub to fill any gap.
//!
//! A 401 on the initial handshake is non-retryable — the token is bad and the
//! loop exits permanently (no point burning CPU on a bad credential).

use std::time::Duration;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use futures::{SinkExt, StreamExt};
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
#[derive(Debug, Clone)]
pub enum QueueSignal {
    /// Connected and the subscription was acked.  The relay buffers nothing for
    /// an absent client, so the queue must do a **full** refresh to reconcile
    /// whatever it missed while disconnected.
    Reconnected,
    /// A queue-relevant GitHub event arrived.
    Event(RelayEvent),
}

// ── message shapes ────────────────────────────────────────────────────────────

/// Every message the relay sends is a JSON object with a "type" discriminator.
/// We only care about the `event` type; all others are silently ignored.
///
/// Every body field is `#[serde(default)]` and `Unknown` catches unrecognised
/// discriminators, so the relay can add to the vocabulary without breaking us.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RelayMsg {
    Ack {
        #[serde(default)]
        events: Vec<String>,
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

// ── event filter ─────────────────────────────────────────────────────────────

/// Returns true for event types that should trigger an immediate queue refresh.
fn is_queue_relevant(event_type: &str) -> bool {
    matches!(
        event_type,
        "pr.opened"
            | "pr.closed"
            | "pr.merged"
            | "pr.reopened"
            | "pr.synchronize"
            | "pr.review_requested"
            | "pr.review_request_removed"
            | "pr.review_submitted"
            | "ci.completed"
    )
}

// ── public entry point ────────────────────────────────────────────────────────

/// Spawn a long-running task that maintains a WebSocket connection to the
/// github-relay and sends a [`QueueSignal`] on `signal_tx` whenever a
/// queue-relevant event arrives.  Returns immediately; the task runs for the
/// lifetime of the daemon.
///
/// Does nothing if `relay_url` or `relay_token` is absent from the config.
pub fn spawn(config: Config, signal_tx: mpsc::UnboundedSender<QueueSignal>) {
    let (url, token) = match (&config.relay_url, &config.relay_token) {
        (Some(u), Some(t)) => (u.clone(), t.clone()),
        _ => {
            debug!("github-relay: relay_url/relay_token not configured — subscriber disabled");
            return;
        }
    };

    tokio::spawn(async move {
        run_loop(&url, &token, signal_tx).await;
    });
}

// ── connection loop ───────────────────────────────────────────────────────────

async fn run_loop(url: &str, token: &str, signal_tx: mpsc::UnboundedSender<QueueSignal>) {
    let mut backoff_secs: u64 = 1;

    loop {
        match connect_and_subscribe(url, token, &signal_tx).await {
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

async fn connect_and_subscribe(
    url: &str,
    token: &str,
    signal_tx: &mpsc::UnboundedSender<QueueSignal>,
) -> Result<(), RelayError> {
    // Build the WebSocket request with the Authorization header.
    let mut request = url
        .into_client_request()
        .map_err(|e| RelayError::Other(e.into()))?;
    request.headers_mut().insert(
        AUTHORIZATION,
        format!("Bearer {token}")
            .parse()
            .map_err(|e: tokio_tungstenite::tungstenite::http::header::InvalidHeaderValue| {
                RelayError::Other(e.into())
            })?,
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

    info!(
        "github-relay: connected (HTTP {})",
        response.status()
    );

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
                    Ok(RelayMsg::Ack { events }) => {
                        info!("github-relay: subscribed, effective events={events:?}");
                        // Re-fetch on (re)connect to fill any gap during the outage.
                        let _ = signal_tx.send(QueueSignal::Reconnected);
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
                        debug!("github-relay: event {event_type}");
                        // The relevance filter stays here for now: the queue's
                        // only handler is "full refresh", so forwarding
                        // irrelevant types would start triggering refreshes that
                        // don't happen today.  Folding relevance into the
                        // queue's classifier is the targeted-update engine's job.
                        if is_queue_relevant(&event_type) {
                            let repo_label = repo.as_deref().unwrap_or("?");
                            // PR events carry `number`; ci.completed carries `name`
                            // (the check/suite name) instead — show whichever applies.
                            let detail = match (number, name.clone()) {
                                (Some(n), _) => format!("#{n}"),
                                (None, Some(n)) => n,
                                (None, None) => "?".to_string(),
                            };
                            info!("github-relay: triggering queue refresh ({event_type} {repo_label} {detail})");
                            let _ = signal_tx.send(QueueSignal::Event(RelayEvent {
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
