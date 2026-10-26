//! The idle rule for remote shells: no keystrokes for [`CLOSE_AFTER`] closes
//! the pane, with a warning from [`WARN_AFTER`] on. Pure: the manager owns the
//! clock, the state and the effects.

use std::time::Duration;

use tokio::time::Instant;
use tracing::warn;

/// Warn (and let the app show a countdown) after this long without keystrokes.
pub const WARN_AFTER: Duration = Duration::from_secs(13 * 60);
/// Close a remote shell after this long without keystrokes.
pub const CLOSE_AFTER: Duration = Duration::from_secs(15 * 60);

/// The QA override: scales the policy, honoured only in a QA daemon.
pub const QA_IDLE_ENV: &str = "NOSTROMO_QA_IDLE_SECS";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IdlePolicy {
    pub warn_after: Duration,
    pub close_after: Duration,
}

/// What an idle remote shell is owed right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdleAction {
    None,
    /// Warn once; the shell closes at `closes_at`.
    Warn {
        closes_at: Instant,
    },
    Close,
}

impl Default for IdlePolicy {
    fn default() -> Self {
        Self {
            warn_after: WARN_AFTER,
            close_after: CLOSE_AFTER,
        }
    }
}

impl IdlePolicy {
    /// The policy scaled to close after `secs` (warn at `secs - 2·secs/15`,
    /// the same 2/15 lead as the real 13/15 minutes).
    pub fn scaled(secs: u64) -> Self {
        let secs = secs.max(1);
        // Warn strictly before close, even for tiny values.
        let lead = (secs * 2 / 15).max(1);
        Self {
            warn_after: Duration::from_secs(secs - lead),
            close_after: Duration::from_secs(secs),
        }
    }

    /// The policy this daemon runs: the QA override applies only when
    /// `qa_daemon` (`NOSTROMO_QA_DAEMON=1`); otherwise it is ignored loudly.
    pub fn resolve(qa_daemon: bool, override_secs: Option<&str>) -> Self {
        let Some(raw) = override_secs else {
            return Self::default();
        };
        if !qa_daemon {
            warn!("{QA_IDLE_ENV} ignored: it is honoured only when NOSTROMO_QA_DAEMON=1");
            return Self::default();
        }
        match raw.trim().parse::<u64>() {
            Ok(secs) if secs > 0 => Self::scaled(secs),
            _ => {
                warn!("{QA_IDLE_ENV}={raw:?} is not a positive number of seconds; ignored");
                Self::default()
            }
        }
    }

    /// The policy from the process environment.
    pub fn from_env() -> Self {
        let qa = std::env::var("NOSTROMO_QA_DAEMON").is_ok_and(|v| v == "1");
        Self::resolve(qa, std::env::var(QA_IDLE_ENV).ok().as_deref())
    }

    /// What a shell whose last keystroke was at `last_keystroke` is owed at
    /// `now`; `warned` is whether it has had its warning since then.
    pub fn evaluate(&self, last_keystroke: Instant, now: Instant, warned: bool) -> IdleAction {
        let idle = now.saturating_duration_since(last_keystroke);
        if idle >= self.close_after {
            IdleAction::Close
        } else if idle >= self.warn_after && !warned {
            IdleAction::Warn {
                closes_at: last_keystroke + self.close_after,
            }
        } else {
            IdleAction::None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn warns_at_exactly_thirteen_minutes_and_closes_at_fifteen() {
        let p = IdlePolicy::default();
        let t0 = Instant::now();
        assert_eq!(
            p.evaluate(t0, t0 + secs(13 * 60 - 1), false),
            IdleAction::None
        );
        assert_eq!(
            p.evaluate(t0, t0 + secs(13 * 60), false),
            IdleAction::Warn {
                closes_at: t0 + secs(15 * 60)
            }
        );
        assert_eq!(
            p.evaluate(t0, t0 + secs(15 * 60 - 1), true),
            IdleAction::None
        );
        assert_eq!(p.evaluate(t0, t0 + secs(15 * 60), true), IdleAction::Close);
    }

    #[test]
    fn a_warned_shell_is_not_warned_again_but_still_closes() {
        let p = IdlePolicy::default();
        let t0 = Instant::now();
        assert_eq!(p.evaluate(t0, t0 + secs(14 * 60), true), IdleAction::None);
        assert_eq!(p.evaluate(t0, t0 + secs(20 * 60), true), IdleAction::Close);
        // An unwarned shell found past the close time closes without a warning.
        assert_eq!(p.evaluate(t0, t0 + secs(16 * 60), false), IdleAction::Close);
    }

    #[test]
    fn the_qa_override_scales_the_policy() {
        let p = IdlePolicy::scaled(15);
        assert_eq!(p.close_after, secs(15));
        assert_eq!(p.warn_after, secs(13));
        let p = IdlePolicy::scaled(150);
        assert_eq!((p.warn_after, p.close_after), (secs(130), secs(150)));
    }

    #[test]
    fn a_tiny_scaled_policy_still_warns_strictly_before_it_closes() {
        for n in 1..=15 {
            let p = IdlePolicy::scaled(n);
            assert!(p.warn_after < p.close_after, "n={n}: {p:?}");
        }
        assert_eq!(IdlePolicy::scaled(1).warn_after, secs(0));
    }

    #[test]
    fn the_qa_override_is_honoured_only_in_a_qa_daemon() {
        assert_eq!(
            IdlePolicy::resolve(true, Some("30")),
            IdlePolicy::scaled(30)
        );
        assert_eq!(
            IdlePolicy::resolve(false, Some("30")),
            IdlePolicy::default()
        );
        assert_eq!(IdlePolicy::resolve(true, None), IdlePolicy::default());
        assert_eq!(
            IdlePolicy::resolve(true, Some("zero")),
            IdlePolicy::default()
        );
        assert_eq!(IdlePolicy::resolve(true, Some("0")), IdlePolicy::default());
    }
}
