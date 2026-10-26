//! The only terminal handle MCP code receives.
//!
//! An agent may open a local shell in its own focus, *ask* for a remote one
//! (the user decides), list the terminals it can see, *ask* to follow one (the
//! user decides) and, while it follows one, read its redacted screen: and
//! nothing else. [`TerminalAgentApi`] wraps the manager but exposes no way to
//! write input, resize, attach (read output), close or restart a terminal, to
//! open a remote shell without the user's Connect, or to read a screen it was
//! not invited to, and it holds no [`super::OperatorCap`].
//! `tests/terminal_policy.rs` keeps `src/mcp/` from naming anything more
//! powerful.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::sync::broadcast;

use super::ecs::{EcsVocabulary, VocabError};
use super::follow::manager::{pane_name, FollowGrant, FOLLOW_ALLOW, FOLLOW_DENY};
use super::follow::{ScreenRead, ScreenReadError};
use super::launcher::Placement;
use super::remote_request::{self, clean_reason, RemoteRequest, RemoteResult};
use super::{TerminalError, TerminalManager};
use crate::ipc::decisions::{DecisionOutcome, DecisionRegistry};
use crate::ipc::protocol::{
    DecisionChoice, RemoteRequester, RemoteShellProject, ServerMsg, TerminalInfo, TerminalKind,
    TerminalStatus,
};

/// The tool that reads a followed terminal's screen (for the refusal's audit line).
pub const READ_SCREEN_TOOL: &str = "nostromo.read_terminal_screen";
/// What an agent that tried to read a screen it may not read is told.
pub const READ_FORBIDDEN: &str = "terminal_read_forbidden";

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

/// An agent's request to follow one of its focus's terminals: the user decides.
#[derive(Debug, Clone)]
pub struct AgentFollowRequest {
    /// The agent's focus (its Hello `pty_id`): the one that would follow.
    pub tag: String,
    /// The agent's name, for the decision sheet.
    pub agent: Option<String>,
    pub terminal_id: String,
    pub reason: Option<String>,
    /// How long to wait for the user.
    pub timeout: Duration,
}

/// How [`TerminalAgentApi::request_follow`] ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FollowRequestResult {
    /// Following started (or already was, for this focus).
    Following,
    Denied,
    Dismissed,
    TimedOut,
    /// No verified app that can show the sheet and stop a follow is connected.
    /// Nobody was asked.
    NoOperator,
    /// The agent's session went away while it waited.
    Cancelled,
    /// Nothing happened, for the reason this code names: `unknown_terminal`,
    /// `terminal_not_running`, `request_pending`, `follower_not_running`,
    /// `follow_unavailable`.
    Refused(&'static str),
}

/// What an agent is told about a terminal it can see: metadata, never output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTerminal {
    pub terminal_id: String,
    pub label: String,
    pub kind: TerminalKind,
    pub status: TerminalStatus,
    /// The asking focus is the terminal's follower (active or paused).
    pub followed_by_you: bool,
}

/// What an agent's focus may do with terminals: open a local one, request a
/// remote one, list the ones it sees, ask to follow one, read the screen of one
/// it follows, ask whether a pane is one, and record a refusal.
#[derive(Clone)]
pub struct TerminalAgentApi {
    manager: Arc<Mutex<TerminalManager>>,
    /// Focuses with a follow request waiting for the user (one at a time each).
    asking: Arc<Mutex<HashSet<String>>>,
}

