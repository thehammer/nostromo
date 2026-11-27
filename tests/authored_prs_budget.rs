//! What the author's PR list may ask of GitHub: an hour of it, in every
//! posture, in a rate limit, and with nobody looking. The real engine runs
//! against a fake GitHub on paused time (see `support/authored_prs_rig.rs`);
//! the numbers below are counted from the requests the fake actually saw, and
//! cross-checked against the usage the snapshot reports.
//!
//! A search answered 304 is not charged against the budget (GitHub does not
//! count it either); every other request, GraphQL included, is.

#[path = "support/authored_prs_rig.rs"]
mod rig;

use std::time::Duration;

use chrono::Duration as Chrono;
use nostromo::data::authored_prs::snapshot::{PollState, RefreshBlocked, RelayState};
use rig::*;

const HOUR: Duration = Duration::from_secs(3600);

/// Twenty open PRs across two organisations; six have a pending check.
fn twenty(fake: &Fake) {
    for i in 1..=20u64 {
        let repo = if i % 2 == 0 {
            "thehammer/proj"
        } else {
            "third-org/widgets"
        };
        let pr = FakePr::new(repo, i).updated(t0() - Chrono::minutes(i as i64));
        fake.put(if i % 3 == 0 {
            pr.pending("build")
        } else {
            pr.passing("build")
        });
    }
}

fn search_times(rig: &Rig) -> Vec<Duration> {
    rig.of_kind(Kind::Search)
        .into_iter()
        .map(|(t, _)| t)
        .collect()
}

fn charged_before(rig: &Rig, end: Duration) -> usize {
    rig.requests()
        .into_iter()
        .filter(|(t, r)| *t < end && r.status != 304)
        .count()
}

fn assert_gaps_at_least(times: &[Duration], gap: Duration) {
    for w in times.windows(2) {
        assert!(
            w[1] - w[0] >= gap,
            "two searches {:?} apart: {times:?}",
            w[1] - w[0]
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// An hour, visible and hidden
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn an_hour_of_visible_polling_of_twenty_prs_stays_inside_the_budget() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(3595), secs(5)).await;
    rig.advance(secs(1)).await; // the last publish

    let charged = charged_before(&rig, HOUR);
    assert!(charged <= 120, "charged {charged} requests in an hour");
    let searches = search_times(&rig);
    assert!(
        searches.len() <= 60,
        "{} searches in an hour",
        searches.len()
    );
    assert!(
        searches.len() >= 55,
        "visible polls about once a minute: {}",
        searches.len()
    );
    assert_gaps_at_least(&searches, secs(60));

    // The 304s are counted on their own and are not charged.
    let snap = rig.snapshot().unwrap();
    let usage = snap.usage;
    assert_eq!(
        usage.since_start.charged as usize,
        rig.charged(),
        "charged = everything but a 304"
    );
    assert_eq!(usage.since_start.not_modified as usize, rig.not_modified());
    assert_eq!(usage.since_start.search as usize, searches.len());
    assert!(
        usage.since_start.not_modified >= 40,
        "an unchanged list is mostly 304s: {}",
        usage.since_start.not_modified
    );
    assert_eq!(
        usage.since_start.charged, usage.since_start.visible_charged,
        "all of it was visible polling"
    );
    assert_eq!(
        usage.window.charged, usage.since_start.charged,
        "inside the rolling hour"
    );
    assert_eq!(snap.prs.len(), 20);
}

#[tokio::test]
async fn visible_polling_never_exceeds_the_hourly_cap_even_when_something_changes_every_minute() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    for minute in 0..60i64 {
        fake.edit("thehammer/proj", 2, |p| {
            p.updated_at = t0() + Chrono::minutes(minute + 1)
        });
        rig.run(secs(60), secs(5)).await;
    }
    let charged = charged_before(&rig, HOUR);
    assert!(charged <= 120, "charged {charged} in the hour");
    assert!(
        charged >= 110,
        "the scenario really did press on the cap: {charged}"
    );
    assert_gaps_at_least(&search_times(&rig), secs(60));
}

