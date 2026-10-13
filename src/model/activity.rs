//! Audit lines for model changes, appended to `~/.claude/activity.jsonl` in
//! that file's existing shape (see `agent_bus::ActivityEvent`) plus the
//! model-specific fields.

use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::{SecondsFormat, Utc};
use serde::Serialize;

use super::ModelTarget;

/// Same override the activity hook honours (`nostromo_activity_hook`).
pub const ACTIVITY_PATH_ENV: &str = "NOSTROMO_ACTIVITY_PATH";

/// `$NOSTROMO_ACTIVITY_PATH`, else `~/.claude/activity.jsonl`.
pub fn activity_path() -> PathBuf {
    std::env::var(ACTIVITY_PATH_ENV)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs_next::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".claude")
                .join("activity.jsonl")
        })
}

/// `model_switch` or `model_default`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelActivityKind {
    ModelSwitch,
    ModelDefault,
}

/// How a request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Applied,
    Failed,
    Denied,
    Expired,
    Refused,
}

/// One activity line.
#[derive(Debug, Clone, Serialize)]
pub struct ModelActivity {
    /// The agent of the focus (the `agent` field of every activity line).
    pub agent: String,
    pub kind: ModelActivityKind,
    pub summary: String,
    pub session_id: Option<String>,
    pub agent_type: Option<String>,
    pub focus_tag: Option<String>,
    pub from: Option<ModelTarget>,
    pub to: Option<ModelTarget>,
    /// `user`, `script`, `agent:<name>` or `network`.
    pub actor: String,
    pub outcome: Outcome,
    /// The agent's stated reason, or why the request failed or was refused.
    pub reason: Option<String>,
    /// Bishop's posture at the time, or `None` when unknown.
    pub posture: Option<String>,
}

#[derive(Serialize)]
struct Line<'a> {
    ts: String,
    #[serde(flatten)]
    activity: &'a ModelActivity,
}

/// Bishop's current posture label, if a posture file is readable.
pub fn current_posture() -> Option<String> {
    crate::data::rate_limits::PostureSnapshot::load().map(|p| p.posture.label().to_owned())
}

/// Append `activity` to the log at `path`. Best effort: a failure is logged,
/// never surfaced (the switch itself already happened or failed).
pub fn append(path: &Path, activity: &ModelActivity) {
    let line = Line {
        ts: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        activity,
    };
    let result = (|| -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut text = serde_json::to_string(&line)?;
        text.push('\n');
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        f.write_all(text.as_bytes())?;
        Ok(())
    })();
    if let Err(e) = result {
        tracing::warn!(path = %path.display(), "could not append model activity: {e:#}");
    }
}
