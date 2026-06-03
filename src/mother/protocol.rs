//! Serde types for the Mother broker NDJSON protocol (Phase 0 wire contract).
//!
//! The broker uses a line-framed JSON envelope in both directions:
//! `{"v":1,"dir":"cmd|ack|event","t":"<type>","id":"<uuid>","ts":"<iso8601>","data":{...}}`
//!
//! Reference: `mother/docs/prds/mother-ipc-protocol.md` and
//! `plugins/mother/broker/{envelope,transport,commands,server,subscriptions,main}.go`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::MotherJob;

pub const PROTOCOL_VERSION: u32 = 1;

// ── Envelope ─────────────────────────────────────────────────────────────────

/// Direction of an envelope message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dir {
    Cmd,
    Ack,
    Event,
}

/// Canonical NDJSON envelope used in both directions.
///
/// `data` is kept as a raw JSON value so callers can deserialize it into the
/// type-specific payload without a double-parse.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u32,
    pub dir: Dir,
    /// The event kind / command name / ack type (field name `t` on the wire).
    #[serde(rename = "t")]
    pub kind: String,
    pub id: String,
    pub ts: String,
    #[serde(default)]
    pub data: serde_json::Value,
}

impl Envelope {
    /// Build a command envelope with a fresh UUID and millisecond-precision timestamp.
    pub fn command(kind: &str, data: serde_json::Value) -> Self {
        Self {
            v: PROTOCOL_VERSION,
            dir: Dir::Cmd,
            kind: kind.to_string(),
            id: Uuid::new_v4().to_string(),
            ts: millis_ts(),
            data,
        }
    }
}

/// Generate a millisecond-precision ISO8601 UTC timestamp.
///
/// Format: `2026-05-31T17:30:00.000Z` — deliberately millis (not micros) so
/// Swift's `.iso8601` date decoder strategy accepts it.
fn millis_ts() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let secs = ms / 1000;
    let frac = ms % 1000;
    // Format as ISO8601 using chrono so we get the exact layout the broker expects.
    use chrono::{TimeZone, Utc};
    let dt = Utc
        .timestamp_opt(secs as i64, (frac * 1_000_000) as u32)
        .single()
        .unwrap_or_else(chrono::Utc::now);
    dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

// ── Command builders ──────────────────────────────────────────────────────────
//
// Each builder assigns a fresh UUID `id` and current millis `ts`.

/// Build an `answer` command (resume an awaiting job with an operator reply).
pub fn cmd_answer(job: &str, text: &str) -> Envelope {
    Envelope::command("answer", serde_json::json!({ "job": job, "text": text }))
}

/// Build a `cancel` command.
pub fn cmd_cancel(job: &str) -> Envelope {
    Envelope::command("cancel", serde_json::json!({ "job": job }))
}

/// Build a `retry` command (in-place retry by job id).
pub fn cmd_retry(job: &str) -> Envelope {
    Envelope::command("retry", serde_json::json!({ "job": job }))
}

/// Build a `force-start` command — bypasses quota cap and conservative posture.
pub fn cmd_force_start(job: &str) -> Envelope {
    Envelope::command("force-start", serde_json::json!({ "job": job }))
}

/// Build a `subscribe` command, filtering requested categories to only those
/// advertised by the broker in its `hello` event.
///
/// The subscription name is always `"queue"` and covers all jobs.
pub fn cmd_subscribe(advertised_capabilities: &[String]) -> Envelope {
    // Desired categories — intersect with what the broker actually advertises.
    const DESIRED: &[&str] = &["state", "activity", "await", "current_activity", "quota"];
    let cats: Vec<&str> = DESIRED
        .iter()
        .filter(|&&c| advertised_capabilities.iter().any(|cap| cap == c))
        .copied()
        .collect();
    Envelope::command(
        "subscribe",
        serde_json::json!({
            "sub": "queue",
            "jobs": ["all"],
            "categories": cats,
        }),
    )
}

// ── Ack ──────────────────────────────────────────────────────────────────────

