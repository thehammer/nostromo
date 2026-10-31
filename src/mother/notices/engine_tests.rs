//! The engine's behaviour over time: windows (MF2a-1), quiet changes and PR
//! events (MF2a-2), merging while the agent is busy (MF2a-3, engine side),
//! switches (MF2a-5), closed focuses, holds, expiry and restarts (MF2a-6), and
//! the notice record each job carries (§W).

use super::*;

use crate::ipc::protocol::ServerMsg;
use crate::mother::notices::detect::JobEvent;
use crate::mother::notices::{NoticeScope, SettingsError};
use crate::mother::JobsFeed;

// ── MF2a-1: one delivery at last + 30 s, never past first + 2 min ───────────

#[test]
fn each_waking_state_reaches_an_idle_focus_exactly_once_30_seconds_after_the_change() {
    for state in ["succeeded", "failed", "cancelled", "awaiting"] {
        let r = Rig::new();
        r.jobs(&[job(F, "j1", "running")]);
        r.advance(SEC);
        r.jobs(&[job(F, "j1", state).asking("Which region?")]);

        r.after(30 * SEC - 1);
        assert!(
            r.deliveries().is_empty(),
            "{state}: nothing before the window closes"
        );

        r.after(1);
        let ds = r.deliveries();
        assert_eq!(ds.len(), 1, "{state}: one delivery when the window closes");
        assert_eq!(ds[0].tag, F, "{state}: to the focus that queued it");
        let el = element_for(&ds[0].fresh, "j1").to_owned();
        assert_eq!(attr(&el, "state").as_deref(), Some(state), "{el}");
        assert_one_advisory_last(&ds[0].fresh);

        r.after(HOUR);
        r.after(HOUR);
        assert_eq!(r.deliveries().len(), 1, "{state}: never again");
        assert_eq!(r.status("j1"), (NoticeStatus::Told, None), "{state}");
    }
}

#[test]
fn a_change_while_the_window_is_open_joins_it_and_moves_its_end() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(20 * SEC);
    r.jobs(&[job(F, "a", "succeeded"), job(F, "b", "running")]);
    r.after(30 * SEC - 1);
    assert!(
        r.deliveries().is_empty(),
        "a quiet change while the window is open still moves its end"
    );
    r.after(1);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1);
    assert_eq!(ids(&ds[0].fresh), sorted(&["a", "b"]));
}

#[test]
fn a_window_with_a_change_every_20_seconds_closes_two_minutes_after_its_first_change() {
    let r = Rig::new();
    for (i, at) in [0, 20, 40, 60, 80, 100, 110].iter().enumerate() {
        r.clock.set(T0 + at * SEC);
        r.jobs(&[job(F, &format!("j{i}"), "succeeded")]);
        r.tick();
        assert!(r.deliveries().is_empty(), "still batching at +{at}s");
    }
    r.clock.set(T0 + 2 * MIN - 1);
    r.tick();
    assert!(r.deliveries().is_empty(), "not before first + 2 min");
    r.clock.set(T0 + 2 * MIN);
    r.tick();
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "one delivery at first + 2 min");
    assert_eq!(elements(&ds[0].fresh).len(), 7);
    assert_one_advisory_last(&ds[0].fresh);
}

#[test]
fn while_a_window_is_open_the_jobs_notice_is_held_for_batching() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Held, Some(NoticeReason::Batching))
    );
}

#[test]
fn each_focus_has_its_own_window_and_gets_only_its_own_jobs() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.advance(10 * SEC);
    r.jobs(&[job(F, "a", "succeeded"), job(G, "b", "failed")]);
    r.after(20 * SEC);
    assert_eq!(r.deliveries_to(F).len(), 1);
    assert!(r.deliveries_to(G).is_empty(), "G's window opened later");
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["a"]));
    r.after(10 * SEC);
    assert_eq!(ids(&r.last_delivery(G).fresh), sorted(&["b"]));
}

// ── MF2a-2: quiet changes ride along, PR events ──────────────────────────────

#[test]
fn queued_ready_and_running_alone_never_deliver_and_appear_as_since_of_the_next_delivery() {
    let r = Rig::new();
    r.jobs(&[job(F, "q", "queued")]);
    r.after(MIN);
    r.jobs(&[job(F, "q", "ready")]);
    r.after(MIN);
    r.jobs(&[job(F, "q", "running")]);
    for _ in 0..6 {
        r.after(30 * MIN);
    }
    assert!(
        r.deliveries().is_empty(),
        "quiet changes never start a turn"
    );

    r.jobs(&[job(F, "q", "succeeded")]);
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1);
    let el = element_for(&ds[0].fresh, "q");
    assert_eq!(attr(el, "state").as_deref(), Some("succeeded"));
    assert_eq!(
        attr(el, "since").as_deref(),
        Some("queued,ready,running"),
        "earlier states, oldest first"
    );
}

