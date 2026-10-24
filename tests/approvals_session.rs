//! Permission prompts end to end through real `SessionManager` sessions.
//!
//! The session is the hermetic fake `claude` of `tests/support/fake_claude_perm.py`
//! (its frames are copied from the real CLI's spike captures), started through a
//! `/bin/sh` wrapper so the manager launches it exactly as it launches `claude`.
//! The broker is the real one over a temp audit directory, with a test presenter
//! standing in for "someone could be asked" (this slice has nobody to ask).
//!
//! What this pins that `tests/approvals_broker.rs` cannot:
//! - which sessions are told to send their prompts to the daemon (the argv);
//! - the exact `control_response` frames the CLI receives;
//! - the daemon's reader never waits on the broker, and answers a prompt itself
//!   when the broker is gone (nothing is left waiting);
//! - stop / restart / new session / exit and shutdown, against a live process;
//! - the note an agent gets after a crash, ahead of its next message.
//!
//! Environment variables are process-wide and tests run on parallel threads, so
//! every test takes `ENV_LOCK` for its whole duration and builds its own paused
//! runtime. The clock only moves when a test calls `tokio::time::advance`.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    restart_note_text, ApprovalBroker, BrokerParts, Incoming, Presenter, SessionInfo, SessionSink,
    APPROVAL_TIMEOUT, APPROVAL_UNAVAILABLE_MESSAGE, INVALID_REQUEST_MESSAGE, RESTART_MESSAGE,
    RESTART_NOTES_FILE, TIMED_OUT_MESSAGE, UNSUPPORTED_REQUEST_ERROR,
};
use nostromo::approvals::guard::{
    self, hook_settings_json, PaneInfo, PaneProbe, ProbeError, TmuxSocket, GUARD_MESSAGE,
};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::session_manager::{
    build_claude_args_with, InterruptOutcome, SessionManager, SessionRestrictions, CLAUDE_BIN_ENV,
};
use nostromo::ipc::stream_json::SessionState;
use serde_json::{json, Value};

// ── fixtures ──────────────────────────────────────────────────────────────────

fn fixture_request(name: &str) -> Value {
    fixture(name)["requests"][0]["request"].clone()
}

/// `request` without its `input` key: what a request entry's `cli_request` holds.
fn without_input(request: &Value) -> Value {
    let mut v = request.clone();
    v.as_object_mut().expect("a request object").remove("input");
    v
}

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("tests/fixtures/approvals/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap()
}

/// Fixtures the broker answers `approval_unavailable` (the guard lets them through).
const ORDINARY: &[&str] = &[
    "simple_rm",
    "compound",
    "heredoc_300",
    "bidi",
    "zero_width",
    "tags",
    "cyrillic",
    "edit",
    "write",
    "notebook_edit",
    "mcp",
    "subagent",
    "flag_default_to_no",
    "flag_matched_ask_rule",
    "flag_requires_user_interaction",
    "flag_suppress_always_allow_rule",
    "safety_check",
    "settings_write",
    "ansi_reason",
    "all_fields",
    "parallel_3",
];

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);
const BARRIER: &str = "barrier";

// ── test doubles ──────────────────────────────────────────────────────────────

struct FakeSink {
    live: AtomicBool,
}

impl SessionSink for FakeSink {
    fn live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn respond(&self, _cli_request_id: &str, _response: &Value) -> std::io::Result<()> {
        Ok(())
    }
}

struct Gate {
    open: Mutex<bool>,
    cv: Condvar,
}

impl Gate {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            open: Mutex::new(false),
            cv: Condvar::new(),
        })
    }

    fn release(&self) {
        *self.open.lock().unwrap() = true;
        self.cv.notify_all();
    }

    fn wait(&self) {
        let guard = self.open.lock().unwrap();
        let _ = self
            .cv
            .wait_timeout_while(guard, Duration::from_secs(60), |open| !*open)
            .unwrap();
    }
}

/// "Can anyone be asked?" (`hold`, changeable mid-test); with a `gate` the answer
/// is withheld until it opens (a stuck broker worker). The barrier tag is always "no".
struct TestPresenter {
    hold: AtomicBool,
    gate: Option<Arc<Gate>>,
    asked: AtomicUsize,
}

impl Presenter for TestPresenter {
    fn can_present(&self, tag: &str) -> bool {
        if tag == BARRIER {
            return false;
        }
        self.asked.fetch_add(1, Ordering::SeqCst);
        if let Some(gate) = &self.gate {
            gate.wait();
        }
        self.hold.load(Ordering::SeqCst)
    }
}

struct FakeProbe {
    pane_9: Option<String>,
}

impl PaneProbe for FakeProbe {
    fn pane(&self, _socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        Ok(self
            .pane_9
            .clone()
            .filter(|_| target == "%9")
            .map(|title| PaneInfo { pid: 4242, title }))
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

// ── the world a test runs in ──────────────────────────────────────────────────

#[derive(Default)]
struct Opts {
    hold: bool,
    gate: Option<Arc<Gate>>,
    pane_9: Option<String>,
    /// Entries already in the audit store when the daemon "starts".
    seed: Vec<Entry>,
}

/// A manager that kills every fake it started when it goes out of scope, a failed
/// assertion included (a fake holding its stdin open would keep the test run from ending).
struct Mgr(SessionManager);

impl std::ops::Deref for Mgr {
    type Target = SessionManager;
    fn deref(&self) -> &SessionManager {
        &self.0
    }
}

impl std::ops::DerefMut for Mgr {
    fn deref_mut(&mut self) -> &mut SessionManager {
        &mut self.0
    }
}

impl Drop for Mgr {
    fn drop(&mut self) {
        self.0.kill_all_on_shutdown();
    }
}

struct World {
    mgr: Mgr,
    broker: ApprovalBroker,
    presenter: Arc<TestPresenter>,
    tmp: tempfile::TempDir,
    spawns: usize,
    barriers: usize,
    barrier_generation: u64,
}

/// What one fake process leaves behind.
struct Fake {
    dir: PathBuf,
    session_id: String,
}

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Run `body` in a fresh world on a paused-clock runtime, with the environment this
/// file's tests share. Serialized: the environment is process-wide.
fn run<Fut: Future<Output = ()>>(opts: Opts, body: impl FnOnce(World) -> Fut) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    rt.block_on(async move {
        let world = World::new(opts);
        body(world).await;
    });
}

fn session(tag: &str) -> SessionInfo {
    SessionInfo {
        tag: tag.into(),
        agent: "cody".into(),
        session_id: Some(format!("sid-{tag}")),
        cwd: Some(PathBuf::from("/work")),
        guarded: true,
    }
}

impl World {
    fn new(opts: Opts) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let approvals_dir = tmp.path().join("approvals");
        std::env::set_var("HOME", &home);
        std::env::set_var(nostromo::approvals::APPROVALS_DIR_ENV, &approvals_dir);
        std::env::set_var(guard::GUARD_BIN_ENV, env!("CARGO_BIN_EXE_nostromo-guard"));

