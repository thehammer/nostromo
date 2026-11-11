//! Slice S3a at the follow manager: the notices pinned byte for byte (the Mac's
//! transcript parser matches them), which of them a staging-only follower may
//! be told, the grant's integrity, and what a staging-only follow is (no hook,
//! no pump, no screen, no notice but `started` and `stopped`).
//!
//! The canary proof (every call an agent can make, every end path, a terminal
//! that prints canaries the whole time) is `src/terminal/staging/tests/s3.rs`.

use std::path::PathBuf;

use tokio::sync::mpsc;

use super::super::{
    EndReason, FollowGrant, FollowNotice, FOLLOW_ALLOW, FOLLOW_ALLOW_STAGING_ONLY, FOLLOW_DENY,
};
use super::*;
use crate::ipc::decisions::DecisionOutcome;
use crate::ipc::protocol::FollowAccess;
use crate::terminal::follow::{PauseReason, ScreenReadError};
use crate::terminal::remote_request::RemoteOutcome;
use crate::terminal::{
    OperatorConn, TERMINAL_FOLLOW_UI, TERMINAL_STAGING_ONLY_UI, TERMINAL_STAGING_UI,
};

const TID: &str = "t-1";
const PANE: &str = "local shell in /tmp/project";

// ── (2a) every notice, byte for byte ──────────────────────────────────────────

/// The wording of every notice as it was before S3a (`git show HEAD~1`), with
/// `t-1` and `local shell in /tmp/project` filled in.
fn pre_s3_wording() -> Vec<(FollowNotice, &'static str)> {
    vec![
        (
            FollowNotice::Started,
            "<nostromo-terminal-follow event=\"started\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\"/>\nYou are now following local shell in /tmp/project. Output it produces from now on will be delivered to you; you cannot type into it.",
        ),
        (
            FollowNotice::Resumed,
            "<nostromo-terminal-follow event=\"resumed\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\"/>\nFollowing local shell in /tmp/project resumed. Output it produces from now on will be delivered to you.",
        ),
        (
            FollowNotice::Paused(PauseReason::TooMuchOutput),
            "<nostromo-terminal-follow event=\"paused\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"too_much_output\"/>\nFollowing local shell in /tmp/project paused itself: too much output. Nothing more is delivered until the user resumes it.",
        ),
        (
            FollowNotice::Paused(PauseReason::TooManyDeliveries),
            "<nostromo-terminal-follow event=\"paused\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"too_many_deliveries\"/>\nFollowing local shell in /tmp/project paused itself: too many deliveries in the last hour. Nothing more is delivered until the user resumes it.",
        ),
        (
            FollowNotice::Stopped(EndReason::UserStopped),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"user_stopped\"/>\nYou are no longer following local shell in /tmp/project (the user stopped it).",
        ),
        (
            FollowNotice::Stopped(EndReason::MovedTo("agent-b".into())),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"moved_to agent-b\"/>\nYou are no longer following local shell in /tmp/project (the user invited agent-b to follow it instead).",
        ),
        (
            FollowNotice::Stopped(EndReason::PaneClosed),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"pane_closed\"/>\nYou are no longer following local shell in /tmp/project (the terminal closed).",
        ),
        (
            FollowNotice::Stopped(EndReason::TerminalRestarted),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"terminal_restarted\"/>\nYou are no longer following local shell in /tmp/project (the terminal was restarted).",
        ),
        (
            FollowNotice::Stopped(EndReason::SessionEnded),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"session_ended\"/>\nYou are no longer following local shell in /tmp/project (this session ended).",
        ),
        (
            FollowNotice::Stopped(EndReason::AppClosed),
            "<nostromo-terminal-follow event=\"stopped\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"app_closed\"/>\nYou are no longer following local shell in /tmp/project (the Nostromo app closed).",
        ),
        (
            FollowNotice::StagedInserted(3),
            "<nostromo-terminal-follow event=\"staged_inserted\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"entry_3\"/>\nThe user placed staged entry 3 at the prompt of local shell in /tmp/project. Only the user's Enter runs it; any output arrives as usual.",
        ),
    ]
}

