//! Slice S3a: staging only, no output.
//!
//! What this pins, against a real terminal manager, follow manager and PTY
//! children:
//!
//! * the canary proof: a terminal (local, and remote through the launcher's
//!   seam) prints numbered lines, a window title, a full-screen program's
//!   screen and a secret the whole time; its staging-only follower drives every
//!   staging op with every fixture, every terminal tool and every follow verb,
//!   and every end path is taken in turn. Nothing injected into it or returned
//!   to it carries a canary, an output element, a redaction marker or the
//!   advisory line; it is told only `started` (staging only) and `stopped`; no
//!   hook is added; no delivery or screen read names it; no audit, tracing or
//!   client frame carries a canary. Upgraded to a full follow, the canary
//!   arrives: the harness can see a leak;
//! * staging-rule parity: every fixture text gets the same code in both
//!   modes, except `history_expansion`, which a staging-only follow always
//!   enforces; `foreground` is never in a staging result;
//! * the screen read refused (and audited, and free of read budget);
//! * `request_follow`: the staging-only sheet, the upgrade, staging off, the
//!   capabilities an app must declare, the limits shared by both modes;
//! * who is held, and who is marked, sensitive.
//!
//! Waits are conditions with a generous deadline, never a sleep then an assert.

use std::time::{Duration, Instant};

use serde_json::json;
use tokio::task::JoinHandle;

use super::*;
use crate::ipc::decisions::{AnswerOutcome, DecisionOutcome, DecisionRegistry};
use crate::mcp::tools::{remote_shell, terminal, terminal_follow};
use crate::terminal::agent_api::{
    AgentFollowRequest, FollowRefusal, FollowRequestResult, ScreenReadRefused,
    MAX_READS_PER_WINDOW, READ_SCREEN_TOOL,
};
use crate::terminal::ecs::EcsPaths;
use crate::terminal::follow::manager::{FollowGrant, ADVISORY};
use crate::terminal::follow::SELECTION_ADVISORY;
use crate::terminal::TERMINAL_STAGING_ONLY_UI;

const HAZARDS: &str = include_str!("../../../../tests/fixtures/terminal_staging/hazards.json");

/// An app that can show a staging-only follow and grant one.
const ALL_CAPS: [&str; 3] = [
    TERMINAL_STAGING_UI,
    TERMINAL_FOLLOW_UI,
    TERMINAL_STAGING_ONLY_UI,
];

/// Longer than `REAL_WAIT`: a full follow's first delivery of sustained output
/// comes about ten seconds in.
const LONG_WAIT: Duration = Duration::from_secs(90);

/// Past any follow-request cooldown (at most 15 minutes) and window (10).
const PAST_COOLDOWN: Duration = Duration::from_secs(16 * 60);

fn hazards() -> Vec<Value> {
    serde_json::from_str(HAZARDS).expect("hazards.json")
}

fn wait_long(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + LONG_WAIT;
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

impl World {
    /// With an app that declared every capability staging only needs.
    fn all_caps() -> Self {
        Self::build(&ALL_CAPS, None)
    }

    fn sensitive(&self) -> crate::ipc::peer::SensitiveTags {
        self.terminals.lock().unwrap().sensitive_tags()
    }

    /// Everything injected into `tag`'s session, from the `from`th injection on.
    fn told(&self, tag: &str, from: usize) -> Vec<String> {
        self.rec
            .injected
            .lock()
            .unwrap()
            .iter()
            .skip(from)
            .filter(|(t, _)| t == tag)
            .map(|(_, text)| text.clone())
            .collect()
    }

    fn injected_count(&self) -> usize {
        self.rec.injected.lock().unwrap().len()
    }
}

// ── a decision registry and an app that answers ───────────────────────────────

/// A decision registry with the verified app registered, the broadcast its
/// sheets go out on, and a runtime for the requests that wait on them.
struct Asker {
    rt: tokio::runtime::Runtime,
    decisions: Arc<Mutex<DecisionRegistry>>,
    tx: broadcast::Sender<ServerMsg>,
    sheets: broadcast::Receiver<ServerMsg>,
}

struct Sheet {
    request_id: String,
    prompt: String,
    choices: Vec<String>,
}

impl Asker {
    fn new() -> Self {
        Self::with_runtime(
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap(),
        )
    }

    fn with_runtime(rt: tokio::runtime::Runtime) -> Self {
        let mut decisions = DecisionRegistry::new();
        decisions.add_operator("app");
        let (tx, sheets) = broadcast::channel(1024);
        Self {
            rt,
            decisions: Arc::new(Mutex::new(decisions)),
            tx,
            sheets,
        }
    }

    /// Start `tag`'s request to follow `terminal_id` with `access`.
    fn start(
        &self,
        w: &World,
        tag: &str,
        terminal_id: &str,
        access: FollowAccess,
    ) -> JoinHandle<FollowRequestResult> {
        let api = w.api.clone();
        let decisions = Arc::clone(&self.decisions);
        let tx = self.tx.clone();
        let request = AgentFollowRequest {
            tag: tag.to_string(),
            agent: Some("Cody".into()),
            terminal_id: terminal_id.to_string(),
            reason: Some("to help".into()),
            timeout: Duration::from_secs(600),
            access,
        };
        self.rt
            .spawn(async move { api.request_follow(request, &decisions, &tx).await })
    }

    /// The sheet `tag`'s request was shown, once it is; `None` when the
    /// request ended without one.
    fn sheet<T>(&mut self, tag: &str, handle: &JoinHandle<T>) -> Option<Sheet> {
        let decisions = Arc::clone(&self.decisions);
        wait_for("the request to be asked or to end", || {
            handle.is_finished() || decisions.lock().unwrap().active_request_id(tag).is_some()
        });
        let id = decisions.lock().unwrap().active_request_id(tag)?;
        let deadline = Instant::now() + REAL_WAIT;
        loop {
            match self.sheets.try_recv() {
                Ok(ServerMsg::DecisionRequest {
                    request_id,
                    prompt,
                    choices,
                    ..
                }) if request_id == id => {
                    return Some(Sheet {
                        request_id,
                        prompt,
                        choices: choices.into_iter().map(|c| c.id).collect(),
                    })
                }
                Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_)) => {}
                Err(_) => {
                    assert!(Instant::now() < deadline, "sheet {id} was never broadcast");
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
        }
    }

    fn answer(&self, sheet: &Sheet, choice: &str) -> AnswerOutcome {
        self.decisions
            .lock()
            .unwrap()
            .answer(&sheet.request_id, Some(choice.to_string()))
    }

    fn finish<T: Send + 'static>(&self, handle: JoinHandle<T>) -> T {
        self.rt.block_on(handle).expect("the request task")
    }

    /// Ask; a sheet, if one is shown, is answered `choice`.
    fn ask(
        &mut self,
        w: &World,
        tag: &str,
        terminal_id: &str,
        access: FollowAccess,
        choice: &str,
    ) -> (FollowRequestResult, Option<Sheet>) {
        let handle = self.start(w, tag, terminal_id, access);
        let sheet = self.sheet(tag, &handle);
        if let Some(sheet) = &sheet {
            assert!(
                matches!(self.answer(sheet, choice), AnswerOutcome::Answered { .. }),
                "{choice} was not accepted on a sheet offering {:?}",
                sheet.choices
            );
        }
        (self.finish(handle), sheet)
    }
}