        let log = AuditLog::open(&approvals_dir).unwrap();
        for entry in &opts.seed {
            log.append(entry).unwrap();
        }
        let presenter = Arc::new(TestPresenter {
            hold: AtomicBool::new(opts.hold),
            gate: opts.gate,
            asked: AtomicUsize::new(0),
        });
        let pane_9 = opts.pane_9;
        let broker = ApprovalBroker::new(
            log,
            BrokerParts {
                presenters: Default::default(),
                presenter: presenter.clone(),
                probe: Arc::new(move || {
                    Box::new(FakeProbe {
                        pane_9: pane_9.clone(),
                    })
                }),
                settings: Arc::new(NoRules),
                timeout: APPROVAL_TIMEOUT,
            },
        );
        let barrier_generation = broker.register_session(
            session(BARRIER),
            Arc::new(FakeSink {
                live: AtomicBool::new(true),
            }),
        );
        let mut mgr = SessionManager::with_store_path(tmp.path().join("daemon-sessions.json"));
        mgr.configure_approvals(broker.clone());
        Self {
            mgr: Mgr(mgr),
            broker,
            presenter,
            tmp,
            spawns: 0,
            barriers: 0,
            barrier_generation,
        }
    }

    /// Start a session of the fake CLI under `tag`.
    fn spawn(&mut self, tag: &str, remote_control: bool) -> Fake {
        self.spawns += 1;
        let dir = self.tmp.path().join(format!("fake-{}", self.spawns));
        std::fs::create_dir_all(&dir).unwrap();
        let wrapper = dir.join("claude");
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
                dir.display()
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
        let work = self.tmp.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let session_id = self
            .mgr
            .spawn_session(
                tag.into(),
                "cody".into(),
                format!("view-{tag}"),
                Some(work),
                None,
                remote_control,
            )
            .expect("the session starts")
            .expect("a session id");
        Fake { dir, session_id }
    }

    fn say(&mut self, tag: &str, text: &str) {
        self.mgr
            .send_user_message(tag, text, &[])
            .expect("the message is accepted");
    }

    fn state(&self, tag: &str) -> SessionState {
        self.mgr
            .list()
            .into_iter()
            .find(|s| s.tag == tag)
            .map(|s| s.state)
            .expect("a known session")
    }

    async fn wait_idle(&self, tag: &str) {
        wait_until(&format!("{tag} to go idle"), || {
            (self.state(tag) == SessionState::Idle).then_some(())
        })
        .await;
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    /// Entries of real requests (not the barrier's).
    fn real_entries(&self) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| {
                !e.tool_use_id
                    .as_deref()
                    .unwrap_or("")
                    .starts_with("barrier-")
            })
            .collect()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| {
                matches!(e.event, Event::Outcome { .. })
                    && e.tool_use_id.as_deref() == Some(tool_use_id)
            })
            .collect()
    }

    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.outcomes(tool_use_id).into_iter().next()
        })
        .await
    }

    /// Returns once every job the broker's worker had queued before the call is done.
    async fn barrier(&mut self) {
        self.barriers += 1;
        let id = format!("barrier-{}", self.barriers);
        let accepted = self.broker.submit(Incoming::Request {
            tag: BARRIER.into(),
            generation: self.barrier_generation,
            cli_request_id: id.clone(),
            value: json!({ "tool_name": "Bash", "input": { "command": "ls" }, "tool_use_id": id }),
        });
        assert!(accepted.is_ok());
        self.wait_outcome(&id).await;
    }

    async fn run_out_the_clock(&mut self) {
        tokio::time::advance(APPROVAL_TIMEOUT + Duration::from_secs(120)).await;
        settle().await;
        self.barrier().await;
    }
}

impl Fake {
    fn read_lines(&self, file: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join(file))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{file}: {e}: {l}")))
            .collect()
    }

    /// Every answer the fake received, as `{request_id, tool_use_id, response: <frame>}`.
    fn responses(&self) -> Vec<Value> {
        self.read_lines("responses.jsonl")
    }

    /// Every line the daemon wrote to the fake's stdin.
    fn stdin(&self) -> Vec<Value> {
        self.read_lines("stdin.jsonl")
    }

    /// The text of every user message the fake received.
    fn user_texts(&self) -> Vec<String> {
        self.stdin()
            .iter()
            .filter(|f| f["type"] == "user")
            .map(|f| {
                f["message"]["content"]
                    .as_str()
                    .expect("plain-text message")
                    .to_owned()
            })
            .collect()
    }

    async fn argv(&self) -> Vec<String> {
        wait_until("the fake to record its argv", || {
            let text = std::fs::read_to_string(self.dir.join("argv.json")).ok()?;
            serde_json::from_str::<Vec<String>>(&text).ok()
        })
        .await
    }

    async fn wait_responses(&self, n: usize) -> Vec<Value> {
        wait_until(&format!("{n} answer(s) to reach the fake"), || {
            let r = self.responses();
            (r.len() >= n).then_some(r)
        })
        .await
    }

    /// T-AP0a-1: nothing the daemon ever wrote to the CLI is an allow.
    #[track_caller]
    fn assert_never_allowed(&self) {
        let raw = std::fs::read_to_string(self.dir.join("stdin.jsonl")).unwrap_or_default();
        for frame in self
            .stdin()
            .iter()
            .filter(|f| f["type"] == "control_response")
        {
            if frame["response"]["subtype"] == "error" {
                // The answer to a control request that is not a permission prompt:
                // an error, which carries no behavior at all.
                assert!(!frame.to_string().contains("behavior"), "{frame}");
                continue;
            }
            assert_eq!(frame["response"]["response"]["behavior"], "deny", "{frame}");
            assert!(
                frame["response"]["response"].get("updatedInput").is_none(),
                "{frame}"
            );
        }
        assert!(
            !raw.contains("\"behavior\":\"allow\"") && !raw.contains("\"behavior\": \"allow\""),
            "{raw}"
        );
    }
}

