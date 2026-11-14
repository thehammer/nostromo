//! The author's PR list: scope, what never leaves GitHub, what is never
//! logged, and how fresh the list stays. The real engine runs against a fake
//! GitHub (see `support/authored_prs_rig.rs`) on paused time; everything below
//! is observed from outside: the requests the fake saw, and the snapshots the
//! engine published.

#[path = "support/authored_prs_rig.rs"]
mod rig;

use std::time::Duration;

use chrono::Duration as Chrono;
use nostromo::data::authored_prs::snapshot::{
    ChecksState, Group, Lifecycle, PollState, ReviewState, TokenState, MAX_BASE_REF,
    MAX_CHECK_NAME, MAX_FAILING_NAMES, MAX_LOGINS, MAX_PRS, MAX_TITLE,
};
use rig::*;

const SEARCH_QUERY: &str =
    "q=is:pr+is:open+author:@me+archived:false&sort=updated&order=desc&per_page=100";

fn one_pr_fake() -> Fake {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).passing("build"));
    fake
}

// ═════════════════════════════════════════════════════════════════════════════
// Scope
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_discovery_search_is_the_authored_open_pr_query_and_asks_again_with_the_last_etag() {
    let mut rig = Rig::start(one_pr_fake(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(secs(130), secs(5)).await;

    let searches = rig.of_kind(Kind::Search);
    assert!(
        searches.len() >= 3,
        "a search at entry and then every minute: {}",
        searches.len()
    );
    for (_, r) in &searches {
        assert_eq!(r.method, "GET");
        assert_eq!(
            r.query.as_deref(),
            Some(SEARCH_QUERY),
            "exactly the authored-PR query"
        );
    }
    assert_eq!(
        searches[0].1.if_none_match, None,
        "nothing to validate on the first ask"
    );
    assert_eq!(searches[0].1.status, 200);
    let etag = searches[0]
        .1
        .sent_etag
        .clone()
        .expect("the fake sent an ETag");
    assert_eq!(
        searches[1].1.if_none_match.as_deref(),
        Some(etag.as_str()),
        "the next ask carries the last ETag"
    );
    assert_eq!(
        searches[1].1.status, 304,
        "unchanged: GitHub answers not modified"
    );
    assert!(
        rig.row("Carefeed/app", 1).is_some(),
        "a 304 keeps the list the 200 gave"
    );
}

#[tokio::test]
async fn a_changed_search_result_is_validated_against_the_etag_it_replaced() {
    let fake = one_pr_fake();
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(secs(70), secs(5)).await;
    fake.put(FakePr::new("Carefeed/app", 2).passing("build"));
    rig.run(secs(130), secs(5)).await;

    let searches = rig.of_kind(Kind::Search);
    let changed = searches
        .iter()
        .position(|(_, r)| r.sent_etag != searches[0].1.sent_etag)
        .expect("a search saw the new list");
    assert_eq!(
        searches[changed].1.if_none_match,
        searches[changed - 1].1.sent_etag,
        "each ask carries the ETag of the answer before it"
    );
    assert_eq!(
        searches[changed].1.status, 200,
        "a changed list is a full answer"
    );
    assert!(rig.row("Carefeed/app", 2).is_some());
}

#[tokio::test]
async fn an_item_whose_detail_author_is_not_me_is_dropped() {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).passing("build"));
    // The search index says it is mine; the detail says it is someone else's.
    let mut theirs = FakePr::new("Carefeed/app", 2).author("someone-else");
    theirs.search_login = Some(ME.to_owned());
    fake.put(theirs);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;

    assert!(rig.row("Carefeed/app", 1).is_some());
    assert!(
        rig.row("Carefeed/app", 2).is_none(),
        "not mine, whatever search said"
    );
    // And it stays dropped through later cycles.
    rig.run(mins(12), secs(10)).await;
    assert!(rig.row("Carefeed/app", 2).is_none());
}

