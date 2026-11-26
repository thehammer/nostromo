//! W13-8..16, 29, 31, 34, 35: when a notification is sent.
//!
//! `DeviceSchedule::step(now, waiting, prefs, cfg, baseline)` is a pure state
//! machine: nothing in it reads a clock, so every test here runs on a fabricated
//! timeline. A device's first step is its baseline (`baseline = true`): what is
//! already waiting is counted but never pushed. Every test starts with that
//! step, then feeds snapshots of "what is waiting now" at chosen instants.
//!
//! What a step returns is the contract: `Alert` (the item's own notification),
//! `Summary` (burst, morning or evening), `Withdraw` (with or without a
//! delivered notification to replace) and `Log` (something that is recorded but
//! not sent). Rendering and the relay are in `tests/push_vocab.rs` and
//! `tests/push_engine.rs`.

use chrono::{DateTime, Duration, NaiveTime, TimeZone, Utc};
use nostromo::push::items::{Detail, ItemKey, MotherReason, Waiting};
use nostromo::push::schedule::{
    enabled_waiting, in_quiet, DeviceSchedule, Effect, ScheduleCfg, SummaryReason, BURST_THRESHOLD,
};
use nostromo::push::wire::{Presence, PushKinds, PushOutcome, PushPrefs, QuietHours};

// ── fixtures ─────────────────────────────────────────────────────────────────

fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, mo, d, h, mi, s).unwrap()
}

/// 10:00 UTC on an ordinary day: outside default quiet hours, before 17:30.
fn t0() -> DateTime<Utc> {
    utc(2026, 11, 26, 10, 0, 0)
}

fn at(secs: i64) -> DateTime<Utc> {
    t0() + Duration::seconds(secs)
}

fn cfg() -> ScheduleCfg {
    ScheduleCfg::default()
}

fn prefs() -> PushPrefs {
    PushPrefs::default()
}

fn chicago() -> PushPrefs {
    PushPrefs {
        tz: "America/Chicago".into(),
        ..PushPrefs::default()
    }
}

fn mother(job: &str, start: Option<DateTime<Utc>>) -> Waiting {
    Waiting {
        key: ItemKey::Mother {
            host: "kobe".into(),
            job_id: job.into(),
        },
        item_ref: format!("ref-{job}"),
        host: "kobe".into(),
        start,
        detail: Detail::Mother {
            job_ref: Some("3f9a1c2e".into()),
            reason: MotherReason::Asked,
            repo: None,
            owner: None,
        },
        preexisting: false,
    }
}

fn review(number: u64, start: Option<DateTime<Utc>>) -> Waiting {
    Waiting {
        key: ItemKey::Review {
            host: "kobe".into(),
            repo: "Carefeed/admin-portal".into(),
            number,
        },
        item_ref: format!("ref-pr{number}"),
        host: "kobe".into(),
        start,
        detail: Detail::Review {
            number,
            changed_lines: Some(10),
            repo: "admin-portal".into(),
            owner: Some("Carefeed".into()),
        },
        preexisting: false,
    }
}

fn decision(
    id: &str,
    start: DateTime<Utc>,
    presence: Option<Presence>,
    deadline: Option<DateTime<Utc>>,
) -> Waiting {
    Waiting {
        key: ItemKey::Decision {
            host: "kobe".into(),
            request_id: id.into(),
        },
        item_ref: format!("ref-{id}"),
        host: "kobe".into(),
        start: Some(start),
        detail: Detail::Decision {
            agent: nostromo::push::wire::AgentClass::Claudia,
            choices: 3,
            deadline,
            presence,
            repo: None,
            owner: None,
        },
        preexisting: false,
    }
}

fn attention(job: &str, reason: &str, since: &str) -> Waiting {
    Waiting {
        key: ItemKey::Attention {
            host: "kobe".into(),
            job_id: job.into(),
            reason: reason.into(),
            since: since.into(),
        },
        item_ref: format!("ref-{job}-{reason}"),
        host: "kobe".into(),
        start: DateTime::parse_from_rfc3339(since)
            .ok()
            .map(|t| t.with_timezone(&Utc)),
        detail: Detail::Attention,
        preexisting: false,
    }
}

fn label(w: &Waiting) -> String {
    match &w.key {
        ItemKey::Mother { job_id, .. } => job_id.clone(),
        ItemKey::Decision { request_id, .. } => request_id.clone(),
        ItemKey::Review { number, .. } => format!("pr{number}"),
        ItemKey::Attention { job_id, reason, .. } => format!("{job_id}:{reason}"),
    }
}

fn alerts(fx: &[Effect]) -> Vec<String> {
    let mut v: Vec<String> = fx
        .iter()
        .filter_map(|e| match e {
            Effect::Alert(w) => Some(label(w)),
            _ => None,
        })
        .collect();
    v.sort();
    v
}

fn summaries(fx: &[Effect]) -> Vec<(SummaryReason, Vec<String>)> {
    fx.iter()
        .filter_map(|e| match e {
            Effect::Summary { reason, covered } => {
                let mut c: Vec<String> = covered.iter().map(label).collect();
                c.sort();
                Some((*reason, c))
            }
            _ => None,
        })
        .collect()
}

fn withdrawn(fx: &[Effect]) -> Vec<(String, bool)> {
    let mut v: Vec<(String, bool)> = fx
        .iter()
        .filter_map(|e| match e {
            Effect::Withdraw {
                item,
                had_notification,
            } => Some((label(item), *had_notification)),
            _ => None,
        })
        .collect();
    v.sort();
    v
}

fn logged(fx: &[Effect]) -> Vec<(String, PushOutcome)> {
    let mut v: Vec<(String, PushOutcome)> = fx
        .iter()
        .filter_map(|e| match e {
            Effect::Log { item, outcome } => Some((label(item), *outcome)),
            _ => None,
        })
        .collect();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}

