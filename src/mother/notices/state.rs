//! The engine's state machine: everything computed under its one lock.
//!
//! [`State`] never touches the session, the audit log or the change channel.
//! Its methods record what happened (in the store, `audits`, `dirty` and
//! `changed`) and return [`Effect`]s for the engine to run once the lock is
//! released (see the lock-order note in the module docs).

use std::collections::{HashMap, HashSet};

use super::batch::{self, Bucket, Hold, HoldReason};
use super::detect::{self, JobEvent, Seen};
use super::element::{self, NoticeItem};
use super::limits::{self, HOUR_MS};
use super::store::{FocusRecord, JobRecord, Snapshot, Store};
use super::{
    gen_of, FocusNoticeState, HeldSummary, NoticeHistoryEntry, NoticeReason, NoticeScope,
    NoticeStatus, NoticeView, SettingsError, FOCUS_UNSEEN_MAX_MS, HISTORY_MAX, JOB_ABSENT_MAX_MS,
};
use crate::ipc::session_manager::{NoticeDelivery, TurnAuthor, TurnEvent};
use crate::mother::audit::MotherAuditEvent;
use crate::mother::origin::{is_tag_like, NotifyLevel, OriginKind};
use crate::mother::MotherJob;

/// What triggered a delivery attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Trigger {
    /// A batch window closed.
    Window,
    /// A turn started or ended (Quiet, session not running, busy).
    AfterTurn,
    /// The hour rolled under a cap hold.
    CapRolled,
    /// The user started a turn: releases every hold, cap and loop guard too.
    UserTurn,
    /// A notice turn started: Quiet / session-not-running items queue behind
    /// it, but only when the delivery cannot become a turn past the cap or the
    /// loop guard whatever this turn does.
    DuringNoticeTurn,
}

/// Something to do once the engine's lock is released.
#[derive(Debug)]
pub(super) enum Effect {
    Deliver {
        tag: String,
        gen: u64,
        merged: String,
        fresh: String,
    },
    Withdraw {
        tag: String,
    },
}

/// The effective level of a change: the lowest of the global switch, the
/// focus's mode and the job's own `notify`. `Err` names why it is off.
fn effective(
    global: bool,
    mode: Option<NotifyLevel>,
    job: Option<NotifyLevel>,
) -> Result<NotifyLevel, NoticeReason> {
    if !global {
        return Err(NoticeReason::GlobalOff);
    }
    let rank = |l: NotifyLevel| match l {
        NotifyLevel::Off => 0,
        NotifyLevel::Quiet => 1,
        NotifyLevel::Wake => 2,
    };
    let focus = mode.unwrap_or(NotifyLevel::Wake);
    let job = job.unwrap_or(NotifyLevel::Wake);
    let level = if rank(job) < rank(focus) { job } else { focus };
    if level == NotifyLevel::Off {
        Err(NoticeReason::FocusOff)
    } else {
        Ok(level)
    }
}

pub(super) struct State {
    pub(super) store: Store,
    /// The store existed (or the engine has looked at the feed once).
    bootstrapped: bool,
    /// The first look after loading compares each job with what was last
    /// accounted for (R9).
    restart_check: bool,
    /// Tags the registry has reported departed (and not seen again).
    closed: HashSet<String>,
    /// Focuses in a notice turn now, and whether it queued a notice-born job.
    notice_turns: HashMap<String, bool>,
    /// The store needs writing.
    dirty: bool,
    /// Something the app or the feed shows changed.
    changed: bool,
    audits: Vec<MotherAuditEvent>,
}

// ── construction and hand-off to the engine ─────────────────────────────────

impl State {
    /// State over a loaded `store`; `existed` is whether its file did.
    pub(super) fn new(mut store: Store, existed: bool, now: i64) -> Self {
        // Messages in flight died with the previous daemon's queue: they wait
        // for the session's next turn.
        for focus in store.focuses.values_mut() {
            let bucket = &mut focus.bucket;
            let lost = bucket.take_back(|f| !f.told);
            bucket.inflight.clear();
            if lost {
                bucket.hold_at_least(HoldReason::SessionNotRunning, now);
            }
        }
        Self {
            store,
            bootstrapped: existed,
            restart_check: existed,
            closed: HashSet::new(),
            notice_turns: HashMap::new(),
            dirty: false,
            changed: false,
            audits: Vec::new(),
        }
    }

