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
    pub fn apply(
        &mut self,
        demand: Demand,
        now: DateTime<Utc>,
    ) -> (Posture, Option<DateTime<Utc>>, bool) {
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
        (
            posture,
            if posture == Posture::Paused {
                resume
            } else {
                None
            },
            rate_limited,
        )
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

#[cfg(test)]
mod tests {
    //! What the feature may ask GitHub, and when: postures, cadences, the
    //! rolling hourly buckets and the rate-limit reading. Pure, so every clock
    //! is a parameter.

    use super::*;
    use chrono::TimeZone;

    fn wall(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000 + secs, 0).unwrap()
    }

    fn obs(remaining: u64, limit: u64, reset_in: i64) -> RateObs {
        RateObs {
            remaining,
            limit,
            reset: wall(reset_in),
        }
    }

    // ── demand ────────────────────────────────────────────────────────────

    #[test]
    fn demand_levels_decode_and_anything_unknown_counts_as_hidden() {
        assert_eq!(Demand::from_wire("visible"), Demand::Visible);
        assert_eq!(Demand::from_wire("hidden"), Demand::Hidden);
        assert_eq!(Demand::from_wire("idle"), Demand::Idle);
        assert_eq!(Demand::from_wire("somethingnew"), Demand::Hidden);
        assert_eq!(Demand::from_wire(""), Demand::Hidden);
        assert_eq!(
            Demand::from_wire("VISIBLE"),
            Demand::Hidden,
            "the wire is case-sensitive"
        );
    }

    #[test]
    fn visible_outranks_hidden_outranks_idle() {
        assert!(Demand::Visible > Demand::Hidden);
        assert!(Demand::Hidden > Demand::Idle);
        assert_eq!(Demand::default(), Demand::Idle);
    }

    // ── cadences ──────────────────────────────────────────────────────────

    #[test]
    fn the_documented_cadences_and_caps_per_posture() {
        let v = Posture::Visible.cadence().unwrap();
        assert_eq!(v.search, Duration::from_secs(60));
        assert_eq!(v.pending_ci, Duration::from_secs(60));
        assert_eq!(v.full, Duration::from_secs(600));
        assert_eq!((v.poll_cap, v.relay_cap), (120, 60));

        let h = Posture::Hidden.cadence().unwrap();
        assert_eq!(h.search, Duration::from_secs(300));
        assert_eq!(h.pending_ci, Duration::from_secs(300));
        assert_eq!(h.full, Duration::from_secs(1800));
        assert_eq!((h.poll_cap, h.relay_cap), (20, 20));

        assert!(
            Posture::Idle.cadence().is_none(),
            "idle does no scheduled work"
        );
        assert!(
            Posture::Paused.cadence().is_none(),
            "paused does no scheduled work"
        );
        assert!(Posture::Visible.active() && Posture::Hidden.active());
        assert!(!Posture::Idle.active() && !Posture::Paused.active());
    }

    // ── posture from demand and GitHub's headers ──────────────────────────

    #[test]
    fn with_no_readings_the_posture_is_the_demand() {
        let mut r = RateState::default();
        assert_eq!(
            r.apply(Demand::Visible, wall(0)),
            (Posture::Visible, None, false)
        );
        assert_eq!(
            r.apply(Demand::Hidden, wall(0)),
            (Posture::Hidden, None, false)
        );
        assert_eq!(r.apply(Demand::Idle, wall(0)), (Posture::Idle, None, false));
    }

    #[test]
    fn under_twenty_percent_remaining_visible_acts_as_hidden_and_says_so() {
        let mut r = RateState::default();
        r.observe(Resource::Search, obs(19, 100, 600));
        assert_eq!(
            r.apply(Demand::Visible, wall(0)),
            (Posture::Hidden, None, true)
        );
        assert_eq!(
            r.apply(Demand::Hidden, wall(0)),
            (Posture::Hidden, None, true),
            "hidden stays hidden but is still reported as limited"
        );
    }

    #[test]
    fn exactly_twenty_percent_is_not_yet_low() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(20, 100, 600));
        assert_eq!(
            r.apply(Demand::Visible, wall(0)),
            (Posture::Visible, None, false)
        );
    }

    #[test]
    fn under_five_percent_pauses_until_the_reset() {
        let mut r = RateState::default();
        r.observe(Resource::Graphql, obs(4, 100, 900));
        let (posture, resumes, limited) = r.apply(Demand::Visible, wall(0));
        assert_eq!(posture, Posture::Paused);
        assert_eq!(resumes, Some(wall(900)), "resumes at the reset");
        assert!(limited);
        // Hidden is paused too.
        assert_eq!(r.apply(Demand::Hidden, wall(0)).0, Posture::Paused);
    }

    #[test]
    fn exactly_five_percent_lowers_but_does_not_pause() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(5, 100, 600));
        assert_eq!(
            r.apply(Demand::Visible, wall(0)),
            (Posture::Hidden, None, true)
        );
    }

    #[test]
    fn the_worst_resource_decides_and_the_latest_reset_ends_the_pause() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(3, 100, 300));
        r.observe(Resource::Search, obs(1, 100, 700));
        r.observe(Resource::Graphql, obs(90, 100, 100));
        let (posture, resumes, _) = r.apply(Demand::Visible, wall(0));
        assert_eq!(posture, Posture::Paused);
        assert_eq!(resumes, Some(wall(700)));
    }

    #[test]
    fn after_the_reset_the_reading_is_forgotten_and_the_posture_returns() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(0, 100, 300));
        assert_eq!(r.apply(Demand::Visible, wall(299)).0, Posture::Paused);
        assert_eq!(
            r.apply(Demand::Visible, wall(300)),
            (Posture::Visible, None, false)
        );
    }

    #[test]
    fn idle_stays_idle_and_is_not_reported_as_limited() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(0, 100, 300));
        assert_eq!(r.apply(Demand::Idle, wall(0)), (Posture::Idle, None, false));
    }

    #[test]
    fn a_retry_after_pauses_until_it_ends_whatever_the_readings_say() {
        let mut r = RateState::default();
        r.pause_until(wall(120));
        let (posture, resumes, limited) = r.apply(Demand::Visible, wall(0));
        assert_eq!(
            (posture, resumes, limited),
            (Posture::Paused, Some(wall(120)), true)
        );
        assert_eq!(r.apply(Demand::Visible, wall(119)).0, Posture::Paused);
        assert_eq!(
            r.apply(Demand::Visible, wall(120)),
            (Posture::Visible, None, false)
        );
    }

    #[test]
    fn a_second_pause_never_shortens_the_first() {
        let mut r = RateState::default();
        r.pause_until(wall(500));
        r.pause_until(wall(100));
        assert_eq!(r.apply(Demand::Visible, wall(200)).1, Some(wall(500)));
    }

    #[test]
    fn next_change_is_the_earliest_reset_or_pause_end() {
        let mut r = RateState::default();
        assert_eq!(r.next_change(), None);
        r.observe(Resource::Core, obs(50, 100, 900));
        assert_eq!(r.next_change(), Some(wall(900)));
        r.pause_until(wall(120));
        assert_eq!(r.next_change(), Some(wall(120)));
    }

    #[test]
    fn a_reading_with_a_zero_limit_is_ignored() {
        let mut r = RateState::default();
        r.observe(Resource::Core, obs(0, 0, 600));
        assert_eq!(
            r.apply(Demand::Visible, wall(0)),
            (Posture::Visible, None, false)
        );
    }

    #[test]
    fn resources_are_read_from_the_header_names() {
        assert_eq!(Resource::from_header("core"), Some(Resource::Core));
        assert_eq!(Resource::from_header("search"), Some(Resource::Search));
        assert_eq!(Resource::from_header("graphql"), Some(Resource::Graphql));
        assert_eq!(Resource::from_header("integration_manifest"), None);
        assert_eq!(Resource::from_header(""), None);
    }

    // ── the rolling hourly bucket ─────────────────────────────────────────

    #[test]
    fn a_bucket_has_room_until_the_cap_is_charged() {
        let t0 = Instant::now();
        let mut b = Bucket::default();
        for i in 0..3 {
            assert!(b.has_room(t0, 3), "charge {i}");
            b.charge(t0);
        }
        assert!(!b.has_room(t0, 3));
        assert_eq!(b.used(t0), 3);
        assert!(b.has_room(t0, 4));
        assert!(!b.has_room(t0, 0), "a zero cap never has room");
    }

    #[test]
    fn a_charge_leaves_the_bucket_exactly_one_hour_later() {
        let t0 = Instant::now();
        let mut b = Bucket::default();
        b.charge(t0);
        b.charge(t0 + Duration::from_secs(1800));
        assert_eq!(
            b.used(t0 + HOUR - Duration::from_secs(1)),
            2,
            "59m59s later: both held"
        );
        assert_eq!(b.used(t0 + HOUR), 1, "an hour later: the first is out");
        assert_eq!(
            b.used(t0 + HOUR + Duration::from_secs(1800)),
            0,
            "and the second"
        );
    }

    #[test]
    fn the_next_slot_is_now_with_room_and_when_the_oldest_leaves_without() {
        let t0 = Instant::now();
        let mut b = Bucket::default();
        assert_eq!(b.next_slot(t0, 2), Some(t0));
        b.charge(t0);
        assert_eq!(b.next_slot(t0, 2), Some(t0));
        b.charge(t0 + Duration::from_secs(10));
        assert_eq!(
            b.next_slot(t0 + Duration::from_secs(20), 2),
            Some(t0 + HOUR),
            "full: a slot opens when the oldest charge is an hour old"
        );
        assert_eq!(b.next_slot(t0, 0), None, "a zero cap never opens");
    }

    #[test]
    fn the_cap_holds_over_any_rolling_hour_when_a_caller_waits_for_the_next_slot() {
        let t0 = Instant::now();
        let mut b = Bucket::default();
        let mut now = t0;
        let mut charged_at = Vec::new();
        // Ask for a request every minute for three hours against a cap of 20.
        for _ in 0..180 {
            if b.has_room(now, 20) {
                b.charge(now);
                charged_at.push(now);
            }
            now += Duration::from_secs(60);
        }
        for (i, start) in charged_at.iter().enumerate() {
            let in_window = charged_at[i..]
                .iter()
                .take_while(|t| t.duration_since(*start) < HOUR)
                .count();
            assert!(
                in_window <= 20,
                "{in_window} charges inside the hour after #{i}"
            );
        }
    }

    // ── errors ────────────────────────────────────────────────────────────

    #[test]
    fn the_error_backoff_doubles_from_two_minutes_and_stops_at_thirty() {
        let mins: Vec<u64> = (1..=8).map(|n| error_backoff(n).as_secs() / 60).collect();
        assert_eq!(mins, vec![2, 4, 8, 16, 30, 30, 30, 30]);
        assert_eq!(
            error_backoff(0),
            error_backoff(1),
            "a zero count is the first error"
        );
        assert_eq!(error_backoff(u32::MAX), MAX_ERROR_BACKOFF, "no overflow");
    }

    #[test]
    fn retry_after_is_whole_seconds_capped_at_an_hour() {
        assert_eq!(parse_retry_after("120"), Some(Duration::from_secs(120)));
        assert_eq!(parse_retry_after(" 7 "), Some(Duration::from_secs(7)));
        assert_eq!(parse_retry_after("0"), Some(Duration::ZERO));
        assert_eq!(parse_retry_after("7200"), Some(MAX_RETRY_AFTER));
        assert_eq!(parse_retry_after("99999999999"), Some(MAX_RETRY_AFTER));
        assert_eq!(parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT"), None);
        assert_eq!(parse_retry_after("-5"), None);
        assert_eq!(parse_retry_after(""), None);
        assert_eq!(parse_retry_after("1.5"), None);
    }

    #[test]
    fn the_documented_constants_hold() {
        assert_eq!(MIN_SEARCH_GAP, Duration::from_secs(60));
        assert_eq!(RELAY_COALESCE, Duration::from_secs(2));
        assert_eq!(LINGER, Duration::from_secs(60));
        assert_eq!(TOKEN_RETRY, Duration::from_secs(1800));
        assert_eq!(HOUR, Duration::from_secs(3600));
    }
}
