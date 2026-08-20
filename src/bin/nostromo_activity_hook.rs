//! `nostromo-activity-hook` — Claude Code hook producer for the ambient
//! activity feed.
//!
//! Registered against the `PostToolUse`, `SubagentStart`, and `SubagentStop`
//! hooks in `.claude/settings.json`. Reads one hook JSON payload on stdin,
//! converts it (via [`build_event`]) into an `ActivityEvent`, and appends
//! exactly one redacted JSONL line to `~/.claude/activity.jsonl` (or
//! `$NOSTROMO_ACTIVITY_PATH`, for testability) — the file
//! `agent_bus::tail_activity_jsonl` already tails.
//!
//! [`build_event`] is a pure function so the payload-shape mapping is
//! unit-testable without spawning this binary or touching the filesystem;
//! `main` is a thin, untested shell around it.

use std::io::Read;

use nostromo::agent_bus::ActivityEvent;

/// Env var overriding the activity log path (tests / non-standard installs).
pub const ACTIVITY_PATH_ENV: &str = "NOSTROMO_ACTIVITY_PATH";

/// The hook-payload-shape-specific fields of an `ActivityEvent` — everything
/// [`build_post_tool_use_fields`] and [`build_subagent_fields`] compute,
/// factored out of [`build_event`]'s common envelope (timestamp, focus tag,
/// session id, cwd).
struct EventFields {
    kind: &'static str,
    agent: String,
    tool_name: Option<String>,
    tool_use_id: Option<String>,
    agent_id: Option<String>,
    agent_type: Option<String>,
    parent_agent_id: Option<String>,
    summary: String,
}

/// `PostToolUse` → a `tool_use` event, summarized via
/// `activity::summary::summarize`. `None` if `tool_name` is missing.
fn build_post_tool_use_fields(obj: &serde_json::Map<String, serde_json::Value>) -> Option<EventFields> {
    let str_field = |key: &str| obj.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let tool_name = str_field("tool_name")?;
    let tool_input = obj.get("tool_input").cloned().unwrap_or(serde_json::Value::Null);
    let summary = nostromo::activity::summary::summarize(&tool_name, &tool_input);
    Some(EventFields {
        kind: "tool_use",
        agent: tool_name.clone(),
        tool_name: Some(tool_name),
        tool_use_id: str_field("tool_use_id"),
        // Present exactly when this `PostToolUse` fired inside a subagent —
        // absent for the main agent's own tool calls, which is the
        // discriminator `resolve_attribution` keys on. Previously hardcoded
        // to `None` unconditionally, so a subagent's own tool calls were
        // always misattributed to the main stream; only its
        // `SubagentStart`/`SubagentStop` bookends (built separately, below)
        // ever reached its own stream.
        agent_id: str_field("agent_id"),
        agent_type: str_field("agent_type"),
        parent_agent_id: str_field("parent_agent_id"),
        summary,
    })
}

/// `SubagentStart`/`SubagentStop` → a `subagent_start`/`subagent_stop` event.
/// `None` if `agent_id` or `agent_type` is missing.
///
/// A subagent spawned directly by the main agent carries no
/// `parent_agent_id` at all — its absence is a valid top-level subagent, not
/// malformed input.
fn build_subagent_fields(
    obj: &serde_json::Map<String, serde_json::Value>,
    hook_event_name: &str,
) -> Option<EventFields> {
    let str_field = |key: &str| obj.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let agent_id = str_field("agent_id")?;
    let agent_type = str_field("agent_type")?;
    let parent_agent_id = str_field("parent_agent_id");
    let kind = if hook_event_name == "SubagentStart" {
        "subagent_start"
    } else {
        "subagent_stop"
    };
    let verb = if kind == "subagent_start" { "started" } else { "finished" };
    let summary = format!("{agent_type} {verb}");
    Some(EventFields {
        kind,
        agent: agent_type.clone(),
        tool_name: None,
        tool_use_id: None,
        agent_id: Some(agent_id),
        agent_type: Some(agent_type),
        parent_agent_id,
        summary,
    })
}

