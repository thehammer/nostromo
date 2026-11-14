//! The author's PR list with the github relay: what a relay event costs and
//! changes, what the list says when the relay is down, and how it catches up
//! after a reconnect. The real engine runs against a fake GitHub and a hand-fed
//! relay channel (see `support/authored_prs_rig.rs`) on paused time.
//!
//! The delay between a relay event and the read it causes is the documented
//! 2 s coalescing window; the snapshot follows the read within the 250 ms
//! publish debounce. The tests state both separately.

#[path = "support/authored_prs_rig.rs"]
mod rig;

use std::time::Duration;

use nostromo::data::authored_prs::snapshot::{ChecksState, Lifecycle, RelayState};
use nostromo::data::relay_client::RelayEvent;
use rig::*;

const REPO: &str = "Carefeed/app";
const COALESCE: Duration = Duration::from_secs(2);
const DEBOUNCE: Duration = Duration::from_millis(250);
const STEP: Duration = Duration::from_millis(50);

fn pending_fake() -> Fake {
    let fake = Fake::new();
    fake.put(FakePr::new(REPO, 1).pending("build"));
    fake.put(FakePr::new(REPO, 2).passing("build").approved_by("bob"));
    fake
}

/// The relay is up, demand is `level` and the first reconcile is done.
async fn live_at(fake: Fake, level: &str) -> Rig {
    let mut rig = Rig::start(fake, RigOpts { relay: true, token: true }).await;
    rig.relay_up().await;
    rig.set_demand(level).await;
    rig.run(secs(10), secs(1)).await;
    assert_eq!(rig.snapshot().unwrap().relay.state, RelayState::Live);
    rig
}

/// The relay is up, demand is visible and the first reconcile is done.
async fn live(fake: Fake) -> Rig {
    live_at(fake, "visible").await
}

fn sha_of(repo: &str, n: u64) -> String {
    format!("sha-{}-{n}", repo.replace('/', "-").to_lowercase())
}

// ═════════════════════════════════════════════════════════════════════════════
// What an event costs
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn ci_completed_for_a_known_head_costs_one_graphql_read_and_no_search() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    assert_eq!(rig.row(REPO, 1).unwrap().checks.state, ChecksState::Pending);

    fake.edit(REPO, 1, |p| {
        p.checks = vec![("build".into(), "COMPLETED".into(), Some("SUCCESS".into()))];
    });
    let mark = rig.fake.log_len();
    let event_at = rig.elapsed;
    rig.relay_event(ci_completed(REPO, &sha_of(REPO, 1))).await;
    let seen = rig
        .run_until(secs(6), STEP, |r| {
            r.row(REPO, 1).map(|p| p.checks.state) == Some(ChecksState::Passing)
        })
        .await
        .expect("the snapshot shows the finished check");

    let since = rig.since(mark);
    assert_eq!(
        since.iter().filter(|r| r.kind() == Kind::Graphql).count(),
        1,
        "exactly one GraphQL read: {since:?}"
    );
    assert!(
        since.iter().all(|r| r.kind() == Kind::Graphql),
        "no search, no /user: {since:?}"
    );
    let read_at = rig.requests()[mark].0;
    assert!(
        read_at - event_at <= COALESCE + STEP,
        "the read follows the event by the coalescing window at most: {:?}",
        read_at - event_at
    );
    assert!(
        seen - read_at <= DEBOUNCE + STEP,
        "the snapshot follows the read within the 250 ms debounce: {:?}",
        seen - read_at
    );
}

#[tokio::test]
async fn ci_completed_matches_the_repo_without_regard_to_case() {
    let mut rig = live(pending_fake()).await;
    let mark = rig.fake.log_len();
    rig.relay_event(ci_completed("carefeed/APP", &sha_of(REPO, 1))).await;
    rig.run(secs(4), STEP).await;
    assert_eq!(rig.count_since(mark, Kind::Graphql), 1);
}

#[tokio::test]
async fn ci_completed_for_a_head_nobody_knows_costs_nothing() {
    let mut rig = live(pending_fake()).await;
    let mark = rig.fake.log_len();
    rig.relay_event(ci_completed(REPO, "some-other-sha")).await;
    rig.relay_event(ci_completed("Carefeed/elsewhere", &sha_of(REPO, 1))).await;
    rig.relay_event(relay_ev("ci.completed", REPO)).await; // no sha at all
    rig.run(secs(10), STEP).await;
    assert_eq!(rig.fake.log_len(), mark, "{:?}", rig.since(mark));
}

