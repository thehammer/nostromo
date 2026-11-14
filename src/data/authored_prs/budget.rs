//! What the feature may ask GitHub, and when. Pure: the clock is a parameter.
//!
//! Demand (who is looking) sets the posture; GitHub's own rate-limit headers
//! can lower it (`visible` to `hidden` under 20% remaining, `paused` under 5%
//! or after a `Retry-After`). Each posture has a cadence and a cap of
//! **charged** requests per rolling hour (a 304 is not charged; every GraphQL
//! call is).

use std::collections::{HashMap, VecDeque};
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::time::Instant;

pub const HOUR: Duration = Duration::from_secs(3600);
/// The longest a `Retry-After` is honoured.
pub const MAX_RETRY_AFTER: Duration = Duration::from_secs(3600);
/// Search never runs more often than this, in any posture.
pub const MIN_SEARCH_GAP: Duration = Duration::from_secs(60);
/// Relay events for one PR inside this window become one read.
pub const RELAY_COALESCE: Duration = Duration::from_secs(2);
/// A merged or closed PR stays in the list this long.
pub const LINGER: Duration = Duration::from_secs(60);
/// A rejected token is retried after this long, or sooner if demand changes.
pub const TOKEN_RETRY: Duration = Duration::from_secs(30 * 60);
/// Back-off after an error: 2, 4, 8 ... minutes, capped.
pub const MAX_ERROR_BACKOFF: Duration = Duration::from_secs(30 * 60);

/// Who is looking. `Visible > Hidden > Idle`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub enum Demand {
    #[default]
    Idle,
    Hidden,
    Visible,
}

impl Demand {
    /// Decode the wire level; an unknown value is `hidden`.
    pub fn from_wire(level: &str) -> Demand {
        match level {
            "visible" => Demand::Visible,
            "idle" => Demand::Idle,
            _ => Demand::Hidden,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Posture {
    Visible,
    Hidden,
    Idle,
    Paused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cadence {
    pub search: Duration,
    pub pending_ci: Duration,
    pub full: Duration,
    /// Charged polling requests per rolling hour.
    pub poll_cap: usize,
    /// Charged relay-triggered requests per rolling hour.
    pub relay_cap: usize,
}

impl Posture {
    /// `None` for `Idle` and `Paused`: they do no scheduled work.
    pub fn cadence(self) -> Option<Cadence> {
        match self {
            Posture::Visible => Some(Cadence {
                search: Duration::from_secs(60),
                pending_ci: Duration::from_secs(60),
                full: Duration::from_secs(10 * 60),
                poll_cap: 120,
                relay_cap: 60,
            }),
            Posture::Hidden => Some(Cadence {
                search: Duration::from_secs(5 * 60),
                pending_ci: Duration::from_secs(5 * 60),
                full: Duration::from_secs(30 * 60),
                poll_cap: 20,
                relay_cap: 20,
            }),
            Posture::Idle | Posture::Paused => None,
        }
    }

    pub fn active(self) -> bool {
        matches!(self, Posture::Visible | Posture::Hidden)
    }
}

/// The three GitHub resources this feature draws on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Resource {
    Core,
    Search,
    Graphql,
}

impl Resource {
    pub fn from_header(name: &str) -> Option<Resource> {
        match name {
            "core" => Some(Resource::Core),
            "search" => Some(Resource::Search),
            "graphql" => Some(Resource::Graphql),
            _ => None,
        }
    }
}

/// One reading of `x-ratelimit-*`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RateObs {
    pub remaining: u64,
    pub limit: u64,
    pub reset: DateTime<Utc>,
}

/// What GitHub last said about each resource, and a pause it demanded.
#[derive(Debug, Default)]
pub struct RateState {
    obs: HashMap<Resource, RateObs>,
    /// No requests until this wall time (a `Retry-After` or secondary limit).
    pause_until: Option<DateTime<Utc>>,
}

impl RateState {
    pub fn observe(&mut self, r: Resource, obs: RateObs) {
        self.obs.insert(r, obs);
    }

    /// Stop until `until` (a `Retry-After`, capped at an hour, or a reset).
    pub fn pause_until(&mut self, until: DateTime<Utc>) {
        self.pause_until = Some(self.pause_until.map_or(until, |p| p.max(until)));
    }

    /// The next wall time at which `apply` may answer differently on its own:
    /// a reading's reset, or the end of a pause.
    pub fn next_change(&self) -> Option<DateTime<Utc>> {
        self.obs
            .values()
            .map(|o| o.reset)
            .chain(self.pause_until)
            .min()
    }

    /// The posture after demand and GitHub's limits are both applied, and the
    /// time a pause ends.
    pub fn apply(&mut self, demand: Demand, now: DateTime<Utc>) -> (Posture, Option<DateTime<Utc>>, bool) {
        self.obs.retain(|_, o| o.reset > now);
        if self.pause_until.is_some_and(|p| p <= now) {
            self.pause_until = None;
        }
        let mut resume = self.pause_until;
        let mut lowered = false;
        for o in self.obs.values() {
            if o.limit == 0 {
                continue;
            }
            let pct = o.remaining as f64 * 100.0 / o.limit as f64;
            if pct < 5.0 {
                resume = Some(resume.map_or(o.reset, |r| r.max(o.reset)));
            } else if pct < 20.0 {
                lowered = true;
            }
        }
        let posture = match demand {
            Demand::Idle => Posture::Idle,
            _ if resume.is_some() => Posture::Paused,
            Demand::Visible if lowered => Posture::Hidden,
            Demand::Visible => Posture::Visible,
            Demand::Hidden => Posture::Hidden,
        };
        let rate_limited = demand != Demand::Idle && (lowered || resume.is_some());
        (posture, if posture == Posture::Paused { resume } else { None }, rate_limited)
    }
}

/// A rolling one-hour count of charged requests.
#[derive(Debug, Default)]
pub struct Bucket {
    stamps: VecDeque<Instant>,
}

impl Bucket {
    fn prune(&mut self, now: Instant) {
        while self
            .stamps
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) >= HOUR)
        {
            self.stamps.pop_front();
        }
    }

    pub fn used(&mut self, now: Instant) -> usize {
        self.prune(now);
        self.stamps.len()
    }

    pub fn has_room(&mut self, now: Instant, cap: usize) -> bool {
        self.used(now) < cap
    }

    pub fn charge(&mut self, now: Instant) {
        self.prune(now);
        self.stamps.push_back(now);
    }

    /// When the next slot opens under `cap` (now if there is one); `None`
    /// when the cap is zero.
    pub fn next_slot(&mut self, now: Instant, cap: usize) -> Option<Instant> {
        if cap == 0 {
            return None;
        }
        self.prune(now);
        if self.stamps.len() < cap {
            return Some(now);
        }
        let idx = self.stamps.len() - cap;
        Some(self.stamps[idx] + HOUR)
    }
}

/// The back-off after the `n`th consecutive error: 2, 4, 8 ... minutes, capped.
pub fn error_backoff(consecutive: u32) -> Duration {
    let mins = 2u64.saturating_pow(consecutive.clamp(1, 16));
    Duration::from_secs(mins * 60).min(MAX_ERROR_BACKOFF)
}

/// Parse `Retry-After` as whole seconds, capped at [`MAX_RETRY_AFTER`].
pub fn parse_retry_after(value: &str) -> Option<Duration> {
    value
        .trim()
        .parse::<u64>()
        .ok()
        .map(|s| Duration::from_secs(s).min(MAX_RETRY_AFTER))
}
