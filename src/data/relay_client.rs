//! github-relay WebSocket subscriber.
//!
//! Connects to the github-relay service and triggers an immediate Perri queue
//! refresh whenever a relevant GitHub event arrives (PR lifecycle, CI completion).
//! The relay delivers events within ~3 seconds of the GitHub webhook firing,
//! replacing the queue's poll-cycle lag with near-real-time updates.
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

// ── message shapes ────────────────────────────────────────────────────────────

/// Every message the relay sends is a JSON object with a "type" discriminator.
/// We only care about the `event` type; all others are silently ignored.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RelayMsg {
    Ack {
        #[serde(default)]
        events: Vec<String>,
    },
    Event {
        event_type: String,
    },
    #[serde(other)]
    Unknown,
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
/// github-relay and signals `refresh_tx` whenever a queue-relevant event
/// arrives.  Returns immediately; the task runs for the lifetime of the daemon.
///
/// Does nothing if `relay_url` or `relay_token` is absent from the config.
pub fn spawn(config: Config, refresh_tx: mpsc::UnboundedSender<()>) {
    let (url, token) = match (&config.relay_url, &config.relay_token) {
        (Some(u), Some(t)) => (u.clone(), t.clone()),
        _ => {
            debug!("github-relay: relay_url/relay_token not configured — subscriber disabled");
            return;
        }
    };

    tokio::spawn(async move {
        run_loop(&url, &token, refresh_tx).await;
    });
}

// ── connection loop ───────────────────────────────────────────────────────────

async fn run_loop(url: &str, token: &str, refresh_tx: mpsc::UnboundedSender<()>) {
    let mut backoff_secs: u64 = 1;

    loop {
        match connect_and_subscribe(url, token, &refresh_tx).await {
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
    refresh_tx: &mpsc::UnboundedSender<()>,
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
    ws.send(Message::Text(sub.to_string().into()))
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
                        let _ = refresh_tx.send(());
                    }
                    Ok(RelayMsg::Event { event_type }) => {
                        debug!("github-relay: event {event_type}");
                        if is_queue_relevant(&event_type) {
                            info!("github-relay: triggering queue refresh ({event_type})");
                            let _ = refresh_tx.send(());
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