fn everything() -> std::ops::Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(5));
        tokio::task::yield_now().await;
    }
}

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

fn outcome_rule(e: &Entry) -> Option<Value> {
    match &e.event {
        Event::Outcome { rule, .. } => rule.clone(),
        other => panic!("not an outcome: {other:?}"),
    }
}

fn is_request(e: &Entry) -> bool {
    matches!(e.event, Event::Request { .. })
}

fn is_outcome(e: &Entry) -> bool {
    matches!(e.event, Event::Outcome { .. })
}

/// The frame the CLI must receive to be told no, with `message`.
fn deny_frame(cli_request_id: &str, message: &str) -> Value {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": cli_request_id,
            "response": { "behavior": "deny", "message": message }
        }
    })
}

/// `cli_request_id` of an answer line the fake recorded.
fn answered_id(line: &Value) -> &str {
    line["request_id"]
        .as_str()
        .expect("the fake records which request an answer was for")
}

// ── PRD 1: which sessions send their prompts to the daemon ────────────────────

#[test]
fn an_approval_capable_session_is_started_with_the_permission_prompt_flag_right_after_the_guard_settings(
) {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn("focus-1", false);

        let argv = fake.argv().await;

        let guard_settings = hook_settings_json(w.mgr.guard_path());
        assert_eq!(
            w.mgr.guard_path(),
            Path::new(env!("CARGO_BIN_EXE_nostromo-guard"))
        );
        let at = argv
            .iter()
            .position(|a| a == "--settings")
            .expect("the guard's --settings");
        assert_eq!(argv[at + 1], guard_settings);
        assert_eq!(
            (argv[at + 2].as_str(), argv[at + 3].as_str()),
            ("--permission-prompt-tool", "stdio"),
            "the prompt flag comes immediately after the guard settings element: {argv:?}"
        );
        assert_eq!(
            argv.iter()
                .filter(|a| *a == "--permission-prompt-tool")
                .count(),
            1,
            "{argv:?}"
        );
        assert!(
            argv.iter().any(|a| a == "--dangerously-skip-permissions"),
            "{argv:?}"
        );
    });
}

#[test]
fn a_restricted_session_keeps_the_arguments_it_had_and_never_sends_prompts_to_the_daemon() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let restrictions = SessionRestrictions {
                builtin_tools: vec!["Read".into()],
                allowed_tools: vec!["Read".into()],
                max_budget_usd: Some(1.5),
            };
            w.mgr.restrict_tag("restricted-1", restrictions.clone());
            let fake = w.spawn("restricted-1", false);

            let argv = fake.argv().await;

            let guard_settings = hook_settings_json(w.mgr.guard_path());
            let expected = build_claude_args_with(
                "cody",
                "view-restricted-1",
                false,
                &fake.session_id,
                false,
                Some(&restrictions),
                &guard_settings,
            );
            assert_eq!(
                argv, expected,
                "the restricted vector is exactly what it is without approvals"
            );
            assert!(
                !argv.iter().any(|a| a == "--permission-prompt-tool"),
                "{argv:?}"
            );

            // A cue the unrestricted CLI would turn into a prompt: this CLI just refuses, and asks no one.
            w.say("restricted-1", "FIXTURE:simple_rm");
            w.wait_idle("restricted-1").await;
            settle().await;

            assert!(
                w.entries().is_empty(),
                "no broker activity at all: {:?}",
                w.entries()
            );
            assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);
            let stdin = fake.stdin();
            assert!(
                stdin.iter().all(|f| f["type"] == "user"),
                "nothing but user messages was written to it: {stdin:?}"
            );
            assert_eq!(stdin.len(), 1);
            assert!(fake.responses().is_empty());
        },
    );
}

#[test]
fn a_remote_control_session_is_not_approval_capable() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("remote-1", true);

            let argv = fake.argv().await;

            assert!(argv.iter().any(|a| a == "--remote-control"), "{argv:?}");
            assert!(
                !argv.iter().any(|a| a == "--permission-prompt-tool"),
                "{argv:?}"
            );
            w.say("remote-1", "FIXTURE:simple_rm");
            w.wait_idle("remote-1").await;
            settle().await;
            assert!(w.entries().is_empty(), "{:?}", w.entries());
            assert!(fake.responses().is_empty());
        },
    );
}

// ── PRD 1 + 3: every prompt is answered, recorded, and denied before the clock moves ──

