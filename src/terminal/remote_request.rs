//! Asking for a remote shell, and waiting for a human to say Connect.
//!
//! An agent (or the user) *requests*; only an answer from the verified app
//! (an [`OperatorCap`], minted for no one else) opens. [`RemoteRequests`] holds
//! the one pending request. [`run`] is the whole flow, shared by the agent's
//! MCP tool and the user's `remote_shell_open`:
//!
//! 1. read the vocabulary afresh and resolve the four words; an unknown one is
//!    returned at once and no one is asked;
//! 2. find the operator connections that declared `remote_shell_confirm`
//!    (none: `NoOperator`, nothing sent);
//! 3. register the request (a second one while it waits: `RequestPending`; an
//!    agent that was just denied, or asks too often: `RequestCooldown` /
//!    `RequestLimit`; the user's own request ends an agent's pending one as
//!    `Superseded`);
//! 4. send `remote_shell_confirm_request` to those connections, and only them;
//! 5. wait for the answer, or the timeout;
//! 6. on Connect, and only then, call the launcher;
//! 7. send `remote_shell_resolved` to the same connections;
//! 8. audit every step.
//!
//! No terminal, pane or process exists before step 6.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use tokio::sync::{mpsc, oneshot};
use tracing::debug;
use uuid::Uuid;

use super::audit::{AuditEvent, AuditPin, AuditRequester, RefusalChannel};
use super::ecs::{EcsTarget, EcsVocabulary, InvalidTarget};
use super::follow::manager::FollowGrant;
use super::launcher::{ConnectFailure, Placement, RemoteLauncher};
use super::{OperatorCap, TerminalManager};
use crate::ipc::protocol::{
    RemoteRequester, ServerMsg, TerminalInfo, TerminalRequester, TerminalTarget,
};

/// How long a request waits for the user when the caller does not say.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);
/// The first cooldown an agent's focus waits after a Cancel, Dismiss or
/// timeout; it doubles on each further denial, up to [`MAX_COOLDOWN`], and a
/// Connect resets it.
pub const BASE_COOLDOWN: Duration = Duration::from_secs(60);
pub const MAX_COOLDOWN: Duration = Duration::from_secs(15 * 60);
/// At most this many requests per focus in [`REQUEST_WINDOW`].
pub const MAX_REQUESTS_PER_WINDOW: usize = 3;
pub const REQUEST_WINDOW: Duration = Duration::from_secs(10 * 60);
/// A focus's denial streak is forgotten after this long without one.
const STREAK_MEMORY: Duration = Duration::from_secs(60 * 60);
/// The bounds a caller's timeout is clamped to.
pub const MIN_TIMEOUT: Duration = Duration::from_secs(10);
pub const MAX_TIMEOUT: Duration = Duration::from_secs(600);
/// The longest reason a request carries (and the audit trail keeps).
pub const MAX_REASON_CHARS: usize = 200;

/// The user's answer to the confirm sheet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Connect,
    Cancel,
    Dismiss,
}

impl Decision {
    /// `connect`, `cancel` or `dismiss`; anything else is `None`.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "connect" => Some(Self::Connect),
            "cancel" => Some(Self::Cancel),
            "dismiss" => Some(Self::Dismiss),
            _ => None,
        }
    }
}

/// How a pending request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteOutcome {
    /// The user clicked Connect (`invite_follow`: and ticked the follow box).
    Connect {
        invite_follow: bool,
    },
    Cancelled,
    Dismissed,
    TimedOut,
    /// Every connection that could show the sheet is gone.
    OperatorGone,
    /// The user's own request took the slot from an agent's.
    Superseded,
}

impl RemoteOutcome {
    /// The word `confirm_outcome` is audited with.
    pub fn audit_name(self) -> &'static str {
        match self {
            Self::Connect { .. } => "connect",
            Self::Cancelled => "cancelled",
            Self::Dismissed => "dismissed",
            Self::TimedOut => "timed_out",
            Self::OperatorGone => "operator_gone",
            Self::Superseded => "superseded",
        }
    }
}

/// Why a request was not registered. Each is content-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitRefused {
    /// A request is already waiting for the user.
    Pending,
    /// The agent's focus was denied recently and must wait.
    Cooldown,
    /// The agent's focus has asked too often in the window.
    Limit,
}

/// Where time comes from; tests inject their own.
pub type Clock = Arc<dyn Fn() -> Instant + Send + Sync>;

/// What is remembered of one agent focus's requests and denials.
#[derive(Default)]
struct FocusHistory {
    /// Consecutive denials (Cancel, Dismiss, timeout) since the last Connect.
    denials: u32,
    cooldown_until: Option<Instant>,
    last_denial: Option<Instant>,
    /// When requests were accepted, within [`REQUEST_WINDOW`].
    requests: VecDeque<Instant>,
}

impl FocusHistory {
    fn cooldown(denials: u32) -> Duration {
        let doublings = denials.saturating_sub(1).min(16);
        BASE_COOLDOWN
            .saturating_mul(1u32 << doublings)
            .min(MAX_COOLDOWN)
    }
}

/// What the registry keeps of a pending request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingRequest {
    pub request_id: String,
    pub requested_by: RemoteRequester,
    pub tag: String,
    pub target: TerminalTarget,
    pub reason: Option<String>,
}

struct Slot {
    request: PendingRequest,
    tx: oneshot::Sender<RemoteOutcome>,
}

/// The at-most-one remote shell request waiting for the user. A request ends
/// exactly once: the first of an answer, the timeout or an abandon wins and
/// the rest find nothing pending.
pub struct RemoteRequests {
    pending: Option<Slot>,
    history: HashMap<String, FocusHistory>,
    clock: Clock,
}

impl Default for RemoteRequests {
    fn default() -> Self {
        Self::with_clock(Arc::new(Instant::now))
    }
}

impl RemoteRequests {
    pub fn with_clock(clock: Clock) -> Self {
        Self {
            pending: None,
            history: HashMap::new(),
            clock,
        }
    }

    pub fn set_clock(&mut self, clock: Clock) {
        self.clock = clock;
    }

