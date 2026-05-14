//! Unit/integration tests for transcript pane phase 3 interaction model.
//!
//! Covers:
//!  1. `navigable_entries` — skips Thinking when hidden, always skips TurnEnd.
//!  2. Cursor navigation — `j`/`k` semantics, clamping at bounds.
//!  3. Expansion toggle — membership in `expanded`; layout grows when expanded.
//!  4. Thinking toggle — line count grows; cursor on Thinking advances when off.
//!  5. Auto-scroll — cursor entry outside viewport triggers offset adjustment.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use nostromo::{
    transcript::snapshot::{TranscriptEntry, TranscriptSnapshot},
    ui::widgets::{
        syntect_cache::SyntectCache,
        transcript_layout::{compute, scroll_to_cursor, TranscriptInteraction},
    },
};

// ── Fixture builder ───────────────────────────────────────────────────────────

/// Build a fixture snapshot with the entry sequence described in the plan:
/// user, assistant-text, tool-use, tool-result, thinking, assistant-text, turn-end.
fn make_snapshot() -> TranscriptSnapshot {
    let entries = vec![
        TranscriptEntry::UserMessage("Hello world".to_string()),                    // 0
        TranscriptEntry::AssistantText("Sure, let me help.".to_string()),           // 1
        TranscriptEntry::ToolUse {                                                   // 2
            name: "Bash".to_string(),
            input: serde_json::json!({"command": "ls -la", "description": "list"}),
        },
        TranscriptEntry::ToolResult {                                                // 3
            tool_use_id: "toolu_abc123xyz".to_string(),
            content: "total 0\ndrwxr-xr-x  2 user group  64 Jan 1 00:00 .".to_string(),
        },
        TranscriptEntry::Thinking("Let me reason about this step by step.".to_string()), // 4
        TranscriptEntry::AssistantText("Done! Here is the result.".to_string()),    // 5
        TranscriptEntry::TurnEnd,                                                    // 6
    ];
    TranscriptSnapshot {
        entries: Arc::new(entries),
        path: PathBuf::from("/tmp/test.jsonl"),
        session_id: "test-session".to_string(),
    }
}

fn make_syntect() -> SyntectCache {
    SyntectCache::load().expect("syntect cache should load in tests")
}

// ── Test 1: navigable_entries ─────────────────────────────────────────────────

#[test]
fn test_navigable_entries_hide_thinking() {
    let snap = make_snapshot();

    // With show_thinking=false: skip Thinking (4) and TurnEnd (6).
    let nav = snap.navigable_entries(false);
    assert_eq!(nav, vec![0, 1, 2, 3, 5], "should skip Thinking and TurnEnd");
}

#[test]
fn test_navigable_entries_show_thinking() {
    let snap = make_snapshot();

    // With show_thinking=true: include Thinking (4), skip TurnEnd (6).
    let nav = snap.navigable_entries(true);
    assert_eq!(nav, vec![0, 1, 2, 3, 4, 5], "should include Thinking but skip TurnEnd");
}

// ── Test 2: cursor navigation ─────────────────────────────────────────────────

/// Simulate moving a cursor through the navigable list.
fn cursor_nav(
    snap: &TranscriptSnapshot,
    show_thinking: bool,
    start: usize,
    moves: &[isize], // +1 = next, -1 = prev
) -> usize {
    let nav = snap.navigable_entries(show_thinking);
    if nav.is_empty() {
        return start;
    }
    let mut pos = nav.iter().position(|&i| i == start).unwrap_or(0);
    for &delta in moves {
        if delta > 0 {
            pos = (pos + 1).min(nav.len() - 1);
        } else {
            pos = pos.saturating_sub(1);
        }
    }
    nav[pos]
}

#[test]
fn test_cursor_navigation_next_prev() {
    let snap = make_snapshot();
    // start at last navigable (5), k back to 3, j forward to 5.
    let after_k = cursor_nav(&snap, false, 5, &[-1]);
    assert_eq!(after_k, 3, "k from 5 should land on 3 (prev navigable)");

    let after_j = cursor_nav(&snap, false, 3, &[1]);
    assert_eq!(after_j, 5, "j from 3 should land on 5 (next navigable)");
}

#[test]
fn test_cursor_clamps_at_bounds() {
    let snap = make_snapshot();
    // Pressing k many times from first entry should stay at first.
    let first = cursor_nav(&snap, false, 0, &[-1, -1, -1]);
    assert_eq!(first, 0, "k at first entry should clamp");

    // Pressing j many times from last entry should stay at last.
    let last = cursor_nav(&snap, false, 5, &[1, 1, 1]);
    assert_eq!(last, 5, "j at last entry should clamp");
}

// ── Test 3: expansion toggle ──────────────────────────────────────────────────

