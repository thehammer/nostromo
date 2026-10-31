//! The hourly cap (SR5), the loop guard (R10) and notice turns per local day
//! (SR9): MF2a-7 and the `wakes_by_day` half of MF2a-12.

use super::*;

use chrono::{Local, TimeZone};

use crate::mother::notices::limits::DayCount;

// ── the cap: six notice turns per focus per rolling hour ─────────────────────

/// Six notices for F, each run as a notice turn that queues nothing, inside
/// ten minutes. Returns when the first notice turn started.
fn six_notice_turns(r: &Rig) -> i64 {
    let mut first = None;
    for k in 0..6 {
        r.jobs(&[job(F, &format!("c{k}"), "succeeded")]);
        r.after(30 * SEC);
        assert_eq!(r.deliveries_to(F).len(), k + 1, "notice {k} is delivered");
        if first.is_none() {
            first = Some(r.now());
        }
        r.notice_turn(F);
        r.advance(MIN);
    }
    first.unwrap()
}

#[test]
fn the_seventh_notice_turn_inside_an_hour_is_held_for_the_cap_and_goes_when_the_hour_rolls() {
    let r = Rig::new();
    let first = six_notice_turns(&r);
    r.jobs(&[job(F, "seventh", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 6, "the seventh waits");
    assert_eq!(
        r.status("seventh"),
        (NoticeStatus::Held, Some(NoticeReason::Cap))
    );
    let held = r.focus(F).and_then(|f| f.held).expect("F shows a hold");
    assert_eq!(held.reason, NoticeReason::Cap);

    r.clock.set(first + HOUR - 1);
    r.tick();
    assert_eq!(r.deliveries().len(), 6, "not before the hour rolls");
    r.clock.set(first + HOUR);
    r.tick();
    let ds = r.deliveries();
    assert_eq!(ds.len(), 7, "delivered when the hour rolls");
    assert_eq!(ids(&ds[6].fresh), sorted(&["seventh"]));
    assert_eq!(r.status("seventh").0, NoticeStatus::Told);
}

#[test]
fn a_cap_hold_goes_behind_the_users_next_message() {
    let r = Rig::new();
    six_notice_turns(&r);
    r.jobs(&[job(F, "seventh", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 6);

    r.reply(F, Reply::Queued);
    r.cli_turn_starts(F);
    assert_eq!(
        r.deliveries().len(),
        6,
        "only the user's turn lifts the cap early"
    );
    r.turn_ends(F);
    r.user_turn_starts(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 7);
    assert_eq!(ids(&ds[6].fresh), sorted(&["seventh"]));
}

#[test]
fn changes_held_by_the_cap_are_combined_into_one_delivery() {
    let r = Rig::new();
    six_notice_turns(&r);
    r.jobs(&[job(F, "x", "succeeded")]);
    r.after(30 * SEC);
    r.after(MIN);
    r.jobs(&[job(F, "y", "failed")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 6);
    r.after(HOUR);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 7, "one delivery for everything held");
    assert_eq!(ids(&ds[6].fresh), sorted(&["x", "y"]));
    assert_one_advisory_last(&ds[6].fresh);
}

#[test]
fn a_delivery_made_after_a_turn_counts_toward_the_cap() {
    // Q3: a held delivery written behind another turn is a notice turn too.
    let r = Rig::new();
    for k in 0..5 {
        r.jobs(&[job(F, &format!("c{k}"), "succeeded")]);
        r.after(30 * SEC);
        r.notice_turn(F);
        r.advance(MIN);
    }
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "held", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(
        r.status("held"),
        (NoticeStatus::Held, Some(NoticeReason::SessionNotRunning))
    );
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    r.turn_ends(F);
    r.notice_turn(F);
    assert_eq!(r.wakes(F), 6);

    r.reply(F, Reply::Woke);
    let before = r.deliveries().len();
    r.jobs(&[job(F, "next", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(
        r.deliveries().len(),
        before,
        "the sixth notice turn reached the cap"
    );
    assert_eq!(
        r.status("next"),
        (NoticeStatus::Held, Some(NoticeReason::Cap))
    );
}

#[test]
fn turns_the_user_or_the_cli_started_never_count_toward_the_cap() {
    let r = Rig::new();
    for _ in 0..10 {
        r.user_turn_starts(F);
        r.turn_ends(F);
        r.cli_turn_starts(F);
        r.turn_ends(F);
    }
    for k in 0..6 {
        r.jobs(&[job(F, &format!("c{k}"), "succeeded")]);
        r.after(30 * SEC);
        assert_eq!(r.deliveries().len(), k + 1);
        r.notice_turn(F);
    }
}

// ── the loop guard ───────────────────────────────────────────────────────────

/// A notice turn (for the newest notice to F) in which the agent queues the
/// job `born` of its own focus, seen in the feed during the turn.
fn notice_turn_queueing(r: &Rig, born: &str) {
    r.notice_turn_starts(F);
    r.jobs(&[job(F, born, "queued")]);
    r.turn_ends(F);
}

/// `id` (queued earlier) finishes; its notice is due when the window closes.
fn finishes(r: &Rig, id: &str) {
    r.advance(MIN);
    r.jobs(&[job(F, id, "succeeded")]);
    r.after(30 * SEC);
}

#[test]
fn an_agent_that_queues_a_job_on_every_notice_gets_exactly_three_notice_turns() {
    let r = Rig::new();
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    notice_turn_queueing(&r, "n1");
    finishes(&r, "n1");
    notice_turn_queueing(&r, "n2");
    finishes(&r, "n2");
    notice_turn_queueing(&r, "n3");
    assert_eq!(r.deliveries().len(), 3);
    assert!(
        r.focus(F).expect("F has a chain").chain_held,
        "three notice turns in a row each queued a job"
    );
    match r.engine.state_msg() {
        crate::ipc::protocol::ServerMsg::MotherNoticeState { focuses, .. } => {
            assert!(focuses.iter().any(|f| f.tag == F && f.chain_held));
        }
        other => panic!("not a notice state frame: {other:?}"),
    }

    r.advance(MIN);
    r.jobs(&[job(F, "n3", "succeeded"), job(F, "x", "failed")]);
    r.after(30 * SEC);
    r.after(2 * HOUR);
    assert_eq!(r.deliveries().len(), 3, "the fourth waits for the user");
    for id in ["n3", "x"] {
        assert_eq!(
            r.status(id),
            (NoticeStatus::Held, Some(NoticeReason::LoopGuard)),
            "{id}"
        );
    }
    r.cli_turn_starts(F);
    r.turn_ends(F);
    assert_eq!(
        r.deliveries().len(),
        3,
        "only the user releases the loop guard"
    );

    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 4, "the user's turn releases exactly one delivery");
    assert_eq!(ids(&ds[3].fresh), sorted(&["n3", "x"]));
    assert_one_advisory_last(&ds[3].fresh);
    assert!(
        !r.focus(F).expect("F").chain_held,
        "the user's turn ends the chain"
    );
}

#[test]
fn a_job_stamped_during_a_notice_turn_is_notice_born() {
    let r = Rig::new();
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    for (born, prev) in [("m1", None), ("m2", Some("m1")), ("m3", Some("m2"))] {
        if let Some(prev) = prev {
            finishes(&r, prev);
        }
        r.notice_turn_starts(F);
        r.engine.note_job_origin(born, F);
        r.turn_ends(F);
        // The feed shows it only after the turn.
        r.jobs(&[job(F, born, "queued")]);
    }
    assert_eq!(r.deliveries().len(), 3);
    assert!(r.focus(F).expect("F").chain_held);
    finishes(&r, "m3");
    assert_eq!(r.deliveries().len(), 3);
    assert_eq!(
        r.status("m3"),
        (NoticeStatus::Held, Some(NoticeReason::LoopGuard))
    );
}

#[test]
fn a_notice_turn_that_queues_nothing_ends_the_chain() {
    let r = Rig::new();
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    notice_turn_queueing(&r, "n1");
    finishes(&r, "n1");
    notice_turn_queueing(&r, "n2");
    finishes(&r, "n2");
    r.notice_turn(F);
    finishes(&r, "other");
    assert_eq!(r.deliveries().len(), 4, "the chain was broken");
    assert!(!r.focus(F).expect("F").chain_held);
}

#[test]
fn a_user_turn_in_the_middle_ends_the_chain() {
    let r = Rig::new();
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    notice_turn_queueing(&r, "n1");
    finishes(&r, "n1");
    notice_turn_queueing(&r, "n2");
    r.user_turn_starts(F);
    r.turn_ends(F);
    finishes(&r, "n2");
    notice_turn_queueing(&r, "n3");
    finishes(&r, "n3");
    notice_turn_queueing(&r, "n4");
    finishes(&r, "n4");
    assert_eq!(r.deliveries().len(), 5, "two chains of two, never three");
    assert!(!r.focus(F).expect("F").chain_held);
}

#[test]
fn a_job_queued_by_another_focus_does_not_grow_the_chain() {
    let r = Rig::new();
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    for k in 0..4 {
        r.notice_turn_starts(F);
        r.jobs(&[job(G, &format!("g{k}"), "queued")]);
        r.turn_ends(F);
        finishes(&r, &format!("f{k}"));
    }
    assert_eq!(r.deliveries_to(F).len(), 5);
    assert!(!r.focus(F).expect("F").chain_held);
}

/// `job`, finished (same job, same creation time).
fn finished(job: &MotherJob) -> MotherJob {
    MotherJob {
        state: "succeeded".to_owned(),
        ..job.clone()
    }
}

/// Three notice turns in a row. After each turn's `Completed` the feed shows,
/// for the first time, a new job of F whose `created_at` is
/// `created_at(turn_started_ms, turn_ended_ms)`; that job then finishes so the
/// next notice is due. Returns the last such job.
fn three_notice_turns_with_jobs_seen_after_the_turn(
    r: &Rig,
    created_at: impl Fn(i64, i64) -> i64,
) -> MotherJob {
    r.jobs(&[job(F, "seed", "succeeded")]);
    r.after(30 * SEC);
    let mut previous: Option<MotherJob> = None;
    for k in 1..=3 {
        if let Some(p) = &previous {
            r.advance(MIN);
            r.jobs(&[finished(p)]);
            r.after(30 * SEC);
            assert_eq!(r.deliveries().len(), k, "notice {k} is delivered");
        }
        r.notice_turn_starts(F);
        let started = r.now();
        r.advance(15 * SEC);
        let ended = r.now();
        r.turn_ends(F);
        // The feed catches up later.
        r.advance(5 * SEC);
        let born = job(F, &format!("born{k}"), "queued").created(created_at(started, ended));
        r.jobs(std::slice::from_ref(&born));
        previous = Some(born);
    }
    previous.unwrap()
}

#[test]
fn a_job_created_during_a_notice_turn_counts_for_the_loop_guard_even_if_the_feed_shows_it_after_the_turn(
) {
    let r = Rig::new();
    let last = three_notice_turns_with_jobs_seen_after_the_turn(&r, |started, _| started + 5 * SEC);
    assert_eq!(r.deliveries().len(), 3);
    assert!(
        r.focus(F).expect("F has a chain").chain_held,
        "three notice turns in a row each queued a job (seen late)"
    );

    r.advance(MIN);
    r.jobs(&[finished(&last)]);
    r.after(30 * SEC);
    r.after(2 * HOUR);
    assert_eq!(r.deliveries().len(), 3, "the fourth waits for the user");
    assert_eq!(
        r.status("born3"),
        (NoticeStatus::Held, Some(NoticeReason::LoopGuard))
    );
    r.cli_turn_starts(F);
    r.turn_ends(F);
    assert_eq!(r.deliveries().len(), 3, "only the user releases the guard");

    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 4, "the user's turn releases it");
    assert_eq!(ids(&ds[3].fresh), sorted(&["born3"]));
    assert!(!r.focus(F).expect("F").chain_held);
}

#[test]
fn a_job_created_outside_the_notice_turn_never_counts_for_the_loop_guard_however_late_it_is_seen() {
    // Created long before the turn, or after it had ended: not the turn's job.
    type CreatedAt = fn(i64, i64) -> i64;
    let cases: [(&str, CreatedAt); 2] = [
        ("long before the turn", |_, _| T0 - HOUR),
        ("after the turn ended", |_, ended| ended + 3 * SEC),
    ];
    for (name, created_at) in cases {
        let r = Rig::new();
        let last = three_notice_turns_with_jobs_seen_after_the_turn(&r, created_at);
        assert!(
            !r.focus(F).expect("F").chain_held,
            "{name}: the chain grew without a notice-born job"
        );
        r.advance(MIN);
        r.jobs(&[finished(&last)]);
        r.after(30 * SEC);
        assert_eq!(r.deliveries().len(), 4, "{name}: the fourth is delivered");
    }
}

// ── wakes per local day ──────────────────────────────────────────────────────

fn local_noon(y: i32, m: u32, d: u32) -> i64 {
    Local
        .with_ymd_and_hms(y, m, d, 12, 0, 0)
        .single()
        .expect("an unambiguous local noon")
        .timestamp_millis()
}

fn local_day(ms: i64) -> String {
    Local
        .timestamp_millis_opt(ms)
        .single()
        .expect("a local time")
        .format("%Y-%m-%d")
        .to_string()
}

/// `n` notices for `tag`, each run as a notice turn, with a user turn and a
/// CLI turn after each (which never count).
fn notice_turns(r: &Rig, tag: &str, n: usize, prefix: &str) {
    for k in 0..n {
        r.jobs(&[job(tag, &format!("{prefix}{k}"), "succeeded")]);
        r.after(30 * SEC);
        r.notice_turn(tag);
        r.user_turn_starts(tag);
        r.turn_ends(tag);
        r.cli_turn_starts(tag);
        r.turn_ends(tag);
        r.advance(MIN);
    }
}

#[test]
fn wakes_by_day_counts_notice_turns_per_local_day() {
    let day1 = local_noon(2026, 10, 20);
    let day2 = local_noon(2026, 10, 21);
    let r = Rig::new();
    r.clock.set(day1);
    notice_turns(&r, F, 3, "a");
    r.clock.set(day2);
    notice_turns(&r, F, 2, "b");
    assert_eq!(
        r.focus(F).expect("F has notice turns").wakes_by_day,
        vec![
            DayCount {
                day: local_day(day1),
                count: 3
            },
            DayCount {
                day: local_day(day2),
                count: 2
            },
        ]
    );
}

#[test]
fn wakes_by_day_reports_the_last_seven_local_days_oldest_first() {
    let r = Rig::new();
    let start = local_noon(2026, 10, 1);
    for d in 0..9 {
        r.clock.set(start + d * DAY);
        notice_turns(&r, F, 1, &format!("d{d}-"));
    }
    let days = r.focus(F).expect("F").wakes_by_day;
    assert_eq!(days.len(), 7, "{days:?}");
    assert_eq!(days.last().unwrap().day, local_day(r.now()));
    assert_eq!(days.first().unwrap().day, local_day(start + 2 * DAY));
    assert!(days.windows(2).all(|w| w[0].day < w[1].day));
}

#[test]
fn wakes_are_counted_per_focus() {
    let r = Rig::new();
    notice_turns(&r, F, 2, "f");
    notice_turns(&r, G, 1, "g");
    assert_eq!(r.wakes(F), 2);
    assert_eq!(r.wakes(G), 1);
}
