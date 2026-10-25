//! The only terminal handle MCP code receives.
//!
//! An agent may open a local shell in its own focus, and *ask* for a remote
//! one (the user decides), and nothing else: [`TerminalAgentApi`] wraps the
//! manager but exposes no way to write input, resize, attach (read output),
//! close or restart a terminal, or to open a remote shell without the user's
//! Connect, and it holds no [`super::OperatorCap`]. `tests/terminal_policy.rs` keeps `src/mcp/` from
//! naming anything more powerful.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use std::time::Duration;

use super::ecs::{EcsVocabulary, VocabError};
use super::launcher::Placement;
use super::remote_request::{self, RemoteRequest, RemoteResult};
use super::{TerminalError, TerminalManager};
use crate::ipc::protocol::{RemoteRequester, RemoteShellProject, TerminalInfo};

/// Longest `tool` or `focus` string an audit line keeps (both are whatever the
/// caller sent: a tool name, and the `pty_id` it declared).
const MAX_AUDIT_FIELD_LEN: usize = 128;

/// The remote-shell vocabulary, as the agent's `list` tool shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteTargets {
    pub projects: Vec<RemoteShellProject>,
    pub shell_types: Vec<String>,
}

/// An agent's request for a remote shell: four words from the vocabulary
/// (canonical or aliased) and why. There is no command in it.
#[derive(Debug, Clone)]
pub struct AgentRemoteRequest {
    /// The agent's focus (its Hello `pty_id`): where the pane would open.
    pub tag: String,
    /// The agent's name, for the confirm sheet.
    pub agent: Option<String>,
    pub project: String,
    pub environment: String,
    pub service: String,
    pub shell_type: String,
    pub reason: Option<String>,
    pub timeout: Duration,
}

/// What an agent's focus may do with terminals: open a local one, request a
/// remote one, ask whether a pane is one, and record a refusal.
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

    /// The vocabulary a request may use, read from the layer's files now.
    pub fn list_remote_targets(&self) -> Result<RemoteTargets, VocabError> {
        let paths = self.lock().ecs_paths().clone();
        let vocabulary = EcsVocabulary::load(&paths)?;
        Ok(RemoteTargets {
            projects: vocabulary.projects(),
            shell_types: vocabulary.shell_types(),
        })
    }

    /// Ask the user for a remote shell and wait for the answer.
    ///
    /// Opens nothing by itself: an unknown word returns at once with no one
    /// asked; otherwise the verified app is shown a confirm sheet and the
    /// shell is started only if the user clicks Connect
    /// (see [`remote_request::run`]). Whatever the user does, the agent never
    /// gets the shell's input or output.
    pub async fn request_remote(&self, request: AgentRemoteRequest) -> RemoteResult {
        let request = RemoteRequest {
            requested_by: RemoteRequester {
                kind: "focus".into(),
                tag: Some(request.tag.clone()),
                agent: request.agent,
            },
            tag: request.tag,
            project: request.project,
            environment: request.environment,
            service: request.service,
            shell_type: request.shell_type,
            reason: request.reason,
            timeout: request.timeout,
            placement: Placement::default(),
        };
        remote_request::run(&self.manager, request).await
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