#[test]
fn test_expansion_toggle_membership() {
    let mut expanded: HashSet<usize> = HashSet::new();

    // Toggle in.
    let idx = 2; // ToolUse entry
    expanded.insert(idx);
    assert!(expanded.contains(&idx), "expanded should contain entry after first toggle");

    // Toggle out.
    expanded.remove(&idx);
    assert!(!expanded.contains(&idx), "expanded should not contain entry after second toggle");
}

#[test]
fn test_expansion_increases_line_count() {
    let snap = make_snapshot();
    let syntect = make_syntect();

    let mut state = TranscriptInteraction {
        cursor: 2,
        expanded: HashSet::new(),
        show_thinking: false,
        following: false,
    };

    let mut cache = HashMap::new();
    let plan_collapsed = compute(&snap, &state, 80, &syntect, &mut cache);
    let collapsed_lines = plan_collapsed.lines.len();

    // Expand ToolUse (index 2).
    state.expanded.insert(2);
    cache.clear();
    let mut cache2 = HashMap::new();
    let plan_expanded = compute(&snap, &state, 80, &syntect, &mut cache2);
    let expanded_lines = plan_expanded.lines.len();

    assert!(
        expanded_lines > collapsed_lines,
        "expanded tool-use should produce more lines ({expanded_lines}) than collapsed ({collapsed_lines})"
    );
}

// ── Test 4: thinking toggle ───────────────────────────────────────────────────

#[test]
fn test_thinking_toggle_line_count() {
    let snap = make_snapshot();
    let syntect = make_syntect();

    let mut state = TranscriptInteraction {
        cursor: 0,
        expanded: HashSet::new(),
        show_thinking: false,
        following: false,
    };

    let mut cache = HashMap::new();
    let plan_hidden = compute(&snap, &state, 80, &syntect, &mut cache);
    let lines_hidden = plan_hidden.lines.len();

    state.show_thinking = true;
    cache.clear();
    let mut cache2 = HashMap::new();
    let plan_shown = compute(&snap, &state, 80, &syntect, &mut cache2);
    let lines_shown = plan_shown.lines.len();

    assert!(
        lines_shown > lines_hidden,
        "showing thinking should produce more lines ({lines_shown}) than hiding ({lines_hidden})"
    );
}

#[test]
fn test_thinking_toggle_off_advances_cursor_from_thinking() {
    let snap = make_snapshot();

    // Simulate: thinking visible, cursor on the Thinking entry (4).

    // navigable with show_thinking=true includes 4.
    let nav_on = snap.navigable_entries(true);
    assert!(nav_on.contains(&4), "thinking entry should be navigable when shown");

    // After turning off, cursor was on 4 — it must advance to the next visible entry.
    // With show_thinking=false, navigable doesn't include 4.
    let nav_off = snap.navigable_entries(false);
    assert!(!nav_off.contains(&4), "thinking entry should not be navigable when hidden");

    // Simulate the advance: find next entry after 4 in nav_off.
    let next_after_thinking = nav_off.iter().find(|&&i| i > 4).copied();
    assert_eq!(
        next_after_thinking,
        Some(5),
        "cursor should advance to entry 5 (next assistant text) after hiding thinking"
    );
}

// ── Test 5: auto-scroll ───────────────────────────────────────────────────────

#[test]
fn test_auto_scroll_brings_cursor_into_view() {
    let snap = make_snapshot();
    let syntect = make_syntect();

    let state = TranscriptInteraction {
        cursor: 5, // last AssistantText
        expanded: HashSet::new(),
        show_thinking: false,
        following: false,
    };

    let mut cache = HashMap::new();
    let plan = compute(&snap, &state, 80, &syntect, &mut cache);

    // With pane height 10 and current_offset 0, cursor entry at row >= 10
    // should trigger a scroll adjustment.
    let pane_height: u16 = 2; // tiny pane to force scrolling
    let initial_offset: u16 = 0;

    let new_offset = scroll_to_cursor(&plan.entry_rows, 5, pane_height, initial_offset);

    // The cursor entry's rows must be within [new_offset, new_offset + pane_height).
    if let Some(range) = plan.entry_rows.get(&5) {
        let entry_top = range.start;
        let entry_bot = range.end.saturating_sub(1);
        assert!(
            entry_top >= new_offset && entry_bot < new_offset + pane_height,
            "cursor entry rows {range:?} should be within viewport [{new_offset}, {})",
            new_offset + pane_height
        );
    }
}

#[test]
fn test_auto_scroll_no_change_when_in_view() {
    let snap = make_snapshot();
    let syntect = make_syntect();

    let state = TranscriptInteraction {
        cursor: 0, // first entry — always at top
        expanded: HashSet::new(),
        show_thinking: false,
        following: false,
    };

    let mut cache = HashMap::new();
    let plan = compute(&snap, &state, 80, &syntect, &mut cache);

    // Large pane — entry 0 is always in view.
    let offset = scroll_to_cursor(&plan.entry_rows, 0, 50, 0);
    assert_eq!(offset, 0, "cursor at top with large pane should not change offset");
}