#[tokio::test]
async fn author_comparison_ignores_case() {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).author("TESTER"));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    assert!(rig.row("Carefeed/app", 1).is_some());
}

#[tokio::test]
async fn carefeed_thehammer_and_a_third_organisation_all_appear() {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/admin-portal", 11).passing("build"));
    fake.put(FakePr::new("thehammer/nostromo", 12).passing("build"));
    fake.put(FakePr::new("third-org/widgets", 13).passing("build"));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;

    let snap = rig.snapshot().expect("published");
    let mut repos: Vec<_> = snap.prs.iter().map(|p| p.repo.as_str()).collect();
    repos.sort();
    assert_eq!(
        repos,
        vec![
            "Carefeed/admin-portal",
            "thehammer/nostromo",
            "third-org/widgets"
        ]
    );
    let row = rig.row("thehammer/nostromo", 12).unwrap();
    assert_eq!(row.url, "https://github.com/thehammer/nostromo/pull/12");
}

#[tokio::test]
async fn a_draft_is_in_the_drafts_group_whatever_its_checks_and_reviews() {
    let fake = Fake::new();
    fake.put(
        FakePr::new("Carefeed/app", 1)
            .draft()
            .failing("unit")
            .changes_requested_by("bob")
            .comment_by("alice", t0() - Chrono::minutes(5)),
    );
    fake.put(
        FakePr::new("Carefeed/app", 2)
            .draft()
            .passing("build")
            .approved_by("bob"),
    );
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;

    for n in [1, 2] {
        let row = rig.row("Carefeed/app", n).unwrap();
        assert!(row.draft);
        assert_eq!(row.group, Group::Draft, "#{n}");
    }
    // The checks themselves are still reported.
    assert_eq!(
        rig.row("Carefeed/app", 1).unwrap().checks.state,
        ChecksState::Failing
    );
}

#[tokio::test]
async fn a_pr_whose_details_cannot_be_read_is_listed_as_details_unavailable() {
    let fake = Fake::new();
    let mut hidden = FakePr::new("third-org/private", 5);
    hidden.accessible = false;
    fake.put(hidden);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    let row = rig
        .row("third-org/private", 5)
        .expect("the search found it");
    assert!(row.details_unavailable);
}

#[tokio::test]
async fn the_feature_only_calls_user_search_and_graphql_and_names_itself_in_every_request() {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).pending("build"));
    fake.put(FakePr::new("thehammer/nostromo", 2).passing("build"));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(15), secs(10)).await;

    let all = rig.requests();
    assert!(
        all.len() > 10,
        "a quarter of an hour of visible polling: {}",
        all.len()
    );
    for (_, r) in &all {
        assert!(
            matches!(r.kind(), Kind::User | Kind::Search | Kind::Graphql),
            "unexpected request {} {}",
            r.method,
            r.path
        );
        assert_eq!(r.ua.as_deref(), Some(UA), "{} {}", r.method, r.path);
        assert_eq!(r.auth.as_deref(), Some(format!("Bearer {TOKEN}").as_str()));
    }
    assert!(
        rig.of_kind(Kind::User).len() == 1,
        "GET /user once per token"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// No text
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_graphql_query_never_asks_for_a_body_or_a_checks_output_summary_or_text() {
    let mut rig = Rig::start(one_pr_fake(), RigOpts::default()).await;
    rig.visible_and_settled().await;

    let queries: Vec<String> = rig
        .of_kind(Kind::Graphql)
        .into_iter()
        .map(|(_, r)| r.graphql_query())
        .collect();
    assert!(!queries.is_empty(), "a detail request was made");
    let words = regex::Regex::new(r"\b(body|bodyText|bodyHTML|output|summary|text)\b").unwrap();
    for q in &queries {
        assert!(q.contains("AuthoredPrDetail"), "{q}");
        // `context` and `contexts` are legitimate field names that merely
        // contain the letters `text`, so the check is by whole word.
        assert!(q.contains("context"), "the query reads check contexts");
        if let Some(m) = words.find(q) {
            panic!("the query asks for `{}`:\n{q}", m.as_str());
        }
        for never in ["bodyText", "bodyHTML", "output", "summary"] {
            assert!(!q.contains(never), "{never} in:\n{q}");
        }
    }
}

#[tokio::test]
async fn body_text_and_check_output_that_github_sends_anyway_never_reach_the_snapshot() {
    let fake = Fake::new();
    fake.put(
        FakePr::new("Carefeed/app", 1)
            .title("Fix the thing")
            .failing("unit-tests")
            .comment_by("alice", t0() - Chrono::minutes(5)),
    );
    fake.put(
        FakePr::new("thehammer/nostromo", 2)
            .pending("build")
            .approved_by("bob"),
    );
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(3), secs(5)).await;

    let text = rig.wire_text();
    assert!(
        text.contains("Fix the thing"),
        "the snapshot has the PR: {text}"
    );
    assert!(text.contains("unit-tests"), "and the failing check's name");
    for never in [CANARY_BODY, INJECTION, "CANARY", "ignore"] {
        assert!(
            !text.contains(never),
            "`{never}` reached the snapshot:\n{text}"
        );
    }
}