#[tokio::test]
async fn pr_merged_costs_nothing_and_the_row_is_merged_at_once() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    fake.edit(REPO, 1, |p| {
        p.in_search = false;
        p.state = "MERGED".into();
        p.merged = true;
    });
    let mark = rig.fake.log_len();
    let event_at = rig.elapsed;
    let mut ev = relay_pr_ev("pr.merged", REPO, 1);
    ev.merged = Some(true);
    rig.relay_event(ev).await;
    let seen = rig
        .run_until(secs(3), STEP, |r| {
            r.row(REPO, 1).map(|p| p.lifecycle) == Some(Lifecycle::Merged)
        })
        .await
        .expect("merged");
    assert!(seen - event_at <= DEBOUNCE + STEP, "{:?}", seen - event_at);
    assert_eq!(rig.fake.log_len(), mark, "a merge costs no request: {:?}", rig.since(mark));
    assert!(rig.row(REPO, 1).unwrap().ended_at.is_some());
    assert_eq!(rig.row(REPO, 2).unwrap().lifecycle, Lifecycle::Open, "the other is untouched");
}

#[tokio::test]
async fn pr_closed_without_a_merge_marks_the_row_closed_for_free_and_it_is_dropped_after_a_minute() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    fake.edit(REPO, 1, |p| {
        p.in_search = false;
        p.state = "CLOSED".into();
    });
    let mark = rig.fake.log_len();
    let mut ev = relay_pr_ev("pr.closed", REPO, 1);
    ev.merged = Some(false);
    rig.relay_event(ev).await;
    rig.run(secs(3), STEP).await;
    assert_eq!(rig.row(REPO, 1).unwrap().lifecycle, Lifecycle::Closed);
    assert_eq!(rig.count_since(mark, Kind::Graphql), 0);

    let before = rig.elapsed;
    let gone = rig
        .run_until(secs(90), Duration::from_millis(500), |r| r.row(REPO, 1).is_none())
        .await
        .expect("dropped");
    assert!(gone - before >= secs(55) && gone - before <= secs(62), "{:?}", gone - before);
    assert!(rig.row(REPO, 2).is_some());
}

#[tokio::test]
async fn pr_events_for_a_known_pr_cost_one_read_however_many_arrive_inside_the_window() {
    let mut rig = live(pending_fake()).await;
    let mark = rig.fake.log_len();
    for ty in [
        "pr.synchronize",
        "pr.review_submitted",
        "pr.review_requested",
        "pr.review_request_removed",
        "pr.synchronize",
    ] {
        rig.relay_event(relay_pr_ev(ty, REPO, 2)).await;
        rig.run(Duration::from_millis(200), STEP).await;
    }
    rig.run(secs(5), STEP).await;
    let since = rig.since(mark);
    assert_eq!(
        since.iter().filter(|r| r.kind() == Kind::Graphql).count(),
        1,
        "five events inside one window are one read: {since:?}"
    );
    assert!(since.iter().all(|r| r.kind() == Kind::Graphql), "{since:?}");
}

#[tokio::test]
async fn a_new_pr_the_relay_says_is_mine_is_read_and_listed_without_a_search() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    // It exists on GitHub but the engine has not seen it.
    fake.put(FakePr::new(REPO, 9).passing("build"));
    let mark = rig.fake.log_len();
    let mut ev = relay_pr_ev("pr.opened", REPO, 9);
    ev.author = Some(ME.to_owned());
    rig.relay_event(ev).await;
    rig.run(secs(5), STEP).await;
    assert!(rig.row(REPO, 9).is_some(), "listed");
    assert_eq!(rig.count_since(mark, Kind::Graphql), 1);
    assert_eq!(rig.count_since(mark, Kind::Search), 0);
}

#[tokio::test]
async fn a_new_pr_by_someone_else_or_an_event_about_an_unknown_pr_costs_nothing() {
    let fake = pending_fake();
    fake.put(FakePr::new(REPO, 8).author("someone-else").out_of_search());
    let mut rig = live(fake).await;
    let mark = rig.fake.log_len();
    let mut theirs = relay_pr_ev("pr.opened", REPO, 8);
    theirs.author = Some("someone-else".into());
    rig.relay_event(theirs).await;
    rig.relay_event(relay_pr_ev("pr.synchronize", REPO, 8)).await; // unknown PR
    rig.relay_event(relay_pr_ev("pr.review_submitted", REPO, 77)).await;
    rig.relay_event(relay_pr_ev("pr.opened", REPO, 78)).await; // no author hint at all
    rig.run(secs(8), STEP).await;
    assert_eq!(rig.fake.log_len(), mark, "{:?}", rig.since(mark));
    assert!(rig.row(REPO, 8).is_none());
}

