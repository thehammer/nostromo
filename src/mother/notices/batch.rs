//! Per-focus batching: what waits to be told, the batch window, and why a due
//! delivery is held.
//!
//! * The first waking change opens a window. Every change for the focus while
//!   it is open joins it (quiet ones too) and moves its end: it closes
//!   [`WINDOW_QUIET_MS`] after the last change or [`WINDOW_MAX_MS`] after the
//!   first, whichever is first.
//! * Changes are kept latest per job: a job's item gathers its states oldest
//!   first (the element's `since`), consecutive repeats collapsed.
//! * A quiet change with no window open is kept (the newest
//!   [`MAX_RIDE_ALONG_JOBS`] jobs) and rides along in the next delivery.
//! * Items handed to the session but not yet written are "in flight", tagged
//!   with the generation of the message that carries them.

use serde::{Deserialize, Serialize};

use super::detect::JobEvent;
use super::element::NoticeItem;

/// A window closes this long after its last change.
pub const WINDOW_QUIET_MS: i64 = 30_000;
/// A window never stays open longer than this after its first change.
pub const WINDOW_MAX_MS: i64 = 120_000;
/// Quiet changes kept without a delivery due: the newest this many jobs.
pub const MAX_RIDE_ALONG_JOBS: usize = 20;
/// Held items older than this are dropped (`expired`).
pub const HOLD_MAX_MS: i64 = 24 * 60 * 60 * 1000;

/// Why a delivery that is due waits. The order is precedence: a stronger hold
/// is never replaced by a weaker one when a change is added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HoldReason {
    /// The focus (or the job) is Quiet: delivered after the next turn starts.
    Quiet,
    /// No session to deliver to: delivered after its next turn starts.
    SessionNotRunning,
    /// The focus is in a notice turn: delivered when it ends.
    Busy,
    /// The hourly cap: delivered when the hour rolls or the user speaks.
    Cap,
    /// The loop guard: delivered when the user speaks.
    LoopGuard,
}

/// A batch window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Window {
    pub first_ms: i64,
    pub last_ms: i64,
}

impl Window {
    /// When the window closes.
    pub fn closes_at(&self) -> i64 {
        (self.last_ms + WINDOW_QUIET_MS).min(self.first_ms + WINDOW_MAX_MS)
    }
}

/// One job waiting to be told.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    pub item: NoticeItem,
    /// It holds a change that must be delivered (a waking change), as opposed
    /// to quiet changes that only ride along.
    pub due: bool,
    /// When its latest change arrived.
    pub updated_ms: i64,
}

/// Items in a message handed to the session and not yet written.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InFlight {
    pub gen: u64,
    pub item: NoticeItem,
    pub due: bool,
    pub at_ms: i64,
    /// Already counted as told (the message woke an idle session at once).
    #[serde(default)]
    pub told: bool,
}

impl From<InFlight> for Pending {
    /// An item taken back from the session's queue waits again, as it did.
    fn from(f: InFlight) -> Self {
        Self {
            item: f.item,
            due: f.due,
            updated_ms: f.at_ms,
        }
    }
}

/// A due delivery's hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hold {
    pub reason: HoldReason,
    pub since_ms: i64,
}

/// Everything waiting for one focus.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Bucket {
    #[serde(default)]
    pub items: Vec<Pending>,
    #[serde(default)]
    pub window: Option<Window>,
    #[serde(default)]
    pub hold: Option<Hold>,
    #[serde(default)]
    pub inflight: Vec<InFlight>,
    /// The generation of the newest message handed to the session.
    #[serde(default)]
    pub gen: u64,
}

impl Bucket {
    /// Add `event` for the job `snapshot` describes. `due` marks a change that
    /// must be delivered. Returns whether it changed anything (a repeat of the
    /// job's newest state does not).
    pub fn add(&mut self, snapshot: NoticeItem, event: JobEvent, due: bool, now: i64) -> bool {
        let changed = match self
            .items
            .iter_mut()
            .find(|p| p.item.job_id == snapshot.job_id)
        {
            Some(p) => {
                let repeat = p.item.states.last() == Some(&event);
                if !repeat {
                    p.item.states.push(event);
                }
                p.item.title = snapshot.title;
                p.item.pr_url = snapshot.pr_url;
                p.item.cost_usd = snapshot.cost_usd;
                p.item.reason = snapshot.reason;
                p.due |= due;
                p.updated_ms = now;
                !repeat
            }
            None => {
                let mut item = snapshot;
                item.states = vec![event];
                self.items.push(Pending {
                    item,
                    due,
                    updated_ms: now,
                });
                true
            }
        };
        self.trim_ride_alongs();
        changed
    }