    /// Does the store need writing? Clears the flag.
    pub(super) fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    /// Did something the app or the feed shows change? Clears the flag.
    pub(super) fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    /// The audit events recorded since the last call.
    pub(super) fn take_audits(&mut self) -> Vec<MotherAuditEvent> {
        std::mem::take(&mut self.audits)
    }

    /// `tag` just queued a job: if it is in a notice turn, the job is
    /// notice-born (loop guard).
    pub(super) fn note_job_origin(&mut self, tag: &str) {
        if let Some(born) = self.notice_turns.get_mut(tag) {
            *born = true;
        }
    }

    /// The store needs writing and the app or feed should hear of it.
    fn touch(&mut self) {
        self.dirty = true;
        self.changed = true;
    }

    fn audit_dropped(&mut self, tag: &str, reason: &'static str) {
        self.audits.push(MotherAuditEvent::JobNoticeDropped {
            focus: tag.to_owned(),
            reason,
        });
    }
}

// ── records ─────────────────────────────────────────────────────────────────

impl State {
    fn focus(&mut self, tag: &str) -> &mut FocusRecord {
        self.store.focuses.entry(tag.to_owned()).or_default()
    }

    /// Record a status change for `job_id`. `history` adds an entry.
    #[allow(clippy::too_many_arguments)]
    fn record(
        &mut self,
        job_id: &str,
        status: NoticeStatus,
        reason: Option<NoticeReason>,
        states: &[JobEvent],
        wake: bool,
        history: bool,
        now: i64,
    ) {
        let Some(rec) = self.store.jobs.get_mut(job_id) else {
            return;
        };
        let view = &mut rec.notice;
        let same = view.status == status && view.reason == reason;
        if same && !history {
            return;
        }
        view.status = status;
        view.reason = reason;
        if let Some(last) = states.last() {
            view.last_state = Some(*last);
        }
        view.at_ms = Some(now);
        if history {
            view.history.push(NoticeHistoryEntry {
                states: states.to_vec(),
                status,
                reason,
                wake,
                at_ms: now,
            });
            let excess = view.history.len().saturating_sub(HISTORY_MAX);
            view.history.drain(..excess);
        }
        if matches!(
            status,
            NoticeStatus::Told | NoticeStatus::Dropped | NoticeStatus::NotSent
        ) {
            if let Some(last) = states.last() {
                rec.last_notified = Some(last.as_str().to_owned());
            }
        }
        self.touch();
    }

    /// Mark each due item of `tag`'s bucket held for `reason` (history only
    /// when its reason changes).
    fn record_held(&mut self, tag: &str, reason: NoticeReason, now: i64) {
        let items: Vec<(String, Vec<JobEvent>)> = self
            .store
            .focuses
            .get(tag)
            .map(|f| {
                f.bucket
                    .items
                    .iter()
                    .filter(|p| p.due)
                    .map(|p| (p.item.job_id.clone(), p.item.states.clone()))
                    .collect()
            })
            .unwrap_or_default();
        for (id, states) in items {
            let changed = self.store.jobs.get(&id).is_some_and(|r| {
                r.notice.status != NoticeStatus::Held || r.notice.reason != Some(reason)
            });
            if changed {
                self.record(
                    &id,
                    NoticeStatus::Held,
                    Some(reason),
                    &states,
                    false,
                    true,
                    now,
                );
            }
        }
    }

    /// Hold `tag`'s due delivery for `reason` (audited when the reason is new).
    fn hold(&mut self, tag: &str, reason: HoldReason, now: i64) {
        let bucket = &mut self.focus(tag).bucket;
        let before = bucket.hold.map(|h| h.reason);
        bucket.hold_with(reason, now);
        if before != Some(reason) {
            self.audits.push(MotherAuditEvent::JobNoticeHeld {
                focus: tag.to_owned(),
                reason: reason.into(),
            });
            self.touch();
        }
        self.record_held(tag, reason.into(), now);
    }

