//! The cap on notice turns (SR5) and the loop guard (R10), per focus: Jonesy's
//! (`jonesy_core::limits`), under the names this module has always used.
//!
//! * **Cap:** at most [`MAX_NOTICE_TURNS_PER_HOUR`] notice turns per focus in
//!   any rolling hour, counted when a turn whose message the engine wrote
//!   starts (a wake or a delivery queued behind another turn: plan index Q3).
//! * **Loop guard:** a notice turn that queued a job of its own focus
//!   ("notice-born") grows the chain; one that did not ends it, and so does any
//!   turn the user starts. At [`CHAIN_LIMIT`] the focus's deliveries wait for
//!   the user.

pub use jonesy_core::limits::{
    local_day, DayCount, Limits, CHAIN_LIMIT, DAY_MS, HOUR_MS,
    MAX_EVENT_TURNS_PER_HOUR as MAX_NOTICE_TURNS_PER_HOUR, WAKE_DAYS,
};
