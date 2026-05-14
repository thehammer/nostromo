//! Fixture-based tests for transcript JSONL parsing.

use nostromo::transcript::{
    record::{ContentBlock, Record, UserContent},
    snapshot::TranscriptEntry,
};

// ── Helper: decode record → entries ──────────────────────────────────────────

fn records_to_entries(records: Vec<Record>) -> Vec<TranscriptEntry> {
    let mut out = Vec::new();
    for rec in records {
        match &rec {
            Record::User { message, .. } => {
                match &message.content {
                    UserContent::Text(s) => {
                        if !s.is_empty() {
                            out.push(TranscriptEntry::UserMessage(s.clone()));
                        }
                    }
                    UserContent::Blocks(blocks) => {
                        let text = blocks
                            .iter()
                            .filter_map(|b| {
                                if let ContentBlock::Text { text } = b {
                                    Some(text.as_str())
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n");
                        if !text.is_empty() {
                            out.push(TranscriptEntry::UserMessage(text));
                        }
                        for block in blocks {
                            if let ContentBlock::ToolResult { tool_use_id, content } = block {
                                out.push(TranscriptEntry::ToolResult {
                                    tool_use_id: tool_use_id.clone(),
                                    content: content.as_display(),
                                });
                            }
                        }
                    }
                }
            }
            Record::Assistant { message, .. } => {
                for block in &message.content {
                    match block {
                        ContentBlock::Text { text } if !text.is_empty() => {
                            out.push(TranscriptEntry::AssistantText(text.clone()));
                        }
                        ContentBlock::Thinking { thinking, .. } if !thinking.is_empty() => {
                            out.push(TranscriptEntry::Thinking(thinking.clone()));
                        }
                        ContentBlock::ToolUse { name, input, .. } => {
                            out.push(TranscriptEntry::ToolUse {
                                name: name.clone(),
                                input: input.clone(),
                            });
                        }
                        ContentBlock::ToolResult { tool_use_id, content } => {
                            out.push(TranscriptEntry::ToolResult {
                                tool_use_id: tool_use_id.clone(),
                                content: content.as_display(),
                            });
                        }
                        _ => {}
                    }
                }
                if message.stop_reason.is_some() {
                    out.push(TranscriptEntry::TurnEnd);
                }
            }
            Record::Other => {}
        }
    }
    out
}

fn load_records(path: &str) -> Vec<Record> {
    let content = std::fs::read_to_string(path).expect("fixture file missing");
    content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| serde_json::from_str::<Record>(line).expect("failed to parse JSONL line"))
        .collect()
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[test]
fn basic_fixture_decodes_correct_entries() {
    let records = load_records("tests/fixtures/transcript/basic.jsonl");
    let entries = records_to_entries(records);

    // Expected sequence:
    //   0: UserMessage("Let's review the PR.")
    //   1: AssistantText("I'll review the PR for you.")
    //   2: ToolUse { name: "Bash", .. }
    //   3: TurnEnd (stop_reason = "tool_use")
    //   4: ToolResult from the second user turn (tool_result block)
    //   5: AssistantText("The diff looks good. One small function added.")
    //   6: TurnEnd (stop_reason = "end_turn")

    // Find the UserMessage
    let user_msgs: Vec<_> = entries
        .iter()
        .filter(|e| matches!(e, TranscriptEntry::UserMessage(_)))
        .collect();
    assert_eq!(user_msgs.len(), 1, "expected exactly one user message");
    if let TranscriptEntry::UserMessage(t) = &user_msgs[0] {
        assert_eq!(t, "Let's review the PR.");
    }

    // Find the tool use
    let tool_uses: Vec<_> = entries
        .iter()
        .filter(|e| matches!(e, TranscriptEntry::ToolUse { .. }))
        .collect();
    assert_eq!(tool_uses.len(), 1);
    if let TranscriptEntry::ToolUse { name, .. } = &tool_uses[0] {
        assert_eq!(name, "Bash");
    }

    // Find the tool result
    let tool_results: Vec<_> = entries
        .iter()
        .filter(|e| matches!(e, TranscriptEntry::ToolResult { .. }))
        .collect();
    assert_eq!(tool_results.len(), 1);

    // Two TurnEnd markers
    let turn_ends = entries
        .iter()
        .filter(|e| matches!(e, TranscriptEntry::TurnEnd))
        .count();
    assert_eq!(turn_ends, 2);

    // Two assistant text entries
    let asst_texts: Vec<_> = entries
        .iter()
        .filter(|e| matches!(e, TranscriptEntry::AssistantText(_)))
        .collect();
    assert_eq!(asst_texts.len(), 2);
}

#[test]
fn meta_only_fixture_produces_zero_entries() {
    let records = load_records("tests/fixtures/transcript/meta-only.jsonl");
    let entries = records_to_entries(records);
    assert!(
        entries.is_empty(),
        "meta-only fixture should produce no entries, got: {entries:?}"
    );
}

#[test]
fn thinking_fixture_has_thinking_before_text() {
    let records = load_records("tests/fixtures/transcript/thinking.jsonl");
    let entries = records_to_entries(records);

    // Expected: UserMessage, Thinking, AssistantText, TurnEnd
    let kinds: Vec<&str> = entries
        .iter()
        .map(|e| match e {
            TranscriptEntry::UserMessage(_) => "User",
            TranscriptEntry::Thinking(_) => "Thinking",
            TranscriptEntry::AssistantText(_) => "Assistant",
            TranscriptEntry::TurnEnd => "TurnEnd",
            TranscriptEntry::ToolUse { .. } => "ToolUse",
            TranscriptEntry::ToolResult { .. } => "ToolResult",
        })
        .collect();

    assert_eq!(kinds, vec!["User", "Thinking", "Assistant", "TurnEnd"]);

    // Thinking text is non-empty
    if let TranscriptEntry::Thinking(t) = &entries[1] {
        assert!(t.contains("carefully"));
    } else {
        panic!("expected Thinking at index 1");
    }
}