#[tokio::test]
async fn an_hour_of_hidden_polling_charges_at_most_twenty_requests() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("hidden").await;
    rig.run(secs(3595), secs(5)).await;
    rig.advance(secs(1)).await;

    let charged = charged_before(&rig, HOUR);
    assert!(
        charged <= 20,
        "charged {charged} requests in an hour while hidden"
    );
    let searches = search_times(&rig);
    // Twelve five-minute polls; the half-hour reconcile searches too, a little
    // ahead of the poll it replaces. Never closer than the one-a-minute gap.
    assert!(searches.len() <= 13, "{} searches", searches.len());
    assert!(searches.len() >= 11, "{} searches", searches.len());
    assert_gaps_at_least(&searches, secs(60));
    let close: Vec<_> = searches
        .windows(2)
        .filter(|w| w[1] - w[0] < mins(4))
        .collect();
    assert!(
        close.len() <= 1,
        "only the reconcile's search may come early: {searches:?}"
    );
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.poll.interval_secs, 300);
    assert_eq!(snap.usage.since_start.visible_charged, 0);
    assert_eq!(
        snap.usage.since_start.hidden_charged,
        snap.usage.since_start.charged
    );
}

#[tokio::test]
async fn hidden_polling_never_exceeds_twenty_charged_even_when_something_changes_every_interval() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("hidden").await;
    for i in 0..12i64 {
        fake.edit("thehammer/proj", 2, |p| {
            p.updated_at = t0() + Chrono::minutes(i + 1)
        });
        rig.run(mins(5), secs(5)).await;
    }
    let charged = charged_before(&rig, HOUR);
    assert!(charged <= 20, "charged {charged}");
    assert!(
        charged >= 15,
        "the scenario really did press on the cap: {charged}"
    );
}