/// A schedule that has taken its baseline step at `now` with nothing waiting.
fn started(prefs: &PushPrefs, now: DateTime<Utc>) -> DeviceSchedule {
    let mut s = DeviceSchedule::new();
    let fx = s.step(now, &[], prefs, &cfg(), true);
    assert!(fx.is_empty(), "the baseline step sends nothing: {fx:?}");
    s
}

fn step(
    s: &mut DeviceSchedule,
    now: DateTime<Utc>,
    waiting: &[Waiting],
    prefs: &PushPrefs,
) -> Vec<Effect> {
    s.step(now, waiting, prefs, &cfg(), false)
}

fn is_empty(fx: &[Effect]) -> bool {
    fx.is_empty()
}

// ── W13-8: the grace delay ───────────────────────────────────────────────────

#[test]
fn a_mother_or_review_item_is_sent_at_exactly_120_seconds_and_never_before() {
    for item in [mother("j1", Some(at(0))), review(4821, Some(at(0)))] {
        let p = prefs();
        let mut s = started(&p, at(-1));
        let w = [item.clone()];
        assert!(is_empty(&step(&mut s, at(0), &w, &p)), "at the start");
        assert!(is_empty(&step(&mut s, at(60), &w, &p)), "+60 s");
        assert!(is_empty(&step(&mut s, at(119), &w, &p)), "+119 s");
        let fx = step(&mut s, at(120), &w, &p);
        assert_eq!(alerts(&fx), vec![label(&item)], "+120 s");
        assert_eq!(fx.len(), 1, "nothing else: {fx:?}");
    }
}

#[test]
fn the_grace_delay_counts_from_the_jobs_own_start_not_from_when_the_engine_noticed() {
    // Mother's paused_at was 100 s ago when the engine first sees the job.
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [mother("j1", Some(at(-100)))];
    assert!(is_empty(&step(&mut s, at(0), &w, &p)));
    assert!(is_empty(&step(&mut s, at(19), &w, &p)));
    assert_eq!(alerts(&step(&mut s, at(20), &w, &p)), vec!["j1"]);
}

#[test]
fn an_item_with_no_start_of_its_own_counts_from_when_it_was_first_seen() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [review(4821, None)];
    assert!(is_empty(&step(&mut s, at(5), &w, &p)), "first seen at +5 s");
    assert!(is_empty(&step(&mut s, at(124), &w, &p)));
    assert_eq!(alerts(&step(&mut s, at(125), &w, &p)), vec!["pr4821"]);
}

#[test]
fn the_grace_delay_is_the_configured_one() {
    let p = prefs();
    let short = ScheduleCfg {
        grace: Duration::seconds(5),
        decision_grace: Duration::seconds(1),
    };
    let mut s = DeviceSchedule::new();
    s.step(at(-1), &[], &p, &short, true);
    let w = [mother("j1", Some(at(0)))];
    assert!(s.step(at(4), &w, &p, &short, false).is_empty());
    assert_eq!(alerts(&s.step(at(5), &w, &p, &short, false)), vec!["j1"]);
}

#[test]
fn an_item_resolved_before_120_seconds_is_never_sent_and_logs_skipped_resolved_in_grace() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [mother("j1", Some(at(0)))];
    assert!(is_empty(&step(&mut s, at(60), &w, &p)));
    let fx = step(&mut s, at(119), &[], &p);
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::SkippedResolvedInGrace)]
    );
    assert!(
        alerts(&fx).is_empty() && withdrawn(&fx).is_empty(),
        "{fx:?}"
    );
    // And it never comes back as a notification.
    for t in [120, 121, 300] {
        assert!(is_empty(&step(&mut s, at(t), &[], &p)), "+{t} s");
    }
}

// ── W13-31: a decision's own timing (S7a) ────────────────────────────────────

#[test]
fn a_decision_whose_mac_is_away_is_sent_at_once() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [decision("d1", at(0), Some(Presence::Away), None)];
    let fx = step(&mut s, at(0), &w, &p);
    assert_eq!(alerts(&fx), vec!["d1"]);
}

#[test]
fn a_decision_with_an_active_or_unknown_mac_is_sent_at_exactly_30_seconds() {
    for presence in [Some(Presence::Active), None] {
        let p = prefs();
        let mut s = started(&p, at(-1));
        let w = [decision("d1", at(0), presence, None)];
        assert!(is_empty(&step(&mut s, at(0), &w, &p)), "{presence:?} +0");
        assert!(is_empty(&step(&mut s, at(29), &w, &p)), "{presence:?} +29");
        assert_eq!(
            alerts(&step(&mut s, at(30), &w, &p)),
            vec!["d1"],
            "{presence:?} +30"
        );
    }
}

#[test]
fn a_decision_answered_within_30_seconds_sends_nothing_and_logs_the_skip() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [decision("d1", at(0), Some(Presence::Active), None)];
    assert!(is_empty(&step(&mut s, at(0), &w, &p)));
    let fx = step(&mut s, at(29), &[], &p);
    assert_eq!(
        logged(&fx),
        vec![("d1".to_string(), PushOutcome::SkippedResolvedInGrace)]
    );
    assert!(alerts(&fx).is_empty());
    assert!(is_empty(&step(&mut s, at(30), &[], &p)));
}

#[test]
fn a_decision_rebroadcast_as_away_is_sent_when_it_turns_away_and_only_once() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let active = [decision("d1", at(0), Some(Presence::Active), None)];
    assert!(is_empty(&step(&mut s, at(0), &active, &p)));
    assert!(is_empty(&step(&mut s, at(9), &active, &p)));
    // At +10 s the Mac goes away: the same decision, now with presence `away`.
    let away = [decision("d1", at(0), Some(Presence::Away), None)];
    assert_eq!(alerts(&step(&mut s, at(10), &away, &p)), vec!["d1"]);
    // Not again: not on the next tick, not at the 30 s mark, not when it flips back.
    assert!(is_empty(&step(&mut s, at(11), &away, &p)));
    assert!(is_empty(&step(&mut s, at(30), &away, &p)));
    assert!(is_empty(&step(&mut s, at(40), &active, &p)));
    assert!(is_empty(&step(&mut s, at(60), &away, &p)));
}