#[test]
fn every_ordinary_prompt_is_denied_approval_unavailable_with_exactly_one_response_and_one_logged_outcome(
) {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn("focus-1", false);
        let start = tokio::time::Instant::now();
        let mut expected_requests = Vec::new();

        for name in ORDINARY {
            let requests: Vec<Value> = fixture(name)["requests"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["request"].clone())
                .collect();
            expected_requests.extend(requests.iter().cloned().map(|r| (name.to_string(), r)));
            w.say("focus-1", &format!("FIXTURE:{name}"));
            fake.wait_responses(expected_requests.len()).await;
        }
        w.wait_idle("focus-1").await;

        assert_eq!(
            tokio::time::Instant::now(),
            start,
            "every denial happened before the clock moved at all"
        );
        let responses = fake.responses();
        assert_eq!(
            responses.len(),
            expected_requests.len(),
            "exactly one response per request"
        );
        for line in &responses {
            assert_eq!(
                line["response"],
                deny_frame(answered_id(line), APPROVAL_UNAVAILABLE_MESSAGE),
                "the CLI is told no, in the contract's wrapper and this slice's words"
            );
        }
        let entries = w.entries();
        for (name, request) in &expected_requests {
            let id = request["tool_use_id"].as_str().unwrap();
            let answers: Vec<&Value> = responses
                .iter()
                .filter(|l| l["tool_use_id"] == id)
                .collect();
            assert_eq!(answers.len(), 1, "{name}/{id}: one response");
            let requests: Vec<&Entry> = entries
                .iter()
                .filter(|e| is_request(e) && e.tool_use_id.as_deref() == Some(id))
                .collect();
            let outcomes: Vec<&Entry> = entries
                .iter()
                .filter(|e| is_outcome(e) && e.tool_use_id.as_deref() == Some(id))
                .collect();
            assert_eq!(
                (requests.len(), outcomes.len()),
                (1, 1),
                "{name}/{id}: one request entry, one outcome entry"
            );
            assert_eq!(
                outcome_name(outcomes[0]),
                "approval_unavailable",
                "{name}/{id}"
            );
            assert_eq!(
                requests[0].request_id, outcomes[0].request_id,
                "{name}/{id}: the same request"
            );
            for e in [requests[0], outcomes[0]] {
                assert_eq!(e.tag.as_deref(), Some("focus-1"), "{name}");
                assert_eq!(
                    e.session_id.as_deref(),
                    Some(fake.session_id.as_str()),
                    "{name}"
                );
                assert_eq!(e.agent.as_deref(), Some("cody"), "{name}");
                let sub = e.subagent.as_ref().map(|s| s["agent_id"].clone());
                assert_eq!(
                    sub,
                    (*name == "subagent" || *name == "all_fields").then(|| json!("agent_abc123")),
                    "{name}"
                );
            }
            let Event::Request {
                cli_request,
                tool_name,
                input,
                ..
            } = &requests[0].event
            else {
                unreachable!()
            };
            assert_eq!(
                cli_request.as_ref(),
                Some(&without_input(request)),
                "{name}: every field the CLI sent, as received, but the input (the entry's own `input` holds it, once)"
            );
            assert_eq!(
                Some(tool_name.as_str()),
                request["tool_name"].as_str(),
                "{name}"
            );
            assert_eq!(input, &request["input"], "{name}");
        }
        assert_eq!(
            entries
                .iter()
                .filter(|e| is_outcome(e)
                    && e.tool_use_id
                        .as_deref()
                        .is_some_and(|i| !i.starts_with("barrier-")))
                .count(),
            expected_requests.len()
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn the_logged_flags_and_reason_of_a_session_request_are_typed_correctly() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn("focus-1", false);
        let cases = [
            (
                "all_fields",
                json!({"default_to_no": true, "suppress_always_allow_rule": true, "requires_user_interaction": true, "classifier_approvable": true}),
                "ask_rule",
            ),
            (
                "flag_default_to_no",
                json!({"default_to_no": true, "suppress_always_allow_rule": false, "requires_user_interaction": false, "classifier_approvable": false}),
                "ask_rule",
            ),
            (
                "flag_suppress_always_allow_rule",
                json!({"default_to_no": false, "suppress_always_allow_rule": true, "requires_user_interaction": false, "classifier_approvable": false}),
                "ask_rule",
            ),
            (
                "flag_requires_user_interaction",
                json!({"default_to_no": false, "suppress_always_allow_rule": false, "requires_user_interaction": true, "classifier_approvable": false}),
                "ask_rule",
            ),
            (
                "safety_check",
                json!({"default_to_no": false, "suppress_always_allow_rule": false, "requires_user_interaction": false, "classifier_approvable": false}),
                "safety_check",
            ),
        ];
        for (i, (name, flags, reason_kind)) in cases.iter().enumerate() {
            w.say("focus-1", &format!("FIXTURE:{name}"));
            fake.wait_responses(i + 1).await;
            let id = fixture_request(name)["tool_use_id"]
                .as_str()
                .unwrap()
                .to_owned();
            w.wait_outcome(&id).await;
            let entries = w.entries();
            let request = entries
                .iter()
                .find(|e| is_request(e) && e.tool_use_id.as_deref() == Some(&id))
                .unwrap();
            let Event::Request {
                flags: logged,
                reason,
                ..
            } = &request.event
            else {
                unreachable!()
            };
            assert_eq!(logged.as_ref(), Some(flags), "{name}");
            assert_eq!(
                reason.as_ref().map(|r| r["kind"].clone()),
                Some(json!(reason_kind)),
                "{name}"
            );
        }
        fake.assert_never_allowed();
    });
}

// ── PRD 2: no prompt, no broker ───────────────────────────────────────────────

#[test]
fn a_call_that_runs_without_asking_causes_no_broker_activity() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);

            w.say("focus-1", "please runs_freely");
            w.wait_idle("focus-1").await;
            settle().await;

            assert!(
                w.entries().is_empty(),
                "no audit entries: {:?}",
                w.entries()
            );
            assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);
            assert!(fake.responses().is_empty());
            assert!(
                fake.stdin().iter().all(|f| f["type"] == "user"),
                "{:?}",
                fake.stdin()
            );
        },
    );
}

// ── other control requests: answered with an error, nothing breaks (T-AP0a-4, N3) ──

#[test]
fn control_requests_that_are_not_permission_prompts_get_one_error_answer_and_nothing_breaks() {
    // Spec change (PR #270 review N3): these used to be left unanswered; the CLI
    // would wait for them forever. Now each gets one `error` control_response.
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn("focus-1", false);

        w.say("focus-1", "FIXTURE:non_can_use_tool");
        let responses = fake.wait_responses(1).await;
        w.wait_idle("focus-1").await;
        settle().await;

        assert_eq!(
            responses[0]["tool_use_id"], "toolu_non_can_use_tool_0",
            "the answer carries the very id the CLI sent"
        );
        let frame = &responses[0]["response"];
        assert_eq!(frame["type"], "control_response");
        assert_eq!(frame["response"]["subtype"], "error");
        assert_eq!(
            frame["response"]["request_id"], responses[0]["request_id"],
            "{frame}"
        );
        assert_eq!(frame["response"]["error"], UNSUPPORTED_REQUEST_ERROR);
        assert!(
            !frame.to_string().contains("behavior"),
            "an error carries no behavior: {frame}"
        );
        assert_eq!(
            fake.responses().len(),
            1,
            "one answer, not one per retry or per line"
        );
        assert!(
            w.entries().is_empty(),
            "no audit entries: {:?}",
            w.entries()
        );
        assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);

        // The session carries on: a real prompt after it is answered as usual.
        w.say("focus-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(2).await;
        assert_eq!(
            responses[1]["response"],
            deny_frame(answered_id(&responses[1]), APPROVAL_UNAVAILABLE_MESSAGE)
        );
        fake.assert_never_allowed();
    });
}

