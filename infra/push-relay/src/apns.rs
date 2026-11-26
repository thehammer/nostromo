//! The call to Apple: an ES256 provider token and one HTTP/2 request per
//! notification.

use std::fmt;

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};

use crate::model::{Environment, PushRequest};

pub const PRODUCTION_HOST: &str = "https://api.push.apple.com";
pub const SANDBOX_HOST: &str = "https://api.sandbox.push.apple.com";

/// What the APNs secret holds: the `.p8` key, its id, the team and the app's
/// bundle id (the `apns-topic`).
#[derive(Clone, Deserialize)]
pub struct ApnsCredentials {
    pub key_pem: String,
    pub key_id: String,
    pub team_id: String,
    pub topic: String,
}

// The key never prints.
impl fmt::Debug for ApnsCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApnsCredentials")
            .field("topic", &self.topic)
            .finish_non_exhaustive()
    }
}

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    iat: i64,
}

/// The provider authentication token: ES256, `kid` the key id, `iss` the team.
pub fn provider_token(creds: &ApnsCredentials, now: i64) -> Result<String, String> {
    let key = EncodingKey::from_ec_pem(creds.key_pem.as_bytes()).map_err(|e| e.to_string())?;
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(creds.key_id.clone());
    jsonwebtoken::encode(
        &header,
        &Claims {
            iss: &creds.team_id,
            iat: now,
        },
        &key,
    )
    .map_err(|e| e.to_string())
}

/// The JSON body Apple receives: the `aps` dictionary and the routing keys.
pub fn payload(req: &PushRequest) -> serde_json::Value {
    let mut aps = serde_json::Map::new();
    if let (Some(title), Some(body)) = (&req.title, &req.body) {
        aps.insert(
            "alert".into(),
            serde_json::json!({ "title": title, "body": body }),
        );
        aps.insert(
            "interruption-level".into(),
            req.interruption_level.as_str().into(),
        );
        aps.insert("thread-id".into(), req.thread_id.clone().into());
        // A passive replacement makes no sound; an alert does.
        if req.interruption_level.as_str() != "passive" {
            aps.insert("sound".into(), "default".into());
        }
    }
    // The notification service extension (W16) runs only for pushes that say so:
    // the flag maps to `aps.mutable-content` exactly, set when true and absent when false.
    if req.mutable_content {
        aps.insert("mutable-content".into(), 1.into());
    }
    aps.insert("badge".into(), req.badge.into());
    let mut out = serde_json::Map::new();
    out.insert("aps".into(), aps.into());
    out.insert("item".into(), req.data.item.clone().into());
    out.insert("kind".into(), req.data.kind.as_str().into());
    out.insert("host".into(), req.data.host.clone().into());
    if let Some(r) = &req.data.ref_ {
        out.insert("ref".into(), r.clone().into());
    }
    if let Some(resolved) = req.data.resolved {
        out.insert("resolved".into(), resolved.into());
    }
    out.into()
}

#[derive(Debug, PartialEq, Eq)]
pub struct Sent {
    pub status: u16,
    /// Apple's `reason`, when it refused (`BadDeviceToken`, ...): a fixed word.
    pub reason: Option<String>,
}

#[derive(Deserialize)]
struct Refusal {
    reason: Option<String>,
}

/// Send one notification. `base` replaces Apple's hosts (tests).
pub async fn send(
    http: &reqwest::Client,
    base: Option<&str>,
    jwt: &str,
    topic: &str,
    req: &PushRequest,
) -> Result<Sent, String> {
    let host = base.unwrap_or(match req.environment {
        Environment::Production => PRODUCTION_HOST,
        Environment::Sandbox => SANDBOX_HOST,
    });
    let response = http
        .post(format!(
            "{}/3/device/{}",
            host.trim_end_matches('/'),
            req.apns_token
        ))
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-push-type", "alert")
        .header("apns-priority", req.priority.to_string())
        .header("apns-expiration", req.expiration_unix.max(0).to_string())
        .header("apns-collapse-id", &req.collapse_id)
        .header("apns-topic", topic)
        .json(&payload(req))
        .send()
        .await
        .map_err(|e| e.without_url().to_string())?;
    let status = response.status().as_u16();
    let reason = if status == 200 {
        None
    } else {
        response
            .json::<Refusal>()
            .await
            .ok()
            .and_then(|r| r.reason)
            // Apple's reasons are short CamelCase words; anything else is dropped.
            .filter(|r| r.len() <= 64 && r.bytes().all(|b| b.is_ascii_alphanumeric()))
    };
    Ok(Sent { status, reason })
}
