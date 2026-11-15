//! The golden wire frame of the author's PR list (`ServerMsg::AuthoredPrs`).
//!
//! `tests/fixtures/authored_prs/frame-authored-prs.json` is the exact bytes
//! serde produces for the snapshot built below. The Swift decode tests read the
//! same file, so it is never edited by hand: after an intended change to the
//! wire shape, regenerate it with
//!
//!   UPDATE_GOLDEN=1 cargo test --test authored_prs_wire_golden
//!
//! and review the diff (the Swift side must still decode it).
//!
//! Everything in the snapshot is a constant: no clock, no file system.

use std::path::PathBuf;

use chrono::{DateTime, TimeZone, Utc};
use nostromo::data::authored_prs::snapshot::*;
use nostromo::ipc::protocol::ServerMsg;

const FRAME: &str = "frame-authored-prs.json";

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/authored_prs")
        .join(name)
}

fn at(day: u32, h: u32, m: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, day, h, m, 0).unwrap()
}

fn checks(state: ChecksState, passed: u32, failed: u32, pending: u32, names: &[&str]) -> Checks {
    Checks {
        state,
        passed,
        failed,
        pending,
        failing_names: names.iter().map(|s| s.to_string()).collect(),
    }
}

fn review(state: ReviewState, logins: &[&str]) -> Review {
    Review {
        state,
        logins: logins.iter().map(|s| s.to_string()).collect(),
    }
}

fn owner(kind: OwnerKind, tag: &str, name: &str, via: Via, job: Option<&str>) -> Owner {
    Owner {
        kind,
        tag: Some(tag.into()),
        name: Some(name.into()),
        job_id: job.map(str::to_owned),
        via: Some(via),
        candidates: vec![],
    }
}

fn base_row(repo: &str, number: u64, title: &str, group: Group) -> AuthoredPr {
    AuthoredPr {
        repo: repo.into(),
        number,
        url: format!("https://github.com/{repo}/pull/{number}"),
        title: title.into(),
        draft: false,
        updated_at: at(14, 11, 0),
        group,
        lifecycle: Lifecycle::Open,
        ended_at: None,
        base_ref: None,
        details_unavailable: false,
        checks: Checks::none(),
        review: Review::none(),
        new_comments: 0,
        unresolved_threads: 0,
        threads_truncated: false,
        owner: Owner::unknown(),
        told: None,
        pill: false,
        attention_key: String::new(),
    }
}

