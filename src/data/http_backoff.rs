//! Throttle detection and backoff shared by the Graph and Google clients.

use chrono::{DateTime, Utc};

use crate::data::google_client::GoogleHttpError;
use crate::data::graph_client::GraphHttpError;

/// Longest we will ever stay quiet because of a `Retry-After` (contract §9
/// caps backoff at 15 minutes).
pub const MAX_RETRY_AFTER: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// Parse an HTTP `Retry-After` value: whole seconds or an HTTP-date, measured
/// from `now`, capped at [`MAX_RETRY_AFTER`]. A date in the past is zero.
/// `None` when the value is neither.
pub fn parse_retry_after(value: &str, now: DateTime<Utc>) -> Option<std::time::Duration> {
    let value = value.trim();
    let wait = if let Ok(secs) = value.parse::<u64>() {
        std::time::Duration::from_secs(secs)
    } else {
        let when = DateTime::parse_from_rfc2822(value)
            .ok()?
            .with_timezone(&Utc);
        (when - now).to_std().unwrap_or(std::time::Duration::ZERO)
    };
    Some(wait.min(MAX_RETRY_AFTER))
}

/// `Some(retry_after)` when `e` is Graph throttling us (429, or 503 with a
/// `Retry-After`); `None` for any other failure.
pub fn throttle_of(e: &anyhow::Error) -> Option<Option<std::time::Duration>> {
    if let Some(http) = e.downcast_ref::<GraphHttpError>() {
        return http.is_throttle().then_some(http.retry_after);
    }
    let http = e.downcast_ref::<GoogleHttpError>()?;
    http.is_throttle().then_some(http.retry_after)
}

/// Consecutive-throttle counter for one polling loop. Success resets it.
/// The wait after a throttle is the server's `Retry-After` when there is one,
/// otherwise exponential backoff: 2 s, 4 s, 8 s … capped at 15 min, plus up
/// to 25 % jitter.
#[derive(Debug)]
pub struct ThrottleBackoff {
    /// The first step of the exponential wait ([`BACKOFF_BASE`] in
    /// production; tests inject a shorter one through `FredTiming`).
    base: std::time::Duration,
    consecutive: u32,
    /// Consecutive non-throttle failures (see [`persistent`](Self::persistent)).
    failures: u32,
}

/// Longest quiet period for a persistent non-throttle failure.
const MAX_PERSISTENT_WAIT: std::time::Duration = std::time::Duration::from_secs(5 * 60);

/// The first step of the throttle backoff (then 4 s, 8 s ...).
pub const BACKOFF_BASE: std::time::Duration = std::time::Duration::from_secs(2);

impl Default for ThrottleBackoff {
    fn default() -> Self {
        Self::with_base(BACKOFF_BASE)
    }
}

impl ThrottleBackoff {
    /// A backoff whose first step is `base` (production: [`BACKOFF_BASE`]).
    pub fn with_base(base: std::time::Duration) -> Self {
        Self {
            base,
            consecutive: 0,
            failures: 0,
        }
    }

    /// A fetch succeeded: the next throttle starts again at the first step.
    pub fn succeeded(&mut self) {
        self.consecutive = 0;
        self.failures = 0;
    }

    /// A non-throttle failure (say 403 `accessNotConfigured`). The first one
    /// is retried at the normal cadence (`None`); a repeat backs off
    /// `poll * 2^(n-1)`, capped at 5 minutes, instead of hammering every poll.
    pub fn persistent(&mut self, poll: std::time::Duration) -> Option<std::time::Duration> {
        self.failures = self.failures.saturating_add(1);
        if self.failures < 2 {
            return None;
        }
        let factor = 1u32.checked_shl(self.failures - 1).unwrap_or(u32::MAX);
        Some(poll.saturating_mul(factor).min(MAX_PERSISTENT_WAIT))
    }

    /// `e` is how a fetch failed. When it is a throttle, how long to stay
    /// quiet; otherwise `None` (and the backoff is left alone).
    pub fn throttled(&mut self, e: &anyhow::Error) -> Option<std::time::Duration> {
        let retry_after = throttle_of(e)?;
        let step = self
            .base
            .saturating_mul(1u32.checked_shl(self.consecutive).unwrap_or(u32::MAX))
            .min(MAX_RETRY_AFTER);
        self.consecutive = self.consecutive.saturating_add(1);
        Some(match retry_after {
            Some(wait) => wait,
            None => (step + step.mul_f64(jitter() * 0.25)).min(MAX_RETRY_AFTER),
        })
    }
}

