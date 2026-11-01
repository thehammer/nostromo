//! Slice S2: remote panes, the switches, archive, the new text refusals, the
//! audit fields and the foreground check.

use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::ipc::protocol::StagingArchive;
use crate::terminal::session::Foreground;
use crate::terminal::{ForegroundProbe, RealForegroundProbe};

const HAZARDS: &str = include_str!("../../../../tests/fixtures/terminal_staging/hazards.json");

fn hazards() -> Vec<Value> {
    serde_json::from_str(HAZARDS).expect("hazards.json")
}

fn set_enabled(w: &World, t: &Term, enabled: bool) {
    w.terminals
        .lock()
        .unwrap()
        .staging_set_enabled(&cap(), &t.id, enabled)
        .unwrap();
}

fn set_global(w: &World, conn: &str, enabled: bool) {
    w.terminals
        .lock()
        .unwrap()
        .staging_set_global(&cap(), conn, enabled)
        .unwrap();
}

fn stage_with_clock(w: &World, t: &Term, command: &str) -> String {
    w.advance(Duration::from_secs(13));
    w.staged_id(A, t, command)
}

// ── D8: the new text refusals ─────────────────────────────────────────────────

#[test]
fn every_hazard_in_the_shared_fixture_gets_its_code_in_remote_and_local_terminals() {
    let cases = hazards();
    assert!(cases.len() >= 25);
    for case in &cases {
        let text = case["text"].as_str().unwrap();
        for (kind, strict) in [("remote", true), ("local", false)] {
            let want = case[kind].as_str().unwrap();
            assert_eq!(
                code_of(text::validate_command_in(text, strict)),
                want,
                "{} ({kind}): {text:?}",
                case["name"]
            );
        }
        assert_eq!(
            text::uses_history_expansion(text),
            case["history"].as_bool().unwrap(),
            "{}",
            case["name"]
        );
    }
}

#[test]
fn history_expansion_is_refused_on_an_ecs_terminal_but_not_on_a_plain_local_one() {
    let mut w = World::new();
    let remote = w.ecs(A);
    w.follow(&remote, A);
    assert_eq!(
        w.refusal(A, &remote, stage_op("!!", None, None)),
        "history_expansion"
    );
    let id = w.staged_id(A, &remote, "ls");
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &remote, replace(&id, Some("sudo !!"), None)),
        "history_expansion"
    );
    let refusal = w.call(A, &remote, stage_op("!!", None, None)).unwrap_err();
    assert_eq!(
        refusal.detail.as_deref(),
        Some("history expansion runs something other than what the user reads; spell the command out")
    );
    let local = w.local(B);
    w.follow(&local, B);
    assert!(w.stage(B, &local, "!!").is_ok());
}

#[test]
fn tmux_input_is_refused_in_every_terminal() {
    let mut w = World::new();
    let local = w.local(A);
    w.follow(&local, A);
    let remote = w.ecs(B);
    w.follow(&remote, B);
    for (tag, t) in [(A, &local), (B, &remote)] {
        let refusal = w
            .call(tag, t, stage_op("tmux send-keys -t x ls", None, None))
            .unwrap_err();
        assert_eq!(refusal.code, "types_into_another_terminal");
        assert_eq!(
            refusal.detail.as_deref(),
            Some("staging never types into another pane")
        );
    }
}

// ── D2: the per-terminal switch ───────────────────────────────────────────────

#[test]
fn turning_staging_off_clears_the_list_refuses_the_follower_and_audits() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    w.frames();

    set_enabled(&w, &t, false);
    assert!(w.peek(&t).is_none());
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!((frames[0].state, frames[0].enabled), ("none", false));

    w.advance(Duration::from_secs(13));
    let refusal = w.call(A, &t, stage_op("ls", None, None)).unwrap_err();
    assert_eq!(refusal.code, "staging_disabled");
    assert_eq!(
        refusal.detail.as_deref(),
        Some("the user turned staging off for this terminal")
    );
    assert_eq!(w.refusal(A, &t, StagingOp::List), "staging_disabled");

    let audited: Vec<Value> = w
        .audit_named("staging_changed")
        .into_iter()
        .filter(|l| l["by"] == "disabled")
        .collect();
    assert_eq!(audited.len(), 1);
    assert_eq!(audited[0]["op"], "clear");
    assert_eq!(audited[0]["unused"], 1);
}