#[tokio::test]
async fn relay_reads_are_capped_at_twenty_an_hour_when_hidden() {
    let fake = Fake::new();
    for i in 1..=3u64 {
        fake.put(FakePr::new("Carefeed/app", i).passing("build"));
    }
    let mut rig = Rig::start(
        fake,
        RigOpts {
            relay: true,
            token: true,
            ..Default::default()
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("hidden").await;
    rig.run(secs(10), secs(1)).await;
    // An event every five seconds for the rest of the hour.
    while rig.elapsed < secs(3595) {
        rig.relay_event(relay_pr_ev(
            "pr.synchronize",
            "Carefeed/app",
            1 + (rig.elapsed.as_secs() / 5) % 3,
        ))
        .await;
        rig.run(secs(5), secs(5)).await;
    }
    rig.advance(secs(1)).await;
    let u = rig.snapshot().unwrap().usage;
    assert!(
        u.since_start.relay_charged >= 15,
        "events were read: {}",
        u.since_start.relay_charged
    );
    assert!(
        u.since_start.relay_charged <= 20,
        "relay reads while hidden are capped at 20 an hour: {}",
        u.since_start.relay_charged
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Nobody looking
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn with_no_operator_connection_the_feature_makes_no_request_for_an_hour_and_relay_events_cost_nothing(
) {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(
        fake,
        RigOpts {
            relay: true,
            token: true,
            ..Default::default()
        },
    )
    .await;
    rig.relay_up().await; // a reconnect, with nobody looking
    rig.run(secs(10), secs(1)).await;
    let settled = rig.published.len();
    for i in 0..360u64 {
        if i % 30 == 0 {
            rig.relay_event(relay_pr_ev("pr.synchronize", "third-org/widgets", 1))
                .await;
            rig.relay_event(ci_completed("third-org/widgets", "whatever"))
                .await;
            rig.relay_event(relay_pr_ev("pr.opened", "Carefeed/app", 99))
                .await;
            if i % 90 == 0 {
                rig.relay_up().await;
            }
        }
        rig.advance(secs(10)).await;
    }
    assert_eq!(rig.fake.log_len(), 0, "{:?}", rig.requests().first());
    let snap = rig.snapshot().expect("a snapshot says nobody is looking");
    assert_eq!(snap.poll.state, PollState::Idle);
    assert_eq!(snap.poll.interval_secs, 0);
    assert_eq!(
        rig.published.len(),
        settled,
        "an idle hour publishes nothing new"
    );
}

#[tokio::test]
async fn an_explicit_idle_stops_all_requests_and_returning_to_visible_costs_exactly_one_reconcile()
{
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            token: true,
            ..Default::default()
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(150), secs(5)).await;
    assert!(rig.fake.log_len() > 3);

    rig.set_demand("idle").await;
    rig.run(secs(2), secs(1)).await;
    let mark = rig.fake.log_len();
    let published = rig.published.len();
    for i in 0..360u64 {
        if i % 20 == 0 {
            rig.relay_event(relay_pr_ev("pr.synchronize", "third-org/widgets", 1))
                .await;
            rig.relay_event(relay_pr_ev("pr.review_submitted", "third-org/widgets", 3))
                .await;
        }
        rig.advance(secs(10)).await;
    }
    assert_eq!(
        rig.count_since(mark, Kind::User)
            + rig.count_since(mark, Kind::Search)
            + rig.count_since(mark, Kind::Graphql),
        0,
        "an hour of idle: {:?}",
        rig.since(mark)
    );
    // Nothing about the list changed on the wire while nobody looked, apart from
    // the rolling-hour usage counts running down as old requests age out.
    for pair in rig.published[published.saturating_sub(1)..].windows(2) {
        let (mut before, after) = (pair[0].1.clone(), pair[1].1.clone());
        before.generated_at = after.generated_at;
        before.usage.window = after.usage.window;
        assert_eq!(
            before, after,
            "an idle hour changed more than the usage window"
        );
        assert!(pair[1].1.usage.window.charged <= pair[0].1.usage.window.charged);
    }
    assert_eq!(rig.snapshot().unwrap().poll.state, PollState::Idle);

    // Looking again: one reconcile, and nothing else for the next minute.
    let mark = rig.fake.log_len();
    rig.set_demand("visible").await;
    rig.run(secs(59), secs(1)).await;
    let since = rig.since(mark);
    assert_eq!(
        since.iter().map(|r| r.kind()).collect::<Vec<_>>(),
        vec![Kind::Search, Kind::Graphql],
        "exactly one reconcile (the identity is already known): {since:?}"
    );
    // And it carries on at the visible cadence afterwards.
    rig.run(secs(130), secs(5)).await;
    assert!(rig.count_since(mark, Kind::Search) >= 3);
}

#[tokio::test]
async fn changing_between_visible_and_hidden_changes_the_cadence_and_asks_for_nothing_by_itself() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("hidden").await;
    rig.run(secs(30), secs(1)).await;
    assert_eq!(rig.snapshot().unwrap().poll.interval_secs, 300);

    let mark = rig.fake.log_len();
    rig.set_demand("visible").await;
    rig.run(secs(2), secs(1)).await;
    assert_eq!(
        rig.snapshot().unwrap().poll.interval_secs,
        60,
        "visible cadence"
    );
    assert_eq!(
        rig.fake.log_len(),
        mark,
        "the change itself asks for nothing"
    );

    rig.run(secs(100), secs(5)).await;
    let mark = rig.fake.log_len();
    rig.set_demand("hidden").await;
    rig.run(secs(2), secs(1)).await;
    assert_eq!(
        rig.fake.log_len(),
        mark,
        "dropping to hidden asks for nothing"
    );
    assert_eq!(rig.snapshot().unwrap().poll.interval_secs, 300);
}

#[tokio::test]
async fn the_highest_demand_over_all_connections_wins_and_a_closed_connection_withdraws_its_own() {
    let rig = Rig::start(Fake::new(), RigOpts::default()).await;
    let board = rig.demand.clone();
    use nostromo::data::authored_prs::Demand;
    assert_eq!(board.current(), Demand::Idle, "nobody has said anything");
    board.set("a", "hidden");
    assert_eq!(board.current(), Demand::Hidden);
    board.set("b", "visible");
    assert_eq!(board.current(), Demand::Visible);
    board.set("c", "idle");
    assert_eq!(
        board.current(),
        Demand::Visible,
        "an idle connection asks for nothing"
    );
    board.remove("b");
    assert_eq!(board.current(), Demand::Hidden, "b went away");
    board.set("a", "idle");
    assert_eq!(board.current(), Demand::Idle);
    board.set("d", "something-new");
    assert_eq!(
        board.current(),
        Demand::Hidden,
        "an unknown level counts as hidden"
    );
    board.remove("d");
    board.remove("never-existed");
    assert_eq!(board.current(), Demand::Idle);
}

// ═════════════════════════════════════════════════════════════════════════════
// What an event or a full reconcile costs
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_relay_event_costs_at_most_two_requests_and_never_a_search_and_a_merge_costs_none() {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).pending("build"));
    fake.put(FakePr::new("Carefeed/app", 2).passing("build"));
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            token: true,
            ..Default::default()
        },
    )
    .await;
    rig.relay_up().await;
    // Hidden: the next search is five minutes off, so a search two minutes in
    // would be the event's doing.
    rig.set_demand("hidden").await;
    rig.run(secs(120), secs(5)).await;

    let mark = rig.fake.log_len();
    rig.relay_event(relay_pr_ev("pr.synchronize", "Carefeed/app", 1))
        .await;
    rig.relay_event(ci_completed("Carefeed/app", "sha-carefeed-app-1"))
        .await;
    rig.run(secs(10), Duration::from_millis(250)).await;
    let since = rig.since(mark);
    assert!(
        since.len() <= 2,
        "an event costs at most two requests: {since:?}"
    );
    assert!(
        since.iter().all(|r| r.kind() == Kind::Graphql),
        "never a search: {since:?}"
    );
    assert_eq!(
        rig.snapshot().unwrap().usage.since_start.relay_charged as usize,
        since.len()
    );

    let mark = rig.fake.log_len();
    fake.edit("Carefeed/app", 2, |p| {
        p.in_search = false;
        p.state = "MERGED".into();
        p.merged = true;
    });
    let mut merged = relay_pr_ev("pr.merged", "Carefeed/app", 2);
    merged.merged = Some(true);
    rig.relay_event(merged).await;
    rig.run(secs(10), Duration::from_millis(250)).await;
    assert_eq!(
        rig.fake.log_len(),
        mark,
        "pr.merged costs nothing: {:?}",
        rig.since(mark)
    );
}

