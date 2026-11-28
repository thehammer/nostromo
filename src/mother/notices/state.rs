//! The engine's state machine: everything computed under its one lock.
//!
//! Two halves. What this module knows about Mother (which jobs exist, what
//! changed about each since the last look, which focus queued it, what was
//! already accounted for) lives here. When and how a focus is told (batch
//! windows, the switches, holds, the cap, the loop guard, what waits and what
//! is in flight) is Jonesy's delivery engine ([`jonesy_core::Delivery`]), with
//! the focus as its actor and the job as its subject.
//!
//! [`State`] never touches the session, the audit log or the change channel.
//! Its methods record what happened (in the store, `audits`, `dirty` and
//! `changed`) and return [`Effect`]s for the engine to run once the lock is
//! released (see the lock-order note in the module docs).

use std::collections::{BTreeMap, HashSet};

use jonesy_core::{
    Audit, Author, Delivery, DropWhy, Host, Level, Outcome, Reason, Record, Status, Turn,
};

use super::detect::{self, JobEvent, Seen};
use super::element::{self, NoticeItem};
use super::limits::HOUR_MS;
use super::pr_state::{self, PrCandidate};
use super::store::{JobRecord, Snapshot, Store};
use super::{
    gen_of, FocusNoticeState, HeldSummary, NoticeHistoryEntry, NoticeReason, NoticeScope,
    NoticeStatus, NoticeView, SettingsError, HISTORY_MAX, JOB_ABSENT_MAX_MS,
};
use crate::ipc::session_manager::{NoticeDelivery, TurnAuthor, TurnEvent};
use crate::mother::audit::MotherAuditEvent;
use crate::mother::origin::{is_tag_like, NotifyLevel, OriginKind};
use crate::mother::MotherJob;

/// Something to do once the engine's lock is released: Jonesy's, with the
/// focus tag as `actor`.
pub(super) use jonesy_core::Effect;

// ── Jonesy's vocabulary and this module's ───────────────────────────────────

impl From<NotifyLevel> for Level {
    fn from(l: NotifyLevel) -> Self {
        match l {
            NotifyLevel::Wake => Self::Wake,
            NotifyLevel::Quiet => Self::Quiet,
            NotifyLevel::Off => Self::Off,
        }
    }
}

impl From<Level> for NotifyLevel {
    fn from(l: Level) -> Self {
        match l {
            Level::Wake => Self::Wake,
            Level::Quiet => Self::Quiet,
            Level::Off => Self::Off,
        }
    }
}

impl From<Status> for NoticeStatus {
    fn from(s: Status) -> Self {
        match s {
            Status::Told => Self::Told,
            Status::Held => Self::Held,
            Status::Dropped => Self::Dropped,
            Status::NotSent => Self::NotSent,
            Status::None => Self::None,
        }
    }
}

impl From<Reason> for NoticeReason {
    fn from(r: Reason) -> Self {
        match r {
            Reason::Batching => Self::Batching,
            Reason::Busy => Self::Busy,
            Reason::Cap => Self::Cap,
            Reason::LoopGuard => Self::LoopGuard,
            Reason::SessionNotRunning => Self::SessionNotRunning,
            Reason::Quiet => Self::Quiet,
            Reason::ActorOff => Self::FocusOff,
            Reason::GlobalOff => Self::GlobalOff,
            Reason::ActorClosed => Self::FocusClosed,
        }
    }
}

impl From<NoticeDelivery> for Outcome {
    fn from(d: NoticeDelivery) -> Self {
        match d {
            NoticeDelivery::Woke => Self::Woke,
            NoticeDelivery::Queued => Self::Queued,
            NoticeDelivery::Replaced => Self::Replaced,
        }
    }
}