// ── the guard before anyone is asked ──────────────────────────────────────────

#[test]
fn the_guard_blocks_production_shell_prompts_before_anyone_is_asked_even_when_someone_could_be() {
    run(
        Opts {
            hold: true,
            pane_9: Some("production:portal:web".into()),
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);

            w.say("focus-1", "FIXTURE:guard_ecs_connect");
            w.say("focus-1", "FIXTURE:guard_send_keys");
            let responses = fake.wait_responses(2).await;

            for line in &responses {
                assert_eq!(
                    line["response"],
                    deny_frame(answered_id(line), GUARD_MESSAGE)
                );
            }
            for (name, rule_id) in [
                ("guard_ecs_connect", guard::RULE_COMMAND),
                ("guard_send_keys", guard::RULE_TMUX_INPUT),
            ] {
                let id = fixture_request(name)["tool_use_id"]
                    .as_str()
                    .unwrap()
                    .to_owned();
                let outcome = w.wait_outcome(&id).await;
                assert_eq!(outcome_name(&outcome), "guard_blocked", "{name}");
                let rule = outcome_rule(&outcome)
                    .expect("the guard rule is recorded")
                    .to_string();
                assert!(rule.contains(rule_id), "{name}: {rule}");
                assert_eq!(w.outcomes(&id).len(), 1, "{name}");
            }
            assert_eq!(
                w.presenter.asked.load(Ordering::SeqCst),
                0,
                "nobody was asked about either"
            );
            fake.assert_never_allowed();
        },
    );
}

// ── a request that cannot be read ─────────────────────────────────────────────

#[test]
fn a_prompt_the_broker_cannot_read_is_denied_as_invalid_and_the_session_carries_on() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);

            w.say("focus-1", "FIXTURE:malformed");
            let responses = fake.wait_responses(1).await;

            assert_eq!(
                responses[0]["response"],
                deny_frame(answered_id(&responses[0]), INVALID_REQUEST_MESSAGE)
            );
            let outcome =
                wait_until("the outcome", || w.entries().into_iter().find(is_outcome)).await;
            assert_eq!(outcome_name(&outcome), "invalid_request");
            let entries = w.entries();
            let requests: Vec<&Entry> = entries.iter().filter(|e| is_request(e)).collect();
            assert_eq!(requests.len(), 1);
            let Event::Request { cli_request, .. } = &requests[0].event else {
                unreachable!()
            };
            assert_eq!(
                cli_request.as_ref(),
                Some(&without_input(&fixture_request("malformed")))
            );
            assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);
            fake.assert_never_allowed();

            w.presenter.hold.store(false, Ordering::SeqCst);
            w.say("focus-1", "FIXTURE:simple_rm");
            let responses = fake.wait_responses(2).await;
            assert_eq!(
                responses[1]["response"],
                deny_frame(answered_id(&responses[1]), APPROVAL_UNAVAILABLE_MESSAGE)
            );
        },
    );
}

// ── the CLI withdraws a request (PRD 6) ───────────────────────────────────────

#[test]
fn a_prompt_the_cli_withdraws_ends_withdrawn_and_no_answer_is_written_for_it() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            let start = tokio::time::Instant::now();

            w.say("focus-1", "CANCEL:cancel");
            let outcome = w.wait_outcome("toolu_cancel_0").await;
            w.wait_idle("focus-1").await;
            settle().await;

            assert_eq!(outcome_name(&outcome), "withdrawn");
            assert_eq!(
                tokio::time::Instant::now(),
                start,
                "without the clock moving"
            );
            assert!(
                fake.responses().is_empty(),
                "the CLI cancelled it: no control_response was written"
            );
            assert!(
                fake.stdin().iter().all(|f| f["type"] == "user"),
                "{:?}",
                fake.stdin()
            );
            let entries = w.entries();
            assert_eq!(entries.iter().filter(|e| is_request(e)).count(), 1);
            assert_eq!(w.outcomes("toolu_cancel_0").len(), 1);
            fake.assert_never_allowed();
        },
    );
}

#[test]
fn a_prompt_withdrawn_the_instant_it_arrives_is_still_ended_exactly_once_when_nobody_can_be_asked()
{
    // With nobody to ask, the broker answers at once, so a withdrawal right behind the
    // prompt can find it already denied. What must hold either way: one ending, never an allow.
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn("focus-1", false);

        w.say("focus-1", "CANCEL:cancel");
        w.wait_outcome("toolu_cancel_0").await;
        w.wait_idle("focus-1").await;
        w.barrier().await;
        settle().await;

        let outcomes = w.outcomes("toolu_cancel_0");
        assert_eq!(outcomes.len(), 1, "exactly one outcome: {outcomes:?}");
        assert!(
            ["approval_unavailable", "withdrawn"].contains(&outcome_name(&outcomes[0])),
            "{}",
            outcome_name(&outcomes[0])
        );
        assert!(fake.responses().len() <= 1);
        if outcome_name(&outcomes[0]) == "withdrawn" {
            assert!(fake.responses().is_empty());
        }
        fake.assert_never_allowed();
    });
}

