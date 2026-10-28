//! Reconnect delay schedule for `nostromo-mcp-bridge`.

use std::time::Duration;

/// Exponential backoff: `min`, doubling per attempt, capped at `max`.
#[derive(Debug, Clone, Copy)]
pub struct Backoff {
    min: Duration,
    max: Duration,
}

impl Backoff {
    pub fn new(min: Duration, max: Duration) -> Self {
        Self {
            min,
            max: max.max(min),
        }
    }

    /// The un-jittered delay before retry number `attempt` (0-based).
    /// Saturates at `max`; never overflows for any attempt number.
    pub fn nominal(&self, attempt: u32) -> Duration {
        let factor = 1u32.checked_shl(attempt).unwrap_or(u32::MAX);
        self.min
            .checked_mul(factor)
            .map_or(self.max, |d| d.min(self.max))
    }

    /// The nominal delay scaled to between 50% (`unit` = 0) and 100%
    /// (`unit` → 1) of itself. Never exceeds `max`.
    pub fn jittered(&self, attempt: u32, unit: f64) -> Duration {
        let unit = if unit.is_finite() {
            unit.clamp(0.0, 1.0)
        } else {
            0.0
        };
        let nominal = self.nominal(attempt);
        nominal.mul_f64(0.5 + 0.5 * unit).min(nominal)
    }
}

/// A uniform-ish value in `[0, 1)` for jitter. Not cryptographic.
pub(super) fn random_unit() -> f64 {
    let bits = (uuid::Uuid::new_v4().as_u128() >> 75) as u64; // 53 bits
    bits as f64 / (1u64 << 53) as f64
}
