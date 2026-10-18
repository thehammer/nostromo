//! The approval broker's hold-and-answer rules (AP0b), driven directly.
//!
//! `tests/approvals_wire.rs` proves the same behaviour over real sockets and a
//! fake CLI. These tests are the fast, exact ones: the broker is called the way
//! the server calls it (`presenter_connected`, `app_disconnected`, `answer`) and
//! the session's stdin is a sink that records every answer.
//!
//! What they pin (PRD criteria 17-19 and the AP0b technical criteria):
//! - a request is held only when the guard let it through, the session carries
//!   the guard hook, and a verified app that renders approvals is connected;
//! - the first answer wins, whoever races it; every later one is told what
//!   happened (`AlreadyResolved{outcome}`), or `UnknownRequest` for an id that
//!   was never held or has been forgotten (the last 256 ended requests are kept);
//! - the words the agent is told for each decision, and the note rules;
//! - the 15-minute deadline, to the second;
//! - the 3 s grace after the last presenter leaves, including the epoch rule: a
//!   reconnect (or a second departure) restarts it.
//!
//! Time: paused tokio time. The broker's worker is a plain thread, so effects are
//! polled for in real time with a cap; nothing parks the runtime, so the paused
//! clock only moves when a test calls `tokio::time::advance`.

use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    AnswerResult, ApprovalBroker, ApprovalPresenters, BrokerParts, Incoming, Presenter, SessionInfo, SessionSink,
    APPROVAL_TIMEOUT, APPROVAL_UNAVAILABLE_MESSAGE, DENIED_MESSAGE, NO_APP_MESSAGE, PRESENTER_GRACE,
    TIMED_OUT_MESSAGE,
};
use nostromo::approvals::guard::{PaneInfo, PaneProbe, ProbeError, TmuxSocket};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::approvals::wire::{AnswerRefusal, ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind};
use nostromo::ipc::protocol::ServerMsg;
use serde_json::{json, Value};
use tokio::sync::broadcast;

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer.
struct FakeSink {
    live: AtomicBool,
    writes: Mutex<Vec<(String, Value)>>,
}

impl FakeSink {
    fn new() -> Arc<Self> {
        Arc::new(Self { live: AtomicBool::new(true), writes: Mutex::new(Vec::new()) })
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.writes.lock().unwrap().clone()
    }

    fn die(&self) {
        self.live.store(false, Ordering::SeqCst);
    }
}

impl SessionSink for FakeSink {
    fn live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn respond(&self, cli_request_id: &str, response: &Value) -> io::Result<()> {
        self.writes.lock().unwrap().push((cli_request_id.to_owned(), response.clone()));
        Ok(())
    }
}

/// No tmux anywhere (the guard's fast path never asks for one on these commands).
struct NoTmux;

impl PaneProbe for NoTmux {
    fn pane(&self, _socket: &TmuxSocket, _target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        Ok(None)
    }

    fn all_panes(&self, _socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        Ok(Vec::new())
    }

    fn subtree_args(&self, _pid: u32) -> Result<Vec<String>, ProbeError> {
        Ok(Vec::new())
    }

    fn servers(&self, _extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        Ok(vec![TmuxSocket::Default])
    }
}

struct NoRules;

impl SettingsSource for NoRules {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        Vec::new()
    }
}

// ── the rig ───────────────────────────────────────────────────────────────────

const T: &str = "focus-1";
const UNGUARDED: &str = "unguarded";
const BARRIER: &str = "barrier";

struct Rig {
    broker: ApprovalBroker,
    sink: Arc<FakeSink>,
    frames: broadcast::Receiver<ServerMsg>,
    _dir: tempfile::TempDir,
    generation: u64,
    barrier_generation: u64,
    barriers: AtomicUsize,
}

fn session(tag: &str, guarded: bool) -> SessionInfo {
    SessionInfo {
        tag: tag.into(),
        agent: "cody".into(),
        session_id: Some(format!("sid-{tag}")),
        cwd: Some(PathBuf::from("/work/proj")),
        guarded,
    }
}

/// A `can_use_tool` request the guard lets through.
fn bash_request(tool_use_id: &str, command: &str) -> Value {
    json!({
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "display_name": "Bash",
        "input": { "command": command, "description": "d" },
        "description": "d",
        "decision_reason_type": "rule",
        "tool_use_id": tool_use_id,
    })
}

fn allow_once() -> ApprovalDecision {
    ApprovalDecision { kind: DecisionKind::AllowOnce, note: None }
}

fn deny(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision { kind: DecisionKind::Deny, note: note.map(str::to_owned) }
}

fn deny_and_stop(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision { kind: DecisionKind::DenyAndStop, note: note.map(str::to_owned) }
}

