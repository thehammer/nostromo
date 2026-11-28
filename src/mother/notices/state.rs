//! The engine's state machine: everything computed under its one lock.
//!
//! Three parts, all Jonesy's shape (<https://github.com/thehammer/jonesy>):
//!
//! * **Sources** say what happened. [`MotherSource`] reads the job feed
//!   (`source`); the GitHub source (`jonesy_github::Pulls`) reports a PR's
//!   end. Neither decides who is told.
//! * **Claims** say who hears it: the focus that queued a job claims the job
//!   and, about the job, its PR.
//! * The **hub** ([`jonesy_core::Hub`]) routes each event to the focuses that
//!   claimed its subject and decides when they are told: batch windows, the
//!   switches, holds, the cap, the loop guard. The focus is its actor.
//!
//! What is left here is the edge between Jonesy's vocabulary and this
//! module's: the job records as the hub's host (each job's notice record and
//! the notice text), the audit lines, and the engine's inputs.
//!
//! [`State`] never touches the session, the audit log or the change channel.
//! Its methods record what happened (in the store, `audits`, `dirty` and
//! `changed`) and return [`Effect`]s for the engine to run once the lock is
//! released (see the lock-order note in the module docs).

use std::collections::BTreeMap;

use jonesy_core::{
    Audit, Author, DropWhy, EventItem, Host, Hub, Level, Outcome, Reason, Record, Signal, Source,
    Status, Turn,
};
use jonesy_github::{PullOutcome, Pulls};

use super::detect::JobEvent;
use super::element::{self, job_id_of};
use super::pr_state::{self, PrCandidate};
use super::source::{self, MotherSource};
use super::store::{JobRecord, Store};
use super::{
    gen_of, FocusNoticeState, HeldSummary, NoticeHistoryEntry, NoticeReason, NoticeScope,
    NoticeStatus, SettingsError, HISTORY_MAX,
};
use crate::ipc::session_manager::{NoticeDelivery, TurnAuthor, TurnEvent};
use crate::mother::audit::MotherAuditEvent;
use crate::mother::origin::{is_tag_like, NotifyLevel};

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
            job_ids: subjects
                .iter()
                .filter_map(|s| job_id_of(s))
                .map(str::to_owned)
                .collect(),
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

/// The job records as the hub's host: each job's notice record is where it
/// writes what became of a change, and a job's item is drawn as this module's
/// notice ([`element::render_message`]). An item that is not about a job (no
/// source reports one yet) would be drawn as Jonesy's own element.
struct Jobs<'a>(&'a mut BTreeMap<String, JobRecord>);

