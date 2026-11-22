//! `authored_prs_exclude_orgs`: PRs of an excluded owner never enter the list,
//! whichever way they would have arrived (search, a relay event, saved state),
//! the search asks GitHub to leave them out, and the owner's name is not
//! published as an SSO-hidden organisation. The real engine runs against a
//! fake GitHub on paused time (see `support/authored_prs_rig.rs`).

#[path = "support/authored_prs_rig.rs"]
mod rig;

use nostromo::data::authored_prs::verdicts::{Verdict, VerdictRecord};
use rig::*;

const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

fn excluding(orgs: &[&str]) -> RigOpts {
    RigOpts {
        exclude_orgs: orgs.iter().map(|s| s.to_string()).collect(),
        ..Default::default()
    }
}

fn two_orgs() -> Fake {
    let fake = Fake::new();
    fake.put(FakePr::new("Carefeed/app", 1).passing("build"));
    fake.put(FakePr::new("thehammer/nostromo", 2).passing("build"));
    fake
}

#[tokio::test]
async fn an_excluded_orgs_pr_from_search_never_enters_the_list_and_another_orgs_does() {
    let mut rig = Rig::start(two_orgs(), excluding(&["carefeed"])).await;
    rig.visible_and_settled().await;
    rig.run(mins(12), secs(10)).await;

    assert!(rig.row("thehammer/nostromo", 2).is_some());
    assert!(rig.row("Carefeed/app", 1).is_none());
    let snap = rig.snapshot().unwrap();
    assert_eq!(snap.prs.len(), 1);
    assert_eq!(snap.total_open, 1, "the excluded result is not counted");
    assert!(
        !serde_json::to_string(&snap)
            .unwrap()
            .to_lowercase()
            .contains("carefeed"),
        "the owner's name appears nowhere in the snapshot"
    );
    for (_, r) in rig.of_kind(Kind::Graphql) {
        assert!(
            !r.body.to_lowercase().contains("carefeed"),
            "no detail read for an excluded repo"
        );
    }
}

#[tokio::test]
async fn the_match_ignores_case_in_either_direction() {
    let fake = Fake::new();
    fake.put(FakePr::new("CAREFEED/app", 1).passing("build"));
    fake.put(FakePr::new("carefeed/other", 2).passing("build"));
    fake.put(FakePr::new("carefeed-labs/app", 3).passing("build"));
    let mut rig = Rig::start(fake, excluding(&["Carefeed"])).await;
    rig.visible_and_settled().await;

    assert!(rig.row("CAREFEED/app", 1).is_none());
    assert!(rig.row("carefeed/other", 2).is_none());
    assert!(
        rig.row("carefeed-labs/app", 3).is_some(),
        "a different owner that merely starts the same way stays"
    );
}

#[tokio::test]
async fn a_relay_event_for_an_excluded_repo_is_ignored_and_triggers_no_read() {
    let fake = two_orgs();
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            ..excluding(&["carefeed"])
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;

    // A new PR of mine in the excluded org, which a relay event would have read.
    fake.put(FakePr::new("Carefeed/app", 9).passing("build"));
    let mark = rig.fake.log_len();
    let mut opened = relay_pr_ev("pr.opened", "Carefeed/app", 9);
    opened.author = Some(ME.to_owned());
    rig.relay_event(opened).await;
    rig.relay_event(relay_pr_ev("pr.synchronize", "carefeed/app", 1))
        .await;
    rig.relay_event(ci_completed("Carefeed/app", "sha-carefeed-app-1"))
        .await;
    rig.run(secs(8), secs(1)).await;
    assert_eq!(rig.fake.log_len(), mark, "{:?}", rig.since(mark));
    assert!(rig.row("Carefeed/app", 9).is_none());

    // The same event for another org still reads.
    fake.put(FakePr::new("thehammer/nostromo", 7).passing("build"));
    let mut mine = relay_pr_ev("pr.opened", "thehammer/nostromo", 7);
    mine.author = Some(ME.to_owned());
    rig.relay_event(mine).await;
    rig.run(secs(5), secs(1)).await;
    assert!(rig.row("thehammer/nostromo", 7).is_some());
}