fn deny_body(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

impl Rig {
    fn new() -> Self {
        Self::with_timeout(APPROVAL_TIMEOUT)
    }

    fn with_timeout(timeout: Duration) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let presenters = ApprovalPresenters::default();
        let broker = ApprovalBroker::new(
            AuditLog::open(dir.path()).unwrap(),
            BrokerParts {
                presenter: Arc::new(presenters.clone()),
                presenters: presenters.clone(),
                probe: Arc::new(|| Box::new(NoTmux)),
                settings: Arc::new(NoRules),
                timeout,
            },
        );
        let (tx, frames) = broadcast::channel(4096);
        broker.configure_broadcast(tx);
        let sink = FakeSink::new();
        let generation = broker.register_session(session(T, true), sink.clone());
        broker.register_session(session(UNGUARDED, false), FakeSink::new());
        let barrier_generation = broker.register_session(session(BARRIER, false), FakeSink::new());
        Self { broker, sink, frames, _dir: dir, generation, barrier_generation, barriers: AtomicUsize::new(0) }
    }

    fn submit_to(&self, tag: &str, generation: u64, tool_use_id: &str, command: &str) {
        let accepted = self.broker.submit(Incoming::Request {
            tag: tag.into(),
            generation,
            cli_request_id: format!("cli-{tool_use_id}"),
            value: bash_request(tool_use_id, command),
        });
        assert!(accepted.is_ok(), "the broker takes a request without waiting");
    }

    fn submit(&self, tool_use_id: &str) {
        self.submit_to(T, self.generation, tool_use_id, "rm -rf /tmp/x");
    }

    /// Submit a request and wait until the broker holds it; returns what the app was shown.
    async fn hold(&self, tool_use_id: &str) -> ApprovalRequestWire {
        self.submit(tool_use_id);
        wait_until(&format!("{tool_use_id} to be held"), || {
            self.broker.snapshot().into_iter().find(|w| w.tool_use_id == tool_use_id)
        })
        .await
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker.audit().read(everything(), &AuditFilter::default()).unwrap()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| matches!(e.event, Event::Outcome { .. }) && e.tool_use_id.as_deref() == Some(tool_use_id))
            .collect()
    }

    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || self.outcomes(tool_use_id).into_iter().next()).await
    }

    /// Returns once every job the worker had queued before this call is done.
    async fn barrier(&self) {
        let n = self.barriers.fetch_add(1, Ordering::SeqCst);
        let id = format!("barrier-{n}");
        self.submit_to(BARRIER, self.barrier_generation, &id, "ls");
        self.wait_outcome(&id).await;
    }

    /// Every frame broadcast since the last call.
    fn frames(&mut self) -> Vec<ServerMsg> {
        let mut out = Vec::new();
        loop {
            match self.frames.try_recv() {
                Ok(m) => out.push(m),
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => return out,
            }
        }
    }

    /// Frames until one satisfies `want`. The outcome is logged just before its frame is
    /// broadcast, so a frame read right after `wait_outcome` can race it. Polls in real
    /// time without parking the (paused) runtime.
    async fn frames_until(&mut self, what: &str, want: impl Fn(&ServerMsg) -> bool) -> Vec<ServerMsg> {
        let start = Instant::now();
        let mut all = Vec::new();
        loop {
            all.extend(self.frames());
            if all.iter().any(&want) {
                return all;
            }
            assert!(start.elapsed() < Duration::from_secs(10), "no frame for {what}: {all:?}");
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.sink.writes()
    }
}

fn everything() -> Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

/// Real-time polling that never parks the (paused) runtime, so the clock stays where the test put it.
async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(start.elapsed() < Duration::from_secs(30), "timed out (real time) waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

/// Give spawned tasks and the blocking pool a moment of real time, without parking the runtime.
async fn settle() {
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

fn outcome_name(e: &Entry) -> &str {
    match &e.event {
        Event::Outcome { outcome, .. } => outcome,
        other => panic!("not an outcome: {other:?}"),
    }
}

fn applied(outcome: &str) -> AnswerResult {
    AnswerResult::Applied { outcome: outcome.to_owned() }
}

fn already(outcome: &str) -> AnswerResult {
    AnswerResult::AlreadyResolved { outcome: outcome.to_owned() }
}

// ── what is held, and what is not ─────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_request_is_held_and_broadcast_when_the_session_is_guarded_and_a_presenter_is_connected() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");

    let wire = rig.hold("toolu_1").await;

    assert_eq!(wire.tag, T);
    assert_eq!(wire.tool_use_id, "toolu_1");
    assert_eq!(wire.tool_name, "Bash");
    assert_eq!(wire.input, json!({ "command": "rm -rf /tmp/x", "description": "d" }));
    assert_eq!(wire.agent.name, "cody");
    assert_eq!(wire.cwd.as_deref(), Some("/work/proj"));
    assert!(!wire.request_id.is_empty() && wire.request_id != "cli-toolu_1", "Nostromo's id, never the CLI's");
    assert_eq!(
        wire.deadline_at_ms - wire.created_at_ms,
        15 * 60 * 1000,
        "the card's countdown is the 15-minute deadline"
    );
    assert_eq!(
        wire.options,
        vec![ApprovalOption::AllowOnce, ApprovalOption::Deny, ApprovalOption::DenyAndStop, ApprovalOption::DenyWithNote]
    );
    assert!(rig.writes().is_empty(), "nothing is told to the CLI while a human decides");
    let frames = rig.frames();
    let kinds: Vec<&str> = frames
        .iter()
        .map(|m| match m {
            ServerMsg::ApprovalRequest { .. } => "request",
            ServerMsg::ApprovalPending { .. } => "pending",
            other => panic!("unexpected frame {other:?}"),
        })
        .collect();
    assert_eq!(kinds, ["request", "pending"], "the request, then the count");
    match (&frames[0], &frames[1]) {
        (ServerMsg::ApprovalRequest { tag, request }, ServerMsg::ApprovalPending { tag: ptag, count }) => {
            assert_eq!((tag.as_str(), ptag.as_str(), *count), (T, T, 1));
            assert_eq!(request, &wire);
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test(start_paused = true)]
async fn the_pending_count_follows_the_held_requests_of_a_focus_up_and_down() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let first = rig.hold("toolu_1").await;
    let second = rig.hold("toolu_2").await;
    assert_eq!(rig.broker.snapshot().len(), 2);

    assert_eq!(rig.broker.answer(&first.request_id, &deny(None), "w", "app"), applied("denied"));
    assert_eq!(rig.broker.answer(&second.request_id, &deny(None), "w", "app"), applied("denied"));

    let counts: Vec<u32> = rig
        .frames()
        .into_iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalPending { count, .. } => Some(count),
            _ => None,
        })
        .collect();
    assert_eq!(counts, [1, 2, 1, 0]);
}

