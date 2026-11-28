//! Mother as a Jonesy source: what the job feed means.
//!
//! [`MotherSource`] is fed each job list the feed publishes and reports, as
//! Jonesy [`Signal`]s, what the delivery side needs to know and nothing about
//! who is told when:
//!
//! * a **claim** for every job a verified focus queued (the focus hears about
//!   the job, at the job's `notify` level) and one on the job's PR, *about*
//!   the job, so a PR outcome from the GitHub source is told as a change of
//!   the job;
//! * an **event** for every change to such a job since the last look
//!   ([`detect`]);
//! * that a focus **caused** a job (the loop guard), or is **closed**.
//!
//! It keeps what it knows of each job ([`JobRecord`]: the state last seen and
//! last accounted for, the focus, the snapshot a notice shows), so the first
//! run announces nothing and a restart announces a change exactly once. The
//! same records hold each job's notice record, which the delivery engine
//! writes through its host (`state::Jobs`).

use std::collections::{BTreeMap, HashSet};

use jonesy_core::{About, Claim, Event, Signal, Source};

use super::detect::{self, JobEvent, Seen};
use super::element::{self, facts_of, job_subject};
use super::limits::HOUR_MS;
use super::store::{JobRecord, Snapshot};
use super::{NoticeReason, NoticeStatus, NoticeView, JOB_ABSENT_MAX_MS};
use crate::mother::origin::OriginKind;
use crate::mother::MotherJob;

/// [`Event::source`] of a job's changes.
pub(super) const SOURCE: &str = "mother";

/// The subject of `job_id`'s PR: the pull request's own when its URL is one
/// the GitHub source knows, else one under the job (a PR that is not on
/// GitHub, or none yet).
pub(super) fn pr_subject(job_id: &str, rec: &JobRecord) -> String {
    rec.snapshot
        .pr_url
        .as_deref()
        .and_then(jonesy_github::pull_subject_from_url)
        .unwrap_or_else(|| format!("{}/pr", job_subject(job_id)))
}

/// The stage of a PR outcome already announced for a job (`pr_final`).
fn heard_of(pr_final: Option<bool>) -> Option<u8> {
    pr_final.map(|merged| {
        if merged {
            jonesy_github::STAGE_MERGED
        } else {
            jonesy_github::STAGE_CLOSED
        }
    })
}

/// The claims `job_id`'s focus holds because of the job: on the job, and on
/// its PR about the job. None for a job no verified focus queued.
pub(super) fn claims_of(job_id: &str, rec: &JobRecord) -> Vec<Signal> {
    let Some(tag) = rec.focus.as_deref() else {
        return Vec::new();
    };
    let level = rec.notify.map(Into::into);
    let job = job_subject(job_id);
    vec![
        Signal::Claim(Claim {
            level,
            ..Claim::new(tag, job.clone())
        }),
        Signal::Claim(Claim {
            level,
            about: Some(About {
                subject: job,
                facts: snapshot_facts(&rec.snapshot, None),
            }),
            heard: heard_of(rec.pr_final),
            ..Claim::new(tag, pr_subject(job_id, rec))
        }),
    ]
}

fn snapshot_facts(snapshot: &Snapshot, reason: Option<&str>) -> jonesy_core::Facts {
    facts_of(
        &snapshot.title,
        snapshot.pr_url.as_deref(),
        snapshot.cost_usd,
        reason,
    )
}

pub(super) struct MotherSource {
    /// What is known of each job (`Store::jobs`).
    pub(super) jobs: BTreeMap<String, JobRecord>,
    /// The store existed (or the source has looked at the feed once).
    bootstrapped: bool,
    /// The first look after loading compares each job with what was last
    /// accounted for (R9).
    restart_check: bool,
    /// The feed was seen at least once since this source started.
    fed: bool,
    /// The jobs in the newest feed (a job not in it has left the feed).
    in_feed: HashSet<String>,
    /// The job records need writing.
    pub(super) dirty: bool,
    /// Something the app or the feed shows changed.
    changed: bool,
}

