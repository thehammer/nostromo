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
    advance, lock_recover, resolve_claude, write_user_frame, PendingMessage, SessionEvent,
    SessionManager, Shared,
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
    /// The session had to be restarted first and could not be: the hold is kept
    /// on the downed session, and the supervisor retries the respawn.
    Failed,
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

/// The baseline of a hold whose credential was already rewritten when it was
/// first looked at: it sorts before every real stamp, so the next look sees a change.
const BEFORE_ANY_STAMP: &str = "";

/// The stamp a hold that failed at `failed_at` should treat as "the credential
/// the turn failed under", given the first stamp `seen` for it. The stamp is the
/// credential's own modification time (`20261018200418Z`, see `parse_mdat`), so
/// when it is later than the failure the user signed in before the probe or the
/// poller got to look: adopting that stamp would hide the sign-in forever, so the
/// baseline is [`BEFORE_ANY_STAMP`] instead and the change is acted on. A stamp
/// that is not a timestamp, or is not later (to the second), is adopted as is.
fn baseline_for(seen: &str, failed_at: DateTime<Utc>) -> String {
    let written = chrono::NaiveDateTime::parse_from_str(seen, "%Y%m%d%H%M%SZ").map(|t| t.and_utc());
    match written {
        Ok(written) if written.timestamp() > failed_at.timestamp() => BEFORE_ANY_STAMP.to_owned(),
        _ => seen.to_owned(),
    }
}

