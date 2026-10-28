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

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use tokio::sync::broadcast;

use super::ecs::{EcsVocabulary, VocabError};
use super::follow::manager::{pane_name, FollowGrant, FOLLOW_ALLOW, FOLLOW_DENY};
use super::follow::{FollowError, ScreenRead, ScreenReadError};
use super::launcher::Placement;
use super::remote_request::{
    self, clean_reason, Clock, FocusLimits, LimitRefused, RemoteRequest, RemoteResult,
};
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

/// The least time between two screen reads by one follower. A read inside it
/// is refused as [`READ_TOO_SOON`], nothing is read and nothing but the refusal
/// is audited.
pub const MIN_READ_INTERVAL: Duration = Duration::from_secs(2);
/// The most screen reads one follower gets in [`READ_WINDOW`]; the next is
/// refused as [`READ_LIMIT`].
pub const MAX_READS_PER_WINDOW: usize = 240;
pub const READ_WINDOW: Duration = Duration::from_secs(60 * 60);
/// Refusal codes of the read limits.
pub const READ_TOO_SOON: &str = "read_too_soon";
pub const READ_LIMIT: &str = "read_limit";

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
    /// Nothing happened: see [`FollowRefusal`].
    Refused(FollowRefusal),
}

/// Why [`TerminalAgentApi::request_follow`] changed nothing. The first six are
/// this API's own refusals, made before anyone is asked (no sheet is shown for
/// any of them); [`FollowRefusal::NotStarted`] is the follow engine's, after
/// the user said Allow. Their codes ([`FollowRefusal::code`]) are distinct,
/// except where the engine and the API name the same fact (`unknown_terminal`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FollowRefusal {
    /// Not a terminal of the asking focus (or no such terminal).
    UnknownTerminal,
    TerminalNotRunning,
    /// The focus already has a request waiting for the user.
    RequestPending,
    /// The user recently said no (or did not answer): wait before asking again.
    RequestCooldown,
    /// The focus has asked too often in the window.
    RequestLimit,
    /// The daemon has no follow engine.
    FollowUnavailable,
    /// The user allowed it and following could not start.
    NotStarted(FollowError),
}

impl FollowRefusal {
    /// The code the agent is told.
    pub fn code(self) -> &'static str {
        match self {
            Self::UnknownTerminal => "unknown_terminal",
            Self::TerminalNotRunning => "terminal_not_running",
            Self::RequestPending => "request_pending",
            Self::RequestCooldown => "request_cooldown",
            Self::RequestLimit => "request_limit",
            Self::FollowUnavailable => "follow_unavailable",
            Self::NotStarted(e) => e.code(),
        }
    }
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
    /// The cooldown and ceiling on follow requests, per focus.
    follow_limits: Arc<Mutex<FocusLimits>>,
    /// When each follower's screen reads were accepted, within [`READ_WINDOW`].
    reads: Arc<Mutex<HashMap<String, VecDeque<Instant>>>>,
    clock: Clock,
}

impl TerminalAgentApi {
    pub fn new(manager: Arc<Mutex<TerminalManager>>) -> Self {
        Self {
            manager,
            asking: Arc::default(),
            follow_limits: Arc::default(),
            reads: Arc::default(),
            clock: Arc::new(Instant::now),
        }
    }