#[tokio::test]
async fn a_full_reconcile_of_twenty_prs_is_one_identity_read_one_search_and_one_graphql_batch() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(3), Duration::from_millis(250)).await;

    assert_eq!(rig.of_kind(Kind::User).len(), 1);
    assert_eq!(rig.of_kind(Kind::Search).len(), 1);
    assert_eq!(
        rig.of_kind(Kind::Graphql).len(),
        1,
        "twenty PRs fit one batch"
    );
    let u = rig.snapshot().unwrap().usage;
    assert!(u.since_start.charged <= 25, "{}", u.since_start.charged);
    assert_eq!(u.since_start.charged, 3);
    assert_eq!(u.since_start.graphql_points, 1);
    assert_eq!(rig.snapshot().unwrap().prs.len(), 20);
}

#[tokio::test]
async fn twenty_one_prs_need_two_graphql_batches_and_a_later_reconcile_stays_small() {
    let fake = Fake::new();
    twenty(&fake);
    fake.put(FakePr::new("thehammer/proj", 21).passing("build"));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(3), Duration::from_millis(250)).await;
    assert_eq!(rig.of_kind(Kind::Graphql).len(), 2);

    // The ten-minute reconcile: a search and the batches, never more than 25.
    rig.run(secs(590), secs(5)).await;
    let mark = rig.fake.log_len();
    rig.run(secs(20), secs(1)).await;
    let charged = rig.since(mark).iter().filter(|r| r.status != 304).count();
    assert!(charged <= 25, "{charged}");
}

// ═════════════════════════════════════════════════════════════════════════════
// GitHub's own limits
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn under_twenty_percent_remaining_a_visible_list_polls_like_a_hidden_one_and_says_it_is_rate_limited(
) {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    assert_eq!(rig.snapshot().unwrap().poll.interval_secs, 60);

    fake.set_rate(Some(Rate {
        remaining: 15,
        limit: 100,
        reset: t0() + Chrono::hours(1),
    }));
    let limited_at = rig
        .run_until(mins(3), secs(1), |r| {
            r.snapshot().map(|s| s.poll.state) == Some(PollState::RateLimited)
        })
        .await
        .expect("the next response carries the low reading");
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.poll.interval_secs, 300, "hidden cadence");
    assert_eq!(snap.poll.resumes_at, None, "not paused: only slower");

    let mark = rig.fake.log_len();
    rig.run(mins(16), secs(5)).await;
    let later: Vec<Duration> = rig
        .of_kind(Kind::Search)
        .into_iter()
        .map(|(t, _)| t)
        .filter(|t| *t > limited_at)
        .collect();
    assert!(later.len() <= 4, "{later:?}");
    assert_gaps_at_least(&later, mins(5));
    assert!(rig.count_since(mark, Kind::Search) >= 2, "it still polls");
}

