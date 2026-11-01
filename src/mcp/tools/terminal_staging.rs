//! `nostromo.terminal_staging`: the agent that follows a terminal keeps a short
//! list of single-line commands for the user to place at its prompt.
//!
//! It edits a display list and nothing else. No byte reaches a terminal from
//! here: the Nostromo app shows the entries in a drawer, a human click places
//! one at the prompt (without a line break), and only the user's Enter runs it.
//! The caller is always its own focus (its Hello `pty_id`); only the focus that
//! currently follows the terminal may stage for it. Each `op` takes a closed
//! set of keys: any other is `unknown_argument` and nothing is changed.

use serde_json::{json, Map, Value};

use crate::mcp::state::McpSharedState;
use crate::terminal::agent_api::{StagingOp, StagingOutcome, StagingRefusal, StagingRequest};
use crate::terminal::staging::{StagingList, MAX_COMMAND_CHARS, MAX_ENTRIES, MAX_NOTE_CHARS};

/// The tool's name.
pub const NAME: &str = "nostromo.terminal_staging";

const OPS: [&str; 5] = ["list", "stage", "replace", "remove", "clear"];

/// The keys every call may carry; the op decides which of the rest it may.
const COMMON_KEYS: [&str; 2] = ["op", "terminal_id"];

/// What the agent is told the tool is.
pub const DESCRIPTION: &str = "Edits a display list only. Nothing here types, pastes or runs; the user clicks an entry to place it at the prompt and presses Enter themselves. \
For a terminal you follow (see nostromo.request_follow), keep up to 12 single-line commands the user can click to place at its prompt. One command per entry, plainly; no secrets; never disguise what a command does. \
Ops: list; stage {command, note?, position?} (position inserts before that entry number, default the end); replace {entry_id, command? and/or note?} (note '' clears it); remove {entry_id}; clear. \
Returns { ok, ... }: list gives { terminal_id, staging, frozen, entries: [{ id, number, command, note?, staged_at, inserted_count, last_inserted_at? }], limits }; stage gives { entry: { id, number }, entries }. \
A notice in your conversation says when the user placed an entry at the prompt, not that it ran. Entries are kept in memory only, and the user can remove them. \
Errors (nothing changed): invalid_args, unknown_argument (a key not allowed for that op), unknown_view, not_following (you do not follow that terminal, or the follow ended), terminal_not_running, no_operator (the Nostromo app is not open to show the drawer), staging_disabled (the user turned staging off, here or everywhere), rate_limited (retry_after seconds), invalid_text (one non-empty printable line: no line break, tab, control or invisible character, no leading or trailing space, no space but U+0020, at most 4 spaces in a row), entry_too_long (1000 characters), note_too_long (120), looks_like_secret (never stage secrets or personal data), remote_shell_command (ask with nostromo.request_remote_shell instead), history_expansion (in a remote shell, or a local one running a program: history expansion runs something other than what the user reads; spell the command out), types_into_another_terminal (staging never types into another pane), invalid_position, unknown_entry, list_full (12 entries).";

/// The descriptor registered in `tool_descriptors()`.
pub fn descriptor() -> Value {
    json!({
        "name": NAME,
        "description": DESCRIPTION,
        "inputSchema": {
            "type": "object",
            "properties": {
                "op": { "type": "string", "enum": OPS, "description": "list, stage, replace, remove or clear" },
                "terminal_id": { "type": "string", "description": "A terminal you follow, from nostromo.list_terminals" },
                "command": { "type": "string", "maxLength": MAX_COMMAND_CHARS, "description": "stage, replace: one line of printable text (at most 1000 characters). Never run for you: the user places it at the prompt and presses Enter." },
                "note": { "type": "string", "maxLength": MAX_NOTE_CHARS, "description": "stage, replace: a short plain note shown beside the entry (at most 120 characters); '' on replace clears it" },
                "position": { "type": "integer", "minimum": 1, "maximum": MAX_ENTRIES, "description": "stage: insert before the entry at this number; default the end" },
                "entry_id": { "type": "string", "description": "replace, remove: the id of an entry, from list" }
            },
            "required": ["op", "terminal_id"],
            "additionalProperties": false
        }
    })
}

/// Handle `nostromo.terminal_staging`.
pub async fn handle(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "terminal tools require the daemon-hosted MCP server" });
    };
    let args: Map<String, Value> = match arguments {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(o)) => o.clone(),
        Some(_) => {
            return json!({ "error": "invalid_args", "detail": "arguments must be an object" })
        }
    };
    let op_name = match parse_op(&args) {
        Ok(op) => op,
        Err(refusal) => return refusal,
    };
    let parsed = match parse_request(op_name, &args) {
        Ok(parsed) => parsed,
        Err(refusal) => return refusal,
    };
    let Some(tag) = pty_id.filter(|t| !t.is_empty()) else {
        return json!({ "error": "unknown_view" });
    };
    if !super::terminal::focus_exists(state, tag) {
        return json!({ "error": "unknown_view" });
    }
    let (terminal_id, op) = parsed;
    let request = StagingRequest {
        terminal_id: terminal_id.clone(),
        agent_name: super::remote_shell::agent_name(daemon, tag),
        op,
    };
    match daemon.terminals.staging(tag, request) {
        Ok(outcome) => render(&terminal_id, outcome),
        Err(refusal) => refusal_json(refusal),
    }
}

