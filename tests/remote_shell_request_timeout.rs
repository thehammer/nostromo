//! Terminal pane slice 2a, criterion 16: a request nobody answers times out.
//! The real wait is five minutes, so these tests run the daemon on a paused
//! tokio clock: when nothing is left to do, the clock jumps to the daemon's
//! next timer.
//!
//! A paused clock and real sockets do not mix with the usual helper timeouts
//! (the clock would jump over them), so everything here waits "patiently" (a
//! million virtual seconds) and asserts on what was sent and in what order,
//! never on when. A watchdog ends the run if the clock ever stops advancing.
//! Whether the user can answer *before* the timeout is covered, in real time,
//! in `remote_shell_request.rs`.

mod remote_shell_support;

use std::time::Duration;

use nostromo::ipc::protocol::ServerMsg;
use remote_shell_support::*;
use serde_json::json;

/// More virtual time than any wait in the daemon.
const PATIENT: Duration = Duration::from_secs(1_000_000);

fn patient(peers: &[Peer]) -> Options {
    let mut opts = Options::new(peers);
    opts.wait = PATIENT;
    opts
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_agent_request_times_out_opens_nothing_and_a_late_answer_is_ignored() {
    let _watchdog = Watchdog::arm(90);
    let mut s = Scene::start_with(patient(&[Peer::App])).await;
    let from = s.app.mark();

    // Nobody answers: the call comes back when the daemon gives up.
    let res = s.mcp.call(REQUEST, args()).await;

    assert_eq!(res["error"], "timeout", "{res}");
    assert!(res.get("terminal_id").is_none() && res.get("pane_id").is_none());
    // The user had been shown the sheet, and is told it is over.
    let confirm = s.app.wait_confirm(from).await;
    let resolved = s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "timed_out");
    assert_eq!(resolved.reason, None);
    let order: Vec<String> = s.app.remote_frames_since(from);
    assert_eq!(
        order,
        ["remote_shell_confirm_request", "remote_shell_resolved"],
        "the sheet opens once and closes once, in that order"
    );
    // Nothing was opened or launched, and the outcome is audited.
    s.d.assert_nothing_opened("a timed-out request");
    s.d.wait_audit("timed_out", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "timed_out"
    })
    .await;
    assert_eq!(
        s.d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:timed_out"]
    );

    // A click on the closed sheet is ignored: nothing launches, nothing is
    // announced, and the user is not told off.
    let after = s.app.mark();
    s.app.answer(&confirm.request_id, "connect").await;
    s.app.sync().await;
    assert_eq!(s.d.launcher().calls(), 0);
    s.d.assert_nothing_opened("a late answer");
    assert!(
        s.app.log[after..]
            .iter()
            .all(|m| matches!(m, ServerMsg::Pong)),
        "{}",
        s.app.summary()
    );

    // The slot is free: the next request is shown (and times out in its turn),
    // it is not turned away as pending.
    let from = s.app.mark();
    let res = s.mcp.call(REQUEST, args()).await;
    assert_eq!(res["error"], "timeout", "not request_pending: {res}");
    s.app.wait_confirm(from).await;
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_request_of_the_users_own_times_out_quietly() {
    let _watchdog = Watchdog::arm(90);
    let d = Daemon::start_with(patient(&[Peer::App])).await;
    d.init_focus(TAG);
    let mut app = d.app().await;
    let from = app.mark();

    app.open_remote(TAG, ["admin-portal", "production", "scheduler", "shell"])
        .await;
    let confirm = app.wait_confirm(from).await;
    let resolved = app.wait_resolved(from, &confirm.request_id).await;

    assert_eq!(confirm.requested_by.kind, "user");
    assert_eq!(resolved.outcome, "timed_out");
    d.assert_nothing_opened("a timed-out request");
    // A timeout is an outcome on the sheet, not a refusal.
    app.sync().await;
    assert!(
        app.refusals_since(from).is_empty(),
        "{:?}",
        app.refusals_since(from)
    );
    d.wait_audit("timed_out", |l| {
        l["event"] == "confirm_outcome" && l["outcome"] == "timed_out"
    })
    .await;
    assert_eq!(
        d.remote_audit_names(),
        ["remote_requested", "confirm_outcome:timed_out"]
    );
    let requested = d.remote_audit().remove(0);
    assert_eq!(requested["requested_by"], json!({"kind": "user"}));
}