#[test]
fn turning_staging_back_on_gives_the_current_follower_a_fresh_list() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    set_enabled(&w, &t, false);
    w.frames();

    set_enabled(&w, &t, true);
    let list = w.peek(&t).expect("a fresh list");
    assert_eq!((list.owner_tag.as_str(), list.entries.len()), (A, 0));
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!((frames[0].state, frames[0].enabled), ("active", true));
    // The agent can stage again (it would be `not_following` forever otherwise).
    assert!(w.stage(A, &t, "ls").is_ok());
    assert!(w
        .audit_named("staging_changed")
        .iter()
        .any(|l| l["by"] == "enabled"));
}

#[test]
fn turning_staging_on_for_an_unfollowed_terminal_only_tells_the_app() {
    let mut w = World::new();
    let t = w.local(A);
    set_enabled(&w, &t, false);
    w.frames();
    set_enabled(&w, &t, true);
    assert!(w.peek(&t).is_none());
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!((frames[0].state, frames[0].enabled), ("none", true));
}

#[test]
fn a_new_follow_while_staging_is_off_creates_no_list_and_says_off() {
    let mut w = World::new();
    let t = w.local(A);
    set_enabled(&w, &t, false);
    w.frames();
    w.follow(&t, A);
    assert!(w.peek(&t).is_none());
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!((frames[0].state, frames[0].enabled), ("none", false));
    assert_eq!(w.refusal(A, &t, StagingOp::List), "staging_disabled");
}

#[test]
fn closing_a_terminal_forgets_its_off_switch() {
    let mut w = World::new();
    let t = w.local(A);
    set_enabled(&w, &t, false);
    assert!(w.terminals.lock().unwrap().staging().is_disabled(&t.id));
    w.terminals.lock().unwrap().staging().terminal_gone(&t.id);
    assert!(!w.terminals.lock().unwrap().staging().is_disabled(&t.id));
}

// ── D3: the global switch ─────────────────────────────────────────────────────

#[test]
fn the_last_enabled_app_turning_off_clears_every_list_and_refuses() {
    let mut w = World::new();
    let _second = w.connect_app("second", &[TERMINAL_STAGING_UI]);
    let t = w.local(A);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    w.frames();

    set_global(&w, "app", false);
    assert!(w.peek(&t).is_some(), "another app still has it on");

    set_global(&w, "second", false);
    assert!(w.peek(&t).is_none());
    let refusal = w.call(A, &t, StagingOp::List).unwrap_err();
    assert_eq!(refusal.code, "staging_disabled");
    assert_eq!(
        refusal.detail.as_deref(),
        Some("the user turned staging off")
    );
    assert!(w
        .audit_named("staging_changed")
        .iter()
        .any(|l| l["by"] == "disabled"));
}

#[test]
fn turning_the_global_switch_on_recreates_lists_for_current_followers() {
    let mut w = World::new();
    let local = w.local(A);
    let remote = w.ecs(B);
    w.follow(&local, A);
    w.follow(&remote, B);
    set_global(&w, "app", false);
    assert!(w.peek(&local).is_none() && w.peek(&remote).is_none());

    set_global(&w, "app", true);
    assert_eq!(w.peek(&local).unwrap().owner_tag, A);
    assert_eq!(w.peek(&remote).unwrap().owner_tag, B);
    assert!(w.stage(A, &local, "ls").is_ok());
}

#[test]
fn the_last_enabled_app_disconnecting_while_another_stays_off_clears_the_lists() {
    let mut w = World::new();
    let _second = w.connect_app("second", &[TERMINAL_STAGING_UI]);
    let t = w.local(A);
    w.follow(&t, A);
    set_global(&w, "app", false);
    assert!(w.peek(&t).is_some());
    w.terminals
        .lock()
        .unwrap()
        .unregister_conn(&cap(), "second");
    assert!(w.peek(&t).is_none(), "only the off app is left");
}

#[test]
fn an_app_that_never_sends_the_global_switch_is_on() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    assert!(w.stage(A, &t, "ls").is_ok());
}

// ── D9: archive ───────────────────────────────────────────────────────────────