/// The staging-only started notice, as the plan words it.
const STARTED_STAGING_ONLY: &str = "<nostromo-terminal-follow event=\"started\" terminal_id=\"t-1\" pane=\"local shell in /tmp/project\" reason=\"staging_only\"/>\nYou may now stage commands for local shell in /tmp/project with nostromo.terminal_staging. You will not receive its output or read its screen, and you are not told when the user places an entry (call list). You cannot type into it.";

#[test]
fn every_notice_that_existed_before_staging_only_keeps_its_exact_bytes() {
    for (notice, want) in pre_s3_wording() {
        assert_eq!(notice.render(TID, PANE), want, "{notice:?}");
    }
}

#[test]
fn the_staging_only_started_notice_has_its_exact_bytes() {
    assert_eq!(
        FollowNotice::StartedStagingOnly.render(TID, PANE),
        STARTED_STAGING_ONLY
    );
}

/// `tests/fixtures/terminal_staging/<name>`: compared, or written with `UPDATE_GOLDEN=1`.
fn check_golden(name: &str, rendered: &str) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/terminal_staging")
        .join(name);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::write(&path, rendered).unwrap_or_else(|e| panic!("write {path:?}: {e}"));
        return;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{path:?} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --lib terminal::follow")
    });
    assert!(
        have == rendered,
        "{name} drifted; if intended, regenerate with UPDATE_GOLDEN=1 and review the diff\n--- file\n{have}\n--- rendered\n{rendered}"
    );
}

#[test]
fn the_staging_only_started_notice_matches_its_golden_file() {
    let rendered = FollowNotice::StartedStagingOnly.render(TID, PANE);
    check_golden("notice-started-staging-only.txt", &rendered);
    assert_eq!(rendered, STARTED_STAGING_ONLY);
}

#[test]
fn the_staging_only_started_notice_parses_as_one_started_notice_with_its_reason() {
    match crate::ipc::stream_json::parse_terminal_origin(STARTED_STAGING_ONLY) {
        Some(crate::ipc::stream_json::TurnOrigin::TerminalFollowNotice { items }) => {
            assert_eq!(items.len(), 1, "{items:?}");
            assert_eq!(items[0].event, "started");
            assert_eq!(items[0].terminal_id, TID);
        }
        other => panic!("one follow notice expected, got {other:?}"),
    }
}

#[test]
fn only_started_staging_only_and_stopped_may_reach_a_staging_only_follower() {
    let mut every: Vec<FollowNotice> = pre_s3_wording().into_iter().map(|(n, _)| n).collect();
    every.push(FollowNotice::StartedStagingOnly);
    for notice in &every {
        let want = matches!(
            notice,
            FollowNotice::StartedStagingOnly | FollowNotice::Stopped(_)
        );
        assert_eq!(notice.reaches_staging_only(), want, "{notice:?}");
    }
    // Every end reason is a `Stopped` the follower may be told.
    assert_eq!(
        every
            .iter()
            .filter(|n| matches!(n, FollowNotice::Stopped(_)))
            .count(),
        6
    );
}

// ── (2d) the grant ────────────────────────────────────────────────────────────

#[test]
fn allow_grants_only_a_full_follow_and_allow_staging_only_only_a_staging_only_one() {
    let answered = |c: &str| DecisionOutcome::Answered(c.to_string());

    let full = FollowGrant::from_decision(&answered(FOLLOW_ALLOW), FollowAccess::Full)
        .expect("allow on a full request");
    assert_eq!(full.access, FollowAccess::Full);
    assert_eq!(full.via, FollowVia::Request);

    let only = FollowGrant::from_decision(
        &answered(FOLLOW_ALLOW_STAGING_ONLY),
        FollowAccess::StagingOnly,
    )
    .expect("allow_staging_only on a staging-only request");
    assert_eq!(only.access, FollowAccess::StagingOnly);
    assert_eq!(only.via, FollowVia::Request);

    // Crossed answers grant nothing.
    assert!(FollowGrant::from_decision(&answered("allow"), FollowAccess::StagingOnly).is_none());
    assert!(
        FollowGrant::from_decision(&answered("allow_staging_only"), FollowAccess::Full).is_none()
    );
    for access in [FollowAccess::Full, FollowAccess::StagingOnly] {
        for outcome in [
            answered(FOLLOW_DENY),
            answered("Allow"),
            answered(""),
            DecisionOutcome::Dismissed,
            DecisionOutcome::TimedOut,
            DecisionOutcome::Cancelled,
        ] {
            assert!(
                FollowGrant::from_decision(&outcome, access).is_none(),
                "{outcome:?} granted {access:?}"
            );
        }
    }
    assert_eq!(FOLLOW_ALLOW, "allow");
    assert_eq!(FOLLOW_ALLOW_STAGING_ONLY, "allow_staging_only");
    assert_eq!(FOLLOW_DENY, "deny");
}