#[test]
fn the_decision_grace_is_its_own_setting() {
    let p = prefs();
    let cfg = ScheduleCfg {
        grace: Duration::seconds(120),
        decision_grace: Duration::seconds(7),
    };
    let mut s = DeviceSchedule::new();
    s.step(at(-1), &[], &p, &cfg, true);
    let w = [decision("d1", at(0), None, None)];
    assert!(s.step(at(6), &w, &p, &cfg, false).is_empty());
    assert_eq!(alerts(&s.step(at(7), &w, &p, &cfg, false)), vec!["d1"]);
}

#[test]
fn a_decision_whose_deadline_passes_is_withdrawn_when_it_was_notified() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [decision("d1", at(0), Some(Presence::Active), Some(at(100)))];
    assert_eq!(alerts(&step(&mut s, at(30), &w, &p)), vec!["d1"]);
    assert!(is_empty(&step(&mut s, at(99), &w, &p)));
    // The asker gave up at +100 s: the frame may still be in the snapshot, but
    // the decision is no longer waiting.
    let fx = step(&mut s, at(100), &w, &p);
    assert_eq!(withdrawn(&fx), vec![("d1".to_string(), true)]);
}

#[test]
fn a_decision_that_times_out_before_it_is_due_is_skipped_not_sent() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [decision("d1", at(0), Some(Presence::Active), Some(at(20)))];
    assert!(is_empty(&step(&mut s, at(10), &w, &p)));
    let fx = step(&mut s, at(20), &w, &p);
    assert_eq!(
        logged(&fx),
        vec![("d1".to_string(), PushOutcome::SkippedResolvedInGrace)]
    );
    assert!(is_empty(&step(&mut s, at(30), &w, &p)), "never sent late");
}

// ── W13-13, W13-9: bursts ────────────────────────────────────────────────────

#[test]
fn four_grace_items_due_together_are_one_summary_and_no_individual_alerts() {
    assert_eq!(BURST_THRESHOLD, 4);
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w: Vec<Waiting> = (1..=4)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    assert!(is_empty(&step(&mut s, at(119), &w, &p)));
    let fx = step(&mut s, at(120), &w, &p);
    assert!(alerts(&fx).is_empty(), "no individual alert: {fx:?}");
    assert_eq!(
        summaries(&fx),
        vec![(
            SummaryReason::Burst,
            vec!["j1".into(), "j2".into(), "j3".into(), "j4".into()]
        )]
    );
    assert_eq!(fx.len(), 1, "{fx:?}");
    // The covered items never push individually afterwards, and leave quietly.
    assert!(is_empty(&step(&mut s, at(500), &w, &p)));
    let gone = step(&mut s, at(501), &[], &p);
    assert_eq!(
        withdrawn(&gone),
        ["j1", "j2", "j3", "j4"]
            .map(|j| (j.to_string(), false))
            .to_vec()
    );
}

#[test]
fn three_grace_items_due_together_are_three_alerts() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w: Vec<Waiting> = (1..=3)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

#[test]
fn reviews_and_mother_jobs_count_together_toward_a_burst() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = vec![
        mother("j1", Some(at(0))),
        mother("j2", Some(at(0))),
        review(1, Some(at(0))),
        review(2, Some(at(0))),
    ];
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(summaries(&fx).len(), 1);
    assert!(alerts(&fx).is_empty());
}

#[test]
fn the_burst_looks_ahead_one_grace_delay_for_items_that_will_come_due() {
    // j1 is due at +120. j2, j3 and j4 come due at +220, +230 and +239: all
    // inside the next 120 s, so four items fall within one grace delay.
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = vec![
        mother("j1", Some(at(0))),
        mother("j2", Some(at(100))),
        mother("j3", Some(at(110))),
        mother("j4", Some(at(119))),
    ];
    assert!(is_empty(&step(&mut s, at(119), &w, &p)));
    let fx = step(&mut s, at(120), &w, &p);
    assert!(alerts(&fx).is_empty(), "{fx:?}");
    assert_eq!(
        summaries(&fx),
        vec![(
            SummaryReason::Burst,
            vec!["j1".into(), "j2".into(), "j3".into(), "j4".into()]
        )]
    );
    for t in [220, 230, 239, 300] {
        assert!(
            is_empty(&step(&mut s, at(t), &w, &p)),
            "+{t} s: the rest were covered"
        );
    }
}

#[test]
fn an_item_due_exactly_one_grace_delay_later_is_outside_the_lookahead() {
    // Three items due at +120 and a fourth due at +240 (now + 120 s, exclusive).
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = vec![
        mother("j1", Some(at(0))),
        mother("j2", Some(at(0))),
        mother("j3", Some(at(0))),
        mother("j4", Some(at(120))),
    ];
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty());
    assert_eq!(alerts(&step(&mut s, at(240), &w, &p)), vec!["j4"]);
}

#[test]
fn a_decision_is_sent_individually_and_never_counted_toward_a_burst() {
    // Four grace items and a decision: one Summary for the four, the decision alone.
    let p = prefs();
    let mut s = started(&p, at(-1));
    let mut w: Vec<Waiting> = (1..=4)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    w.push(decision("d1", at(90), Some(Presence::Active), None));
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(
        alerts(&fx),
        vec!["d1"],
        "the decision is its own notification"
    );
    let sums = summaries(&fx);
    assert_eq!(sums.len(), 1);
    assert_eq!(sums[0].0, SummaryReason::Burst);
    assert!(
        !sums[0].1.contains(&"d1".to_string()),
        "a summary cannot carry a timeout"
    );
}