/// The MCP surface over `w`'s API, with `asker`'s registry and broadcast.
fn mcp_state(w: &World, asker: &Asker) -> McpSharedState {
    let panes = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        w.dir.path().join("s3-panes.json"),
    )));
    for tag in [A, B] {
        panes.lock().unwrap().get_or_init(tag);
    }
    let sessions = Arc::new(Mutex::new(SessionManager::with_store_path(
        w.dir.path().join("s3-sessions.json"),
    )));
    McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: panes,
        session_mgr: sessions,
        broadcast_tx: asker.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions: Arc::clone(&asker.decisions),
        tickets: TicketRegistryState::default(),
        tracker: Default::default(),
        terminals: w.api.clone(),
    })
}

fn local_pane(w: &World) -> String {
    format!("local shell in {}", w.dir.path().display())
}

// ── the screen read ───────────────────────────────────────────────────────────

#[test]
fn a_staging_only_follower_reading_the_screen_is_refused_audited_and_spends_no_read_budget() {
    let mut w = World::new();
    let t = w.local(A);
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    let asker = Asker::new();
    let mcp = mcp_state(&w, &asker);

    // Far past the per-window cap, with no time passing: a counted read would
    // be refused `read_too_soon` from the second on.
    for _ in 0..MAX_READS_PER_WINDOW + 5 {
        assert_eq!(
            w.api.read_screen_if_following(A, &t.id),
            Err(ScreenReadRefused::StagingOnly)
        );
    }
    assert_eq!(
        ScreenReadRefused::StagingOnly.code(),
        "terminal_read_forbidden"
    );
    let answer = asker.rt.block_on(terminal_follow::read_screen(
        &mcp,
        Some(&json!({ "terminal_id": t.id })),
        Some(A),
    ));
    assert_eq!(
        answer,
        json!({
            "error": "terminal_read_forbidden",
            "detail": "staging only: you may stage for this terminal but not read it",
        })
    );
    let refused: Vec<Value> = w
        .audit_named("refused")
        .into_iter()
        .filter(|l| l["op"] == "read" && l["code"] == "terminal_read_forbidden")
        .collect();
    assert!(!refused.is_empty(), "the refusal is audited");
    assert!(refused.iter().all(|l| l["tool"] == READ_SCREEN_TOOL));
    assert!(w.audit_named("screen_read").is_empty());

    // Followed in full, its first read is not too soon: nothing was counted.
    w.follow_as(&t, A, FollowAccess::Full);
    assert!(w.api.read_screen_if_following(A, &t.id).is_ok());
}

// ── staging-rule parity (S3A-10) ──────────────────────────────────────────────

/// What staging `text` as A gives through the API: its refusal code, or `ok`
/// (and the entry is removed again).
fn stage_code(w: &World, t: &Term, text: &str) -> String {
    w.advance(Duration::from_secs(13));
    match w.stage(A, t, text) {
        Ok(StagingOutcome::Staged { entry_id, .. }) => {
            w.advance(Duration::from_secs(13));
            w.call(A, t, remove(&entry_id)).expect("remove");
            "ok".to_string()
        }
        Ok(other) => panic!("{other:?}"),
        Err(refusal) => refusal.code.to_string(),
    }
}