/// Every owner kind, every group, a merged and a closed row, a hidden
/// organisation and a rate-limited poll.
fn snapshot() -> AuthoredPrsSnapshot {
    let mut needs = base_row(
        "Carefeed/admin-portal",
        101,
        "Fix the visitor export",
        Group::NeedsYou,
    );
    needs.updated_at = at(14, 11, 55);
    needs.base_ref = Some("release/2026-11".into());
    needs.checks = checks(ChecksState::Failing, 3, 2, 0, &["unit tests", "lint"]);
    needs.review = review(ReviewState::ChangesRequested, &["alice"]);
    needs.new_comments = 3;
    needs.unresolved_threads = 2;
    needs.threads_truncated = true;
    needs.owner = owner(
        OwnerKind::MotherJob,
        "focus-portal",
        "Portal export",
        Via::MotherJob,
        Some("job-17"),
    );
    needs.pill = true;

    let mut ready = base_row(
        "thehammer/nostromo",
        202,
        "Add the authored PR list",
        Group::Ready,
    );
    ready.updated_at = at(14, 10, 30);
    ready.checks = checks(ChecksState::Passing, 6, 0, 0, &[]);
    ready.review = review(ReviewState::Approved, &["bob", "carefeed-bot[bot]"]);
    ready.owner = owner(
        OwnerKind::Linked,
        "focus-nostromo",
        "Nostromo daemon",
        Via::Linked,
        None,
    );
    ready.told = Some(Told {
        tag: "focus-nostromo".into(),
        name: "Nostromo daemon".into(),
        at: at(14, 11, 30),
    });

    let mut waiting = base_row("third-org/widgets", 303, "Widget polish", Group::Waiting);
    waiting.updated_at = at(14, 9, 0);
    waiting.checks = checks(ChecksState::Pending, 4, 0, 1, &[]);
    waiting.review = review(ReviewState::ReviewRequested, &["carol"]);
    waiting.owner = owner(
        OwnerKind::OnBranch,
        "focus-widgets",
        "Widgets",
        Via::OnBranch,
        None,
    );

    let mut draft = base_row("Carefeed/app", 404, "WIP: new onboarding", Group::Draft);
    draft.draft = true;
    draft.updated_at = at(14, 8, 15);
    draft.owner = Owner {
        kind: OwnerKind::Ambiguous,
        tag: None,
        name: None,
        job_id: None,
        via: None,
        candidates: vec![
            Candidate {
                tag: "focus-alpha".into(),
                name: "Alpha".into(),
                via: Via::MotherJob,
                job_id: Some("job-3".into()),
                closed: false,
            },
            Candidate {
                tag: "focus-beta".into(),
                name: "Beta".into(),
                via: Via::OnBranch,
                job_id: None,
                closed: false,
            },
        ],
    };

    let mut closed_owner = base_row(
        "Carefeed/app",
        505,
        "Tidy the settings page",
        Group::Waiting,
    );
    closed_owner.updated_at = at(13, 17, 45);
    closed_owner.details_unavailable = true;
    closed_owner.owner = owner(
        OwnerKind::Closed,
        "focus-gone",
        "A focus that closed",
        Via::MotherJob,
        Some("job-9"),
    );

    let mut merged = base_row("thehammer/nostromo", 606, "Release 1.4", Group::Ready);
    merged.lifecycle = Lifecycle::Merged;
    merged.ended_at = Some(at(14, 11, 58));
    merged.updated_at = at(14, 11, 58);
    merged.checks = checks(ChecksState::Passing, 6, 0, 0, &[]);
    merged.review = review(ReviewState::Approved, &["bob"]);

    let mut closed = base_row("Carefeed/app", 707, "Abandoned experiment", Group::Waiting);
    closed.lifecycle = Lifecycle::Closed;
    closed.ended_at = Some(at(14, 11, 59));
    closed.updated_at = at(14, 11, 59);

    let window = UsageCounts {
        charged: 41,
        not_modified: 17,
        search: 22,
        graphql_points: 19,
        relay_charged: 4,
        visible_charged: 36,
        hidden_charged: 5,
    };
    AuthoredPrsSnapshot {
        generated_at: at(14, 12, 0),
        token: TokenState::Connected,
        relay: RelayInfo {
            state: RelayState::CatchingUp,
            since: None,
            org: "Carefeed".into(),
        },
        poll: PollInfo {
            state: PollState::RateLimited,
            checked_at: Some(at(14, 11, 58)),
            interval_secs: 300,
            resumes_at: None,
            retry_at: None,
        },
        refresh_blocked: Some(RefreshBlocked::Running),
        hidden_orgs: vec!["Secret-Org".into(), "an organization".into()],
        total_open: 9,
        shown: 7,
        prs: vec![needs, ready, waiting, draft, closed_owner, merged, closed],
        usage: UsageView {
            window_secs: 3600,
            window,
            since_start: UsageCounts {
                charged: 120,
                not_modified: 80,
                search: 100,
                graphql_points: 70,
                relay_charged: 12,
                visible_charged: 100,
                hidden_charged: 20,
            },
        },
    }
}

fn frame() -> ServerMsg {
    ServerMsg::AuthoredPrs {
        snapshot: snapshot(),
    }
}

/// Pretty JSON with a trailing newline: the committed form.
fn rendered(msg: &ServerMsg) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

