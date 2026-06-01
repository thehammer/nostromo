//! Integration test: TranscriptReader tails a live-appended JSONL file.

use std::io::Write;
use std::time::Duration;

use nostromo::transcript::{snapshot::TranscriptEntry, TranscriptReader};
use tempfile::tempdir;

/// Three JSONL records to append one at a time.
const USER_LINE: &str = r#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Hello from the tail test."},"uuid":"u-001","timestamp":"2026-05-14T10:00:00.000Z","sessionId":"test-sid"}"#;
const ASSISTANT_LINE: &str = r#"{"parentUuid":"u-001","isSidechain":false,"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","id":"msg-001","type":"message","content":[{"type":"text","text":"Hi there!"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":5}},"uuid":"a-001","timestamp":"2026-05-14T10:00:01.000Z","sessionId":"test-sid"}"#;
const META_LINE: &str = r#"{"type":"agent-setting","agentSetting":"test","sessionId":"test-sid"}"#;

#[tokio::test]
async fn reader_tails_appended_records() {
    let dir = tempdir().unwrap();
    let session_id = "test-sid".to_string();

    // Point cwd at the tempdir so the reader computes the path inside it.
    // We manually create the project dir structure.
    let cwd = dir.path().to_path_buf();

    // The reader computes: project_dir(cwd) / "test-sid.jsonl"
    // project_dir replaces '/' with '-', so we replicate that:
    let sanitized = cwd.to_string_lossy().replace('/', "-");
    let project_dir = dir.path().join(".claude").join("projects").join(&sanitized);
    std::fs::create_dir_all(&project_dir).unwrap();
    let log_path = project_dir.join("test-sid.jsonl");

    // Override home so the reader finds the file under dir.
    // We do this by constructing the path directly and writing there.
    // The reader uses dirs_next::home_dir() — we can't easily override that
    // in tests, so instead we construct the full path ourselves and write
    // a pre-created file at the exact location the reader expects.
    //
    // Strategy: set HOME env var to dir.path() so dirs_next returns it.
    std::env::set_var("HOME", dir.path());

    // Spawn the reader BEFORE the file exists to test the "wait for file"
    // path.
    let (reader, mut rx) = TranscriptReader::spawn(cwd.clone(), session_id.clone());

    // Short pause to let the reader start up and notice the missing file.
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Write the first record (user message).
    {
        let mut f = std::fs::File::create(&log_path).unwrap();
        writeln!(f, "{META_LINE}").unwrap();
        writeln!(f, "{USER_LINE}").unwrap();
        f.flush().unwrap();
    }

    // Wait for the snapshot to contain the user message.
    let snap = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            rx.changed().await.unwrap();
            let snap = rx.borrow().clone();
            if snap
                .entries
                .iter()
                .any(|e| matches!(e, TranscriptEntry::UserMessage(_)))
            {
                return snap;
            }
        }
    })
    .await
    .expect("timed out waiting for user message");

    assert!(snap
        .entries
        .iter()
        .any(|e| matches!(e, TranscriptEntry::UserMessage(_))));

    // Append the assistant line.
    {
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&log_path)
            .unwrap();
        writeln!(f, "{ASSISTANT_LINE}").unwrap();
        f.flush().unwrap();
    }

    // Wait for the snapshot to contain both user message and TurnEnd.
    let snap = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            rx.changed().await.unwrap();
            let snap = rx.borrow().clone();
            if snap
                .entries
                .iter()
                .any(|e| matches!(e, TranscriptEntry::TurnEnd))
            {
                return snap;
            }
        }
    })
    .await
    .expect("timed out waiting for TurnEnd");

    // Verify final snapshot has entries in order.
    let kinds: Vec<&str> = snap
        .entries
        .iter()
        .map(|e| match e {
            TranscriptEntry::UserMessage(_) => "User",
            TranscriptEntry::AssistantText(_) => "Assistant",
            TranscriptEntry::TurnEnd => "TurnEnd",
            TranscriptEntry::Thinking(_) => "Thinking",
            TranscriptEntry::ToolUse { .. } => "ToolUse",
            TranscriptEntry::ToolResult { .. } => "ToolResult",
        })
        .collect();

    assert!(kinds.contains(&"User"), "missing User: {kinds:?}");
    assert!(kinds.contains(&"Assistant"), "missing Assistant: {kinds:?}");
    assert!(kinds.contains(&"TurnEnd"), "missing TurnEnd: {kinds:?}");

    // User comes before Assistant.
    let user_idx = kinds.iter().position(|&k| k == "User").unwrap();
    let asst_idx = kinds.iter().position(|&k| k == "Assistant").unwrap();
    assert!(user_idx < asst_idx, "User should precede Assistant");

    // Verify session_id and path are correct.
    assert_eq!(snap.session_id, "test-sid");
    assert!(snap.path.ends_with("test-sid.jsonl"));

    // Drop the reader explicitly to shut down the background task cleanly.
    drop(reader);
}
