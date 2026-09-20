//! `nostromo.get_render_state` tool handler (W1 — render-state-visibility).
//!
//! The daemon's [`PaneRegistry`](crate::ipc::pane_registry::PaneRegistry) only
//! ever knows the pane tree it was told to build — structure, never what any
//! window actually painted. `nostromo.show` and friends return success the
//! moment the daemon accepts and registers a call, not when anything is
//! actually on screen (see the 2026-09-04 live QA pass this wedge answers).
//!
//! This module closes that gap from the other side: the macOS client reports
//! what each of its windows actually materialised (`ClientMsg::RenderedShape`,
//! stored in `PaneRegistry::record_rendered_shape`), and [`compute`] diffs
//! that report against the daemon's own idea of "expected"
//! (`PaneRegistry::pane_ids`).
//!
//! [`compute`] is the single source of truth for this comparison — both the
//! standalone [`handle`] (`nostromo.get_render_state`) and the `render_state`
//! section `nostromo.get_view_state` adds to its response (D7) call it, so
//! there is exactly one place that can get "does a missing report count as
//! agreement" wrong.

use serde_json::{json, Value};

use crate::mcp::{state::McpSharedState, tools::apply_layout::target_tag};

/// Handle `nostromo.get_render_state({ view_id? })`. `view_id` defaults to the
/// caller's own focus (resolved from `pty_id`), matching every other pane
/// tool's `target_tag` convention.
pub async fn handle(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    compute(state, tag)
}

/// Compute the render-state response body for `tag`.
///
/// Returns `windows: []` and `agrees_everywhere: null` (never `true`) when no
/// window has ever reported for this tag — a missing report must never read
/// as agreement, or the tool would lie by omission exactly where it matters
/// most (a client that crashed, never connected, or hasn't caught up yet).
pub fn compute(state: &McpSharedState, tag: &str) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({
            "error": "not_supported",
            "detail": "nostromo.get_render_state requires the daemon-hosted MCP server",
        });
    };

    let (expected, reports) = {
        let reg = daemon.pane_registry.lock().unwrap();
        let expected = reg.pane_ids(tag);
        let reports: Vec<(String, Vec<String>, chrono::DateTime<chrono::Utc>)> = reg
            .rendered_shapes_for_tag(tag)
            .into_iter()
            .map(|(window_id, report)| (window_id, report.pane_ids.clone(), report.reported_at))
            .collect();
        (expected, reports)
    };

    let now = chrono::Utc::now();
    let windows: Vec<Value> = reports
        .into_iter()
        .map(|(window_id, rendered, reported_at)| {
            let diff = diff_shapes(&expected, &rendered);
            let age_ms = (now - reported_at).num_milliseconds().max(0);
            json!({
                "window_id": window_id,
                "rendered": rendered,
                "missing": diff.missing,
                "extra": diff.extra,
                "reported_at": reported_at.to_rfc3339(),
                "age_ms": age_ms,
                "agrees": diff.agrees,
            })
        })
        .collect();

    let agrees_everywhere = if windows.is_empty() {
        Value::Null
    } else {
        Value::Bool(windows.iter().all(|w| w["agrees"] == Value::Bool(true)))
    };

    json!({
        "tag": tag,
        "expected": expected,
        "windows": windows,
        "windows_reporting": windows.len(),
        "agrees_everywhere": agrees_everywhere,
    })
}

/// The expected/rendered comparison for one window: which expected pane ids
/// never showed up (`missing`), which rendered pane ids weren't expected
/// (`extra`), and whether the two sets are identical (`agrees`).
struct ShapeDiff {
    missing: Vec<String>,
    extra: Vec<String>,
    agrees: bool,
}

