//! `nostromo.open_terminal`: an agent opens a local terminal pane in its own
//! focus, and that is all it can do with it.
//!
//! The user types into the terminal. There is no tool to write input to, read
//! output from or close one, and the tool takes no command, environment or
//! initial input, so an agent cannot use it to run anything. The handle it
//! uses ([`crate::terminal::TerminalAgentApi`]) has no way to do more.

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::ipc::pane_registry::PaneError;
use crate::mcp::state::{DaemonMcpBackend, McpSharedState};

/// The one argument the tool takes.
const WORKING_DIRECTORY: &str = "working_directory";

/// Handle `nostromo.open_terminal`.
pub async fn open_terminal(
    state: &McpSharedState,
    arguments: Option<&Value>,
    pty_id: Option<&str>,
) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "open_terminal requires the daemon-hosted MCP server" });
    };
    let args = arguments.unwrap_or(&Value::Null);
    let object = match args {
        Value::Null => None,
        Value::Object(o) => Some(o),
        _ => return json!({ "error": "invalid_args", "detail": "arguments must be an object" }),
    };

    if let Some(key) = object
        .into_iter()
        .flat_map(|o| o.keys())
        .find(|k| k.as_str() != WORKING_DIRECTORY)
    {
        return json!({ "error": "unknown_argument", "detail": key });
    }

    // The caller's own focus, and only that: no `view_id`.
    let Some(tag) = pty_id.filter(|t| !t.is_empty()) else {
        return json!({ "error": "unknown_view" });
    };
    if !focus_exists(state, tag) {
        return json!({ "error": "unknown_view" });
    }

    let requested = match object.and_then(|o| o.get(WORKING_DIRECTORY)) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(PathBuf::from(s)),
        Some(_) => return json!({ "error": "invalid_working_directory" }),
    };
    let cwd = match requested {
        Some(path) if path.is_absolute() && path.is_dir() => Some(path),
        Some(_) => return json!({ "error": "invalid_working_directory" }),
        // Default: where the focus's session runs (else the manager's `$HOME`).
        None => daemon
            .session_mgr
            .lock()
            .ok()
            .and_then(|m| m.cwd_for(tag))
            .filter(|p| p.is_dir()),
    };

    match daemon.terminals.open_local(tag, cwd) {
        Ok(info) => json!({ "ok": true, "terminal_id": info.terminal_id, "pane_id": info.pane_id }),
        Err(e) => json!({ "error": e.code() }),
    }
}

/// Does `tag` name a focus the daemon knows (a pane tree or a session)?
fn focus_exists(state: &McpSharedState, tag: &str) -> bool {
    let Some(daemon) = &state.daemon else {
        return false;
    };
    if daemon
        .pane_registry
        .lock()
        .is_ok_and(|panes| panes.get(tag).is_some())
    {
        return true;
    }
    daemon
        .session_mgr
        .lock()
        .is_ok_and(|m| m.focus_registry().iter().any(|f| f.tag == tag))
}

// ── protecting terminal panes ─────────────────────────────────────────────────

/// What a tool that targets `pane_id` of `tag` returns when that pane is a
/// live terminal (and audits the refusal as `op`): `terminal_pane_protected`.
/// `None` when it is not one. Call it holding no pane-registry lock.
pub(crate) fn refuse_terminal_target(
    daemon: &DaemonMcpBackend,
    pty_id: Option<&str>,
    tool: &str,
    op: &str,
    tag: &str,
    pane_id: &str,
) -> Option<Value> {
    if !daemon.terminals.is_terminal_leaf(tag, pane_id) {
        return None;
    }
    let code = PaneError::TerminalProtected.code();
    daemon.terminals.audit_refusal(pty_id, op, tool, code);
    Some(json!({ "error": code }))
}

/// Audit a pane-registry refusal that concerns terminals (`op: "layout"`).
/// Any other error is ignored. Call it holding no pane-registry lock.
pub(crate) fn audit_pane_refusal(
    daemon: &DaemonMcpBackend,
    pty_id: Option<&str>,
    tool: &str,
    error: PaneError,
) {
    if matches!(
        error,
        PaneError::TerminalProtected | PaneError::ReservedPaneId
    ) {
        daemon
            .terminals
            .audit_refusal(pty_id, "layout", tool, error.code());
    }
}