#[tokio::test]
async fn the_head_branch_and_sha_never_reach_the_wire() {
    let fake = Fake::new();
    fake.put(
        FakePr::new("Carefeed/app", 1)
            .head("canary/head-branch-Hq77", "canarysha0000Hq77deadbeef")
            .passing("build"),
    );
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(2), secs(5)).await;

    assert!(rig.row("Carefeed/app", 1).is_some());
    let text = rig.wire_text();
    for never in ["Hq77", "canary/head", "head_ref", "headRef", "head_sha"] {
        assert!(!text.contains(never), "`{never}` is on the wire:\n{text}");
    }
}

#[tokio::test]
async fn every_string_on_the_wire_is_bounded_and_every_login_is_a_login() {
    let login = regex::Regex::new(r"^[A-Za-z0-9-]{1,39}(\[bot\])?$").unwrap();
    let fake = Fake::new();
    let mut pr = FakePr::new("Carefeed/app", 1).title(&format!(
        "{}\n\u{1b}[31m{}",
        "T".repeat(10),
        "x".repeat(1000)
    ));
    pr.base_ref = format!("stack/{}", "b".repeat(300));
    for i in 0..30 {
        pr = pr.failing(&format!("check-{i}-{}", "n".repeat(300)));
    }
    for who in [
        "valid-one",
        "has space",
        "evil\nlogin",
        "a".repeat(50).as_str(),
        "<script>",
        "../etc",
    ] {
        pr = pr.changes_requested_by(who);
    }
    for i in 0..30 {
        pr = pr.changes_requested_by(&format!("reviewer-{i}"));
    }
    pr.reviews.push((
        "CHANGES_REQUESTED".into(),
        "robot[bot]".into(),
        "Bot".into(),
    ));
    pr.comments = (0..1200)
        .map(|_| {
            (
                t0() - Chrono::minutes(5),
                "alice".to_owned(),
                "User".to_owned(),
            )
        })
        .collect();
    fake.put(pr);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;

    let row = rig.row("Carefeed/app", 1).expect("the row");
    assert!(
        row.title.chars().count() <= MAX_TITLE,
        "{}",
        row.title.chars().count()
    );
    assert!(
        !row.title.chars().any(|c| c.is_control()),
        "{:?}",
        row.title
    );
    let base = row.base_ref.as_deref().expect("a stacked base is shown");
    assert!(
        base.chars().count() <= MAX_BASE_REF,
        "{}",
        base.chars().count()
    );
    assert_eq!(row.new_comments, 999, "capped");
    assert_eq!(row.checks.failed, 30, "every failure is counted");
    assert!(row.checks.failing_names.len() <= MAX_FAILING_NAMES);
    for n in &row.checks.failing_names {
        assert!(n.chars().count() <= MAX_CHECK_NAME, "{n}");
    }
    assert_eq!(row.review.state, ReviewState::ChangesRequested);
    assert!(row.review.logins.len() <= MAX_LOGINS);
    assert!(!row.review.logins.is_empty());
    for l in &row.review.logins {
        assert!(login.is_match(l), "not a login: {l:?}");
    }
    assert!(row.review.logins.contains(&"valid-one".to_string()));
}