#[test]
fn every_fixture_text_gets_the_same_code_in_both_modes_but_history_expansion_which_staging_only_always_refuses(
) {
    let hazards = hazards();
    let commands = commands();
    let hostile = hostile();
    let mut wrong = Vec::new();
    for ecs in [false, true] {
        for access in ACCESSES {
            let mut w = World::new();
            let t = if ecs { w.ecs(A) } else { w.local(A) };
            w.follow_as(&t, A, access);
            let strict = ecs || access == FollowAccess::StagingOnly;
            let mut check = |name: &str, text: &str, want: &str| {
                let got = stage_code(&w, &t, text);
                if got != want {
                    wrong.push(format!(
                        "{access:?} ecs={ecs} {name}: {text:?}: want {want}, got {got}"
                    ));
                }
            };
            for command in &commands {
                check("commands.json", command, "ok");
            }
            for case in &hostile {
                check(&case.name, &case.text, &case.code);
            }
            for case in &hazards {
                let want = case[if strict { "remote" } else { "local" }]
                    .as_str()
                    .unwrap();
                check(
                    case["name"].as_str().unwrap(),
                    case["text"].as_str().unwrap(),
                    want,
                );
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} disagree:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

#[test]
fn a_plain_local_shell_at_a_prompt_refuses_bang_bang_from_a_staging_only_follower_and_accepts_it_from_a_full_one(
) {
    let mut w = World::new();
    let t = w.local(A);
    let mcp = Mcp::new(&w, &[A]);
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    assert!(w.peek(&t).unwrap().foreground.is_none(), "at a prompt");
    assert_eq!(
        w.refusal(A, &t, stage_op("!!", None, None)),
        "history_expansion"
    );
    let id = stage_with_clock(&w, &t, "ls");
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &t, replace(&id, Some("sudo !!"), None)),
        "history_expansion"
    );
    w.advance(Duration::from_secs(13));
    let answer = mcp.call(
        A,
        json!({"op": "stage", "terminal_id": t.id, "command": "!!"}),
    );
    assert_eq!(answer["error"], "history_expansion", "{answer}");

    // The same terminal, the same focus, followed in full.
    w.follow_as(&t, A, FollowAccess::Full);
    w.advance(Duration::from_secs(13));
    assert!(w.stage(A, &t, "!!").is_ok());
    // And back again.
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &t, stage_op("!!", None, None)),
        "history_expansion"
    );
}

fn stage_with_clock(w: &World, t: &Term, command: &str) -> String {
    w.advance(Duration::from_secs(13));
    w.staged_id(A, t, command)
}

#[test]
fn the_foreground_program_is_never_in_any_staging_result_in_either_mode() {
    for access in ACCESSES {
        let mut w = World::new();
        let t = w.local(A);
        w.follow_as(&t, A, access);
        let mcp = Mcp::new(&w, &[A]);
        let id = stage_with_clock(&w, &t, "ls");
        w.store().set_foreground(&t.id, Some("zzprog".into()));
        assert_eq!(
            w.peek(&t).unwrap().foreground.as_deref(),
            Some("zzprog"),
            "the store holds it for the app"
        );

        let mut seen = Vec::new();
        let listed = w.list(A, &t).unwrap();
        seen.push(crate::mcp::tools::terminal_staging::render_list_for_tests(
            &t.id, &listed,
        ));
        for args in [
            json!({"op": "list", "terminal_id": t.id}),
            json!({"op": "stage", "terminal_id": t.id, "command": "pwd"}),
            json!({"op": "stage", "terminal_id": t.id, "command": "!!"}),
            json!({"op": "replace", "terminal_id": t.id, "entry_id": id, "command": "ls -la"}),
            json!({"op": "remove", "terminal_id": t.id, "entry_id": id}),
            json!({"op": "clear", "terminal_id": t.id}),
            json!({"op": "list", "terminal_id": t.id}),
        ] {
            w.advance(Duration::from_secs(13));
            seen.push(mcp.call(A, args));
        }
        for value in &seen {
            let text = value.to_string();
            assert!(
                !text.contains("zzprog") && !text.contains("foreground"),
                "{access:?}: {text}"
            );
        }
        assert_eq!(seen[1]["follow_mode"], access.as_str(), "{}", seen[1]);
        assert_eq!(seen[0]["follow_mode"], access.as_str());
        // A program in the foreground makes even a full follow strict.
        assert_eq!(seen[3]["error"], "history_expansion", "{}", seen[3]);
    }
}

// ── sensitive (S3A-12) ────────────────────────────────────────────────────────
//
// The remote shells here belong to another focus: a follower of its own focus's
// remote shell is held sensitive, which makes the terminal's focus (itself)
// sensitive, and a sensitive focus's terminal marks whoever it tells anything,
// so such a follower is marked at the started notice in either mode (a rule
// older than S3a).

/// The focus the remote shells of these tests belong to.
const OWNER: &str = "focus-owner";

#[test]
fn a_staging_only_follower_of_a_remote_shell_is_held_sensitive_but_not_marked_by_the_grant() {
    let mut w = World::new();
    let sensitive = w.sensitive();
    let t = w.ecs(OWNER);
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    assert!(sensitive.tag_is_sensitive(A), "held while it follows");
    w.stop(&t);
    assert!(
        !sensitive.tag_is_sensitive(A),
        "the grant alone said nothing of the terminal, so nothing marks it"
    );
}

#[test]
fn its_first_staging_call_on_a_remote_shell_marks_a_staging_only_follower_for_good_accepted_or_refused(
) {
    for case in ["list", "invalid_text", "staging_disabled", "stage"] {
        let mut w = World::new();
        let sensitive = w.sensitive();
        let t = w.ecs(OWNER);
        w.follow_as(&t, A, FollowAccess::StagingOnly);
        match case {
            "list" => {
                w.list(A, &t).unwrap();
            }
            "stage" => {
                w.stage(A, &t, "ls").unwrap();
            }
            "invalid_text" => {
                assert_eq!(w.refusal(A, &t, stage_op("a\nb", None, None)), case);
            }
            "staging_disabled" => {
                w.terminals
                    .lock()
                    .unwrap()
                    .staging_set_enabled(&cap(), &t.id, false)
                    .unwrap();
                assert_eq!(w.refusal(A, &t, StagingOp::List), case);
            }
            _ => unreachable!(),
        }
        w.stop(&t);
        assert!(sensitive.tag_is_sensitive(A), "{case}: marked for good");
        w.follow.session_ended(A);
        assert!(sensitive.tag_is_sensitive(A), "{case}: and stays marked");
        // A stranger's refused call names the terminal too, but it follows
        // nothing: it is told `not_following` and stays as it was.
        assert_eq!(w.refusal(B, &t, StagingOp::List), "not_following");
        assert!(!sensitive.tag_is_sensitive(B), "{case}");
    }
}