#[tokio::test(start_paused = true)]
async fn nothing_is_held_without_a_verified_app_the_agent_is_told_the_app_is_closed_at_once() {
    let mut rig = Rig::new();
    let before = tokio::time::Instant::now();

    rig.submit("toolu_1");
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "no_app");
    assert_eq!(rig.writes(), [("cli-toolu_1".to_owned(), deny_body(NO_APP_MESSAGE))]);
    assert!(rig.broker.snapshot().is_empty());
    assert!(rig.frames().is_empty(), "nothing held, so nothing broadcast");
    assert_eq!(tokio::time::Instant::now(), before, "denied at once: the clock never moved");
}

#[tokio::test(start_paused = true)]
async fn an_app_that_does_not_render_approvals_gets_approval_unavailable_at_once_and_nothing_is_held() {
    let mut rig = Rig::new();
    rig.broker.app_connected("mac-today");
    let before = tokio::time::Instant::now();

    rig.submit("toolu_1");
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "approval_unavailable");
    assert_eq!(rig.writes(), [("cli-toolu_1".to_owned(), deny_body(APPROVAL_UNAVAILABLE_MESSAGE))]);
    assert!(rig.broker.snapshot().is_empty());
    assert!(!rig.broker.has_approval_presenter());
    assert!(rig.frames().is_empty());
    assert_eq!(tokio::time::Instant::now(), before);
}

#[tokio::test(start_paused = true)]
async fn a_session_without_the_guard_hook_is_never_held_even_with_a_presenter_connected() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let naked_sink = FakeSink::new();
    let naked = rig.broker.register_session(session("naked", false), naked_sink.clone());

    rig.submit_to("naked", naked, "toolu_naked", "rm -rf /tmp/x");
    let outcome = rig.wait_outcome("toolu_naked").await;

    assert_eq!(outcome_name(&outcome), "no_app", "the contract's name for 'nobody can be asked about this'");
    assert_eq!(
        naked_sink.writes(),
        [("cli-toolu_naked".to_owned(), deny_body(APPROVAL_UNAVAILABLE_MESSAGE))],
        "the app is open, so the agent is not told it is closed"
    );
    assert!(rig.broker.snapshot().is_empty());
    assert!(
        !rig.frames().iter().any(|m| matches!(m, ServerMsg::ApprovalRequest { .. })),
        "no approval card for a session that carries no guard"
    );
}

// ── answers ───────────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn allow_once_writes_the_input_unchanged_and_the_resolution_names_the_window() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    rig.frames();

    let result = rig.broker.answer(&wire.request_id, &allow_once(), "win-7", "app");

    assert_eq!(result, applied("allowed_once"));
    assert_eq!(
        rig.writes(),
        [("cli-toolu_1".to_owned(), json!({ "behavior": "allow", "updatedInput": { "command": "rm -rf /tmp/x", "description": "d" } }))]
    );
    let frames = rig.frames();
    match frames.as_slice() {
        [ServerMsg::ApprovalResolved { tag, request_id, outcome, by_window, at_ms }, ServerMsg::ApprovalPending { tag: ptag, count }] => {
            assert_eq!((tag.as_str(), request_id.as_str(), outcome.as_str()), (T, wire.request_id.as_str(), "allowed_once"));
            assert_eq!(by_window.as_deref(), Some("win-7"));
            assert!(*at_ms > 0);
            assert_eq!((ptag.as_str(), *count), (T, 0));
        }
        other => panic!("expected the resolution then the new count, got {other:?}"),
    }
    let outcome = rig.wait_outcome("toolu_1").await;
    let Event::Outcome { outcome: name, by_window, latency_ms, .. } = &outcome.event else { unreachable!() };
    assert_eq!(name, "allowed_once");
    assert_eq!(by_window.as_deref(), Some("win-7"));
    assert!(latency_ms.is_some(), "the log records how long the human took");
    assert!(rig.broker.snapshot().is_empty());
}