#[tokio::test]
async fn at_most_one_hundred_rows_are_published_and_the_total_still_says_how_many_there_are() {
    let fake = Fake::new();
    seed_passing(&fake, "Carefeed/app", 130);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.prs.len(), MAX_PRS);
    assert_eq!(snap.shown as usize, MAX_PRS);
    assert_eq!(snap.total_open, 130);
    // 130 PRs are read twenty at a time.
    let graphql = rig.of_kind(Kind::Graphql).len();
    assert_eq!(graphql, 7, "ceil(130 / 20) detail requests");
}

// ═════════════════════════════════════════════════════════════════════════════
// Rows: classification, order, base branch, lingering
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn rows_are_ordered_needs_you_ready_waiting_drafts_then_newest_first() {
    let fake = Fake::new();
    let ago = |m: i64| t0() - Chrono::minutes(m);
    let repo = "Carefeed/app";
    fake.put(FakePr::new(repo, 1).failing("unit").updated(ago(60)));
    fake.put(
        FakePr::new(repo, 2)
            .changes_requested_by("bob")
            .passing("b")
            .updated(ago(10)),
    );
    fake.put(
        FakePr::new(repo, 3)
            .approved_by("bob")
            .passing("b")
            .updated(ago(30)),
    );
    fake.put(FakePr::new(repo, 4).pending("b").updated(ago(5)));
    fake.put(
        FakePr::new(repo, 5)
            .passing("b")
            .review_requested_of("carol")
            .updated(ago(20)),
    );
    fake.put(FakePr::new(repo, 6).draft().updated(ago(1)));
    fake.put(
        FakePr::new(repo, 7)
            .passing("b")
            .unresolved_threads(2)
            .updated(ago(45)),
    );
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;

    let rows = rig.snapshot().unwrap().prs;
    let order: Vec<(u64, Group)> = rows.iter().map(|r| (r.number, r.group)).collect();
    assert_eq!(
        order,
        vec![
            (2, Group::NeedsYou),
            (7, Group::NeedsYou),
            (1, Group::NeedsYou),
            (3, Group::Ready),
            (4, Group::Waiting),
            (5, Group::Waiting),
            (6, Group::Draft),
        ],
        "groups in order, each newest first"
    );
    let r7 = rig.row(repo, 7).unwrap();
    assert_eq!(r7.unresolved_threads, 2);
}

#[tokio::test]
async fn a_base_branch_is_published_only_when_it_is_not_main_or_the_repos_default() {
    let fake = Fake::new();
    let mut stacked = FakePr::new("Carefeed/app", 1).passing("b");
    stacked.base_ref = "release/2026-11".into();
    let mut on_main = FakePr::new("Carefeed/app", 2).passing("b");
    on_main.base_ref = "main".into();
    let mut on_default = FakePr::new("thehammer/old", 3).passing("b");
    on_default.default_branch = "develop".into();
    on_default.base_ref = "develop".into();
    let mut main_not_default = FakePr::new("thehammer/old", 4).passing("b");
    main_not_default.default_branch = "develop".into();
    main_not_default.base_ref = "main".into();
    for p in [stacked, on_main, on_default, main_not_default] {
        fake.put(p);
    }
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    assert_eq!(
        rig.row("Carefeed/app", 1).unwrap().base_ref.as_deref(),
        Some("release/2026-11")
    );
    assert_eq!(rig.row("Carefeed/app", 2).unwrap().base_ref, None);
    assert_eq!(rig.row("thehammer/old", 3).unwrap().base_ref, None);
    assert_eq!(rig.row("thehammer/old", 4).unwrap().base_ref, None);
}