#[test]
fn a_local_staging_only_follower_is_never_marked() {
    let mut w = World::new();
    let sensitive = w.sensitive();
    let t = w.local(A);
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    assert!(!sensitive.tag_is_sensitive(A));
    w.list(A, &t).unwrap();
    w.stage(A, &t, "ls").unwrap();
    w.advance(Duration::from_secs(13));
    assert_eq!(
        w.refusal(A, &t, stage_op("a\nb", None, None)),
        "invalid_text"
    );
    assert!(!sensitive.tag_is_sensitive(A));
    w.stop(&t);
    assert!(!sensitive.tag_is_sensitive(A));
}

#[test]
fn a_full_follower_of_a_remote_shell_is_held_and_its_staging_calls_do_not_mark_it() {
    let mut w = World::new();
    let sensitive = w.sensitive();
    let t = w.ecs(OWNER);
    w.follow(&t, A);
    assert!(sensitive.tag_is_sensitive(A), "held while it follows");
    w.list(A, &t).unwrap();
    w.stage(A, &t, "ls").unwrap();
    w.advance(Duration::from_secs(13));
    let _ = w.call(A, &t, stage_op("a\nb", None, None));
    w.stop(&t);
    assert!(
        !sensitive.tag_is_sensitive(A),
        "unchanged by S3a: a full follow marks when output reaches it, not when it stages"
    );
}

// ── request_follow (S3A) ──────────────────────────────────────────────────────

#[test]
fn a_staging_only_request_offers_exactly_allow_staging_only_and_deny() {
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);

    let handle = asker.start(&w, A, &t.id, FollowAccess::StagingOnly);
    let sheet = asker.sheet(A, &handle).expect("the user is asked");
    assert_eq!(sheet.choices, ["allow_staging_only", "deny"]);
    let pane = local_pane(&w);
    assert_eq!(
        sheet.prompt,
        format!(
            "Cody in {A} asks to stage commands for {pane}. Cody can stage commands but will NOT see this terminal's output or screen. You place and run every command yourself."
        )
    );
    // `allow` is not one of its choices: the registry refuses it, nothing starts.
    assert!(matches!(
        asker.answer(&sheet, "allow"),
        AnswerOutcome::UnknownChoice
    ));
    assert_eq!(w.follow.access_of(A, &t.id), None);
    assert!(matches!(
        asker.answer(&sheet, "allow_staging_only"),
        AnswerOutcome::Answered { .. }
    ));
    assert_eq!(asker.finish(handle), FollowRequestResult::StagingOnly);
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
    let listed = w.api.list_terminals(A);
    let mine = listed.iter().find(|x| x.terminal_id == t.id).unwrap();
    assert!(mine.followed_by_you);
    assert_eq!(mine.follow_mode, Some(FollowAccess::StagingOnly));

    // Asked again: it already has that; nobody is asked.
    let (again, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(again, FollowRequestResult::StagingOnly);
    assert!(sheet.is_none());

    // A remote shell's sheet leads with its environment.
    let remote = w.ecs(B);
    let handle = asker.start(&w, B, &remote.id, FollowAccess::StagingOnly);
    let sheet = asker.sheet(B, &handle).expect("the user is asked");
    assert_eq!(sheet.choices, ["allow_staging_only", "deny"]);
    assert_eq!(
        sheet.prompt,
        format!(
            "Staging only for PRODUCTION: Cody in {B} asks to stage commands for production · admin-portal · scheduler. Output from PRODUCTION will NOT be sent to Cody's model. You place and run every command yourself."
        )
    );
    asker.answer(&sheet, "deny");
    assert_eq!(asker.finish(handle), FollowRequestResult::Denied);
    assert_eq!(w.follow.access_of(B, &remote.id), None);
}

#[test]
fn a_staging_only_follower_asking_for_full_gets_a_fresh_sheet_and_deny_leaves_its_follow_and_list_alone(
) {
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);
    w.follow_as(&t, A, FollowAccess::StagingOnly);
    let id = w.staged_id(A, &t, "ls");

    let (denied, sheet) = asker.ask(&w, A, &t.id, FollowAccess::Full, "deny");
    assert_eq!(denied, FollowRequestResult::Denied);
    let sheet = sheet.expect("a fresh sheet, not an answer from the existing follow");
    assert_eq!(sheet.choices, ["allow", "deny"]);
    let pane = local_pane(&w);
    assert_eq!(
        sheet.prompt,
        format!(
            "Cody in {A} asks to follow {pane}. Output will be sent to Cody's model. Cody can stage commands here now without seeing output; allowing also sends it this terminal's output."
        )
    );
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
    let list = w.list(A, &t).unwrap();
    assert_eq!(list.entries.len(), 1);
    assert_eq!(list.entries[0].id, id);
    assert!(list.staging_only);

    w.advance(PAST_COOLDOWN);
    let (allowed, _) = asker.ask(&w, A, &t.id, FollowAccess::Full, "allow");
    assert_eq!(allowed, FollowRequestResult::Following);
    assert_eq!(w.follow.access_of(A, &t.id), Some(FollowAccess::Full));
    let list = w.list(A, &t).unwrap();
    assert!(list.entries.is_empty(), "a new follow, a new list");
    assert!(!list.staging_only);
}

