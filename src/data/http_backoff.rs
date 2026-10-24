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
        let when = DateTime::parse_from_rfc2822(value).ok()?.with_timezone(&Utc);
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
#[derive(Debug, Default)]
pub struct ThrottleBackoff {
    consecutive: u32,
}

const BACKOFF_BASE: std::time::Duration = std::time::Duration::from_secs(2);

impl ThrottleBackoff {
    /// A fetch succeeded: the next throttle starts again at the first step.
    pub fn succeeded(&mut self) {
        self.consecutive = 0;
    }

    /// `e` is how a fetch failed. When it is a throttle, how long to stay
    /// quiet; otherwise `None` (and the backoff is left alone).
    pub fn throttled(&mut self, e: &anyhow::Error) -> Option<std::time::Duration> {
        let retry_after = throttle_of(e)?;
        let step = BACKOFF_BASE
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
    fn graph_429_is_unchanged() {
        let e: anyhow::Error = GraphHttpError {
            status: StatusCode::TOO_MANY_REQUESTS,
            url: "u".into(),
            body: String::new(),
            retry_after: Some(std::time::Duration::from_secs(3)),
        }
        .into();
        assert_eq!(throttle_of(&e), Some(Some(std::time::Duration::from_secs(3))));
    }
}