#[tokio::test]
async fn under_five_percent_remaining_the_list_pauses_until_the_reset_and_asks_for_nothing_meanwhile(
) {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;

    let reset = t0() + Chrono::minutes(30);
    fake.set_rate(Some(Rate {
        remaining: 4,
        limit: 100,
        reset,
    }));
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("paused after the low reading");
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.poll.resumes_at, Some(reset), "resumes at the reset");

    // A refresh while paused is refused, and says so.
    let mark = rig.fake.log_len();
    rig.refresh().await;
    rig.run(secs(2), secs(1)).await;
    assert_eq!(
        rig.snapshot().unwrap().refresh_blocked,
        Some(RefreshBlocked::RateLimited)
    );

    // Nothing at all until the reset.
    let until_just_before_reset = mins(30) - secs(5) - rig.elapsed;
    rig.run(until_just_before_reset, secs(10)).await;
    assert_eq!(rig.fake.log_len(), mark, "paused: {:?}", rig.since(mark));
    assert_eq!(rig.snapshot().unwrap().poll.state, PollState::Paused);

    // The limit has reset: one reconcile, then back to normal.
    fake.set_rate(None);
    rig.run(secs(15), secs(1)).await;
    let since = rig.since(mark);
    assert_eq!(
        since.iter().filter(|r| r.kind() == Kind::Search).count(),
        1,
        "{since:?}"
    );
    assert_eq!(
        since.iter().filter(|r| r.kind() == Kind::Graphql).count(),
        1,
        "{since:?}"
    );
    assert_ne!(rig.snapshot().unwrap().poll.state, PollState::Paused);
}

#[tokio::test]
async fn a_403_with_retry_after_stops_every_request_until_it_has_passed_then_resumes() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;

    fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: Some(120),
        }),
    );
    let refused_at = rig
        .run_until(mins(3), secs(1), |r| {
            r.fake.log().iter().any(|q| q.status == 403)
        })
        .await
        .expect("the next search is refused");
    let failed_at = refused_at;
    rig.run(secs(2), secs(1)).await;
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.poll.state, PollState::Paused);
    let left = snap.poll.resumes_at.unwrap() - snap.generated_at;
    assert!(
        left > Chrono::seconds(100) && left <= Chrono::seconds(120),
        "{left}"
    );

    let mark = rig.fake.log_len();
    while rig.elapsed < failed_at + secs(119) {
        rig.advance(secs(1)).await;
    }
    assert_eq!(
        rig.fake.log_len(),
        mark,
        "zero requests for 119 s: {:?}",
        rig.since(mark)
    );

    fake.force("search", None);
    rig.run(secs(10), secs(1)).await;
    assert!(
        rig.fake.log_len() > mark,
        "resumed once the 120 s had passed"
    );
}

#[tokio::test]
async fn a_retry_after_longer_than_an_hour_is_honoured_for_an_hour_at_most() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 429,
            retry_after: Some(86_400),
        }),
    );
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("paused");
    let snap = rig.snapshot().unwrap();
    let left = snap.poll.resumes_at.unwrap() - snap.generated_at;
    assert!(left <= Chrono::seconds(3600), "{left}");
    assert!(left >= Chrono::seconds(3500), "{left}");
}