#[test]
fn interrupting_a_turn_withdraws_every_held_prompt_and_writes_nothing() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            w.say("focus-1", "FIXTURE:parallel_3");
            wait_until("three prompts to be asked about", || {
                (w.presenter.asked.load(Ordering::SeqCst) == 3).then_some(())
            })
            .await;
            w.barrier().await;
            assert_eq!(
                w.state("focus-1"),
                SessionState::MidTurn,
                "the turn is waiting on the three prompts"
            );

            assert_eq!(
                w.mgr.interrupt("focus-1").unwrap(),
                InterruptOutcome::Requested
            );

            for i in 0..3 {
                let outcome = w.wait_outcome(&format!("toolu_parallel_3_{i}")).await;
                assert_eq!(outcome_name(&outcome), "withdrawn", "{i}");
            }
            w.wait_idle("focus-1").await;
            assert!(
                fake.responses().is_empty(),
                "the CLI withdrew them: nothing was answered"
            );
            fake.assert_never_allowed();
        },
    );
}

// ── T-AP0a-4: the reader never waits on the broker ────────────────────────────

#[test]
fn the_sessions_other_frames_keep_flowing_while_the_broker_is_stuck_on_its_prompts() {
    let gate = Gate::new();
    run(
        Opts {
            hold: true,
            gate: Some(gate.clone()),
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ServerMsg>();
            w.mgr
                .client_sender_registry()
                .lock()
                .unwrap()
                .insert("c1".into(), tx);
            w.mgr.attach("focus-1", "c1").unwrap();

            // Three prompts arrive; the broker's worker is stuck inside the first one.
            w.say("focus-1", "FIXTURE:parallel_3");
            wait_until("the broker to be stuck on the first prompt", || {
                (w.presenter.asked.load(Ordering::SeqCst) == 1).then_some(())
            })
            .await;

            // The CLI goes on talking: an interrupt makes it withdraw the prompts, refuse the
            // calls and end the turn. A client of the daemon must see all of that happen.
            assert_eq!(
                w.mgr.interrupt("focus-1").unwrap(),
                InterruptOutcome::Requested
            );
            let mut saw_delta = false;
            let mut saw_idle = false;
            wait_until(
                "the turn to end for an attached client while the broker is stuck",
                || {
                    while let Ok(msg) = rx.try_recv() {
                        match msg {
                            ServerMsg::SessionTurnDelta { .. } => saw_delta = true,
                            ServerMsg::SessionState {
                                state: SessionState::Idle,
                                ..
                            } => saw_idle = true,
                            _ => {}
                        }
                    }
                    (saw_delta && saw_idle).then_some(())
                },
            )
            .await;
            assert_eq!(
                w.presenter.asked.load(Ordering::SeqCst),
                1,
                "and the broker really was still stuck"
            );
            assert!(
                w.entries().iter().filter(|e| is_outcome(e)).count() == 0,
                "no prompt had been dealt with yet"
            );

            // Let the broker go: the withdrawals that queued up behind the prompts are applied.
            gate.release();
            for i in 0..3 {
                let outcome = w.wait_outcome(&format!("toolu_parallel_3_{i}")).await;
                assert_eq!(outcome_name(&outcome), "withdrawn", "{i}");
            }
            assert!(fake.responses().is_empty());
            fake.assert_never_allowed();
        },
    );
}

// ── PRD 4: clean shutdown ─────────────────────────────────────────────────────

#[test]
fn a_clean_shutdown_tells_the_agent_each_pending_prompt_was_not_approved_before_the_process_is_killed(
) {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            w.say("focus-1", "FIXTURE:parallel_3");
            wait_until("three prompts to be held", || {
                (w.presenter.asked.load(Ordering::SeqCst) == 3).then_some(())
            })
            .await;
            w.barrier().await;
            assert!(fake.responses().is_empty(), "held: nothing answered yet");

            let started = Instant::now();
            w.mgr.prepare_shutdown(Duration::from_secs(2));
            let took = started.elapsed();

            assert!(took < Duration::from_secs(2), "the daemon waits for the CLI to act on the denies, not for the full timeout: {took:?}");
            let responses = fake.responses();
            assert_eq!(
                responses.len(),
                3,
                "all three denies reached the CLI before it was killed"
            );
            for line in &responses {
                assert_eq!(
                    line["response"],
                    deny_frame(answered_id(line), RESTART_MESSAGE)
                );
            }
            let mut told: Vec<&str> = responses
                .iter()
                .filter_map(|l| l["tool_use_id"].as_str())
                .collect();
            told.sort();
            assert_eq!(
                told,
                [
                    "toolu_parallel_3_0",
                    "toolu_parallel_3_1",
                    "toolu_parallel_3_2"
                ]
            );
            for i in 0..3 {
                let outcomes = w.outcomes(&format!("toolu_parallel_3_{i}"));
                assert_eq!(outcomes.len(), 1, "{i}");
                assert_eq!(outcome_name(&outcomes[0]), "restart", "{i}");
            }
            assert_eq!(
                RESTART_MESSAGE,
                "Nostromo restarted before anyone answered; this was not approved."
            );

            // A prompt that arrives after shutdown began is denied the same way.
            w.wait_idle("focus-1").await;
            w.say("focus-1", "FIXTURE:subagent");
            let responses = fake.wait_responses(4).await;
            assert_eq!(
                responses[3]["response"],
                deny_frame(answered_id(&responses[3]), RESTART_MESSAGE)
            );
            assert_eq!(
                outcome_name(&w.wait_outcome("toolu_subagent_0").await),
                "restart"
            );

            w.mgr.kill_all_on_shutdown();
            settle().await;
            let outcomes: Vec<Entry> = w.real_entries().into_iter().filter(is_outcome).collect();
            assert_eq!(
                outcomes.len(),
                4,
                "the kill added no ending of its own: {outcomes:?}"
            );
            assert!(outcomes.iter().all(|o| outcome_name(o) == "restart"));
            fake.assert_never_allowed();
        },
    );
}

#[test]
fn a_shutdown_with_nothing_pending_returns_at_once() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            w.spawn("focus-1", false);
            let started = Instant::now();

            w.mgr.prepare_shutdown(Duration::from_secs(2));

            assert!(
                started.elapsed() < Duration::from_millis(500),
                "{:?}",
                started.elapsed()
            );
        },
    );
}

// ── timeout against a live process ────────────────────────────────────────────