impl MotherSource {
    /// A source over the stored job records; `existed` is whether the store's
    /// file did.
    pub(super) fn new(mut jobs: BTreeMap<String, JobRecord>, existed: bool) -> Self {
        // A store written before `accounted_state` kept an event token where
        // Mother's state belongs: unknown, so never announce from it.
        let mut migrated = false;
        for rec in jobs.values_mut() {
            if rec.last_notified.take().is_some() {
                migrated = true;
                if rec.accounted_state.is_none() {
                    rec.accounted_state = Some(rec.state.clone());
                }
            }
        }
        Self {
            jobs,
            bootstrapped: existed,
            restart_check: existed,
            fed: false,
            in_feed: HashSet::new(),
            dirty: migrated,
            changed: false,
        }
    }

    /// Every claim the stored records imply (claims are kept in memory: this
    /// is how they come back after a restart, before the feed is seen).
    pub(super) fn claims(&self) -> Vec<Signal> {
        self.jobs
            .iter()
            .flat_map(|(id, rec)| claims_of(id, rec))
            .collect()
    }

    /// Was the feed seen since this source started?
    pub(super) fn fed(&self) -> bool {
        self.fed
    }

    /// Is `job_id` in the newest feed?
    pub(super) fn in_feed(&self, job_id: &str) -> bool {
        self.in_feed.contains(job_id)
    }

    /// Do the job records need writing? Clears the flag.
    pub(super) fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    /// Did something the app or the feed shows change? Clears the flag.
    pub(super) fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    fn touch(&mut self) {
        self.dirty = true;
        self.changed = true;
    }

    /// Forget jobs gone from the feed for a week, and the claims on them.
    pub(super) fn forget_absent(&mut self, now: i64) -> Vec<Signal> {
        let gone: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, r)| now - r.last_seen_ms > JOB_ABSENT_MAX_MS)
            .map(|(id, _)| id.clone())
            .collect();
        for id in &gone {
            self.jobs.remove(id);
            self.dirty = true;
        }
        gone.iter()
            .map(|id| Signal::Forget {
                subject: job_subject(id),
            })
            .collect()
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
}

impl Source for MotherSource {
    /// A job list from the feed (annotated with origins).
    type Input<'a> = &'a [MotherJob];

    fn id(&self) -> &str {
        SOURCE
    }

    fn ingest(&mut self, jobs: &[MotherJob], now: i64) -> Vec<Signal> {
        self.fed = true;
        self.in_feed = jobs.iter().map(|j| j.id.clone()).collect();
        if !self.bootstrapped {
            self.bootstrap(jobs, now);
            return self.claims();
        }
        let mut out = Vec::new();
        let restart = std::mem::take(&mut self.restart_check);
        for job in jobs {
            let prev = self.jobs.get(&job.id).cloned();
            let events = changes_since(prev.as_ref(), job, restart);
            self.refresh_record(job, now);
            let Some(rec) = self.jobs.get_mut(&job.id) else {
                continue;
            };
            // A job whose focus or PR changed holds different claims: the old
            // ones go, and the ones it holds now are asserted below.
            let reshaped = prev.as_ref().is_some_and(|p| {
                p.focus != rec.focus || pr_subject(&job.id, p) != pr_subject(&job.id, rec)
            });
            if reshaped {
                out.push(Signal::Forget {
                    subject: job_subject(&job.id),
                });
            }
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
            // The origin book says the focus is closed (it saw a registry push
            // without it): after a daemon restart no departure is reported for
            // a focus closed meanwhile, so this is how the engine learns it.
            let closed = job
                .nostromo
                .as_ref()
                .is_some_and(|a| a.origin.closed == Some(true));
            if closed {
                out.push(Signal::ActorClosed { actor: tag.clone() });
            }
            if prev.is_none() {
                out.push(Signal::Caused {
                    actor: tag,
                    at_ms: job.created_at.map(|t| t.timestamp_millis()),
                });
            }
            out.extend(claims_of(&job.id, rec));
            let snapshot = rec.snapshot.clone();
            for event in events {
                let reason = element::reason_for(job, event);
                out.push(Signal::Event(Event {
                    source: SOURCE.to_owned(),
                    kind: event.kind().to_owned(),
                    subject: job_subject(&job.id),
                    time_ms: now,
                    facts: snapshot_facts(&snapshot, reason.as_deref()),
                    content: None,
                    waking: event.is_waking(),
                    stage: None,
                }));
            }
        }
        out.extend(self.forget_absent(now));
        out
    }
}

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