impl TerminalAgentApi {
    pub fn new(manager: Arc<Mutex<TerminalManager>>) -> Self {
        Self {
            manager,
            asking: Arc::default(),
        }
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

    /// The terminals `focus_tag` can see: its own, and any other focus's that it
    /// follows. Metadata only.
    pub fn list_terminals(&self, focus_tag: &str) -> Vec<AgentTerminal> {
        self.lock()
            .list()
            .into_iter()
            .filter_map(|info| {
                let followed_by_you = info.follower.as_ref().is_some_and(|f| f.tag == focus_tag);
                (info.tag == focus_tag || followed_by_you).then_some(AgentTerminal {
                    terminal_id: info.terminal_id,
                    label: info.label,
                    kind: info.kind,
                    status: info.status,
                    followed_by_you,
                })
            })
            .collect()
    }

    /// Ask the user to let `request.tag` follow one of its focus's terminals,
    /// and wait for the answer.
    ///
    /// Checks first, asking no one: the terminal must be the focus's own and
    /// running, and a verified app that can show who follows and stop it
    /// (`terminal_follow_ui`) must be connected (else `NoOperator`). Then a
    /// decision is posed to the user (Allow or Deny; only the verified app can
    /// answer one). Allow starts following (without the screen) from here, in
    /// this call: if the call is dropped first, the sheet is withdrawn and
    /// nothing follows.
    pub async fn request_follow(
        &self,
        request: AgentFollowRequest,
        decisions: &Arc<Mutex<DecisionRegistry>>,
        broadcast: &broadcast::Sender<ServerMsg>,
    ) -> FollowRequestResult {
        let (info, follow, sensitive, follow_ui) = {
            let m = self.lock();
            (
                m.info(&request.terminal_id),
                m.follow(),
                m.sensitive_tags().tag_is_sensitive(&request.tag),
                m.follow_ui_connected(),
            )
        };
        // Another focus's terminal is answered like one that does not exist.
        let Some(info) = info.filter(|i| i.tag == request.tag) else {
            return FollowRequestResult::Refused("unknown_terminal");
        };
        if info.follower.as_ref().is_some_and(|f| f.tag == request.tag) {
            return FollowRequestResult::Following;
        }
        if info.status != TerminalStatus::Running {
            return FollowRequestResult::Refused("terminal_not_running");
        }
        let Some(follow) = follow else {
            return FollowRequestResult::Refused("follow_unavailable");
        };
        if !follow_ui || !lock(decisions).has_operator_for(sensitive) {
            return FollowRequestResult::NoOperator;
        }
        let Some(_asking) = Asking::start(&self.asking, &request.tag) else {
            return FollowRequestResult::Refused("request_pending");
        };

        let (request_id, mut rx, sheet) = lock(decisions).submit(
            request.tag.clone(),
            follow_prompt(&info, &request),
            request.reason.as_deref().and_then(clean_reason),
            vec![
                DecisionChoice {
                    id: FOLLOW_ALLOW.into(),
                    label: "Allow".into(),
                    detail: None,
                    is_default: false,
                },
                DecisionChoice {
                    id: FOLLOW_DENY.into(),
                    label: "Deny".into(),
                    detail: None,
                    is_default: false,
                },
            ],
            None,
        );
        if let Some(sheet) = sheet {
            let _ = broadcast.send(sheet);
        }
        // From here, a dropped call withdraws the sheet.
        let mut withdraw = Withdraw {
            decisions,
            broadcast,
            request_id: &request_id,
            armed: true,
        };
        let outcome = match tokio::time::timeout(request.timeout, &mut rx).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => DecisionOutcome::Cancelled,
            Err(_) => {
                // Out of time: end the request (closing the sheet, showing the
                // next one queued behind it). An answer that raced the
                // timeout is already in `rx` and wins.
                withdraw.withdraw();
                rx.await.unwrap_or(DecisionOutcome::TimedOut)
            }
        };
        withdraw.armed = false;
        drop(withdraw);

        if let Some(grant) = FollowGrant::from_decision(&outcome) {
            return match follow.invite_granted(grant, &request.terminal_id, &request.tag) {
                Ok(()) => FollowRequestResult::Following,
                Err(e) => FollowRequestResult::Refused(e.code()),
            };
        }
        match outcome {
            DecisionOutcome::Dismissed => FollowRequestResult::Dismissed,
            DecisionOutcome::TimedOut => FollowRequestResult::TimedOut,
            DecisionOutcome::Cancelled => FollowRequestResult::Cancelled,
            DecisionOutcome::Answered(_) => FollowRequestResult::Denied,
        }
    }