    /// Drop everything waiting for `tag` with `status`/`reason`.
    fn drop_all(
        &mut self,
        tag: &str,
        status: NoticeStatus,
        reason: NoticeReason,
        audit: Option<&'static str>,
        now: i64,
    ) -> bool {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return false;
        };
        let gone = focus.bucket.clear();
        if gone.is_empty() {
            return false;
        }
        for item in &gone {
            self.record(
                &item.job_id,
                status,
                Some(reason),
                &item.states,
                false,
                true,
                now,
            );
        }
        if let Some(word) = audit {
            self.audit_dropped(tag, word);
        }
        self.touch();
        true
    }

    /// Forget jobs gone from the feed for a week.
    fn forget_absent_jobs(&mut self, now: i64) {
        let before = self.store.jobs.len();
        self.store
            .jobs
            .retain(|_, r| now - r.last_seen_ms <= JOB_ABSENT_MAX_MS);
        if self.store.jobs.len() != before {
            self.dirty = true;
        }
    }
}

// ── the feed ────────────────────────────────────────────────────────────────

impl State {
    pub(super) fn on_jobs(&mut self, jobs: &[MotherJob], now: i64) {
        if !self.bootstrapped {
            self.bootstrap(jobs, now);
            return;
        }
        let restart = std::mem::take(&mut self.restart_check);
        for job in jobs {
            let prev = self.store.jobs.get(&job.id).cloned();
            let events = changes_since(prev.as_ref(), job, restart);
            self.refresh_record(job, now);
            let Some(rec) = self.store.jobs.get_mut(&job.id) else {
                continue;
            };
            let Some(tag) = rec.focus.clone() else {
                // Never notified: unverified, the user's own, or unknown.
                rec.last_notified = Some(job.state.clone());
                if rec.notice.status != NoticeStatus::None
                    || rec.notice.reason != Some(NoticeReason::NotNotifiable)
                {
                    rec.notice.status = NoticeStatus::None;
                    rec.notice.reason = Some(NoticeReason::NotNotifiable);
                    self.touch();
                }
                continue;
            };
            if rec.notice.reason == Some(NoticeReason::NotNotifiable) {
                // An origin upgraded to verified since.
                rec.notice.reason = None;
                self.changed = true;
            }
            let notify = rec.notify;
            // The origin book says the focus is closed (it saw a registry push
            // without it): after a daemon restart no departure is reported for
            // a focus closed meanwhile, so this is how the engine learns it.
            let closed = job
                .nostromo
                .as_ref()
                .is_some_and(|a| a.origin.closed == Some(true));
            if closed && self.closed.insert(tag.clone()) {
                self.drop_all(
                    &tag,
                    NoticeStatus::NotSent,
                    NoticeReason::FocusClosed,
                    Some("focus_closed"),
                    now,
                );
            }
            if prev.is_none() {
                self.note_job_origin(&tag);
            }
            for event in events {
                let snapshot = item_for(job, event);
                self.route(&job.id, &tag, notify, snapshot, event, now);
            }
        }
        self.forget_absent_jobs(now);
    }

    /// First run ever: what is there now was never news to anyone.
    fn bootstrap(&mut self, jobs: &[MotherJob], now: i64) {
        for job in jobs {
            let mut rec = record_for(job, now);
            rec.last_notified = Some(job.state.clone());
            if rec.focus.is_none() {
                rec.notice.reason = Some(NoticeReason::NotNotifiable);
            }
            self.store.jobs.insert(job.id.clone(), rec);
        }
        self.bootstrapped = true;
        self.restart_check = false;
        self.touch();
    }

    /// Bring `job`'s record up to what the feed shows now. A record keeps what
    /// it learned: its notice and accounting.
    fn refresh_record(&mut self, job: &MotherJob, now: i64) {
        let fresh = record_for(job, now);
        match self.store.jobs.get_mut(&job.id) {
            Some(rec) => {
                let moved = rec.state != fresh.state
                    || rec.has_pr != fresh.has_pr
                    || rec.focus != fresh.focus
                    || rec.notify != fresh.notify
                    || rec.snapshot != fresh.snapshot
                    || now - rec.last_seen_ms > HOUR_MS;
                rec.state = fresh.state;
                rec.has_pr = fresh.has_pr;
                rec.focus = fresh.focus;
                rec.notify = fresh.notify;
                rec.snapshot = fresh.snapshot;
                rec.last_seen_ms = now;
                self.dirty |= moved;
            }
            None => {
                self.touch();
                self.store.jobs.insert(job.id.clone(), fresh);
            }
        }
    }