    /// Register a request. Its id, and a receiver for how it ends.
    ///
    /// Agent requests (`kind: "focus"`) are held to the focus's cooldown and
    /// request ceiling; the user's own never are, so the rules cannot lock the
    /// user out. A user request finding an agent's pending takes the slot and
    /// ends the agent's as [`RemoteOutcome::Superseded`].
    pub fn submit(
        &mut self,
        requested_by: RemoteRequester,
        tag: String,
        target: TerminalTarget,
        reason: Option<String>,
    ) -> Result<(String, oneshot::Receiver<RemoteOutcome>), SubmitRefused> {
        let now = (self.clock)();
        let agent = requested_by.kind != "user";
        self.history.retain(|_, h| {
            h.last_denial
                .is_some_and(|d| now.saturating_duration_since(d) < STREAK_MEMORY)
                || h.requests
                    .back()
                    .is_some_and(|r| now.saturating_duration_since(*r) < REQUEST_WINDOW)
        });
        if agent {
            if let Some(h) = self.history.get_mut(&tag) {
                if h.cooldown_until.is_some_and(|until| now < until) {
                    return Err(SubmitRefused::Cooldown);
                }
                while h
                    .requests
                    .front()
                    .is_some_and(|r| now.saturating_duration_since(*r) >= REQUEST_WINDOW)
                {
                    h.requests.pop_front();
                }
                if h.requests.len() >= MAX_REQUESTS_PER_WINDOW {
                    return Err(SubmitRefused::Limit);
                }
            }
        }
        if let Some(slot) = &self.pending {
            if agent || slot.request.requested_by.kind == "user" {
                return Err(SubmitRefused::Pending);
            }
            let id = slot.request.request_id.clone();
            self.finish(&id, Some(RemoteOutcome::Superseded));
        }
        if agent {
            self.history
                .entry(tag.clone())
                .or_default()
                .requests
                .push_back(now);
        }
        let request_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending = Some(Slot {
            request: PendingRequest {
                request_id: request_id.clone(),
                requested_by,
                tag,
                target,
                reason,
            },
            tx,
        });
        Ok((request_id, rx))
    }

    /// The operator's answer. `false` (and nothing changes) when `request_id`
    /// is not the pending request: a late answer is ignored. The cap is the
    /// proof the answer came from the verified app.
    pub fn answer(
        &mut self,
        _cap: &OperatorCap,
        request_id: &str,
        decision: Decision,
        invite_follow: bool,
    ) -> bool {
        let outcome = match decision {
            Decision::Connect => RemoteOutcome::Connect { invite_follow },
            Decision::Cancel => RemoteOutcome::Cancelled,
            Decision::Dismiss => RemoteOutcome::Dismissed,
        };
        self.finish(request_id, Some(outcome))
    }

    /// The wait is over. `false` when the request is no longer pending.
    pub fn timeout(&mut self, request_id: &str) -> bool {
        self.finish(request_id, Some(RemoteOutcome::TimedOut))
    }

    /// No connection can show the sheet any more: end the pending request, if
    /// there is one. `false` when nothing was pending.
    pub fn operator_gone(&mut self) -> bool {
        let Some(id) = self.pending.as_ref().map(|s| s.request.request_id.clone()) else {
            return false;
        };
        self.finish(&id, Some(RemoteOutcome::OperatorGone))
    }

    /// The requester went away: forget the request, tell no one.
    pub fn abandon(&mut self, request_id: &str) -> bool {
        self.finish(request_id, None)
    }

    pub fn pending(&self) -> Option<&PendingRequest> {
        self.pending.as_ref().map(|s| &s.request)
    }

    /// A denial by the user starts (or lengthens) the agent focus's cooldown;
    /// a Connect clears it. Anything else says nothing about the user's mind.
    fn note_outcome(&mut self, request: &PendingRequest, outcome: RemoteOutcome) {
        if request.requested_by.kind == "user" {
            return;
        }
        let now = (self.clock)();
        let history = self.history.entry(request.tag.clone()).or_default();
        match outcome {
            RemoteOutcome::Connect { .. } => {
                history.denials = 0;
                history.cooldown_until = None;
                history.last_denial = None;
            }
            RemoteOutcome::Cancelled | RemoteOutcome::Dismissed | RemoteOutcome::TimedOut => {
                history.denials = history.denials.saturating_add(1);
                history.cooldown_until = Some(now + FocusHistory::cooldown(history.denials));
                history.last_denial = Some(now);
            }
            RemoteOutcome::OperatorGone | RemoteOutcome::Superseded => {}
        }
    }

    fn finish(&mut self, request_id: &str, outcome: Option<RemoteOutcome>) -> bool {
        if self
            .pending
            .as_ref()
            .is_none_or(|s| s.request.request_id != request_id)
        {
            return false;
        }
        let slot = self.pending.take().expect("checked above");
        if let Some(outcome) = outcome {
            self.note_outcome(&slot.request, outcome);
            // The waiter may have gone: that is its own end of the request.
            let _ = slot.tx.send(outcome);
        }
        true
    }
}

// ── the flow ─────────────────────────────────────────────────────────────────

/// One request for a remote shell.
#[derive(Debug, Clone)]
pub struct RemoteRequest {
    /// `kind: "user"`, or `kind: "focus"` with the agent's focus `tag` and name.
    pub requested_by: RemoteRequester,
    /// The focus whose pane tree the shell goes in.
    pub tag: String,
    pub project: String,
    pub environment: String,
    pub service: String,
    pub shell_type: String,
    pub reason: Option<String>,
    /// How long to wait for the user (clamped to [`MIN_TIMEOUT`]..=[`MAX_TIMEOUT`]).
    pub timeout: Duration,
    pub placement: Placement,
}

/// How a request ended.
#[derive(Debug)]
pub enum RemoteResult {
    /// The user connected and the shell is open.
    Connected(Box<TerminalInfo>),
    /// There is no usable vocabulary (`config.json` missing or unreadable).
    NotConfigured(String),
    /// A word was outside the vocabulary. No one was asked.
    InvalidTarget(InvalidTarget),
    /// No verified app that can show the sheet is connected. Nothing was sent.
    NoOperator,
    /// A request is already waiting for the user.
    RequestPending,
    /// The agent's focus was denied recently and must wait. Nothing was sent.
    RequestCooldown,
    /// The agent's focus has asked too often. Nothing was sent.
    RequestLimit,
    /// The user's own request took the slot while this one waited.
    Superseded,
    Cancelled,
    Dismissed,
    TimedOut,
    /// The user said Connect and the launcher failed. No pane exists.
    ConnectFailed(ConnectFailure),
}

/// A registered request: its id, the receiver for how it ends and the
/// connections that were sent the sheet.
type Asked = (
    String,
    oneshot::Receiver<RemoteOutcome>,
    Vec<mpsc::UnboundedSender<ServerMsg>>,
);