#[test]
fn a_retry_alone_never_delivers_and_rides_along_in_the_next_delivery() {
    let r = Rig::new();
    r.jobs(&[job(F, "r", "running")]);
    r.advance(SEC);
    r.jobs(&[job(F, "r", "failed")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 1, "the failure is told");

    r.after(MIN);
    r.jobs(&[job(F, "r", "queued")]);
    for _ in 0..4 {
        r.after(30 * MIN);
    }
    assert_eq!(r.deliveries().len(), 1, "retry_started never starts a turn");

    r.jobs(&[job(F, "r", "running")]);
    r.after(MIN);
    r.jobs(&[job(F, "r", "succeeded")]);
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2);
    let el = element_for(&ds[1].fresh, "r");
    assert_eq!(attr(el, "state").as_deref(), Some("succeeded"));
    assert_eq!(attr(el, "since").as_deref(), Some("retry_started,running"));
}

#[test]
fn a_quiet_change_of_another_job_rides_along_in_the_next_delivery() {
    let r = Rig::new();
    r.jobs(&[job(F, "quiet", "running")]);
    r.after(10 * MIN);
    assert!(r.deliveries().is_empty());
    r.jobs(&[job(F, "quiet", "running"), job(F, "loud", "succeeded")]);
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1);
    assert_eq!(ids(&ds[0].fresh), sorted(&["loud", "quiet"]));
    assert_eq!(
        attr(element_for(&ds[0].fresh, "quiet"), "state").as_deref(),
        Some("running")
    );
    assert_one_advisory_last(&ds[0].fresh);
}

#[test]
fn a_pr_opened_then_success_within_30_seconds_is_one_wake_naming_both() {
    let pr = "https://github.com/acme/repo/pull/7";
    let r = Rig::new();
    r.jobs(&[job(F, "a", "running")]);
    r.after(MIN);
    r.jobs(&[job(F, "a", "running").with_pr(pr)]);
    r.after(10 * SEC);
    r.jobs(&[job(F, "a", "succeeded").with_pr(pr)]);

    r.after(30 * SEC - 1);
    assert!(
        r.deliveries().is_empty(),
        "the success moved the window's end"
    );
    r.after(1);
    r.after(HOUR);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "one wake for both changes");
    let el = element_for(&ds[0].fresh, "a");
    assert_eq!(attr(el, "state").as_deref(), Some("succeeded"));
    assert_eq!(attr(el, "since").as_deref(), Some("running,pr_opened"));
    assert_eq!(attr(el, "pr").as_deref(), Some(pr));
}

#[test]
fn a_pr_opened_with_nothing_final_gives_one_wake_for_pr_opened() {
    let pr = "https://github.com/acme/repo/pull/8";
    let r = Rig::new();
    r.jobs(&[job(F, "a", "running")]);
    r.after(MIN);
    r.jobs(&[job(F, "a", "running").with_pr(pr)]);
    r.after(30 * SEC);
    r.after(HOUR);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1);
    let el = element_for(&ds[0].fresh, "a");
    assert_eq!(attr(el, "state").as_deref(), Some("pr_opened"));
    assert_eq!(attr(el, "pr").as_deref(), Some(pr));
}

#[test]
fn a_merged_pr_wakes_once_however_often_it_is_reported() {
    let pr = "https://github.com/acme/repo/pull/9";
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded").with_pr(pr)]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 1);

    r.after(5 * MIN);
    r.engine.pr_event("a", true);
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "pr_merged wakes");
    let el = element_for(&ds[1].fresh, "a");
    assert_eq!(attr(el, "state").as_deref(), Some("pr_merged"));
    assert_eq!(attr(el, "pr").as_deref(), Some(pr));

    r.engine.pr_event("a", true);
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2, "a repeated merge says nothing");
}

#[test]
fn a_closed_pr_is_quiet_and_rides_along_in_the_next_delivery() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded").with_pr("https://github.com/acme/repo/pull/10")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 1);

    r.engine.pr_event("a", false);
    r.after(HOUR);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1, "pr_closed alone never wakes");

    r.jobs(&[job(F, "b", "succeeded")]);
    r.after(30 * SEC);
    let msg = r.last_delivery(F).fresh;
    assert_eq!(
        attr(element_for(&msg, "a"), "state").as_deref(),
        Some("pr_closed")
    );
}

