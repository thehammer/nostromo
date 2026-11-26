//! The request schema and the delivery record. Closed: every struct denies
//! unknown fields, and every string is bounded.

use serde::{Deserialize, Serialize};

pub const MAX_TITLE_CHARS: usize = 64;
pub const MAX_BODY_CHARS: usize = 96;
/// APNs accepts a collapse id of at most 64 bytes.
pub const MAX_COLLAPSE_ID_BYTES: usize = 64;
pub const MAX_THREAD_ID_BYTES: usize = 64;
pub const MAX_TOKEN_CHARS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Environment {
    Sandbox,
    Production,
}

/// Apple's push type. Only `alert` exists: the relay never sends a background
/// (content-available) push.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushType {
    Alert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum InterruptionLevel {
    #[serde(rename = "active")]
    Active,
    #[serde(rename = "time-sensitive")]
    TimeSensitive,
    #[serde(rename = "passive")]
    Passive,
}

impl InterruptionLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::TimeSensitive => "time-sensitive",
            Self::Passive => "passive",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataKind {
    Mother,
    Decision,
    Review,
    Summary,
}

impl DataKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mother => "mother",
            Self::Decision => "decision",
            Self::Review => "review",
            Self::Summary => "summary",
        }
    }
}

/// What the app needs to route a tap: exactly these keys.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Data {
    pub item: String,
    pub kind: DataKind,
    pub host: String,
    #[serde(rename = "ref", default)]
    pub ref_: Option<String>,
    #[serde(default)]
    pub resolved: Option<bool>,
}

/// The primary's request. Mirrors `src/push/publisher.rs::RelayRequest`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRequest {
    pub push_id: String,
    pub apns_token: String,
    pub environment: Environment,
    pub push_type: PushType,
    pub priority: u8,
    pub expiration_unix: i64,
    pub collapse_id: String,
    pub thread_id: String,
    pub interruption_level: InterruptionLevel,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub body: Option<String>,
    pub badge: u32,
    pub mutable_content: bool,
    pub data: Data,
}

/// Why a well-formed request is refused.
#[derive(Debug, PartialEq, Eq)]
pub struct Invalid(pub &'static str);

/// 128 bits, lower-case hex.
pub fn is_push_id(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl PushRequest {
    pub fn validate(&self) -> Result<(), Invalid> {
        if !is_push_id(&self.push_id) {
            return Err(Invalid("push_id"));
        }
        let token = &self.apns_token;
        if token.is_empty()
            || token.len() > MAX_TOKEN_CHARS
            || !token.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(Invalid("apns_token"));
        }
        if !matches!(self.priority, 5 | 10) {
            return Err(Invalid("priority"));
        }
        if self.collapse_id.is_empty() || self.collapse_id.len() > MAX_COLLAPSE_ID_BYTES {
            return Err(Invalid("collapse_id"));
        }
        if self.thread_id.len() > MAX_THREAD_ID_BYTES {
            return Err(Invalid("thread_id"));
        }
        // Title and body go together or not at all (a badge-only push has neither).
        match (&self.title, &self.body) {
            (None, None) => {}
            (Some(t), Some(b))
                if t.chars().count() <= MAX_TITLE_CHARS && b.chars().count() <= MAX_BODY_CHARS => {}
            _ => return Err(Invalid("title_body")),
        }
        for s in [&self.data.item, &self.data.host] {
            if s.is_empty() || s.len() > 64 {
                return Err(Invalid("data"));
            }
        }
        if self.data.ref_.as_ref().is_some_and(|r| r.len() > 64) {
            return Err(Invalid("data"));
        }
        Ok(())
    }

    /// The kind a delivery record names: `withdraw` for the replacement of an
    /// item, `badge` for a push with no text, else the notification's kind.
    pub fn record_kind(&self) -> &'static str {
        if self.data.resolved == Some(true) {
            "withdraw"
        } else if self.title.is_none() {
            "badge"
        } else {
            self.data.kind.as_str()
        }
    }
}

/// One delivery attempt. Exactly these five fields, and nothing about the
/// notification's content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub push_id: String,
    /// Unix seconds.
    pub ts: i64,
    /// `mother`, `decision`, `review`, `summary`, `withdraw` or `badge`.
    pub kind: String,
    /// `accepted`, `rejected` or `error`.
    pub outcome: String,
    /// `ts` plus seven days: the table's TTL attribute.
    pub expires_at: i64,
}
