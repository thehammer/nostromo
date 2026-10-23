//! A turn that failed because Claude could not sign in: hold its message, pause
//! the session's queue, and send the message again exactly once after the login
//! changes (or when the verified app asks).
//!
//! The state lives in each session's [`LoginLink`] cell, a **leaf lock** (see
//! [`Shared`]): the reader thread makes the hold when a turn ends in an auth
//! failure (`on_turn_end`), the manager resends or discards it (`resend_held`,
//! `discard_held`), and `send_user_message` and `step` only ever ask whether the
//! session is paused. The coordinator (`ipc::claude_login`) reads the holds
//! through the manager to tell clients and to watch the credential.
//!
//! Nothing here logs or stores message text, error text, a credential stamp or
//! `security` output: the held frame is kept in memory only (a daemon restart
//! forgets it, like `pending`).

use std::sync::{Arc, Mutex};

use anyhow::Result;
use chrono::{DateTime, SecondsFormat, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use super::{
    advance, lock_recover, resolve_claude, write_user_frame, PendingMessage, SessionEvent, SessionManager, Shared,
};
use crate::ipc::auth_failure::TurnAuthOutcome;
use crate::ipc::claude_login::{
    CredentialStamp, LoginCoordinator, AUTO_RESEND_TTL, MAX_AUTO_RESENDS,
};
use crate::ipc::protocol::{ClaudeLoginPhase, ClaudeLoginSession, ClaudeLoginWatch, ServerMsg};
use crate::ipc::stream_json::SessionState;

/// What asked for a held message to be sent again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResendTrigger {
    /// The credential changed. `stamp` is what the watch saw now (never logged).
    /// Allowed only for a resendable hold, younger than `AUTO_RESEND_TTL`, with
    /// fewer than `MAX_AUTO_RESENDS` attempts, and at most once per stamp.
    Keychain { stamp: String },
    /// A human pressed Retry. Allowed whatever the hold's age, attempts or kind.
    Manual,
}

impl ResendTrigger {
    fn id(&self) -> &'static str {
        match self {
            ResendTrigger::Keychain { .. } => "keychain",
            ResendTrigger::Manual => "manual",
        }
    }
}

/// What [`SessionManager::resend_held`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResendOutcome {
    /// The held message was written again (after a restart, when it came to that).
    Resent,
    /// Nothing changed: no such hold, not waiting, or this trigger may not resend it.
    NoOp,
    /// Not now (a turn or a model switch is running, or the write failed); asking
    /// again later may succeed.
    Busy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HoldPhase {
    /// The message is held and waits for the login.
    Held,
    /// It was written again; its turn has not ended.
    Resending,
}

/// One session's hold: the message of a turn that failed to authenticate (or,
/// with no `frame`, a pause that has nothing to send again).
pub(super) struct Hold {
    id: String,
    /// The exact frame that was written, note prefix included.
    frame: Option<PendingMessage>,
    phase: HoldPhase,
    /// A resend repeats nothing: the turn did no real work and the daemon wrote its message.
    resendable: bool,
    failed_at: DateTime<Utc>,
    failed_instant: tokio::time::Instant,
    /// The credential when the turn failed; `None` until the watch could say.
    stamp_at_failure: Option<String>,
    /// The latest changed stamp already logged, so the change is reported once.
    noticed_stamp: Option<String>,
    /// The stamp the latest keychain-triggered attempt was made on.
    last_attempt_stamp: Option<String>,
    attempts: u8,
    /// The session process was already restarted for this message.
    escalated: bool,
    /// The last resend failed after the credential had changed: the live process
    /// may have cached the old one, so one restart is due.
    escalation_due: bool,
}