#[test]
fn an_archived_entry_leaves_the_list_and_frees_room_for_a_thirteenth() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    let mut ids = Vec::new();
    for i in 0..MAX_ENTRIES {
        ids.push(stage_with_clock(&w, &t, &format!("echo {i}")));
    }
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &t, stage_op("echo 13", None, None)),
        "list_full"
    );

    w.report_inserted(&t, &ids[0], 6);
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &ids[0], Some(StagingArchive::Manual))
        .unwrap();
    assert!(w.stage(A, &t, "echo 13").is_ok());
    let list = w.list(A, &t).unwrap();
    assert!(list.entries.iter().all(|e| e.id != ids[0]));

    let archived: Vec<Value> = w
        .audit_named("staging_changed")
        .into_iter()
        .filter(|l| l["op"] == "archive")
        .collect();
    assert_eq!(archived.len(), 1);
    assert_eq!(
        (archived[0]["by"].as_str(), archived[0]["unused"].as_u64()),
        (Some("user"), Some(0))
    );
}

#[test]
fn an_auto_archive_is_audited_by_auto() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    let id = w.staged_id(A, &t, "ls");
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &id, Some(StagingArchive::Auto))
        .unwrap();
    assert!(w
        .audit_named("staging_changed")
        .iter()
        .any(|l| l["op"] == "archive" && l["by"] == "auto"));
}

// ── D6: audit fields and the UI-event frame ───────────────────────────────────

#[test]
fn unused_counts_what_was_removed_without_ever_being_inserted() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    let used = stage_with_clock(&w, &t, "ls");
    let unused = stage_with_clock(&w, &t, "pwd");
    w.report_inserted(&t, &used, 2);
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &used, None)
        .unwrap();
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &unused, None)
        .unwrap();
    let removed: Vec<u64> = w
        .audit_named("staging_changed")
        .into_iter()
        .filter(|l| l["op"] == "remove")
        .map(|l| l["unused"].as_u64().unwrap())
        .collect();
    assert_eq!(removed, vec![0, 1]);
    for line in w.audit_named("staging_changed") {
        if line["op"] == "stage" {
            assert_eq!(line["unused"], 0);
        }
    }
}

#[test]
fn staging_inserted_marks_only_the_first_insert() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    let id = w.staged_id(A, &t, "ls");
    w.report_inserted(&t, &id, 2);
    w.report_inserted(&t, &id, 2);
    let firsts: Vec<bool> = w
        .audit_named("staging_inserted")
        .iter()
        .map(|l| l["first"].as_bool().unwrap())
        .collect();
    assert_eq!(firsts, vec![true, false]);
}

#[test]
fn a_known_ui_event_is_audited_and_an_unknown_one_is_refused_and_writes_nothing() {
    let mut w = World::new();
    let t = w.local(A);
    for event in ["confirm_cancelled", "just_changed"] {
        w.terminals
            .lock()
            .unwrap()
            .staging_ui_event(&cap(), &t.id, event)
            .unwrap();
    }
    let lines = w.audit_named("staging_ui_event");
    let events: Vec<&str> = lines
        .iter()
        .map(|l| l["ui_event"].as_str().unwrap())
        .collect();
    assert_eq!(events, vec!["confirm_cancelled", "just_changed"]);

    let err = w
        .terminals
        .lock()
        .unwrap()
        .staging_ui_event(&cap(), &t.id, "ls -la # canary-text")
        .unwrap_err();
    assert_eq!(err.code(), "invalid_event");
    assert_eq!(
        w.audit_named("staging_ui_event").len(),
        2,
        "nothing written"
    );
    assert!(
        !w.audit_text().contains("canary-text"),
        "refusal carries the text"
    );
}

#[test]
fn ui_events_are_budgeted_per_terminal_and_event() {
    let mut w = World::new();
    let t = w.local(A);
    for _ in 0..(crate::terminal::MAX_REFUSALS_PER_WINDOW as usize + 40) {
        w.terminals
            .lock()
            .unwrap()
            .staging_ui_event(&cap(), &t.id, "just_changed")
            .unwrap();
    }
    assert_eq!(
        w.audit_named("staging_ui_event").len(),
        crate::terminal::MAX_REFUSALS_PER_WINDOW as usize
    );
}