#[test]
fn a_decision_that_comes_due_within_the_lookahead_does_not_count_toward_the_burst() {
    // Three grace items due at +120 s, and a decision that comes due at +130 s,
    // inside the next grace delay: still three alerts, not a Summary.
    let p = prefs();
    let mut s = started(&p, at(-1));
    let mut w: Vec<Waiting> = (1..=3)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    w.push(decision("d1", at(100), Some(Presence::Active), None));
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    assert_eq!(alerts(&step(&mut s, at(130), &w, &p)), vec!["d1"]);
}

#[test]
fn decisions_do_not_tip_three_grace_items_into_a_burst() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let mut w: Vec<Waiting> = (1..=3)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    w.push(decision("d1", at(90), Some(Presence::Active), None));
    w.push(decision("d2", at(90), Some(Presence::Active), None));
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["d1", "d2", "j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

// ── W13-14: quiet hours ──────────────────────────────────────────────────────

fn quiet(start: &str, end: &str) -> QuietHours {
    QuietHours {
        start: start.into(),
        end: end.into(),
        enabled: true,
    }
}

fn time(h: u32, m: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(h, m, 0).unwrap()
}

#[test]
fn in_quiet_wraps_midnight_includes_the_start_and_excludes_the_end() {
    let q = quiet("22:00", "07:00");
    for (h, m, inside) in [
        (21, 59, false),
        (22, 0, true),
        (23, 30, true),
        (0, 0, true),
        (3, 15, true),
        (6, 59, true),
        (7, 0, false),
        (7, 1, false),
        (12, 0, false),
    ] {
        assert_eq!(in_quiet(time(h, m), &q), inside, "{h:02}:{m:02}");
    }
}

#[test]
fn in_quiet_without_a_wrap_and_with_start_equal_to_end() {
    let day = quiet("01:00", "05:00");
    for (h, m, inside) in [
        (0, 59, false),
        (1, 0, true),
        (4, 59, true),
        (5, 0, false),
        (23, 0, false),
    ] {
        assert_eq!(in_quiet(time(h, m), &day), inside, "{h:02}:{m:02}");
    }
    // start == end is empty, not "all day".
    let empty = quiet("08:00", "08:00");
    for (h, m) in [(0, 0), (7, 59), (8, 0), (8, 1), (23, 59)] {
        assert!(!in_quiet(time(h, m), &empty), "{h:02}:{m:02}");
    }
}

#[test]
fn nothing_alerts_during_quiet_hours_and_held_items_are_logged() {
    // 2026-11-25 22:30 CST (04:30 UTC on the 25th... CST is UTC-6).
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 25, 2, 0, 0)); // 20:00 CST on the 24th
    let w = [
        mother("j1", Some(utc(2026, 11, 25, 4, 30, 0))),
        review(4821, Some(utc(2026, 11, 25, 4, 30, 0))),
        decision(
            "d1",
            utc(2026, 11, 25, 4, 30, 0),
            Some(Presence::Away),
            None,
        ),
    ];
    // The decision (away: due at once) and the grace items (due +120 s) are all
    // due inside quiet hours.
    let fx = step(&mut s, utc(2026, 11, 25, 4, 30, 0), &w, &p);
    assert!(alerts(&fx).is_empty(), "{fx:?}");
    assert_eq!(
        logged(&fx),
        vec![("d1".to_string(), PushOutcome::HeldQuietHours)]
    );
    let fx = step(&mut s, utc(2026, 11, 25, 4, 32, 0), &w, &p);
    assert!(alerts(&fx).is_empty(), "{fx:?}");
    assert_eq!(
        logged(&fx),
        vec![
            ("j1".to_string(), PushOutcome::HeldQuietHours),
            ("pr4821".to_string(), PushOutcome::HeldQuietHours)
        ]
    );
    // Hours later, still quiet, still nothing.
    for (h, m) in [(5, 0), (8, 0), (12, 59)] {
        let fx = step(&mut s, utc(2026, 11, 25, h, m, 0), &w, &p);
        assert!(
            alerts(&fx).is_empty() && summaries(&fx).is_empty(),
            "{h}:{m} UTC: {fx:?}"
        );
    }
}

#[test]
fn one_morning_summary_at_the_end_of_quiet_hours_when_something_is_still_waiting() {
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 25, 2, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 25, 4, 30, 0)))];
    step(&mut s, utc(2026, 11, 25, 4, 30, 0), &w, &p);
    step(&mut s, utc(2026, 11, 25, 4, 32, 0), &w, &p);
    // 06:59:59 local is still night.
    let fx = step(&mut s, utc(2026, 11, 25, 12, 59, 59), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    // 07:00 local (13:00 UTC): exactly one Summary, and not an alert for the held item.
    let fx = step(&mut s, utc(2026, 11, 25, 13, 0, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
    assert!(alerts(&fx).is_empty(), "{fx:?}");
    // Not again that morning, and the held item never becomes an individual alert.
    for (h, m) in [(13, 1), (13, 30), (15, 0)] {
        let fx = step(&mut s, utc(2026, 11, 25, h, m, 0), &w, &p);
        assert!(fx.is_empty(), "{h}:{m} UTC: {fx:?}");
    }
}

#[test]
fn no_morning_summary_when_everything_was_resolved_overnight() {
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 25, 2, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 25, 4, 30, 0)))];
    step(&mut s, utc(2026, 11, 25, 4, 30, 0), &w, &p);
    step(&mut s, utc(2026, 11, 25, 4, 32, 0), &w, &p);
    // Resolved at 06:00 UTC (midnight local): the withdrawal is still sent in
    // quiet hours (PRD C4), as a badge-only push because it never had a notification.
    let fx = step(&mut s, utc(2026, 11, 25, 6, 0, 0), &[], &p);
    assert_eq!(withdrawn(&fx), vec![("j1".to_string(), false)]);
    let fx = step(&mut s, utc(2026, 11, 25, 13, 0, 0), &[], &p);
    assert!(summaries(&fx).is_empty(), "nothing waits: {fx:?}");
}