impl Host<EventItem> for Jobs<'_> {
    fn status(&self, subject: &str) -> Option<(Status, Option<Reason>)> {
        let view = &self.0.get(job_id_of(subject)?)?.notice;
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
            // The Mother source's own: the hub never set it.
            NoticeReason::NotNotifiable => None,
        });
        Some((status, reason))
    }

    fn record(&mut self, subject: &str, rec: Record<'_, String>) -> bool {
        let Some(job) = job_id_of(subject).and_then(|id| self.0.get_mut(id)) else {
            return false;
        };
        let status = NoticeStatus::from(rec.status);
        let reason = rec.reason.map(NoticeReason::from);
        let states: Vec<JobEvent> = rec
            .states
            .iter()
            .filter_map(|k| JobEvent::from_kind(k))
            .collect();
        let view = &mut job.notice;
        let same = view.status == status && view.reason == reason;
        if same && !rec.history {
            return false;
        }
        view.status = status;
        view.reason = reason;
        if let Some(last) = states.last() {
            view.last_state = Some(*last);
        }
        view.at_ms = Some(rec.at_ms);
        if rec.history {
            view.history.push(NoticeHistoryEntry {
                states,
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

    fn render(&self, items: &[EventItem]) -> String {
        let notices: Vec<_> = items.iter().filter_map(element::notice_item).collect();
        let others: Vec<EventItem> = items
            .iter()
            .filter(|i| job_id_of(&i.subject).is_none())
            .cloned()
            .collect();
        let mut out = element::render_message(&notices);
        if !others.is_empty() {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(&jonesy_core::event::render(&others));
        }
        out
    }
}

pub(super) struct State {
    /// Who hears what, and when: Jonesy's claims and delivery engine.
    hub: Hub,
    /// The job feed as a source, and what it knows of each job.
    mother: MotherSource,
    /// Store snapshots taken, so a write can tell it is stale.
    pub(super) saves: u64,
}

// ── construction and hand-off to the engine ─────────────────────────────────

impl State {
    /// State over a loaded `store`; `existed` is whether its file did.
    pub(super) fn new(store: Store, existed: bool, now: i64) -> Self {
        let mut mother = MotherSource::new(store.jobs, existed);
        // Messages in flight died with the previous daemon's queue: the
        // delivery engine makes them wait for the session's next turn.
        let mut hub = Hub::new(store.enabled, store.focuses, now);
        // Claims are not stored: the records say who queued what.
        let claims = mother.claims();
        hub.apply(&mut Jobs(&mut mother.jobs), claims, now);
        Self {
            hub,
            mother,
            saves: 0,
        }
    }

    /// Everything the store file holds, as of now.
    pub(super) fn store(&self) -> Store {
        Store {
            enabled: self.hub.delivery().enabled(),
            focuses: self.hub.delivery().actors().clone(),
            jobs: self.mother.jobs.clone(),
        }
    }

    /// What is known of each job.
    pub(super) fn jobs(&self) -> &BTreeMap<String, JobRecord> {
        &self.mother.jobs
    }

    /// The global switch.
    pub(super) fn enabled(&self) -> bool {
        self.hub.delivery().enabled()
    }

    /// Does the store need writing? Clears the flag.
    pub(super) fn take_dirty(&mut self) -> bool {
        let delivery = self.hub.delivery_mut().take_dirty();
        self.mother.take_dirty() | delivery
    }

    /// Did something the app or the feed shows change? Clears the flag.
    pub(super) fn take_changed(&mut self) -> bool {
        let delivery = self.hub.delivery_mut().take_changed();
        self.mother.take_changed() | delivery
    }

    /// The audit events recorded since the last call.
    pub(super) fn take_audits(&mut self) -> Vec<MotherAuditEvent> {
        self.hub
            .delivery_mut()
            .take_audits()
            .into_iter()
            .map(audit_of)
            .collect()
    }

    /// `tag` just queued a job, created at `created_ms` when known. It is
    /// notice-born (loop guard) if `tag` is in a notice turn, or if it was
    /// created inside the turn that just ended and the feed showed it late.
    pub(super) fn note_job_origin(&mut self, tag: &str, created_ms: Option<i64>) {
        self.hub.delivery_mut().note_origin(tag, created_ms);
    }

    /// Apply what a source reported.
    fn apply(&mut self, signals: Vec<Signal>, now: i64) {
        self.hub
            .apply(&mut Jobs(&mut self.mother.jobs), signals, now);
    }
}

// ── the sources ─────────────────────────────────────────────────────────────

impl State {
    /// A new job list from the feed: the Mother source says what it means.
    pub(super) fn on_jobs(&mut self, jobs: &[crate::mother::MotherJob], now: i64) {
        let signals = self.mother.ingest(jobs, now);
        self.apply(signals, now);
    }

    /// See `NoticeEngine::pr_candidates`.
    pub(super) fn pr_candidates(&self, now: i64) -> Option<Vec<PrCandidate>> {
        if !self.mother.fed() {
            return None;
        }
        let delivery = self.hub.delivery();
        if !delivery.enabled() {
            return Some(Vec::new());
        }
        let candidates = self
            .mother
            .jobs
            .iter()
            .filter(|(id, rec)| {
                rec.pr_final.is_none()
                    && self.mother.in_feed(id)
                    && rec
                        .finished_ms
                        .is_none_or(|f| now - f < pr_state::TRACK_MAX_MS)
            })
            .filter_map(|(id, rec)| {
                let tag = rec.focus.as_ref().filter(|t| !delivery.is_closed(t))?;
                let mode = delivery.mode_of(tag);
                jonesy_core::effective(true, mode, rec.notify.map(Level::from)).ok()?;
                Some(PrCandidate {
                    job_id: id.clone(),
                    pr_url: rec.snapshot.pr_url.clone()?,
                })
            })
            .collect();
        Some(candidates)
    }

    /// `job_id`'s PR was merged or closed: the GitHub source reports it on the
    /// PR's subject, and the job's focus hears it through its claim on the PR
    /// (about the job), as does the focus of any other job on the same PR.
    pub(super) fn pr_event(&mut self, job_id: &str, merged: bool, now: i64) {
        let Some(rec) = self.mother.jobs.get_mut(job_id) else {
            return;
        };
        // Once merged, nothing more is said; once closed, only a merge is news.
        if rec.pr_final == Some(true) || rec.pr_final == Some(merged) {
            return;
        }
        // The claims as they stood before this outcome (what the PR claim has
        // heard comes from `pr_final`), with the job's snapshot as of now.
        let mut signals = source::claims_of(job_id, rec);
        rec.pr_final = Some(merged);
        self.mother.dirty = true;
        if rec.focus.is_none() {
            return;
        }
        let subject = source::pr_subject(job_id, rec);
        signals.extend(Pulls.ingest(
            PullOutcome {
                subject: &subject,
                merged,
            },
            now,
        ));
        self.apply(signals, now);
        // Another job on the same PR heard it too: its record says so, so a
        // report for that job (or a restart) does not announce it again.
        for claim in self.hub.claims().matching(&subject) {
            let job = claim.about.as_ref().and_then(|a| job_id_of(&a.subject));
            let Some(rec) = job.and_then(|id| self.mother.jobs.get_mut(id)) else {
                continue;
            };
            let heard = claim.heard.map(|s| s >= jonesy_github::STAGE_MERGED);
            if heard.is_some() && rec.pr_final != Some(true) && rec.pr_final != heard {
                rec.pr_final = heard;
                self.mother.dirty = true;
            }
        }
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
        self.hub.delivery_mut().delivered(
            &mut Jobs(&mut self.mother.jobs),
            tag,
            gen,
            outcome.map(Outcome::from),
            now,
        );
    }

    pub(super) fn on_turn(&mut self, tag: &str, event: &TurnEvent, now: i64) -> Vec<Effect> {
        self.hub
            .delivery_mut()
            .on_turn(&mut Jobs(&mut self.mother.jobs), tag, turn_of(event), now)
    }

    pub(super) fn on_registry(&mut self, present: &[String], departed: &[String], now: i64) {
        self.hub.delivery_mut().on_registry(
            &mut Jobs(&mut self.mother.jobs),
            present,
            departed,
            now,
        );
    }

    pub(super) fn tick(&mut self, now: i64) -> Vec<Effect> {
        let effects = self
            .hub
            .delivery_mut()
            .tick(&mut Jobs(&mut self.mother.jobs), now);
        let forgotten = self.mother.forget_absent(now);
        self.apply(forgotten, now);
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
        let host = &mut Jobs(&mut self.mother.jobs);
        let delivery = self.hub.delivery_mut();
        match scope {
            NoticeScope::Focus => {
                let (Some(tag), Some(mode)) = (tag.filter(|t| is_tag_like(t)), mode) else {
                    return Err(SettingsError::FocusNeedsTagAndMode);
                };
                Ok(delivery.set_actor_mode(host, tag, mode.into(), now))
            }
            NoticeScope::Global => {
                let Some(enabled) = enabled else {
                    return Err(SettingsError::GlobalNeedsEnabled);
                };
                Ok(delivery.set_enabled(host, enabled, now))
            }
        }
    }
}

// ── what the app sees ───────────────────────────────────────────────────────

impl State {
    pub(super) fn focus_states(&self, now: i64) -> Vec<FocusNoticeState> {
        self.hub
            .delivery()
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