#[test]
fn a_full_follower_asking_for_staging_only_already_has_more_and_nobody_is_asked() {
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);
    w.follow(&t, A);
    let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(result, FollowRequestResult::Following);
    assert!(sheet.is_none());
    assert_eq!(w.follow.access_of(A, &t.id), Some(FollowAccess::Full));
}

#[test]
fn staging_off_everywhere_or_for_the_terminal_refuses_a_staging_only_request_before_anyone_is_asked(
) {
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);
    let set_global = |on: bool| {
        w.terminals
            .lock()
            .unwrap()
            .staging_set_global(&cap(), "app", on)
            .unwrap()
    };

    set_global(false);
    let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(
        result,
        FollowRequestResult::Refused(FollowRefusal::StagingDisabled)
    );
    assert!(sheet.is_none());
    assert_eq!(FollowRefusal::StagingDisabled.code(), "staging_disabled");

    set_global(true);
    w.terminals
        .lock()
        .unwrap()
        .staging_set_enabled(&cap(), &t.id, false)
        .unwrap();
    let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(
        result,
        FollowRequestResult::Refused(FollowRefusal::StagingDisabled)
    );
    assert!(sheet.is_none());
    assert_eq!(w.follow.access_of(A, &t.id), None);

    // Staging is not what a full request asks for: it is still asked.
    let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::Full, "deny");
    assert_eq!(result, FollowRequestResult::Denied);
    assert!(sheet.is_some());
}

#[test]
fn without_an_app_that_declared_all_three_capabilities_a_staging_only_request_is_no_operator_and_asks_nobody(
) {
    for caps in [
        &[TERMINAL_STAGING_UI, TERMINAL_FOLLOW_UI][..],
        &[TERMINAL_FOLLOW_UI, TERMINAL_STAGING_ONLY_UI][..],
        &[TERMINAL_STAGING_UI, TERMINAL_STAGING_ONLY_UI][..],
        &[][..],
    ] {
        let mut w = World::build(caps, None);
        let mut asker = Asker::new();
        let t = w.local(A);
        let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
        assert_eq!(result, FollowRequestResult::NoOperator, "{caps:?}");
        assert!(sheet.is_none(), "{caps:?}: somebody was asked");
        assert_eq!(w.follow.access_of(A, &t.id), None);
    }
    // An app that declared all three is asked.
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);
    let (result, sheet) = asker.ask(&w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(result, FollowRequestResult::Denied);
    assert!(sheet.is_some());
}

#[test]
fn the_cooldown_is_shared_by_both_modes() {
    for (first, second) in [
        (FollowAccess::Full, FollowAccess::StagingOnly),
        (FollowAccess::StagingOnly, FollowAccess::Full),
    ] {
        let mut w = World::all_caps();
        let mut asker = Asker::new();
        let t = w.local(A);
        let (denied, _) = asker.ask(&w, A, &t.id, first, "deny");
        assert_eq!(denied, FollowRequestResult::Denied);
        let (result, sheet) = asker.ask(&w, A, &t.id, second, "deny");
        assert_eq!(
            result,
            FollowRequestResult::Refused(FollowRefusal::RequestCooldown),
            "{first:?} then {second:?}"
        );
        assert!(sheet.is_none());
    }
}

#[test]
fn one_request_at_a_time_is_shared_by_both_modes() {
    for (first, second) in [
        (FollowAccess::Full, FollowAccess::StagingOnly),
        (FollowAccess::StagingOnly, FollowAccess::Full),
    ] {
        let mut w = World::all_caps();
        let mut asker = Asker::new();
        let t = w.local(A);
        let waiting = asker.start(&w, A, &t.id, first);
        let sheet = asker.sheet(A, &waiting).expect("the first is asked");
        let second_call = asker.start(&w, A, &t.id, second);
        wait_for("the second request to be answered", || {
            second_call.is_finished()
        });
        assert_eq!(
            asker.finish(second_call),
            FollowRequestResult::Refused(FollowRefusal::RequestPending),
            "{first:?} then {second:?}"
        );
        asker.answer(&sheet, "deny");
        assert_eq!(asker.finish(waiting), FollowRequestResult::Denied);
    }
}

#[test]
fn the_ceiling_is_shared_by_both_modes() {
    let mut w = World::all_caps();
    let mut asker = Asker::new();
    let t = w.local(A);
    for (access, allow, want) in [
        (FollowAccess::Full, "allow", FollowRequestResult::Following),
        (
            FollowAccess::StagingOnly,
            "allow_staging_only",
            FollowRequestResult::StagingOnly,
        ),
        (FollowAccess::Full, "allow", FollowRequestResult::Following),
    ] {
        let (result, sheet) = asker.ask(&w, A, &t.id, access, allow);
        assert_eq!(result, want);
        assert!(sheet.is_some());
        w.stop(&t);
    }
    for access in ACCESSES {
        let (result, sheet) = asker.ask(&w, A, &t.id, access, "deny");
        assert_eq!(
            result,
            FollowRequestResult::Refused(FollowRefusal::RequestLimit),
            "{access:?}"
        );
        assert!(sheet.is_none());
    }
}

// ── the canary proof (S3A criterion 48) ───────────────────────────────────────