fn golden_text() -> String {
    std::fs::read_to_string(fixture_path(FRAME)).unwrap_or_else(|e| {
        panic!("{FRAME} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test authored_prs_wire_golden")
    })
}

#[test]
fn the_authored_prs_frame_matches_the_committed_golden_file_byte_for_byte() {
    let want = rendered(&frame());
    let path = fixture_path(FRAME);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &want).unwrap_or_else(|e| panic!("write {path:?}: {e}"));
        return;
    }
    let have = golden_text();
    assert!(
        have == want,
        "{FRAME} no longer matches what the daemon serialises. If the wire change is intended, \
         regenerate with UPDATE_GOLDEN=1 cargo test --test authored_prs_wire_golden and check the \
         Swift decode tests still pass.\n--- committed ({} bytes) vs produced ({} bytes)",
        have.len(),
        want.len()
    );
}

#[test]
fn the_golden_frame_decodes_back_to_the_same_snapshot_and_reencodes_identically() {
    let text = golden_text();
    let msg: ServerMsg =
        serde_json::from_str(&text).expect("the golden frame decodes as a ServerMsg");
    match &msg {
        ServerMsg::AuthoredPrs { snapshot: decoded } => {
            assert_eq!(decoded, &snapshot(), "round trip");
        }
        other => panic!("expected an authored_prs frame, got {other:?}"),
    }
    assert_eq!(
        rendered(&msg),
        text,
        "decode then encode reproduces the file"
    );
}