#[tokio::test(start_paused = true)]
async fn deny_tells_the_agent_the_contract_words_and_deny_and_stop_adds_interrupt() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let plain = rig.hold("toolu_deny").await;
    let stop = rig.hold("toolu_stop").await;
    rig.frames();

    assert_eq!(rig.broker.answer(&plain.request_id, &deny(None), "w1", "app"), applied("denied"));
    assert_eq!(rig.broker.answer(&stop.request_id, &deny_and_stop(None), "w2", "app"), applied("denied_and_stopped"));

    assert_eq!(DENIED_MESSAGE, "The user denied this in Nostromo.");
    let writes = rig.writes();
    assert_eq!(writes.len(), 2);
    let body = |id: &str| writes.iter().find(|(r, _)| r == id).unwrap().1.clone();
    assert_eq!(body("cli-toolu_deny"), deny_body("The user denied this in Nostromo."));
    assert!(body("cli-toolu_deny").get("interrupt").is_none(), "a plain deny does not interrupt");
    assert_eq!(
        body("cli-toolu_stop"),
        json!({ "behavior": "deny", "message": "The user denied this in Nostromo.", "interrupt": true })
    );
    for (tool, window, name) in [("toolu_deny", "w1", "denied"), ("toolu_stop", "w2", "denied_and_stopped")] {
        let e = rig.wait_outcome(tool).await;
        let Event::Outcome { outcome, by_window, latency_ms, .. } = &e.event else { unreachable!() };
        assert_eq!((outcome.as_str(), by_window.as_deref()), (name, Some(window)));
        assert!(latency_ms.is_some());
    }
    let resolved: Vec<(String, Option<String>)> = rig
        .frames()
        .into_iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalResolved { outcome, by_window, .. } => Some((outcome, by_window)),
            _ => None,
        })
        .collect();
    assert_eq!(
        resolved,
        [("denied".to_owned(), Some("w1".to_owned())), ("denied_and_stopped".to_owned(), Some("w2".to_owned()))]
    );
}

#[tokio::test(start_paused = true)]
async fn a_denial_note_is_cleaned_before_the_agent_reads_it() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let long = "x".repeat(600);
    let hidden_then_long = format!("{}{}", "\u{200B}".repeat(100), "y".repeat(600));
    let multibyte = "é".repeat(501);
    let exactly_500 = "z".repeat(500);
    // (what the human typed, what the agent reads after "User's note: ")
    let cases: Vec<(String, String)> = vec![
        ("use /tmp/y instead".into(), "use /tmp/y instead".into()),
        ("a\u{200B}b\u{202E}c\u{FEFF}d".into(), "abcd".into()),
        ("line one\nline two".into(), "line one line two".into()),
        (long, "x".repeat(500)),
        (hidden_then_long, "y".repeat(500)),
        (multibyte, "é".repeat(500)),
        (exactly_500.clone(), exactly_500),
    ];

    for (i, (typed, read)) in cases.iter().enumerate() {
        for stop in [false, true] {
            let tool = format!("toolu_{i}_{stop}");
            let wire = rig.hold(&tool).await;
            let decision = if stop { deny_and_stop(Some(typed)) } else { deny(Some(typed)) };

            assert_eq!(
                rig.broker.answer(&wire.request_id, &decision, "w", "app"),
                applied(if stop { "denied_and_stopped" } else { "denied" })
            );

            let (_, body) = rig.writes().into_iter().find(|(id, _)| *id == format!("cli-{tool}")).unwrap();
            assert_eq!(
                body["message"],
                format!("The user denied this in Nostromo.\n\nUser's note: {read}"),
                "typed {typed:.40?} (stop={stop})"
            );
            assert_eq!(body["behavior"], "deny");
            assert_eq!(body.get("interrupt").is_some(), stop, "interrupt only for deny_and_stop");
            if stop {
                assert_eq!(body["interrupt"], true);
            }
        }
    }
}

#[tokio::test(start_paused = true)]
async fn an_allow_never_carries_the_note_it_was_sent_with() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;

    let decision = ApprovalDecision { kind: DecisionKind::AllowOnce, note: Some("ignore me".into()) };
    assert_eq!(rig.broker.answer(&wire.request_id, &decision, "w", "app"), applied("allowed_once"));

    assert_eq!(
        rig.writes()[0].1,
        json!({ "behavior": "allow", "updatedInput": { "command": "rm -rf /tmp/x", "description": "d" } })
    );
}