impl Hold {
    fn first(frame: Option<PendingMessage>, turn_resendable: bool, stamp: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            resendable: frame.is_some() && turn_resendable,
            frame,
            phase: HoldPhase::Held,
            failed_at: Utc::now(),
            failed_instant: tokio::time::Instant::now(),
            stamp_at_failure: stamp,
            noticed_stamp: None,
            last_attempt_stamp: None,
            attempts: 0,
            escalated: false,
            escalation_due: false,
        }
    }

    /// The resent message failed to authenticate again: a new hold, so a late
    /// duplicate Retry that names the old id does nothing.
    fn failed_again(self, stamp: Option<String>, turn_resendable: bool) -> Self {
        let resendable = self.frame.is_some() && turn_resendable;
        Self {
            id: Uuid::new_v4().to_string(),
            resendable,
            phase: HoldPhase::Held,
            stamp_at_failure: stamp.or(self.stamp_at_failure),
            noticed_stamp: None,
            escalation_due: resendable && self.last_attempt_stamp.is_some() && !self.escalated,
            ..self
        }
    }

    /// What a replacement process inherits: the message is held again, whatever
    /// the old process was doing with it.
    pub(super) fn for_respawn(mut self) -> Self {
        self.phase = HoldPhase::Held;
        self
    }

    fn phase_on_wire(&self) -> ClaudeLoginPhase {
        match (&self.frame, self.phase, self.resendable) {
            (None, ..) => ClaudeLoginPhase::PausedNoHold,
            (Some(_), HoldPhase::Resending, _) => ClaudeLoginPhase::Resending,
            (Some(_), HoldPhase::Held, true) => ClaudeLoginPhase::Waiting,
            (Some(_), HoldPhase::Held, false) => ClaudeLoginPhase::NotResendable,
        }
    }

    fn allows(&self, trigger: &ResendTrigger) -> bool {
        match trigger {
            ResendTrigger::Manual => true,
            ResendTrigger::Keychain { stamp } => {
                self.resendable
                    && self.failed_instant.elapsed() < AUTO_RESEND_TTL
                    && self.attempts < MAX_AUTO_RESENDS
                    && (self.escalation_due
                        || (self.stamp_at_failure.as_deref() != Some(stamp)
                            && self.last_attempt_stamp.as_deref() != Some(stamp)))
            }
        }
    }
}

#[derive(Default)]
struct LoginCell {
    /// The frame most recently written, not yet bound to the turn it starts.
    written: Option<PendingMessage>,
    /// The frame that started the turn now running.
    bound: Option<PendingMessage>,
    hold: Option<Hold>,
}

/// A session's login state, shared with its reader thread.
pub(super) struct LoginLink {
    cell: Mutex<LoginCell>,
    coordinator: Option<Arc<LoginCoordinator>>,
}

impl LoginLink {
    pub(super) fn new(coordinator: Option<Arc<LoginCoordinator>>) -> Arc<Self> {
        Arc::new(Self { cell: Mutex::new(LoginCell::default()), coordinator })
    }

    /// Is the session paused for a sign-in? A leaf lock: callable under `state`.
    pub(super) fn paused(&self) -> bool {
        lock_recover(&self.cell).hold.is_some()
    }

    /// Hold a replacement process's carried hold (before it is advanced).
    pub(super) fn restore(&self, hold: Hold) {
        lock_recover(&self.cell).hold = Some(hold);
        self.notify();
    }

    /// Take the hold for a replacement process.
    pub(super) fn take_for_respawn(&self) -> Option<Hold> {
        lock_recover(&self.cell).hold.take().map(Hold::for_respawn)
    }

    pub(super) fn notify(&self) {
        if let Some(c) = &self.coordinator {
            c.changed();
        }
    }

    fn remember_written(&self, msg: &PendingMessage) {
        lock_recover(&self.cell).written = Some(msg.clone());
    }

    fn forget_written(&self) {
        lock_recover(&self.cell).written = None;
    }
}

// ── writing ────────────────────────────────────────────────────────────────────

/// Write `msg` verbatim as one user frame, remembering it as the message the
/// next turn will be bound to. It is remembered *before* the write: the CLI's
/// echo can reach the reader before the write returns. A failed write forgets it.
pub(super) fn write_recorded(shared: &Shared, msg: &PendingMessage) -> Result<()> {
    shared.login.remember_written(msg);
    let result = write_user_frame(&shared.stdin, &msg.text, &msg.images);
    if result.is_err() {
        shared.login.forget_written();
    }
    result
}