    pub(super) fn pr_event(&mut self, job_id: &str, merged: bool, now: i64) {
        let Some(rec) = self.store.jobs.get_mut(job_id) else {
            return;
        };
        if rec.pr_final == Some(merged) {
            return;
        }
        rec.pr_final = Some(merged);
        self.dirty = true;
        let Some(tag) = rec.focus.clone() else {
            return;
        };
        let event = if merged {
            JobEvent::PrMerged
        } else {
            JobEvent::PrClosed
        };
        let snapshot = item_from(job_id, &rec.snapshot, None);
        let notify = rec.notify;
        self.route(job_id, &tag, notify, snapshot, event, now);
    }
}

// ── routing and delivery ────────────────────────────────────────────────────

impl State {
    /// Send one change of a verified job of `tag` where it belongs.
    fn route(
        &mut self,
        job_id: &str,
        tag: &str,
        notify: Option<NotifyLevel>,
        snapshot: NoticeItem,
        event: JobEvent,
        now: i64,
    ) {
        if self.closed.contains(tag) {
            self.record(
                job_id,
                NoticeStatus::NotSent,
                Some(NoticeReason::FocusClosed),
                &[event],
                false,
                true,
                now,
            );
            return;
        }
        let global = self.store.enabled;
        let focus = self.focus(tag);
        focus.last_seen_ms = now;
        let mode = focus.mode;
        let level = match effective(global, mode, notify) {
            Ok(level) => level,
            Err(reason) => {
                self.record(
                    job_id,
                    NoticeStatus::Dropped,
                    Some(reason),
                    &[event],
                    false,
                    true,
                    now,
                );
                if event.is_waking() {
                    self.audit_dropped(
                        tag,
                        if reason == NoticeReason::GlobalOff {
                            "global_off"
                        } else {
                            "focus_off"
                        },
                    );
                }
                return;
            }
        };
        let due = event.is_waking();
        let bucket = &mut self.focus(tag).bucket;
        if !bucket.add(snapshot, event, due, now) {
            // Already waiting with this state (a restart's re-check): it keeps
            // its window or hold, and no window opens for it again.
            return;
        }
        let states = bucket
            .items
            .iter()
            .find(|p| p.item.job_id == job_id)
            .map(|p| p.item.states.clone())
            .unwrap_or_default();
        let held = wait_for_window(bucket, level, due, now);
        self.touch();
        if let Some((reason, history)) = held {
            self.record(
                job_id,
                NoticeStatus::Held,
                Some(reason),
                &states,
                false,
                history,
                now,
            );
        }
    }

    /// Try to deliver what is due for `tag`.
    fn attempt(&mut self, tag: &str, trigger: Trigger, now: i64) -> Option<Effect> {
        self.clear_to_deliver(tag, trigger, now)
            .then(|| self.hand_over(tag, now))
    }

    /// May what is due for `tag` go now? When not, says why (a hold) or drops
    /// it (a closed focus).
    fn clear_to_deliver(&mut self, tag: &str, trigger: Trigger, now: i64) -> bool {
        let Some(focus) = self.store.focuses.get(tag) else {
            return false;
        };
        let (has_due, chain, chain_held, capped) = (
            focus.bucket.has_due(),
            focus.limits.chain,
            focus.limits.chain_held(),
            focus.limits.capped(now),
        );
        if !has_due {
            return false;
        }
        if self.closed.contains(tag) {
            self.drop_all(
                tag,
                NoticeStatus::NotSent,
                NoticeReason::FocusClosed,
                None,
                now,
            );
            return false;
        }
        if trigger == Trigger::DuringNoticeTurn {
            // Queued behind the notice turn now running, this delivery is the
            // next notice turn: send it only if that one stays within the cap
            // (this turn already counted) and the loop guard even if this turn
            // queues a job. Otherwise it waits for a later turn's start.
            return chain + 1 < limits::CHAIN_LIMIT && !capped;
        }
        if trigger != Trigger::UserTurn {
            if chain_held {
                self.hold(tag, HoldReason::LoopGuard, now);
                return false;
            }
            if capped {
                self.hold(tag, HoldReason::Cap, now);
                return false;
            }
        }
        if self.notice_turns.contains_key(tag) {
            self.hold(tag, HoldReason::Busy, now);
            return false;
        }
        true
    }