#[test]
fn a_job_first_seen_in_a_waking_state_after_bootstrap_counts_as_a_change() {
    let r = Rig::new();
    r.jobs(&[job(F, "fresh", "failed")
        .failing_with("timeout")
        .costing(1.5)]);
    r.after(30 * SEC);
    let msg = r.last_delivery(F).fresh;
    let el = element_for(&msg, "fresh");
    assert_eq!(attr(el, "state").as_deref(), Some("failed"));
    assert_eq!(attr(el, "reason").as_deref(), Some("failure: timeout"));
    assert_eq!(attr(el, "cost_usd").as_deref(), Some("1.50"));
    assert_eq!(attr(el, "since"), None, "nothing earlier to report");
}

// ── MF2a-3 (engine side): one message while the agent is busy ───────────────

#[test]
fn notices_arriving_while_a_turn_runs_are_merged_into_one_message_with_one_advisory_line() {
    let r = Rig::new();
    r.reply(F, Reply::Queued);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let first = r.last_delivery(F);
    assert_eq!(ids(&first.fresh), sorted(&["a"]));
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Held, Some(NoticeReason::Busy)),
        "queued behind the turn: not told yet"
    );

    r.reply(F, Reply::Replaced);
    r.advance(10 * SEC);
    r.jobs(&[job(F, "a", "succeeded"), job(F, "b", "failed")]);
    r.after(30 * SEC);
    let ds = r.deliveries_to(F);
    assert_eq!(ds.len(), 2);
    let second = &ds[1];
    assert_eq!(
        ids(&second.merged),
        sorted(&["a", "b"]),
        "the merged text carries what is still waiting"
    );
    assert_one_advisory_last(&second.merged);
    assert_eq!(
        ids(&second.fresh),
        sorted(&["b"]),
        "fresh is only the new news"
    );
    assert_one_advisory_last(&second.fresh);
    assert_ne!(first.key, second.key, "a new generation");

    r.notice_turn_starts(F);
    for id in ["a", "b"] {
        let n = r.notice(id);
        assert_eq!(n.status, NoticeStatus::Told, "{id}");
        assert!(
            !n.history.last().expect("a history entry").wake,
            "{id}: written behind a turn, not a wake"
        );
    }
    let delivered = r.audit_events("job_notice_delivered");
    let last = delivered.last().expect("a delivery audit");
    assert_eq!(last["combined"], 2);
    assert_eq!(last["wake"], false);
}

#[test]
fn a_job_that_moves_again_while_its_notice_waits_is_one_element_in_the_merged_message() {
    // §W: one element per job. The job asked a question (queued behind the
    // turn), then resumed and finished before that turn ended: the merged
    // message reports it once, newest state last.
    let r = Rig::new();
    r.reply(F, Reply::Queued);
    r.jobs(&[job(F, "a", "awaiting").asking("Which one?")]);
    r.after(30 * SEC);
    r.reply(F, Reply::Replaced);
    r.advance(5 * SEC);
    r.jobs(&[job(F, "a", "running")]);
    r.advance(5 * SEC);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let merged = r.last_delivery(F).merged;
    let for_a: Vec<&str> = elements(&merged)
        .into_iter()
        .filter(|e| attr(e, "id").as_deref() == Some("a"))
        .collect();
    assert_eq!(for_a.len(), 1, "one element for the job:\n{merged}");
    assert_eq!(attr(for_a[0], "state").as_deref(), Some("succeeded"));
    let since = attr(for_a[0], "since").unwrap_or_default();
    assert!(
        since.starts_with("awaiting"),
        "the earlier states of this delivery, oldest first: {since}"
    );
    assert_one_advisory_last(&merged);
}

#[test]
fn a_queued_notice_is_told_when_its_turn_starts() {
    let r = Rig::new();
    r.reply(F, Reply::Queued);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.status("a").0, NoticeStatus::Held);
    r.user_turn_starts(F);
    assert_eq!(
        r.status("a").0,
        NoticeStatus::Held,
        "a user's turn starting is not the notice's turn"
    );
    r.turn_ends(F);
    r.notice_turn_starts(F);
    assert_eq!(r.status("a"), (NoticeStatus::Told, None));
    assert!(!r.notice("a").history.last().unwrap().wake);
}

#[test]
fn an_idle_wake_is_told_at_once() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let n = r.notice("a");
    assert_eq!(n.status, NoticeStatus::Told);
    assert!(n.history.last().unwrap().wake);
    let delivered = r.audit_events("job_notice_delivered");
    assert_eq!(delivered.len(), 1);
    assert_eq!(delivered[0]["wake"], true);
    assert_eq!(delivered[0]["combined"], 1);
    assert_eq!(delivered[0]["focus"], F);
    assert_eq!(delivered[0]["job_ids"], serde_json::json!(["a"]));
}

