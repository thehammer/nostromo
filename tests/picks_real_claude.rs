//! The hidden picks session against the REAL `claude` CLI (opt-in).
//!
//! Everything else about the picks session is tested against a fake `claude` that only writes
//! down its arguments. That cannot tell whether the real CLI, started with those arguments,
//! can still call the three picks tools, cannot call anything else, and does not load the
//! user's hooks. This test starts the real thing against a tiny stub MCP server (the real
//! Nostromo daemon is not involved) and checks exactly that.
//!
//! Run it with
//!
//! ```text
//! NOSTROMO_REAL_CLAUDE=1 cargo test --test picks_real_claude -- --ignored --nocapture
//! ```
//!
//! It uses your real `claude` login (so it costs a few cents; the `haiku` model keeps that
//! small) and needs `python3`. It never runs by default: it is `#[ignore]`d AND does nothing
//! unless `NOSTROMO_REAL_CLAUDE=1`. Beyond what `claude` itself writes, it touches nothing under
//! your home: the one transcript directory `claude` creates for the probe's temp working
//! directory is deleted afterwards. No token or event body is ever printed.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use nostromo::data::work::picks::{picks_restrictions, transcript_dir_for, GeneratorEnv, PICKS_MCP_TOOLS};
use nostromo::ipc::session_manager::{build_claude_args_with, resolve_claude};
use serde_json::{json, Value};

/// Only a safety net against a hung run; never part of a success condition.
const SAFETY_KILL_AFTER: Duration = Duration::from_secs(150);

/// A minimal MCP stdio server (newline-delimited JSON-RPC). Every `tools/call` appends the tool's
/// name to the file named by `$STUB_LOG` and answers with an empty item list.
const STUB_MCP_SERVER: &str = r#"
import json, os, sys

TOOLS = [
    "teri_list_work_items",
    "teri_get_work_item",
    "teri_publish_picks",
    "mother_enqueue_job",
    "nostromo_set_pane_content",
]

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    if mid is None:
        continue  # notifications get no answer
    if method == "initialize":
        version = (msg.get("params") or {}).get("protocolVersion") or "2024-11-05"
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "stub-nostromo", "version": "0"},
        }})
    elif method == "tools/list":
        tools = [
            {"name": t, "description": "stub tool " + t,
             "inputSchema": {"type": "object", "properties": {}, "additionalProperties": True}}
            for t in TOOLS
        ]
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": tools}})
    elif method == "tools/call":
        name = (msg.get("params") or {}).get("name", "")
        with open(os.environ["STUB_LOG"], "a") as log:
            log.write(name + "\n")
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": json.dumps({"items": []})}],
        }})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}})
"#;

const PROBE_PROMPT: &str = "This is a tool-access probe. Do these steps in order, one tool call at a time, and \
do not skip a step even if an earlier one returns an error or an empty result. \
Step 0: use ToolSearch with the query \
\"select:mcp__nostromo__teri_list_work_items,mcp__nostromo__teri_get_work_item,mcp__nostromo__teri_publish_picks,mcp__nostromo__mother_enqueue_job\" \
to load the tools. \
Step 1: call teri_list_work_items. \
Step 2: call mother_enqueue_job with any arguments. \
Step 3: call teri_publish_picks with any arguments. \
Then reply with the single word done.";

/// Kills the child and deletes the probe's transcript directory however the test ends.
struct Probe {
    child: Child,
    transcripts: Option<PathBuf>,
}