    /// The redacted plain-text screen of `terminal_id`, for `focus_tag`, only
    /// while that focus follows it (active or paused). Any other case (never
    /// invited, stopped, someone else's, no such terminal) is one answer,
    /// [`ScreenReadRefused::Forbidden`], audited as `refused {channel: "mcp",
    /// op: "read"}`.
    pub fn read_screen_if_following(
        &self,
        focus_tag: &str,
        terminal_id: &str,
    ) -> Result<ScreenRead, ScreenReadRefused> {
        let follow = self.lock().follow();
        let read = follow
            .ok_or(ScreenReadError::NotFollowing)
            .and_then(|f| f.read_screen_as(focus_tag, terminal_id));
        match read {
            Ok(screen) => Ok(screen),
            Err(ScreenReadError::NotFollowing) => {
                self.audit_refusal(Some(focus_tag), "read", READ_SCREEN_TOOL, READ_FORBIDDEN);
                Err(ScreenReadRefused::Forbidden)
            }
            Err(ScreenReadError::Withheld) => Err(ScreenReadRefused::Withheld),
        }
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

/// Why [`TerminalAgentApi::read_screen_if_following`] returned no screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenReadRefused {
    /// The asker may not read it: it does not follow the terminal.
    Forbidden,
    /// Redaction failed, so nothing was returned (fail closed).
    Withheld,
}

impl ScreenReadRefused {
    /// The code the agent is told.
    pub fn code(self) -> &'static str {
        match self {
            Self::Forbidden => READ_FORBIDDEN,
            Self::Withheld => "redaction_failed",
        }
    }
}

/// What the user is asked: who asks, for which pane, and where the output goes.
/// A remote pane's sheet leads with the environment in capitals.
fn follow_prompt(info: &TerminalInfo, request: &AgentFollowRequest) -> String {
    let clean = |s: &str| clean_reason(s).unwrap_or_default();
    let agent = request
        .agent
        .as_deref()
        .and_then(clean_reason)
        .unwrap_or_else(|| "An agent".to_string());
    let who = format!("{agent} in {}", clean(&request.tag));
    let pane = clean(&pane_name(info));
    match (info.kind, &info.target) {
        (TerminalKind::Ecs, target) => {
            let environment = target
                .as_ref()
                .map_or_else(|| "REMOTE".to_string(), |t| t.environment.to_uppercase());
            format!(
                "Output from {environment} will be sent to {agent}'s model. {who} asks to follow {pane}."
            )
        }
        (TerminalKind::Local, _) => {
            format!("{who} asks to follow {pane}. Output will be sent to {agent}'s model.")
        }
    }
}

/// A focus's place in line: one follow request waiting for the user at a time.
struct Asking<'a> {
    asking: &'a Mutex<HashSet<String>>,
    tag: String,
}

impl<'a> Asking<'a> {
    fn start(asking: &'a Mutex<HashSet<String>>, tag: &str) -> Option<Self> {
        lock(asking).insert(tag.to_string()).then(|| Self {
            asking,
            tag: tag.to_string(),
        })
    }
}

impl Drop for Asking<'_> {
    fn drop(&mut self) {
        lock(self.asking).remove(&self.tag);
    }
}

/// A decision that nobody is waiting for any more: withdrawn (resolved as timed
/// out, which closes the sheet) when the call is dropped or ran out of time.
struct Withdraw<'a> {
    decisions: &'a Arc<Mutex<DecisionRegistry>>,
    broadcast: &'a broadcast::Sender<ServerMsg>,
    request_id: &'a str,
    armed: bool,
}

impl Withdraw<'_> {
    fn withdraw(&self) {
        // The next request queued behind this one, if any, is shown now.
        if let Some(next) = lock(self.decisions).timeout_request(self.request_id) {
            let _ = self.broadcast.send(next);
        }
    }
}

impl Drop for Withdraw<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.withdraw();
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
