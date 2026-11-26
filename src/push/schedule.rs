//! When a notification is sent (W13): a pure state machine per device, driven by
//! an injected clock (`now` is passed in; nothing here reads the time), so tests
//! run on a fabricated timeline.
//!
//! One notification per item over its lifetime; a grace delay for Mother and
//! review items; a decision's own timing (S7a); burst coalescing with exact
//! lookahead (S2); per-device quiet hours; the morning and evening summaries;
//! per-kind switches; and withdrawal when an item leaves the waiting set.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Utc};
use chrono_tz::Tz;

use crate::push::items::{Detail, ItemKey, Waiting};
use crate::push::wire::{Presence, PushOutcome, PushPrefs, QuietHours};

/// A Summary replaces the individual notifications of this many grace items
/// (or more) that come due within one grace delay.
pub const BURST_THRESHOLD: usize = 4;
/// A daily summary later than this after its time is skipped (the daemon slept).
const SUMMARY_LATE_LIMIT: Duration = Duration::minutes(10);

#[derive(Debug, Clone, Copy)]
pub struct ScheduleCfg {
    /// Mother and review items wait this long before they are pushed.
    pub grace: Duration,
    /// A decision waits this long when the Mac is in use.
    pub decision_grace: Duration,
}

impl Default for ScheduleCfg {
    fn default() -> Self {
        Self {
            grace: Duration::seconds(120),
            decision_grace: Duration::seconds(30),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SummaryReason {
    Burst,
    Morning,
    Evening,
}

/// What the engine should do now for one device.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Send this item's own notification.
    Alert(Waiting),
    /// Send a Summary of everything waiting. For a burst, `covered` are the
    /// items it replaces (each is logged as coalesced); empty otherwise.
    Summary {
        reason: SummaryReason,
        covered: Vec<Waiting>,
    },
    /// The item left the waiting set. With `had_notification` the delivered
    /// notification is replaced in place; without, only the badge is corrected.
    Withdraw {
        item: Waiting,
        had_notification: bool,
    },
    /// Nothing is sent; the attempt is only logged.
    Log { item: Waiting, outcome: PushOutcome },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    /// Waiting out its grace delay.
    Pending,
    /// Its own notification was sent.
    Notified,
    /// Covered by a Summary.
    Coalesced,
    /// Due during quiet hours: never pushed individually.
    HeldQuiet,
    /// Counted in badge and summaries only: already waiting when the device
    /// (or the daemon) started, or a count-only item.
    Counted,
}

#[derive(Debug, Clone)]
struct Tracked {
    item: Waiting,
    first_seen: DateTime<Utc>,
    status: Status,
}

impl Tracked {
    fn start(&self) -> DateTime<Utc> {
        self.item.start.unwrap_or(self.first_seen)
    }

    /// When the item is due: a decision at once if its Mac is away, else after
    /// the decision grace; anything else after the grace delay.
    fn due_at(&self, cfg: &ScheduleCfg) -> DateTime<Utc> {
        match &self.item.detail {
            Detail::Decision { presence, .. } => {
                if *presence == Some(Presence::Away) {
                    self.start()
                } else {
                    self.start() + cfg.decision_grace
                }
            }
            _ => self.start() + cfg.grace,
        }
    }

    fn is_decision(&self) -> bool {
        matches!(self.item.detail, Detail::Decision { .. })
    }
}

/// One device's schedule.
#[derive(Debug, Default)]
pub struct DeviceSchedule {
    items: BTreeMap<ItemKey, Tracked>,
    last_morning: Option<NaiveDate>,
    last_evening: Option<NaiveDate>,
}

impl DeviceSchedule {
    pub fn new() -> Self {
        Self::default()
    }

    /// Advance to `now` given everything waiting (every kind; the device's own
    /// switches are applied here). While `baseline` is true (this device's
    /// first step), items first seen are counted but never pushed: they were
    /// already waiting before the device registered, and count as already
    /// notified, like an item marked `preexisting` by the engine.
    pub fn step(
        &mut self,
        now: DateTime<Utc>,
        waiting: &[Waiting],
        prefs: &PushPrefs,
        cfg: &ScheduleCfg,
        baseline: bool,
    ) -> Vec<Effect> {
        let mut fx = Vec::new();
        let live: Vec<&Waiting> = waiting.iter().filter(|w| !expired(w, now)).collect();
        let present: BTreeSet<&ItemKey> = live.iter().map(|w| &w.key).collect();

        // 1. Items that left the waiting set.
        let gone: Vec<ItemKey> = self
            .items
            .keys()
            .filter(|k| !present.contains(k))
            .cloned()
            .collect();
        for key in gone {
            let Some(t) = self.items.remove(&key) else {
                continue;
            };
            if !prefs.kinds.enabled(key.kind()) {
                continue;
            }
            match t.status {
                Status::Pending => fx.push(Effect::Log {
                    item: t.item,
                    outcome: PushOutcome::SkippedResolvedInGrace,
                }),
                Status::Notified => fx.push(Effect::Withdraw {
                    item: t.item,
                    had_notification: true,
                }),
                Status::Coalesced | Status::HeldQuiet | Status::Counted => {
                    fx.push(Effect::Withdraw {
                        item: t.item,
                        had_notification: false,
                    })
                }
            }
        }

        // 2. New items; a snapshot refresh for known ones (presence, deadline).
        for w in &live {
            match self.items.get_mut(&w.key) {
                Some(t) => t.item = (*w).clone(),
                None => {
                    let status = if baseline || w.preexisting || w.is_count_only() {
                        Status::Counted
                    } else {
                        Status::Pending
                    };
                    self.items.insert(
                        w.key.clone(),
                        Tracked {
                            item: (*w).clone(),
                            first_seen: now,
                            status,
                        },
                    );
                }
            }
        }

        // 3. What is due.
        let tz = parse_tz(&prefs.tz);
        let local = now.with_timezone(&tz);
        let quiet = prefs.quiet.enabled && in_quiet(local.time(), &prefs.quiet);
        let enabled = |t: &Tracked| prefs.kinds.enabled(t.item.kind());
        let due: Vec<ItemKey> = self
            .items
            .iter()
            .filter(|(_, t)| t.status == Status::Pending && enabled(t) && t.due_at(cfg) <= now)
            .map(|(k, _)| k.clone())
            .collect();
        if quiet {
            for key in due {
                if let Some(t) = self.items.get_mut(&key) {
                    t.status = Status::HeldQuiet;
                    fx.push(Effect::Log {
                        item: t.item.clone(),
                        outcome: PushOutcome::HeldQuietHours,
                    });
                }
            }
        } else {
            let (decisions, grace_due): (Vec<ItemKey>, Vec<ItemKey>) = due
                .into_iter()
                .partition(|k| self.items.get(k).is_some_and(Tracked::is_decision));
            // A decision is never coalesced and never counts toward a burst.
            for key in decisions {
                self.notify(&key, &mut fx);
            }
            if !grace_due.is_empty() {
                // Exact lookahead: the grace items still pending that come due
                // within the next grace delay count with the ones due now.
                let lookahead: Vec<ItemKey> = self
                    .items
                    .iter()
                    .filter(|(k, t)| {
                        !grace_due.contains(k)
                            && t.status == Status::Pending
                            && enabled(t)
                            && !t.is_decision()
                            && t.due_at(cfg) > now
                            && t.due_at(cfg) < now + cfg.grace
                    })
                    .map(|(k, _)| k.clone())
                    .collect();
                if grace_due.len() + lookahead.len() >= BURST_THRESHOLD {
                    let mut covered = Vec::new();
                    for key in grace_due.iter().chain(&lookahead) {
                        if let Some(t) = self.items.get_mut(key) {
                            t.status = Status::Coalesced;
                            covered.push(t.item.clone());
                        }
                    }
                    fx.push(Effect::Summary {
                        reason: SummaryReason::Burst,
                        covered,
                    });
                } else {
                    for key in grace_due {
                        self.notify(&key, &mut fx);
                    }
                }
            }
        }

        // 4. The morning digest at the end of quiet hours, and the evening summary.
        let anything = self.items.values().any(enabled);
        let date = local.date_naive();
        let morning_at = parse_hhmm(&prefs.quiet.end).unwrap_or_else(default_morning);
        if due_daily(
            &mut self.last_morning,
            date,
            local.time(),
            morning_at,
            baseline,
        ) && anything
        {
            fx.push(Effect::Summary {
                reason: SummaryReason::Morning,
                covered: Vec::new(),
            });
        }
        if let Some(at) = prefs.evening_summary.as_deref().and_then(parse_hhmm) {
            let inside_quiet = prefs.quiet.enabled && in_quiet(at, &prefs.quiet);
            if due_daily(&mut self.last_evening, date, local.time(), at, baseline)
                && !inside_quiet
                && anything
            {
                fx.push(Effect::Summary {
                    reason: SummaryReason::Evening,
                    covered: Vec::new(),
                });
            }
        }
        fx
    }

    fn notify(&mut self, key: &ItemKey, fx: &mut Vec<Effect>) {
        if let Some(t) = self.items.get_mut(key) {
            t.status = Status::Notified;
            fx.push(Effect::Alert(t.item.clone()));
        }
    }
}

/// A decision past its deadline is no longer waiting: its asker gave up.
fn expired(w: &Waiting, now: DateTime<Utc>) -> bool {
    matches!(&w.detail, Detail::Decision { deadline: Some(d), .. } if *d <= now)
}

/// Everything waiting that a device's switches leave on, as the badge and the
/// summaries count it.
pub fn enabled_waiting<'a>(
    waiting: &'a [Waiting],
    prefs: &PushPrefs,
    now: DateTime<Utc>,
) -> Vec<&'a Waiting> {
    waiting
        .iter()
        .filter(|w| prefs.kinds.enabled(w.kind()) && !expired(w, now))
        .collect()
}