#[tokio::test(start_paused = true)]
async fn the_first_answer_wins_when_two_windows_answer_at_the_same_moment() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app-a");
    rig.broker.presenter_connected("app-b");

    for round in 0..30 {
        let wire = rig.hold(&format!("toolu_race_{round}")).await;
        let go = Arc::new(Barrier::new(2));
        let (allow, deny_result) = std::thread::scope(|s| {
            let (b1, b2) = (rig.broker.clone(), rig.broker.clone());
            let (g1, g2) = (Arc::clone(&go), Arc::clone(&go));
            let id = wire.request_id.clone();
            let id2 = id.clone();
            let a = s.spawn(move || {
                g1.wait();
                b1.answer(&id, &allow_once(), "win-a", "app-a")
            });
            let b = s.spawn(move || {
                g2.wait();
                b2.answer(&id2, &deny(None), "win-b", "app-b")
            });
            (a.join().unwrap(), b.join().unwrap())
        });

        let writes: Vec<_> = rig.writes().into_iter().filter(|(id, _)| *id == format!("cli-toolu_race_{round}")).collect();
        assert_eq!(writes.len(), 1, "round {round}: exactly one answer reaches the CLI, got {writes:?}");
        match (allow, deny_result) {
            (AnswerResult::Applied { outcome }, AnswerResult::AlreadyResolved { outcome: told }) => {
                assert_eq!((outcome.as_str(), told.as_str()), ("allowed_once", "allowed_once"), "round {round}");
                assert_eq!(writes[0].1["behavior"], "allow");
            }
            (AnswerResult::AlreadyResolved { outcome: told }, AnswerResult::Applied { outcome }) => {
                assert_eq!((outcome.as_str(), told.as_str()), ("denied", "denied"), "round {round}");
                assert_eq!(writes[0].1["behavior"], "deny");
            }
            other => panic!("round {round}: exactly one answer applies and the other hears what won: {other:?}"),
        }
        rig.wait_outcome(&format!("toolu_race_{round}")).await;
        assert_eq!(rig.outcomes(&format!("toolu_race_{round}")).len(), 1, "round {round}: one outcome entry");
    }
}

#[tokio::test(start_paused = true)]
async fn an_answer_for_an_id_no_request_ever_had_is_unknown_and_writes_nothing() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    for decision in [allow_once(), deny(None), deny_and_stop(None)] {
        assert_eq!(rig.broker.answer("no-such-request", &decision, "w", "app"), AnswerResult::UnknownRequest);
    }
    assert_eq!(AnswerResult::UnknownRequest.refusal(), Some((AnswerRefusal::UnknownRequest, None)));
    rig.barrier().await;
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn an_answer_for_a_request_that_was_never_held_is_unknown_and_never_approves_it() {
    // Nobody could be asked: the request ended `no_app` at once, and was never offered.
    let rig = Rig::new();
    rig.submit("toolu_1");
    let denied = rig.wait_outcome("toolu_1").await;
    let id = denied.request_id.clone().expect("the log names the request");

    rig.broker.presenter_connected("app");
    let result = rig.broker.answer(&id, &allow_once(), "w", "app");

    assert_eq!(result, AnswerResult::UnknownRequest);
    assert_eq!(rig.writes().len(), 1, "only the original deny");
    assert_eq!(rig.writes()[0].1["behavior"], "deny");
}

#[tokio::test(start_paused = true)]
async fn a_late_answer_is_told_how_the_request_ended() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    // Answered.
    let answered = rig.hold("toolu_answered").await;
    assert_eq!(rig.broker.answer(&answered.request_id, &deny(None), "w", "app"), applied("denied"));
    assert_eq!(rig.broker.answer(&answered.request_id, &allow_once(), "w2", "app"), already("denied"));

    // Timed out.
    let slow = rig.hold("toolu_slow").await;
    settle().await;
    tokio::time::advance(APPROVAL_TIMEOUT).await;
    rig.wait_outcome("toolu_slow").await;
    assert_eq!(rig.broker.answer(&slow.request_id, &allow_once(), "w", "app"), already("timed_out"));

    // The session stopped.
    let stopped = rig.hold("toolu_stopped").await;
    rig.broker.on_session_gone(T, rig.generation, "stopped");
    assert_eq!(rig.broker.answer(&stopped.request_id, &allow_once(), "w", "app"), already("cancelled"));

    for (_, body) in rig.writes() {
        assert_eq!(body["behavior"], "deny", "no late answer produced an allow: {body}");
    }
}

#[test]
fn an_answer_result_maps_to_the_refusal_frame_the_app_is_sent() {
    assert_eq!(applied("allowed_once").refusal(), None, "an applied answer is not a refusal: the resolution is broadcast");
    assert_eq!(already("denied").refusal(), Some((AnswerRefusal::AlreadyResolved, Some("denied"))));
    assert_eq!(already("timed_out").refusal(), Some((AnswerRefusal::AlreadyResolved, Some("timed_out"))));
    assert_eq!(AnswerResult::UnknownRequest.refusal(), Some((AnswerRefusal::UnknownRequest, None)));
}

#[tokio::test(start_paused = true)]
async fn a_late_answer_after_the_app_went_away_hears_no_app() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    settle().await;
    rig.broker.app_disconnected("app");
    settle().await;
    tokio::time::advance(PRESENTER_GRACE + Duration::from_millis(100)).await;
    rig.wait_outcome("toolu_1").await;

    rig.broker.presenter_connected("app-late");
    assert_eq!(rig.broker.answer(&wire.request_id, &allow_once(), "w", "app-late"), already("no_app"));
    assert!(rig.writes().iter().all(|(_, b)| b["behavior"] == "deny"));
}