#[tokio::test]
async fn a_merged_or_closed_pr_lingers_for_a_minute_then_is_dropped() {
    let fake = Fake::new();
    seed_passing(&fake, "thehammer/proj", 3);
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    assert_eq!(rig.snapshot().unwrap().prs.len(), 3);

    // #2 merges and #3 is closed without merging; neither is in the search any more.
    fake.edit("thehammer/proj", 2, |p| {
        p.in_search = false;
        p.state = "MERGED".into();
        p.merged = true;
    });
    fake.edit("thehammer/proj", 3, |p| {
        p.in_search = false;
        p.state = "CLOSED".into();
    });
    let both_ended = rig
        .run_until(mins(3), Duration::from_millis(500), |r| {
            let lc = |n| r.row("thehammer/proj", n).map(|p| p.lifecycle);
            lc(2) == Some(Lifecycle::Merged) && lc(3) == Some(Lifecycle::Closed)
        })
        .await
        .expect("the next poll learns what became of them");
    let merged = rig.row("thehammer/proj", 2).unwrap();
    assert!(merged.ended_at.is_some(), "a merged row says when it ended");
    assert_eq!(
        rig.row("thehammer/proj", 1).unwrap().lifecycle,
        Lifecycle::Open
    );

    let gone = rig
        .run_until(mins(2), Duration::from_millis(500), |r| {
            r.row("thehammer/proj", 2).is_none() && r.row("thehammer/proj", 3).is_none()
        })
        .await
        .expect("they are dropped");
    let lingered = gone - both_ended;
    assert!(
        lingered >= secs(59) && lingered <= secs(63),
        "lingered {lingered:?}: a minute, plus one debounce"
    );
    assert!(rig.row("thehammer/proj", 1).is_some(), "the open one stays");
}