    /// Replace the clock the follow-request cooldown and ceiling and the screen
    /// read limits read (tests move their own by hand).
    pub fn with_clock(mut self, clock: Clock) -> Self {
        self.clock = clock;
        self
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
            return FollowRequestResult::Refused(FollowRefusal::UnknownTerminal);
        };
        if info.follower.as_ref().is_some_and(|f| f.tag == request.tag) {
            return FollowRequestResult::Following;
        }
        if info.status != TerminalStatus::Running {
            return FollowRequestResult::Refused(FollowRefusal::TerminalNotRunning);
        }
        let Some(follow) = follow else {
            return FollowRequestResult::Refused(FollowRefusal::FollowUnavailable);
        };
        if !follow_ui || !lock(decisions).has_operator_for(sensitive) {
            return FollowRequestResult::NoOperator;
        }
        let Some(_asking) = Asking::start(&self.asking, &request.tag) else {
            return FollowRequestResult::Refused(FollowRefusal::RequestPending);
        };
        // Asked once, a request counts towards the ceiling whatever becomes of
        // it; the user's no starts the cooldown (see below).
        {
            let now = (self.clock)();
            let mut limits = lock(&self.follow_limits);
            match limits.check(&request.tag, now) {
                Ok(()) => limits.accepted(&request.tag, now),
                Err(LimitRefused::Cooldown) => {
                    return FollowRequestResult::Refused(FollowRefusal::RequestCooldown)
                }
                Err(LimitRefused::Limit) => {
                    return FollowRequestResult::Refused(FollowRefusal::RequestLimit)
                }
            }
        }