/// The op, after refusing any key outside the closed set (before anything else
/// is looked at).
fn parse_op(args: &Map<String, Value>) -> Result<&'static str, Value> {
    let all_keys = [
        "op",
        "terminal_id",
        "command",
        "note",
        "position",
        "entry_id",
    ];
    if let Some(key) = args.keys().find(|k| !all_keys.contains(&k.as_str())) {
        return Err(json!({ "error": "unknown_argument", "detail": key }));
    }
    let op = match args.get("op") {
        Some(Value::String(s)) => OPS.iter().find(|o| **o == s.as_str()).copied(),
        _ => None,
    };
    let Some(op) = op else {
        return Err(json!({
            "error": "invalid_args",
            "detail": "op is required: list, stage, replace, remove or clear"
        }));
    };
    let allowed: &[&str] = match op {
        "stage" => &["command", "note", "position"],
        "replace" => &["entry_id", "command", "note"],
        "remove" => &["entry_id"],
        _ => &[],
    };
    if let Some(key) = args
        .keys()
        .find(|k| !COMMON_KEYS.contains(&k.as_str()) && !allowed.contains(&k.as_str()))
    {
        return Err(json!({ "error": "unknown_argument", "detail": key }));
    }
    Ok(op)
}

/// The terminal id and the operation, with every required key present and of
/// the right type.
fn parse_request(op: &str, args: &Map<String, Value>) -> Result<(String, StagingOp), Value> {
    let terminal_id = match args.get("terminal_id") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => return Err(invalid("terminal_id is required (a string)")),
    };
    let string = |key: &str| -> Result<Option<String>, Value> {
        match args.get(key) {
            None => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.clone())),
            Some(_) => Err(invalid(&format!("{key} must be a string"))),
        }
    };
    let entry_id = |required: bool| -> Result<String, Value> {
        match string("entry_id")? {
            Some(id) if !id.is_empty() => Ok(id),
            _ if required => Err(invalid("entry_id is required (a string)")),
            _ => Ok(String::new()),
        }
    };
    let staged = match op {
        "stage" => {
            let command =
                string("command")?.ok_or_else(|| invalid("command is required (a string)"))?;
            let position = match args.get("position") {
                None => None,
                Some(Value::Number(n)) => match (n.as_u64(), n.as_i64()) {
                    (Some(p), _) => Some(usize::try_from(p).unwrap_or(usize::MAX)),
                    // Negative: no such position.
                    (None, Some(_)) => Some(usize::MAX),
                    _ => return Err(invalid("position must be an integer")),
                },
                Some(_) => return Err(invalid("position must be an integer")),
            };
            StagingOp::Stage {
                command,
                note: string("note")?,
                position,
            }
        }
        "replace" => {
            let entry_id = entry_id(true)?;
            let command = string("command")?;
            let note = string("note")?;
            if command.is_none() && note.is_none() {
                return Err(invalid("replace needs command and/or note"));
            }
            StagingOp::Replace {
                entry_id,
                command,
                note,
            }
        }
        "remove" => StagingOp::Remove {
            entry_id: entry_id(true)?,
        },
        "clear" => StagingOp::Clear,
        _ => StagingOp::List,
    };
    Ok((terminal_id, staged))
}

fn invalid(detail: &str) -> Value {
    json!({ "error": "invalid_args", "detail": detail })
}

fn refusal_json(refusal: StagingRefusal) -> Value {
    let mut out = json!({ "error": refusal.code });
    if let Some(detail) = refusal.detail {
        out["detail"] = json!(detail);
    }
    if let Some(seconds) = refusal.retry_after {
        out["retry_after"] = json!(seconds);
    }
    out
}

fn render(terminal_id: &str, outcome: StagingOutcome) -> Value {
    match outcome {
        StagingOutcome::List(list) => render_list(terminal_id, &list),
        StagingOutcome::Staged {
            entry_id,
            number,
            entries,
        } => {
            json!({ "ok": true, "entry": { "id": entry_id, "number": number }, "entries": entries })
        }
        StagingOutcome::Replaced { entry_id, number } => {
            json!({ "ok": true, "entry": { "id": entry_id, "number": number } })
        }
        StagingOutcome::Removed { entries } => json!({ "ok": true, "entries": entries }),
        StagingOutcome::Cleared => json!({ "ok": true, "entries": 0 }),
    }
}

fn render_list(terminal_id: &str, list: &StagingList) -> Value {
    let entries: Vec<Value> = list
        .entries
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let mut entry = json!({
                "id": e.id,
                "number": i + 1,
                "command": e.command,
                "staged_at": e.staged_at,
                "inserted_count": e.inserted_count,
            });
            if let Some(note) = &e.note {
                entry["note"] = json!(note);
            }
            if let Some(at) = e.last_inserted_at {
                entry["last_inserted_at"] = json!(at);
            }
            entry
        })
        .collect();
    json!({
        "ok": true,
        "terminal_id": terminal_id,
        "staging": "on",
        "frozen": false,
        "entries": entries,
        "limits": {
            "max_entries": MAX_ENTRIES,
            "max_command_chars": MAX_COMMAND_CHARS,
            "max_note_chars": MAX_NOTE_CHARS,
        },
    })
}