#[test]
fn an_audit_canary_over_every_new_field_and_event_shows_no_command_text() {
    const CANARY: &str = "canary-9c1e";
    let mut w = World::new();
    let t = w.ecs(A);
    w.follow(&t, A);
    let id = w.staged_id(A, &t, &format!("echo {CANARY}"));
    w.report_inserted(&t, &id, 20);
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &id, Some(StagingArchive::Manual))
        .unwrap();
    let id = stage_with_clock(&w, &t, &format!("echo {CANARY} again"));
    w.terminals
        .lock()
        .unwrap()
        .staging_ui_event(&cap(), &t.id, "confirm_cancelled")
        .unwrap();
    let _ = w.call(A, &t, stage_op(&format!("!! {CANARY}"), None, None));
    w.terminals
        .lock()
        .unwrap()
        .staging_remove(&cap(), &t.id, &id, None)
        .unwrap();
    set_enabled(&w, &t, false);
    set_enabled(&w, &t, true);
    set_global(&w, "app", false);
    set_global(&w, "app", true);
    let audit = w.audit_text();
    assert!(!audit.contains(CANARY), "{audit}");
    assert!(!audit.contains("echo "), "{audit}");
    let allowed: BTreeSet<&str> = [
        "ts",
        "event",
        "terminal_id",
        "tag",
        "op",
        "by",
        "entries",
        "bytes",
        "unused",
        "entry_number",
        "confirmed",
        "first",
        "ui_event",
        "code",
    ]
    .into();
    for line in audit.lines() {
        let v: Value = serde_json::from_str(line).unwrap();
        let name = v["event"].as_str().unwrap();
        if name.starts_with("staging_") {
            let keys: BTreeSet<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
            assert!(keys.is_subset(&allowed), "{name}: {keys:?}");
        }
    }
}

// ── D7: foreground ────────────────────────────────────────────────────────────

struct FakeProbe {
    value: Mutex<Foreground>,
    calls: AtomicUsize,
}

impl FakeProbe {
    fn new(value: Foreground) -> Self {
        Self {
            value: Mutex::new(value),
            calls: AtomicUsize::new(0),
        }
    }
    fn set(&self, value: Foreground) {
        *self.value.lock().unwrap() = value;
    }
}

impl ForegroundProbe for FakeProbe {
    fn probe(&self, _terminal_id: &str, _session: &TerminalSession) -> Foreground {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.value.lock().unwrap().clone()
    }
}

fn tick(w: &World, probe: &dyn ForegroundProbe) {
    TerminalManager::foreground_tick(&w.terminals, probe);
}

#[test]
fn a_foreground_change_sends_exactly_one_frame_and_no_change_sends_none() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    let probe = FakeProbe::new(Foreground::Shell);
    w.frames();

    tick(&w, &probe);
    assert!(w.frames().is_empty(), "no change, no frame");

    probe.set(Foreground::Program("ssh".into()));
    tick(&w, &probe);
    tick(&w, &probe);
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].foreground.as_deref(), Some("ssh"));
    assert_eq!(frames[0].entries.len(), 1);

    probe.set(Foreground::Shell);
    tick(&w, &probe);
    let frames = w.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].foreground, None);

    probe.set(Foreground::Unknown);
    tick(&w, &probe);
    assert_eq!(w.frames()[0].foreground.as_deref(), Some("unknown program"));
}

#[test]
fn only_local_running_terminals_with_entries_are_probed() {
    let mut w = World::new();
    let local = w.local(A);
    let remote = w.ecs(B);
    w.follow(&local, A);
    w.follow(&remote, B);
    let probe = FakeProbe::new(Foreground::Shell);
    tick(&w, &probe);
    assert_eq!(
        probe.calls.load(Ordering::SeqCst),
        0,
        "empty lists are not probed"
    );
    w.staged_id(B, &remote, "ls");
    tick(&w, &probe);
    assert_eq!(probe.calls.load(Ordering::SeqCst), 0, "ECS is never probed");
    w.staged_id(A, &local, "ls");
    tick(&w, &probe);
    assert_eq!(probe.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn history_expansion_is_refused_in_a_local_terminal_while_a_program_runs() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    let probe = FakeProbe::new(Foreground::Program("ssh".into()));
    tick(&w, &probe);
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &t, stage_op("!!", None, None)),
        "history_expansion"
    );
    probe.set(Foreground::Shell);
    tick(&w, &probe);
    w.advance(Duration::from_secs(13));
    assert!(w.stage(A, &t, "!!").is_ok());
}

#[test]
fn the_foreground_program_is_never_told_to_the_agent_or_audited() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    tick(&w, &FakeProbe::new(Foreground::Program("zzprog".into())));
    assert_eq!(
        w.peek(&t).unwrap().foreground.as_deref(),
        Some("zzprog"),
        "the store holds it for the app"
    );
    let listed = w.list(A, &t).unwrap();
    let rendered = crate::mcp::tools::terminal_staging::render_list_for_tests(&t.id, &listed);
    assert!(!rendered.to_string().contains("zzprog"));
    assert!(!w.audit_text().contains("zzprog"));
}