/// Prints canaries until it is killed, five rounds a second: a numbered line,
/// a window title, a full-screen program's screen, and a secret.
const CANARY_CHILD: &str = ": > \"$READY\"; n=0; while :; do n=$((n+1)); printf 'CANARY-S3-OUT-%d\\n' \"$n\"; printf '\\033]0;CANARY-S3-TITLE\\007'; printf '\\033[?1049h\\033[HCANARY-S3-ALT\\033[?1049l'; printf 'DB_PASSWORD=CANARY-S3-SECRET-zq7x%d\\n' \"$n\"; sleep 0.2; done";

const CANARY: &str = "CANARY-S3";

fn canary_terminal(w: &mut World, ecs: bool) -> Term {
    let t = if ecs {
        w.ecs_with(A, CANARY_CHILD)
    } else {
        w.local_with(A, CANARY_CHILD)
    };
    wait_long("the canaries to stream", || last_canary(&t) >= 3);
    t
}

/// The number of the last `CANARY-S3-OUT-<n>` line the terminal printed.
fn last_canary(t: &Term) -> u64 {
    let ring = String::from_utf8_lossy(&t.session.ring_bytes()).into_owned();
    let marker = "CANARY-S3-OUT-";
    ring.rmatch_indices(marker)
        .filter_map(|(at, _)| {
            ring[at + marker.len()..]
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .ok()
        })
        .next()
        .unwrap_or(0)
}

/// Invite A for staging only through the pane's popover (a minted
/// `OperatorCap`); the start adds no screen hook.
fn popover_invite(w: &World, t: &Term) {
    let hooks = t.session.screen_hook_count();
    w.follow
        .invite_staging_only(&cap(), &t.id, A)
        .expect("the staging-only invite");
    assert_eq!(
        t.session.screen_hook_count(),
        hooks,
        "a staging-only start added a screen hook"
    );
}

/// Every staging op with every fixture text, through the API and the MCP tool,
/// and an insert the user reports. What A is given back goes into `out`.
fn drive_staging(w: &World, mcp: &McpSharedState, asker: &Asker, t: &Term, out: &mut Vec<String>) {
    let tick = || w.advance(Duration::from_secs(13));
    let mut texts = every_text();
    texts.extend(
        hazards()
            .iter()
            .map(|c| c["text"].as_str().unwrap().to_string()),
    );
    let mut ids: Vec<String> = Vec::new();
    for text in &texts {
        tick();
        let staged = w.stage(A, t, text);
        if let Ok(StagingOutcome::Staged { entry_id, .. }) = &staged {
            ids.push(entry_id.clone());
        }
        out.push(format!("{staged:?}"));
        tick();
        out.push(format!(
            "{:?}",
            w.call(A, t, stage_op("ls", Some(text), None))
        ));
        if let Some(id) = ids.last() {
            tick();
            out.push(format!(
                "{:?}",
                w.call(A, t, replace(id, Some(text), Some(text)))
            ));
        }
        tick();
        out.push(
            asker
                .rt
                .block_on(crate::mcp::tools::terminal_staging::handle(
                    mcp,
                    Some(
                        &json!({"op": "stage", "terminal_id": t.id, "command": text, "note": text}),
                    ),
                    Some(A),
                ))
                .to_string(),
        );
        if ids.len() >= MAX_ENTRIES - 4 {
            tick();
            out.push(format!("{:?}", w.call(A, t, StagingOp::Clear)));
            ids.clear();
        }
    }
    tick();
    out.push(format!("{:?}", w.call(A, t, StagingOp::Clear)));
    // The user places an entry: it is counted, and A is not told.
    tick();
    let id = w.staged_id(A, t, "ls -la");
    w.report_inserted(t, &id, 6);
    let listed = w.list(A, t).expect("list");
    assert_eq!(listed.entries[0].inserted_count, 1);
    for op in ["list", "clear"] {
        tick();
        out.push(
            asker
                .rt
                .block_on(crate::mcp::tools::terminal_staging::handle(
                    mcp,
                    Some(&json!({"op": op, "terminal_id": t.id})),
                    Some(A),
                ))
                .to_string(),
        );
    }
}

/// Every other call A can make about `t`: the screen read, the list, both
/// follow requests (the full one denied), and every terminal tool's handler.
fn agent_calls(
    w: &World,
    mcp: &McpSharedState,
    asker: &mut Asker,
    t: &Term,
    out: &mut Vec<String>,
) {
    let read = w.api.read_screen_if_following(A, &t.id);
    assert_eq!(read, Err(ScreenReadRefused::StagingOnly));
    out.push(format!("{read:?}"));
    out.push(format!("{:?}", w.api.list_terminals(A)));

    let (already, sheet) = asker.ask(w, A, &t.id, FollowAccess::StagingOnly, "deny");
    assert_eq!(already, FollowRequestResult::StagingOnly);
    assert!(sheet.is_none());
    out.push(format!("{already:?}"));
    w.advance(PAST_COOLDOWN);
    let (denied, sheet) = asker.ask(w, A, &t.id, FollowAccess::Full, "deny");
    assert_eq!(denied, FollowRequestResult::Denied);
    out.push(format!("{denied:?}"));
    out.push(sheet.expect("a sheet").prompt);
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );

    // The MCP handlers of every terminal tool.
    let id = json!({ "terminal_id": t.id });
    let screen = asker
        .rt
        .block_on(terminal_follow::read_screen(mcp, Some(&id), Some(A)));
    assert_eq!(screen["error"], "terminal_read_forbidden", "{screen}");
    for value in [
        asker
            .rt
            .block_on(terminal_follow::list_terminals(mcp, None, Some(A))),
        screen,
        asker
            .rt
            .block_on(crate::mcp::tools::terminal_staging::handle(
                mcp,
                Some(&json!({"op": "list", "terminal_id": t.id})),
                Some(A),
            )),
        asker
            .rt
            .block_on(terminal::open_terminal(mcp, None, Some(A))),
        asker.rt.block_on(remote_shell::list_targets(mcp, None)),
        asker.rt.block_on(remote_shell::request_shell(
            mcp,
            Some(&json!({
                "project": "admin-portal", "environment": "production",
                "service": "scheduler", "shell_type": "shell",
            })),
            Some(A),
        )),
        asker.rt.block_on(terminal_follow::request_follow(
            mcp,
            Some(&json!({ "terminal_id": t.id, "mode": "staging_only" })),
            Some(A),
        )),
    ] {
        out.push(value.to_string());
    }
    w.advance(PAST_COOLDOWN);
    let state = mcp.clone();
    let args = json!({ "terminal_id": t.id, "mode": "full" });
    let full = asker
        .rt
        .spawn(async move { terminal_follow::request_follow(&state, Some(&args), Some(A)).await });
    let sheet = asker.sheet(A, &full).expect("a sheet for the MCP request");
    assert_eq!(sheet.choices, ["allow", "deny"]);
    asker.answer(&sheet, "deny");
    let denied = asker.finish(full);
    assert_eq!(denied["error"], "denied", "{denied}");
    out.push(denied.to_string());
    assert_eq!(
        w.follow.access_of(A, &t.id),
        Some(FollowAccess::StagingOnly)
    );
}