// ═════════════════════════════════════════════════════════════════════════════
// Logs
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_full_cycle_a_relay_event_and_failures_log_no_title_branch_check_login_repo_url_number_or_token(
) {
    let (log, _guard) = capture_logs();
    tracing::trace!("capture-check");

    let fake = Fake::new();
    fake.state.lock().unwrap().me = "canary-me-Zq81".into();
    let mut pr = FakePr::new("canary-org/canary-repo", 424242)
        .author("canary-me-Zq81")
        .title("CANARY-TITLE-Zq81")
        .head("canary/branch-Zq81", "canarysha-Zq81")
        .failing("canary-check-Zq81")
        .changes_requested_by("canary-reviewer-Zq81")
        .comment_by("canary-commenter-Zq81", t0() - Chrono::minutes(2));
    pr.default_branch = "canary-default-Zq81".into();
    pr.base_ref = "canary-base-Zq81".into();
    fake.put(pr);
    fake.state.lock().unwrap().sso = Some("partial-results; organizations=987654".into());
    fake.state
        .lock()
        .unwrap()
        .orgs
        .insert(987654, Some("canary-hidden-org-Zq81".into()));

    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            token: true,
        },
    )
    .await;
    rig.relay_up().await;
    rig.visible_and_settled().await;

    // A relay event for the known head, carrying every canary it can.
    let mut ev = ci_completed("canary-org/canary-repo", "canarysha-Zq81");
    ev.title = Some("CANARY-TITLE-Zq81".into());
    ev.url = Some("https://github.com/canary-org/canary-repo/pull/424242".into());
    ev.author = Some("canary-me-Zq81".into());
    ev.name = Some("canary-check-Zq81".into());
    ev.number = Some(424242);
    rig.relay_event(ev).await;
    rig.run(secs(5), secs(1)).await;

    // A failing search, then a rate-limit pause, then recovery.
    fake.force(
        "search",
        Some(Forced {
            status: 500,
            retry_after: None,
        }),
    );
    rig.run(mins(3), secs(5)).await;
    fake.force(
        "search",
        Some(Forced {
            status: 403,
            retry_after: Some(30),
        }),
    );
    rig.run(mins(6), secs(5)).await;
    fake.force("search", None);
    rig.run(mins(8), secs(5)).await;

    let text = log.text();
    assert!(text.contains("capture-check"), "the capture works: {text}");
    assert!(
        text.contains("authored-prs"),
        "the feature logged something: {text}"
    );
    for never in [
        "Zq81",
        "CANARY-TITLE",
        "canary/branch",
        "canary-",
        "424242",
        "github.com/canary",
        "CANARY-ERROR-BODY",
        TOKEN,
        "AuthoredPrsTestToken",
        "Bearer",
    ] {
        assert!(!text.contains(never), "`{never}` was logged:\n{text}");
    }
    // The snapshot did carry them (so the test is not vacuous).
    let wire = rig.wire_text();
    assert!(
        wire.contains("CANARY-TITLE-Zq81") && wire.contains("424242"),
        "{wire}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Freshness without the relay
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_visible_list_shows_a_non_relay_change_within_two_minutes() {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/proj", 1).passing("build"));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(2), secs(5)).await;
    assert_eq!(rig.row("thehammer/proj", 1).unwrap().group, Group::Waiting);

    // Someone reviews it: the PR's updated_at moves.
    let before = rig.elapsed;
    fake.edit("thehammer/proj", 1, |p| {
        p.reviews
            .push(("CHANGES_REQUESTED".into(), "bob".into(), "User".into()));
        p.updated_at = t0() + Chrono::minutes(5);
    });
    let seen = rig
        .run_until(mins(2), secs(1), |r| {
            r.row("thehammer/proj", 1).map(|p| p.group) == Some(Group::NeedsYou)
        })
        .await;
    let seen = seen.expect("visible: within two minutes");
    assert!(seen - before <= mins(2), "{:?}", seen - before);
}

#[tokio::test]
async fn a_check_that_finishes_without_touching_updated_at_is_seen_through_the_pending_refresh() {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/proj", 1).pending("build"));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    assert_eq!(
        rig.row("thehammer/proj", 1).unwrap().checks.state,
        ChecksState::Pending
    );

    let before = rig.elapsed;
    fake.edit("thehammer/proj", 1, |p| {
        p.checks = vec![("build".into(), "COMPLETED".into(), Some("FAILURE".into()))];
    });
    let seen = rig
        .run_until(mins(2), secs(1), |r| {
            r.row("thehammer/proj", 1).map(|p| p.checks.state) == Some(ChecksState::Failing)
        })
        .await
        .expect("a finished check shows within two minutes when visible");
    assert!(seen - before <= mins(2));
    assert_eq!(rig.row("thehammer/proj", 1).unwrap().group, Group::NeedsYou);
}

#[tokio::test]
async fn a_hidden_list_shows_a_non_relay_change_within_fifteen_minutes() {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/proj", 1).passing("build"));
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("hidden").await;
    rig.run(mins(1), secs(5)).await;
    assert_eq!(rig.row("thehammer/proj", 1).unwrap().group, Group::Waiting);

    let before = rig.elapsed;
    fake.edit("thehammer/proj", 1, |p| {
        p.reviews
            .push(("CHANGES_REQUESTED".into(), "bob".into(), "User".into()));
        p.updated_at = t0() + Chrono::minutes(5);
    });
    let seen = rig
        .run_until(mins(15), secs(5), |r| {
            r.row("thehammer/proj", 1).map(|p| p.group) == Some(Group::NeedsYou)
        })
        .await
        .expect("hidden: within fifteen minutes");
    assert!(seen - before <= mins(15));
}