const SHELL_CHILD: &str = ": > \"$READY\"; exec /bin/sh -i";

#[test]
fn a_real_pty_reports_sleep_as_the_foreground_and_returns_to_the_shell_after_ctrl_c() {
    let mut w = World::new();
    let t = w.local_with(A, SHELL_CHILD);
    w.follow(&t, A);
    w.staged_id(A, &t, "ls");
    w.frames();
    let input = |bytes: &[u8]| {
        w.terminals
            .lock()
            .unwrap()
            .input(&cap(), &t.id, bytes)
            .unwrap()
    };
    input(b"sleep 30\r");
    wait_for("the foreground to name sleep", || {
        tick(&w, &RealForegroundProbe);
        w.peek(&t)
            .and_then(|l| l.foreground)
            .is_some_and(|f| f.contains("sleep"))
    });
    input(b"\x03");
    wait_for("the foreground to be the shell again", || {
        tick(&w, &RealForegroundProbe);
        w.peek(&t).is_some_and(|l| l.foreground.is_none())
    });
}

#[test]
fn a_shell_that_exec_replaced_itself_reports_the_new_program() {
    let mut w = World::new();
    let t = w.local_with(A, ": > \"$READY\"; exec sleep 30");
    wait_for(
        "the program to be named",
        || matches!(t.session.foreground(), Foreground::Program(n) if n.contains("sleep")),
    );
}

// ── D5: staging is never activity (SR10) ──────────────────────────────────────

#[test]
fn an_agent_staging_every_20_seconds_for_15_minutes_does_not_keep_a_remote_shell_open() {
    let mut w = World::new();
    let t = w.ecs(A);
    w.follow(&t, A);
    let start = tokio::time::Instant::now();
    let mut warned_at = None;
    for step in 1..=45u64 {
        let secs = step * 20;
        w.advance(Duration::from_secs(20));
        let outcome = if step % 5 == 0 {
            w.call(A, &t, StagingOp::Clear)
        } else {
            w.stage(A, &t, "echo hi")
        };
        assert!(outcome.is_ok(), "step {step}: {outcome:?}");
        w.terminals
            .lock()
            .unwrap()
            .idle_tick(start + Duration::from_secs(secs));
        let warned = w
            .terminals
            .lock()
            .unwrap()
            .info(&t.id)
            .is_some_and(|i| i.idle_closes_at.is_some());
        if warned && warned_at.is_none() {
            warned_at = Some(secs);
        }
        if secs < 13 * 60 {
            assert!(!warned, "warned early at {secs}s");
        }
    }
    assert_eq!(warned_at, Some(13 * 60), "the warning comes at 13:00");
    assert!(
        w.terminals.lock().unwrap().info(&t.id).is_none(),
        "the shell closed at 15:00 though the agent kept staging"
    );
    assert!(w
        .audit_named("idle_closed")
        .iter()
        .any(|l| l["terminal_id"] == t.id.as_str()));
}

#[test]
fn a_users_insert_report_archive_switch_and_ui_event_touch_no_idle_state() {
    let mut w = World::new();
    let t = w.ecs(A);
    w.follow(&t, A);
    let start = tokio::time::Instant::now();
    let id = w.staged_id(A, &t, "ls");
    // Past the warning, then every app-side staging frame, then the tick.
    w.terminals
        .lock()
        .unwrap()
        .idle_tick(start + Duration::from_secs(13 * 60));
    assert!(w
        .terminals
        .lock()
        .unwrap()
        .info(&t.id)
        .unwrap()
        .idle_closes_at
        .is_some());
    w.report_inserted(&t, &id, 2);
    w.terminals
        .lock()
        .unwrap()
        .staging_ui_event(&cap(), &t.id, "just_changed")
        .unwrap();
    set_enabled(&w, &t, false);
    set_enabled(&w, &t, true);
    set_global(&w, "app", false);
    set_global(&w, "app", true);
    assert!(
        w.terminals
            .lock()
            .unwrap()
            .info(&t.id)
            .unwrap()
            .idle_closes_at
            .is_some(),
        "the warning stands"
    );
    assert!(w.audit_named("idle_kept_open").is_empty());
}