/// Pure set-diff of `expected` vs `rendered`. Order in the inputs is
/// irrelevant (both are treated as sets, matching the "duplicate pane ids
/// can't exist in a valid tree" invariant `PaneRegistry` already upholds);
/// output lists are sorted for a deterministic wire shape.
fn diff_shapes(expected: &[String], rendered: &[String]) -> ShapeDiff {
    use std::collections::BTreeSet;

    let expected_set: BTreeSet<&str> = expected.iter().map(String::as_str).collect();
    let rendered_set: BTreeSet<&str> = rendered.iter().map(String::as_str).collect();

    let missing: Vec<String> = expected_set
        .difference(&rendered_set)
        .map(|s| s.to_string())
        .collect();
    let extra: Vec<String> = rendered_set
        .difference(&expected_set)
        .map(|s| s.to_string())
        .collect();
    let agrees = missing.is_empty() && extra.is_empty();

    ShapeDiff {
        missing,
        extra,
        agrees,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── diff_shapes: pure function, table-driven ──────────────────────────────

    #[test]
    fn diff_shapes_equal_sets_agree_with_no_missing_or_extra() {
        let expected = vec!["repl".to_string(), "queue".to_string()];
        let rendered = vec!["queue".to_string(), "repl".to_string()];
        let diff = diff_shapes(&expected, &rendered);
        assert!(diff.agrees);
        assert!(diff.missing.is_empty());
        assert!(diff.extra.is_empty());
    }

    #[test]
    fn diff_shapes_rendered_missing_a_subset() {
        let expected = vec!["repl".to_string(), "detail.0".to_string(), "detail.1".to_string()];
        let rendered = vec!["repl".to_string()];
        let diff = diff_shapes(&expected, &rendered);
        assert!(!diff.agrees);
        assert_eq!(diff.missing, vec!["detail.0", "detail.1"]);
        assert!(diff.extra.is_empty());
    }

    #[test]
    fn diff_shapes_rendered_has_an_extra_pane() {
        let expected = vec!["repl".to_string()];
        let rendered = vec!["repl".to_string(), "stale_pane".to_string()];
        let diff = diff_shapes(&expected, &rendered);
        assert!(!diff.agrees);
        assert!(diff.missing.is_empty());
        assert_eq!(diff.extra, vec!["stale_pane"]);
    }

    #[test]
    fn diff_shapes_both_missing_and_extra() {
        let expected = vec!["repl".to_string(), "queue".to_string()];
        let rendered = vec!["repl".to_string(), "stale_pane".to_string()];
        let diff = diff_shapes(&expected, &rendered);
        assert!(!diff.agrees);
        assert_eq!(diff.missing, vec!["queue"]);
        assert_eq!(diff.extra, vec!["stale_pane"]);
    }

    #[test]
    fn diff_shapes_empty_rendered_reports_everything_expected_as_missing() {
        let expected = vec!["repl".to_string(), "queue".to_string()];
        let rendered: Vec<String> = vec![];
        let diff = diff_shapes(&expected, &rendered);
        assert!(!diff.agrees);
        assert_eq!(diff.missing, vec!["queue", "repl"]);
        assert!(diff.extra.is_empty());
    }

    #[test]
    fn diff_shapes_empty_expected_reports_everything_rendered_as_extra() {
        let expected: Vec<String> = vec![];
        let rendered = vec!["repl".to_string()];
        let diff = diff_shapes(&expected, &rendered);
        assert!(!diff.agrees);
        assert!(diff.missing.is_empty());
        assert_eq!(diff.extra, vec!["repl"]);
    }

    #[test]
    fn diff_shapes_both_empty_agree() {
        let expected: Vec<String> = vec![];
        let rendered: Vec<String> = vec![];
        let diff = diff_shapes(&expected, &rendered);
        assert!(diff.agrees);
        assert!(diff.missing.is_empty());
        assert!(diff.extra.is_empty());
    }

    // ── compute: the D3 lying-by-omission guard ───────────────────────────────

    #[test]
    fn compute_with_no_windows_reporting_is_null_not_true() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let state = McpSharedState::for_test(tx);
        // `state.daemon` is `None` in `for_test`, so this exercises the
        // `not_supported` branch — the daemon-backed case (windows: []
        // when a tag has no reports) is covered by the integration test in
        // `tests/mcp_render_state.rs`, which can construct a real
        // `DaemonMcpBackend`.
        let result = compute(&state, "perri");
        assert_eq!(result["error"], "not_supported");
    }
}