    /// Turn what is due for `tag` into the next generation's message.
    fn hand_over(&mut self, tag: &str, now: i64) -> Effect {
        let bucket = &mut self.focus(tag).bucket;
        bucket.gen += 1;
        let gen = bucket.gen;
        let items = bucket.take_items();
        let fresh_items: Vec<NoticeItem> = items.iter().map(|p| p.item.clone()).collect();
        bucket.put_in_flight(items, gen, now);
        let merged_items: Vec<NoticeItem> =
            bucket.untold_inflight().map(|f| f.item.clone()).collect();
        let merged = element::render_message(&merged_items);
        let fresh = element::render_message(&fresh_items);
        bucket.hold = None;
        bucket.window = None;
        for item in &fresh_items {
            self.record(
                &item.job_id,
                NoticeStatus::Held,
                Some(NoticeReason::Busy),
                &item.states,
                false,
                false,
                now,
            );
        }
        self.touch();
        Effect::Deliver {
            tag: tag.to_owned(),
            gen,
            merged,
            fresh,
        }
    }

    /// The outcome of handing generation `gen` to `tag`'s session (`None`: no
    /// live session).
    pub(super) fn delivered(
        &mut self,
        tag: &str,
        gen: u64,
        outcome: Option<NoticeDelivery>,
        now: i64,
    ) {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return;
        };
        match outcome {
            Some(NoticeDelivery::Woke) => {
                let told: Vec<NoticeItem> = focus
                    .bucket
                    .inflight
                    .iter_mut()
                    .filter(|f| f.gen == gen && !f.told)
                    .map(|f| {
                        f.told = true;
                        f.item.clone()
                    })
                    .collect();
                self.told(tag, &told, true, now);
            }
            Some(NoticeDelivery::Queued) => {}
            Some(NoticeDelivery::Replaced) => {
                for f in focus.bucket.inflight.iter_mut().filter(|f| !f.told) {
                    f.gen = gen;
                }
            }
            None => {
                focus.bucket.take_back(|f| f.gen == gen && !f.told);
                self.hold(tag, HoldReason::SessionNotRunning, now);
            }
        }
        self.touch();
    }

    /// `items` reached `tag`'s agent.
    fn told(&mut self, tag: &str, items: &[NoticeItem], wake: bool, now: i64) {
        if items.is_empty() {
            return;
        }
        for item in items {
            self.record(
                &item.job_id,
                NoticeStatus::Told,
                None,
                &item.states,
                wake,
                true,
                now,
            );
        }
        self.audits.push(MotherAuditEvent::JobNoticeDelivered {
            job_ids: items.iter().map(|i| i.job_id.clone()).collect(),
            focus: tag.to_owned(),
            wake,
            combined: items.len(),
        });
    }
}

// ── turns ───────────────────────────────────────────────────────────────────

impl State {
    pub(super) fn on_turn(&mut self, tag: &str, event: &TurnEvent, now: i64) -> Vec<Effect> {
        match event {
            TurnEvent::Started { author } if author.is_notice() => {
                let TurnAuthor::Injected { key, .. } = author else {
                    return Vec::new();
                };
                self.notice_turn_started(tag, gen_of(key).unwrap_or(0), now)
            }
            TurnEvent::Started { author } => {
                // A turn of any other author: a notice turn before it is over.
                self.end_notice_turn(tag);
                self.other_turn_started(tag, matches!(author, TurnAuthor::User), now)
            }
            TurnEvent::Discarded => {
                // The notice turn that "started" was a phantom: the real turn's
                // Started follows. Undo its count; its items stay told.
                if self.notice_turns.remove(tag).is_some() {
                    let limits = &mut self.focus(tag).limits;
                    limits.wakes.pop();
                    self.touch();
                }
                Vec::new()
            }
            TurnEvent::Completed | TurnEvent::Exited => {
                let was_notice = self.end_notice_turn(tag);
                // Only what was due to wake and waited for this notice turn
                // goes now (the session is idle, so it wakes). Quiet and
                // not-running holds never wake: they wait for a turn to start.
                if was_notice && matches!(event, TurnEvent::Completed) {
                    let hold = self
                        .store
                        .focuses
                        .get(tag)
                        .and_then(|f| f.bucket.hold.map(|h| h.reason));
                    if hold == Some(HoldReason::Busy) {
                        return self
                            .attempt(tag, Trigger::AfterTurn, now)
                            .into_iter()
                            .collect();
                    }
                }
                Vec::new()
            }
        }
    }