#[tokio::test]
async fn nothing_excluded_leaves_the_search_query_as_it_always_was() {
    let mut plain = Rig::start(two_orgs(), RigOpts::default()).await;
    plain.visible_and_settled().await;
    let searches = plain.of_kind(Kind::Search);
    assert!(!searches.is_empty());
    for (_, r) in searches {
        assert_eq!(
            r.query.as_deref(),
            Some("q=is:pr+is:open+author:@me+archived:false&sort=updated&order=desc&per_page=100")
        );
    }
}

#[tokio::test]
async fn the_search_asks_github_to_leave_each_excluded_org_out() {
    let mut rig = Rig::start(
        two_orgs(),
        excluding(&["Carefeed", "other-org", "carefeed"]),
    )
    .await;
    rig.visible_and_settled().await;
    rig.run(secs(130), secs(5)).await;
    let searches = rig.of_kind(Kind::Search);
    assert!(searches.len() >= 3);
    for (_, r) in &searches {
        assert_eq!(
            r.query.as_deref(),
            Some("q=is:pr+is:open+author:@me+archived:false+-org:carefeed+-org:other-org&sort=updated&order=desc&per_page=100")
        );
    }
    // The ETag still works: the same query is asked again with the last one.
    assert!(searches
        .iter()
        .skip(1)
        .any(|(_, r)| r.if_none_match.is_some()));
}

#[tokio::test]
async fn an_excluded_org_the_sso_hid_is_not_published() {
    let fake = two_orgs();
    fake.set_sso(Some("partial-results; organizations=111,222"));
    fake.set_org(111, Some("Carefeed"));
    fake.set_org(222, Some("Other-Org"));
    let mut rig = Rig::start(fake, excluding(&["carefeed"])).await;
    rig.visible_and_settled().await;
    for _ in 0..5 {
        rig.run(mins(12), secs(10)).await;
        let snap = rig.snapshot().unwrap();
        assert!(
            !serde_json::to_string(&snap)
                .unwrap()
                .to_lowercase()
                .contains("carefeed"),
            "{:?}",
            snap.hidden_orgs
        );
    }
    assert_eq!(rig.snapshot().unwrap().hidden_orgs, ["Other-Org"]);
    assert_eq!(
        rig.of_kind(Kind::Org).len(),
        2,
        "each id is looked up once, the excluded one included"
    );
}

#[tokio::test]
async fn without_exclusions_the_hidden_org_is_named_as_before() {
    let fake = two_orgs();
    fake.set_sso(Some("partial-results; organizations=111"));
    fake.set_org(111, Some("Carefeed"));
    let mut rig = Rig::start(fake, RigOpts::default()).await;
    rig.visible_and_settled().await;
    rig.run(mins(12), secs(10)).await;
    assert_eq!(rig.snapshot().unwrap().hidden_orgs, ["Carefeed"]);
}

#[tokio::test]
async fn saved_links_and_verdicts_of_an_excluded_repo_are_not_resurrected() {
    let mut first = Rig::start(two_orgs(), RigOpts::default()).await;
    first.visible_and_settled().await;
    assert!(first.row("Carefeed/app", 1).is_some());
    let at = t0();
    first.store.link("carefeed/app#1", "alpha", at);
    first.store.link("thehammer/nostromo#2", "beta", at);
    for (repo, n) in [("carefeed/app", 1), ("thehammer/nostromo", 2)] {
        first
            .verdicts
            .record(VerdictRecord::new(repo, n, SHA, Verdict::Approved, at, None, None).unwrap());
    }
    first.stop_engine();

    let mut again = Rig::start_again_on(
        two_orgs(),
        excluding(&["carefeed"]),
        first.state_root.clone(),
    )
    .await;
    again.visible_and_settled().await;
    again.run(secs(10), secs(1)).await;

    for file in ["authored-pr-links.json", "perri-verdicts.json"] {
        let text = std::fs::read_to_string(first.state_root.join(file)).unwrap();
        assert!(
            !text.to_lowercase().contains("carefeed"),
            "{file} still names the excluded owner"
        );
        assert!(text.contains("thehammer/nostromo"), "{file} kept the rest");
    }
    assert!(again.row("Carefeed/app", 1).is_none());
    assert!(again.store.get("carefeed/app#1").is_none());
    assert!(again.verdicts.newest("carefeed/app", 1).is_none());
    assert!(again.store.get("thehammer/nostromo#2").is_some());
    assert!(again.verdicts.newest("thehammer/nostromo", 2).is_some());
    assert!(again.row("thehammer/nostromo", 2).is_some());
}

