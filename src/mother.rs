//! Mother job queue client — async helpers for interacting with the Mother CLI
//! and its on-disk state directory.
//!
//! **Env overrides:**
//! - `MOTHER_BIN`             — path to the `mother` binary (default: `mother`)
//! - `MOTHER_ROOT`            — state root (default: `$HOME/.mother`)
//! - `MOTHER_STATUSLINE_CACHE`— statusline cache file (default: `/tmp/.mother-statusline`)

use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::process::Command;
use tracing::warn;

// ── env helpers ──────────────────────────────────────────────────────────────

pub fn mother_bin() -> String {
    std::env::var("MOTHER_BIN").unwrap_or_else(|_| "mother".into())
}

pub fn mother_root() -> PathBuf {
    std::env::var("MOTHER_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            dirs_next::home_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".mother")
        })
}

pub fn statusline_cache_path() -> PathBuf {
    std::env::var("MOTHER_STATUSLINE_CACHE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp/.mother-statusline"))
}

// ── MotherStatus ─────────────────────────────────────────────────────────────

/// Summary counts parsed from the statusline cache.
///
/// Cache format: `running:queued:failed:awaiting` (four colon-separated
/// integers).  Three-field caches (pre-`awaiting` field) are handled by
/// defaulting the missing field to 0.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct MotherStatus {
    pub running: usize,
    pub queued: usize,
    pub failed: usize,
    pub awaiting: usize,
}

impl MotherStatus {
    /// Parse from a statusline string (e.g. `"1:2:0:1"`).
    pub fn parse(s: &str) -> Self {
        let s = s.trim();
        let parts: Vec<&str> = s.split(':').collect();
        let get = |i: usize| {
            parts
                .get(i)
                .and_then(|v| v.trim().parse::<usize>().ok())
                .unwrap_or(0usize)
        };
        Self {
            running: get(0),
            queued: get(1),
            failed: get(2),
            awaiting: get(3),
        }
    }

    /// Load from the statusline cache file.  Returns `Default` on any error.
    pub fn load() -> Self {
        let path = statusline_cache_path();
        match std::fs::read_to_string(&path) {
            Ok(s) => Self::parse(&s),
            Err(_) => Self::default(),
        }
    }

    /// Short string suitable for the global status bar.
    pub fn status_line(&self) -> String {
        if self.awaiting > 0 {
            format!("⚙ mother: {} awaiting", self.awaiting)
        } else if self.running > 0 || self.queued > 0 {
            format!("⚙ mother: {} running, {} queued", self.running, self.queued)
        } else {
            "⚙ mother: idle".to_string()
        }
    }
}

// ── MotherJob ─────────────────────────────────────────────────────────────────

/// A Mother job record, deserialised from `mother list --format json`.
///
/// All optional fields are `None` when absent in the JSON; extra fields added
/// by future Mother versions are silently ignored via `#[serde(default)]`.
#[derive(Debug, Clone, serde::Serialize, Deserialize)]
pub struct MotherJob {
    pub id: String,
    pub state: String,
    #[serde(default)]
    pub repo: String,
    #[serde(default)]
    pub isolation: String,
    #[serde(default)]
    pub title: String,
    pub created_at: Option<DateTime<Utc>>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub plan_path: Option<String>,
    /// Question written by a worker that called `mother await --question "..."`.
    pub question: Option<String>,
    /// `"user"` when paused by an explicit `mother await`.
    pub paused_reason: Option<String>,
    /// Result of the Perri adherence pass: `"passed"`, `"blocked_for_human"`, etc.
    pub adherence_status: Option<String>,
    /// Which escalation tier spawned the current worker.
    pub current_tier: Option<String>,
}

impl MotherJob {
    /// True when this job is waiting for operator input.
    pub fn is_awaiting(&self) -> bool {
        self.state == "awaiting"
    }

    /// True when this job completed successfully.
    pub fn is_succeeded(&self) -> bool {
        self.state == "succeeded"
    }

    /// True when this job has failed (terminal).
    pub fn is_failed(&self) -> bool {
        self.state == "failed"
    }
}

// ── async helpers ─────────────────────────────────────────────────────────────

/// List all Mother jobs by shelling out to `mother list --format json`.
pub async fn list_jobs() -> Result<Vec<MotherJob>> {
    let out = Command::new(mother_bin())
        .args(["list", "--format", "json"])
        .output()
        .await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        warn!("mother list failed: {stderr}");
    }
    let jobs: Vec<MotherJob> = serde_json::from_slice(&out.stdout)?;
    Ok(jobs)
}

/// Read the last `n` lines from the job's log file using pure Rust I/O
/// (no shell-out).
pub async fn tail_log(id: &str, n: usize) -> Result<String> {
    let path = mother_root().join("logs").join(format!("{id}.log"));
    let content = tokio::fs::read_to_string(&path).await.unwrap_or_default();
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(n);
    Ok(lines[start..].join("\n"))
}

/// Cancel any non-terminal job (queued, ready, running, awaiting).
pub async fn cancel(id: &str) -> Result<()> {
    let out = Command::new(mother_bin())
        .args(["cancel", id])
        .output()
        .await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        warn!("mother cancel {id} failed: {stderr}");
    }
    Ok(())
}

/// Resume an `awaiting` job by providing the operator's answer.
pub async fn resume(id: &str, answer: &str) -> Result<()> {
    let out = Command::new(mother_bin())
        .args(["resume", id, answer])
        .output()
        .await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        warn!("mother resume {id} failed: {stderr}");
    }
    Ok(())
}

/// Re-enqueue a plan file (used to retry failed jobs via `mother add --plan`).
pub async fn add_plan(plan_path: &Path) -> Result<()> {
    let out = Command::new(mother_bin())
        .args(["add", "--plan", plan_path.to_str().unwrap_or_default()])
        .output()
        .await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        warn!("mother add --plan {} failed: {stderr}", plan_path.display());
    }
    Ok(())
}

// ── peek types ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
pub struct PeekTodo {
    pub status: String,
    pub content: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
pub struct PeekToolCall {
    pub tool: String,
    pub brief: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
pub struct PeekSnapshot {
    #[serde(default)]
    pub todos: Vec<PeekTodo>,
    #[serde(default)]
    pub tool_trail: Vec<PeekToolCall>,
    #[serde(default)]
    pub last_text: String,
    pub question: Option<String>,
}

/// Fetch a live snapshot of a running job via `mother peek <id> --format json`.
pub async fn peek(id: &str) -> Result<PeekSnapshot> {
    let out = Command::new(mother_bin())
        .args(["peek", id, "--format", "json", "--tail", "5"])
        .output()
        .await?;
    if out.stdout.is_empty() {
        return Ok(PeekSnapshot::default());
    }
    let snap: PeekSnapshot = serde_json::from_slice(&out.stdout).unwrap_or_default();
    Ok(snap)
}