/// The session's turn event as the delivery engine names it: a turn whose
/// message is a notice is an event turn of that notice's generation.
fn turn_of(event: &TurnEvent) -> Turn {
    match event {
        TurnEvent::Started { author } => Turn::Started {
            author: match author {
                TurnAuthor::Injected { key, .. } if author.is_notice() => Author::Event {
                    gen: gen_of(key).unwrap_or(0),
                },
                TurnAuthor::User => Author::User,
                _ => Author::Other,
            },
        },
        TurnEvent::Completed => Turn::Completed,
        TurnEvent::Exited => Turn::Exited,
        TurnEvent::Discarded => Turn::Discarded,
    }
}

/// The audit line for something the delivery engine did.
fn audit_of(audit: Audit) -> MotherAuditEvent {
    match audit {
        Audit::Delivered {
            subjects,
            actor,
            wake,
        } => MotherAuditEvent::JobNoticeDelivered {
            combined: subjects.len(),
            job_ids: subjects,
            focus: actor,
            wake,
        },
        Audit::Held { actor, reason } => MotherAuditEvent::JobNoticeHeld {
            focus: actor,
            reason: reason.into(),
        },
        Audit::Dropped { actor, why } => MotherAuditEvent::JobNoticeDropped {
            focus: actor,
            reason: match why {
                DropWhy::ActorOff => "focus_off",
                DropWhy::GlobalOff => "global_off",
                DropWhy::ActorClosed => "focus_closed",
                DropWhy::Expired => "expired",
            },
        },
        Audit::ActorModeSet { actor, mode } => MotherAuditEvent::MotherNoticeSettingsChanged {
            scope: NoticeScope::Focus,
            focus: Some(actor),
            mode: Some(mode.into()),
            enabled: None,
        },
        Audit::EnabledSet { enabled } => MotherAuditEvent::MotherNoticeSettingsChanged {
            scope: NoticeScope::Global,
            focus: None,
            mode: None,
            enabled: Some(enabled),
        },
    }
}

/// The job records as the delivery engine's host: each job's notice record
/// is where it writes what became of a change, and the notice text is this
/// module's ([`element::render_message`]).
struct Jobs<'a>(&'a mut BTreeMap<String, JobRecord>);

impl Host<NoticeItem> for Jobs<'_> {
    fn status(&self, subject: &str) -> Option<(Status, Option<Reason>)> {
        let view = &self.0.get(subject)?.notice;
        let status = match view.status {
            NoticeStatus::Told => Status::Told,
            NoticeStatus::Held => Status::Held,
            NoticeStatus::Dropped => Status::Dropped,
            NoticeStatus::NotSent => Status::NotSent,
            NoticeStatus::None => Status::None,
        };
        let reason = view.reason.and_then(|r| match r {
            NoticeReason::Batching => Some(Reason::Batching),
            NoticeReason::Busy => Some(Reason::Busy),
            NoticeReason::Cap => Some(Reason::Cap),
            NoticeReason::LoopGuard => Some(Reason::LoopGuard),
            NoticeReason::SessionNotRunning => Some(Reason::SessionNotRunning),
            NoticeReason::Quiet => Some(Reason::Quiet),
            NoticeReason::FocusOff => Some(Reason::ActorOff),
            NoticeReason::GlobalOff => Some(Reason::GlobalOff),
            NoticeReason::FocusClosed => Some(Reason::ActorClosed),
            // This module's own: the delivery engine never set it.
            NoticeReason::NotNotifiable => None,
        });
        Some((status, reason))
    }

    fn record(&mut self, subject: &str, rec: Record<'_, JobEvent>) -> bool {
        let Some(job) = self.0.get_mut(subject) else {
            return false;
        };
        let status = NoticeStatus::from(rec.status);
        let reason = rec.reason.map(NoticeReason::from);
        let view = &mut job.notice;
        let same = view.status == status && view.reason == reason;
        if same && !rec.history {
            return false;
        }
        view.status = status;
        view.reason = reason;
        if let Some(last) = rec.states.last() {
            view.last_state = Some(*last);
        }
        view.at_ms = Some(rec.at_ms);
        if rec.history {
            view.history.push(NoticeHistoryEntry {
                states: rec.states.to_vec(),
                status,
                reason,
                wake: rec.wake,
                at_ms: rec.at_ms,
            });
            let excess = view.history.len().saturating_sub(HISTORY_MAX);
            view.history.drain(..excess);
        }
        if matches!(
            status,
            NoticeStatus::Told | NoticeStatus::Dropped | NoticeStatus::NotSent
        ) {
            job.accounted_state = Some(job.state.clone());
        }
        true
    }

    fn render(&self, items: &[NoticeItem]) -> String {
        element::render_message(items)
    }
}