#[test]
fn deliveries_wait_while_the_focus_runs_a_notice_turn_and_go_when_it_ends() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.notice_turn_starts(F);

    r.jobs(&[job(F, "b", "succeeded")]);
    r.after(30 * SEC);
    r.after(5 * MIN);
    assert_eq!(
        r.deliveries().len(),
        1,
        "nothing while the notice turn runs"
    );
    assert_eq!(
        r.status("b"),
        (NoticeStatus::Held, Some(NoticeReason::Busy))
    );
    let held = r.focus(F).and_then(|f| f.held).expect("F shows a hold");
    assert_eq!(held.reason, NoticeReason::Busy);
    assert_eq!(held.count, 1);

    r.turn_ends(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "delivered when the notice turn ends");
    assert_eq!(ids(&ds[1].fresh), sorted(&["b"]));
}

// ── MF2a-5: switches ─────────────────────────────────────────────────────────

fn set_focus(r: &Rig, tag: &str, mode: NotifyLevel) {
    r.engine
        .apply_settings(NoticeScope::Focus, Some(tag), Some(mode), None)
        .expect("a valid focus setting");
}

fn set_global(r: &Rig, enabled: bool) {
    r.engine
        .apply_settings(NoticeScope::Global, None, None, Some(enabled))
        .expect("a valid global setting");
}

#[test]
fn a_focus_set_off_gets_nothing_and_holds_nothing() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Off);
    r.jobs(&[job(F, "a", "running")]);
    r.advance(SEC);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.cli_turn_starts(F);
    r.user_turn_starts(F);
    r.after(2 * HOUR);
    assert!(r.deliveries().is_empty());
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Dropped, Some(NoticeReason::FocusOff))
    );
    let f = r.focus(F).expect("F has a mode set");
    assert_eq!(f.mode, NotifyLevel::Off);
    assert_eq!(f.held, None, "nothing is held for an Off focus");
}

#[test]
fn setting_a_focus_off_drops_what_was_waiting_and_takes_back_a_queued_notice() {
    let r = Rig::new();
    r.reply(F, Reply::Queued);
    r.jobs(&[job(F, "queued-already", "succeeded")]);
    r.after(30 * SEC);
    r.jobs(&[job(F, "batching", "succeeded")]);

    set_focus(&r, F, NotifyLevel::Off);
    assert!(
        r.withdrawn().contains(&F.to_owned()),
        "the queued notice is taken back"
    );
    for id in ["queued-already", "batching"] {
        assert_eq!(
            r.status(id),
            (NoticeStatus::Dropped, Some(NoticeReason::FocusOff)),
            "{id}"
        );
    }
    r.after(HOUR);
    r.user_turn_starts(F);
    assert_eq!(r.deliveries().len(), 1, "nothing after the switch");
    assert_eq!(r.focus(F).and_then(|f| f.held), None);
}

#[test]
fn global_off_means_no_delivery_to_any_focus_until_it_is_back_on() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded"), job(G, "b", "failed")]);
    set_global(&r, false);
    let withdrawn = r.withdrawn();
    assert!(withdrawn.contains(&F.to_owned()) && withdrawn.contains(&G.to_owned()));
    for id in ["a", "b"] {
        assert_eq!(
            r.status(id),
            (NoticeStatus::Dropped, Some(NoticeReason::GlobalOff)),
            "{id}"
        );
    }
    r.jobs(&[job(F, "c", "cancelled")]);
    assert_eq!(
        r.status("c"),
        (NoticeStatus::Dropped, Some(NoticeReason::GlobalOff))
    );
    r.after(HOUR);
    r.user_turn_starts(F);
    r.user_turn_starts(G);
    assert!(r.deliveries().is_empty());
    match r.engine.state_msg() {
        ServerMsg::MotherNoticeState { enabled, .. } => assert!(!enabled),
        other => panic!("not a notice state frame: {other:?}"),
    }

    set_global(&r, true);
    r.jobs(&[job(F, "d", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["d"]));
}

#[test]
fn a_quiet_focus_is_never_woken_and_gets_one_combined_message_after_its_next_turn_starts() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    r.jobs(&[job(F, "a", "succeeded"), job(F, "b", "failed")]);
    r.after(30 * SEC);
    r.after(3 * HOUR);
    assert!(r.deliveries().is_empty(), "Quiet never wakes");
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Held, Some(NoticeReason::Quiet))
    );

    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "one message after the turn starts");
    assert_eq!(ids(&ds[0].fresh), sorted(&["a", "b"]));
    assert_one_advisory_last(&ds[0].fresh);

    r.turn_ends(F);
    r.notice_turn_starts(F);
    assert_eq!(r.status("a").0, NoticeStatus::Told);
    assert_eq!(r.status("b").0, NoticeStatus::Told);
}