#[test]
fn an_item_resolved_before_it_is_due_overnight_logs_the_skip() {
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 25, 2, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 25, 4, 30, 0)))];
    step(&mut s, utc(2026, 11, 25, 4, 30, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 25, 4, 31, 0), &[], &p);
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::SkippedResolvedInGrace)]
    );
}

#[test]
fn an_item_notified_before_quiet_hours_and_still_waiting_gets_the_morning_summary() {
    let p = chicago();
    // 21:00 CST on the 24th: the device registers; the item starts then.
    let mut s = started(&p, utc(2026, 11, 25, 2, 59, 0));
    let w = [mother("j1", Some(utc(2026, 11, 25, 3, 0, 0)))];
    step(&mut s, utc(2026, 11, 25, 3, 0, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 25, 3, 2, 0), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"], "21:02 local is not quiet");
    let fx = step(&mut s, utc(2026, 11, 25, 13, 0, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
}

#[test]
fn quiet_hours_end_is_exclusive_an_item_due_at_exactly_the_end_is_sent() {
    let p = prefs(); // UTC, 22:00-07:00
    let mut s = started(&p, utc(2026, 11, 26, 6, 55, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 6, 58, 0)))];
    step(&mut s, utc(2026, 11, 26, 6, 58, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 7, 0, 0), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"]);
}

#[test]
fn an_item_due_at_exactly_the_start_of_quiet_hours_is_held() {
    let p = prefs();
    let mut s = started(&p, utc(2026, 11, 26, 21, 55, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 21, 58, 0)))];
    step(&mut s, utc(2026, 11, 26, 21, 58, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 22, 0, 0), &w, &p);
    assert!(alerts(&fx).is_empty());
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::HeldQuietHours)]
    );
}

#[test]
fn a_burst_inside_quiet_hours_sends_no_summary_either() {
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 25, 2, 0, 0));
    let w: Vec<Waiting> = (1..=5)
        .map(|n| mother(&format!("j{n}"), Some(utc(2026, 11, 25, 4, 30, 0))))
        .collect();
    step(&mut s, utc(2026, 11, 25, 4, 30, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 25, 4, 32, 0), &w, &p);
    assert!(
        alerts(&fx).is_empty() && summaries(&fx).is_empty(),
        "{fx:?}"
    );
    assert_eq!(logged(&fx).len(), 5);
}

// DST: the spring-forward and fall-back days of America/Chicago.

#[test]
fn quiet_hours_follow_the_clock_across_spring_forward_2026_03_08() {
    // 22:00 CST on the 7th to 07:00 CDT on the 8th. CDT is UTC-5, so 07:00 is
    // 12:00 UTC (a fixed UTC-6 offset would say 13:00; a fixed -5 would be right
    // only after the change).
    let p = chicago();
    let mut s = started(&p, utc(2026, 3, 8, 3, 0, 0)); // 21:00 CST on the 7th
    let w = [mother("j1", Some(utc(2026, 3, 8, 4, 30, 0)))]; // 22:30 CST
    step(&mut s, utc(2026, 3, 8, 4, 30, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 3, 8, 4, 32, 0), &w, &p);
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::HeldQuietHours)]
    );
    // 06:59:59 CDT: still quiet. 07:00:00 CDT: the digest.
    let fx = step(&mut s, utc(2026, 3, 8, 11, 59, 59), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    let fx = step(&mut s, utc(2026, 3, 8, 12, 0, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
}

#[test]
fn an_item_due_at_07_00_cdt_on_the_spring_forward_day_is_sent_then() {
    let p = chicago();
    let mut s = started(&p, utc(2026, 3, 8, 11, 0, 0));
    let w = [mother("j1", Some(utc(2026, 3, 8, 11, 58, 0)))];
    step(&mut s, utc(2026, 3, 8, 11, 58, 0), &w, &p);
    // Due 12:00 UTC = 07:00 CDT: quiet has just ended.
    let fx = step(&mut s, utc(2026, 3, 8, 12, 0, 0), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"]);
}

#[test]
fn quiet_hours_follow_the_clock_across_fall_back_2026_11_01() {
    // 22:00 CDT on 31 Oct to 07:00 CST on 1 Nov. CST is UTC-6, so 07:00 is
    // 13:00 UTC (a fixed UTC-5 offset would fire the digest at 12:00).
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 1, 2, 0, 0)); // 21:00 CDT on the 31st
    let w = [mother("j1", Some(utc(2026, 11, 1, 3, 30, 0)))]; // 22:30 CDT
    step(&mut s, utc(2026, 11, 1, 3, 30, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 1, 3, 32, 0), &w, &p);
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::HeldQuietHours)]
    );
    // 12:00 UTC is 06:00 CST: the night is an hour longer than the clock said.
    let fx = step(&mut s, utc(2026, 11, 1, 12, 0, 0), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    let fx = step(&mut s, utc(2026, 11, 1, 12, 59, 59), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    let fx = step(&mut s, utc(2026, 11, 1, 13, 0, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
}

#[test]
fn an_item_due_in_the_repeated_hour_of_fall_back_is_held() {
    // 07:30 UTC on 1 Nov is 01:30 CST (the second 01:30): deep in quiet hours.
    let p = chicago();
    let mut s = started(&p, utc(2026, 11, 1, 7, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 1, 7, 28, 0)))];
    step(&mut s, utc(2026, 11, 1, 7, 28, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 1, 7, 30, 0), &w, &p);
    assert!(alerts(&fx).is_empty());
    assert_eq!(
        logged(&fx),
        vec![("j1".to_string(), PushOutcome::HeldQuietHours)]
    );
}

// ── W13-14: the daily summaries ──────────────────────────────────────────────

#[test]
fn the_evening_summary_fires_at_17_30_local_when_something_is_waiting() {
    let p = prefs(); // UTC; evening 17:30
    let mut s = started(&p, at(-1));
    let w = [mother("j1", Some(at(0)))];
    assert_eq!(alerts(&step(&mut s, at(120), &w, &p)), vec!["j1"]);
    let fx = step(&mut s, utc(2026, 11, 26, 17, 29, 59), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Evening, vec![])]);
    // Once a day, and again the next day.
    assert!(is_empty(&step(
        &mut s,
        utc(2026, 11, 26, 17, 31, 0),
        &w,
        &p
    )));
    let fx = step(&mut s, utc(2026, 11, 27, 17, 30, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Evening, vec![])]);
}