#[test]
fn an_unanswered_prompt_is_denied_after_fifteen_minutes_in_the_contract_s_words() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            w.say("focus-1", "FIXTURE:simple_rm");
            wait_until("the prompt to be held", || {
                (w.presenter.asked.load(Ordering::SeqCst) == 1).then_some(())
            })
            .await;
            w.barrier().await;
            settle().await;
            assert!(fake.responses().is_empty());

            tokio::time::advance(APPROVAL_TIMEOUT).await;
            let responses = fake.wait_responses(1).await;

            assert_eq!(
                responses[0]["response"],
                deny_frame(answered_id(&responses[0]), TIMED_OUT_MESSAGE)
            );
            assert_eq!(
                outcome_name(&w.wait_outcome("toolu_simple_rm_0").await),
                "timed_out"
            );
            w.run_out_the_clock().await;
            assert_eq!(fake.responses().len(), 1, "a late timer adds nothing");
            assert_eq!(w.outcomes("toolu_simple_rm_0").len(), 1);
            fake.assert_never_allowed();
        },
    );
}

// ── T-AP0a-2: never a word to a process that is gone or replaced ──────────────

/// A prompt is held; `end` ends the session some way; the prompt ends `cancelled` and nothing is written.
async fn held_prompt_ends_cancelled(w: &mut World, fake: &Fake, end: impl FnOnce(&mut World)) {
    w.say("focus-1", "FIXTURE:simple_rm");
    wait_until("the prompt to be held", || {
        (w.presenter.asked.load(Ordering::SeqCst) == 1).then_some(())
    })
    .await;
    w.barrier().await;
    settle().await;

    end(w);

    let outcome = w.wait_outcome("toolu_simple_rm_0").await;
    assert_eq!(outcome_name(&outcome), "cancelled");
    assert!(
        fake.responses().is_empty(),
        "nothing was written to the CLI: {:?}",
        fake.responses()
    );
    w.run_out_the_clock().await;
    assert_eq!(
        w.outcomes("toolu_simple_rm_0").len(),
        1,
        "a late timer or watchdog adds no second ending"
    );
    assert!(fake.responses().is_empty());
    fake.assert_never_allowed();
}

#[test]
fn stopping_a_session_with_a_held_prompt_ends_it_cancelled_without_a_write() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            held_prompt_ends_cancelled(&mut w, &fake, |w| w.mgr.stop("focus-1")).await;
        },
    );
}

#[test]
fn starting_a_fresh_conversation_with_a_held_prompt_ends_it_cancelled_without_a_write() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            held_prompt_ends_cancelled(&mut w, &fake, |w| w.mgr.new_session("focus-1")).await;
        },
    );
}

#[test]
fn a_process_that_exits_with_a_held_prompt_ends_it_cancelled_without_a_write() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            // The reader finds EOF and tells the broker.
            held_prompt_ends_cancelled(&mut w, &fake, |w| w.mgr.kill_all_on_shutdown()).await;
        },
    );
}

#[test]
fn restarting_a_session_cancels_its_held_prompt_and_the_new_process_never_hears_about_it() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            w.say("focus-1", "FIXTURE:simple_rm");
            wait_until("the prompt to be held", || {
                (w.presenter.asked.load(Ordering::SeqCst) == 1).then_some(())
            })
            .await;
            w.barrier().await;
            settle().await;

            w.mgr.restart("focus-1").expect("restart");

            let outcome = w.wait_outcome("toolu_simple_rm_0").await;
            assert_eq!(outcome_name(&outcome), "cancelled");
            assert!(
                fake.responses().is_empty(),
                "nothing written to the old process, or to the new one"
            );

            // The new process is a new generation: it can be asked and answered normally.
            w.presenter.hold.store(false, Ordering::SeqCst);
            w.say("focus-1", "FIXTURE:subagent");
            let responses = fake.wait_responses(1).await;
            assert_eq!(responses[0]["tool_use_id"], "toolu_subagent_0");
            assert_eq!(
                responses[0]["response"],
                deny_frame(answered_id(&responses[0]), APPROVAL_UNAVAILABLE_MESSAGE)
            );
            w.run_out_the_clock().await;
            let responses = fake.responses();
            assert_eq!(
                responses.len(),
                1,
                "the old prompt was never answered into the new pipe: {responses:?}"
            );
            assert_eq!(w.outcomes("toolu_simple_rm_0").len(), 1);
            assert_eq!(w.outcomes("toolu_subagent_0").len(), 1);
            fake.assert_never_allowed();
        },
    );
}

// ── the broker is gone: the reader answers for itself ─────────────────────────

#[test]
fn when_the_broker_cannot_take_a_prompt_the_reader_denies_it_itself_and_it_is_still_on_record() {
    run(
        Opts {
            hold: true,
            ..Opts::default()
        },
        |mut w| async move {
            let fake = w.spawn("focus-1", false);
            w.broker.stop_worker_for_test();

            w.say("focus-1", "FIXTURE:simple_rm");
            let responses = fake.wait_responses(1).await;

            assert_eq!(
                responses[0]["response"],
                deny_frame(answered_id(&responses[0]), APPROVAL_UNAVAILABLE_MESSAGE),
                "nothing is left waiting"
            );
            let outcome = w.wait_outcome("toolu_simple_rm_0").await;
            assert_eq!(outcome_name(&outcome), "approval_unavailable");
            let entries = w.entries();
            let requests: Vec<&Entry> = entries.iter().filter(|e| is_request(e)).collect();
            assert_eq!(requests.len(), 1, "a request entry exists");
            assert_eq!(requests[0].request_id, outcome.request_id);
            let Event::Request { cli_request, .. } = &requests[0].event else {
                unreachable!()
            };
            assert_eq!(
                cli_request.as_ref(),
                Some(&without_input(&fixture_request("simple_rm")))
            );
            assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);

            // And again: the session keeps being answered, once per prompt.
            w.wait_idle("focus-1").await;
            w.say("focus-1", "FIXTURE:subagent");
            let responses = fake.wait_responses(2).await;
            assert_eq!(
                responses[1]["response"],
                deny_frame(answered_id(&responses[1]), APPROVAL_UNAVAILABLE_MESSAGE)
            );
            w.wait_outcome("toolu_subagent_0").await;
            assert_eq!(w.entries().iter().filter(|e| is_outcome(e)).count(), 2);
            assert_eq!(fake.responses().len(), 2);
            fake.assert_never_allowed();
        },
    );
}