// ── the verbs ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn no_verb_takes_an_excluded_repo_and_none_reads_or_writes_for_it() {
    let mut rig = Rig::start(two_orgs(), excluding(&["carefeed"])).await;
    rig.visible_and_settled().await;
    let mark = rig.fake.log_len();
    let a = rig.actions.clone();

    // preview, notify and start-a-session all compose from the list first.
    assert_eq!(a.compose_for("Carefeed/app", 1).err(), Some("unknown_pr"));
    assert_eq!(a.compose_for("carefeed/app", 1).err(), Some("unknown_pr"));
    // link and unlink
    assert!(!a.set_link("Carefeed/app", 1, Some("alpha")));
    assert!(rig.store.get("carefeed/app#1").is_none());
    // merge
    match rig.merge("m1", "Carefeed/app", 1, "abcdef12").await {
        nostromo::data::authored_prs::wire::AuthoredPrResult::Err(e) => {
            assert_eq!(e.code, "not_found")
        }
        _ => panic!("merged an excluded repo"),
    }
    // record_verdict, approved and not, with the repo in either case
    for verdict in [Verdict::Approved, Verdict::ChangesRequested] {
        let r = a
            .record_verdict(
                "Carefeed/app",
                1,
                &"a".repeat(40),
                verdict,
                Some("perri"),
                Some("a note"),
            )
            .await;
        assert_eq!(r, Err("pr_unknown"));
    }
    assert!(rig.verdicts.newest("carefeed/app", 1).is_none());
    assert_eq!(rig.fake.log_len(), mark, "no read: {:?}", rig.since(mark));
    let on_disk =
        std::fs::read_to_string(rig.state_root.join("perri-verdicts.json")).unwrap_or_default();
    assert!(!on_disk.to_lowercase().contains("carefeed"));

    // The same verbs still work for another owner.
    assert!(
        a.compose_for("thehammer/nostromo", 2).is_ok() || a.row("thehammer/nostromo", 2).is_some()
    );
}

// ── relay events ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn closed_and_merged_events_for_an_excluded_repo_change_and_cost_nothing() {
    let fake = two_orgs();
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            ..excluding(&["carefeed"])
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    let before = rig.snapshot().unwrap().prs.len();
    let mark = rig.fake.log_len();
    for ty in ["pr.closed", "pr.merged"] {
        let mut ev = relay_pr_ev(ty, "Carefeed/app", 1);
        ev.merged = Some(ty == "pr.merged");
        rig.relay_event(ev).await;
    }
    rig.run(secs(5), secs(1)).await;
    assert_eq!(rig.fake.log_len(), mark);
    assert_eq!(rig.snapshot().unwrap().prs.len(), before);
}

// ── the snapshot ─────────────────────────────────────────────────────────────