    /// Generation `gen`'s notice turn started: its items are told, older
    /// untold ones were lost with a cleared queue.
    fn notice_turn_started(&mut self, tag: &str, gen: u64, now: i64) -> Vec<Effect> {
        let mut effects = Vec::new();
        self.notice_turns.insert(tag.to_owned(), false);
        let focus = self.focus(tag);
        focus.limits.note_notice_turn(now);
        let bucket = &mut focus.bucket;
        let told: Vec<NoticeItem> = bucket
            .drain_inflight(|f| f.gen == gen)
            .into_iter()
            .filter(|f| !f.told)
            .map(|f| f.item)
            .collect();
        let lost_any = bucket.take_back(|f| f.gen < gen && !f.told);
        bucket.inflight.retain(|f| f.gen > gen);
        let after_turn = matches!(
            bucket.hold.map(|h| h.reason),
            Some(HoldReason::Quiet | HoldReason::SessionNotRunning)
        );
        self.told(tag, &told, false, now);
        if lost_any {
            // Lost from a cleared queue: they go when this turn ends.
            self.hold(tag, HoldReason::Busy, now);
        } else if after_turn {
            // Quiet and not-running holds go behind any turn that starts, this
            // one included, when that is safe.
            effects.extend(self.attempt(tag, Trigger::DuringNoticeTurn, now));
        }
        self.touch();
        effects
    }

    /// A turn started that no notice began (`user`: the user's own).
    fn other_turn_started(&mut self, tag: &str, user: bool, now: i64) -> Vec<Effect> {
        let mut effects = Vec::new();
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return effects;
        };
        if user && focus.limits.chain > 0 {
            focus.limits.user_turn();
            self.dirty = true;
            self.changed = true;
        }
        // A notice still in flight is left alone: turn events reach the engine
        // after the fact, so it may already be written. One lost to a cleared
        // queue is found at the next notice turn's start (its generation is
        // older) and sent again then.
        let release = match focus.bucket.hold.map(|h| h.reason) {
            None => false,
            Some(_) if user => true,
            Some(r) => matches!(r, HoldReason::Quiet | HoldReason::SessionNotRunning),
        };
        if release {
            let trigger = if user {
                Trigger::UserTurn
            } else {
                Trigger::AfterTurn
            };
            effects.extend(self.attempt(tag, trigger, now));
        }
        effects
    }

    /// End `tag`'s notice turn, if it is in one: grow or end the chain.
    fn end_notice_turn(&mut self, tag: &str) -> bool {
        let Some(born) = self.notice_turns.remove(tag) else {
            return false;
        };
        let limits = &mut self.focus(tag).limits;
        let before = limits.chain;
        limits.notice_turn_ended(born);
        if limits.chain != before {
            self.touch();
        }
        true
    }
}

// ── registry, timers and settings ───────────────────────────────────────────

impl State {
    pub(super) fn on_registry(&mut self, present: &[String], departed: &[String], now: i64) {
        for tag in present {
            self.closed.remove(tag);
            if let Some(focus) = self.store.focuses.get_mut(tag) {
                if now - focus.last_seen_ms > HOUR_MS {
                    focus.last_seen_ms = now;
                    self.dirty = true;
                }
            }
        }
        for tag in departed {
            self.closed.insert(tag.clone());
            self.notice_turns.remove(tag);
            self.drop_all(
                tag,
                NoticeStatus::NotSent,
                NoticeReason::FocusClosed,
                Some("focus_closed"),
                now,
            );
        }
        // Modes of focuses unseen for 90 days go; departed ones keep theirs
        // until then (a recreated focus gets its tag back).
        let before = self.store.focuses.len();
        self.store
            .focuses
            .retain(|_, f| !(now - f.last_seen_ms > FOCUS_UNSEEN_MAX_MS && f.bucket.is_empty()));
        if self.store.focuses.len() != before {
            self.touch();
        }
    }

    pub(super) fn tick(&mut self, now: i64) -> Vec<Effect> {
        let mut effects = Vec::new();
        let tags: Vec<String> = self.store.focuses.keys().cloned().collect();
        for tag in tags {
            self.expire(&tag, now);
            let Some(focus) = self.store.focuses.get_mut(&tag) else {
                continue;
            };
            if focus.bucket.window.is_some_and(|w| now >= w.closes_at()) {
                focus.bucket.window = None;
                effects.extend(self.attempt(&tag, Trigger::Window, now));
                continue;
            }
            let rolled = focus.bucket.hold.map(|h| h.reason) == Some(HoldReason::Cap)
                && !focus.limits.capped(now);
            if rolled {
                if focus.mode == Some(NotifyLevel::Quiet) {
                    // A Quiet focus is never woken: back to "after a turn".
                    self.hold(&tag, HoldReason::Quiet, now);
                } else {
                    effects.extend(self.attempt(&tag, Trigger::CapRolled, now));
                }
            }
        }
        self.forget_absent_jobs(now);
        effects
    }