impl Hold {
    /// The credential at the failure is not known yet: it is looked at off the
    /// reader (`capture_stamp`), or adopted by the poller.
    fn first(frame: Option<PendingMessage>, turn_resendable: bool) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            resendable: frame.is_some() && turn_resendable,
            frame,
            phase: HoldPhase::Held,
            failed_at: Utc::now(),
            failed_instant: tokio::time::Instant::now(),
            stamp_at_failure: None,
            noticed_stamp: None,
            last_attempt_stamp: None,
            attempts: 0,
            escalated: false,
            escalation_due: false,
        }
    }

    /// The resent message failed to authenticate again: a new hold, so a late
    /// duplicate Retry that names the old id does nothing.
    fn failed_again(self, turn_resendable: bool) -> Self {
        let resendable = self.frame.is_some() && turn_resendable;
        Self {
            id: Uuid::new_v4().to_string(),
            resendable,
            phase: HoldPhase::Held,
            stamp_at_failure: None,
            noticed_stamp: None,
            escalation_due: resendable && self.last_attempt_stamp.is_some() && !self.escalated,
            ..self
        }
    }

    /// What a replacement process inherits: the message is held again. A message
    /// that was being resent had already been written to the old process, which
    /// may have acted on it before it died, so it is not resent by itself again
    /// (only a human's Retry sends it): never twice without someone looking.
    pub(super) fn for_respawn(mut self) -> Self {
        if self.phase == HoldPhase::Resending {
            self.resendable = false;
            self.escalation_due = false;
        }
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
        Arc::new(Self {
            cell: Mutex::new(LoginCell::default()),
            coordinator,
        })
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

    /// The session is gone (stopped, or the crash-loop guard gave up on it): it
    /// waits for no sign-in, and neither the held message nor anything written
    /// but not yet bound to a turn outlives it.
    pub(super) fn clear(&self) {
        let mut cell = lock_recover(&self.cell);
        *cell = LoginCell::default();
    }

    /// Stop was pressed: drop the hold unless its message is being resent (that
    /// turn's interrupted end clears it). True when a hold was dropped.
    pub(super) fn discard_for_stop(&self) -> bool {
        let mut cell = lock_recover(&self.cell);
        if cell
            .hold
            .as_ref()
            .is_some_and(|h| h.phase != HoldPhase::Resending)
        {
            cell.hold = None;
            return true;
        }
        false
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
            cell.written = None;
            let resending = cell
                .hold
                .as_ref()
                .is_some_and(|h| h.phase == HoldPhase::Resending);
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

    let queued = lock_recover(&shared.pending).len();
    let (first, stamp_for) = {
        let mut cell = lock_recover(&link.cell);
        let bound = cell.bound.take();
        cell.written = None;
        match cell.hold.take() {
            Some(prev) if prev.phase == HoldPhase::Resending => {
                let hold = prev.failed_again(outcome.resendable);
                let id = hold.id.clone();
                cell.hold = Some(hold);
                (None, Some(id))
            }
            // A hold is already there and not being resent: another turn (not
            // ours) failed. Keep the hold as it is.
            Some(prev) => {
                cell.hold = Some(prev);
                (None, None)
            }
            None => {
                let hold = Hold::first(bound, outcome.resendable);
                let (resendable, id) = (hold.resendable, hold.id.clone());
                cell.hold = Some(hold);
                (Some(resendable), Some(id))
            }
        }
    };
    if let Some(id) = stamp_for {
        capture_stamp(link, id);
    }
    match first {
        Some(resendable) => {
            warn!(
                tag,
                signal = outcome.signal.id(),
                resendable,
                queued,
                "claude auth failure detected"
            );
        }
        None => info!(tag, "held message resent: auth_failed"),
    }
    link.notify();
}

/// Note the credential as of this failure on the hold `hold_id`. The probe may
/// take seconds (a process), and the reader waits on nothing but stdout, so it
/// runs on a thread of its own; a probe that cannot say leaves the stamp to the
/// poller, which adopts the first one it sees.
fn capture_stamp(link: &Arc<LoginLink>, hold_id: String) {
    let Some(coordinator) = link.coordinator.clone() else {
        return;
    };
    let link = Arc::clone(link);
    let spawned = std::thread::Builder::new()
        .name("claude-login-stamp".into())
        .spawn(move || {
            if let CredentialStamp::Stamp(stamp) = coordinator.stamp_now() {
                let mut cell = lock_recover(&link.cell);
                if let Some(hold) = cell
                    .hold
                    .as_mut()
                    .filter(|h| h.id == hold_id && h.stamp_at_failure.is_none())
                {
                    hold.stamp_at_failure = Some(baseline_for(&stamp, hold.failed_at));
                }
            }
        });
    if let Err(e) = spawned {
        warn!("could not start the credential probe: {e}");
    }
}

// ── resending ──────────────────────────────────────────────────────────────────

/// What [`plan_resend`] decided, made under the session's locks.
enum ResendPlan {
    /// The hold is now `Resending` and the session `MidTurn`: write `frame`.
    Write {
        frame: PendingMessage,
        attempt: u8,
        prev_attempt_stamp: Option<String>,
    },
    /// Restart the session process first (the credential may be cached), then plan again.
    Escalate,
    Skip(ResendOutcome),
}

/// Decide whether `hold_id` may be written again and, if so, move the hold to
/// resending and the session to `MidTurn` in one step. `after_restart` skips the
/// trigger rules: the restart was already the escalation.
fn plan_resend(
    shared: &Shared,
    hold_id: &str,
    trigger: &ResendTrigger,
    after_restart: bool,
) -> ResendPlan {
    let mut state = lock_recover(&shared.state);
    let applying = lock_recover(&shared.model).applying.is_some();
    let mut cell = lock_recover(&shared.login.cell);
    let Some(hold) = cell.hold.as_mut() else {
        return ResendPlan::Skip(ResendOutcome::NoOp);
    };
    if hold.id != hold_id || hold.phase != HoldPhase::Held {
        return ResendPlan::Skip(ResendOutcome::NoOp);
    }
    let Some(frame) = hold.frame.clone() else {
        return ResendPlan::Skip(ResendOutcome::NoOp);
    };
    if !after_restart && !hold.allows(trigger) {
        return ResendPlan::Skip(ResendOutcome::NoOp);
    }
    if !after_restart && hold.escalation_due && matches!(trigger, ResendTrigger::Keychain { .. }) {
        hold.escalated = true;
        hold.escalation_due = false;
        return ResendPlan::Escalate;
    }
    if *state != SessionState::Idle || applying {
        return ResendPlan::Skip(ResendOutcome::Busy);
    }
    let prev_attempt_stamp = hold.last_attempt_stamp.clone();
    hold.phase = HoldPhase::Resending;
    hold.attempts = hold.attempts.saturating_add(1);
    if let ResendTrigger::Keychain { stamp } = trigger {
        hold.last_attempt_stamp = Some(stamp.clone());
    }
    *state = SessionState::MidTurn;
    ResendPlan::Write {
        frame,
        attempt: hold.attempts,
        prev_attempt_stamp,
    }
}

/// The message could not be written: back to waiting, as if nothing had been tried.
fn undo_resend(shared: &Shared, hold_id: &str, prev_attempt_stamp: Option<String>) {
    let mut state = lock_recover(&shared.state);
    let mut cell = lock_recover(&shared.login.cell);
    if let Some(hold) = cell.hold.as_mut().filter(|h| h.id == hold_id) {
        hold.phase = HoldPhase::Held;
        hold.attempts = hold.attempts.saturating_sub(1);
        hold.last_attempt_stamp = prev_attempt_stamp;
    }
    *state = SessionState::Idle;
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
    pub fn has_login_hold(&self) -> bool {
        self.sessions
            .values()
            .any(|s| s.waits_for_login() && s.shared.login.paused())
    }

    /// Ask the coordinator to publish: something about a hold changed.
    pub(super) fn login_changed(&self) {
        if let Some(c) = &self.login {
            c.changed();
        }
    }

    /// Where `claude` is, for the sign-in instructions. Looking it up can run
    /// `which`, and this is called under the manager's lock on every publish, so
    /// a path found is kept (while it still runs) and one not found is not
    /// looked for again for a minute. An override in the environment is cheap
    /// and always read fresh.
    fn claude_bin(&self) -> Option<String> {
        const RETRY_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
        if std::env::var(super::CLAUDE_BIN_ENV).is_ok_and(|p| !p.is_empty()) {
            return resolve_claude().ok().map(|p| p.display().to_string());
        }
        let mut cache = lock_recover(&self.claude_bin_cache);
        match &*cache {
            Some((Some(path), _)) if super::is_executable(path) => {
                return Some(path.display().to_string())
            }
            Some((None, at)) if at.elapsed() < RETRY_AFTER => return None,
            _ => {}
        }
        let found = resolve_claude().ok();
        *cache = Some((found.clone(), std::time::Instant::now()));
        found.map(|p| p.display().to_string())
    }

    /// Tell clients where things stand again, though nothing changed.
    fn rebroadcast_login(&self) {
        if let Some(c) = &self.login {
            c.rebroadcast();
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
            claude_bin: needs_login.then(|| self.claude_bin()).flatten(),
            watch: self
                .login
                .as_ref()
                .map_or(ClaudeLoginWatch::Keychain, |c| c.watch_state()),
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
        for (tag, session) in self.sessions.iter().filter(|(_, s)| s.waits_for_login()) {
            let mut cell = lock_recover(&session.shared.login.cell);
            let Some(hold) = cell.hold.as_mut() else {
                continue;
            };
            let Some(base) = hold.stamp_at_failure.as_deref() else {
                hold.stamp_at_failure = Some(baseline_for(current, hold.failed_at));
                // Seen again (as a change, if the sign-in beat this look) on the next one.
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
            } else if hold.resendable
                && hold.phase == HoldPhase::Held
                && (changed || hold.escalation_due)
            {
                acts.push((tag.clone(), Act::Resend(hold.id.clone())));
            }
        }
        for (tag, act) in acts {
            match act {
                Act::Resend(id) => {
                    self.resend_held(
                        &tag,
                        &id,
                        ResendTrigger::Keychain {
                            stamp: current.to_owned(),
                        },
                    );
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
    pub fn resend_held(
        &mut self,
        tag: &str,
        hold_id: &str,
        trigger: ResendTrigger,
    ) -> ResendOutcome {
        self.resend_inner(tag, hold_id, &trigger, false)
    }

    fn resend_inner(
        &mut self,
        tag: &str,
        hold_id: &str,
        trigger: &ResendTrigger,
        after_restart: bool,
    ) -> ResendOutcome {
        let Some(session) = self.sessions.get(tag) else {
            return ResendOutcome::NoOp;
        };
        if !session.alive() {
            return ResendOutcome::NoOp;
        }
        let shared = session.shared.clone();
        match plan_resend(&shared, hold_id, trigger, after_restart) {
            ResendPlan::Skip(outcome) => {
                // A human's action that changed nothing still hears where things
                // stand; the poller's own tries stay quiet.
                if matches!(trigger, ResendTrigger::Manual) {
                    self.rebroadcast_login();
                }
                outcome
            }
            ResendPlan::Escalate => {
                info!(tag, "held message resent: restarting");
                if let Err(e) = self.restart(tag) {
                    // The hold stays with the downed session (see `restart`).
                    warn!(tag, "restart before resending a held message failed; the hold is kept and the respawn retried: {e:#}");
                    return ResendOutcome::Failed;
                }
                self.resend_inner(tag, hold_id, trigger, true)
            }
            ResendPlan::Write {
                frame,
                attempt,
                prev_attempt_stamp,
            } => {
                info!(
                    tag,
                    hold_id,
                    trigger = trigger.id(),
                    attempt,
                    "resending held message"
                );
                if write_recorded(&shared, &frame).is_ok() {
                    shared.broadcast(SessionEvent::State(SessionState::MidTurn));
                    shared.login.notify();
                    return ResendOutcome::Resent;
                }
                warn!(tag, "held message could not be written");
                undo_resend(&shared, hold_id, prev_attempt_stamp);
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
        let Some(session) = self.sessions.get(tag) else {
            return false;
        };
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
            self.rebroadcast_login();
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