pub(super) struct State {
    /// When and how each focus is told: Jonesy's delivery engine.
    delivery: Delivery<NoticeItem>,
    /// What is known of each job (`Store::jobs`).
    pub(super) jobs: BTreeMap<String, JobRecord>,
    /// The store existed (or the engine has looked at the feed once).
    bootstrapped: bool,
    /// The first look after loading compares each job with what was last
    /// accounted for (R9).
    restart_check: bool,
    /// The feed was seen at least once since this engine started.
    fed: bool,
    /// The jobs in the newest feed (a job not in it has left the feed).
    in_feed: HashSet<String>,
    /// Store snapshots taken, so a write can tell it is stale.
    pub(super) saves: u64,
    /// The store needs writing.
    dirty: bool,
    /// Something the app or the feed shows changed.
    changed: bool,
}

// ── construction and hand-off to the engine ─────────────────────────────────

impl State {
    /// State over a loaded `store`; `existed` is whether its file did.
    pub(super) fn new(mut store: Store, existed: bool, now: i64) -> Self {
        // A store written before `accounted_state` kept an event token where
        // Mother's state belongs: unknown, so never announce from it.
        let mut migrated = false;
        for rec in store.jobs.values_mut() {
            if rec.last_notified.take().is_some() {
                migrated = true;
                if rec.accounted_state.is_none() {
                    rec.accounted_state = Some(rec.state.clone());
                }
            }
        }
        Self {
            // Messages in flight died with the previous daemon's queue: the
            // delivery engine makes them wait for the session's next turn.
            delivery: Delivery::new(store.enabled, store.focuses, now),
            jobs: store.jobs,
            bootstrapped: existed,
            restart_check: existed,
            fed: false,
            in_feed: HashSet::new(),
            saves: 0,
            dirty: migrated,
            changed: false,
        }
    }

    /// Everything the store file holds, as of now.
    pub(super) fn store(&self) -> Store {
        Store {
            enabled: self.delivery.enabled(),
            focuses: self.delivery.actors().clone(),
            jobs: self.jobs.clone(),
        }
    }

    /// The global switch.
    pub(super) fn enabled(&self) -> bool {
        self.delivery.enabled()
    }

    /// Does the store need writing? Clears the flag.
    pub(super) fn take_dirty(&mut self) -> bool {
        let delivery = self.delivery.take_dirty();
        std::mem::take(&mut self.dirty) | delivery
    }

    /// Did something the app or the feed shows change? Clears the flag.
    pub(super) fn take_changed(&mut self) -> bool {
        let delivery = self.delivery.take_changed();
        std::mem::take(&mut self.changed) | delivery
    }

    /// The audit events recorded since the last call.
    pub(super) fn take_audits(&mut self) -> Vec<MotherAuditEvent> {
        self.delivery
            .take_audits()
            .into_iter()
            .map(audit_of)
            .collect()
    }

    /// `tag` just queued a job, created at `created_ms` when known. It is
    /// notice-born (loop guard) if `tag` is in a notice turn, or if it was
    /// created inside the turn that just ended and the feed showed it late.
    pub(super) fn note_job_origin(&mut self, tag: &str, created_ms: Option<i64>) {
        self.delivery.note_origin(tag, created_ms);
    }