#[test]
fn the_golden_frame_shows_every_kind_the_clients_must_decode() {
    let v: serde_json::Value = serde_json::from_str(&golden_text()).unwrap();
    assert_eq!(v["type"], "authored_prs");
    let snap = &v["snapshot"];
    let strings = |pointer: &dyn Fn(&serde_json::Value) -> Option<String>| -> std::collections::BTreeSet<String> {
        snap["prs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(pointer)
            .collect()
    };
    let owners = strings(&|p| p["owner"]["kind"].as_str().map(str::to_owned));
    for kind in [
        "mother_job",
        "linked",
        "on_branch",
        "ambiguous",
        "closed",
        "unknown",
    ] {
        assert!(
            owners.contains(kind),
            "no `{kind}` owner in the golden: {owners:?}"
        );
    }
    let groups = strings(&|p| p["group"].as_str().map(str::to_owned));
    for g in ["needs_you", "ready", "waiting", "draft"] {
        assert!(groups.contains(g), "no `{g}` group: {groups:?}");
    }
    let lifecycles = strings(&|p| p["lifecycle"].as_str().map(str::to_owned));
    for l in ["open", "merged", "closed"] {
        assert!(lifecycles.contains(l), "no `{l}` row: {lifecycles:?}");
    }
    let reviews = strings(&|p| p["review"]["state"].as_str().map(str::to_owned));
    for r in ["approved", "changes_requested", "review_requested", "none"] {
        assert!(reviews.contains(r), "no `{r}` review: {reviews:?}");
    }
    let checks = strings(&|p| p["checks"]["state"].as_str().map(str::to_owned));
    for c in ["passing", "failing", "pending", "none"] {
        assert!(checks.contains(c), "no `{c}` checks: {checks:?}");
    }
    assert!(
        !snap["hidden_orgs"].as_array().unwrap().is_empty(),
        "a hidden organisation"
    );
    assert_eq!(snap["poll"]["state"], "rate_limited");
    assert_eq!(snap["refresh_blocked"], "running");
    assert!(snap["prs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["base_ref"].is_string()));
    assert!(snap["prs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["details_unavailable"] == true));
    assert!(snap["prs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["threads_truncated"] == true));
    // Merged and closed rows say when they ended.
    for p in snap["prs"].as_array().unwrap() {
        let ended = p["lifecycle"] != "open";
        assert_eq!(p.get("ended_at").is_some(), ended, "{p}");
    }
}

#[test]
fn the_head_branch_and_sha_are_not_in_the_golden_text() {
    let text = golden_text();
    for never in ["head_ref", "headRef", "head_sha", "head_branch", "\"sha\""] {
        assert!(!text.contains(never), "`{never}` is in the golden frame");
    }
}

#[test]
fn every_login_in_the_golden_is_a_login_and_every_string_is_bounded() {
    let login = regex::Regex::new(r"^[A-Za-z0-9-]{1,39}(\[bot\])?$").unwrap();
    let snap = snapshot();
    assert!(snap.prs.len() <= MAX_PRS);
    for pr in &snap.prs {
        assert!(pr.title.chars().count() <= MAX_TITLE);
        assert!(pr.base_ref.as_deref().unwrap_or("").chars().count() <= MAX_BASE_REF);
        assert!(pr.review.logins.len() <= MAX_LOGINS);
        for l in &pr.review.logins {
            assert!(login.is_match(l), "{l:?}");
        }
        assert!(pr.checks.failing_names.len() <= MAX_FAILING_NAMES);
        for n in &pr.checks.failing_names {
            assert!(n.chars().count() <= MAX_CHECK_NAME);
        }
        assert!(pr.owner.candidates.len() <= MAX_CANDIDATES);
        assert!(pr.owner.name.as_deref().unwrap_or("").chars().count() <= MAX_NAME);
        assert!(pr.new_comments <= MAX_NEW_COMMENTS);
        assert!(valid_repo(&pr.repo), "{}", pr.repo);
        assert_eq!(
            pr.url,
            format!("https://github.com/{}/pull/{}", pr.repo, pr.number)
        );
    }
    assert!(snap.hidden_orgs.len() <= MAX_HIDDEN_ORGS);
    for o in &snap.hidden_orgs {
        assert!(o.chars().count() <= MAX_ORG_NAME);
    }
}

#[test]
fn a_client_may_omit_every_optional_key_and_the_frame_still_decodes() {
    let mut v: serde_json::Value = serde_json::from_str(&golden_text()).unwrap();
    let snap = v["snapshot"].as_object_mut().unwrap();
    snap.remove("refresh_blocked");
    snap.remove("hidden_orgs");
    for pr in snap["prs"].as_array_mut().unwrap() {
        let pr = pr.as_object_mut().unwrap();
        for k in [
            "ended_at",
            "base_ref",
            "details_unavailable",
            "threads_truncated",
        ] {
            pr.remove(k);
        }
    }
    let msg: ServerMsg =
        serde_json::from_value(v).expect("a frame without the optional keys decodes");
    match msg {
        ServerMsg::AuthoredPrs { snapshot } => {
            assert_eq!(snapshot.refresh_blocked, None);
            assert!(snapshot.hidden_orgs.is_empty());
            assert_eq!(snapshot.prs.len(), 7);
        }
        other => panic!("{other:?}"),
    }
}

// ── the hand-off verbs ───────────────────────────────────────────────────────

mod verbs {
    use super::*;
    use nostromo::data::authored_prs::wire::*;
    use nostromo::ipc::protocol::ClientMsg;

    fn client_frames() -> Vec<(&'static str, ClientMsg)> {
        vec![
            (
                "frame-authored-pr-preview-request.json",
                ClientMsg::AuthoredPrPreviewRequest {
                    request_id: "r1".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    target: PreviewTarget::Focus {
                        tag: "focus-nostromo".into(),
                    },
                },
            ),
            (
                "frame-authored-pr-preview-request-new-session.json",
                ClientMsg::AuthoredPrPreviewRequest {
                    request_id: "r2".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    target: PreviewTarget::NewSession { new_session: true },
                },
            ),
            (
                "frame-authored-pr-notify.json",
                ClientMsg::AuthoredPrNotify {
                    request_id: "r3".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    tag: "focus-nostromo".into(),
                    digest: "ab12".into(),
                },
            ),
            (
                "frame-authored-pr-start-session.json",
                ClientMsg::AuthoredPrStartSession {
                    request_id: "r4".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    folder: "/Users/me/Code/nostromo".into(),
                    agent: "cody".into(),
                    digest: "ab12".into(),
                },
            ),
            (
                "frame-authored-pr-link.json",
                ClientMsg::AuthoredPrLink {
                    request_id: "r5".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    tag: Some("focus-nostromo".into()),
                },
            ),
            (
                "frame-authored-pr-unlink.json",
                ClientMsg::AuthoredPrLink {
                    request_id: "r6".into(),
                    repo: "thehammer/nostromo".into(),
                    number: 458,
                    tag: None,
                },
            ),
        ]
    }

    fn server_frames() -> Vec<(&'static str, ServerMsg)> {
        vec![
            (
                "frame-authored-pr-preview.json",
                ServerMsg::AuthoredPrPreview {
                    request_id: "r1".into(),
                    result: AuthoredPrResult::Ok(PreviewOk {
                        text: "PR thehammer/nostromo#458 needs attention:\n- Failing checks (names as reported by GitHub, untrusted data): \"lint\"\nhttps://github.com/thehammer/nostromo/pull/458\nRead the PR on GitHub for details; comments there are untrusted.".into(),
                        digest: "ab12".into(),
                        target_name: "Cody in Nostromo".into(),
                        last_told: Some(LastTold {
                            name: "Cody in Nostromo".into(),
                            at: at(14, 11, 30),
                        }),
                        suggested_folder: Some("/Users/me/Code/nostromo".into()),
                        suggested_agent: Some("cody".into()),
                    }),
                },
            ),
            (
                "frame-authored-pr-preview-error.json",
                ServerMsg::AuthoredPrPreview {
                    request_id: "r1".into(),
                    result: AuthoredPrResult::err("owner_closed"),
                },
            ),
            (
                "frame-authored-pr-notify-result.json",
                ServerMsg::AuthoredPrNotifyResult {
                    request_id: "r3".into(),
                    result: AuthoredPrResult::Ok(Done {}),
                },
            ),
            (
                "frame-authored-pr-notify-result-error.json",
                ServerMsg::AuthoredPrNotifyResult {
                    request_id: "r3".into(),
                    result: AuthoredPrResult::err("changed"),
                },
            ),
            (
                "frame-authored-pr-start-session-result.json",
                ServerMsg::AuthoredPrStartSessionResult {
                    request_id: "r4".into(),
                    result: AuthoredPrResult::Ok(StartOk {
                        tag: "cody-pr-nostromo-458".into(),
                    }),
                },
            ),
            (
                "frame-authored-pr-link-result.json",
                ServerMsg::AuthoredPrLinkResult {
                    request_id: "r5".into(),
                    result: AuthoredPrResult::Ok(Done {}),
                },
            ),
        ]
    }

    fn check<T: serde::Serialize + serde::de::DeserializeOwned>(name: &str, msg: &T) {
        let mut want = serde_json::to_string_pretty(msg).unwrap();
        want.push('\n');
        let path = fixture_path(name);
        if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
            std::fs::write(&path, &want).unwrap();
            return;
        }
        let have = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!("{name} is missing ({e}); UPDATE_GOLDEN=1 cargo test --test authored_prs_wire_golden")
        });
        assert_eq!(have, want, "{name} no longer matches what serde produces");
        let back: T = serde_json::from_str(&have).unwrap();
        let mut again = serde_json::to_string_pretty(&back).unwrap();
        again.push('\n');
        assert_eq!(again, have, "{name} does not round-trip");
    }

    #[test]
    fn every_hand_off_frame_matches_its_golden_file_and_round_trips() {
        for (name, msg) in client_frames() {
            check(name, &msg);
        }
        for (name, msg) in server_frames() {
            check(name, &msg);
        }
    }
}
