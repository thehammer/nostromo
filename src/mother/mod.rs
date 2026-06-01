//! Mother job queue client — async helpers for interacting with the Mother CLI
//! and its on-disk state directory.
//!
//! **Env overrides:**
//! - `MOTHER_BIN`             — path to the `mother` binary (default: `mother`)
//! - `MOTHER_ROOT`            — state root (default: `$HOME/.mother`)
//! - `MOTHER_BROKER_SOCK`     — broker socket (default: `$MOTHER_ROOT/broker.sock`)
//! - `MOTHER_STATUSLINE_CACHE`— statusline cache file (default: `/tmp/.mother-statusline`)

pub mod broker_client;
pub mod protocol;

use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
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

/// Path to the Mother broker Unix socket.
///
/// Resolution order: `MOTHER_BROKER_SOCK` env → `$MOTHER_ROOT/broker.sock`.
pub fn broker_sock_path() -> PathBuf {
    std::env::var("MOTHER_BROKER_SOCK")
        .map(PathBuf::from)
        .unwrap_or_else(|_| mother_root().join("broker.sock"))
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

    /// Derive status counts from a live job slice.
    ///
    /// Replaces `MotherStatus::load()` when the broker source feeds live state.
    pub fn from_jobs(jobs: &[MotherJob]) -> Self {
        let mut status = Self::default();
        for job in jobs {
            match job.state.as_str() {
                "running" => status.running += 1,
                "queued" | "ready" => status.queued += 1,
                "failed" => status.failed += 1,
                "awaiting" => status.awaiting += 1,
                _ => {}
            }
        }
        status
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

// ── Phase progress types ──────────────────────────────────────────────────────

/// A single agent phase within a Mother job (pipeline cycle or flat sequence).
///
/// `state` is a plain `String` so unknown future values are tolerated without
/// parse errors.  `findings` is present only on review-type phases.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct PhaseInfo {
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub request_type: String,
    #[serde(default)]
    pub state: String,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub findings: Option<u32>,
}

/// One cycle within a pipeline Mother job.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct CycleInfo {
    #[serde(default)]
    pub cycle: u32,
    #[serde(default)]
    pub phases: Vec<PhaseInfo>,
}

// ── MotherJob ─────────────────────────────────────────────────────────────────

/// A Mother job record, deserialised from `mother list --format json` or the
/// broker snapshot/event stream.
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
    /// Most recent activity description from the broker `current_activity` event.
    #[serde(default)]
    pub current_activity: Option<String>,
    /// Job kind — `"pipeline"` for multi-cycle jobs, absent for standard jobs.
    pub kind: Option<String>,
    /// Flat phase sequence for standard (non-pipeline) jobs.
    ///
    /// Absent in older/non-pipeline job records; decoded defensively via
    /// `#[serde(default)]`.
    #[serde(default)]
    pub phases: Vec<PhaseInfo>,
    /// Per-cycle phase sequences for pipeline jobs.
    ///
    /// Absent in non-pipeline job records; decoded defensively via
    /// `#[serde(default)]`.
    #[serde(default)]
    pub cycles: Vec<CycleInfo>,
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

/// Archive a single terminal-state job by id.
pub async fn archive(id: &str) -> Result<()> {
    let out = Command::new(mother_bin())
        .args(["archive", id])
        .output()
        .await?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        warn!("mother archive {id} failed: {stderr}");
    }
    Ok(())
}

/// Re-enqueue a plan file (used for new-plan enqueue via `mother add --plan`).
///
/// This is the MCP `MotherEnqueue` path only. Cancel/answer/retry operations
/// use the broker client (`BrokerClient::send_command`).
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