impl Drop for Probe {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(dir) = &self.transcripts {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

fn opted_in() -> bool {
    if std::env::var("NOSTROMO_REAL_CLAUDE").as_deref() != Ok("1") {
        println!("picks_real_claude: skipped (set NOSTROMO_REAL_CLAUDE=1 to run against the real claude CLI)");
        return false;
    }
    true
}

fn event_kind(event: &Value) -> String {
    let kind = event["type"].as_str().unwrap_or("?");
    match event["subtype"].as_str() {
        Some(sub) => format!("{kind}/{sub}"),
        None => kind.to_string(),
    }
}

/// Content blocks of an assistant or user event.
fn blocks(event: &Value) -> Vec<&Value> {
    event["message"]["content"].as_array().map(|a| a.iter().collect()).unwrap_or_default()
}

fn tool_result_text(block: &Value) -> String {
    match &block["content"] {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

#[test]
#[ignore = "opt-in: NOSTROMO_REAL_CLAUDE=1 cargo test --test picks_real_claude -- --ignored --nocapture"]
fn the_real_claude_can_call_exactly_the_picks_tools_under_the_picks_session_arguments() {
    if !opted_in() {
        return;
    }
    let Ok(claude) = resolve_claude() else {
        println!("picks_real_claude: skipped (no `claude` binary found)");
        return;
    };
    if Command::new("python3").arg("--version").output().is_err() {
        println!("picks_real_claude: skipped (no python3 for the stub MCP server)");
        return;
    }

    // ── the stub MCP server and its config ───────────────────────────────────
    let rig = tempfile::tempdir().unwrap();
    let stub = rig.path().join("stub_mcp.py");
    std::fs::write(&stub, STUB_MCP_SERVER).unwrap();
    let log = rig.path().join("calls.log");
    std::fs::write(&log, "").unwrap();
    let mcp_config = rig.path().join("mcp.json");
    let config = json!({
        "mcpServers": {
            "nostromo": {
                "command": "python3",
                "args": ["-I", stub],
                "env": { "STUB_LOG": log },
            }
        }
    });
    std::fs::write(&mcp_config, serde_json::to_vec_pretty(&config).unwrap()).unwrap();

    // ── the session, started the way production starts the picks session ─────
    let cwd = tempfile::tempdir().unwrap();
    let session_id = uuid::Uuid::new_v4().to_string();
    // The real guard binary, as production wires it.
    let guard_settings =
        nostromo::approvals::guard::hook_settings_json(std::path::Path::new(env!("CARGO_BIN_EXE_nostromo-guard")));
    let mut args = build_claude_args_with("", "picks probe", false, &session_id, false, Some(&picks_restrictions()), &guard_settings);
    args.extend(["--mcp-config".into(), mcp_config.to_string_lossy().into_owned()]);
    args.extend(["--model".into(), "haiku".into()]);

    let stderr_log = rig.path().join("claude.stderr");
    let mut child = Command::new(&claude)
        .args(&args)
        .current_dir(cwd.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(std::fs::File::create(&stderr_log).unwrap()))
        .spawn()
        .expect("claude starts");
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let projects = GeneratorEnv::local().projects_dir;
    let _probe = Probe { child, transcripts: projects.map(|p| transcript_dir_for(&p, cwd.path())) };

    let message = json!({"type": "user", "message": {"role": "user", "content": PROBE_PROMPT}});
    writeln!(stdin, "{message}").unwrap();
    drop(stdin);

    // ── read every event, with a safety deadline ─────────────────────────────
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let started = Instant::now();
    let mut events: Vec<Value> = Vec::new();
    loop {
        let left = SAFETY_KILL_AFTER.saturating_sub(started.elapsed());
        match rx.recv_timeout(left) {
            Ok(line) => {
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    events.push(event);
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break, // claude closed stdout: it is done
            Err(mpsc::RecvTimeoutError::Timeout) => {
                panic!("the probe was still running after {SAFETY_KILL_AFTER:?}; killing it. {}", summary(&events, &stderr_log));
            }
        }
    }

    let called: Vec<String> = std::fs::read_to_string(&log).unwrap_or_default().lines().map(String::from).collect();
    let context = || format!("stub saw {called:?}. {}", summary(&events, &stderr_log));

    // (a) the session starts with ToolSearch and the three picks tools, and nothing from the user's setup
    let init = events
        .iter()
        .find(|e| e["type"] == "system" && e["subtype"] == "init")
        .unwrap_or_else(|| panic!("no system/init event. {}", context()));
    let tools: Vec<&str> = init["tools"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    assert!(tools.contains(&"ToolSearch"), "ToolSearch is available: {tools:?}");
    for tool in PICKS_MCP_TOOLS {
        assert!(tools.contains(&tool), "{tool} is available to the session: {tools:?}");
    }

    // (b) the picks tools are loadable AND callable
    for tool in ["teri_list_work_items", "teri_publish_picks"] {
        assert!(called.iter().any(|c| c == tool), "{tool} was never reached. {}", context());
    }

    // (c) nothing else can be reached, and asking for it is refused with a denial
    for tool in ["mother_enqueue_job", "nostromo_set_pane_content"] {
        assert!(!called.iter().any(|c| c == tool), "{tool} must never run. {}", context());
    }
    let attempt = events
        .iter()
        .filter(|e| e["type"] == "assistant")
        .flat_map(blocks)
        .find(|b| b["type"] == "tool_use" && b["name"].as_str().is_some_and(|n| n.contains("mother_enqueue_job")))
        .unwrap_or_else(|| panic!("the probe never tried mother_enqueue_job. {}", context()));
    let attempt_id = attempt["id"].as_str().expect("a tool_use id");
    let result = events
        .iter()
        .filter(|e| e["type"] == "user")
        .flat_map(blocks)
        .find(|b| b["type"] == "tool_result" && b["tool_use_id"] == attempt_id)
        .unwrap_or_else(|| panic!("no tool_result for the mother_enqueue_job call. {}", context()));
    assert_eq!(result["is_error"], true, "the call is an error. {}", context());
    let text = tool_result_text(result).to_lowercase();
    assert!(text.contains("denied"), "the error says the call was denied: {text:.300}");

    // (d) no user hooks ran
    let hooks: Vec<String> =
        events.iter().filter(|e| e["type"] == "system" && e["subtype"] == "hook_started").map(event_kind).collect();
    assert!(hooks.is_empty(), "user hooks must not run in the picks session: {hooks:?}");
}

/// What happened, without any event bodies: event kinds, tool names and the tail of stderr.
fn summary(events: &[Value], stderr_log: &Path) -> String {
    let kinds: Vec<String> = events.iter().map(event_kind).collect();
    let tool_uses: Vec<&str> = events
        .iter()
        .filter(|e| e["type"] == "assistant")
        .flat_map(blocks)
        .filter(|b| b["type"] == "tool_use")
        .filter_map(|b| b["name"].as_str())
        .collect();
    let stderr = std::fs::read_to_string(stderr_log).unwrap_or_default();
    let tail: Vec<&str> = stderr.lines().rev().take(10).collect();
    format!("events: {kinds:?}; tool calls: {tool_uses:?}; stderr tail: {tail:?}")
}