#[tokio::test]
async fn events_with_no_usable_repo_or_a_hostile_one_are_ignored() {
    let mut rig = live(pending_fake()).await;
    let mark = rig.fake.log_len();
    for repo in [None, Some(""), Some("no-slash"), Some("a/b/c"), Some("o/n\"){ x"), Some("../x")] {
        rig.relay_event(RelayEvent {
            event_type: "pr.synchronize".into(),
            repo: repo.map(str::to_owned),
            number: Some(1),
            ..Default::default()
        })
        .await;
    }
    rig.run(secs(6), STEP).await;
    assert_eq!(rig.fake.log_len(), mark, "{:?}", rig.since(mark));
}

#[tokio::test]
async fn after_a_push_the_new_head_is_the_one_ci_events_match() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    fake.edit(REPO, 1, |p| p.head_sha = "brand-new-head".into());
    rig.relay_event(relay_pr_ev("pr.synchronize", REPO, 1)).await;
    rig.run(secs(5), STEP).await;

    let mark = rig.fake.log_len();
    rig.relay_event(ci_completed(REPO, &sha_of(REPO, 1))).await; // the old head
    rig.run(secs(4), STEP).await;
    assert_eq!(rig.fake.log_len(), mark, "the old head no longer matches");
    rig.relay_event(ci_completed(REPO, "brand-new-head")).await;
    rig.run(secs(4), STEP).await;
    assert_eq!(rig.count_since(mark, Kind::Graphql), 1);
}

#[tokio::test]
async fn relay_events_never_trigger_a_search_or_a_full_reconcile() {
    // Hidden: search runs every five minutes, so a search any sooner than that
    // can only have been caused by something else, and the one-a-minute search
    // gap is no excuse.
    let mut rig = live_at(pending_fake(), "hidden").await;
    let mark = rig.fake.log_len();
    let kinds = ["pr.synchronize", "pr.review_submitted", "pr.review_requested", "pr.opened"];
    for i in 0..40usize {
        let mut ev = relay_pr_ev(kinds[i % kinds.len()], REPO, 1 + (i as u64 % 2));
        ev.author = Some(ME.into());
        rig.relay_event(ev).await;
        rig.relay_event(ci_completed(REPO, &sha_of(REPO, 1))).await;
        rig.run(secs(7), secs(1)).await;
    }
    // 40 * 7 s = 280 s: inside one five-minute search interval.
    assert!(rig.elapsed < secs(10 + 300));
    let since = rig.since(mark);
    assert_eq!(
        since.iter().filter(|r| r.kind() == Kind::Search).count(),
        0,
        "{} events and not one search: {since:?}",
        40 * 2
    );
    assert_eq!(since.iter().filter(|r| r.kind() == Kind::User).count(), 0);
    // Not a full reconcile either: one graphql read never covers both PRs
    // because of an event for one (a reconcile reads every PR at once).
    assert!(
        since.iter().filter(|r| r.kind() == Kind::Graphql).count() >= 1,
        "the events were read"
    );
}

