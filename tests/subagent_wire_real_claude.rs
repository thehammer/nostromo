//! How the REAL `claude` CLI tags subagent traffic on stream-json (opt-in).
//!
//! The daemon's subagent tagging (`TurnBlock::*::parent_tool_use_id`, tool-fold
//! slice TF1) is pinned against a synthetic fixture
//! (`src/ipc/testdata/stream_subagent.jsonl`). This test checks the fixture is
//! honest: it runs one prompt that makes the CLI start a subagent, and reports
//! whether the subagent's `user` tool_result lines carry `isSidechain: true`
//! and/or a `parent_tool_use_id`.
//!
//! Run it with
//!
//! ```text
//! NOSTROMO_REAL_CLAUDE=1 cargo test --test subagent_wire_real_claude -- --ignored --nocapture
//! ```
//!
//! It uses your real `claude` login (`~/.local/bin/claude`, else `claude` on
//! PATH) and costs a few cents: Haiku, `--max-budget-usd 0.25`, only the Agent
//! and Read tools. It never runs by default: it is `#[ignore]`d AND does
//! nothing unless `NOSTROMO_REAL_CLAUDE=1`. It works in a temp directory and
//! deletes the transcript directory `claude` makes for it.
//!
//! It asserts that every subagent tool_result line is recognisable to the
//! daemon (`isSidechain: true` or a non-null `parent_tool_use_id`), and that
//! the daemon's transcript tags every block the subagent produced and opens
//! exactly one turn. If the CLI changes how it tags this traffic, this fails
//! and the TF1 parser (`subagent_parent`, `parse_user_event`) needs a look.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use nostromo::data::work::picks::transcript_dir_for;
use nostromo::ipc::stream_json::{SessionTranscript, TurnBlock};
use serde_json::Value;

const PROMPT: &str = "Use the Agent tool (subagent_type general-purpose) to read the file notes.txt in the \
current directory and report its first line. Do not read the file yourself: the subagent must. \
Then answer in one sentence.";

fn claude_bin() -> PathBuf {
    let local = PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/bin/claude");
    if local.is_file() {
        local
    } else {
        PathBuf::from("claude")
    }
}

#[test]
#[ignore = "runs the real claude CLI: set NOSTROMO_REAL_CLAUDE=1 and pass --ignored"]
fn subagent_traffic_is_tagged_on_the_real_stream() {
    if std::env::var("NOSTROMO_REAL_CLAUDE").as_deref() != Ok("1") {
        println!("subagent_wire_real_claude: skipped (set NOSTROMO_REAL_CLAUDE=1 to run against the real claude CLI)");
        return;
    }

    let cwd = tempfile::tempdir().unwrap();
    std::fs::write(cwd.path().join("notes.txt"), "first line of the notes\nsecond line\n").unwrap();

    let mut child = Command::new(claude_bin())
        .current_dir(cwd.path())
        .args([
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--model",
            "haiku",
            "--max-budget-usd",
            "0.25",
            "--allowedTools",
            "Agent Task Read",
            "--setting-sources",
            "project",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn claude");
    child.stdin.take().unwrap().write_all(PROMPT.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("claude output");
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();

    // Best-effort cleanup of the transcript directory claude made for the temp cwd.
    if let Some(home) = std::env::var_os("HOME") {
        let projects = PathBuf::from(home).join(".claude/projects");
        let _ = std::fs::remove_dir_all(transcript_dir_for(&projects, cwd.path()));
    }

    // What the raw lines say.
    let lines: Vec<Value> = stdout.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let is_subagent = |v: &Value| {
        v.get("isSidechain").and_then(Value::as_bool) == Some(true)
            || v.get("parent_tool_use_id").is_some_and(|p| !p.is_null())
    };
    let subagent_call_ids: HashSet<String> = lines
        .iter()
        .filter(|v| v.get("type").and_then(Value::as_str) == Some("assistant") && is_subagent(v))
        .flat_map(|v| v["message"]["content"].as_array().cloned().unwrap_or_default())
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_use"))
        .filter_map(|b| b.get("id").and_then(Value::as_str).map(str::to_string))
        .collect();
    assert!(
        !subagent_call_ids.is_empty(),
        "the CLI started no subagent that made a tool call; nothing to check. Raw stream:\n{stdout}"
    );

    let mut result_lines = 0;
    for v in lines.iter().filter(|v| v.get("type").and_then(Value::as_str) == Some("user")) {
        let Some(arr) = v["message"]["content"].as_array() else { continue };
        let answers_subagent = arr.iter().any(|b| {
            b.get("type").and_then(Value::as_str) == Some("tool_result")
                && b.get("tool_use_id").and_then(Value::as_str).is_some_and(|id| subagent_call_ids.contains(id))
        });
        if !answers_subagent {
            continue;
        }
        result_lines += 1;
        println!(
            "subagent tool_result line: isSidechain={:?} parent_tool_use_id={:?}",
            v.get("isSidechain"),
            v.get("parent_tool_use_id")
        );
        assert!(
            is_subagent(v),
            "a subagent's tool_result line carries neither isSidechain nor parent_tool_use_id: {v}"
        );
    }
    assert!(result_lines > 0, "no tool_result line answered a subagent call. Raw stream:\n{stdout}");

    // What the daemon makes of them.
    let mut t = SessionTranscript::new();
    t.set_live(true);
    for line in stdout.lines() {
        let _ = t.ingest_line(line);
    }
    let turns = t.snapshot();
    assert_eq!(turns.len(), 1, "a subagent prompt opened a spurious turn: {turns:#?}");
    let untagged_subagent_result = turns[0].blocks.iter().any(|b| match b {
        TurnBlock::ToolResult { tool_use_id: Some(id), parent_tool_use_id: None, .. } => subagent_call_ids.contains(id),
        _ => false,
    });
    assert!(!untagged_subagent_result, "a subagent's tool_result reached the turn untagged: {:#?}", turns[0].blocks);
}