#[test]
fn a_quiet_focus_releases_after_a_turn_of_any_author() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(HOUR);
    r.reply(F, Reply::Queued);
    r.cli_turn_starts(F);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["a"]));
}

#[test]
fn switching_a_focus_to_quiet_while_a_window_is_open_stops_the_wake() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    set_focus(&r, F, NotifyLevel::Quiet);
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    assert_eq!(r.deliveries().len(), 1);
}

#[test]
fn switching_quiet_back_to_wake_does_not_wake_for_what_is_held() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    set_focus(&r, F, NotifyLevel::Wake);
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(r.deliveries().is_empty(), "held items go at the next turn");
    r.reply(F, Reply::Queued);
    r.cli_turn_starts(F);
    assert_eq!(r.deliveries().len(), 1);
}

#[test]
fn a_quiet_focus_is_not_woken_when_a_notice_turn_ends() {
    // Quiet means no wake (MF2a-5). A change that arrives while a Quiet
    // focus runs a notice turn waits for the focus's next turn to start; it
    // does not start a turn of its own when this one ends.
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    assert_eq!(r.deliveries().len(), 1);
    r.turn_ends(F);
    r.notice_turn_starts(F);

    r.jobs(&[job(F, "b", "succeeded")]);
    r.after(30 * SEC);
    // The session is idle once this turn ends: a delivery now would wake it.
    r.reply(F, Reply::Woke);
    r.turn_ends(F);
    r.after(HOUR);
    assert_eq!(
        r.deliveries().len(),
        1,
        "b must not wake the Quiet focus after the notice turn"
    );
    assert_eq!(r.status("b").0, NoticeStatus::Held);

    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["b"]));
}

#[test]
fn a_job_set_to_notify_off_is_never_told_under_a_waking_focus() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded").notify(NotifyLevel::Off)]);
    r.after(30 * SEC);
    r.user_turn_starts(F);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());
    assert_eq!(r.status("a").0, NoticeStatus::Dropped);
}

#[test]
fn a_job_set_to_wake_does_not_wake_a_quiet_focus() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    r.jobs(&[job(F, "a", "succeeded").notify(NotifyLevel::Wake)]);
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Held, Some(NoticeReason::Quiet))
    );
}

#[test]
fn a_job_set_to_quiet_does_not_wake_a_waking_focus() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded").notify(NotifyLevel::Quiet)]);
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());
    r.reply(F, Reply::Queued);
    r.cli_turn_starts(F);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["a"]));
}

#[test]
fn settings_survive_a_restart() {
    let r = Rig::with_store();
    r.jobs(&[]);
    set_focus(&r, F, NotifyLevel::Quiet);
    set_focus(&r, G, NotifyLevel::Off);
    set_global(&r, false);

    let r = r.restart();
    match r.engine.state_msg() {
        ServerMsg::MotherNoticeState { enabled, focuses } => {
            assert!(!enabled, "global off survives");
            let mode = |tag: &str| focuses.iter().find(|f| f.tag == tag).map(|f| f.mode);
            assert_eq!(mode(F), Some(NotifyLevel::Quiet));
            assert_eq!(mode(G), Some(NotifyLevel::Off));
        }
        other => panic!("not a notice state frame: {other:?}"),
    }

    set_global(&r, true);
    r.jobs(&[job(F, "a", "succeeded"), job(G, "b", "succeeded")]);
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(
        r.deliveries().is_empty(),
        "Quiet and Off are still honoured"
    );
    assert_eq!(r.status("b").0, NoticeStatus::Dropped);
}

#[test]
fn incomplete_settings_are_refused_and_change_nothing() {
    let r = Rig::new();
    assert_eq!(
        r.engine
            .apply_settings(NoticeScope::Focus, None, Some(NotifyLevel::Off), None),
        Err(SettingsError::FocusNeedsTagAndMode)
    );
    assert_eq!(
        r.engine
            .apply_settings(NoticeScope::Focus, Some(F), None, None),
        Err(SettingsError::FocusNeedsTagAndMode)
    );
    assert!(r
        .engine
        .apply_settings(NoticeScope::Focus, Some(""), Some(NotifyLevel::Off), None)
        .is_err());
    assert_eq!(
        r.engine
            .apply_settings(NoticeScope::Global, None, None, None),
        Err(SettingsError::GlobalNeedsEnabled)
    );
    assert!(r.engine.enabled());
    assert!(r.audit_events("mother_notice_settings_changed").is_empty());
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 1, "F is still Wake");
}