/// Run one request to its end (see the module docs). Holds no lock while it
/// waits.
pub(crate) async fn run(
    manager: &Arc<Mutex<TerminalManager>>,
    request: RemoteRequest,
) -> RemoteResult {
    let (paths, launcher) = {
        let m = lock(manager);
        (m.ecs_paths().clone(), m.remote_launcher())
    };
    // 1. The vocabulary is read now, never cached.
    let vocabulary = match EcsVocabulary::load(&paths) {
        Ok(v) => v,
        Err(e) => return RemoteResult::NotConfigured(e.problem),
    };
    let target = match vocabulary.resolve(
        &request.project,
        &request.environment,
        &request.service,
        &request.shell_type,
    ) {
        Ok(t) => t,
        Err(invalid) if invalid.unsafe_config_code().is_some() => {
            return RemoteResult::NotConfigured(invalid.detail())
        }
        Err(invalid) => return RemoteResult::InvalidTarget(invalid),
    };
    let wire_target = target.terminal_target();
    let timeout = request.timeout.clamp(MIN_TIMEOUT, MAX_TIMEOUT);

    // 2-4. Who can be asked, the registration and the sheet.
    let (request_id, mut rx, conns) = match ask_operators(manager, &request, &target, timeout) {
        Ok(asked) => asked,
        Err(refused) => return refused,
    };

    // If the caller goes away from here on, the sheet is closed and the
    // request forgotten.
    let mut guard = Abandon {
        manager,
        request_id: &request_id,
        conns: &conns,
        request: &request,
        target: &wire_target,
        finished: false,
        outcome_audited: false,
        connect_started: false,
    };

    // 5. The answer, or the timeout.
    let outcome = wait_for_outcome(manager, &request_id, &mut rx, timeout).await;
    audit_outcome(manager, &request, &wire_target, outcome);
    guard.outcome_audited = true;

    let (result, resolved) = match outcome {
        RemoteOutcome::Cancelled => (RemoteResult::Cancelled, resolved(&request_id, "cancelled")),
        RemoteOutcome::Dismissed => (RemoteResult::Dismissed, resolved(&request_id, "dismissed")),
        RemoteOutcome::TimedOut => (RemoteResult::TimedOut, resolved(&request_id, "timed_out")),
        RemoteOutcome::Superseded => (
            RemoteResult::Superseded,
            resolved(&request_id, "superseded"),
        ),
        RemoteOutcome::OperatorGone => (
            RemoteResult::NoOperator,
            ServerMsg::RemoteShellResolved {
                request_id: request_id.clone(),
                outcome: "cancelled".into(),
                reason: Some("operator_gone".into()),
                remedy: None,
                detail: None,
            },
        ),
        // 6. The only place a remote shell is started: after Connect.
        RemoteOutcome::Connect { .. } => {
            connect(&mut guard, launcher.as_ref(), &target, &request_id).await
        }
    };

    // 7. The sheet closes.
    for conn in &conns {
        let _ = conn.send(resolved.clone());
    }
    guard.finished = true;

    // 8. The shell is running and the user ticked "let the agent follow it":
    //    the agent that asked follows it, from the start.
    if let (RemoteResult::Connected(info), Some(grant)) =
        (&result, FollowGrant::from_remote_answer(&outcome))
    {
        invite_requester(manager, &request, info, grant);
    }
    result
}

/// Step 8. The user's own request ignores the follow box (nobody asked for an
/// agent to follow it). A follower that is no longer there, or no app left to
/// show who follows, leaves the shell as it is.
fn invite_requester(
    manager: &Arc<Mutex<TerminalManager>>,
    request: &RemoteRequest,
    info: &TerminalInfo,
    grant: FollowGrant,
) {
    if request.requested_by.kind != "focus" {
        return;
    }
    let Some(follower) = request.requested_by.tag.as_deref() else {
        return;
    };
    // Not under the manager's lock: following takes it.
    let follow = lock(manager).follow();
    let Some(follow) = follow else {
        return;
    };
    // Refused (`no_operator`) when no app that can show who follows is left.
    if let Err(e) = follow.invite_granted(grant, &info.terminal_id, follower) {
        debug!(
            code = e.code(),
            "follow box ticked but following did not start"
        );
    }
}

/// Steps 2-4: find the operators that can show the sheet, register the
/// request and send them the sheet, under one lock. Its id, the receiver for
/// how it ends and the connections asked; or the refusal (`NoOperator`,
/// `RequestPending`), audited, with nothing sent.
fn ask_operators(
    manager: &Arc<Mutex<TerminalManager>>,
    request: &RemoteRequest,
    target: &EcsTarget,
    timeout: Duration,
) -> Result<Asked, RemoteResult> {
    let wire_target = &target.terminal_target();
    let reason = request.reason.as_deref().and_then(clean_reason);

    let mut m = lock(manager);
    let conns = m.remote_confirm_conns();
    if conns.is_empty() {
        m.record_unanswered(request, wire_target, reason.as_deref(), "no_operator");
        return Err(RemoteResult::NoOperator);
    }
    let submitted = m.remote_requests_mut().submit(
        request.requested_by.clone(),
        request.tag.clone(),
        wire_target.clone(),
        reason.clone(),
    );
    let (request_id, rx) = match submitted {
        Ok(ok) => ok,
        Err(refused) => {
            let (outcome, result) = match refused {
                SubmitRefused::Pending => ("request_pending", RemoteResult::RequestPending),
                SubmitRefused::Cooldown => ("request_cooldown", RemoteResult::RequestCooldown),
                SubmitRefused::Limit => ("request_limit", RemoteResult::RequestLimit),
            };
            m.record_unanswered(request, wire_target, reason.as_deref(), outcome);
            return Err(result);
        }
    };
    m.record_remote_requested(request, wire_target, reason.as_deref());
    let confirm = ServerMsg::RemoteShellConfirmRequest {
        request_id: request_id.clone(),
        tag: Some(request.tag.clone()),
        target: wire_target.clone(),
        requested_by: RemoteRequester {
            // Not agent-typed, but the sheet shows it: the same cleaning as the reason.
            agent: request.requested_by.agent.as_deref().and_then(clean_reason),
            ..request.requested_by.clone()
        },
        reason,
        expires_at: (Utc::now() + timeout).to_rfc3339_opts(SecondsFormat::Secs, true),
        shell_command: Some(target.shell_command.clone()),
        profile: target.profile.clone(),
        cluster: Some(target.cluster.clone()),
    };
    for conn in &conns {
        let _ = conn.send(confirm.clone());
    }
    Ok((request_id, rx, conns))
}

/// Step 5: the user's answer, or the timeout.
async fn wait_for_outcome(
    manager: &Arc<Mutex<TerminalManager>>,
    request_id: &str,
    rx: &mut oneshot::Receiver<RemoteOutcome>,
    timeout: Duration,
) -> RemoteOutcome {
    match tokio::time::timeout(timeout, &mut *rx).await {
        Ok(Ok(outcome)) => outcome,
        // The registry dropped the sender without an outcome: nothing to wait for.
        Ok(Err(_)) => RemoteOutcome::Cancelled,
        Err(_) => {
            lock(manager).remote_requests_mut().timeout(request_id);
            // An answer that raced the timeout was already sent: take it.
            rx.await.unwrap_or(RemoteOutcome::TimedOut)
        }
    }
}