/// Build an `ActivityEvent` from one Claude Code hook JSON payload.
///
/// Returns `None` (never panics) for:
/// - malformed/truncated JSON,
/// - a payload missing a required field (e.g. no `hook_event_name`),
/// - an unrecognized `hook_event_name` — this hook only handles
///   `PostToolUse`, `SubagentStart`, and `SubagentStop`; notably NOT
///   `PreToolUse` or any tool-*result* event.
///
/// Never reads `tool_response` — this hook records only that a tool ran, not
/// what it returned. Tool results are not attributed activity, and may
/// themselves carry data sensitive to the caller's context.
pub fn build_event(payload: &serde_json::Value) -> Option<ActivityEvent> {
    let obj = payload.as_object()?;
    let hook_event_name = obj.get("hook_event_name")?.as_str()?;

    let fields = match hook_event_name {
        "PostToolUse" => build_post_tool_use_fields(obj)?,
        "SubagentStart" | "SubagentStop" => build_subagent_fields(obj, hook_event_name)?,
        // Only PostToolUse/SubagentStart/SubagentStop are handled — never
        // PreToolUse, and never any tool-*result* event.
        _ => return None,
    };

    let str_field = |key: &str| obj.get(key).and_then(|v| v.as_str()).map(str::to_string);
    Some(ActivityEvent {
        ts: chrono::Utc::now(),
        agent: fields.agent,
        kind: fields.kind.to_string(),
        summary: fields.summary,
        focus_tag: std::env::var("NOSTROMO_FOCUS_TAG").ok(),
        session_id: str_field("session_id"),
        agent_id: fields.agent_id,
        agent_type: fields.agent_type,
        parent_agent_id: fields.parent_agent_id,
        tool_name: fields.tool_name,
        tool_use_id: fields.tool_use_id,
        cwd: str_field("cwd"),
        seq: None,
    })
}

