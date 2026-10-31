//! The cap on notice turns (SR5) and the loop guard (R10), per focus.
//!
//! * **Cap:** at most [`MAX_NOTICE_TURNS_PER_HOUR`] notice turns per focus in
//!   any rolling hour, counted when a turn whose message the engine wrote
//!   starts (a wake or a delivery queued behind another turn: plan index Q3).
//! * **Loop guard:** a notice turn that queued a job of its own focus
//!   ("notice-born") grows the chain; one that did not ends it, and so does any
//!   turn the user starts. At [`CHAIN_LIMIT`] the focus's deliveries wait for
//!   the user.
//!
//! All times are milliseconds from the engine's injected clock.

use chrono::{Local, TimeZone};
use serde::{Deserialize, Serialize};

/// Notice turns allowed per focus per rolling hour.
pub const MAX_NOTICE_TURNS_PER_HOUR: usize = 6;
/// Notice turns in a row that each queued a notice-born job before deliveries
/// wait for the user.
pub const CHAIN_LIMIT: u32 = 3;
pub const HOUR_MS: i64 = 60 * 60 * 1000;
pub const DAY_MS: i64 = 24 * HOUR_MS;
/// How many local days `wakes_by_day` reports.
pub const WAKE_DAYS: usize = 7;
/// Notice-turn times older than this are forgotten.
const WAKE_HISTORY_MS: i64 = 8 * DAY_MS;

/// One local day's notice turns (`MotherNoticeState.focuses[].wakes_by_day`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DayCount {
    /// `YYYY-MM-DD`, local time.
    pub day: String,
    pub count: u32,
}

/// A focus's cap and loop-guard state. Persisted with the focus.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Limits {
    /// When each notice turn started, oldest first.
    #[serde(default)]
    pub wakes: Vec<i64>,
    /// Notice turns in a row that queued a notice-born job.
    #[serde(default)]
    pub chain: u32,
}

impl Limits {
    /// A notice turn started at `now`.
    pub fn note_notice_turn(&mut self, now: i64) {
        self.wakes.push(now);
        self.wakes.retain(|t| now - *t < WAKE_HISTORY_MS);
    }

    /// Notice turns in the hour up to `now`.
    pub fn turns_in_hour(&self, now: i64) -> usize {
        self.wakes
            .iter()
            .filter(|t| **t <= now && now - **t < HOUR_MS)
            .count()
    }

    /// Is the hourly cap reached at `now`?
    pub fn capped(&self, now: i64) -> bool {
        self.turns_in_hour(now) >= MAX_NOTICE_TURNS_PER_HOUR
    }

    /// Has the chain reached the loop guard?
    pub fn chain_held(&self) -> bool {
        self.chain >= CHAIN_LIMIT
    }

    /// A notice turn ended; `born` says whether it queued a notice-born job.
    pub fn notice_turn_ended(&mut self, born: bool) {
        self.chain = if born {
            self.chain.saturating_add(1)
        } else {
            0
        };
    }

    /// The user started a turn: the chain is over.
    pub fn user_turn(&mut self) {
        self.chain = 0;
    }

    /// Notice turns per local day for the last [`WAKE_DAYS`] days up to `now`,
    /// oldest first, days without any left out.
    pub fn wakes_by_day(&self, now: i64) -> Vec<DayCount> {
        let Some(today) = local_day(now) else {
            return Vec::new();
        };
        let first = today - chrono::Duration::days(WAKE_DAYS as i64 - 1);
        let mut days: std::collections::BTreeMap<chrono::NaiveDate, u32> = Default::default();
        for t in &self.wakes {
            if let Some(day) = local_day(*t).filter(|d| *d >= first && *d <= today) {
                *days.entry(day).or_default() += 1;
            }
        }
        days.into_iter()
            .map(|(day, count)| DayCount {
                day: day.format("%Y-%m-%d").to_string(),
                count,
            })
            .collect()
    }

    /// Nothing worth keeping (no recent turns, no chain).
    pub fn is_empty(&self) -> bool {
        self.wakes.is_empty() && self.chain == 0
    }
}

/// The local calendar day of `ms`.
pub fn local_day(ms: i64) -> Option<chrono::NaiveDate> {
    Local
        .timestamp_millis_opt(ms)
        .single()
        .map(|t| t.date_naive())
}