#[tokio::test(start_paused = true)]
async fn an_answer_to_a_session_whose_process_is_gone_writes_nothing_and_is_logged_cancelled() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    rig.sink.die();

    let result = rig.broker.answer(&wire.request_id, &allow_once(), "w", "app");

    assert_eq!(result, applied("cancelled"), "the answer ended it, but nothing could be delivered");
    assert!(rig.writes().is_empty(), "never write to a process that is gone");
    assert_eq!(outcome_name(&rig.wait_outcome("toolu_1").await), "cancelled");
}

#[tokio::test(start_paused = true)]
async fn the_broker_remembers_how_the_last_256_held_requests_ended() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    const HELD: usize = 300;
    for i in 0..HELD {
        rig.submit(&format!("toolu_{i}"));
    }
    let held = wait_until("every request to be held", || {
        let s = rig.broker.snapshot();
        (s.len() == HELD).then_some(s)
    })
    .await;
    let id_of = |i: usize| held.iter().find(|w| w.tool_use_id == format!("toolu_{i}")).unwrap().request_id.clone();
    // End them one by one, in order.
    for i in 0..HELD {
        assert_eq!(rig.broker.answer(&id_of(i), &deny(None), "w", "app"), applied("denied"));
    }

    // The newest 256 (44..=299) are remembered; the 44 before are not.
    assert_eq!(rig.broker.answer(&id_of(HELD - 1), &allow_once(), "w", "app"), already("denied"));
    assert_eq!(rig.broker.answer(&id_of(44), &allow_once(), "w", "app"), already("denied"), "the 256th newest is still there");
    assert_eq!(rig.broker.answer(&id_of(43), &allow_once(), "w", "app"), AnswerResult::UnknownRequest, "the 257th is forgotten");
    assert_eq!(rig.broker.answer(&id_of(0), &allow_once(), "w", "app"), AnswerResult::UnknownRequest);
    assert!(rig.writes().iter().all(|(_, b)| b["behavior"] == "deny"), "a forgotten or late answer never approves");
}

// ── the deadline ──────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_held_request_is_denied_timed_out_at_exactly_fifteen_minutes() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    settle().await;
    rig.frames();

    tokio::time::advance(Duration::from_secs(14 * 60 + 59)).await;
    settle().await;
    assert!(rig.writes().is_empty(), "nothing at 14:59");
    assert_eq!(rig.broker.snapshot().len(), 1, "still waiting for a human at 14:59");

    tokio::time::advance(Duration::from_secs(1)).await;
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "timed_out");
    assert_eq!(rig.writes(), [("cli-toolu_1".to_owned(), deny_body(TIMED_OUT_MESSAGE))]);
    assert!(TIMED_OUT_MESSAGE.contains("within 15 minutes"));
    rig.frames_until("timed_out", |m| matches!(m, ServerMsg::ApprovalResolved { request_id, outcome, by_window: None, .. }
        if *request_id == wire.request_id && outcome == "timed_out")).await;
    assert_eq!(rig.broker.answer(&wire.request_id, &allow_once(), "w", "app"), already("timed_out"));
}

// ── the app leaves ────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn when_the_last_presenter_leaves_held_requests_are_denied_no_app_after_the_grace_and_not_before() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    settle().await;
    rig.frames();

    rig.broker.app_disconnected("app");
    settle().await;
    tokio::time::advance(Duration::from_millis(2900)).await;
    settle().await;
    assert!(rig.writes().is_empty(), "nothing before the 3 s grace is over");
    assert_eq!(rig.broker.snapshot().len(), 1);

    tokio::time::advance(Duration::from_millis(200)).await;
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "no_app");
    assert_eq!(rig.writes(), [("cli-toolu_1".to_owned(), deny_body(NO_APP_MESSAGE))]);
    rig.frames_until("no_app", |m| matches!(m, ServerMsg::ApprovalResolved { request_id, outcome, .. }
        if *request_id == wire.request_id && outcome == "no_app")).await;
    assert!(PRESENTER_GRACE < Duration::from_secs(5), "the PRD's bound: denied well inside 5 s");
}

#[tokio::test(start_paused = true)]
async fn losing_one_of_two_presenters_starts_no_grace() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app-a");
    rig.broker.presenter_connected("app-b");
    rig.hold("toolu_1").await;
    settle().await;

    rig.broker.app_disconnected("app-a");
    settle().await;
    tokio::time::advance(Duration::from_secs(60)).await;
    settle().await;

    assert!(rig.writes().is_empty());
    assert_eq!(rig.broker.snapshot().len(), 1, "another window still shows it");
}

#[tokio::test(start_paused = true)]
async fn a_reconnect_within_the_grace_keeps_the_request_and_its_snapshot_redelivers_it() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    settle().await;
    rig.broker.app_disconnected("app");
    settle().await;
    tokio::time::advance(Duration::from_secs(2)).await;

    let snapshot = rig.broker.presenter_connected("app-again");

    assert_eq!(snapshot, vec![wire.clone()], "the snapshot redelivers the same request");
    tokio::time::advance(Duration::from_secs(60)).await;
    settle().await;
    assert!(rig.writes().is_empty(), "the reconnect cancelled the denial");
    assert_eq!(rig.broker.answer(&wire.request_id, &allow_once(), "w", "app-again"), applied("allowed_once"));
}

