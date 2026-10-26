//! When the daily run happens (A7).
//!
//! `report_time` is the ready-by time in the daemon's local time; the run
//! starts `lead_minutes` before it. The engine looks at the wall clock every
//! tick rather than sleeping until a deadline (a sleep drifts across system
//! sleep), and asks [`is_due`] each time. Every day, weekends included.
//!
//! Pure: the clock and the local time zone are passed in.

use chrono::{
    DateTime, Duration, FixedOffset, Local, LocalResult, NaiveDate, NaiveDateTime, NaiveTime,
    TimeZone, Utc,
};

use crate::huey::config::HueyConfig;
use crate::huey::run::{FailReason, Trigger};

/// A run that starts more than this many minutes after its start time is
/// late, and says why.
pub const LATE_AFTER_MINUTES: i64 = 10;
/// A failed curated run is retried once, this many minutes later (V5).
pub const RETRY_AFTER_MINUTES: i64 = 10;

/// Converts between UTC and the daemon's local wall-clock time.
pub trait LocalTime: Send + Sync {
    fn to_local(&self, at: DateTime<Utc>) -> NaiveDateTime;
    /// A local time that does not exist (a DST gap) moves forward to the
    /// first one that does; an ambiguous one takes the earlier instant.
    fn to_utc(&self, local: NaiveDateTime) -> DateTime<Utc>;
}

/// The real one: `chrono::Local`.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemLocalTime;

impl LocalTime for SystemLocalTime {
    fn to_local(&self, at: DateTime<Utc>) -> NaiveDateTime {
        at.with_timezone(&Local).naive_local()
    }

    fn to_utc(&self, local: NaiveDateTime) -> DateTime<Utc> {
        resolve(&Local, local)
    }
}

/// A fixed offset from UTC, for tests (and anyone who wants one).
#[derive(Debug, Clone, Copy)]
pub struct FixedLocalTime(pub FixedOffset);

impl FixedLocalTime {
    pub fn utc() -> Self {
        Self(FixedOffset::east_opt(0).expect("zero offset"))
    }

    /// `hours` east of UTC (negative for the Americas).
    pub fn hours(hours: i32) -> Self {
        Self(FixedOffset::east_opt(hours * 3600).expect("offset in range"))
    }
}

impl LocalTime for FixedLocalTime {
    fn to_local(&self, at: DateTime<Utc>) -> NaiveDateTime {
        at.with_timezone(&self.0).naive_local()
    }

    fn to_utc(&self, local: NaiveDateTime) -> DateTime<Utc> {
        resolve(&self.0, local)
    }
}

fn resolve<Tz: TimeZone>(tz: &Tz, local: NaiveDateTime) -> DateTime<Utc> {
    let mut probe = local;
    // A DST gap is at most a few hours; step forward until a time exists.
    for _ in 0..(6 * 4) {
        match tz.from_local_datetime(&probe) {
            LocalResult::Single(t) => return t.with_timezone(&Utc),
            LocalResult::Ambiguous(early, _) => return early.with_timezone(&Utc),
            LocalResult::None => probe += Duration::minutes(15),
        }
    }
    Utc.from_utc_datetime(&local)
}