    /// Keep at most [`MAX_RIDE_ALONG_JOBS`] items: the oldest that are not due
    /// go first. A due item is never dropped here.
    fn trim_ride_alongs(&mut self) {
        while self.items.len() > MAX_RIDE_ALONG_JOBS {
            let oldest = self
                .items
                .iter()
                .enumerate()
                .filter(|(_, p)| !p.due)
                .min_by_key(|(_, p)| p.updated_ms)
                .map(|(i, _)| i);
            match oldest {
                Some(i) => {
                    self.items.remove(i);
                }
                None => break,
            }
        }
    }

    /// Open the window at `now`, or move its end.
    pub fn touch_window(&mut self, now: i64) {
        match &mut self.window {
            Some(w) => w.last_ms = now,
            None => {
                self.window = Some(Window {
                    first_ms: now,
                    last_ms: now,
                })
            }
        }
    }

    /// Hold with `reason` unless a stronger hold is already set.
    pub fn hold_at_least(&mut self, reason: HoldReason, now: i64) {
        if self.hold.is_none_or(|h| h.reason < reason) {
            self.hold = Some(Hold {
                reason,
                since_ms: now,
            });
        }
    }

    /// Hold with exactly `reason` (the outcome of a delivery attempt).
    pub fn hold_with(&mut self, reason: HoldReason, now: i64) {
        if self.hold.map(|h| h.reason) != Some(reason) {
            self.hold = Some(Hold {
                reason,
                since_ms: now,
            });
        }
    }

    /// Is any item due?
    pub fn has_due(&self) -> bool {
        self.items.iter().any(|p| p.due)
    }

    /// Items in flight that were not yet told.
    pub fn untold_inflight(&self) -> impl Iterator<Item = &InFlight> {
        self.inflight.iter().filter(|f| !f.told)
    }

    /// Take every waiting item for a delivery: due items first, otherwise in
    /// the order they arrived.
    pub fn take_items(&mut self) -> Vec<Pending> {
        let mut items = std::mem::take(&mut self.items);
        items.sort_by_key(|p| !p.due);
        items
    }

    /// Hand `items` to the session as generation `gen`. One element per job: a
    /// job whose notice still waits in the session's queue gains the new
    /// states in place of a second element.
    pub fn put_in_flight(&mut self, items: Vec<Pending>, gen: u64, now: i64) {
        for p in items {
            match self
                .inflight
                .iter_mut()
                .find(|f| !f.told && f.item.job_id == p.item.job_id)
            {
                Some(f) => {
                    for s in &p.item.states {
                        if f.item.states.last() != Some(s) {
                            f.item.states.push(*s);
                        }
                    }
                    f.item.title = p.item.title;
                    f.item.pr_url = p.item.pr_url;
                    f.item.cost_usd = p.item.cost_usd;
                    f.item.reason = p.item.reason;
                    f.due |= p.due;
                    f.gen = gen;
                    f.at_ms = now;
                }
                None => self.inflight.push(InFlight {
                    gen,
                    item: p.item,
                    due: p.due,
                    at_ms: now,
                    told: false,
                }),
            }
        }
    }

    /// Remove and return the in-flight entries `pick` selects.
    pub fn drain_inflight(&mut self, pick: impl Fn(&InFlight) -> bool) -> Vec<InFlight> {
        let (taken, kept): (Vec<InFlight>, Vec<InFlight>) = std::mem::take(&mut self.inflight)
            .into_iter()
            .partition(|f| pick(f));
        self.inflight = kept;
        taken
    }

    /// Move the in-flight entries `pick` selects back to the waiting items.
    /// Returns whether any moved.
    pub fn take_back(&mut self, pick: impl Fn(&InFlight) -> bool) -> bool {
        let back = self.drain_inflight(pick);
        if back.is_empty() {
            return false;
        }
        self.restore(back.into_iter().map(Pending::from).collect());
        true
    }

    /// Put items back (a delivery that could not be made), merging with
    /// whatever arrived meanwhile.
    pub fn restore(&mut self, items: Vec<Pending>) {
        for back in items.into_iter().rev() {
            match self
                .items
                .iter_mut()
                .find(|p| p.item.job_id == back.item.job_id)
            {
                Some(p) => {
                    let mut states = back.item.states.clone();
                    for s in &p.item.states {
                        if states.last() != Some(s) {
                            states.push(*s);
                        }
                    }
                    p.item.states = states;
                    p.due |= back.due;
                }
                None => self.items.insert(0, back),
            }
        }
    }

    /// Nothing waiting, nothing in flight.
    pub fn is_empty(&self) -> bool {
        self.items.is_empty() && self.inflight.is_empty() && self.window.is_none()
    }

    /// Forget everything waiting and in flight; returns what was dropped.
    pub fn clear(&mut self) -> Vec<NoticeItem> {
        let mut gone: Vec<NoticeItem> = self.items.drain(..).map(|p| p.item).collect();
        gone.extend(self.inflight.drain(..).filter(|f| !f.told).map(|f| f.item));
        self.window = None;
        self.hold = None;
        gone
    }
}