// ── PRD 5: a crash while a prompt was pending ─────────────────────────────────

fn pending_request(tag: &str, tool: &str) -> Entry {
    let mut e = Entry::new(
        Event::Request {
            tool_name: tool.into(),
            input: json!({ "command": "rm -rf /tmp/x" }),
            display_text: None,
            reason: None,
            flags: None,
            options: None,
            cli_request: None,
        },
        Utc::now() - ChronoDuration::minutes(5),
    );
    e.request_id = Some("req-crashed".into());
    e.tag = Some(tag.into());
    e.tool_use_id = Some("toolu_crashed".into());
    e
}

#[test]
fn after_a_crash_the_agent_is_told_once_what_was_pending_ahead_of_its_next_message() {
    let opts = Opts {
        seed: vec![pending_request("crashed-focus", "Bash")],
        ..Opts::default()
    };
    run(opts, |mut w| async move {
        // The daemon starts: the request left without an ending is closed as a crash.
        assert_eq!(w.broker.startup_reconcile(Utc::now()).unwrap(), 1);
        let outcome = w.wait_outcome("toolu_crashed").await;
        assert_eq!(outcome_name(&outcome), "restart_crash");
        assert_eq!(outcome.request_id.as_deref(), Some("req-crashed"));
        assert!(
            w.tmp
                .path()
                .join("approvals")
                .join(RESTART_NOTES_FILE)
                .exists(),
            "restart-notes.json records the focus"
        );

        let fake = w.spawn("crashed-focus", false);
        w.say("crashed-focus", "carry on please");
        wait_until("the first message to reach the CLI", || {
            (!fake.user_texts().is_empty()).then_some(())
        })
        .await;
        w.wait_idle("crashed-focus").await;
        w.say("crashed-focus", "and another thing");
        wait_until("the second message to reach the CLI", || {
            (fake.user_texts().len() >= 2).then_some(())
        })
        .await;

        let texts = fake.user_texts();
        assert_eq!(
            texts[0],
            "A permission request for Bash was pending when Nostromo restarted. It was not approved.\n\ncarry on please",
            "the note, a blank line, then the message as sent"
        );
        assert_eq!(
            texts[0],
            format!("{}\n\ncarry on please", restart_note_text("Bash"))
        );
        assert_eq!(
            texts[1], "and another thing",
            "only the first message carries it"
        );
        assert_eq!(texts.len(), 2);
        let notes =
            std::fs::read_to_string(w.tmp.path().join("approvals").join(RESTART_NOTES_FILE))
                .unwrap_or_default();
        assert!(
            !notes.contains("crashed-focus"),
            "once told, it is not remembered: {notes:?}"
        );
        assert!(fake.responses().is_empty());
    });
}

#[test]
fn a_focus_with_no_crashed_prompt_gets_its_messages_unchanged() {
    let opts = Opts {
        seed: vec![pending_request("crashed-focus", "Bash")],
        ..Opts::default()
    };
    run(opts, |mut w| async move {
        w.broker.startup_reconcile(Utc::now()).unwrap();
        let fake = w.spawn("other-focus", false);

        w.say("other-focus", "hello there");
        wait_until("the message to reach the CLI", || {
            (!fake.user_texts().is_empty()).then_some(())
        })
        .await;

        assert_eq!(fake.user_texts(), ["hello there"]);
    });
}

#[test]
fn a_message_that_is_only_queued_neither_takes_the_crash_note_nor_carries_it() {
    let opts = Opts {
        hold: true,
        seed: vec![pending_request("crashed-focus", "Bash")],
        ..Opts::default()
    };
    run(opts, |mut w| async move {
        // The session is mid-turn, waiting on a held prompt, when the note comes into being.
        let fake = w.spawn("crashed-focus", false);
        w.say("crashed-focus", "FIXTURE:simple_rm");
        wait_until("the prompt to be held", || {
            (w.presenter.asked.load(Ordering::SeqCst) == 1).then_some(())
        })
        .await;
        w.barrier().await;
        settle().await;
        // (Reconciling mid-run also closes the live held prompt, which has no ending yet; that
        // is an artefact of making the note appear while the session is busy, and is not checked.)
        assert!(w.broker.startup_reconcile(Utc::now()).unwrap() >= 1);
        let note = restart_note_text("Bash");
        assert_eq!(
            w.broker.peek_restart_note("crashed-focus").as_deref(),
            Some(note.as_str())
        );

        // A message sent now can only be queued.
        w.say("crashed-focus", "queued one");
        assert_eq!(
            fake.user_texts(),
            ["FIXTURE:simple_rm"],
            "it was not written: the turn is still running"
        );
        assert_eq!(
            w.broker.peek_restart_note("crashed-focus").as_deref(),
            Some(note.as_str()),
            "and it did not use up the note"
        );

        // The turn ends (the prompt times out); the queued message is written, without the note.
        tokio::time::advance(APPROVAL_TIMEOUT).await;
        let texts = wait_until("the queued message to be written", || {
            let t = fake.user_texts();
            (t.len() >= 2).then_some(t)
        })
        .await;
        assert_eq!(
            texts[1], "queued one",
            "a queued message never carries the note"
        );
        assert_eq!(
            w.broker.peek_restart_note("crashed-focus").as_deref(),
            Some(note.as_str()),
            "still waiting for a message written while idle"
        );

        // The next message written while idle carries it, once.
        w.wait_idle("crashed-focus").await;
        w.say("crashed-focus", "third");
        let texts = wait_until("the third message", || {
            let t = fake.user_texts();
            (t.len() >= 3).then_some(t)
        })
        .await;
        assert_eq!(texts[2], format!("{note}\n\nthird"));
        w.wait_idle("crashed-focus").await;
        w.say("crashed-focus", "fourth");
        let texts = wait_until("the fourth message", || {
            let t = fake.user_texts();
            (t.len() >= 4).then_some(t)
        })
        .await;
        assert_eq!(texts[3], "fourth", "exactly once");
        assert_eq!(w.broker.peek_restart_note("crashed-focus"), None);
        assert_eq!(w.broker.take_restart_note("crashed-focus"), None);
    });
}