// ── refusing everything else ──────────────────────────────────────────────────

/// What a refused, terminal-shaped request tried to do to a terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalOp {
    /// Write to it: input, keys, paste, a signal, running something.
    Input,
    /// Read from it: its output, screen or scrollback.
    Read,
    /// Close it.
    Close,
}

impl TerminalOp {
    pub fn as_str(self) -> &'static str {
        match self {
            TerminalOp::Input => "input",
            TerminalOp::Read => "read",
            TerminalOp::Close => "close",
        }
    }

    /// The refusal's code, `terminal_<op>_forbidden`.
    pub fn forbidden_code(self) -> String {
        format!("terminal_{}_forbidden", self.as_str())
    }
}

/// Words that make a name about a terminal.
const TERMINAL_WORDS: [&str; 5] = ["terminal", "shell", "pty", "tty", "console"];

/// Verbs that write to a terminal, read from one, close one. Matched as
/// substrings, deliberately wide: a miss lets a made-up tool name through as
/// "unknown tool" without the audit line, a false hit only changes its code.
const INPUT_VERBS: [&str; 16] = [
    "input",
    "write",
    "send",
    "key",
    "paste",
    "type",
    "signal",
    "kill",
    "interrupt",
    "exec",
    "run",
    "stdin",
    "typing",
    "command",
    "resize",
    "restart",
];
const READ_VERBS: [&str; 13] = [
    "read",
    "output",
    "screen",
    "scrollback",
    "tail",
    "capture",
    "snapshot",
    "follow",
    "attach",
    "history",
    "contents",
    "buffer",
    "stream",
];
const CLOSE_VERBS: [&str; 7] = [
    "close",
    "remove",
    "destroy",
    "detach",
    "stop",
    "terminate",
    "exit",
];

/// Names that type into a terminal without saying which one.
const BARE_INPUT_NAMES: [&str; 4] = ["send_key", "sendkey", "keystroke", "stdin"];

/// Real tool names the classifier would match anyway, each with the reason.
/// Empty: `nostromo.open_terminal` matches no verb. A later tool that does
/// must be listed here deliberately (`no_registered_tool_is_classified`).
const EXEMPT_TOOL_NAMES: [(&str, &str); 0] = [];

/// Does `name` look like an attempt to write to, read from or close a
/// terminal? A tool with such a name is never registered.
pub fn classify_terminal_attempt(name: &str) -> Option<TerminalOp> {
    if EXEMPT_TOOL_NAMES.iter().any(|(n, _)| *n == name) {
        return None;
    }
    let lower = name.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| lower.contains(w));
    let bare_input = has(&BARE_INPUT_NAMES);
    if !bare_input && !has(&TERMINAL_WORDS) {
        return None;
    }
    if bare_input || has(&INPUT_VERBS) {
        Some(TerminalOp::Input)
    } else if has(&READ_VERBS) {
        Some(TerminalOp::Read)
    } else if has(&CLOSE_VERBS) {
        Some(TerminalOp::Close)
    } else {
        None
    }
}

/// How a terminal-shaped frame on the MCP socket names itself, if it is one.
pub struct TerminalFrame {
    /// The verb after the `terminal_`/`pty_`/`terminal/`/`pty/` prefix, safe
    /// to put in the audit trail.
    pub verb: String,
    /// The name to quote back in the refusal.
    pub name: String,
    pub op: TerminalOp,
}