#[test]
fn no_evening_summary_when_nothing_is_waiting() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &[], &p);
    assert!(fx.is_empty(), "{fx:?}");
}

#[test]
fn the_evening_summary_is_skipped_when_17_30_falls_inside_quiet_hours() {
    let p = PushPrefs {
        quiet: quiet("17:00", "19:00"),
        ..prefs()
    };
    let mut s = started(&p, at(-1));
    let w = [mother("j1", Some(at(0)))];
    step(&mut s, at(120), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

#[test]
fn the_evening_summary_can_be_turned_off_and_can_be_moved() {
    let off = PushPrefs {
        evening_summary: None,
        ..prefs()
    };
    let mut s = started(&off, at(-1));
    let w = [mother("j1", Some(at(0)))];
    step(&mut s, at(120), &w, &off);
    assert!(step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &off).is_empty());

    let moved = PushPrefs {
        evening_summary: Some("18:15".into()),
        ..prefs()
    };
    let mut s = started(&moved, at(-1));
    step(&mut s, at(120), &w, &moved);
    assert!(step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &moved).is_empty());
    let fx = step(&mut s, utc(2026, 11, 26, 18, 15, 0), &w, &moved);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Evening, vec![])]);
}

#[test]
fn the_morning_summary_fires_at_the_configured_end_even_with_quiet_hours_off() {
    let p = PushPrefs {
        quiet: QuietHours {
            start: "22:00".into(),
            end: "07:00".into(),
            enabled: false,
        },
        ..prefs()
    };
    let mut s = started(&p, utc(2026, 11, 26, 5, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 5, 0, 0)))];
    // Quiet hours are off: the item is sent at 05:02, not held.
    let fx = step(&mut s, utc(2026, 11, 26, 5, 2, 0), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"]);
    let fx = step(&mut s, utc(2026, 11, 26, 6, 59, 59), &w, &p);
    assert!(summaries(&fx).is_empty());
    let fx = step(&mut s, utc(2026, 11, 26, 7, 0, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
}

#[test]
fn with_quiet_hours_off_an_item_due_late_at_night_is_still_sent() {
    let p = PushPrefs {
        quiet: QuietHours {
            start: "22:00".into(),
            end: "07:00".into(),
            enabled: false,
        },
        ..prefs()
    };
    let mut s = started(&p, utc(2026, 11, 26, 22, 55, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 23, 0, 0)))];
    step(&mut s, utc(2026, 11, 26, 23, 0, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 23, 2, 0), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"]);
}

#[test]
fn a_late_tick_more_than_ten_minutes_after_the_summary_time_does_not_fire_it() {
    // The daemon slept through 07:00 and woke at 07:10:00.
    let p = prefs();
    let mut s = started(&p, utc(2026, 11, 26, 5, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 5, 0, 0)))];
    step(&mut s, utc(2026, 11, 26, 5, 2, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 6, 59, 0), &w, &p);
    assert!(fx.is_empty());
    let fx = step(&mut s, utc(2026, 11, 26, 7, 10, 0), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
    // And it is not made up for later the same day.
    let fx = step(&mut s, utc(2026, 11, 26, 7, 11, 0), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

#[test]
fn a_tick_just_inside_ten_minutes_after_the_summary_time_still_fires_it() {
    let p = prefs();
    let mut s = started(&p, utc(2026, 11, 26, 5, 0, 0));
    let w = [mother("j1", Some(utc(2026, 11, 26, 5, 0, 0)))];
    step(&mut s, utc(2026, 11, 26, 5, 2, 0), &w, &p);
    step(&mut s, utc(2026, 11, 26, 6, 59, 0), &w, &p);
    let fx = step(&mut s, utc(2026, 11, 26, 7, 9, 59), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Morning, vec![])]);
}

// ── W13-35 / restart: baseline and preexisting items ─────────────────────────

#[test]
fn items_already_waiting_at_a_devices_first_step_are_never_pushed() {
    let p = prefs();
    let mut s = DeviceSchedule::new();
    let w = [
        mother("j1", Some(at(-3600))),
        review(4821, Some(at(-3600))),
        decision("d1", at(-3600), Some(Presence::Away), None),
    ];
    let fx = s.step(at(0), &w, &p, &cfg(), true);
    assert!(fx.is_empty(), "{fx:?}");
    for t in [1, 30, 120, 600, 3600] {
        let fx = step(&mut s, at(t), &w, &p);
        assert!(
            alerts(&fx).is_empty() && summaries(&fx).is_empty(),
            "+{t} s: {fx:?}"
        );
    }
    // They leave quietly, as badge corrections.
    let fx = step(&mut s, at(4000), &[], &p);
    assert_eq!(
        withdrawn(&fx),
        vec![
            ("d1".to_string(), false),
            ("j1".to_string(), false),
            ("pr4821".to_string(), false)
        ]
    );
}

