//! `nostromo.get_daemon_diagnostics` tool handler.
//!
//! Returns an on-demand latency snapshot for the daemon's MCP tool surface —
//! per-tool call counts and p50/p95/max wall-clock durations in milliseconds,
//! plus process identity and uptime. Backed entirely by
//! [`crate::mcp::tool_stats::ToolStats`]: in-memory, bounded, and reset on
//! daemon restart. Not a metrics pipeline.
//!
//! ```json
//! {
//!   "nostromo_version": "0.1.0",
//!   "pid": 41231,
//!   "started_at": "2026-08-17T09:12:03Z",
//!   "uptime_secs": 4821,
//!   "total_calls": 137,
//!   "distinct_tools": 6,
//!   "sample_window": 256,
//!   "tools": [
//!     {
//!       "name": "nostromo.apply_layout",
//!       "calls": 12,
//!       "window": 12,
//!       "p50_ms": 8.4,
//!       "p95_ms": 210.7,
//!       "max_ms": 311.2,
//!       "last_ms": 9.1
//!     }
//!   ]
//! }
//! ```
//!
//! This tool's own row lags by one call: the snapshot is taken before its own
//! dispatch duration is recorded by the `tools::dispatch` timing wrapper.

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Handle `nostromo.get_daemon_diagnostics`.
pub fn handle(state: &McpSharedState) -> Value {
    let mut snapshot = state.tool_stats.snapshot_json();

    // snapshot_json() returns the `tools`/`total_calls`/etc. fields; splice in
    // process identity and the wall-clock start time.
    let obj = snapshot
        .as_object_mut()
        .expect("snapshot_json returns an object");
    obj.insert(
        "nostromo_version".to_string(),
        json!(env!("CARGO_PKG_VERSION")),
    );
    obj.insert("pid".to_string(), json!(std::process::id()));
    obj.insert(
        "started_at".to_string(),
        json!(state.tool_stats.started_at_rfc3339()),
    );

    snapshot
}