    /// Drop `tag`'s items (waiting or in flight) older than 24 h.
    fn expire(&mut self, tag: &str, now: i64) {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return;
        };
        let old = |t: i64| now - t > batch::HOLD_MAX_MS;
        let mut gone: Vec<NoticeItem> = Vec::new();
        let (expired, kept): (Vec<batch::Pending>, Vec<batch::Pending>) =
            std::mem::take(&mut focus.bucket.items)
                .into_iter()
                .partition(|p| old(p.updated_ms));
        focus.bucket.items = kept;
        gone.extend(expired.into_iter().map(|p| p.item));
        let expired = focus
            .bucket
            .drain_inflight(|f| old(f.at_ms) || (f.told && now - f.at_ms > HOUR_MS));
        gone.extend(expired.into_iter().filter(|f| !f.told).map(|f| f.item));
        if !focus.bucket.has_due() && focus.bucket.window.is_none() {
            focus.bucket.hold = None;
        }
        if gone.is_empty() {
            return;
        }
        for item in &gone {
            self.record(
                &item.job_id,
                NoticeStatus::Dropped,
                None,
                &item.states,
                false,
                true,
                now,
            );
        }
        self.audit_dropped(tag, "expired");
        self.touch();
    }

    pub(super) fn apply_settings(
        &mut self,
        scope: NoticeScope,
        tag: Option<&str>,
        mode: Option<NotifyLevel>,
        enabled: Option<bool>,
        now: i64,
    ) -> Result<Vec<Effect>, SettingsError> {
        let mut effects = Vec::new();
        match scope {
            NoticeScope::Focus => {
                let (Some(tag), Some(mode)) = (tag.filter(|t| is_tag_like(t)), mode) else {
                    return Err(SettingsError::FocusNeedsTagAndMode);
                };
                let focus = self.focus(tag);
                focus.mode = (mode != NotifyLevel::Wake).then_some(mode);
                focus.last_seen_ms = now;
                match mode {
                    NotifyLevel::Off => {
                        self.drop_all(
                            tag,
                            NoticeStatus::Dropped,
                            NoticeReason::FocusOff,
                            Some("focus_off"),
                            now,
                        );
                        effects.push(Effect::Withdraw {
                            tag: tag.to_owned(),
                        });
                    }
                    NotifyLevel::Quiet => {
                        let bucket = &mut self.focus(tag).bucket;
                        if bucket.window.take().is_some() && bucket.has_due() {
                            self.hold(tag, HoldReason::Quiet, now);
                        }
                    }
                    // Quiet to Wake does not wake for what is held: it goes
                    // after the next turn, as it would have.
                    NotifyLevel::Wake => {}
                }
                self.audits
                    .push(MotherAuditEvent::MotherNoticeSettingsChanged {
                        scope,
                        focus: Some(tag.to_owned()),
                        mode: Some(mode),
                        enabled: None,
                    });
            }
            NoticeScope::Global => {
                let Some(enabled) = enabled else {
                    return Err(SettingsError::GlobalNeedsEnabled);
                };
                self.store.enabled = enabled;
                if !enabled {
                    let tags: Vec<String> = self.store.focuses.keys().cloned().collect();
                    for tag in tags {
                        if self.drop_all(
                            &tag,
                            NoticeStatus::Dropped,
                            NoticeReason::GlobalOff,
                            Some("global_off"),
                            now,
                        ) {
                            effects.push(Effect::Withdraw { tag });
                        }
                    }
                }
                self.audits
                    .push(MotherAuditEvent::MotherNoticeSettingsChanged {
                        scope,
                        focus: None,
                        mode: None,
                        enabled: Some(enabled),
                    });
            }
        }
        self.touch();
        Ok(effects)
    }
}

// ── what the app sees ───────────────────────────────────────────────────────

