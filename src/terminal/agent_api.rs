//! The only terminal handle MCP code receives.
//!
//! An agent may open a local shell in its own focus and nothing else:
//! [`TerminalAgentApi`] wraps the manager but exposes no way to write input,
//! resize, attach (read output), close or restart a terminal, and it holds no
//! [`super::OperatorCap`]. `tests/terminal_policy.rs` keeps `src/mcp/` from
//! naming anything more powerful.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use super::{TerminalError, TerminalManager};
use crate::ipc::protocol::TerminalInfo;

/// Longest `tool` or `focus` string an audit line keeps (both are whatever the
/// caller sent: a tool name, and the `pty_id` it declared).
const MAX_AUDIT_FIELD_LEN: usize = 128;

/// What an agent's focus may do with terminals: open one, ask whether a pane
/// is one, and record a refusal.
#[derive(Clone)]
pub struct TerminalAgentApi {
    manager: Arc<Mutex<TerminalManager>>,
}

impl TerminalAgentApi {
    pub fn new(manager: Arc<Mutex<TerminalManager>>) -> Self {
        Self { manager }
    }

    /// A handle on a manager with no audit file, store or pane registry.
    pub fn in_memory() -> Self {
        Self::new(TerminalManager::in_memory())
    }

    /// Open a local login shell in focus `tag` (default `$HOME` when `cwd` is
    /// `None`). Audited as `opened {requested_by: {kind: "focus", tag}}`.
    pub fn open_local(
        &self,
        tag: &str,
        cwd: Option<PathBuf>,
    ) -> Result<TerminalInfo, TerminalError> {
        self.lock().open_local_for_agent(tag, cwd)
    }

    /// Is `pane_id` in `tag` a registered terminal leaf?
    ///
    /// Takes the manager's lock, so call it before locking the pane registry,
    /// never while holding it (the manager locks the registry itself).
    pub fn is_terminal_leaf(&self, tag: &str, pane_id: &str) -> bool {
        self.lock().is_terminal_leaf(tag, pane_id)
    }

    /// Record that a request from `focus` over MCP was refused: `op` is what it
    /// tried (`input`, `read`, `close`, `content`, `layout`, …), `tool` the
    /// tool or frame, `code` the refusal's code.
    pub fn audit_refusal(&self, focus: Option<&str>, op: &str, tool: &str, code: &str) {
        let clip = |s: &str| -> String { s.chars().take(MAX_AUDIT_FIELD_LEN).collect() };
        let focus = focus.map(clip);
        self.lock()
            .audit_refused_mcp(op, Some(code), None, focus.as_deref(), Some(&clip(tool)));
    }

    fn lock(&self) -> MutexGuard<'_, TerminalManager> {
        self.manager.lock().unwrap_or_else(|e| e.into_inner())
    }
}
