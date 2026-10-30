//! How often one follower may change its staging list.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

/// Changes (stage, replace, remove, clear) one follower may make in a rolling minute.
pub const CHANGES_PER_MINUTE: usize = 30;
/// Changes one follower may make in a rolling hour.
pub const CHANGES_PER_HOUR: usize = 300;

const MINUTE: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(60 * 60);

/// When each follower's change calls were counted, within the hour. A call
/// counts whether it was accepted or refused for its content, so a hostile
/// caller is bounded too; `list` is not a change and never counts.
#[derive(Default)]
pub struct StagingLimits {
    changes: HashMap<String, VecDeque<Instant>>,
}

impl StagingLimits {
    /// Count one change by `tag` at `now`, or say how many whole seconds (at
    /// least one) until it may make one. A refused call is not counted.
    pub fn take(&mut self, tag: &str, now: Instant) -> Result<(), u64> {
        // Forget followers whose changes have all aged out.
        self.changes.retain(|_, times| {
            times
                .back()
                .is_some_and(|t| now.saturating_duration_since(*t) < HOUR)
        });
        let times = self.changes.entry(tag.to_string()).or_default();
        while times
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) >= HOUR)
        {
            times.pop_front();
        }
        let in_minute: Vec<Instant> = times
            .iter()
            .copied()
            .filter(|t| now.saturating_duration_since(*t) < MINUTE)
            .collect();
        let mut wait = Duration::ZERO;
        if in_minute.len() >= CHANGES_PER_MINUTE {
            // The oldest change in the minute leaves the window first.
            wait = wait.max(MINUTE.saturating_sub(now.saturating_duration_since(in_minute[0])));
        }
        if times.len() >= CHANGES_PER_HOUR {
            wait = wait.max(HOUR.saturating_sub(now.saturating_duration_since(times[0])));
        }
        if !wait.is_zero() {
            return Err(wait.as_secs_f64().ceil().max(1.0) as u64);
        }
        times.push_back(now);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_31st_change_in_a_minute_is_refused_with_a_wait() {
        let mut limits = StagingLimits::default();
        let t0 = Instant::now();
        for _ in 0..CHANGES_PER_MINUTE {
            limits.take("a", t0).unwrap();
        }
        let wait = limits.take("a", t0 + Duration::from_secs(10)).unwrap_err();
        assert_eq!(wait, 50);
        assert!(limits.take("a", t0 + Duration::from_secs(60)).is_ok());
    }

    #[test]
    fn the_301st_change_in_an_hour_is_refused() {
        let mut limits = StagingLimits::default();
        let t0 = Instant::now();
        // 30 a minute for ten minutes: never over the minute limit.
        for minute in 0..10u64 {
            for _ in 0..CHANGES_PER_MINUTE {
                limits
                    .take("a", t0 + Duration::from_secs(minute * 61))
                    .unwrap();
            }
        }
        let now = t0 + Duration::from_secs(10 * 61);
        let wait = limits.take("a", now).unwrap_err();
        assert!(wait >= 1);
        assert!(limits.take("a", t0 + HOUR + Duration::from_secs(1)).is_ok());
    }

    #[test]
    fn followers_are_counted_apart_and_a_refused_call_is_not_counted() {
        let mut limits = StagingLimits::default();
        let t0 = Instant::now();
        for _ in 0..CHANGES_PER_MINUTE {
            limits.take("a", t0).unwrap();
        }
        assert!(limits.take("b", t0).is_ok());
        for _ in 0..100 {
            assert!(limits.take("a", t0).is_err());
        }
        assert!(limits.take("a", t0 + MINUTE).is_ok());
    }

    #[test]
    fn a_wait_is_never_less_than_a_second() {
        let mut limits = StagingLimits::default();
        let t0 = Instant::now();
        for _ in 0..CHANGES_PER_MINUTE {
            limits.take("a", t0).unwrap();
        }
        let wait = limits
            .take("a", t0 + MINUTE - Duration::from_millis(1))
            .unwrap_err();
        assert_eq!(wait, 1);
    }
}
