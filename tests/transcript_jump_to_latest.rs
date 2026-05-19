//! Tests for `TranscriptSnapshot::latest_user_message_index` and
//! `TranscriptPane::jump_to_latest_user_message`.

use std::path::PathBuf;
use std::sync::Arc;

use nostromo::transcript::snapshot::{TranscriptEntry, TranscriptSnapshot};

// ── Snapshot helpers ──────────────────────────────────────────────────────────

fn snapshot(entries: Vec<TranscriptEntry>) -> TranscriptSnapshot {
    TranscriptSnapshot {
        entries: Arc::new(entries),
        path: PathBuf::from("/tmp/test.jsonl"),
        session_id: "test-session".to_string(),
    }
}

// ── TranscriptSnapshot::latest_user_message_index ────────────────────────────

#[test]
fn latest_user_message_empty_entries() {
    let snap = snapshot(vec![]);
    assert_eq!(snap.latest_user_message_index(), None);
}

#[test]
fn latest_user_message_only_assistant_entries() {
    let snap = snapshot(vec![
        TranscriptEntry::AssistantText("Hello.".to_string()),
        TranscriptEntry::TurnEnd,
        TranscriptEntry::AssistantText("World.".to_string()),
    ]);
    assert_eq!(snap.latest_user_message_index(), None);
}

#[test]
fn latest_user_message_single_user_message() {
    let snap = snapshot(vec![
        TranscriptEntry::UserMessage("Ask something".to_string()), // 0
        TranscriptEntry::AssistantText("Answer".to_string()),      // 1
        TranscriptEntry::TurnEnd,                                  // 2
    ]);
    assert_eq!(snap.latest_user_message_index(), Some(0));
}

#[test]
fn latest_user_message_returns_last_when_several_exist() {
    let snap = snapshot(vec![
        TranscriptEntry::UserMessage("First question".to_string()), // 0
        TranscriptEntry::AssistantText("First answer".to_string()), // 1
        TranscriptEntry::TurnEnd,                                   // 2
        TranscriptEntry::UserMessage("Second question".to_string()), // 3
        TranscriptEntry::AssistantText("Second answer".to_string()), // 4
        TranscriptEntry::TurnEnd,                                   // 5
        TranscriptEntry::UserMessage("Third question".to_string()), // 6
        TranscriptEntry::AssistantText("Third answer".to_string()), // 7
        TranscriptEntry::TurnEnd,                                   // 8
    ]);
    assert_eq!(snap.latest_user_message_index(), Some(6));
}

#[test]
fn latest_user_message_scans_past_trailing_assistant_entries() {
    // Last entry is an assistant response — must scan backwards past it.
    let snap = snapshot(vec![
        TranscriptEntry::UserMessage("First".to_string()), // 0
        TranscriptEntry::AssistantText("First reply".to_string()), // 1
        TranscriptEntry::TurnEnd,                          // 2
        TranscriptEntry::UserMessage("Second".to_string()), // 3
        TranscriptEntry::AssistantText("Second reply".to_string()), // 4
        TranscriptEntry::Thinking("internal reasoning".to_string()), // 5
        TranscriptEntry::ToolUse {
            // 6
            name: "Bash".to_string(),
            input: serde_json::json!({"command": "echo hi"}),
        },
        TranscriptEntry::ToolResult {
            // 7
            tool_use_id: "tu_abc".to_string(),
            content: "hi".to_string(),
        },
        TranscriptEntry::AssistantText("Done".to_string()), // 8
        TranscriptEntry::TurnEnd,                           // 9
    ]);
    // Index 3 is the latest user message; entries 4-9 are all non-user.
    assert_eq!(snap.latest_user_message_index(), Some(3));
}

// TranscriptPane::jump_to_latest_user_message is tested as a unit test
// in src/transcript/integration.rs (where #[cfg(test)] helpers are available).