/// Parsed `data` payload of an ack envelope.
#[derive(Debug, Clone, Deserialize)]
pub struct AckData {
    pub ok: bool,
    pub error: Option<AckError>,
    /// Job id echoed back on success (answer/cancel/retry).
    pub job: Option<String>,
    /// Subscription name echoed back on subscribe ack.
    pub sub: Option<String>,
}

/// Error object inside a negative ack.
#[derive(Debug, Clone, Deserialize)]
pub struct AckError {
    pub code: String,
    pub message: String,
}

// ── BrokerErrorCode ───────────────────────────────────────────────────────────

/// Typed error codes returned by the broker in negative acks.
///
/// Switch on `BrokerErrorCode`, **never** on the message text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrokerErrorCode {
    NoSuchJob,
    InvalidState,
    Malformed,
    Unavailable,
    VersionMismatch,
    Unauthorized,
    Internal,
    Other(String),
}

impl BrokerErrorCode {
    /// Parse a broker error code string into a typed enum variant.
    ///
    /// Named `parse_code` (not `from_str`) to avoid shadowing `std::str::FromStr`.
    pub fn parse_code(s: &str) -> Self {
        match s {
            "no_such_job" => Self::NoSuchJob,
            "invalid_state" => Self::InvalidState,
            "malformed" => Self::Malformed,
            "unavailable" => Self::Unavailable,
            "version_mismatch" => Self::VersionMismatch,
            "unauthorized" => Self::Unauthorized,
            "internal" => Self::Internal,
            other => Self::Other(other.to_string()),
        }
    }

    /// Operator-facing message suitable for display in `status_note` or a toast.
    pub fn operator_message(&self, verb: &str, detail: &str) -> String {
        match self {
            Self::NoSuchJob => "Job no longer exists.".to_string(),
            Self::InvalidState => {
                format!("Can't {verb} — job is no longer in a valid state for that.")
            }
            Self::Malformed => "Internal error: malformed command.".to_string(),
            Self::Unavailable => "Mother is busy, try again.".to_string(),
            Self::VersionMismatch => {
                "Mother broker version incompatible — update Nostromo or the broker.".to_string()
            }
            Self::Unauthorized => "Unauthorized.".to_string(),
            Self::Internal | Self::Other(_) => {
                format!("Mother failed to apply the action: {detail}.")
            }
        }
    }
}

// ── Hello event ───────────────────────────────────────────────────────────────

/// Payload of the `hello` event sent by the broker on connect.
#[derive(Debug, Clone, Deserialize)]
pub struct HelloData {
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

// ── Snapshot event ────────────────────────────────────────────────────────────

/// Payload of the `snapshot` event sent in response to `subscribe`.
#[derive(Debug, Clone, Deserialize)]
pub struct SnapshotData {
    pub sub: String,
    pub jobs: Vec<MotherJob>,
}

// ── State / await / current_activity event payloads ───────────────────────────

/// Common fields present in state-changing and activity broker events.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct EventData {
    /// Job id that this event applies to.
    pub job: Option<String>,
    /// Event category (`state`, `activity`, `await`, `current_activity`, `quota`).
    pub category: Option<String>,
    // ── state events ──────────────────────────────────────────────────────────
    pub state: Option<String>,
    // ── await events ──────────────────────────────────────────────────────────
    pub question: Option<String>,
    pub paused_reason: Option<String>,
    // ── current_activity events ───────────────────────────────────────────────
    pub activity: Option<String>,
    // ── retried / escalated ───────────────────────────────────────────────────
    pub to_state: Option<String>,
}

// ── State fold ────────────────────────────────────────────────────────────────

/// Result of applying a broker event kind to a job's current state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FoldResult {
    /// The event sets the job state to this string.
    SetState(String),
    /// The event does not affect state (e.g. `current_activity`, `ping`).
    NoStateChange,
}