#[tokio::test]
async fn the_relay_state_is_unaffected_by_a_pause() {
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            token: true,
            ..Default::default()
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: Some(300),
        }),
    );
    rig.run(mins(3), secs(5)).await;
    assert_eq!(rig.snapshot().unwrap().poll.state, PollState::Paused);
    assert_eq!(
        rig.snapshot().unwrap().relay.state,
        RelayState::Live,
        "the relay is still delivering; only polling is paused"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The wall clock moves under the engine
// ═════════════════════════════════════════════════════════════════════════════

fn now_of(rig: &Rig) -> chrono::DateTime<chrono::Utc> {
    t0() + Chrono::from_std(rig.elapsed).unwrap()
}

#[tokio::test]
async fn a_rate_limit_that_resets_ten_hours_from_now_pauses_for_an_hour_at_most_and_requests_resume(
) {
    let fake = Fake::new();
    twenty(&fake);
    // GitHub says nothing is left and the window resets ten hours from now.
    fake.set_rate(Some(Rate {
        remaining: 0,
        limit: 5000,
        reset: t0() + Chrono::hours(10),
    }));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run_until(mins(2), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("paused after the empty reading");
    let resumes = rig.snapshot().unwrap().poll.resumes_at.unwrap();
    assert!(
        resumes <= now_of(&rig) + Chrono::hours(1),
        "a reset is never trusted past an hour: resumes at {resumes}, it is {}",
        now_of(&rig)
    );

    // The limit really does lift sooner than that header said.
    fake.set_rate(None);
    let mark = rig.fake.log_len();
    rig.run(mins(55), secs(10)).await;
    assert_eq!(rig.fake.log_len(), mark, "paused until the hour is up");
    rig.run_until(mins(10), secs(10), |r| r.fake.log_len() > mark)
        .await
        .expect("requests resume about an hour after the pause began, not ten");
    assert!(rig.elapsed <= mins(70), "{:?}", rig.elapsed);
}

#[tokio::test]
async fn a_pause_ends_when_the_wall_clock_jumps_past_it_without_waiting_out_the_jump() {
    // The Mac slept: the wall clock is hours ahead, little monotonic time passed.
    let jump = WallJump::new();
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            // A relay makes the engine look up every two seconds, so "the
            // next wake" is not an accident of the pause's own length.
            relay: true,
            wall_jump: Some(jump.clone()),
            ..Default::default()
        },
    )
    .await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 429,
            retry_after: Some(3600),
        }),
    );
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("paused for the Retry-After");

    // Still paused five minutes on: the pause is real.
    fake.force("search", None);
    let mark = rig.fake.log_len();
    rig.run(mins(5), secs(5)).await;
    assert_eq!(rig.fake.log_len(), mark, "no request while paused");

    // Five hours pass on the wall clock in an instant.
    jump.jump(Duration::from_secs(5 * 3600));
    let jumped_at = rig.elapsed;
    rig.run_until(secs(30), secs(1), |r| r.fake.log_len() > mark)
        .await
        .expect("the pause is over once the wall clock is past it");
    assert!(rig.elapsed - jumped_at <= secs(30));
    assert_ne!(rig.snapshot().unwrap().poll.state, PollState::Paused);
}

// ═════════════════════════════════════════════════════════════════════════════
// A secondary limit: a 403 or a GraphQL error with no Retry-After
// ═════════════════════════════════════════════════════════════════════════════

/// The list is paused for roughly a minute (never an error), asks for nothing
/// meanwhile, and goes back to work afterwards.
async fn assert_pauses_about_a_minute_then_resumes(rig: &mut Rig, lift: impl FnOnce()) {
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("a secondary limit pauses polling; it is not an error");
    let snap = rig.snapshot().unwrap();
    let resumes = snap.poll.resumes_at.expect("a pause says when it ends");
    let left = resumes - now_of(rig);
    assert!(
        left > Chrono::seconds(20) && left <= Chrono::hours(1),
        "paused for {left}"
    );
    assert_eq!(snap.poll.retry_at, None, "this is a pause, not a retry");
    assert!(
        !rig.published
            .iter()
            .any(|(_, s)| s.poll.state == PollState::Error),
        "the failure was never shown as `poll: error`"
    );

    // Nothing at all until the pause is over.
    let mark = rig.fake.log_len();
    let quiet_for = (resumes - now_of(rig)).to_std().unwrap() - secs(3);
    rig.run(quiet_for, secs(1)).await;
    assert_eq!(rig.fake.log_len(), mark, "paused: {:?}", rig.since(mark));

    lift();
    rig.run(secs(15), secs(1)).await;
    assert!(
        rig.fake.log_len() > mark,
        "polling resumed after the pause: {:?}",
        rig.since(mark)
    );
    assert_ne!(rig.snapshot().unwrap().poll.state, PollState::Paused);
    assert_ne!(rig.snapshot().unwrap().poll.state, PollState::Error);
}

/// Plenty left in the primary limit (this is GitHub's abuse protection), and a 403
/// whose body says `words`: a pause of about a minute, then back to work.
async fn a_403_saying_pauses_about_a_minute(words: &str) {
    let fake = Fake::new();
    twenty(&fake);
    fake.set_rate(Some(Rate {
        remaining: 4000,
        limit: 5000,
        reset: t0() + Chrono::minutes(50),
    }));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force_words("search", Some(words));
    fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: None,
        }),
    );
    let lifted = fake.clone();
    assert_pauses_about_a_minute_then_resumes(&mut rig, move || lifted.force("search", None)).await;
}