/// The local date `at` falls on: the date a run at `at` reports for.
pub fn local_date(at: DateTime<Utc>, tz: &dyn LocalTime) -> NaiveDate {
    tz.to_local(at).date()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Schedule {
    /// Ready-by, local time.
    pub report_time: NaiveTime,
    pub lead_minutes: u32,
}

impl Schedule {
    pub fn from_config(config: &HueyConfig) -> Self {
        Self {
            report_time: config.report_time,
            lead_minutes: config.lead_minutes,
        }
    }

    /// When the report for `date` should be ready.
    pub fn ready_by(&self, date: NaiveDate, tz: &dyn LocalTime) -> DateTime<Utc> {
        tz.to_utc(date.and_time(self.report_time))
    }

    /// When the run for `date` starts: `lead_minutes` before ready-by.
    pub fn run_at(&self, date: NaiveDate, tz: &dyn LocalTime) -> DateTime<Utc> {
        self.ready_by(date, tz) - Duration::minutes(i64::from(self.lead_minutes))
    }

    /// The next scheduled start at or after `now`.
    pub fn next_run_at(&self, now: DateTime<Utc>, tz: &dyn LocalTime) -> DateTime<Utc> {
        let date = self.report_date(now, tz);
        let at = self.run_at(date, tz);
        if at >= now {
            at
        } else {
            self.run_at(date + Duration::days(1), tz)
        }
    }

    /// The date a run at `now` reports for: the local date, or tomorrow once
    /// tomorrow's run has started (a start time that falls before midnight,
    /// say `00:15` with a 30-minute lead).
    pub fn report_date(&self, now: DateTime<Utc>, tz: &dyn LocalTime) -> NaiveDate {
        let today = local_date(now, tz);
        let tomorrow = today + Duration::days(1);
        if self.run_at(tomorrow, tz) <= now {
            tomorrow
        } else {
            today
        }
    }

    /// The start time as the local clock shows it (`06:00`).
    pub fn run_time_label(&self) -> String {
        let start = self.report_time - Duration::minutes(i64::from(self.lead_minutes));
        start.format("%H:%M").to_string()
    }
}

/// What has already happened for one report date (from `runs.jsonl`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DayRuns {
    /// A report for the date exists.
    pub produced: bool,
    /// Failed attempts, oldest first.
    pub failures: Vec<(DateTime<Utc>, FailReason)>,
}

impl DayRuns {
    pub fn attempted(&self) -> bool {
        self.produced || !self.failures.is_empty()
    }

    pub fn last_failure(&self) -> Option<(DateTime<Utc>, FailReason)> {
        self.failures.last().copied()
    }

    /// Model failures for the date.
    pub fn model_failures(&self) -> usize {
        self.failures
            .iter()
            .filter(|(_, r)| *r == FailReason::ModelFailed)
            .count()
    }

    /// Only the failures that ended at or after `start`: a manual run
    /// before the scheduled start does not use up the day.
    pub fn since(&self, start: DateTime<Utc>) -> DayRuns {
        DayRuns {
            produced: self.produced,
            failures: self
                .failures
                .iter()
                .copied()
                .filter(|(at, _)| *at >= start)
                .collect(),
        }
    }
}

/// What the scheduler should do now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Due {
    No,
    Run {
        trigger: Trigger,
        late_reason: Option<String>,
    },
}

/// Should a run start now for today's report?
///
/// - Nothing happened today and the start time has passed: run. More than
///   [`LATE_AFTER_MINUTES`] past it, the run is a catch-up and says why.
/// - Today's only attempt failed in the model: retry once,
///   [`RETRY_AFTER_MINUTES`] after it ended (V5).
/// - Otherwise (a report exists, a fetch failed, the retry was used): no.
///
/// `day` is the record for `schedule.report_date(now)`; failures from
/// before the start time (a manual run) are not counted.
pub fn is_due(schedule: &Schedule, now: DateTime<Utc>, tz: &dyn LocalTime, day: &DayRuns) -> Due {
    if day.produced {
        return Due::No;
    }
    let date = schedule.report_date(now, tz);
    let run_at = schedule.run_at(date, tz);
    if now < run_at {
        return Due::No;
    }
    let day = day.since(run_at);
    match day.last_failure() {
        None => {
            let late = now - run_at > Duration::minutes(LATE_AFTER_MINUTES);
            Due::Run {
                trigger: if late {
                    Trigger::CatchUp
                } else {
                    Trigger::Scheduled
                },
                late_reason: late.then(|| late_reason(schedule)),
            }
        }
        Some((at, FailReason::ModelFailed))
            if day.model_failures() == 1
                && now - at >= Duration::minutes(RETRY_AFTER_MINUTES) =>
        {
            Due::Run {
                trigger: Trigger::Retry,
                late_reason: None,
            }
        }
        Some(_) => Due::No,
    }
}