impl State {
    pub(super) fn focus_states(&self, now: i64) -> Vec<FocusNoticeState> {
        self.store
            .focuses
            .iter()
            .filter(|(_, f)| !f.is_trivial())
            .map(|(tag, f)| {
                let b = &f.bucket;
                let waiting =
                    b.items.iter().filter(|p| p.due).count() + b.untold_inflight().count();
                let reason = match (b.hold, b.window, b.untold_inflight().next()) {
                    (Some(Hold { reason, .. }), _, _) => Some(reason.into()),
                    (None, Some(_), _) => Some(NoticeReason::Batching),
                    (None, None, Some(_)) => Some(NoticeReason::Busy),
                    _ => None,
                };
                FocusNoticeState {
                    tag: tag.clone(),
                    mode: f.mode.unwrap_or(NotifyLevel::Wake),
                    held: reason.filter(|_| waiting > 0).map(|reason| HeldSummary {
                        count: waiting,
                        reason,
                    }),
                    chain_held: f.limits.chain_held(),
                    wakes_by_day: f.limits.wakes_by_day(now),
                }
            })
            .collect()
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────

/// The changes to report for `job`, given the record `prev` of the last look.
/// On the first look after a restart (`restart`), a job that moved without the
/// engine seeing it is reported as its current state, unless that state was
/// already accounted for.
fn changes_since(prev: Option<&JobRecord>, job: &MotherJob, restart: bool) -> Vec<JobEvent> {
    let mut events = detect::changes(
        prev.map(|p| Seen {
            state: &p.state,
            has_pr: p.has_pr,
        }),
        job,
    );
    if restart && events.is_empty() {
        if let Some(p) = prev {
            if p.last_notified.as_deref() != Some(job.state.as_str()) {
                events.extend(JobEvent::from_state(&job.state));
            }
        }
    }
    events
}

/// Open or join the window for a change at `level`, or hold it. Returns the
/// reason the job now waits and whether it earns a history entry.
fn wait_for_window(
    bucket: &mut Bucket,
    level: NotifyLevel,
    due: bool,
    now: i64,
) -> Option<(NoticeReason, bool)> {
    match level {
        NotifyLevel::Wake => {
            if due || bucket.window.is_some() {
                bucket.touch_window(now);
            }
            due.then(|| {
                let reason = match bucket.hold.map(|h| h.reason) {
                    Some(r @ (HoldReason::Cap | HoldReason::LoopGuard)) => r.into(),
                    _ => NoticeReason::Batching,
                };
                (reason, false)
            })
        }
        NotifyLevel::Quiet => {
            // It joins an open window (moving its end) but never opens one.
            if bucket.window.is_some() {
                bucket.touch_window(now);
            }
            due.then(|| {
                bucket.hold_at_least(HoldReason::Quiet, now);
                let reason = bucket
                    .hold
                    .map(|h| h.reason.into())
                    .unwrap_or(NoticeReason::Quiet);
                (reason, true)
            })
        }
        NotifyLevel::Off => None,
    }
}

/// What a notice says about `job`, as of now (title and PR cleaned).
fn snapshot_of(job: &MotherJob) -> Snapshot {
    Snapshot {
        title: element::clean_title(&job.title),
        pr_url: job.pr_url.as_deref().and_then(element::clean_pr),
        cost_usd: job.actual_cost_usd,
    }
}

/// A job's record as the feed shows it now (accounting fields empty).
fn record_for(job: &MotherJob, now: i64) -> JobRecord {
    let focus = job
        .nostromo
        .as_ref()
        .filter(|a| a.origin.kind == OriginKind::Focus)
        .and_then(|a| a.origin.focus_tag.clone());
    JobRecord {
        state: job.state.clone(),
        has_pr: job.pr_url.is_some(),
        last_seen_ms: now,
        last_notified: None,
        focus,
        notify: job.nostromo.as_ref().and_then(|a| a.notify),
        snapshot: snapshot_of(job),
        pr_final: None,
        notice: NoticeView::default(),
    }
}

/// What a notice says about `job` for `event` (states filled in by the batch).
fn item_for(job: &MotherJob, event: JobEvent) -> NoticeItem {
    item_from(&job.id, &snapshot_of(job), element::reason_for(job, event))
}

/// A notice item for `job_id` from its `snapshot` (states filled in by the batch).
fn item_from(job_id: &str, snapshot: &Snapshot, reason: Option<String>) -> NoticeItem {
    NoticeItem {
        job_id: job_id.to_owned(),
        title: snapshot.title.clone(),
        states: Vec::new(),
        pr_url: snapshot.pr_url.clone(),
        cost_usd: snapshot.cost_usd,
        reason,
    }
}