#[tokio::test]
async fn a_403_naming_a_secondary_limit_with_requests_remaining_is_a_pause_of_about_a_minute() {
    a_403_saying_pauses_about_a_minute("You have exceeded a Secondary Rate Limit").await;
}

#[tokio::test]
async fn a_403_naming_abuse_detection_in_any_case_is_a_pause_of_about_a_minute() {
    a_403_saying_pauses_about_a_minute("ABUSE detection mechanism triggered").await;
}

/// A 403 with allowance left and no `Retry-After` whose body says `words`: an
/// error with back-off, never a pause.
async fn a_403_saying_is_an_error_not_a_pause(words: &str) {
    let fake = Fake::new();
    twenty(&fake);
    fake.set_rate(Some(Rate {
        remaining: 4000,
        limit: 5000,
        reset: t0() + Chrono::minutes(50),
    }));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force_words("search", Some(words));
    fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: None,
        }),
    );
    rig.run_until(mins(3), secs(1), |r| {
        r.fake.log().iter().any(|q| q.status == 403)
    })
    .await
    .expect("the search is refused");
    rig.run(mins(5), secs(1)).await;

    assert!(
        !rig.published
            .iter()
            .any(|(_, s)| s.poll.state == PollState::Paused),
        "a permission refusal is never shown as `paused`"
    );
    assert!(
        rig.published
            .iter()
            .any(|(_, s)| s.poll.state == PollState::Error),
        "it is an error (retried with back-off)"
    );
}

#[tokio::test]
async fn a_permission_403_with_requests_remaining_is_an_error_with_backoff_not_a_pause() {
    a_403_saying_is_an_error_not_a_pause("Resource protected by organization SAML enforcement")
        .await;
}

#[tokio::test]
async fn only_the_first_few_kilobytes_of_a_403_body_are_read_for_the_limit_wording() {
    // The phrase sits past the read bound, so it is never seen: not a limit.
    let padded = format!("{} secondary rate limit", "x".repeat(8 * 1024));
    a_403_saying_is_an_error_not_a_pause(&padded).await;
}

#[tokio::test]
async fn a_429_with_no_retry_after_is_a_pause_whatever_its_body_says() {
    let fake = Fake::new();
    twenty(&fake);
    fake.set_rate(Some(Rate {
        remaining: 4000,
        limit: 5000,
        reset: t0() + Chrono::minutes(50),
    }));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 429,
            retry_after: None,
        }),
    );
    let lifted = fake.clone();
    assert_pauses_about_a_minute_then_resumes(&mut rig, move || lifted.force("search", None)).await;
}

#[tokio::test]
async fn a_graphql_rate_limited_error_in_a_200_is_a_pause_of_about_a_minute() {
    let fake = Fake::new();
    twenty(&fake);
    fake.force_graphql_body(Some(serde_json::json!({
        "errors": [{"type": "RATE_LIMITED", "message": "x"}],
        "data": null
    })));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    let lifted = fake.clone();
    assert_pauses_about_a_minute_then_resumes(&mut rig, move || lifted.force_graphql_body(None))
        .await;
    // Once the limit lifts the reconcile completes: the PRs are read.
    rig.run(secs(30), secs(1)).await;
    assert!(rig.row("thehammer/proj", 2).is_some(), "the list fills in");
}

// ═════════════════════════════════════════════════════════════════════════════
// A pause is measured on the wall clock, with nothing else to wake the engine
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn with_no_relay_a_pause_still_ends_within_a_minute_of_the_wall_clock_jumping_past_it() {
    let jump = WallJump::new();
    let fake = Fake::new();
    twenty(&fake);
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            // No relay: nothing else wakes the engine during the pause.
            relay: false,
            wall_jump: Some(jump.clone()),
            ..Default::default()
        },
    )
    .await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 429,
            retry_after: Some(3600),
        }),
    );
    rig.run_until(mins(3), secs(1), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Paused)
    })
    .await
    .expect("paused for the Retry-After");

    fake.force("search", None);
    let mark = rig.fake.log_len();
    rig.run(mins(5), secs(5)).await;
    assert_eq!(rig.fake.log_len(), mark, "no request while paused");

    // Five hours pass on the wall clock in an instant; no monotonic time does.
    jump.jump(Duration::from_secs(5 * 3600));
    let jumped_at = rig.elapsed;
    rig.run_until(secs(75), secs(1), |r| r.fake.log_len() > mark)
        .await
        .expect("requests resume within about a minute of the wall clock passing the pause");
    assert!(rig.elapsed - jumped_at <= secs(75));
    rig.run(secs(5), secs(1)).await;
    assert_ne!(rig.snapshot().unwrap().poll.state, PollState::Paused);
}