#[tokio::test(start_paused = true)]
async fn a_second_departure_restarts_the_grace_from_the_second_departure() {
    // Lose the presenter at t=0, reconnect at t=1, lose it again at t=2: the
    // denial is due at t=5 (3 s after the LAST departure), not at t=3.
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    rig.hold("toolu_1").await;
    settle().await;

    rig.broker.app_disconnected("app"); // t=0
    settle().await;
    tokio::time::advance(Duration::from_secs(1)).await;
    rig.broker.presenter_connected("app-2"); // t=1
    settle().await;
    tokio::time::advance(Duration::from_secs(1)).await;
    rig.broker.app_disconnected("app-2"); // t=2
    settle().await;

    tokio::time::advance(Duration::from_millis(1100)).await; // t=3.1: the first grace's moment has passed
    settle().await;
    assert!(rig.writes().is_empty(), "the first grace period was cancelled by the reconnect");
    assert_eq!(rig.broker.snapshot().len(), 1);
    tokio::time::advance(Duration::from_millis(1700)).await; // t=4.8
    settle().await;
    assert!(rig.writes().is_empty(), "not before 3 s after the last departure");

    tokio::time::advance(Duration::from_millis(300)).await; // t=5.1
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "no_app");
    assert_eq!(rig.writes(), [("cli-toolu_1".to_owned(), deny_body(NO_APP_MESSAGE))]);
}

/// "Can anyone be asked?" as a flag the test flips, with a gate that can hold the broker's worker
/// inside the question (so a presenter can leave while a request is being prepared).
struct StalePresenter {
    present: AtomicBool,
    entered: AtomicBool,
    release: Mutex<bool>,
    cv: std::sync::Condvar,
}

impl Presenter for StalePresenter {
    fn can_present(&self, tag: &str) -> bool {
        if tag == BARRIER {
            return false;
        }
        // The decision is made before the wait: it is a stale "yes" by the time it is used.
        let answer = self.present.load(Ordering::SeqCst);
        if answer && !self.entered.swap(true, Ordering::SeqCst) {
            let open = self.release.lock().unwrap();
            let _ = self.cv.wait_timeout_while(open, Duration::from_secs(30), |open| !*open).unwrap();
            return answer;
        }
        answer
    }

    fn app_connected(&self) -> bool {
        self.present.load(Ordering::SeqCst)
    }
}

#[tokio::test(start_paused = true)]
async fn a_request_held_just_as_the_last_presenter_leaves_is_not_stranded() {
    let dir = tempfile::tempdir().unwrap();
    let presenter = Arc::new(StalePresenter {
        present: AtomicBool::new(true),
        entered: AtomicBool::new(false),
        release: Mutex::new(false),
        cv: std::sync::Condvar::new(),
    });
    let broker = ApprovalBroker::new(
        AuditLog::open(dir.path()).unwrap(),
        BrokerParts {
            presenter: presenter.clone(),
            presenters: ApprovalPresenters::default(),
            probe: Arc::new(|| Box::new(NoTmux)),
            settings: Arc::new(NoRules),
            timeout: APPROVAL_TIMEOUT,
        },
    );
    let sink = FakeSink::new();
    let generation = broker.register_session(session(T, true), sink.clone());
    let accepted = broker.submit(Incoming::Request {
        tag: T.into(),
        generation,
        cli_request_id: "cli-1".into(),
        value: bash_request("toolu_1", "rm -rf /tmp/x"),
    });
    assert!(accepted.is_ok());
    // The worker is inside "can anyone be asked?" (and has been told yes).
    wait_until("the worker to ask", || presenter.entered.load(Ordering::SeqCst).then_some(())).await;

    // The app quits now: nobody is left to ask.
    presenter.present.store(false, Ordering::SeqCst);
    broker.presenter_lost();
    settle().await;
    tokio::time::advance(Duration::from_millis(200)).await;
    // The worker carries on with its stale "yes" and holds the request.
    *presenter.release.lock().unwrap() = true;
    presenter.cv.notify_all();
    wait_until("the request to be held", || (!broker.snapshot().is_empty()).then_some(())).await;
    settle().await;

    // Whatever the order of those events, it is not left waiting for 15 minutes.
    tokio::time::advance(PRESENTER_GRACE + Duration::from_secs(1)).await;
    wait_until("the stranded request to be denied", || (!sink.writes().is_empty()).then_some(())).await;

    assert_eq!(sink.writes(), [("cli-1".to_owned(), deny_body(NO_APP_MESSAGE))]);
    assert!(broker.snapshot().is_empty());
}

// ── the session goes away ─────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_session_that_stops_cancels_its_held_requests_and_nothing_is_written() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    rig.frames();

    rig.broker.on_session_gone(T, rig.generation, "stopped");

    assert_eq!(outcome_name(&rig.wait_outcome("toolu_1").await), "cancelled");
    assert!(rig.writes().is_empty(), "never write to a session that is gone");
    let frames = rig
        .frames_until("cancelled", |m| matches!(m, ServerMsg::ApprovalPending { tag, count: 0 } if tag == T))
        .await;
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::ApprovalResolved { request_id, outcome, .. }
            if *request_id == wire.request_id && outcome == "cancelled")),
        "every card is told: {frames:?}"
    );
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::ApprovalPending { tag, count: 0 } if tag == T)),
        "and the count drops to zero: {frames:?}"
    );
    assert!(rig.broker.snapshot().is_empty());
}