async fn relay_org_with(orgs: &[&str]) -> Rig {
    let mut rig = Rig::start(
        two_orgs(),
        RigOpts {
            relay: true,
            ..excluding(orgs)
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(10), secs(1)).await;
    rig
}

#[tokio::test]
async fn the_relay_org_is_published_empty_when_it_is_excluded() {
    let rig = relay_org_with(&["carefeed"]).await;
    assert_eq!(rig.snapshot().unwrap().relay.org, "");
    for (_, s) in &rig.published {
        assert_eq!(s.relay.org, "");
    }
}

#[tokio::test]
async fn the_relay_org_is_published_as_it_is_when_another_org_is_excluded() {
    let rig = relay_org_with(&["other-org"]).await;
    assert_eq!(rig.snapshot().unwrap().relay.org, "Carefeed");
}

#[tokio::test]
async fn an_sso_org_is_withheld_until_it_is_named_even_in_the_first_snapshots() {
    let fake = two_orgs();
    fake.set_sso(Some("partial-results; organizations=111,222"));
    fake.set_org(111, Some("Carefeed"));
    fake.set_org(222, Some("Other-Org"));
    let mut rig = Rig::start(fake, excluding(&["carefeed"])).await;
    rig.set_demand("visible").await;
    rig.run(mins(12), secs(10)).await;
    // Every snapshot the engine ever published, the first ones (the search has
    // reported the ids, no lookup has answered yet) included: an id that is not
    // named yet is withheld, so no generic label and no excluded name shows.
    assert!(rig.published.len() > 1);
    for (_, s) in &rig.published {
        assert!(
            s.hidden_orgs.iter().all(|o| o == "Other-Org"),
            "{:?}",
            s.hidden_orgs
        );
    }
    assert_eq!(rig.snapshot().unwrap().hidden_orgs, ["Other-Org"]);
    for (_, s) in &rig.published {
        assert!(!serde_json::to_string(s)
            .unwrap()
            .to_lowercase()
            .contains("carefeed"));
    }
}

#[tokio::test]
async fn total_open_is_what_github_said_when_it_returned_no_excluded_item() {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/a", 1).passing("build"));
    fake.put(FakePr::new("thehammer/b", 2).passing("build"));
    let mut rig = Rig::start(fake, excluding(&["carefeed"])).await;
    rig.visible_and_settled().await;
    assert_eq!(rig.snapshot().unwrap().total_open, 2);
}

// ── a repo that moved into an excluded owner ────────────────────────────────

#[tokio::test]
async fn a_pr_whose_detail_names_an_excluded_owner_is_dropped_open_or_not() {
    let fake = Fake::new();
    fake.put(FakePr::new("thehammer/moved", 1).passing("build"));
    fake.put(FakePr::new("thehammer/moved", 2).passing("build"));
    let mut rig = Rig::start(fake.clone(), excluding(&["carefeed"])).await;
    rig.visible_and_settled().await;
    assert!(rig.row("thehammer/moved", 1).is_some());
    assert!(rig.row("thehammer/moved", 2).is_some());

    // Both are transferred into the excluded owner; #2 is also closed.
    fake.edit("thehammer/moved", 1, |p| {
        p.detail_repo = Some("Carefeed/moved".into());
        p.updated_at += chrono::Duration::minutes(5);
    });
    fake.edit("thehammer/moved", 2, |p| {
        p.detail_repo = Some("Carefeed/moved".into());
        p.state = "CLOSED".into();
        p.in_search = false;
    });
    rig.refresh().await;
    rig.run(mins(3), secs(5)).await;
    assert!(rig.row("thehammer/moved", 1).is_none(), "open, transferred");
    assert!(
        rig.row("thehammer/moved", 2).is_none(),
        "closed, transferred"
    );
}

// ── logs ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn no_log_line_names_an_excluded_org_and_a_rejected_search_says_why() {
    let (log, _guard) = capture_logs();
    let fake = two_orgs();
    fake.set_sso(Some("partial-results; organizations=111"));
    fake.set_org(111, Some("Carefeed"));
    let mut rig = Rig::start(
        fake.clone(),
        RigOpts {
            relay: true,
            ..excluding(&["carefeed"])
        },
    )
    .await;
    rig.relay_up().await;
    rig.set_demand("visible").await;
    rig.run(secs(30), secs(1)).await;
    let mut opened = relay_pr_ev("pr.opened", "Carefeed/app", 9);
    opened.author = Some(ME.to_owned());
    rig.relay_event(opened).await;
    fake.force(
        "search",
        Some(Forced {
            status: 422,
            retry_after: None,
        }),
    );
    rig.run(mins(5), secs(5)).await;

    let text = log.text();
    assert!(
        text.contains("exclusion list may be too long") && text.contains("422"),
        "{text}"
    );
    assert!(!text.to_lowercase().contains("carefeed"), "{text}");
}

#[test]
fn the_daemon_builds_its_exclusions_from_the_config() {
    let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/bin/nostromd.rs"))
        .unwrap();
    assert!(
        src.contains("ExcludedOrgs::from_config(config)") && src.contains("exclude_orgs,"),
        "start_authored_prs must pass the configured exclusions to Deps"
    );
}