#[test]
fn an_item_the_engine_marks_preexisting_is_never_pushed_but_is_counted() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let mut old = mother("j1", Some(at(-3600)));
    old.preexisting = true;
    let w = [old.clone()];
    for t in [0, 120, 600] {
        let fx = step(&mut s, at(t), &w, &p);
        assert!(
            alerts(&fx).is_empty() && logged(&fx).is_empty(),
            "+{t} s: {fx:?}"
        );
    }
    assert_eq!(enabled_waiting(&w, &p, at(0)).len(), 1);
    // It still makes the evening summary worth sending.
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Evening, vec![])]);
}

#[test]
fn a_baseline_step_after_a_summary_time_does_not_fire_that_summary() {
    // A restart at 18:00: the 17:30 summary of that day is not sent.
    let p = prefs();
    let mut s = DeviceSchedule::new();
    let w = [mother("j1", Some(utc(2026, 11, 26, 9, 0, 0)))];
    let fx = s.step(utc(2026, 11, 26, 18, 0, 0), &w, &p, &cfg(), true);
    assert!(fx.is_empty(), "{fx:?}");
    let fx = step(&mut s, utc(2026, 11, 26, 18, 1, 0), &w, &p);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

// ── W13-15: one notification per item lifetime ───────────────────────────────

#[test]
fn an_item_is_never_sent_twice_however_long_it_waits() {
    let p = PushPrefs {
        quiet: QuietHours {
            enabled: false,
            ..QuietHours::default()
        },
        evening_summary: None,
        ..prefs()
    };
    let mut s = started(&p, at(-1));
    let w = [
        mother("j1", Some(at(0))),
        review(4821, Some(at(0))),
        decision("d1", at(0), None, None),
    ];
    let mut sent = 0;
    for t in (0..=(26 * 3600)).step_by(30) {
        let fx = step(&mut s, at(t), &w, &p);
        sent += alerts(&fx).len();
        // The only summary a day-long wait can produce is the morning digest.
        for (reason, _) in summaries(&fx) {
            assert_eq!(reason, SummaryReason::Morning);
        }
    }
    assert_eq!(
        sent, 3,
        "each item exactly once: no 24 h or daily reminders"
    );
}

#[test]
fn a_mother_job_that_leaves_and_re_enters_awaiting_is_a_new_item() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let first = [mother("j1", Some(at(0)))];
    assert_eq!(alerts(&step(&mut s, at(120), &first, &p)), vec!["j1"]);
    // Answered: gone from the waiting set.
    let fx = step(&mut s, at(200), &[], &p);
    assert_eq!(withdrawn(&fx), vec![("j1".to_string(), true)]);
    // It pauses again at +300 s: a new item, with its own grace delay.
    let again = [mother("j1", Some(at(300)))];
    assert!(is_empty(&step(&mut s, at(300), &again, &p)));
    assert!(is_empty(&step(&mut s, at(419), &again, &p)));
    assert_eq!(alerts(&step(&mut s, at(420), &again, &p)), vec!["j1"]);
}

// ── withdrawal ───────────────────────────────────────────────────────────────

#[test]
fn a_notified_item_that_leaves_is_withdrawn_with_a_notification_to_replace() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [
        mother("j1", Some(at(0))),
        review(4821, Some(at(0))),
        decision("d1", at(0), Some(Presence::Away), None),
    ];
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx).len(), 3);
    let fx = step(&mut s, at(130), &[], &p);
    assert_eq!(
        withdrawn(&fx),
        vec![
            ("d1".to_string(), true),
            ("j1".to_string(), true),
            ("pr4821".to_string(), true)
        ]
    );
    // And only once.
    assert!(is_empty(&step(&mut s, at(131), &[], &p)));
}

#[test]
fn an_item_that_never_had_a_notification_leaves_as_a_badge_only_withdrawal() {
    // Coalesced, held for quiet hours, and pre-existing items.
    let p = prefs();
    let mut s = started(&p, at(-1));
    let burst: Vec<Waiting> = (1..=4)
        .map(|n| mother(&format!("c{n}"), Some(at(0))))
        .collect();
    let mut old = mother("old", Some(at(-3600)));
    old.preexisting = true;
    let mut w = burst.clone();
    w.push(old);
    step(&mut s, at(120), &w, &p);
    let fx = step(&mut s, at(200), &[], &p);
    let got = withdrawn(&fx);
    assert_eq!(got.len(), 5);
    assert!(got.iter().all(|(_, had)| !had), "{got:?}");
}

#[test]
fn an_attention_item_that_is_acked_or_lapses_leaves_as_a_badge_only_withdrawal() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let a = attention("j1", "gates_incomplete", "2026-11-26T09:00:00Z");
    step(&mut s, at(0), std::slice::from_ref(&a), &p);
    let fx = step(&mut s, at(600), &[], &p);
    assert_eq!(
        withdrawn(&fx),
        vec![("j1:gates_incomplete".to_string(), false)]
    );
}

#[test]
fn a_reason_that_lapses_and_returns_with_a_new_since_is_a_new_item() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let first = attention("j1", "progress_stalled", "2026-11-26T09:00:00Z");
    step(&mut s, at(0), std::slice::from_ref(&first), &p);
    // Acked: gone.
    let fx = step(&mut s, at(60), &[], &p);
    assert_eq!(withdrawn(&fx).len(), 1);
    // Re-raised with a new `since`: counted again, never pushed.
    let second = attention("j1", "progress_stalled", "2026-11-26T10:05:00Z");
    assert_ne!(first.key, second.key);
    let fx = step(&mut s, at(300), std::slice::from_ref(&second), &p);
    assert!(fx.is_empty(), "{fx:?}");
    let fx = step(&mut s, at(900), std::slice::from_ref(&second), &p);
    assert!(alerts(&fx).is_empty(), "{fx:?}");
    let fx = step(&mut s, at(960), &[], &p);
    assert_eq!(
        withdrawn(&fx).len(),
        1,
        "the new item is withdrawn on its own"
    );
}