/// Mirror the broker's `foldState` function: derive the new job state (if any)
/// from an event kind and its data.
///
/// This ensures the client's derived state agrees with the broker's
/// no-gap/no-dup delivery contract.
pub fn fold_state(kind: &str, data: &EventData) -> FoldResult {
    match kind {
        "queued" | "ready" | "running" | "succeeded" | "failed" | "cancelled" => {
            FoldResult::SetState(kind.to_string())
        }
        "awaiting_input" | "paused_for_quota" => FoldResult::SetState("awaiting".to_string()),
        "resumed" | "auto_resumed" => FoldResult::SetState("ready".to_string()),
        "retried" | "escalated" => {
            let state = data.to_state.clone().unwrap_or_else(|| "ready".to_string());
            FoldResult::SetState(state)
        }
        _ => FoldResult::NoStateChange,
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Envelope round-trip ───────────────────────────────────────────────────

    #[test]
    fn envelope_command_has_correct_wire_fields() {
        let env = cmd_answer("job-abc", "yes");
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(v["v"], 1);
        assert_eq!(v["dir"], "cmd");
        assert_eq!(v["t"], "answer");
        assert!(!v["id"].as_str().unwrap().is_empty());
        assert!(!v["ts"].as_str().unwrap().is_empty());
        // data.job (not job_id!) and data.text
        assert_eq!(v["data"]["job"], "job-abc");
        assert_eq!(v["data"]["text"], "yes");
    }

    #[test]
    fn cmd_cancel_data_job_field() {
        let env = cmd_cancel("job-xyz");
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(v["t"], "cancel");
        assert_eq!(v["data"]["job"], "job-xyz");
        assert!(
            v["data"].get("text").is_none(),
            "cancel should not have 'text'"
        );
    }

    #[test]
    fn cmd_retry_data_job_field() {
        let env = cmd_retry("job-xyz");
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(v["t"], "retry");
        assert_eq!(v["data"]["job"], "job-xyz");
    }

    #[test]
    fn cmd_force_start_data_job_field() {
        let env = cmd_force_start("job-xyz");
        let v = serde_json::to_value(&env).unwrap();
        assert_eq!(v["t"], "force-start");
        assert_eq!(v["data"]["job"], "job-xyz");
    }

    #[test]
    fn cmd_answer_unique_ids() {
        let e1 = cmd_answer("j", "a");
        let e2 = cmd_answer("j", "a");
        assert_ne!(e1.id, e2.id, "each command should get a unique UUID id");
    }

    #[test]
    fn ts_is_millis_iso8601() {
        let ts = millis_ts();
        // Should end with Z and have millisecond precision (.XXX)
        assert!(ts.ends_with('Z'), "ts should end with Z: {ts}");
        assert!(ts.contains('.'), "ts should have fractional seconds: {ts}");
        // Parse it back — must be valid ISO8601
        let parsed = chrono::DateTime::parse_from_rfc3339(&ts);
        assert!(parsed.is_ok(), "ts must be valid RFC3339: {ts}");
    }

    // ── Ack parsing ───────────────────────────────────────────────────────────

    #[test]
    fn ack_success_parses() {
        let json = r#"{"v":1,"dir":"ack","t":"cancel","id":"abc","ts":"2026-01-01T00:00:00.000Z","data":{"ok":true,"job":"job-1"}}"#;
        let env: Envelope = serde_json::from_str(json).unwrap();
        assert_eq!(env.dir, Dir::Ack);
        assert_eq!(env.kind, "cancel");
        let ack: AckData = serde_json::from_value(env.data).unwrap();
        assert!(ack.ok);
        assert_eq!(ack.job.as_deref(), Some("job-1"));
        assert!(ack.error.is_none());
    }

    #[test]
    fn ack_failure_parses_error_code() {
        let json = r#"{"v":1,"dir":"ack","t":"cancel","id":"abc","ts":"2026-01-01T00:00:00.000Z","data":{"ok":false,"error":{"code":"no_such_job","message":"not found"}}}"#;
        let env: Envelope = serde_json::from_str(json).unwrap();
        let ack: AckData = serde_json::from_value(env.data).unwrap();
        assert!(!ack.ok);
        let err = ack.error.unwrap();
        assert_eq!(
            BrokerErrorCode::parse_code(&err.code),
            BrokerErrorCode::NoSuchJob
        );
    }

    #[test]
    fn ack_unknown_error_code_maps_to_other() {
        let code = BrokerErrorCode::parse_code("some_future_code");
        assert!(matches!(code, BrokerErrorCode::Other(_)));
    }

    #[test]
    fn all_known_error_codes_parse() {
        for (s, expected) in [
            ("no_such_job", BrokerErrorCode::NoSuchJob),
            ("invalid_state", BrokerErrorCode::InvalidState),
            ("malformed", BrokerErrorCode::Malformed),
            ("unavailable", BrokerErrorCode::Unavailable),
            ("version_mismatch", BrokerErrorCode::VersionMismatch),
            ("unauthorized", BrokerErrorCode::Unauthorized),
            ("internal", BrokerErrorCode::Internal),
        ] {
            assert_eq!(BrokerErrorCode::parse_code(s), expected, "failed for {s}");
        }
    }

    // ── foldState table ───────────────────────────────────────────────────────

    #[test]
    fn fold_state_direct_states() {
        for kind in [
            "queued",
            "ready",
            "running",
            "succeeded",
            "failed",
            "cancelled",
        ] {
            let data = EventData::default();
            let result = fold_state(kind, &data);
            assert_eq!(
                result,
                FoldResult::SetState(kind.to_string()),
                "kind={kind}"
            );
        }
    }

    #[test]
    fn fold_state_awaiting_variants() {
        let data = EventData::default();
        assert_eq!(
            fold_state("awaiting_input", &data),
            FoldResult::SetState("awaiting".to_string())
        );
        assert_eq!(
            fold_state("paused_for_quota", &data),
            FoldResult::SetState("awaiting".to_string())
        );
    }

    #[test]
    fn fold_state_resumed() {
        let data = EventData::default();
        assert_eq!(
            fold_state("resumed", &data),
            FoldResult::SetState("ready".to_string())
        );
        assert_eq!(
            fold_state("auto_resumed", &data),
            FoldResult::SetState("ready".to_string())
        );
    }

    #[test]
    fn fold_state_retried_with_to_state() {
        let data = EventData {
            to_state: Some("running".to_string()),
            ..Default::default()
        };
        assert_eq!(
            fold_state("retried", &data),
            FoldResult::SetState("running".to_string())
        );
    }

    #[test]
    fn fold_state_retried_without_to_state_defaults_ready() {
        let data = EventData::default();
        assert_eq!(
            fold_state("retried", &data),
            FoldResult::SetState("ready".to_string())
        );
        assert_eq!(
            fold_state("escalated", &data),
            FoldResult::SetState("ready".to_string())
        );
    }

    #[test]
    fn fold_state_non_state_events_return_no_change() {
        for kind in ["current_activity", "ping", "hello", "snapshot"] {
            let data = EventData::default();
            assert_eq!(
                fold_state(kind, &data),
                FoldResult::NoStateChange,
                "kind={kind}"
            );
        }
    }

    // ── cmd_subscribe ─────────────────────────────────────────────────────────

    #[test]
    fn subscribe_intersects_with_advertised() {
        let caps = vec![
            "state".to_string(),
            "await".to_string(),
            "unknown_future".to_string(),
        ];
        let env = cmd_subscribe(&caps);
        let cats = env.data["categories"].as_array().unwrap();
        let cat_strs: Vec<&str> = cats.iter().map(|v| v.as_str().unwrap()).collect();
        assert!(cat_strs.contains(&"state"));
        assert!(cat_strs.contains(&"await"));
        assert!(
            !cat_strs.contains(&"unknown_future"),
            "should not include non-desired caps"
        );
        assert!(
            !cat_strs.contains(&"current_activity"),
            "current_activity not advertised so must be absent"
        );
    }

    #[test]
    fn subscribe_sub_is_queue_and_jobs_all() {
        let caps = vec!["state".to_string()];
        let env = cmd_subscribe(&caps);
        assert_eq!(env.kind, "subscribe");
        assert_eq!(env.data["sub"], "queue");
        assert_eq!(env.data["jobs"][0], "all");
    }
}