// ── the reader's side ──────────────────────────────────────────────────────────

/// A turn started: it belongs to the message the daemon last wrote, if any.
pub(super) fn on_turn_started(shared: &Shared) {
    let mut cell = lock_recover(&shared.login.cell);
    cell.bound = cell.written.take();
}

/// A turn ended. `outcome` is `Some` when it was an auth failure. The caller
/// advances the session afterwards; while a hold exists `step` does not drain
/// the queue.
pub(super) fn on_turn_end(shared: &Shared, tag: &str, outcome: Option<TurnAuthOutcome>) {
    let link = &shared.login;
    let Some(outcome) = outcome else {
        // A turn that did not fail ends a resend: the message went through.
        let cleared = {
            let mut cell = lock_recover(&link.cell);
            cell.bound = None;
            let resending = cell.hold.as_ref().is_some_and(|h| h.phase == HoldPhase::Resending);
            if resending {
                cell.hold = None;
            }
            resending
        };
        if cleared {
            info!(tag, "held message resent: ok");
            link.notify();
        }
        return;
    };

    // The credential as of this failure. It may block (a process), so before any lock.
    let stamp = match link.coordinator.as_ref().map(|c| c.stamp_now()) {
        Some(CredentialStamp::Stamp(s)) => Some(s),
        _ => None,
    };
    let queued = lock_recover(&shared.pending).len();
    let first = {
        let mut cell = lock_recover(&link.cell);
        let bound = cell.bound.take();
        match cell.hold.take() {
            Some(prev) if prev.phase == HoldPhase::Resending => {
                cell.hold = Some(prev.failed_again(stamp, outcome.resendable));
                None
            }
            // A hold is already there and not being resent: another turn (not
            // ours) failed. Keep the hold as it is.
            Some(prev) => {
                cell.hold = Some(prev);
                None
            }
            None => {
                let hold = Hold::first(bound, outcome.resendable, stamp);
                let resendable = hold.resendable;
                cell.hold = Some(hold);
                Some(resendable)
            }
        }
    };
    match first {
        Some(resendable) => {
            warn!(tag, signal = outcome.signal.id(), resendable, queued, "claude auth failure detected");
        }
        None => info!(tag, "held message resent: auth_failed"),
    }
    link.notify();
}

// ── the manager's side ─────────────────────────────────────────────────────────

impl SessionManager {
    /// Give sessions spawned from now on a coordinator to tell of their holds
    /// (`LoginCoordinator::attach` calls this).
    pub fn configure_login(&mut self, coordinator: Arc<LoginCoordinator>) {
        self.login = Some(coordinator);
    }

    /// The coordinator, if one is configured.
    pub fn login(&self) -> Option<&Arc<LoginCoordinator>> {
        self.login.as_ref()
    }

    /// Is any session holding a message for a sign-in?
    pub(crate) fn has_login_hold(&self) -> bool {
        self.sessions.values().any(|s| s.shared.login.paused())
    }

    /// Ask the coordinator to publish: something about a hold changed.
    pub(super) fn login_changed(&self) {
        if let Some(c) = &self.login {
            c.changed();
        }
    }

    /// The whole picture: every session waiting for a sign-in.
    pub fn login_snapshot(&self) -> ServerMsg {
        let mut sessions: Vec<ClaudeLoginSession> = self
            .sessions
            .values()
            .filter(|s| s.stop_reason.is_none())
            .filter_map(|s| {
                let cell = lock_recover(&s.shared.login.cell);
                let hold = cell.hold.as_ref()?;
                Some(ClaudeLoginSession {
                    tag: s.tag.clone(),
                    hold_id: hold.frame.is_some().then(|| hold.id.clone()),
                    phase: hold.phase_on_wire(),
                    queued: lock_recover(&s.shared.pending).len() as u32,
                    failed_at: hold.failed_at.to_rfc3339_opts(SecondsFormat::Secs, true),
                    auto_resends_left: MAX_AUTO_RESENDS.saturating_sub(hold.attempts),
                })
            })
            .collect();
        sessions.sort_by(|a, b| a.tag.cmp(&b.tag));
        let needs_login = !sessions.is_empty();
        ServerMsg::ClaudeLoginState {
            needs_login,
            claude_bin: needs_login
                .then(|| resolve_claude().ok().map(|p| p.display().to_string()))
                .flatten(),
            watch: self.login.as_ref().map_or(ClaudeLoginWatch::Keychain, |c| c.watch_state()),
            sessions,
        }
    }