fn audit_outcome(
    manager: &Arc<Mutex<TerminalManager>>,
    request: &RemoteRequest,
    wire_target: &TerminalTarget,
    outcome: RemoteOutcome,
) {
    let m = lock(manager);
    m.record(AuditEvent::ConfirmOutcome {
        tag: m.audit_tag(&request.tag),
        target: wire_target.clone(),
        outcome: outcome.audit_name().into(),
        invite_follow: matches!(
            outcome,
            RemoteOutcome::Connect {
                invite_follow: true
            }
        ),
    });
}

/// Step 6, after Connect: call the launcher and audit how it went. The result,
/// and the frame that closes the sheet.
async fn connect(
    guard: &mut Abandon<'_>,
    launcher: &dyn RemoteLauncher,
    target: &EcsTarget,
    request_id: &str,
) -> (RemoteResult, ServerMsg) {
    let (manager, request, wire_target) = (guard.manager, guard.request, guard.target);
    {
        let m = lock(manager);
        m.record(AuditEvent::ConnectStarted {
            tag: m.audit_tag(&request.tag),
            target: wire_target.clone(),
            pin: pin_of(target),
        });
    }
    guard.connect_started = true;
    let requester = TerminalRequester {
        kind: request.requested_by.kind.clone(),
        tag: request.requested_by.tag.clone(),
    };
    let connected = launcher
        .connect(target, &request.tag, &request.placement, &requester)
        .await;
    let m = lock(manager);
    match connected {
        Ok(info) => {
            m.record(AuditEvent::Connected {
                terminal_id: info.terminal_id.clone(),
                pane_id: info.pane_id.clone(),
                tag: m.audit_tag(&info.tag),
                kind: info.kind,
                target: wire_target.clone(),
                pin: pin_of(target),
            });
            (
                RemoteResult::Connected(Box::new(info)),
                resolved(request_id, "connected"),
            )
        }
        Err(failure) => {
            m.record(AuditEvent::ConnectFailed {
                tag: m.audit_tag(&request.tag),
                target: wire_target.clone(),
                reason_code: failure.reason_code.clone(),
            });
            let msg = ServerMsg::RemoteShellResolved {
                request_id: request_id.to_string(),
                outcome: "connect_failed".into(),
                reason: Some(failure.reason_code.clone()),
                remedy: failure.remedy.clone(),
                detail: failure.detail.clone(),
            };
            (RemoteResult::ConnectFailed(failure), msg)
        }
    }
}

/// The reason as the sheet and the audit trail show it: control characters
/// (line breaks included) become spaces, characters that reorder or hide text
/// (bidi overrides and isolates, zero-width characters, the byte-order mark)
/// are dropped, then it is trimmed and cut to [`MAX_REASON_CHARS`]. `None`
/// when nothing is left.
pub(crate) fn clean_reason(reason: &str) -> Option<String> {
    let cleaned: String = reason
        .chars()
        .filter_map(|c| match c {
            c if c.is_control() => Some(' '),
            '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2028}'..='\u{2029}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}' => None,
            c => Some(c),
        })
        .take(MAX_REASON_CHARS)
        .collect();
    let cleaned = cleaned.trim();
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

fn resolved(request_id: &str, outcome: &str) -> ServerMsg {
    ServerMsg::RemoteShellResolved {
        request_id: request_id.to_string(),
        outcome: outcome.to_string(),
        reason: None,
        remedy: None,
        detail: None,
    }
}

/// What the connect is audited against: the digests the request was pinned to.
fn pin_of(target: &EcsTarget) -> AuditPin {
    AuditPin {
        config_sha256: target.pin.config_sha256.clone(),
        local_sha256: target.pin.local_sha256.clone(),
        argv_sha256: target.pin.argv_sha256.clone(),
    }
}

fn lock(manager: &Arc<Mutex<TerminalManager>>) -> MutexGuard<'_, TerminalManager> {
    manager.lock().unwrap_or_else(|e| e.into_inner())
}

/// Dropped before [`run`] finished (the agent's call was cancelled): forget the
/// request, close the sheet and say so in the audit trail.
struct Abandon<'a> {
    manager: &'a Arc<Mutex<TerminalManager>>,
    request_id: &'a str,
    conns: &'a [mpsc::UnboundedSender<ServerMsg>],
    request: &'a RemoteRequest,
    target: &'a TerminalTarget,
    finished: bool,
    outcome_audited: bool,
    connect_started: bool,
}

impl Drop for Abandon<'_> {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        let mut m = lock(self.manager);
        m.remote_requests_mut().abandon(self.request_id);
        if !self.outcome_audited {
            m.record(AuditEvent::ConfirmOutcome {
                tag: m.audit_tag(&self.request.tag),
                target: self.target.clone(),
                outcome: "abandoned".into(),
                invite_follow: false,
            });
        }
        if self.connect_started {
            m.record(AuditEvent::ConnectFailed {
                tag: m.audit_tag(&self.request.tag),
                target: self.target.clone(),
                reason_code: "abandoned".into(),
            });
        }
        let msg = ServerMsg::RemoteShellResolved {
            request_id: self.request_id.to_string(),
            outcome: "cancelled".into(),
            reason: Some("requester_gone".into()),
            remedy: None,
            detail: None,
        };
        for conn in self.conns {
            let _ = conn.send(msg.clone());
        }
    }
}

impl TerminalManager {
    /// `remote_requested` for a request that got past the vocabulary.
    fn record_remote_requested(
        &self,
        request: &RemoteRequest,
        target: &TerminalTarget,
        reason: Option<&str>,
    ) {
        self.record(AuditEvent::RemoteRequested {
            tag: self.audit_tag(&request.tag),
            requested_by: AuditRequester {
                kind: request.requested_by.kind.clone(),
                tag: request
                    .requested_by
                    .tag
                    .as_deref()
                    .map(|t| self.audit_tag(t)),
            },
            target: target.clone(),
            reason: reason.map(str::to_owned),
        });
    }

    /// `remote_requested` and `confirm_outcome` for a request that ended
    /// without a sheet (`no_operator`, `request_pending`). Held to the refusal
    /// budget of the channel it came in on, so a loop of such calls cannot
    /// flood the trail.
    fn record_unanswered(
        &self,
        request: &RemoteRequest,
        target: &TerminalTarget,
        reason: Option<&str>,
        outcome: &str,
    ) {
        let channel = if request.requested_by.kind == "user" {
            RefusalChannel::Ipc
        } else {
            RefusalChannel::Mcp
        };
        if !self.take_refusal_budget(channel) {
            return;
        }
        self.record_remote_requested(request, target, reason);
        self.record(AuditEvent::ConfirmOutcome {
            tag: self.audit_tag(&request.tag),
            target: target.clone(),
            outcome: outcome.to_string(),
            invite_follow: false,
        });
    }
}