/// Every `<nostromo-terminal-follow …/>` element in `text`: `(event, reason)`.
fn follow_events(text: &str) -> Vec<(String, Option<String>)> {
    let open = "<nostromo-terminal-follow ";
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(at) = rest.find(open) {
        let element = &rest[at..];
        let end = element.find("/>").expect("an element closes");
        let element = &element[..end];
        let attr = |name: &str| {
            let needle = format!(" {name}=\"");
            element.find(&needle).map(|s| {
                let v = &element[s + needle.len()..];
                v[..v.find('"').unwrap()].to_string()
            })
        };
        out.push((attr("event").unwrap_or_default(), attr("reason")));
        rest = &rest[at + end..];
    }
    out
}

/// Every frame in `rx` so far, as JSON.
fn drain_broadcast(rx: &mut broadcast::Receiver<ServerMsg>, into: &mut Vec<String>) {
    loop {
        match rx.try_recv() {
            Ok(msg) => into.push(serde_json::to_string(&msg).unwrap()),
            Err(broadcast::error::TryRecvError::Lagged(n)) => {
                panic!("{n} frames were lost before they could be checked")
            }
            Err(_) => return,
        }
    }
}

fn drain_targeted(w: &mut World, into: &mut Vec<String>) {
    if let Some(rx) = w.frames.as_mut() {
        while let Ok(msg) = rx.try_recv() {
            into.push(serde_json::to_string(&msg).unwrap());
        }
    }
}

#[test]
fn nothing_of_a_local_terminals_output_reaches_its_staging_only_follower_by_any_call_or_end() {
    canary_proof(false);
}

#[test]
fn nothing_of_a_remote_terminals_output_reaches_its_staging_only_follower_by_any_call_or_end() {
    canary_proof(true);
}