#[test]
fn settings_changes_and_refusals_are_audited_with_enums_only() {
    let r = Rig::new();
    set_focus(&r, F, NotifyLevel::Quiet);
    set_global(&r, false);
    r.engine.audit_settings_refused("local_other");

    let changed = r.audit_events("mother_notice_settings_changed");
    assert_eq!(changed.len(), 2);
    assert_eq!(changed[0]["scope"], "focus");
    assert_eq!(changed[0]["focus"], F);
    assert_eq!(changed[0]["mode"], "quiet");
    assert_eq!(changed[1]["scope"], "global");
    assert_eq!(changed[1]["enabled"], false);
    let refused = r.audit_events("mother_notice_settings_refused");
    assert_eq!(refused.len(), 1);
    assert_eq!(refused[0]["peer"], "local_other");
}

// ── MF2a-6: closed focus, not running, expiry, restart ───────────────────────

#[test]
fn a_closed_focus_gets_nothing_and_its_jobs_say_not_sent_focus_closed() {
    let r = Rig::new();
    r.jobs(&[job(F, "pending", "succeeded")]);
    r.engine.on_registry(&[G.to_owned()], &[F.to_owned()]);
    r.after(30 * SEC);
    assert_eq!(
        r.status("pending"),
        (NoticeStatus::NotSent, Some(NoticeReason::FocusClosed))
    );

    r.jobs(&[job(F, "later", "failed")]);
    r.after(30 * SEC);
    r.cli_turn_starts(F);
    r.after(HOUR);
    assert!(
        r.deliveries_to(F).is_empty(),
        "nothing is delivered to a closed focus"
    );
    assert_eq!(
        r.status("later"),
        (NoticeStatus::NotSent, Some(NoticeReason::FocusClosed))
    );
    let dropped = r.audit_events("job_notice_dropped");
    assert!(
        dropped
            .iter()
            .any(|d| d["focus"] == F && d["reason"] == "focus_closed"),
        "{dropped:?}"
    );

    r.jobs(&[job(G, "other", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries_to(G).len(), 1, "other focuses are unaffected");
}

#[test]
fn a_held_notice_for_a_focus_that_closes_is_dropped_as_not_sent() {
    let r = Rig::new();
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.status("a").0, NoticeStatus::Held);
    r.engine.on_registry(&[], &[F.to_owned()]);
    r.tick();
    assert_eq!(
        r.status("a"),
        (NoticeStatus::NotSent, Some(NoticeReason::FocusClosed))
    );
    r.reply(F, Reply::Woke);
    r.user_turn_starts(F);
    assert_eq!(r.deliveries().len(), 1, "only the failed attempt");
}

#[test]
fn a_focus_without_a_running_session_holds_until_its_next_turn_starts() {
    let r = Rig::new();
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(
        r.status("a"),
        (NoticeStatus::Held, Some(NoticeReason::SessionNotRunning))
    );
    let held = r.focus(F).and_then(|f| f.held).expect("F shows a hold");
    assert_eq!(held.reason, NoticeReason::SessionNotRunning);
    assert_eq!(held.count, 1);
    let attempts = r.deliveries().len();

    // The session comes back, idle. Nothing is written until a turn starts.
    r.reply(F, Reply::Woke);
    r.after(5 * MIN);
    r.after(HOUR);
    assert_eq!(
        r.deliveries().len(),
        attempts,
        "a held notice waits for the focus's next turn, it does not wake"
    );

    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    let d = r.last_delivery(F);
    assert_eq!(ids(&d.fresh), sorted(&["a"]));
    r.turn_ends(F);
    r.notice_turn_starts(F);
    assert_eq!(r.status("a").0, NoticeStatus::Told);
    assert_eq!(r.wakes(F), 1, "that delivery is a notice turn (Q3)");
}

#[test]
fn a_not_running_hold_is_released_by_a_turn_of_any_author() {
    let r = Rig::new();
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let attempts = r.deliveries().len();
    r.reply(F, Reply::Queued);
    r.cli_turn_starts(F);
    assert_eq!(r.deliveries().len(), attempts + 1);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["a"]));
}

#[test]
fn a_hold_older_than_24_hours_is_dropped_and_audited_as_expired() {
    let r = Rig::new();
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.after(23 * HOUR);
    assert_eq!(
        r.status("a").0,
        NoticeStatus::Held,
        "younger than 24 h: kept"
    );
    r.after(2 * HOUR);
    assert_eq!(
        r.status("a").0,
        NoticeStatus::Dropped,
        "older than 24 h: dropped"
    );
    let dropped = r.audit_events("job_notice_dropped");
    assert!(
        dropped
            .iter()
            .any(|d| d["focus"] == F && d["reason"] == "expired"),
        "{dropped:?}"
    );
    let attempts = r.deliveries().len();
    r.reply(F, Reply::Woke);
    r.user_turn_starts(F);
    assert_eq!(
        r.deliveries().len(),
        attempts,
        "an expired notice is never sent"
    );
    assert_eq!(r.focus(F).and_then(|f| f.held), None);
}