#[tokio::test]
async fn a_failed_search_keeps_checked_at_and_reports_an_error_with_a_retry_time() {
    let fake = one_pr_fake();
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(secs(90), secs(5)).await;
    let good = rig.snapshot().unwrap();
    let checked = good
        .poll
        .checked_at
        .expect("a successful cycle stamps checked_at");
    assert_eq!(good.poll.state, PollState::Ok);

    fake.force(
        "search",
        Some(Forced {
            status: 500,
            retry_after: None,
        }),
    );
    rig.run_until(mins(3), secs(5), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Error)
    })
    .await
    .expect("the failure shows");
    let bad = rig.snapshot().unwrap();
    assert_eq!(
        bad.poll.checked_at,
        Some(checked),
        "a failure does not refresh checked_at"
    );
    let retry = bad
        .poll
        .retry_at
        .expect("an error says when it will try again");
    assert!(retry > bad.generated_at, "{retry} vs {}", bad.generated_at);
    assert!(
        rig.row("Carefeed/app", 1).is_some(),
        "the last good list stays on show"
    );

    // After the service recovers the next try succeeds and checked_at moves.
    fake.force("search", None);
    rig.run_until(mins(5), secs(5), |r| {
        r.snapshot().map(|s| s.poll.state) == Some(PollState::Ok)
    })
    .await
    .expect("recovers");
    let healed = rig.snapshot().unwrap();
    assert!(healed.poll.checked_at.unwrap() > checked);
    assert_eq!(healed.poll.retry_at, None);
}