#[test]
fn the_remote_sheets_follow_box_grants_a_full_follow_and_nothing_else_grants_one() {
    let grant = FollowGrant::from_remote_answer(&RemoteOutcome::Connect {
        invite_follow: true,
    })
    .expect("Connect with the box ticked");
    assert_eq!(grant.access, FollowAccess::Full);
    assert_eq!(grant.via, FollowVia::Sheet);
    for outcome in [
        RemoteOutcome::Connect {
            invite_follow: false,
        },
        RemoteOutcome::Cancelled,
        RemoteOutcome::Dismissed,
        RemoteOutcome::TimedOut,
        RemoteOutcome::OperatorGone,
        RemoteOutcome::Superseded,
    ] {
        assert!(
            FollowGrant::from_remote_answer(&outcome).is_none(),
            "{outcome:?}"
        );
    }
}

// ── (2d) what a staging-only follow is ────────────────────────────────────────

fn invite_staging_only(w: &World, t: &Term, tag: &str) {
    w.follow
        .invite_staging_only(&cap(), &t.id, tag)
        .expect("the staging-only invite is accepted");
}

/// An operator connection declaring `caps`; the receiver of its targeted frames.
fn connect(w: &World, key: &str, caps: &[&str]) -> mpsc::UnboundedReceiver<ServerMsg> {
    let (targeted, rx) = mpsc::unbounded_channel();
    let (stream, stream_rx) = mpsc::channel(16);
    std::mem::forget(stream_rx);
    w.terminals.lock().unwrap().register_conn(
        &cap(),
        key,
        OperatorConn {
            stream,
            capabilities: caps.iter().map(|c| c.to_string()).collect(),
            targeted,
            staging_enabled: true,
        },
    );
    rx
}

#[tokio::test(start_paused = true)]
async fn a_staging_only_follower_is_reported_as_such_never_paused() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    invite_staging_only(&w, &t, A);

    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
    assert_eq!(w.follow.access_of(B, &t.id), None);
    assert!(w.follow.is_follower(A, &t.id));
    let want = TerminalFollower {
        tag: A.into(),
        paused: false,
        pause_reason: None,
        mode: FollowAccess::StagingOnly,
    };
    assert_eq!(w.follower(&t), Some(want.clone()));
    assert_eq!(user_id_of(&w.info(&t)), Some(want.clone()));
    // A flood of output cannot pause what has no output.
    w.run(&t, "seq 1 8000");
    advance_ms(5_000).await;
    assert_eq!(w.follower(&t), Some(want));
}