/// The `remote_shell_targets` frame for the vocabulary the files hold now.
pub fn remote_targets_msg(paths: &super::ecs::EcsPaths) -> ServerMsg {
    match EcsVocabulary::load(paths) {
        Ok(vocabulary) => ServerMsg::RemoteShellTargets {
            configured: true,
            problem: None,
            projects: vocabulary.projects(),
            shell_types: vocabulary.shell_types(),
        },
        Err(e) => ServerMsg::RemoteShellTargets {
            configured: false,
            problem: Some(e.problem),
            projects: Vec::new(),
            shell_types: Vec::new(),
        },
    }
}

#[cfg(test)]
mod tests {
    use tokio::sync::oneshot::error::TryRecvError;

    use super::*;
    use crate::terminal::access::tests::cap;
    use crate::terminal::ecs::EcsPaths;

    fn requester() -> RemoteRequester {
        RemoteRequester {
            kind: "focus".into(),
            tag: Some("cody-1".into()),
            agent: Some("cody".into()),
        }
    }

    fn target() -> TerminalTarget {
        TerminalTarget {
            project: "admin-portal".into(),
            environment: "production".into(),
            service: "scheduler".into(),
            shell_type: "shell".into(),
        }
    }

    fn submit(
        requests: &mut RemoteRequests,
    ) -> Result<(String, oneshot::Receiver<RemoteOutcome>), SubmitRefused> {
        requests.submit(requester(), "cody-1".into(), target(), Some("why".into()))
    }

    // ── one request at a time ────────────────────────────────────────────────

    #[test]
    fn a_second_request_while_one_is_pending_is_refused_and_the_first_is_untouched() {
        let mut requests = RemoteRequests::default();
        let (first_id, mut first_rx) = submit(&mut requests).expect("the first is accepted");

        let second = submit(&mut requests);

        assert!(matches!(second, Err(SubmitRefused::Pending)));
        let pending = requests.pending().expect("the first is still pending");
        assert_eq!(pending.request_id, first_id);
        assert_eq!(pending.tag, "cody-1");
        assert_eq!(pending.target, target());
        assert_eq!(pending.reason.as_deref(), Some("why"));
        assert_eq!(pending.requested_by, requester());
        assert!(matches!(first_rx.try_recv(), Err(TryRecvError::Empty)));
        // And it can still be answered.
        assert!(requests.answer(&cap(), &first_id, Decision::Connect, false));
    }

    #[test]
    fn once_a_request_has_ended_a_new_one_is_accepted_with_a_new_id() {
        let mut requests = RemoteRequests::default();
        let (first_id, _rx) = submit(&mut requests).unwrap();
        assert!(requests.answer(&cap(), &first_id, Decision::Connect, false));

        let (second_id, _rx2) = submit(&mut requests).expect("nothing is pending any more");

        assert_ne!(first_id, second_id);
        assert_eq!(requests.pending().unwrap().request_id, second_id);
    }

    #[test]
    fn nothing_is_pending_at_first() {
        assert!(RemoteRequests::default().pending().is_none());
    }

    // ── answers ──────────────────────────────────────────────────────────────

    #[test]
    fn each_decision_ends_the_request_with_its_outcome() {
        for (decision, follow, want) in [
            (
                Decision::Connect,
                false,
                RemoteOutcome::Connect {
                    invite_follow: false,
                },
            ),
            (
                Decision::Connect,
                true,
                RemoteOutcome::Connect {
                    invite_follow: true,
                },
            ),
            (Decision::Cancel, false, RemoteOutcome::Cancelled),
            (Decision::Dismiss, false, RemoteOutcome::Dismissed),
        ] {
            let mut requests = RemoteRequests::default();
            let (id, mut rx) = submit(&mut requests).unwrap();

            assert!(
                requests.answer(&cap(), &id, decision, follow),
                "{decision:?}"
            );

            assert_eq!(rx.try_recv(), Ok(want), "{decision:?}");
            assert!(requests.pending().is_none(), "{decision:?}");
        }
    }

    #[test]
    fn a_second_answer_to_the_same_request_is_ignored() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();
        assert!(requests.answer(&cap(), &id, Decision::Cancel, false));

        let late = requests.answer(&cap(), &id, Decision::Connect, true);