/// A cheap value in `[0, 1)`; spreads out retries, not security sensitive.
pub fn jitter() -> f64 {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    f64::from(nanos % 1000) / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::StatusCode;

    fn google(status: u16, reason: Option<&str>, retry_after: Option<u64>) -> anyhow::Error {
        GoogleHttpError {
            status: StatusCode::from_u16(status).unwrap(),
            path: "/x".into(),
            reason: reason.map(str::to_owned),
            retry_after: retry_after.map(std::time::Duration::from_secs),
        }
        .into()
    }

    #[test]
    fn google_429_and_rate_limit_403_are_throttles() {
        assert_eq!(throttle_of(&google(429, None, None)), Some(None));
        assert!(throttle_of(&google(403, Some("rateLimitExceeded"), None)).is_some());
        assert!(throttle_of(&google(403, Some("userRateLimitExceeded"), Some(7))).is_some());
        assert_eq!(
            throttle_of(&google(503, None, Some(7))),
            Some(Some(std::time::Duration::from_secs(7)))
        );
    }

    #[test]
    fn google_plain_403_is_not_a_throttle() {
        assert!(throttle_of(&google(403, Some("forbidden"), None)).is_none());
        assert!(throttle_of(&google(500, None, None)).is_none());
    }

    #[test]
    fn persistent_failures_back_off_and_reset() {
        let poll = std::time::Duration::from_secs(5);
        let mut b = ThrottleBackoff::default();
        assert_eq!(b.persistent(poll), None);
        assert_eq!(b.persistent(poll), Some(poll * 2));
        assert_eq!(b.persistent(poll), Some(poll * 4));
        for _ in 0..40 {
            b.persistent(poll);
        }
        assert_eq!(b.persistent(poll), Some(MAX_PERSISTENT_WAIT));
        b.succeeded();
        assert_eq!(b.persistent(poll), None);
    }

    fn throttle_without_retry_after() -> anyhow::Error {
        GraphHttpError {
            status: StatusCode::TOO_MANY_REQUESTS,
            url: "u".into(),
            body: String::new(),
            retry_after: None,
        }
        .into()
    }

    /// The user-approved production values (no waiting: the backoff only
    /// computes the wait): at least 2 s after the first throttle, then 4 s,
    /// each with at most 25% jitter. The timing tests inject a shorter base;
    /// this is the one place that pins the real constant.
    #[test]
    fn the_production_backoff_is_at_least_2_then_4_seconds_with_bounded_jitter() {
        assert_eq!(BACKOFF_BASE, std::time::Duration::from_secs(2));
        let mut b = ThrottleBackoff::default();
        let first = b.throttled(&throttle_without_retry_after()).unwrap();
        let second = b.throttled(&throttle_without_retry_after()).unwrap();
        assert!(
            (std::time::Duration::from_secs(2)..=std::time::Duration::from_millis(2500))
                .contains(&first),
            "{first:?}"
        );
        assert!(
            (std::time::Duration::from_secs(4)..=std::time::Duration::from_secs(5))
                .contains(&second),
            "{second:?}"
        );
    }

    #[test]
    fn an_injected_base_scales_every_step() {
        let base = std::time::Duration::from_millis(100);
        let mut b = ThrottleBackoff::with_base(base);
        let first = b.throttled(&throttle_without_retry_after()).unwrap();
        let second = b.throttled(&throttle_without_retry_after()).unwrap();
        assert!((base..=base.mul_f64(1.25)).contains(&first), "{first:?}");
        assert!(
            (base * 2..=(base * 2).mul_f64(1.25)).contains(&second),
            "{second:?}"
        );
    }

    #[test]
    fn graph_429_is_unchanged() {
        let e: anyhow::Error = GraphHttpError {
            status: StatusCode::TOO_MANY_REQUESTS,
            url: "u".into(),
            body: String::new(),
            retry_after: Some(std::time::Duration::from_secs(3)),
        }
        .into();
        assert_eq!(
            throttle_of(&e),
            Some(Some(std::time::Duration::from_secs(3)))
        );
    }
}