/// A frame that is not MCP's JSON-RPC but one of the daemon's terminal
/// messages (`"type": "terminal_…"`), or a JSON-RPC `method` in a `terminal/`
/// or `pty/` namespace. Neither is something this socket serves.
pub fn terminal_frame(frame: &Value) -> Option<TerminalFrame> {
    // A `type` only means something on a frame that is not JSON-RPC.
    let typed = frame
        .get("type")
        .filter(|_| frame.get("jsonrpc").is_none())
        .and_then(Value::as_str);
    let methoded = frame.get("method").and_then(Value::as_str);
    let (named, verb) = [typed, methoded].into_iter().flatten().find_map(|named| {
        // Case and `.`/`-` for `_` do not make a different frame.
        let normal = named.to_ascii_lowercase().replace(['.', '-'], "_");
        ["terminal_", "pty_", "terminal/", "pty/"]
            .iter()
            .find_map(|prefix| normal.strip_prefix(prefix).map(str::to_owned))
            .map(|verb| (named, verb))
    })?;
    let verb: String = verb
        .chars()
        .take(32)
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_lowercase() || *c == '_')
        .collect();
    let verb = if verb.is_empty() {
        "unknown".to_owned()
    } else {
        verb
    };
    let op = classify_terminal_attempt(named).unwrap_or(match verb.as_str() {
        "attach" => TerminalOp::Read,
        "detach" => TerminalOp::Close,
        _ => TerminalOp::Input,
    });
    Some(TerminalFrame {
        verb,
        name: named.chars().take(64).collect(),
        op,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::tools::tool_descriptors;

    #[test]
    fn the_names_an_agent_might_guess_are_classified() {
        for (name, op) in [
            (concat!("nostromo_terminal_", "input"), TerminalOp::Input),
            ("nostromo_send_keys", TerminalOp::Input),
            ("terminal_write", TerminalOp::Input),
            ("nostromo_paste_to_shell", TerminalOp::Input),
            ("nostromo_terminal_signal", TerminalOp::Input),
            ("nostromo.terminal_kill", TerminalOp::Input),
            ("nostromo_close_terminal", TerminalOp::Close),
            ("nostromo_read_terminal_output", TerminalOp::Read),
            ("pty_snapshot", TerminalOp::Read),
            ("nostromo.terminal_attach", TerminalOp::Read),
            ("get_terminal_buffer", TerminalOp::Read),
            ("terminal_history", TerminalOp::Read),
            ("terminal_resize", TerminalOp::Input),
            ("terminate_shell", TerminalOp::Close),
            ("Nostromo.Terminal_Exit", TerminalOp::Close),
        ] {
            assert_eq!(classify_terminal_attempt(name), Some(op), "{name}");
        }
    }

    #[test]
    fn ordinary_unknown_names_are_not_classified() {
        for name in [
            "nostromo.no_such_tool",
            "perri.list_pr_queue",
            "",
            "nostromo.show",
        ] {
            assert_eq!(classify_terminal_attempt(name), None, "{name}");
        }
    }

    #[test]
    fn no_registered_tool_is_classified() {
        for d in tool_descriptors() {
            let name = d["name"].as_str().expect("tool name");
            assert_eq!(classify_terminal_attempt(name), None, "{name}");
        }
    }

    #[test]
    fn terminal_frames_are_recognised_in_both_shapes_and_nothing_else_is() {
        let f = terminal_frame(&json!({"type": "terminal_resize"})).expect("type frame");
        assert_eq!(f.verb, "resize");
        let f = terminal_frame(&json!({"jsonrpc": "2.0", "id": 9, "method": "terminal/input"}))
            .expect("method frame");
        assert_eq!((f.verb.as_str(), f.op), ("input", TerminalOp::Input));
        let f = terminal_frame(&json!({"type": "pty_attach"})).expect("pty frame");
        assert_eq!(f.op, TerminalOp::Read);
        assert!(
            terminal_frame(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).is_none()
        );
        for frame in [
            json!({"type": "Terminal_Resize"}),
            json!({"type": "terminal.resize"}),
            json!({"type": "pty-attach"}),
        ] {
            assert!(terminal_frame(&frame).is_some(), "{frame}");
        }
        assert!(terminal_frame(&json!({"type": "hello"})).is_none());
        // A JSON-RPC frame is judged by its method, not a stray `type`.
        assert!(terminal_frame(
            &json!({"jsonrpc": "2.0", "id": 1, "method": "ping", "type": "terminal_x"})
        )
        .is_none());
    }
}