/// A daily event at `at` (local): true once per local date, within
/// [`SUMMARY_LATE_LIMIT`] of `at`. While `baseline` it is only marked done, so a
/// restart after `at` does not fire it.
fn due_daily(
    last: &mut Option<NaiveDate>,
    date: NaiveDate,
    time: NaiveTime,
    at: NaiveTime,
    baseline: bool,
) -> bool {
    if *last == Some(date) || time < at {
        return false;
    }
    *last = Some(date);
    !baseline && time - at < SUMMARY_LATE_LIMIT
}

/// Is the local time inside quiet hours? `start == end` is empty; `start > end`
/// wraps midnight. The end is exclusive.
pub fn in_quiet(time: NaiveTime, quiet: &QuietHours) -> bool {
    let start = parse_hhmm(&quiet.start).unwrap_or_else(default_quiet_start);
    let end = parse_hhmm(&quiet.end).unwrap_or_else(default_morning);
    match start.cmp(&end) {
        std::cmp::Ordering::Equal => false,
        std::cmp::Ordering::Less => start <= time && time < end,
        std::cmp::Ordering::Greater => time >= start || time < end,
    }
}

pub fn parse_hhmm(s: &str) -> Option<NaiveTime> {
    NaiveTime::parse_from_str(s.trim(), "%H:%M").ok()
}

/// The IANA zone, or UTC for a name this build does not know.
pub fn parse_tz(name: &str) -> Tz {
    name.parse().unwrap_or(Tz::UTC)
}

fn default_quiet_start() -> NaiveTime {
    NaiveTime::from_hms_opt(22, 0, 0).unwrap()
}

fn default_morning() -> NaiveTime {
    NaiveTime::from_hms_opt(7, 0, 0).unwrap()
}