#[tokio::test]
async fn relay_events_leave_the_search_cadence_alone_over_ten_minutes() {
    let mut rig = live(pending_fake()).await;
    let mark = rig.fake.log_len();
    for i in 0..40usize {
        rig.relay_event(relay_pr_ev("pr.synchronize", REPO, 1 + (i as u64 % 2))).await;
        rig.run(secs(15), secs(1)).await;
    }
    let n = rig.count_since(mark, Kind::Search);
    assert!(n <= 10, "ten minutes of cadence is ten searches: {n}");
    let times: Vec<Duration> = rig.of_kind(Kind::Search).into_iter().map(|(t, _)| t).collect();
    for w in times.windows(2) {
        assert!(w[1] - w[0] >= secs(60), "{times:?}");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The relay's own state
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn without_a_relay_the_list_says_not_configured() {
    let mut rig = Rig::start(pending_fake(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.relay.state, RelayState::NotConfigured);
    assert_eq!(snap.relay.since, None);
}

#[tokio::test]
async fn when_the_relay_goes_down_the_list_says_offline_since_when() {
    let mut rig = live(pending_fake()).await;
    rig.relay_down().await;
    rig.run_until(secs(6), Duration::from_millis(250), |r| {
        r.snapshot().map(|s| s.relay.state) == Some(RelayState::Offline)
    })
    .await
    .expect("noticed within a few seconds");
    let relay = rig.snapshot().unwrap().relay;
    assert!(relay.since.is_some(), "offline says since when: {relay:?}");
    assert_eq!(relay.org, "Carefeed");
}

#[tokio::test]
async fn a_relay_organisations_pending_prs_are_polled_only_while_the_relay_is_not_covering_them() {
    let mut rig = live(pending_fake()).await;

    // Live: the relay covers Carefeed, so a pending check is not polled.
    let mark = rig.fake.log_len();
    rig.run(mins(5), secs(5)).await;
    assert_eq!(
        rig.count_since(mark, Kind::Graphql),
        0,
        "no polling of a PR the relay covers: {:?}",
        rig.since(mark)
    );

    // Down: the PR joins the pending-CI refresh, once a minute.
    rig.relay_down().await;
    let mark = rig.fake.log_len();
    rig.run(mins(5), secs(5)).await;
    let polled = rig.count_since(mark, Kind::Graphql);
    assert!(polled >= 4, "polled while the relay is down: {polled}");

    // Back: the reconcile runs, and then the polling stops again.
    rig.relay_up().await;
    rig.run(secs(150), secs(5)).await;
    let mark = rig.fake.log_len();
    rig.run(mins(5), secs(5)).await;
    assert_eq!(rig.count_since(mark, Kind::Graphql), 0, "{:?}", rig.since(mark));
}

#[tokio::test]
async fn after_a_reconnect_the_relay_is_catching_up_until_a_reconcile_succeeds_and_then_live() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    rig.relay_down().await;
    rig.run(mins(2), secs(5)).await;

    // The reconcile after the reconnect is going to fail.
    fake.force("search", Some(Forced { status: 500, retry_after: None }));
    let reconnected_at = rig.elapsed;
    rig.relay_up().await;
    rig.run(secs(10), secs(1)).await;
    assert_eq!(
        rig.snapshot().unwrap().relay.state,
        RelayState::CatchingUp,
        "connected, but not yet reconciled"
    );
    assert_eq!(rig.snapshot().unwrap().relay.since, None);

    // Ten minutes of failing reconciles: it never claims to be live.
    rig.run(mins(10), secs(5)).await;
    let healed_from = rig.elapsed;
    for (at, snap) in &rig.published {
        if *at > reconnected_at + secs(1) && *at <= healed_from {
            assert_eq!(
                snap.relay.state,
                RelayState::CatchingUp,
                "snapshot at {at:?} claims {:?} before any reconcile succeeded",
                snap.relay.state
            );
        }
    }
    assert!(
        rig.of_kind(Kind::Search).iter().any(|(_, r)| r.status == 500),
        "the reconcile really was failing"
    );

    // The service recovers; the next reconcile succeeds and the relay is live.
    fake.force("search", None);
    let live_at = rig
        .run_until(mins(15), secs(5), |r| {
            r.snapshot().map(|s| s.relay.state) == Some(RelayState::Live)
        })
        .await
        .expect("live once a reconcile has succeeded");
    assert!(live_at > healed_from);
    let first_ok_search = rig
        .of_kind(Kind::Search)
        .into_iter()
        .filter(|(t, r)| *t > reconnected_at && r.status != 500)
        .map(|(t, _)| t)
        .min()
        .expect("a search succeeded after the reconnect");
    assert!(
        first_ok_search <= live_at,
        "live only after a search succeeded: ok at {first_ok_search:?}, live at {live_at:?}"
    );
}

#[tokio::test]
async fn a_reconnect_reconciles_once_and_goes_live() {
    let mut rig = live(pending_fake()).await;
    rig.relay_down().await;
    rig.run(mins(3), secs(5)).await;
    let mark = rig.fake.log_len();
    rig.relay_up().await;
    rig.run(secs(70), secs(1)).await;
    assert!(rig.count_since(mark, Kind::Search) >= 1);
    assert!(rig.count_since(mark, Kind::Graphql) >= 1, "everything is read again");
    assert_eq!(rig.snapshot().unwrap().relay.state, RelayState::Live);
}

#[tokio::test]
async fn a_pr_that_merged_while_the_relay_was_down_becomes_merged_without_any_event() {
    let fake = pending_fake();
    let mut rig = live(fake.clone()).await;
    rig.relay_down().await;
    // It merges while we cannot hear: gone from the search, merged in the detail.
    fake.edit(REPO, 2, |p| {
        p.in_search = false;
        p.state = "MERGED".into();
        p.merged = true;
    });
    rig.run(secs(30), secs(5)).await;
    rig.relay_up().await;
    rig.run_until(mins(3), secs(1), |r| {
        r.row(REPO, 2).map(|p| p.lifecycle) == Some(Lifecycle::Merged)
    })
    .await
    .expect("the reconcile learns it merged");
    assert_eq!(rig.row(REPO, 1).unwrap().lifecycle, Lifecycle::Open);
    assert!(rig.row(REPO, 2).unwrap().ended_at.is_some());
}