#[test]
fn the_first_run_ever_announces_nothing() {
    let r = Rig::with_store();
    r.jobs(&[
        job(F, "a", "succeeded"),
        job(F, "b", "awaiting").asking("Which one?"),
        job(F, "c", "failed").with_pr("https://github.com/acme/repo/pull/1"),
    ]);
    r.after(30 * SEC);
    r.jobs(&[
        job(F, "a", "succeeded"),
        job(F, "b", "awaiting").asking("Which one?"),
        job(F, "c", "failed").with_pr("https://github.com/acme/repo/pull/1"),
    ]);
    r.after(HOUR);
    r.user_turn_starts(F);
    assert!(r.deliveries().is_empty(), "what was there was never news");
    assert!(
        r.store_path.as_ref().unwrap().exists(),
        "the first look is recorded"
    );

    r.jobs(&[job(F, "d", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(ids(&r.last_delivery(F).fresh), sorted(&["d"]));
}

#[test]
fn a_job_that_finished_while_the_daemon_was_down_is_announced_once_and_never_again() {
    let r = Rig::with_store();
    r.jobs(&[job(F, "a", "running")]);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());

    // Down; the job succeeds meanwhile.
    let r = r.restart();
    r.advance(HOUR);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.after(HOUR);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "exactly one notice after the restart");
    assert_eq!(
        attr(element_for(&ds[0].fresh, "a"), "state").as_deref(),
        Some("succeeded")
    );

    let r = r.restart();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    r.after(HOUR);
    r.user_turn_starts(F);
    assert!(r.deliveries().is_empty(), "a second restart says nothing");
}

#[test]
fn a_restart_while_a_window_is_open_still_announces_the_change_exactly_once() {
    let r = Rig::with_store();
    r.jobs(&[]);
    r.jobs(&[job(F, "a", "running")]);
    r.advance(SEC);
    r.jobs(&[job(F, "a", "succeeded")]);

    let r = r.restart();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(2 * MIN);
    r.user_turn_starts(F);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1);

    let r = r.restart();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(2 * MIN);
    r.user_turn_starts(F);
    assert!(r.deliveries().is_empty());
}

#[test]
fn a_notice_held_for_a_stopped_session_survives_a_restart() {
    let r = Rig::with_store();
    r.jobs(&[]);
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.status("a").0, NoticeStatus::Held);

    let r = r.restart();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(2 * MIN);
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "delivered once after the restart");
    assert_eq!(ids(&ds[0].fresh), sorted(&["a"]));
}

#[test]
fn a_notice_queued_but_unwritten_when_the_daemon_stopped_is_delivered_once_after_the_restart() {
    let r = Rig::with_store();
    r.jobs(&[]);
    r.reply(F, Reply::Queued);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 1);

    let r = r.restart();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(2 * MIN);
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    r.after(HOUR);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 1, "the lost message is delivered once");
    r.turn_ends(F);
    r.notice_turn_starts(F);
    assert_eq!(r.status("a").0, NoticeStatus::Told);
}

#[test]
fn a_change_dropped_by_a_switch_is_not_announced_after_a_restart_or_when_the_switch_is_back_on() {
    let r = Rig::with_store();
    r.jobs(&[]);
    set_focus(&r, F, NotifyLevel::Off);
    r.jobs(&[job(F, "a", "succeeded")]);
    let r = r.restart();
    set_focus(&r, F, NotifyLevel::Wake);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(HOUR);
    r.user_turn_starts(F);
    assert!(r.deliveries().is_empty());
}

// ── the notice record (§W) ───────────────────────────────────────────────────

#[test]
fn jobs_not_queued_by_a_verified_focus_are_never_notified() {
    let r = Rig::new();
    let jobs = vec![
        job_of_kind(OriginKind::Unverified, Some(F), "unverified", "running"),
        job_of_kind(OriginKind::You, None, "you", "running"),
        job_of_kind(OriginKind::Unknown, None, "unknown", "running"),
        MotherJob {
            id: "bare".into(),
            state: "running".into(),
            ..Default::default()
        },
    ];
    r.jobs(&jobs);
    let done: Vec<MotherJob> = jobs
        .into_iter()
        .map(|mut j| {
            j.state = "succeeded".into();
            j
        })
        .collect();
    r.jobs(&done);
    r.after(30 * SEC);
    r.user_turn_starts(F);
    r.after(HOUR);
    assert!(r.deliveries().is_empty());
    for id in ["unverified", "you", "unknown"] {
        assert_eq!(
            r.status(id),
            (NoticeStatus::None, Some(NoticeReason::NotNotifiable)),
            "{id}"
        );
    }
}