    /// The watch saw `current`. Every hold that has not seen a stamp yet adopts
    /// it as the one the turn failed under; every hold whose credential has
    /// changed is resent (the one-attempt-per-stamp and other rules are
    /// `resend_held`'s), and a paused queue with nothing held is released.
    pub(crate) fn on_credential_stamp(&mut self, current: &str) {
        enum Act {
            Resend(String),
            Release,
        }
        let mut acts: Vec<(String, Act)> = Vec::new();
        for (tag, session) in &self.sessions {
            let mut cell = lock_recover(&session.shared.login.cell);
            let Some(hold) = cell.hold.as_mut() else { continue };
            let Some(base) = hold.stamp_at_failure.as_deref() else {
                hold.stamp_at_failure = Some(current.to_owned());
                continue;
            };
            let changed = base != current;
            if changed && hold.noticed_stamp.as_deref() != Some(current) {
                hold.noticed_stamp = Some(current.to_owned());
                info!(tag, "claude credential changed");
            }
            if hold.frame.is_none() {
                if changed {
                    acts.push((tag.clone(), Act::Release));
                }
            } else if hold.phase == HoldPhase::Held && (changed || hold.escalation_due) {
                acts.push((tag.clone(), Act::Resend(hold.id.clone())));
            }
        }
        for (tag, act) in acts {
            match act {
                Act::Resend(id) => {
                    self.resend_held(&tag, &id, ResendTrigger::Keychain { stamp: current.to_owned() });
                }
                Act::Release => {
                    self.drop_hold(&tag, None, false);
                }
            }
        }
    }

    /// Write `tag`'s held message again, exactly once. Under the session's locks
    /// the hold moves from held to resending only if `hold_id` is the current hold
    /// and it is waiting; anything else is a no-op that sends the current state
    /// again. See [`ResendTrigger`] for who may.
    ///
    /// A resend that fails again after the credential changed restarts the
    /// session process once (it may have cached the old credential) and resends
    /// once more after the respawn.
    pub fn resend_held(&mut self, tag: &str, hold_id: &str, trigger: ResendTrigger) -> ResendOutcome {
        self.resend_inner(tag, hold_id, &trigger, false)
    }

