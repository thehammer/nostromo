//! Ambient agent activity: secret redaction, per-tool summaries, and the
//! bounded per-agent stream store fed by the `activity.jsonl` tailer.
//!
//! Modules:
//! - [`redact`]  — secret-shape scrubbing, applied by both the hook producer
//!   and (defensively) by [`store::ActivityStore::ingest`].
//! - [`summary`] — derives a bounded, redacted, per-tool display summary.
//! - [`store`]   — bounded, attributed, per-agent activity stream buffering.

pub mod hook_status;
pub mod redact;
pub mod store;
pub mod summary;