/// `machine asleep or daemon not running at 06:00`.
pub fn late_reason(schedule: &Schedule) -> String {
    format!(
        "machine asleep or daemon not running at {}",
        schedule.run_time_label()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 26, h, m, 0).unwrap()
    }

    fn sched() -> Schedule {
        Schedule::from_config(&HueyConfig::default())
    }

    #[test]
    fn runs_at_six_local_and_is_ready_by_half_past() {
        let tz = FixedLocalTime::hours(-5);
        let date = NaiveDate::from_ymd_opt(2026, 10, 26).unwrap();
        assert_eq!(sched().run_at(date, &tz), at(11, 0));
        assert_eq!(sched().ready_by(date, &tz), at(11, 30));
        assert_eq!(sched().next_run_at(at(12, 0), &tz), at(11, 0) + Duration::days(1));
    }

    #[test]
    fn due_on_time_late_and_retry() {
        let tz = FixedLocalTime::utc();
        let none = DayRuns::default();
        assert_eq!(is_due(&sched(), at(5, 59), &tz, &none), Due::No);
        assert_eq!(
            is_due(&sched(), at(6, 0), &tz, &none),
            Due::Run {
                trigger: Trigger::Scheduled,
                late_reason: None
            }
        );
        assert_eq!(
            is_due(&sched(), at(9, 0), &tz, &none),
            Due::Run {
                trigger: Trigger::CatchUp,
                late_reason: Some("machine asleep or daemon not running at 06:00".into())
            }
        );
        let failed = DayRuns {
            produced: false,
            failures: vec![(at(6, 0), FailReason::ModelFailed)],
        };
        assert_eq!(is_due(&sched(), at(6, 9), &tz, &failed), Due::No);
        assert!(matches!(
            is_due(&sched(), at(6, 10), &tz, &failed),
            Due::Run {
                trigger: Trigger::Retry,
                ..
            }
        ));
        let twice = DayRuns {
            produced: false,
            failures: vec![
                (at(6, 0), FailReason::ModelFailed),
                (at(6, 10), FailReason::ModelFailed),
            ],
        };
        assert_eq!(is_due(&sched(), at(8, 0), &tz, &twice), Due::No);
        let fetch = DayRuns {
            produced: false,
            failures: vec![(at(6, 0), FailReason::FetchFailed)],
        };
        assert_eq!(is_due(&sched(), at(8, 0), &tz, &fetch), Due::No);
    }

    #[test]
    fn a_manual_failure_before_the_start_does_not_use_up_the_day() {
        let tz = FixedLocalTime::utc();
        let early = DayRuns {
            produced: false,
            failures: vec![(at(5, 50), FailReason::FetchFailed)],
        };
        assert_eq!(
            is_due(&sched(), at(6, 0), &tz, &early),
            Due::Run {
                trigger: Trigger::Scheduled,
                late_reason: None
            }
        );
    }

    #[test]
    fn a_start_before_midnight_reports_for_the_next_day_on_time() {
        let tz = FixedLocalTime::utc();
        let s = Schedule {
            report_time: NaiveTime::from_hms_opt(0, 15, 0).unwrap(),
            lead_minutes: 30,
        };
        let d26 = NaiveDate::from_ymd_opt(2026, 10, 26).unwrap();
        assert_eq!(s.report_date(at(23, 44), &tz), d26);
        assert_eq!(s.report_date(at(23, 45), &tz), d26 + Duration::days(1));
        assert_eq!(
            is_due(&s, at(23, 45), &tz, &DayRuns::default()),
            Due::Run {
                trigger: Trigger::Scheduled,
                late_reason: None
            }
        );
        assert_eq!(s.next_run_at(at(12, 0), &tz), at(23, 45));
    }
}

