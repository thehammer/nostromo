//! The request to the relay (W13): one `POST {relay_url}/push` per notification,
//! 5 s timeout, **no retry and no queue**.
//!
//! The body's types are the vocabulary of what may leave this machine: there is
//! no `background` push type, no free-text field, and a `data` object of exactly
//! the five keys the relay accepts.

use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::push::wire::PushEnvironment;

/// Apple's push type. Only `alert` exists: a notification is never removed by a
/// background (content-available) push (S1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PushType {
    Alert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum InterruptionLevel {
    #[serde(rename = "active")]
    Active,
    #[serde(rename = "time-sensitive")]
    TimeSensitive,
    #[serde(rename = "passive")]
    Passive,
}

/// What the app needs to route a tap; every value is from the vocabulary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RelayData {
    /// The item's opaque `item_ref`.
    pub item: String,
    /// `mother`, `decision`, `review` or `summary`.
    pub kind: String,
    pub host: String,
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    pub ref_: Option<String>,
    /// `true` on the replacement that withdraws an item.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved: Option<bool>,
}

/// The relay's request body. The relay mirrors it with `deny_unknown_fields`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RelayRequest {
    pub push_id: String,
    pub apns_token: String,
    pub environment: PushEnvironment,
    pub push_type: PushType,
    /// 10 now, 5 considerate of power (badge-only pushes).
    pub priority: u8,
    pub expiration_unix: i64,
    pub collapse_id: String,
    pub thread_id: String,
    pub interruption_level: InterruptionLevel,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub badge: u32,
    /// Sets `aps.mutable-content`, for W16's extension; `false` in W13.
    pub mutable_content: bool,
    pub data: RelayData,
}

/// What came of one send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// Apple accepted it.
    Delivered,
    /// The relay answered and Apple refused (`apns_status`, `apns_reason`).
    Rejected { status: u16, reason: Option<String> },
    /// The relay could not be reached or did not answer properly.
    Unreachable,
}

#[derive(Debug, Deserialize)]
struct RelayResponse {
    apns_status: u16,
    #[serde(default)]
    apns_reason: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Publisher {
    client: reqwest::Client,
    url: String,
    token_path: PathBuf,
}

impl Publisher {
    pub fn new(relay_url: &str, token_path: PathBuf) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap_or_default(),
            url: format!("{}/push", relay_url.trim_end_matches('/')),
            token_path,
        }
    }

    /// Send one notification. No retry: the next change of state is the retry.
    /// Logs the outcome class only, never a token, title or body.
    pub async fn send(&self, request: &RelayRequest) -> Delivery {
        // Read on every send, so rotating the token needs no restart.
        let token = match std::fs::read_to_string(&self.token_path) {
            Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
            _ => {
                warn!("push relay token is missing or empty");
                return Delivery::Unreachable;
            }
        };
        let response = match self
            .client
            .post(&self.url)
            .bearer_auth(token)
            .json(request)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                warn!(timeout = e.is_timeout(), "push relay request failed");
                return Delivery::Unreachable;
            }
        };
        let status = response.status();
        if !status.is_success() {
            warn!(status = status.as_u16(), "push relay answered with an error");
            return Delivery::Unreachable;
        }
        match response.json::<RelayResponse>().await {
            Ok(r) if r.apns_status == 200 => Delivery::Delivered,
            Ok(r) => Delivery::Rejected {
                status: r.apns_status,
                reason: r.apns_reason,
            },
            Err(_) => Delivery::Unreachable,
        }
    }
}