// ═════════════════════════════════════════════════════════════════════════════
// A secondary limit that keeps coming backs off; a stated Retry-After is obeyed
// ═════════════════════════════════════════════════════════════════════════════

/// Wait for a pause other than `previous` (by its end) and say how long it is.
async fn next_pause(rig: &mut Rig, previous: &mut Option<chrono::DateTime<chrono::Utc>>) -> Chrono {
    let seen = *previous;
    rig.run_until(mins(15), secs(1), |r| {
        r.snapshot().is_some_and(|s| {
            s.poll.state == PollState::Paused
                && s.poll.resumes_at.is_some()
                && s.poll.resumes_at != seen
        })
    })
    .await
    .expect("the engine paused again");
    let resumes = rig.snapshot().unwrap().poll.resumes_at.unwrap();
    *previous = Some(resumes);
    resumes - now_of(rig)
}

fn within(left: Chrono, lo: i64, hi: i64, what: &str) {
    assert!(
        left >= Chrono::seconds(lo) && left <= Chrono::seconds(hi),
        "{what}: paused for {left}, wanted {lo}..={hi} s"
    );
}

async fn visible_rig_over_twenty() -> Rig {
    let fake = Fake::new();
    twenty(&fake);
    fake.set_rate(Some(Rate {
        remaining: 4000,
        limit: 5000,
        reset: t0() + Chrono::hours(5),
    }));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    rig
}

fn force_search(rig: &Rig, status: u16, retry_after: Option<u64>, words: Option<&str>) {
    rig.fake.force_words("search", words);
    rig.fake.force(
        "search",
        Some(Forced {
            status,
            retry_after,
        }),
    );
}

#[tokio::test]
async fn a_secondary_limit_that_keeps_coming_backs_off_and_a_success_starts_it_over() {
    let mut rig = visible_rig_over_twenty().await;
    force_search(
        &rig,
        403,
        None,
        Some("You have exceeded a secondary rate limit"),
    );
    let mut prev = None;
    let first = next_pause(&mut rig, &mut prev).await;
    within(first, 50, 90, "the first");
    let second = next_pause(&mut rig, &mut prev).await;
    within(second, 100, 150, "the second in a row");
    let third = next_pause(&mut rig, &mut prev).await;
    within(third, 200, 300, "the third in a row");

    // GitHub is well again: a request succeeds, and the count starts over.
    rig.fake.force("search", None);
    rig.fake.force_words("search", None);
    let mark = rig.fake.log_len();
    rig.run_until(mins(15), secs(1), |r| {
        r.since(mark)
            .iter()
            // Unchanged results come back 304: a success all the same.
            .any(|q| q.kind() == Kind::Search && matches!(q.status, 200 | 304))
    })
    .await
    .expect("a search succeeds once the pause is over");
    force_search(
        &rig,
        403,
        None,
        Some("You have exceeded a secondary rate limit"),
    );
    let again = next_pause(&mut rig, &mut prev).await;
    within(again, 50, 90, "the first after a success");
}

async fn a_stated_retry_after_is_obeyed_as_given(status: u16) {
    let mut rig = visible_rig_over_twenty().await;
    force_search(&rig, status, Some(30), None);
    let mut prev = None;
    for i in 0..3 {
        let left = next_pause(&mut rig, &mut prev).await;
        within(left, 20, 40, &format!("{status} with Retry-After 30, #{i}"));
    }
}

#[tokio::test]
async fn a_429_with_retry_after_thirty_is_thirty_seconds_every_time_never_escalated() {
    a_stated_retry_after_is_obeyed_as_given(429).await;
}

#[tokio::test]
async fn a_403_with_retry_after_thirty_is_thirty_seconds_every_time_never_escalated() {
    a_stated_retry_after_is_obeyed_as_given(403).await;
}