    fn resend_inner(&mut self, tag: &str, hold_id: &str, trigger: &ResendTrigger, after_restart: bool) -> ResendOutcome {
        enum Plan {
            Write { frame: PendingMessage, attempt: u8, prev_attempt_stamp: Option<String> },
            Escalate,
            Skip(ResendOutcome),
        }
        let Some(session) = self.sessions.get(tag) else { return ResendOutcome::NoOp };
        if !session.alive() {
            return ResendOutcome::NoOp;
        }
        let shared = session.shared.clone();
        let plan = {
            let mut state = lock_recover(&shared.state);
            let applying = lock_recover(&shared.model).applying.is_some();
            let mut guard = lock_recover(&shared.login.cell);
            let cell: &mut LoginCell = &mut guard;
            match cell.hold.as_mut() {
                Some(hold) if hold.id == hold_id && hold.phase == HoldPhase::Held && hold.frame.is_some() => {
                    if !after_restart && !hold.allows(trigger) {
                        Plan::Skip(ResendOutcome::NoOp)
                    } else if !after_restart && hold.escalation_due && matches!(trigger, ResendTrigger::Keychain { .. }) {
                        hold.escalated = true;
                        hold.escalation_due = false;
                        Plan::Escalate
                    } else if *state != SessionState::Idle || applying {
                        Plan::Skip(ResendOutcome::Busy)
                    } else {
                        let prev_attempt_stamp = hold.last_attempt_stamp.clone();
                        hold.phase = HoldPhase::Resending;
                        hold.attempts = hold.attempts.saturating_add(1);
                        if let ResendTrigger::Keychain { stamp } = trigger {
                            hold.last_attempt_stamp = Some(stamp.clone());
                        }
                        *state = SessionState::MidTurn;
                        Plan::Write {
                            frame: hold.frame.clone().expect("checked above"),
                            attempt: hold.attempts,
                            prev_attempt_stamp,
                        }
                    }
                }
                _ => Plan::Skip(ResendOutcome::NoOp),
            }
        };
        match plan {
            Plan::Skip(outcome) => {
                // A human's action that changed nothing still hears where things
                // stand; the poller's own tries stay quiet.
                if matches!(trigger, ResendTrigger::Manual) {
                    if let Some(c) = &self.login {
                        c.rebroadcast();
                    }
                }
                outcome
            }
            Plan::Escalate => {
                info!(tag, "held message resent: restarting");
                if let Err(e) = self.restart(tag) {
                    warn!(tag, "restart before resending a held message failed: {e:#}");
                    return ResendOutcome::Busy;
                }
                self.resend_inner(tag, hold_id, trigger, true)
            }
            Plan::Write { frame, attempt, prev_attempt_stamp } => {
                info!(tag, hold_id, trigger = trigger.id(), attempt, "resending held message");
                if write_recorded(&shared, &frame).is_ok() {
                    shared.broadcast(SessionEvent::State(SessionState::MidTurn));
                    shared.login.notify();
                    return ResendOutcome::Resent;
                }
                // Not written: back to waiting, as if nothing had been tried.
                warn!(tag, "held message could not be written");
                {
                    let mut state = lock_recover(&shared.state);
                    let mut cell = lock_recover(&shared.login.cell);
                    if let Some(hold) = cell.hold.as_mut().filter(|h| h.id == hold_id) {
                        hold.phase = HoldPhase::Held;
                        hold.attempts = hold.attempts.saturating_sub(1);
                        hold.last_attempt_stamp = prev_attempt_stamp;
                    }
                    *state = SessionState::Idle;
                }
                shared.broadcast(SessionEvent::State(SessionState::Idle));
                shared.login.notify();
                ResendOutcome::Busy
            }
        }
    }

    /// Drop `tag`'s hold, unpause its queue and let it drain. `hold_id` is the
    /// hold the human saw; `None` names a pause with nothing held. False (and
    /// nothing changes) when it is not the current one.
    pub fn discard_held(&mut self, tag: &str, hold_id: Option<&str>) -> bool {
        self.drop_hold(tag, hold_id, true)
    }

    fn drop_hold(&mut self, tag: &str, hold_id: Option<&str>, discarded: bool) -> bool {
        let Some(session) = self.sessions.get(tag) else { return false };
        let shared = session.shared.clone();
        let (dropped, idle) = {
            let state = lock_recover(&shared.state);
            let mut cell = lock_recover(&shared.login.cell);
            let matches = match (&cell.hold, hold_id) {
                (Some(hold), Some(id)) => hold.frame.is_some() && hold.id == id,
                (Some(hold), None) => hold.frame.is_none(),
                (None, _) => false,
            };
            if matches {
                cell.hold = None;
            }
            (matches, *state == SessionState::Idle)
        };
        if !dropped {
            if let Some(c) = &self.login {
                c.rebroadcast();
            }
            return false;
        }
        if discarded {
            info!(tag, "held message discarded");
        } else {
            info!(tag, "paused queue released after the credential changed");
        }
        // The queue drains now unless a turn is running (its end drains it).
        if idle {
            advance(&shared);
        }
        shared.login.notify();
        true
    }
}