#[tokio::test(start_paused = true)]
async fn resuming_a_staging_only_follow_is_not_paused_and_tells_no_one() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    invite_staging_only(&w, &t, A);
    let mark = w.rec.mark();

    assert_eq!(w.follow.resume(&cap(), &t.id), Err(FollowError::NotPaused));
    assert_eq!(w.rec.texts_for(A, mark), Vec::<String>::new());
    assert!(w.audit_named("follow_resumed").is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_staging_only_follower_cannot_read_the_screen_or_snapshot_it() {
    let mut w = World::new();
    let t = w.local("focus-1", "printf 'ON-SCREEN-ZQ7\\n'");
    invite_staging_only(&w, &t, A);

    assert_eq!(
        w.follow.read_screen_as(A, &t.id),
        Err(ScreenReadError::NotFollowing)
    );
    assert_eq!(w.follow.screen_snapshot_redacted(&t.id), None);
    assert!(w.audit_named("screen_read").is_empty());
    assert!(!w.audit_text().contains("ON-SCREEN-ZQ7"));
}

#[tokio::test(start_paused = true)]
async fn a_staging_only_invite_adds_no_screen_hook_and_says_only_started_with_its_reason() {
    let mut w = World::new();
    let t = w.local("focus-1", "printf 'ALREADY-ON-SCREEN\\n'");
    let hooks = t.session.screen_hook_count();
    let mark = w.rec.mark();

    invite_staging_only(&w, &t, A);

    assert_eq!(t.session.screen_hook_count(), hooks, "no hook was added");
    let pane = format!("local shell in {}", w.cwd.display());
    let told = w.rec.texts_for(A, mark);
    assert_eq!(
        told,
        vec![FollowNotice::StartedStagingOnly.render(&t.id, &pane)],
        "exactly the staging-only started notice"
    );
    let events = w.rec.events();
    assert!(
        matches!(events.last(), Some(Ev::Inject { key, .. }) if key == &t.id),
        "keyed by the terminal id: {events:?}"
    );
    // Output keeps coming; nothing more is said.
    let mark = w.rec.mark();
    for i in 0..5 {
        w.run_and_settle(&t, &format!("printf 'LINE-{i}\\n'")).await;
    }
    advance_ms(30_000).await;
    assert_eq!(w.rec.texts_for(A, mark), Vec::<String>::new());
    assert!(w.audit_named("delivery").is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_staging_only_follow_ends_with_a_stopped_notice_like_any_other() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    invite_staging_only(&w, &t, A);
    let mark = w.rec.mark();

    w.follow.stop(&cap(), &t.id).unwrap();

    assert_ended_with_notice(&w, &t, mark, "user_stopped");
    assert_eq!(w.rec.texts_for(A, mark).len(), 1);
}

#[tokio::test(start_paused = true)]
async fn an_entry_placed_while_following_for_staging_only_is_never_told_but_is_counted_pushed_and_audited(
) {
    let mut w = World::new();
    let mut frames = connect(&w, "app", &[TERMINAL_STAGING_UI, TERMINAL_FOLLOW_UI]);
    let t = w.local("focus-1", "");
    invite_staging_only(&w, &t, A);
    let store = w.terminals.lock().unwrap().staging();
    let (id, ..) = store.stage(A, &t.id, "Cody", "ls -la", None, None).unwrap();
    while frames.try_recv().is_ok() {}
    let mark = w.rec.mark();

    w.terminals
        .lock()
        .unwrap()
        .staging_inserted(&cap(), &t.id, &id, 6, false)
        .unwrap();
    // Output that a full follow would deliver, with the notice ahead of it.
    for i in 0..3 {
        w.run_and_settle(&t, &format!("printf 'AFTER-{i}\\n'"))
            .await;
    }
    advance_ms(30_000).await;

    assert_eq!(
        w.rec.texts_for(A, mark),
        Vec::<String>::new(),
        "a staging-only follower is told nothing of the insert"
    );
    let list = store.list(A, &t.id, "Cody").unwrap();
    assert_eq!(list.entries[0].inserted_count, 1);
    assert!(list.entries[0].last_inserted_at.is_some());
    let pushed: Vec<ServerMsg> = std::iter::from_fn(|| frames.try_recv().ok()).collect();
    assert!(
        pushed.iter().any(|m| matches!(
            m,
            ServerMsg::TerminalStagingList { entries, staging_only: true, .. }
                if entries.first().is_some_and(|e| e.inserted_count == 1)
        )),
        "the app is sent the counted list: {pushed:?}"
    );
    let audited = w.audit_named("staging_inserted");
    assert_eq!(audited.len(), 1);
    assert_eq!(audited[0]["entry_number"], 1);
    // A stop now says only `stopped`.
    w.follow.stop(&cap(), &t.id).unwrap();
    let told = w.rec.texts_for(A, mark);
    assert_eq!(told.len(), 1, "{told:?}");
    assert!(notice_element(&told[0], "stopped").is_some());
    assert!(!told[0].contains("staged_inserted"));
}

#[tokio::test(start_paused = true)]
async fn a_mode_change_for_the_same_focus_ends_the_old_follow_and_starts_an_empty_list() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    let pane = format!("local shell in {}", w.cwd.display());
    let base = t.session.screen_hook_count();
    w.invite(&t, A, false);
    assert_eq!(t.session.screen_hook_count(), base + 1);
    let store = w.terminals.lock().unwrap().staging();
    store.stage(A, &t.id, "Cody", "ls", None, None).unwrap();
    w.run_and_settle(&t, "printf 'FULL-ERA\\n'").await;
    assert_eq!(w.rec.deliveries_for(A, 0).len(), 1);

    // Full to staging only.
    let mark = w.rec.mark();
    invite_staging_only(&w, &t, A);
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
    assert!(
        store.list(A, &t.id, "Cody").unwrap().entries.is_empty(),
        "a new follow starts with an empty list"
    );
    assert!(store.peek(&t.id).unwrap().staging_only);
    w.run_and_settle(&t, "printf 'STAGING-ERA\\n'").await;
    // The old hook lets go at the first chunk after it was stopped.
    wait_for("the full follow's hook to be dropped", || {
        t.session.screen_hook_count() == base
    });
    advance_ms(30_000).await;
    assert_eq!(
        w.rec.texts_for(A, mark),
        vec![FollowNotice::StartedStagingOnly.render(&t.id, &pane)],
        "nothing of the full follow's pump is delivered after the change"
    );

    // Staging only to full: a fresh full follow, its list empty again.
    store.stage(A, &t.id, "Cody", "pwd", None, None).unwrap();
    let mark = w.rec.mark();
    w.invite(&t, A, false);
    assert_eq!(w.follow.access_of(A, &t.id), Some(FollowAccess::Full));
    assert!(store.list(A, &t.id, "Cody").unwrap().entries.is_empty());
    assert!(!store.peek(&t.id).unwrap().staging_only);
    let started = w.rec.notices_for(A, "started", mark);
    assert_eq!(started.len(), 1);
    assert_eq!(
        attr(notice_element(&started[0], "started").unwrap(), "reason"),
        None
    );
    w.run_and_settle(&t, "printf 'FULL-AGAIN\\n'").await;
    let delivered = w.rec.deliveries_for(A, mark);
    assert_eq!(delivered.len(), 1, "{delivered:?}");
    assert!(delivered[0].contains("FULL-AGAIN"));
    assert!(!delivered[0].contains("STAGING-ERA"));
}

#[tokio::test(start_paused = true)]
async fn the_invite_audit_line_says_which_mode() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    w.invite(&t, A, false);
    invite_staging_only(&w, &t, B);
    w.follow
        .invite(&cap(), &t.id, A, true, FollowVia::Sheet)
        .unwrap();

    let invited = w.audit_named("follow_invited");
    let modes: Vec<&str> = invited
        .iter()
        .map(|l| l["mode"].as_str().unwrap())
        .collect();
    assert_eq!(modes, ["full", "staging_only", "full"]);
    assert_eq!(invited[1]["follower"], B);
    assert_eq!(invited[1]["include_screen"], false);
    assert_eq!(invited[1]["via"], "control");
    assert_eq!(invited[2]["include_screen"], true);
}