// ── AP0b review fix-ups ───────────────────────────────────────────────────────

use nostromo::ipc::protocol::MAX_FRAME_LEN;

fn big_command(bytes: usize) -> String {
    format!("echo {}", "x".repeat(bytes))
}

#[tokio::test(start_paused = true)]
async fn f1_a_request_too_large_to_show_is_denied_at_hold_and_never_held() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    rig.submit_to(T, rig.generation, "toolu_big", &big_command(MAX_FRAME_LEN + 1024));
    let outcome = rig.wait_outcome("toolu_big").await;

    assert_eq!(outcome_name(&outcome), "too_large");
    assert!(rig.broker.snapshot().is_empty(), "never held");
    let writes = rig.writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].1["behavior"], "deny");
    assert!(
        !writes[0].1["message"].as_str().unwrap().contains("xxxx"),
        "the deny carries no request content"
    );
    let audit = serde_json::to_string(&outcome).unwrap();
    assert!(audit.len() < 4096, "the outcome entry is content-free");
}

#[tokio::test(start_paused = true)]
async fn f1_many_near_limit_requests_never_make_an_oversize_snapshot_and_none_is_dropped_silently() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let ids: Vec<String> = (0..6).map(|i| format!("toolu_n{i}")).collect();
    for id in &ids {
        rig.submit_to(T, rig.generation, id, &big_command(1_300_000));
    }
    rig.barrier().await;

    let snapshot = rig.broker.presenter_connected("app-2");

    let frame = serde_json::to_vec(&ServerMsg::ApprovalsSnapshot { requests: snapshot.clone() }).unwrap();
    assert!(frame.len() <= MAX_FRAME_LEN, "the snapshot frame is {} bytes", frame.len());
    assert!(!snapshot.is_empty(), "what fits is still shown");
    for id in &ids {
        let shown = snapshot.iter().any(|w| w.tool_use_id == *id);
        let denied = rig.outcomes(id).first().map(|e| outcome_name(e).to_owned());
        assert!(
            shown ^ (denied.as_deref() == Some("too_large")),
            "{id}: either shown or denied too_large, got shown={shown} outcome={denied:?}"
        );
    }
    assert!(snapshot.len() < ids.len(), "some did not fit and were denied");
}

#[tokio::test(start_paused = true)]
async fn f2_a_huge_window_id_with_newlines_is_cleaned_and_bounded_before_it_is_logged_or_broadcast() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold("toolu_1").await;
    rig.frames();
    let window = format!("win\nforged\r\n{}", "w".repeat(4 * 1024 * 1024));

    let result = rig.broker.answer(&wire.request_id, &allow_once(), &window, "app");

    assert_eq!(result, applied("allowed_once"));
    let limit = nostromo::approvals::audit::MAX_RECORDED_STRING_BYTES + 32;
    let by_window = rig.frames().into_iter().find_map(|m| match m {
        ServerMsg::ApprovalResolved { by_window, .. } => by_window,
        _ => None,
    });
    let by_window = by_window.expect("the resolution names a window");
    assert!(by_window.len() <= limit, "broadcast window id is {} bytes", by_window.len());
    let outcome = rig.wait_outcome("toolu_1").await;
    let Event::Outcome { by_window: logged, .. } = &outcome.event else { unreachable!() };
    assert!(logged.as_deref().unwrap().len() <= limit);
}

#[tokio::test(start_paused = true)]
async fn f3_a_verified_app_that_never_rendered_approvals_cannot_answer() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    rig.broker.app_connected("operator-only");
    let wire = rig.hold("toolu_1").await;

    let result = rig.broker.answer(&wire.request_id, &allow_once(), "w", "operator-only");

    assert_eq!(result, AnswerResult::NotPresenter);
    assert_eq!(result.refusal().map(|r| r.0), Some(AnswerRefusal::NotOperatorApp));
    assert!(rig.writes().is_empty(), "nothing reached the CLI");
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
    assert_eq!(rig.broker.answer(&wire.request_id, &deny(None), "w", "app"), applied("denied"));
}

#[tokio::test(start_paused = true)]
async fn f5_resubscribing_without_renders_approvals_revokes_presenter_status() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    rig.broker.presenter_connected("app-b");
    let wire = rig.hold("toolu_1").await;

    rig.broker.presenter_revoked("app");

    assert_eq!(rig.broker.answer(&wire.request_id, &allow_once(), "w", "app"), AnswerResult::NotPresenter);
    assert!(rig.broker.has_approval_presenter(), "app-b is still one");

    rig.broker.presenter_revoked("app-b");
    settle().await;
    tokio::time::advance(PRESENTER_GRACE + Duration::from_millis(100)).await;
    let outcome = rig.wait_outcome("toolu_1").await;
    assert_eq!(
        outcome_name(&outcome),
        "approval_unavailable",
        "the last presenter revoking starts the grace (the app is still connected, so not no_app)"
    );
}