        let (request_id, mut rx, sheet) = lock(decisions).submit(
            request.tag.clone(),
            follow_prompt(&info, &request),
            request
                .reason
                .as_deref()
                .and_then(clean_reason)
                .map(|reason| follow_detail(&reason)),
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
            Some(info.pane_id.clone()),
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

        // The user's mind: an Allow clears the focus's cooldown; a no, a
        // dismissal or silence starts (or lengthens) it. A request whose caller
        // went away says nothing.
        if let Some(grant) = FollowGrant::from_decision(&outcome) {
            lock(&self.follow_limits).approved(&request.tag);
            return match follow.invite_granted(grant, &request.terminal_id, &request.tag) {
                Ok(()) => FollowRequestResult::Following,
                // The app that said Allow is gone: nothing follows.
                Err(FollowError::NoOperator) => FollowRequestResult::NoOperator,
                Err(e) => FollowRequestResult::Refused(FollowRefusal::NotStarted(e)),
            };
        }
        if !matches!(outcome, DecisionOutcome::Cancelled) {
            lock(&self.follow_limits).denied(&request.tag, (self.clock)());
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
    ///
    /// A follower is also held to a minimum interval between reads
    /// ([`MIN_READ_INTERVAL`]) and an hourly cap ([`MAX_READS_PER_WINDOW`]):
    /// past either the read is refused ([`ScreenReadRefused::TooSoon`] /
    /// [`ScreenReadRefused::Limit`], audited as a `refused` line with the code
    /// and nothing else). Whether the follow is paused for flood does not
    /// matter: a read of the current screen is allowed then, on purpose (it is
    /// the same redacted, capped screen the follower was invited to see).
    pub fn read_screen_if_following(
        &self,
        focus_tag: &str,
        terminal_id: &str,
    ) -> Result<ScreenRead, ScreenReadRefused> {
        let follow = self.lock().follow();
        // Anyone who does not follow the terminal gets the one answer, whatever
        // the limits say; only a follower's reads are counted.
        if !follow
            .as_ref()
            .is_some_and(|f| f.is_follower(focus_tag, terminal_id))
        {
            self.audit_refusal(Some(focus_tag), "read", READ_SCREEN_TOOL, READ_FORBIDDEN);
            return Err(ScreenReadRefused::Forbidden);
        }
        // The limits bound the redaction work and the audit lines a follower can
        // cause. They are held across the read so two calls cannot both pass.
        let mut reads = lock(&self.reads);
        if let Err(refused) = self.check_read_limits(&mut reads, focus_tag) {
            drop(reads);
            self.audit_refusal(Some(focus_tag), "read", READ_SCREEN_TOOL, refused.code());
            return Err(refused);
        }
        let read = follow
            .ok_or(ScreenReadError::NotFollowing)
            .and_then(|f| f.read_screen_as(focus_tag, terminal_id));
        match read {
            Ok(screen) => {
                self.note_read(&mut reads, focus_tag);
                Ok(screen)
            }
            // The follow ended between the check and the read.
            Err(ScreenReadError::NotFollowing) => {
                drop(reads);
                self.audit_refusal(Some(focus_tag), "read", READ_SCREEN_TOOL, READ_FORBIDDEN);
                Err(ScreenReadRefused::Forbidden)
            }
            Err(ScreenReadError::Withheld) => {
                self.note_read(&mut reads, focus_tag);
                Err(ScreenReadRefused::Withheld)
            }
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

    /// May `focus_tag` read now? Not within [`MIN_READ_INTERVAL`] of its last
    /// read, nor once it has had [`MAX_READS_PER_WINDOW`] in [`READ_WINDOW`].
    /// Forgets followers whose reads have all aged out.
    fn check_read_limits(
        &self,
        reads: &mut HashMap<String, VecDeque<Instant>>,
        focus_tag: &str,
    ) -> Result<(), ScreenReadRefused> {
        let now = (self.clock)();
        reads.retain(|_, times| {
            times
                .back()
                .is_some_and(|t| now.saturating_duration_since(*t) < READ_WINDOW)
        });
        let Some(times) = reads.get_mut(focus_tag) else {
            return Ok(());
        };
        while times
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) >= READ_WINDOW)
        {
            times.pop_front();
        }
        if times
            .back()
            .is_some_and(|t| now.saturating_duration_since(*t) < MIN_READ_INTERVAL)
        {
            return Err(ScreenReadRefused::TooSoon);
        }
        if times.len() >= MAX_READS_PER_WINDOW {
            return Err(ScreenReadRefused::Limit);
        }
        Ok(())
    }

    fn note_read(&self, reads: &mut HashMap<String, VecDeque<Instant>>, focus_tag: &str) {
        reads
            .entry(focus_tag.to_string())
            .or_default()
            .push_back((self.clock)());
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
    /// The follower read again within [`MIN_READ_INTERVAL`]. Nothing was read.
    TooSoon,
    /// The follower has used its [`MAX_READS_PER_WINDOW`] for the hour. Nothing
    /// was read.
    Limit,
}

impl ScreenReadRefused {
    /// The code the agent is told.
    pub fn code(self) -> &'static str {
        match self {
            Self::Forbidden => READ_FORBIDDEN,
            Self::Withheld => "redaction_failed",
            Self::TooSoon => READ_TOO_SOON,
            Self::Limit => READ_LIMIT,
        }
    }
}

/// The longest agent name the follow sheet repeats in its own sentences. A crafted
/// name stays too short to imitate the system's wording.
const MAX_AGENT_NAME_CHARS: usize = 40;

/// The label the follow sheet puts over the agent's reason.
pub const FOLLOW_REASON_LABEL: &str = "Agent's stated reason (unverified)";

fn short_agent_name(name: &str) -> String {
    name.chars().take(MAX_AGENT_NAME_CHARS).collect::<String>().trim_end().to_string()
}

/// The sheet's detail: the label, then the reason on its own line.
fn follow_detail(reason: &str) -> String {
    format!("{FOLLOW_REASON_LABEL}\n{reason}")
}

/// What the user is asked: who asks, for which pane, and where the output goes.
/// A remote pane's sheet leads with the environment in capitals.
fn follow_prompt(info: &TerminalInfo, request: &AgentFollowRequest) -> String {
    let clean = |s: &str| clean_reason(s).unwrap_or_default();
    let agent = request
        .agent
        .as_deref()
        .and_then(clean_reason)
        .map(|name| short_agent_name(&name))
        .unwrap_or_else(|| "An agent".to_string());
    let who = format!("{agent} in {}", clean(&request.tag));
    let pane = clean(&pane_name(info));
    let mut prompt = match (info.kind, &info.target) {
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
    };
    // Allow moves the follow: the user is told whose it was.
    if let Some(current) = &info.follower {
        prompt.push_str(&format!(
            " {} follows it now; allowing moves it to {agent}.",
            clean(&current.tag)
        ));
    }
    prompt
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
        if let Some(next) = lock(self.decisions).withdraw(self.request_id) {
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