    /// The store needs writing and the app or feed should hear of it.
    fn touch(&mut self) {
        self.dirty = true;
        self.changed = true;
    }

    /// Forget jobs gone from the feed for a week.
    fn forget_absent_jobs(&mut self, now: i64) {
        let before = self.jobs.len();
        self.jobs
            .retain(|_, r| now - r.last_seen_ms <= JOB_ABSENT_MAX_MS);
        if self.jobs.len() != before {
            self.dirty = true;
        }
    }
}

// ── the feed ────────────────────────────────────────────────────────────────

impl State {
    pub(super) fn on_jobs(&mut self, jobs: &[MotherJob], now: i64) {
        self.fed = true;
        self.in_feed = jobs.iter().map(|j| j.id.clone()).collect();
        if !self.bootstrapped {
            self.bootstrap(jobs, now);
            return;
        }
        let restart = std::mem::take(&mut self.restart_check);
        for job in jobs {
            let prev = self.jobs.get(&job.id).cloned();
            let events = changes_since(prev.as_ref(), job, restart);
            self.refresh_record(job, now);
            let Some(rec) = self.jobs.get_mut(&job.id) else {
                continue;
            };
            let Some(tag) = rec.focus.clone() else {
                // Never notified: unverified, the user's own, or unknown.
                rec.accounted_state = Some(job.state.clone());
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
            if closed {
                self.delivery
                    .close_actor(&mut Jobs(&mut self.jobs), &tag, now);
            }
            if prev.is_none() {
                let created = job.created_at.map(|t| t.timestamp_millis());
                self.note_job_origin(&tag, created);
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
            rec.accounted_state = Some(job.state.clone());
            if rec.focus.is_none() {
                rec.notice.reason = Some(NoticeReason::NotNotifiable);
            }
            self.jobs.insert(job.id.clone(), rec);
        }
        self.bootstrapped = true;
        self.restart_check = false;
        self.touch();
    }

    /// Bring `job`'s record up to what the feed shows now. A record keeps what
    /// it learned: its notice and accounting.
    fn refresh_record(&mut self, job: &MotherJob, now: i64) {
        let fresh = record_for(job, now);
        match self.jobs.get_mut(&job.id) {
            Some(rec) => {
                let moved = rec.state != fresh.state
                    || rec.has_pr != fresh.has_pr
                    || rec.focus != fresh.focus
                    || rec.finished_ms != fresh.finished_ms
                    || rec.notify != fresh.notify
                    || rec.snapshot != fresh.snapshot
                    || now - rec.last_seen_ms > HOUR_MS;
                rec.state = fresh.state;
                rec.has_pr = fresh.has_pr;
                rec.finished_ms = fresh.finished_ms;
                rec.focus = fresh.focus;
                rec.notify = fresh.notify;
                rec.snapshot = fresh.snapshot;
                rec.last_seen_ms = now;
                self.dirty |= moved;
            }
            None => {
                self.touch();
                self.jobs.insert(job.id.clone(), fresh);
            }
        }
    }

    /// See `NoticeEngine::pr_candidates`.
    pub(super) fn pr_candidates(&self, now: i64) -> Option<Vec<PrCandidate>> {
        if !self.fed {
            return None;
        }
        if !self.delivery.enabled() {
            return Some(Vec::new());
        }
        let candidates = self
            .jobs
            .iter()
            .filter(|(id, rec)| {
                rec.pr_final.is_none()
                    && self.in_feed.contains(*id)
                    && rec
                        .finished_ms
                        .is_none_or(|f| now - f < pr_state::TRACK_MAX_MS)
            })
            .filter_map(|(id, rec)| {
                let tag = rec.focus.as_ref().filter(|t| !self.delivery.is_closed(t))?;
                let mode = self.delivery.mode_of(tag);
                jonesy_core::effective(true, mode, rec.notify.map(Level::from)).ok()?;
                Some(PrCandidate {
                    job_id: id.clone(),
                    pr_url: rec.snapshot.pr_url.clone()?,
                })
            })
            .collect();
        Some(candidates)
    }

    pub(super) fn pr_event(&mut self, job_id: &str, merged: bool, now: i64) {
        let Some(rec) = self.jobs.get_mut(job_id) else {
            return;
        };
        // Once merged, nothing more is said; once closed, only a merge is news.
        if rec.pr_final == Some(true) || rec.pr_final == Some(merged) {
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
        self.delivery.route(
            &mut Jobs(&mut self.jobs),
            job_id,
            tag,
            notify.map(Level::from),
            snapshot,
            event,
            event.is_waking(),
            now,
        );
    }
}

// ── turns, registry, timers and settings ────────────────────────────────────

impl State {
    /// The outcome of handing generation `gen` to `tag`'s session (`None`: no
    /// live session).
    pub(super) fn delivered(
        &mut self,
        tag: &str,
        gen: u64,
        outcome: Option<NoticeDelivery>,
        now: i64,
    ) {
        self.delivery.delivered(
            &mut Jobs(&mut self.jobs),
            tag,
            gen,
            outcome.map(Outcome::from),
            now,
        );
    }

    pub(super) fn on_turn(&mut self, tag: &str, event: &TurnEvent, now: i64) -> Vec<Effect> {
        self.delivery
            .on_turn(&mut Jobs(&mut self.jobs), tag, turn_of(event), now)
    }

    pub(super) fn on_registry(&mut self, present: &[String], departed: &[String], now: i64) {
        self.delivery
            .on_registry(&mut Jobs(&mut self.jobs), present, departed, now);
    }

    pub(super) fn tick(&mut self, now: i64) -> Vec<Effect> {
        let effects = self.delivery.tick(&mut Jobs(&mut self.jobs), now);
        self.forget_absent_jobs(now);
        effects
    }

    pub(super) fn apply_settings(
        &mut self,
        scope: NoticeScope,
        tag: Option<&str>,
        mode: Option<NotifyLevel>,
        enabled: Option<bool>,
        now: i64,
    ) -> Result<Vec<Effect>, SettingsError> {
        let host = &mut Jobs(&mut self.jobs);
        match scope {
            NoticeScope::Focus => {
                let (Some(tag), Some(mode)) = (tag.filter(|t| is_tag_like(t)), mode) else {
                    return Err(SettingsError::FocusNeedsTagAndMode);
                };
                Ok(self.delivery.set_actor_mode(host, tag, mode.into(), now))
            }
            NoticeScope::Global => {
                let Some(enabled) = enabled else {
                    return Err(SettingsError::GlobalNeedsEnabled);
                };
                Ok(self.delivery.set_enabled(host, enabled, now))
            }
        }
    }
}

// ── what the app sees ───────────────────────────────────────────────────────

impl State {
    pub(super) fn focus_states(&self, now: i64) -> Vec<FocusNoticeState> {
        self.delivery
            .actor_states(now)
            .into_iter()
            .map(|a| FocusNoticeState {
                tag: a.actor,
                mode: a.mode.into(),
                held: a.held.map(|h| HeldSummary {
                    count: h.count,
                    reason: h.reason.into(),
                }),
                chain_held: a.chain_held,
                wakes_by_day: a.wakes_by_day,
            })
            .collect()
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────

/// The changes to report for `job`, given the record `prev` of the last look.
/// On the first look after a restart (`restart`), a job that moved without the
/// engine seeing it is reported as its current state, unless that state was
/// already accounted for (the state in the record, not the last event).
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
            if p.accounted_state.as_deref() != Some(job.state.as_str()) {
                events.extend(JobEvent::from_state(&job.state));
            }
        }
    }
    events
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
        finished_ms: job.finished_at.map(|t| t.timestamp_millis()),
        accounted_state: None,
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