#[tokio::test(start_paused = true)]
async fn a_granted_staging_only_follow_needs_an_app_that_declared_staging_only() {
    let mut w = World::new();
    let t = w.local("focus-1", "");
    let grant = || {
        FollowGrant::from_decision(
            &DecisionOutcome::Answered(FOLLOW_ALLOW_STAGING_ONLY.into()),
            FollowAccess::StagingOnly,
        )
        .unwrap()
    };

    // An app that can follow and stage, but not show staging only.
    let _old = connect(&w, "old", &[TERMINAL_FOLLOW_UI, TERMINAL_STAGING_UI]);
    assert_eq!(
        w.follow.invite_granted(grant(), &t.id, A),
        Err(FollowError::NoOperator)
    );
    assert_eq!(w.follower(&t), None);
    assert_eq!(w.rec.events(), vec![], "the follower was told nothing");
    assert!(w.audit_named("follow_invited").is_empty());

    let _new = connect(
        &w,
        "new",
        &[
            TERMINAL_FOLLOW_UI,
            TERMINAL_STAGING_UI,
            TERMINAL_STAGING_ONLY_UI,
        ],
    );
    w.follow.invite_granted(grant(), &t.id, A).expect("granted");
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
    let invited = w.audit_named("follow_invited");
    assert_eq!(invited.len(), 1);
    assert_eq!(invited[0]["via"], "request");
    assert_eq!(invited[0]["mode"], "staging_only");
    let started = w.rec.notices_for(A, "started", 0);
    assert_eq!(started.len(), 1);
    assert_eq!(
        attr(notice_element(&started[0], "started").unwrap(), "reason").as_deref(),
        Some("staging_only")
    );
}