        assert!(!late, "a late answer reports that it changed nothing");
        assert_eq!(rx.try_recv(), Ok(RemoteOutcome::Cancelled));
    }

    #[test]
    fn an_answer_for_another_request_id_is_ignored_and_the_pending_one_stays_pending() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();

        for wrong in ["", "no-such-request", "0", &format!("{id}x")] {
            assert!(
                !requests.answer(&cap(), wrong, Decision::Connect, false),
                "{wrong:?}"
            );
        }

        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(requests.pending().unwrap().request_id, id);
        assert!(requests.answer(&cap(), &id, Decision::Connect, false));
    }

    #[test]
    fn an_answer_with_nothing_pending_is_ignored() {
        let mut requests = RemoteRequests::default();

        assert!(!requests.answer(&cap(), "anything", Decision::Connect, false));
        assert!(requests.pending().is_none());
    }

    // ── timeout and abandon ──────────────────────────────────────────────────

    #[test]
    fn the_timeout_ends_the_request_as_timed_out() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();

        assert!(requests.timeout(&id));

        assert_eq!(rx.try_recv(), Ok(RemoteOutcome::TimedOut));
        assert!(requests.pending().is_none());
        assert!(!requests.timeout(&id), "it ends once");
    }

    #[test]
    fn an_answer_that_arrives_after_the_timeout_is_ignored() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();
        requests.timeout(&id);

        let late = requests.answer(&cap(), &id, Decision::Connect, false);

        assert!(!late);
        assert_eq!(rx.try_recv(), Ok(RemoteOutcome::TimedOut));
    }

    #[test]
    fn a_timeout_after_an_answer_changes_nothing() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();
        requests.answer(&cap(), &id, Decision::Dismiss, false);

        assert!(!requests.timeout(&id));

        assert_eq!(rx.try_recv(), Ok(RemoteOutcome::Dismissed));
    }

    #[test]
    fn a_timeout_for_another_request_id_changes_nothing() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();

        assert!(!requests.timeout("some-other-request"));

        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(requests.pending().unwrap().request_id, id);
    }

    #[test]
    fn abandoning_forgets_the_request_without_an_outcome_and_frees_the_slot() {
        let mut requests = RemoteRequests::default();
        let (id, mut rx) = submit(&mut requests).unwrap();

        assert!(requests.abandon(&id));

        assert!(matches!(rx.try_recv(), Err(TryRecvError::Closed)));
        assert!(requests.pending().is_none());
        assert!(!requests.abandon(&id), "it ends once");
        assert!(!requests.answer(&cap(), &id, Decision::Connect, false));
        assert!(submit(&mut requests).is_ok());
    }

    #[test]
    fn abandoning_another_request_id_changes_nothing() {
        let mut requests = RemoteRequests::default();
        let (id, _rx) = submit(&mut requests).unwrap();

        assert!(!requests.abandon("some-other-request"));

        assert_eq!(requests.pending().unwrap().request_id, id);
    }

    // ── cooldown, ceiling and preemption (injected clock) ───────────────────

    const MS: Duration = Duration::from_millis(1);
    const MIN: Duration = Duration::from_secs(60);

    /// A clock the test moves by hand.
    struct TestClock {
        offset: Arc<Mutex<Duration>>,
    }

    impl TestClock {
        fn new() -> (Self, RemoteRequests) {
            let base = Instant::now();
            let offset = Arc::new(Mutex::new(Duration::ZERO));
            let reader = Arc::clone(&offset);
            let clock: Clock = Arc::new(move || base + *reader.lock().unwrap());
            (Self { offset }, RemoteRequests::with_clock(clock))
        }

        fn advance(&self, by: Duration) {
            *self.offset.lock().unwrap() += by;
        }

        fn elapsed(&self) -> Duration {
            *self.offset.lock().unwrap()
        }
    }

    fn agent(tag: &str) -> RemoteRequester {
        RemoteRequester {
            kind: "focus".into(),
            tag: Some(tag.into()),
            agent: Some("cody".into()),
        }
    }

    fn user() -> RemoteRequester {
        RemoteRequester {
            kind: "user".into(),
            tag: None,
            agent: None,
        }
    }

    type Submitted = Result<(String, oneshot::Receiver<RemoteOutcome>), SubmitRefused>;

    fn ask(requests: &mut RemoteRequests, who: RemoteRequester, tag: &str) -> Submitted {
        requests.submit(who, tag.into(), target(), None)
    }

    fn ask_as_agent(requests: &mut RemoteRequests, tag: &str) -> Submitted {
        ask(requests, agent(tag), tag)
    }

    fn ask_as_user(requests: &mut RemoteRequests, tag: &str) -> Submitted {
        ask(requests, user(), tag)
    }

    fn refusal(submitted: Submitted) -> Option<SubmitRefused> {
        submitted.err()
    }

    /// The agent asks and the user answers `decision`.
    fn agent_asks_and_user_answers(requests: &mut RemoteRequests, tag: &str, decision: Decision) {
        let (id, _rx) = ask_as_agent(requests, tag).expect("the request is accepted");
        assert!(requests.answer(&cap(), &id, decision, false));
    }

    /// The agent asks and the wait times out.
    fn agent_asks_and_times_out(requests: &mut RemoteRequests, tag: &str) {
        let (id, _rx) = ask_as_agent(requests, tag).expect("the request is accepted");
        assert!(requests.timeout(&id));
    }

    /// `n` consecutive denials of `tag`, each far enough after the last that
    /// neither its cooldown nor the request ceiling is in play. The cooldown
    /// that the last one started runs from now.
    fn deny_n_times(clock: &TestClock, requests: &mut RemoteRequests, tag: &str, n: u32) {
        for i in 0..n {
            if i > 0 {
                // Past the longest cooldown and the whole request window.
                clock.advance(MAX_COOLDOWN + REQUEST_WINDOW);
            }
            agent_asks_and_user_answers(requests, tag, Decision::Cancel);
        }
    }

    #[test]
    fn a_denied_agent_focus_waits_a_minute_and_not_one_moment_longer() {
        let (clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);

        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown),
            "right after the denial"
        );
        clock.advance(BASE_COOLDOWN - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown),
            "a millisecond before the minute is up"
        );
        assert!(requests.pending().is_none(), "a refusal registers nothing");

        clock.advance(MS);
        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "once the minute is up"
        );
    }

    #[test]
    fn cancel_dismiss_and_timeout_each_start_the_cooldown() {
        for how in ["cancel", "dismiss", "timeout"] {
            let (clock, mut requests) = TestClock::new();
            match how {
                "cancel" => agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel),
                "dismiss" => {
                    agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Dismiss)
                }
                _ => agent_asks_and_times_out(&mut requests, "cody-1"),
            }

            assert_eq!(
                refusal(ask_as_agent(&mut requests, "cody-1")),
                Some(SubmitRefused::Cooldown),
                "{how}"
            );
            clock.advance(BASE_COOLDOWN);
            assert!(ask_as_agent(&mut requests, "cody-1").is_ok(), "{how}");
        }
    }

    #[test]
    fn each_consecutive_denial_doubles_the_cooldown_up_to_fifteen_minutes() {
        let wanted = [60u64, 120, 240, 480, 900, 900, 900];
        for (i, secs) in wanted.into_iter().enumerate() {
            let (clock, mut requests) = TestClock::new();
            deny_n_times(&clock, &mut requests, "cody-1", i as u32 + 1);
            let cooldown = Duration::from_secs(secs);

            clock.advance(cooldown - MS);
            assert_eq!(
                refusal(ask_as_agent(&mut requests, "cody-1")),
                Some(SubmitRefused::Cooldown),
                "denial {} must cost {secs}s (still cooling a millisecond early)",
                i + 1
            );
            clock.advance(MS);
            assert!(
                ask_as_agent(&mut requests, "cody-1").is_ok(),
                "denial {} must cost no more than {secs}s",
                i + 1
            );
        }
    }

    #[test]
    fn a_connect_resets_the_streak_so_the_next_denial_costs_a_minute_again() {
        let (clock, mut requests) = TestClock::new();
        deny_n_times(&clock, &mut requests, "cody-1", 3);
        clock.advance(MAX_COOLDOWN + REQUEST_WINDOW);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);

        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "a Connect leaves no cooldown behind"
        );
    }

    #[test]
    fn after_a_connect_the_next_denial_starts_from_a_minute_not_from_where_it_was() {
        let (clock, mut requests) = TestClock::new();
        deny_n_times(&clock, &mut requests, "cody-1", 3);
        clock.advance(MAX_COOLDOWN + REQUEST_WINDOW);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
        clock.advance(REQUEST_WINDOW);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);

        clock.advance(BASE_COOLDOWN - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown)
        );
        clock.advance(MS);
        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "it would still be cooling if the streak had survived the Connect"
        );
    }

    #[test]
    fn the_cooldown_belongs_to_the_focus_that_was_denied() {
        let (clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);

        assert!(
            ask_as_agent(&mut requests, "cody-2").is_ok(),
            "another focus is not held up by cody-1's denial"
        );
        let id = requests.pending().unwrap().request_id.clone();
        assert!(requests.answer(&cap(), &id, Decision::Connect, false));
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown),
            "and cody-2's Connect does not clear cody-1's cooldown"
        );
        clock.advance(BASE_COOLDOWN);
        assert!(ask_as_agent(&mut requests, "cody-1").is_ok());
    }

    #[test]
    fn two_focuses_keep_separate_streaks() {
        let (clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        clock.advance(BASE_COOLDOWN);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        // cody-1 has two denials (120 s). cody-2 has one (60 s).
        agent_asks_and_user_answers(&mut requests, "cody-2", Decision::Cancel);

        clock.advance(BASE_COOLDOWN);
        assert!(ask_as_agent(&mut requests, "cody-2").is_ok(), "60 s each");
        let id = requests.pending().unwrap().request_id.clone();
        requests.abandon(&id);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown),
            "cody-1's second denial costs it 120 s"
        );
    }

    #[test]
    fn the_users_own_requests_are_never_held_by_a_cooldown_or_the_ceiling() {
        let (_clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown)
        );

        // The user, on the same focus, mid-cooldown, as often as they like.
        for _ in 0..(MAX_REQUESTS_PER_WINDOW * 2) {
            let (id, _rx) = ask_as_user(&mut requests, "cody-1").expect("the user is never held");
            assert!(requests.answer(&cap(), &id, Decision::Cancel, false));
        }
    }

    #[test]
    fn the_users_denials_do_not_start_a_cooldown_for_the_agent() {
        let (_clock, mut requests) = TestClock::new();
        for decision in [Decision::Cancel, Decision::Dismiss] {
            let (id, _rx) = ask_as_user(&mut requests, "cody-1").unwrap();
            assert!(requests.answer(&cap(), &id, decision, false));
        }
        let (id, _rx) = ask_as_user(&mut requests, "cody-1").unwrap();
        assert!(requests.timeout(&id));

        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "the user said no to their own request, not to the agent's"
        );
    }

    #[test]
    fn the_users_requests_do_not_count_toward_the_agents_ceiling() {
        let (_clock, mut requests) = TestClock::new();
        for _ in 0..MAX_REQUESTS_PER_WINDOW {
            let (id, _rx) = ask_as_user(&mut requests, "cody-1").unwrap();
            assert!(requests.answer(&cap(), &id, Decision::Connect, false));
        }

        for _ in 0..MAX_REQUESTS_PER_WINDOW {
            agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
        }
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Limit),
            "only the agent's own three count"
        );
    }

    #[test]
    fn a_users_connect_does_not_clear_the_agents_cooldown() {
        let (_clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        let (id, _rx) = ask_as_user(&mut requests, "cody-1").unwrap();
        assert!(requests.answer(&cap(), &id, Decision::Connect, false));

        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown)
        );
    }

    #[test]
    fn a_focus_may_make_three_requests_in_ten_minutes_and_the_fourth_is_over_the_limit() {
        let (_clock, mut requests) = TestClock::new();
        for n in 1..=MAX_REQUESTS_PER_WINDOW {
            let (id, _rx) =
                ask_as_agent(&mut requests, "cody-1").unwrap_or_else(|e| panic!("#{n}: {e:?}"));
            assert!(requests.answer(&cap(), &id, Decision::Connect, false));
        }

        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Limit)
        );
        assert!(requests.pending().is_none(), "a refusal registers nothing");
        assert!(
            ask_as_agent(&mut requests, "cody-2").is_ok(),
            "the ceiling is per focus"
        );
    }

    #[test]
    fn the_ceiling_window_slides_one_request_at_a_time() {
        let (clock, mut requests) = TestClock::new();
        // Requests at 0, 1 and 2 minutes, each connected.
        for _ in 0..MAX_REQUESTS_PER_WINDOW {
            agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
            clock.advance(MIN);
        }
        // Now at 3 minutes.
        clock.advance(REQUEST_WINDOW - MIN * 3 - MS);
        assert_eq!(clock.elapsed(), REQUEST_WINDOW - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Limit),
            "a millisecond before the first request is ten minutes old"
        );

        clock.advance(MS);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Limit),
            "the first has aged out; the one just made takes its place"
        );

        clock.advance(MIN);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Limit),
            "one at a time: the second aged out, the one just made took its place"
        );
    }

    #[test]
    fn refused_attempts_do_not_count_toward_the_ceiling() {
        let (clock, mut requests) = TestClock::new();
        // One request waits since minute 0; at minute 2 the agent is told
        // Pending over and over.
        let (id, _rx) = ask_as_agent(&mut requests, "cody-1").unwrap();
        clock.advance(2 * MIN);
        for _ in 0..10 {
            assert_eq!(
                refusal(ask_as_agent(&mut requests, "cody-1")),
                Some(SubmitRefused::Pending)
            );
        }
        assert!(requests.answer(&cap(), &id, Decision::Connect, false));

        // Two more are accepted at minute 2: only accepted requests were counted.
        for _ in 2..=MAX_REQUESTS_PER_WINDOW {
            agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Connect);
        }
        // At minute 5 the fourth is refused, ten times.
        clock.advance(3 * MIN);
        for _ in 0..10 {
            assert_eq!(
                refusal(ask_as_agent(&mut requests, "cody-1")),
                Some(SubmitRefused::Limit)
            );
        }
        // At minute 10 the first has aged out, and nothing else is held against the focus.
        clock.advance(5 * MIN);
        assert!(ask_as_agent(&mut requests, "cody-1").is_ok());
    }

    #[test]
    fn a_users_request_takes_the_slot_from_an_agents_and_the_agent_hears_superseded() {
        let (_clock, mut requests) = TestClock::new();
        let (agent_id, mut agent_rx) = ask_as_agent(&mut requests, "cody-1").unwrap();

        let (user_id, mut user_rx) = ask_as_user(&mut requests, "cody-1")
            .expect("the user's request is accepted while an agent's waits");

        assert_eq!(agent_rx.try_recv(), Ok(RemoteOutcome::Superseded));
        let pending = requests
            .pending()
            .expect("the user's request holds the slot");
        assert_eq!(pending.request_id, user_id);
        assert_eq!(pending.requested_by.kind, "user");
        assert!(matches!(user_rx.try_recv(), Err(TryRecvError::Empty)));
        assert!(
            !requests.answer(&cap(), &agent_id, Decision::Connect, false),
            "the superseded request can no longer be answered"
        );
        assert!(requests.answer(&cap(), &user_id, Decision::Connect, true));
        assert_eq!(
            user_rx.try_recv(),
            Ok(RemoteOutcome::Connect {
                invite_follow: true
            })
        );
    }

    #[test]
    fn being_superseded_is_not_a_denial() {
        let (_clock, mut requests) = TestClock::new();
        let (_agent_id, mut agent_rx) = ask_as_agent(&mut requests, "cody-1").unwrap();
        let (user_id, _user_rx) = ask_as_user(&mut requests, "cody-1").unwrap();
        assert_eq!(agent_rx.try_recv(), Ok(RemoteOutcome::Superseded));
        assert!(requests.answer(&cap(), &user_id, Decision::Cancel, false));

        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "no cooldown for the agent that was superseded"
        );
    }

    #[test]
    fn a_users_request_does_not_supersede_another_users_or_an_agent_that_arrives_later() {
        let (_clock, mut requests) = TestClock::new();
        let (first, mut first_rx) = ask_as_user(&mut requests, "cody-1").unwrap();

        assert_eq!(
            refusal(ask_as_user(&mut requests, "cody-1")),
            Some(SubmitRefused::Pending),
            "user against user"
        );
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Pending),
            "agent against user"
        );
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-2")),
            Some(SubmitRefused::Pending),
            "another agent against user"
        );
        assert!(matches!(first_rx.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(requests.pending().unwrap().request_id, first);
    }

    #[test]
    fn an_agent_never_supersedes_another_agent() {
        let (_clock, mut requests) = TestClock::new();
        let (first, mut first_rx) = ask_as_agent(&mut requests, "cody-1").unwrap();

        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-2")),
            Some(SubmitRefused::Pending)
        );
        assert!(matches!(first_rx.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(requests.pending().unwrap().request_id, first);
    }

    #[test]
    fn an_operator_gone_or_an_abandon_is_not_a_denial() {
        let (_clock, mut requests) = TestClock::new();
        let (_id, mut rx) = ask_as_agent(&mut requests, "cody-1").unwrap();
        assert!(requests.operator_gone());
        assert_eq!(rx.try_recv(), Ok(RemoteOutcome::OperatorGone));
        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "operator gone starts no cooldown"
        );
        let id = requests.pending().unwrap().request_id.clone();
        assert!(requests.abandon(&id));

        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "abandoning starts no cooldown"
        );
    }

    #[test]
    fn operator_gone_and_abandon_do_not_lengthen_a_streak_either() {
        let (clock, mut requests) = TestClock::new();
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        clock.advance(BASE_COOLDOWN);
        let (_id, _rx) = ask_as_agent(&mut requests, "cody-1").unwrap();
        assert!(requests.operator_gone());
        let (id, _rx) = ask_as_agent(&mut requests, "cody-1").unwrap();
        assert!(requests.abandon(&id));
        // Out of the request window, so only the streak is in play.
        clock.advance(REQUEST_WINDOW);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);

        // A second denial: 120 s, not 240 s.
        clock.advance(2 * MIN - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown)
        );
        clock.advance(MS);
        assert!(ask_as_agent(&mut requests, "cody-1").is_ok());
    }

    #[test]
    fn a_denial_streak_is_remembered_for_an_hour_and_then_forgotten() {
        // Two denials, the second at 15 minutes.
        let two_denials = || {
            let (clock, mut requests) = TestClock::new();
            agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
            clock.advance(REQUEST_WINDOW + 5 * MIN);
            agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
            (clock, requests)
        };
        let hour = Duration::from_secs(60 * 60);

        // A moment under an hour later the streak is still there: the third
        // denial costs 240 s.
        let (clock, mut requests) = two_denials();
        clock.advance(hour - Duration::from_secs(1));
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        clock.advance(Duration::from_secs(240) - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown),
            "remembered: the third denial costs 240 s"
        );

        // An hour after the last denial it is gone: the next costs 60 s.
        let (clock, mut requests) = two_denials();
        clock.advance(hour);
        agent_asks_and_user_answers(&mut requests, "cody-1", Decision::Cancel);
        clock.advance(BASE_COOLDOWN - MS);
        assert_eq!(
            refusal(ask_as_agent(&mut requests, "cody-1")),
            Some(SubmitRefused::Cooldown)
        );
        clock.advance(MS);
        assert!(
            ask_as_agent(&mut requests, "cody-1").is_ok(),
            "forgotten: that denial costs a minute again"
        );
    }

    // ── vocabulary of the flow ───────────────────────────────────────────────

    #[test]
    fn decisions_parse_from_exactly_connect_cancel_and_dismiss() {
        assert_eq!(Decision::parse("connect"), Some(Decision::Connect));
        assert_eq!(Decision::parse("cancel"), Some(Decision::Cancel));
        assert_eq!(Decision::parse("dismiss"), Some(Decision::Dismiss));
        for other in [
            "",
            "Connect",
            "CONNECT",
            " connect",
            "connect ",
            "accept",
            "yes",
            "approve",
            "deny",
            "cancelled",
            "dismissed",
            "timeout",
        ] {
            assert_eq!(Decision::parse(other), None, "{other:?}");
        }
    }

    #[test]
    fn outcomes_are_audited_under_their_documented_names() {
        let names = [
            (
                RemoteOutcome::Connect {
                    invite_follow: false,
                },
                "connect",
            ),
            (
                RemoteOutcome::Connect {
                    invite_follow: true,
                },
                "connect",
            ),
            (RemoteOutcome::Cancelled, "cancelled"),
            (RemoteOutcome::Dismissed, "dismissed"),
            (RemoteOutcome::TimedOut, "timed_out"),
        ];
        for (outcome, name) in names {
            assert_eq!(outcome.audit_name(), name, "{outcome:?}");
        }
    }

    #[test]
    fn the_waiting_limits_are_five_minutes_by_default_and_ten_seconds_to_ten_minutes() {
        assert_eq!(DEFAULT_TIMEOUT, Duration::from_secs(300));
        assert_eq!(MIN_TIMEOUT, Duration::from_secs(10));
        assert_eq!(MAX_TIMEOUT, Duration::from_secs(600));
        assert_eq!(MAX_REASON_CHARS, 200);
    }

    // ── the targets frame ────────────────────────────────────────────────────

    fn fixture_paths() -> EcsPaths {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ecs");
        EcsPaths::new(
            dir.join("config.json"),
            dir.join("ecs-local.json"),
            dir.join("ecs.sh"),
        )
    }

    #[test]
    fn the_targets_frame_carries_the_vocabulary_when_configured() {
        let ServerMsg::RemoteShellTargets {
            configured,
            problem,
            projects,
            shell_types,
        } = remote_targets_msg(&fixture_paths())
        else {
            panic!("expected a remote_shell_targets frame");
        };

        assert!(configured);
        assert_eq!(problem, None);
        let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "admin-portal",
                "family-portal",
                "payments",
                "referral-monitor"
            ]
        );
        assert_eq!(shell_types, ["console", "shell", "tinker"]);
    }

    #[test]
    fn the_targets_frame_says_not_configured_and_why_when_config_json_is_missing() {
        let dir = tempfile::TempDir::new().unwrap();
        let paths = EcsPaths::new(
            dir.path().join("config.json"),
            dir.path().join("ecs-local.json"),
            dir.path().join("ecs.sh"),
        );

        let ServerMsg::RemoteShellTargets {
            configured,
            problem,
            projects,
            shell_types,
        } = remote_targets_msg(&paths)
        else {
            panic!("expected a remote_shell_targets frame");
        };

        assert!(!configured);
        assert!(problem.is_some_and(|p| p.contains("config.json")));
        assert!(projects.is_empty());
        assert!(shell_types.is_empty());
    }
}