// ── W13-34: attention items are count-only ───────────────────────────────────

#[test]
fn attention_items_never_alert_but_are_counted_and_make_the_next_summary() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let w = [
        attention("j1", "progress_stalled", "2026-11-26T09:00:00Z"),
        attention("j1", "burn_ahead", "2026-11-26T09:00:00Z"),
        attention("j2", "gates_incomplete", "2026-11-26T09:30:00Z"),
    ];
    // Many steps over many hours: never an alert, never a burst, however many.
    for t in [0, 120, 240, 3600, 6 * 3600] {
        let fx = step(&mut s, at(t), &w, &p);
        assert!(
            alerts(&fx).is_empty() && summaries(&fx).is_empty(),
            "+{t} s: {fx:?}"
        );
    }
    // They count toward the badge ...
    assert_eq!(enabled_waiting(&w, &p, at(0)).len(), 3);
    // ... and the next Summary (the 17:30 one, with nothing else waiting).
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &p);
    assert_eq!(summaries(&fx), vec![(SummaryReason::Evening, vec![])]);
}

#[test]
fn attention_items_do_not_count_toward_a_burst_of_grace_items() {
    let p = prefs();
    let mut s = started(&p, at(-1));
    let mut w: Vec<Waiting> = (1..=3)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    w.push(attention("j9", "burn_ahead", "2026-11-26T09:00:00Z"));
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

// ── W13-16: per-kind switches ────────────────────────────────────────────────

fn kinds(mother: bool, decision: bool, review: bool) -> PushKinds {
    PushKinds {
        mother,
        decision,
        review,
    }
}

#[test]
fn a_disabled_kind_is_never_sent_and_the_others_still_are() {
    let p = PushPrefs {
        kinds: kinds(true, true, false),
        ..prefs()
    };
    let mut s = started(&p, at(-1));
    let w = [
        mother("j1", Some(at(0))),
        review(4821, Some(at(0))),
        decision("d1", at(0), Some(Presence::Away), None),
    ];
    let fx = step(&mut s, at(0), &w, &p);
    assert_eq!(alerts(&fx), vec!["d1"]);
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1"], "the review is off");
    for t in [300, 3600] {
        assert!(alerts(&step(&mut s, at(t), &w, &p)).is_empty());
    }
}

#[test]
fn a_disabled_kind_does_not_count_toward_a_burst() {
    // Four reviews are off; three Mother jobs are on: three alerts, not a summary.
    let p = PushPrefs {
        kinds: kinds(true, true, false),
        ..prefs()
    };
    let mut s = started(&p, at(-1));
    let mut w: Vec<Waiting> = (1..=3)
        .map(|n| mother(&format!("j{n}"), Some(at(0))))
        .collect();
    w.extend((1..=4).map(|n| review(n, Some(at(0)))));
    let fx = step(&mut s, at(120), &w, &p);
    assert_eq!(alerts(&fx), vec!["j1", "j2", "j3"]);
    assert!(summaries(&fx).is_empty(), "{fx:?}");
}

#[test]
fn a_disabled_kind_is_absent_from_the_badge_and_from_summaries() {
    let p = PushPrefs {
        kinds: kinds(false, true, true),
        ..prefs()
    };
    let w = [
        mother("j1", Some(at(0))),
        review(4821, Some(at(0))),
        decision("d1", at(0), None, None),
    ];
    let counted = enabled_waiting(&w, &p, at(0));
    assert_eq!(counted.len(), 2);
    assert!(counted.iter().all(|x| label(x) != "j1"));

    // Only a disabled kind is waiting: the evening summary has nothing to say.
    let only_mother = PushPrefs {
        kinds: kinds(false, true, true),
        ..prefs()
    };
    let mut s = started(&only_mother, at(-1));
    let w = [mother("j1", Some(at(0)))];
    step(&mut s, at(120), &w, &only_mother);
    let fx = step(&mut s, utc(2026, 11, 26, 17, 30, 0), &w, &only_mother);
    assert!(fx.is_empty(), "{fx:?}");
}

#[test]
fn an_item_of_a_disabled_kind_that_leaves_sends_nothing_to_that_device() {
    let p = PushPrefs {
        kinds: kinds(true, true, false),
        ..prefs()
    };
    let mut s = started(&p, at(-1));
    let w = [review(4821, Some(at(0)))];
    step(&mut s, at(120), &w, &p);
    let fx = step(&mut s, at(200), &[], &p);
    assert!(fx.is_empty(), "{fx:?}");
}

#[test]
fn the_badge_counts_every_enabled_waiting_item_across_kinds_but_not_an_expired_decision() {
    let p = prefs();
    let w = [
        mother("j1", Some(at(0))),
        review(1, Some(at(0))),
        decision("d1", at(0), None, Some(at(100))),
        decision("d2", at(0), None, None),
        attention("j2", "burn_ahead", "2026-11-26T09:00:00Z"),
    ];
    assert_eq!(enabled_waiting(&w, &p, at(50)).len(), 5);
    assert_eq!(
        enabled_waiting(&w, &p, at(100)).len(),
        4,
        "d1's deadline has passed"
    );
}

// ── two devices do not share state ───────────────────────────────────────────

#[test]
fn each_devices_schedule_is_its_own() {
    let on = prefs();
    let off = PushPrefs {
        kinds: kinds(false, true, true),
        ..prefs()
    };
    let mut a = started(&on, at(-1));
    let mut b = started(&off, at(-1));
    let w = [mother("j1", Some(at(0)))];
    assert_eq!(alerts(&step(&mut a, at(120), &w, &on)), vec!["j1"]);
    assert!(step(&mut b, at(120), &w, &off).is_empty());
}