#[test]
fn a_told_job_records_its_state_time_and_history() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "running")]);
    r.advance(SEC);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let n = r.notice("a");
    assert_eq!(n.status, NoticeStatus::Told);
    assert_eq!(n.last_state, Some(JobEvent::Succeeded));
    assert_eq!(n.at_ms, Some(r.now()));
    let last = n.history.last().expect("a history entry");
    assert_eq!(last.status, NoticeStatus::Told);
    assert_eq!(last.states, vec![JobEvent::Running, JobEvent::Succeeded]);
    assert!(last.wake);
    assert_eq!(last.at_ms, r.now());
}

#[test]
fn a_jobs_history_keeps_the_newest_ten_entries_newest_last() {
    let r = Rig::new();
    let mut told_at = Vec::new();
    for _ in 0..12 {
        r.jobs(&[job(F, "a", "running")]);
        r.advance(SEC);
        r.jobs(&[job(F, "a", "awaiting").asking("Which one?")]);
        r.after(30 * SEC);
        told_at.push(r.now());
        r.advance(MIN);
    }
    assert_eq!(r.deliveries().len(), 12);
    let history = r.notice("a").history;
    assert_eq!(history.len(), 10);
    assert_eq!(history.last().unwrap().at_ms, *told_at.last().unwrap());
    assert!(
        history.windows(2).all(|w| w[0].at_ms <= w[1].at_ms),
        "oldest first, newest last"
    );
    assert!(
        history.iter().all(|h| h.at_ms >= told_at[2]),
        "the two oldest deliveries are gone"
    );
}

#[test]
fn annotate_puts_each_jobs_notice_record_on_the_job() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded"), job(F, "b", "running")]);
    r.after(30 * SEC);
    let mut jobs = vec![job(F, "a", "succeeded"), job(F, "b", "running")];
    r.engine.annotate(&mut jobs);
    let notice = |j: &MotherJob| j.nostromo.as_ref().and_then(|a| a.notice.clone());
    assert_eq!(notice(&jobs[0]), r.engine.notice_of("a"));
    assert_eq!(notice(&jobs[0]).map(|n| n.status), Some(NoticeStatus::Told));
    assert_eq!(notice(&jobs[1]), r.engine.notice_of("b"));
}

#[test]
fn the_feed_republishes_jobs_with_their_fresh_notice_records() {
    let r = Rig::new();
    let feed = JobsFeed::new().with_notices(Arc::clone(&r.engine));
    let published = feed.publish_jobs(vec![job(F, "a", "running")]);
    r.jobs(&published);
    r.advance(SEC);
    let published = feed.publish_jobs(vec![job(F, "a", "succeeded")]);
    r.jobs(&published);
    r.after(30 * SEC);

    let republished = feed
        .republish_annotations()
        .expect("a list was published before");
    let status = |jobs: &[MotherJob]| {
        jobs.iter()
            .find(|j| j.id == "a")
            .and_then(|j| j.nostromo.as_ref())
            .and_then(|a| a.notice.as_ref())
            .map(|n| n.status)
    };
    assert_eq!(status(&republished), Some(NoticeStatus::Told));
    assert_eq!(
        status(&feed.jobs_rx().borrow()),
        Some(NoticeStatus::Told),
        "every reader of the feed sees it"
    );
}

#[test]
fn a_notice_state_change_is_signalled_for_republishing() {
    let r = Rig::new();
    let mut changes = r.engine.changes();
    changes.borrow_and_update();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    assert!(changes.has_changed().unwrap_or(false));
}

#[test]
fn the_state_frame_lists_each_focus_with_its_mode_and_hold() {
    let r = Rig::new();
    set_focus(&r, G, NotifyLevel::Quiet);
    r.reply(F, Reply::Down);
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    match r.engine.state_msg() {
        ServerMsg::MotherNoticeState { enabled, focuses } => {
            assert!(enabled);
            let f = focuses.iter().find(|f| f.tag == F).expect("F is listed");
            assert_eq!(f.mode, NotifyLevel::Wake);
            let held = f.held.as_ref().expect("F holds a notice");
            assert_eq!(held.count, 1);
            assert_eq!(held.reason, NoticeReason::SessionNotRunning);
            assert!(!f.chain_held);
            let g = focuses.iter().find(|f| f.tag == G).expect("G is listed");
            assert_eq!(g.mode, NotifyLevel::Quiet);
            assert_eq!(g.held, None);
        }
        other => panic!("not a notice state frame: {other:?}"),
    }
}
