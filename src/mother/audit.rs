//! The Mother audit trail: `~/.nostromo/audit/mother.jsonl`.
//!
//! The same rotating writer as the terminal audit (`crate::terminal::audit`):
//! directory `0700`, file `0600`, rotation at 10 MiB, twelve rotated files
//! kept. The events are a closed enum with no free-text field, so a job title,
//! a focus name, a session id or a plan path cannot reach the file: only job
//! ids, focus tags and a fixed `via` word.

use std::io;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::origin::Via;
use crate::terminal::audit::AuditLog;

/// The live file under the user's home: `~/.nostromo/audit/mother.jsonl`.
pub fn default_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("audit")
        .join("mother.jsonl")
}

/// One audited Mother event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum MotherAuditEvent {
    /// The daemon recorded who queued a job (an MCP caller's own focus, or the
    /// app's Send to agent, which has no focus).
    JobOriginStamped {
        job: String,
        /// The focus tag; absent when the user queued it in the app.
        #[serde(skip_serializing_if = "Option::is_none")]
        focus: Option<String>,
        via: Via,
    },
    /// A record claimed a focus whose session history does not hold the
    /// record's session id. Audited once per job.
    JobOriginUnverified { job: String, claimed_focus: String },
}

/// Appends [`MotherAuditEvent`]s. Cheap to clone.
#[derive(Clone, Debug)]
pub struct MotherAudit {
    log: AuditLog,
}

impl MotherAudit {
    /// A log appending to `path`, creating its directory with mode `0700`.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            log: AuditLog::open(path)?,
        })
    }

    /// A log that records nothing (tests, daemons without a home, or a file
    /// that could not be opened: origins are still computed).
    pub fn disabled() -> Self {
        Self {
            log: AuditLog::disabled(),
        }
    }

    /// The live file, if this log records anything.
    pub fn path(&self) -> Option<&Path> {
        self.log.path()
    }

    /// Append one event. A failed write is logged (content-free) and
    /// otherwise ignored: a job's origin never depends on the audit file.
    pub fn record(&self, event: &MotherAuditEvent) {
        if let Err(e) = self.log.append(event) {
            tracing::warn!(error = %e.kind(), "mother audit append failed");
        }
    }
}