#[tokio::test]
async fn repeated_failures_back_off_two_then_four_minutes() {
    let fake = one_pr_fake();
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    fake.force(
        "search",
        Some(Forced {
            status: 500,
            retry_after: None,
        }),
    );
    rig.run(mins(14), secs(5)).await;

    let failures: Vec<Duration> = rig
        .of_kind(Kind::Search)
        .into_iter()
        .filter(|(_, r)| r.status == 500)
        .map(|(t, _)| t)
        .collect();
    assert!(failures.len() >= 3, "{failures:?}");
    assert!(failures[1] - failures[0] >= mins(2), "{failures:?}");
    assert!(failures[2] - failures[1] >= mins(4), "{failures:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Tokens
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn with_no_token_the_feature_says_so_and_makes_no_request() {
    let mut rig = Rig::start(
        one_pr_fake(),
        RigOpts {
            relay: false,
            token: false,
        },
    )
    .await;
    rig.set_demand("visible").await;
    rig.run(mins(10), secs(10)).await;
    assert_eq!(rig.fake.log_len(), 0);
    let snap = rig
        .snapshot()
        .expect("a snapshot still says why there is nothing");
    assert_eq!(snap.token, TokenState::Missing);
    assert!(snap.prs.is_empty());
}

#[tokio::test]
async fn a_rejected_token_stops_all_requests_until_demand_changes_or_thirty_minutes_pass() {
    let fake = one_pr_fake();
    fake.force(
        "user",
        Some(Forced {
            status: 401,
            retry_after: None,
        }),
    );
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    assert_eq!(rig.snapshot().unwrap().token, TokenState::Rejected);
    let mark = rig.fake.log_len();
    assert_eq!(mark, 1, "one request, refused: {:?}", rig.requests());

    rig.run(mins(29), secs(10)).await;
    assert_eq!(rig.fake.log_len(), mark, "nothing for 29 minutes");

    // A change of demand retries at once (the token has been fixed meanwhile).
    fake.force("user", None);
    rig.set_demand("hidden").await;
    rig.run(secs(10), secs(1)).await;
    assert!(rig.fake.log_len() > mark, "retried on the demand change");
    assert_eq!(rig.snapshot().unwrap().token, TokenState::Connected);
}

#[tokio::test]
async fn a_rejected_token_is_retried_on_its_own_after_thirty_minutes() {
    let fake = one_pr_fake();
    fake.force(
        "user",
        Some(Forced {
            status: 401,
            retry_after: None,
        }),
    );
    let mut rig = Rig::start(fake.clone(), RigOpts::default()).await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    let mark = rig.fake.log_len();
    rig.run(mins(31), secs(10)).await;
    assert!(rig.fake.log_len() > mark, "tried again by itself");
}

// ═════════════════════════════════════════════════════════════════════════════
// A refresh the operator asks for
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_refresh_runs_one_full_reconcile_within_the_search_gap() {
    let mut rig = Rig::start(one_pr_fake(), RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(secs(150), secs(5)).await;

    // Control: a quiet minute of ordinary polling reads no PR's detail (the
    // one PR has no pending check, and the next full reconcile is minutes away).
    let mark = rig.fake.log_len();
    rig.run(secs(65), secs(1)).await;
    assert_eq!(
        rig.count_since(mark, Kind::Graphql),
        0,
        "{:?}",
        rig.since(mark)
    );

    // A refresh re-reads everything. Search never runs twice inside a minute in
    // any posture, so it starts at most a minute later.
    let mark = rig.fake.log_len();
    rig.refresh().await;
    rig.run(secs(65), secs(1)).await;
    assert!(
        rig.count_since(mark, Kind::Search) >= 1,
        "{:?}",
        rig.since(mark)
    );
    assert_eq!(
        rig.count_since(mark, Kind::Graphql),
        1,
        "every PR read again in one request: {:?}",
        rig.since(mark)
    );
}

#[tokio::test]
async fn a_refresh_with_nobody_looking_does_nothing() {
    let mut rig = Rig::start(one_pr_fake(), RigOpts::default()).await;
    rig.set_demand("idle").await;
    rig.refresh().await;
    rig.run(mins(2), secs(5)).await;
    assert_eq!(rig.fake.log_len(), 0);
}

// ═════════════════════════════════════════════════════════════════════════════
// Organisations hidden by SSO
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn an_organisation_sso_hid_is_named_once_and_a_failed_lookup_keeps_a_generic_label() {
    let fake = one_pr_fake();
    fake.set_sso(Some("partial-results; organizations=111,222"));
    fake.set_org(111, Some("Secret-Org"));
    fake.set_org(222, None);
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(12), secs(10)).await;

    let orgs = rig.snapshot().unwrap().hidden_orgs;
    assert_eq!(orgs.len(), 2, "{orgs:?}");
    assert!(orgs.contains(&"Secret-Org".to_string()), "{orgs:?}");
    assert!(
        orgs.iter().all(|o| !o.trim().is_empty()),
        "a lookup that failed leaves a generic label, never a blank: {orgs:?}"
    );
    let lookups: Vec<String> = rig
        .of_kind(Kind::Org)
        .into_iter()
        .map(|(_, r)| r.path)
        .collect();
    assert_eq!(
        lookups.len(),
        2,
        "each organisation is looked up once: {lookups:?}"
    );
}

#[tokio::test]
async fn at_most_five_organisation_names_are_looked_up_a_day() {
    let fake = one_pr_fake();
    fake.set_sso(Some("partial-results; organizations=1,2,3,4,5,6,7"));
    for id in 1..=7 {
        fake.set_org(id, Some(&format!("Org-{id}")));
    }
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(30), secs(10)).await;
    assert_eq!(rig.of_kind(Kind::Org).len(), 5);
    let orgs = rig.snapshot().unwrap().hidden_orgs;
    assert_eq!(orgs.len(), 7, "all seven are listed: {orgs:?}");
    assert_eq!(orgs.iter().filter(|o| o.starts_with("Org-")).count(), 5);
    assert!(orgs.iter().all(|o| !o.trim().is_empty()));
}