fn canary_proof(ecs: bool) {
    // Every tracing line written on this thread and the runtime's threads.
    // (The PTY reader threads are the session's own and log no text.)
    let captured = Captured::default();
    let dispatch = tracing::Dispatch::new(
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .with_writer({
                let captured = captured.clone();
                move || captured.clone()
            })
            .finish(),
    );
    let _main = tracing::dispatcher::set_default(&dispatch);
    let rt = {
        let dispatch = dispatch.clone();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .on_thread_start(move || {
                std::mem::forget(tracing::dispatcher::set_default(&dispatch));
            })
            .build()
            .unwrap()
    };
    let mut asker = Asker::with_runtime(rt);
    // Built inside the runtime, so a full follow's pump runs (the control at the end).
    let mut w = {
        let _in = asker.rt.enter();
        World::all_caps()
    };
    let missing = w.dir.path().join("no-remote-shells");
    w.terminals.lock().unwrap().set_ecs_paths(EcsPaths::new(
        missing.join("config"),
        missing.join("local"),
        missing.join("aliases"),
    ));
    let mcp = mcp_state(&w, &asker);
    let mut returned: Vec<String> = Vec::new();
    let mut frames: Vec<String> = Vec::new();
    let mut invites = 0;

    let t = canary_terminal(&mut w, ecs);

    // 1. Granted through the decision path.
    let hooks = t.session.screen_hook_count();
    let grant = FollowGrant::from_decision(
        &DecisionOutcome::Answered("allow_staging_only".into()),
        FollowAccess::StagingOnly,
    )
    .expect("the staging-only grant");
    w.follow.invite_granted(grant, &t.id, A).expect("granted");
    invites += 1;
    assert_eq!(
        t.session.screen_hook_count(),
        hooks,
        "a staging-only start added a screen hook"
    );
    let streaming_from = last_canary(&t);
    drive_staging(&w, &mcp, &asker, &t, &mut returned);
    agent_calls(&w, &mcp, &mut asker, &t, &mut returned);
    wait_long("output to keep streaming while A works", || {
        last_canary(&t) > streaming_from + 5
    });

    // 2. The user stops it.
    w.stop(&t);
    returned.push(format!("{:?}", w.call(A, &t, StagingOp::List)));
    returned.push(format!("{:?}", w.api.read_screen_if_following(A, &t.id)));

    // 3. Through the popover, with a minted OperatorCap; then a move to B.
    popover_invite(&w, &t);
    invites += 1;
    agent_calls(&w, &mcp, &mut asker, &t, &mut returned);
    w.follow
        .invite_staging_only(&cap(), &t.id, B)
        .expect("moved to B");
    returned.push(format!("{:?}", w.call(A, &t, StagingOp::List)));

    // 4. Back to A; its session ends.
    popover_invite(&w, &t);
    invites += 1;
    w.follow.session_ended(A);
    assert_eq!(w.follow.access_of(A, &t.id), None);

    // 5. Back to A; the app closes (and opens again).
    popover_invite(&w, &t);
    invites += 1;
    drain_targeted(&mut w, &mut frames);
    w.terminals.lock().unwrap().unregister_conn(&cap(), "app");
    w.follow.app_closed();
    w.frames = Some(w.connect_app("app-2", &ALL_CAPS));

    // 6. Back to A; the pane closes.
    popover_invite(&w, &t);
    invites += 1;
    returned.push(format!("{:?}", w.list(A, &t)));
    w.terminals.lock().unwrap().close(&cap(), &t.id).unwrap();

    // 7. A local terminal is restarted (a remote one cannot be).
    if !ecs {
        let ended = canary_terminal(&mut w, ecs);
        ended.session.kill();
        wait_for("the terminal to end", || {
            w.terminals
                .lock()
                .unwrap()
                .info(&ended.id)
                .is_some_and(|i| i.status == TerminalStatus::Ended)
        });
        popover_invite(&w, &ended);
        invites += 1;
        w.terminals
            .lock()
            .unwrap()
            .restart(&cap(), &ended.id)
            .unwrap();
    }

    // What A was told and given.
    let told = w.told(A, 0);
    let all: Vec<&String> = told.iter().chain(returned.iter()).collect();
    for text in &all {
        for marker in [
            CANARY,
            "<nostromo-terminal-output",
            ADVISORY,
            SELECTION_ADVISORY,
        ] {
            assert!(!text.contains(marker), "{marker} reached A: {text}");
        }
        assert!(
            !text.to_lowercase().contains("[redacted"),
            "a redaction marker reached A: {text}"
        );
    }
    let events: Vec<(String, Option<String>)> =
        told.iter().flat_map(|t| follow_events(t)).collect();
    for (event, reason) in &events {
        match event.as_str() {
            "started" => assert_eq!(reason.as_deref(), Some("staging_only"), "{events:?}"),
            "stopped" => {}
            other => panic!("A was told `{other}`: {events:?}"),
        }
    }
    assert_eq!(
        events.iter().filter(|(e, _)| e == "started").count(),
        invites,
        "{events:?}"
    );
    let mut stopped: Vec<String> = events
        .iter()
        .filter(|(e, _)| e == "stopped")
        .map(|(_, r)| r.clone().unwrap_or_default())
        .map(|r| {
            if r.starts_with("moved_to ") {
                "moved_to".to_string()
            } else {
                r
            }
        })
        .collect();
    stopped.sort();
    let mut want = vec!["app_closed", "moved_to", "pane_closed", "user_stopped"];
    if !ecs {
        want.push("terminal_restarted");
    }
    want.sort();
    assert_eq!(
        stopped, want,
        "a session end says nothing; every other end says stopped"
    );
    // No delivery or screen read names A, by its tag or its opaque one.
    let names = [A.to_string(), w.sensitive().opaque_tag(A)];
    for event in ["delivery", "screen_read"] {
        let lines: Vec<Value> = w
            .audit_named(event)
            .into_iter()
            .filter(|l| {
                names
                    .iter()
                    .any(|n| l["follower"] == n.as_str() || l["focus"] == n.as_str())
            })
            .collect();
        assert!(lines.is_empty(), "{event} audited for A: {lines:?}");
    }

    // The control: the same harness, A upgraded to a full follow through an
    // Allow on its request, does see the canary. A leak would show.
    let control = canary_terminal(&mut w, ecs);
    popover_invite(&w, &control);
    let hooks = control.session.screen_hook_count();
    let from = w.injected_count();
    w.advance(PAST_COOLDOWN);
    let (upgraded, sheet) = asker.ask(&w, A, &control.id, FollowAccess::Full, "allow");
    assert_eq!(upgraded, FollowRequestResult::Following);
    assert_eq!(sheet.expect("a sheet").choices, ["allow", "deny"]);
    assert_eq!(control.session.screen_hook_count(), hooks + 1);
    wait_long("the canary to reach a full follower", || {
        w.told(A, from)
            .iter()
            .any(|t| t.contains("<nostromo-terminal-output") && t.contains("CANARY-S3-OUT-"))
    });

    // Nothing written anywhere during the proof carries a canary: the audit
    // file, a tracing line, a frame to the clients or a sheet.
    drain_targeted(&mut w, &mut frames);
    drain_broadcast(&mut w.broadcast.lock().unwrap(), &mut frames);
    drain_broadcast(&mut asker.sheets, &mut frames);
    let audit = w.audit_text();
    assert!(!audit.contains(CANARY), "the audit file carries a canary");
    let logs = String::from_utf8_lossy(&captured.0.lock().unwrap()).into_owned();
    assert!(!logs.contains(CANARY), "a tracing line carries a canary");
    for frame in &frames {
        assert!(
            !frame.contains(CANARY),
            "a client frame carries a canary: {frame}"
        );
    }
    assert!(
        frames.iter().any(|f| f.contains("staging_only")),
        "the frames were captured"
    );
}