fn main() {
    let mut buf = String::new();
    if std::io::stdin().read_to_string(&mut buf).is_err() {
        return;
    }
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(&buf) else {
        return;
    };
    let Some(event) = build_event(&payload) else {
        return;
    };

    let path = std::env::var(ACTIVITY_PATH_ENV)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            dirs_next::home_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("."))
                .join(".claude")
                .join("activity.jsonl")
        });

    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(line) = serde_json::to_string(&event) {
        use std::io::Write as _;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── 1. well-formed payload shapes ─────────────────────────────────────────

    #[test]
    fn post_tool_use_payload_produces_a_tool_use_event() {
        let payload = json!({
            "session_id": "sess-123",
            "transcript_path": "/tmp/transcript.jsonl",
            "cwd": "/Users/hammer/Code/nostromo",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_use_id": "tu-1",
            "tool_input": {"command": "ls -la"},
            "tool_response": {"output": "total 0"}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        assert_eq!(ev.kind, "tool_use");
        assert_eq!(ev.session_id.as_deref(), Some("sess-123"));
        assert_eq!(ev.cwd.as_deref(), Some("/Users/hammer/Code/nostromo"));
        assert_eq!(ev.tool_name.as_deref(), Some("Bash"));
        assert_eq!(ev.tool_use_id.as_deref(), Some("tu-1"));
    }

    #[test]
    fn post_tool_use_payload_without_tool_use_id_leaves_it_none() {
        let payload = json!({
            "session_id": "sess-123",
            "cwd": "/tmp",
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/a.rs"},
            "tool_response": {}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        assert_eq!(ev.tool_use_id, None);
    }

    #[test]
    fn post_tool_use_payload_inside_a_subagent_carries_agent_id_and_type() {
        // The case B7/resolve_attribution actually depends on: a subagent's
        // own tool call fires PostToolUse with agent_id/agent_type/
        // parent_agent_id present, which is the only signal that
        // distinguishes it from the main agent's own tool calls. Without
        // this, every subagent's real work is misattributed to the main
        // stream and only its SubagentStart/SubagentStop bookends land in
        // its own stream.
        let payload = json!({
            "session_id": "sess-123",
            "cwd": "/tmp",
            "hook_event_name": "PostToolUse",
            "tool_name": "Grep",
            "tool_use_id": "tu-7",
            "agent_id": "agent-42",
            "agent_type": "code-reviewer",
            "parent_agent_id": "agent-1",
            "tool_input": {"pattern": "TODO"},
            "tool_response": {}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        assert_eq!(ev.agent_id.as_deref(), Some("agent-42"));
        assert_eq!(ev.agent_type.as_deref(), Some("code-reviewer"));
        assert_eq!(ev.parent_agent_id.as_deref(), Some("agent-1"));
    }

    #[test]
    fn post_tool_use_payload_for_the_main_agent_has_no_agent_id() {
        // The negative case: absence of agent_id is what marks a tool_use
        // event as belonging to the main agent's own stream, not a missing
        // field to backfill.
        let payload = json!({
            "session_id": "sess-123",
            "cwd": "/tmp",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
            "tool_response": {}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        assert_eq!(ev.agent_id, None);
        assert_eq!(ev.agent_type, None);
        assert_eq!(ev.parent_agent_id, None);
    }

    #[test]
    fn subagent_start_payload_produces_a_subagent_start_event() {
        let payload = json!({
            "session_id": "sess-123",
            "hook_event_name": "SubagentStart",
            "agent_id": "agent-1",
            "agent_type": "cody",
            "parent_agent_id": "agent-0",
            "cwd": "/tmp"
        });
        let ev = build_event(&payload).expect("well-formed SubagentStart must produce an event");
        assert_eq!(ev.kind, "subagent_start");
        assert_eq!(ev.agent_id.as_deref(), Some("agent-1"));
        assert_eq!(ev.agent_type.as_deref(), Some("cody"));
        assert_eq!(ev.parent_agent_id.as_deref(), Some("agent-0"));
    }

    #[test]
    fn subagent_start_payload_missing_parent_agent_id_defaults_sanely() {
        // A top-level subagent spawned directly by the main agent carries no
        // `parent_agent_id` at all — its absence must not be treated as
        // malformed input.
        let payload = json!({
            "session_id": "sess-123",
            "hook_event_name": "SubagentStart",
            "agent_id": "agent-1",
            "agent_type": "cody",
            "cwd": "/tmp"
        });
        let ev = build_event(&payload)
            .expect("a missing parent_agent_id is a valid top-level subagent, not malformed input");
        assert_eq!(ev.parent_agent_id, None);
    }

    #[test]
    fn subagent_stop_payload_produces_a_subagent_stop_event() {
        let payload = json!({
            "session_id": "sess-123",
            "hook_event_name": "SubagentStop",
            "agent_id": "agent-1",
            "agent_type": "cody",
            "parent_agent_id": "agent-0",
            "cwd": "/tmp"
        });
        let ev = build_event(&payload).expect("well-formed SubagentStop must produce an event");
        assert_eq!(ev.kind, "subagent_stop");
        assert_eq!(ev.agent_id.as_deref(), Some("agent-1"));
    }

    // ── 2. malformed / incomplete input never panics ─────────────────────────

    #[test]
    fn a_payload_that_matches_no_recognized_shape_yields_none() {
        let payload = json!("not an object");
        assert!(build_event(&payload).is_none());
    }

    #[test]
    fn payload_missing_hook_event_name_yields_none() {
        let payload = json!({
            "session_id": "sess-123",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"}
        });
        assert!(build_event(&payload).is_none());
    }

    #[test]
    fn unrecognized_hook_event_name_yields_none() {
        for name in ["PreToolUse", "Stop", "Notification", "SessionStart"] {
            let payload = json!({
                "session_id": "sess-123",
                "hook_event_name": name,
                "tool_name": "Bash",
                "tool_input": {"command": "ls"}
            });
            assert!(
                build_event(&payload).is_none(),
                "hook_event_name {name} must not produce an event"
            );
        }
    }

    // ── 3. secrets and tool results never leak through the hook ─────────────

    #[test]
    fn bash_post_tool_use_with_a_secret_looking_command_is_scrubbed() {
        let payload = json!({
            "session_id": "sess-123",
            "cwd": "/tmp",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "curl -H 'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789' https://api.example.com"},
            "tool_response": {"output": "ok"}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        assert!(
            !ev.summary.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            "secret leaked into summary: {}",
            ev.summary
        );
    }

    #[test]
    fn tool_response_is_never_read_by_build_event() {
        let payload = json!({
            "session_id": "sess-123",
            "cwd": "/tmp",
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/a.rs"},
            "tool_response": {"output": "DISTINCTIVE_TOOL_RESPONSE_MARKER_98765"}
        });
        let ev = build_event(&payload).expect("well-formed PostToolUse must produce an event");
        let serialized = serde_json::to_string(&ev).unwrap();
        assert!(
            !serialized.contains("DISTINCTIVE_TOOL_RESPONSE_MARKER_98765"),
            "build_event must never read tool_response: {serialized}"
        );
    }
}
