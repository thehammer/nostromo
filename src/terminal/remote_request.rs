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
//! 3. register the request (a second one while it waits: `RequestPending`);
//! 4. send `remote_shell_confirm_request` to those connections, and only them;
//! 5. wait for the answer, or the timeout;
//! 6. on Connect, and only then, call the launcher;
//! 7. send `remote_shell_resolved` to the same connections;
//! 8. audit every step.
//!
//! No terminal, pane or process exists before step 6.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::{SecondsFormat, Utc};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use super::audit::{AuditEvent, AuditPin, AuditRequester, RefusalChannel};
use super::ecs::{EcsTarget, EcsVocabulary, InvalidTarget};
use super::launcher::{ConnectFailure, Placement, RemoteLauncher};
use super::{OperatorCap, TerminalManager};
use crate::ipc::protocol::{
    RemoteRequester, ServerMsg, TerminalInfo, TerminalRequester, TerminalTarget,
};

/// How long a request waits for the user when the caller does not say.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);
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
        }
    }
}

/// A request is already waiting for the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RequestPending;

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
#[derive(Default)]
pub struct RemoteRequests {
    pending: Option<Slot>,
}

impl RemoteRequests {
    /// Register a request. Its id, and a receiver for how it ends.
    pub fn submit(
        &mut self,
        requested_by: RemoteRequester,
        tag: String,
        target: TerminalTarget,
        reason: Option<String>,
    ) -> Result<(String, oneshot::Receiver<RemoteOutcome>), RequestPending> {
        if self.pending.is_some() {
            return Err(RequestPending);
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
    result
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
        Err(RequestPending) => {
            m.record_unanswered(request, wire_target, reason.as_deref(), "request_pending");
            return Err(RemoteResult::RequestPending);
        }
    };
    m.record_remote_requested(request, wire_target, reason.as_deref());
    let confirm = ServerMsg::RemoteShellConfirmRequest {
        request_id: request_id.clone(),
        tag: Some(request.tag.clone()),
        target: wire_target.clone(),
        requested_by: request.requested_by.clone(),
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
fn clean_reason(reason: &str) -> Option<String> {
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
    ) -> Result<(String, oneshot::Receiver<RemoteOutcome>), RequestPending> {
        requests.submit(requester(), "cody-1".into(), target(), Some("why".into()))
    }

    // ── one request at a time ────────────────────────────────────────────────

    #[test]
    fn a_second_request_while_one_is_pending_is_refused_and_the_first_is_untouched() {
        let mut requests = RemoteRequests::default();
        let (first_id, mut first_rx) = submit(&mut requests).expect("the first is accepted");

        let second = submit(&mut requests);

        assert!(matches!(second, Err(RequestPending)));
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
        assert!(requests.answer(&cap(), &first_id, Decision::Cancel, false));

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
