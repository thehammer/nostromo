//! The approval broker (design contract §6): the daemon's one place that hears a
//! session's permission requests, logs them, and always answers them.
//!
//! These tests drive the broker directly, through the same entry points a
//! session's reader uses (`submit`, `on_cancel`, `on_session_gone`), against a
//! fake session sink that records what would have been written to the CLI. The
//! same behaviour through real `SessionManager` sessions and the fake CLI is in
//! `tests/approvals_session.rs`.
//!
//! What they pin:
//! - every request ends exactly once, with the contract's words, and is logged
//!   (a `request` entry and one `outcome` entry);
//! - **nothing ever answers "allow"** (T-AP0a-1): no ending writes one;
//! - nothing is ever written to a session whose process is gone or replaced
//!   (T-AP0a-2);
//! - the guard is consulted before anyone could be asked;
//! - a crash leaves a note for the agent, once.
//!
//! Time: the clock is paused tokio time. The broker's worker is a plain thread,
//! so effects are polled for in real time with a cap; the 15-minute timeout and
//! the 1-second arrival watchdog are driven with `tokio::time::advance`. Polling
//! never parks the runtime, so the paused clock never moves on its own.

use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event, RETENTION_DAYS};
use nostromo::approvals::broker::{
    restart_note_text, ApprovalBroker, BrokerParts, Incoming, Outcome, Presenter, SessionInfo, SessionSink,
    ARRIVAL_WATCHDOG, INVALID_REQUEST_MESSAGE, APPROVAL_UNAVAILABLE_MESSAGE, NO_APP_MESSAGE, APPROVAL_TIMEOUT, RESTART_MESSAGE,
    RESTART_NOTES_FILE, TIMED_OUT_MESSAGE, WATCHDOG_GRACE,
};
use nostromo::approvals::guard::{
    self, PaneInfo, PaneProbe, ProbeError, TmuxSocket, GUARD_MESSAGE,
};
use nostromo::approvals::request::{AskRule, SettingsSource};
use serde_json::{json, Value};

// ── fixtures ──────────────────────────────────────────────────────────────────

fn fixture_request(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("tests/fixtures/approvals/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture["requests"][0]["request"].clone()
}

/// A fixture's request under a tool_use_id of the test's choosing (so several can be told apart).
fn request_as(name: &str, tool_use_id: &str) -> Value {
    let mut v = fixture_request(name);
    v["tool_use_id"] = json!(tool_use_id);
    v
}

/// `request` without its `input` key: what a request entry's `cli_request` holds
/// (the input is recorded once, in the entry's own `input`).
fn without_input(request: &Value) -> Value {
    let mut v = request.clone();
    v.as_object_mut().expect("a request object").remove("input");
    v
}

/// Fixtures whose request is an ordinary prompt that nothing blocks: the broker asks, finds nobody, denies.
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
];

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer.
struct FakeSink {
    live: AtomicBool,
    writes: Mutex<Vec<(String, Value)>>,
}

impl FakeSink {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            live: AtomicBool::new(true),
            writes: Mutex::new(Vec::new()),
        })
    }

    fn die(&self) {
        self.live.store(false, Ordering::SeqCst);
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.writes.lock().unwrap().clone()
    }
}

impl SessionSink for FakeSink {
    fn live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn respond(&self, cli_request_id: &str, response: &Value) -> io::Result<()> {
        self.writes
            .lock()
            .unwrap()
            .push((cli_request_id.to_owned(), response.clone()));
        Ok(())
    }
}

/// Holds threads until the test lets them go (a real-time safety cap keeps a failed test from hanging).
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

const T: &str = "t1";
const BARRIER: &str = "barrier";

/// "Can anyone be asked?": `hold` is the answer; with a `gate` the answer is
/// withheld until the gate opens (a stuck worker). The `barrier` tag is always
/// "no" at once, so a request on it finishes every job queued before it.
struct TestPresenter {
    hold: bool,
    gate: Option<Arc<Gate>>,
    asked: Mutex<Vec<String>>,
    entered: AtomicUsize,
}

impl TestPresenter {
    fn asked(&self, tag: &str) -> usize {
        self.asked
            .lock()
            .unwrap()
            .iter()
            .filter(|t| *t == tag)
            .count()
    }
}

impl Presenter for TestPresenter {
    fn can_present(&self, tag: &str) -> bool {
        if tag == BARRIER {
            return false;
        }
        self.entered.fetch_add(1, Ordering::SeqCst);
        self.asked.lock().unwrap().push(tag.to_owned());
        if let Some(gate) = &self.gate {
            gate.wait();
        }
        self.hold
    }
}

/// tmux and ps as the guard sees them: nothing running, or `%9` is a production pane.
struct FakeProbe {
    /// The title of tmux pane `%9`, if there is one.
    pane_9: Option<String>,
    seen: Arc<Mutex<Vec<String>>>,
}

impl PaneProbe for FakeProbe {
    fn pane(&self, _socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        self.seen.lock().unwrap().push(target.to_owned());
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

/// The user has no ask rules (and nothing here reads the real settings files).
struct NoRules;

impl SettingsSource for NoRules {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        Vec::new()
    }
}

/// No rules either, but the first lookup waits for a gate: the broker's worker is
/// busy before it has even logged the request.
struct SlowSettings(Arc<Gate>);

impl SettingsSource for SlowSettings {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        self.0.wait();
        Vec::new()
    }
}

// ── the rig ───────────────────────────────────────────────────────────────────

struct Opts {
    hold: bool,
    gate: Option<Arc<Gate>>,
    pane_9: Option<String>,
    settings: Arc<dyn SettingsSource>,
    timeout: Duration,
}

impl Default for Opts {
    fn default() -> Self {
        Self {
            hold: false,
            gate: None,
            pane_9: None,
            settings: Arc::new(NoRules),
            timeout: APPROVAL_TIMEOUT,
        }
    }
}

fn holding() -> Opts {
    Opts {
        hold: true,
        ..Opts::default()
    }
}

struct Rig {
    broker: ApprovalBroker,
    presenter: Arc<TestPresenter>,
    sink: Arc<FakeSink>,
    barrier_sink: Arc<FakeSink>,
    probed: Arc<Mutex<Vec<String>>>,
    dir: tempfile::TempDir,
    generation: u64,
    barrier_generation: u64,
    barriers: AtomicUsize,
}

fn session(tag: &str) -> SessionInfo {
    SessionInfo {
        tag: tag.into(),
        agent: "cody".into(),
        session_id: Some(format!("sid-{tag}")),
        cwd: Some(PathBuf::from("/work/proj")),
        guarded: true,
    }
}

impl Rig {
    fn new(opts: Opts) -> Self {
        let dir = tempfile::tempdir().unwrap();
        Self::on_dir(dir, opts)
    }

    fn on_dir(dir: tempfile::TempDir, opts: Opts) -> Self {
        let presenter = Arc::new(TestPresenter {
            hold: opts.hold,
            gate: opts.gate,
            asked: Mutex::new(Vec::new()),
            entered: AtomicUsize::new(0),
        });
        let probed = Arc::new(Mutex::new(Vec::new()));
        let probe_log = Arc::clone(&probed);
        let pane_9 = opts.pane_9;
        let parts = BrokerParts {
            presenters: Default::default(),
            presenter: presenter.clone(),
            probe: Arc::new(move || {
                Box::new(FakeProbe {
                    pane_9: pane_9.clone(),
                    seen: Arc::clone(&probe_log),
                })
            }),
            settings: opts.settings,
            timeout: opts.timeout,
        };
        let broker = ApprovalBroker::new(AuditLog::open(dir.path()).unwrap(), parts);
        let (sink, barrier_sink) = (FakeSink::new(), FakeSink::new());
        let generation = broker.register_session(session(T), sink.clone());
        let barrier_generation = broker.register_session(session(BARRIER), barrier_sink.clone());
        Self {
            broker,
            presenter,
            sink,
            barrier_sink,
            probed,
            dir,
            generation,
            barrier_generation,
            barriers: AtomicUsize::new(0),
        }
    }

    /// Hand the broker a request the way a session's reader does.
    fn submit(&self, cli_request_id: &str, value: Value) {
        self.submit_as(T, self.generation, cli_request_id, value);
    }

    fn submit_as(&self, tag: &str, generation: u64, cli_request_id: &str, value: Value) {
        let accepted = self.broker.submit(Incoming::Request {
            tag: tag.into(),
            generation,
            cli_request_id: cli_request_id.into(),
            value,
        });
        assert!(
            accepted.is_ok(),
            "the broker takes a request without waiting"
        );
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.sink.writes()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        outcomes_for(&self.entries(), tool_use_id)
            .into_iter()
            .cloned()
            .collect()
    }

    /// Wait (real time, capped) until the request carrying `tool_use_id` has an `outcome` entry.
    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.outcomes(tool_use_id).into_iter().next()
        })
        .await
    }

    /// Returns once every job the worker had queued before this call has been done.
    async fn barrier(&self) {
        let n = self.barriers.fetch_add(1, Ordering::SeqCst);
        let id = format!("barrier-{n}");
        self.submit_as(
            BARRIER,
            self.barrier_generation,
            &id,
            request_as("simple_rm", &id),
        );
        self.wait_outcome(&id).await;
    }

    /// Let the broker's timer tasks be polled for the first time (so they know "now").
    async fn arm(&self) {
        self.barrier().await;
        settle().await;
    }

    /// Run the clock far past every deadline and watchdog; nothing further may happen.
    async fn run_out_the_clock(&self) {
        tokio::time::advance(APPROVAL_TIMEOUT + WATCHDOG_GRACE + Duration::from_secs(60)).await;
        settle().await;
        self.barrier().await;
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
        assert!(
            start.elapsed() < Duration::from_secs(20),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(5));
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

fn request_entries(entries: &[Entry]) -> Vec<&Entry> {
    entries
        .iter()
        .filter(|e| matches!(e.event, Event::Request { .. }))
        .collect()
}

fn outcomes_for<'a>(entries: &'a [Entry], tool_use_id: &str) -> Vec<&'a Entry> {
    entries
        .iter()
        .filter(|e| {
            matches!(e.event, Event::Outcome { .. })
                && e.tool_use_id.as_deref() == Some(tool_use_id)
        })
        .collect()
}

fn requests_for<'a>(entries: &'a [Entry], tool_use_id: &str) -> Vec<&'a Entry> {
    request_entries(entries)
        .into_iter()
        .filter(|e| e.tool_use_id.as_deref() == Some(tool_use_id))
        .collect()
}

fn outcome_name(e: &Entry) -> &str {
    match &e.event {
        Event::Outcome { outcome, .. } => outcome,
        other => panic!("not an outcome: {other:?}"),
    }
}

fn watchdog_flag(e: &Entry) -> bool {
    match &e.event {
        Event::Outcome { watchdog, .. } => *watchdog,
        other => panic!("not an outcome: {other:?}"),
    }
}

fn outcome_rule(e: &Entry) -> Option<Value> {
    match &e.event {
        Event::Outcome { rule, .. } => rule.clone(),
        other => panic!("not an outcome: {other:?}"),
    }
}

fn deny(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

/// T-AP0a-1: every answer ever written is a deny (with a message), never an allow.
#[track_caller]
fn assert_never_allowed(writes: &[(String, Value)]) {
    for (id, response) in writes {
        assert_eq!(
            response["behavior"], "deny",
            "the answer to {id} must be a deny: {response}"
        );
        assert!(
            response["message"].as_str().is_some_and(|m| !m.is_empty()),
            "{response}"
        );
        assert!(
            response.get("updatedInput").is_none(),
            "no input is ever approved: {response}"
        );
        assert!(!response.to_string().contains("allow"), "{response}");
    }
}

// ── the ordinary ending: nobody to ask ────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_request_with_nobody_to_ask_is_denied_with_the_approval_unavailable_words_and_logged() {
    let rig = Rig::new(Opts::default());
    let value = request_as("simple_rm", "toolu_1");

    rig.submit("cli-1", value.clone());
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(rig.writes(), [("cli-1".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE))]);
    assert_eq!(
        APPROVAL_UNAVAILABLE_MESSAGE,
        "Nostromo's approval screen isn't available yet, so this was denied. Tell the user what you wanted to run and give them the exact command; do not retry it.",
        "in this slice the agent is told something true: the screen does not exist yet"
    );
    assert!(
        !APPROVAL_UNAVAILABLE_MESSAGE.contains("app is closed"),
        "the app may be open in this slice"
    );
    assert_eq!(outcome_name(&outcome), "approval_unavailable");
    assert!(!watchdog_flag(&outcome));
    let entries = rig.entries();
    let requests = requests_for(&entries, "toolu_1");
    assert_eq!(requests.len(), 1, "one request entry");
    assert_eq!(
        outcomes_for(&entries, "toolu_1").len(),
        1,
        "one outcome entry"
    );
    assert_eq!(
        requests[0].request_id, outcome.request_id,
        "the two are the same request"
    );
    assert!(
        requests[0]
            .request_id
            .as_deref()
            .is_some_and(|id| !id.is_empty() && id != "cli-1"),
        "the log's id is Nostromo's, not the CLI's"
    );
    for e in [requests[0], &outcome] {
        assert_eq!(e.tag.as_deref(), Some(T));
        assert_eq!(e.session_id.as_deref(), Some("sid-t1"));
        assert_eq!(e.tool_use_id.as_deref(), Some("toolu_1"));
        assert_eq!(e.agent.as_deref(), Some("cody"));
        assert_eq!(e.subagent, None);
        assert_eq!(e.v, 1);
    }
    assert!(requests[0].ts <= outcome.ts);
    assert_never_allowed(&rig.writes());
}

#[test]
fn the_contract_s_no_app_words_stay_defined_for_the_slice_that_has_an_app() {
    // Not used by any ending in this slice (nobody is asked, so it is never true
    // that "the app is closed"), but the contract's wording is kept for later.
    assert_eq!(
        NO_APP_MESSAGE,
        "Nostromo can't ask anyone right now (the app is closed), so this was denied. Tell the user what you wanted to run."
    );
    assert_eq!(Outcome::NoApp.as_str(), "no_app");
    assert_eq!(Outcome::NotAvailable.as_str(), "approval_unavailable");
    assert_eq!(Outcome::DenyWriteFailed.as_str(), "deny_write_failed");
    assert_ne!(NO_APP_MESSAGE, APPROVAL_UNAVAILABLE_MESSAGE);
}

#[tokio::test(start_paused = true)]
async fn ask_user_question_and_exit_plan_mode_requests_get_the_same_approval_unavailable_text() {
    let rig = Rig::new(Opts::default());
    rig.submit(
        "cli-q",
        json!({
            "subtype": "can_use_tool",
            "tool_name": "AskUserQuestion",
            "input": { "questions": [{ "question": "Which one?", "options": [{ "label": "a" }] }] },
            "tool_use_id": "toolu_q",
        }),
    );
    rig.submit(
        "cli-p",
        json!({
            "subtype": "can_use_tool",
            "tool_name": "ExitPlanMode",
            "input": { "plan": "1. do the thing" },
            "tool_use_id": "toolu_p",
        }),
    );

    for id in ["toolu_q", "toolu_p"] {
        assert_eq!(outcome_name(&rig.wait_outcome(id).await), "approval_unavailable", "{id}");
    }

    let mut writes = rig.writes();
    writes.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        writes,
        [
            ("cli-p".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE)),
            ("cli-q".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE)),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn every_ordinary_fixture_is_denied_approval_unavailable_with_one_response_and_one_outcome_each() {
    let rig = Rig::new(Opts::default());
    let start = tokio::time::Instant::now();

    for name in ORDINARY {
        let id = format!("toolu_{name}");
        rig.submit(&format!("cli-{name}"), request_as(name, &id));
        let outcome = rig.wait_outcome(&id).await;
        assert_eq!(outcome_name(&outcome), "approval_unavailable", "{name}");
    }

    assert_eq!(
        tokio::time::Instant::now(),
        start,
        "all of it happened before the clock moved at all"
    );
    let writes = rig.writes();
    assert_eq!(writes.len(), ORDINARY.len(), "one answer per request");
    for name in ORDINARY {
        let answers: Vec<_> = writes
            .iter()
            .filter(|(id, _)| *id == format!("cli-{name}"))
            .collect();
        assert_eq!(answers.len(), 1, "{name}");
        assert_eq!(answers[0].1, deny(APPROVAL_UNAVAILABLE_MESSAGE), "{name}");
        let entries = rig.entries();
        assert_eq!(
            requests_for(&entries, &format!("toolu_{name}")).len(),
            1,
            "{name}"
        );
        assert_eq!(
            outcomes_for(&entries, &format!("toolu_{name}")).len(),
            1,
            "{name}"
        );
    }
    assert_never_allowed(&writes);
}

#[tokio::test(start_paused = true)]
async fn the_request_entry_holds_every_field_the_cli_sent() {
    let rig = Rig::new(Opts::default());
    let all = fixture_request("all_fields");
    rig.submit("cli-1", all.clone());
    rig.wait_outcome("toolu_all_fields_0").await;

    let entries = rig.entries();
    let entry = requests_for(&entries, "toolu_all_fields_0")[0];
    let Event::Request {
        tool_name,
        input,
        display_text,
        reason,
        flags,
        cli_request,
        ..
    } = &entry.event
    else {
        unreachable!()
    };

    assert_eq!(
        cli_request.as_ref(),
        Some(&without_input(&all)),
        "the CLI's request object as received, every field but `input` (which is the entry's own `input`, once)"
    );
    assert_eq!(tool_name, "Bash");
    assert_eq!(input, &all["input"]);
    assert_eq!(
        flags.as_ref(),
        Some(&json!({
            "default_to_no": true,
            "suppress_always_allow_rule": true,
            "requires_user_interaction": true,
            "classifier_approvable": true
        }))
    );
    let reason = reason.as_ref().expect("a why line");
    assert_eq!(reason["kind"], "ask_rule");
    assert_eq!(reason["rule"]["rule"], "Bash(rm:*)");
    assert!(
        display_text
            .as_deref()
            .is_some_and(|t| t.contains("rm -rf /tmp/x/all")),
        "{display_text:?}"
    );
    assert_eq!(
        entry.subagent,
        Some(json!({ "agent_id": "agent_abc123" })),
        "the request came from a subagent"
    );
}

#[tokio::test(start_paused = true)]
async fn each_flag_fixture_is_logged_whole_with_its_typed_flags() {
    let rig = Rig::new(Opts::default());
    let cases = [
        ("flag_default_to_no", [true, false, false, false]),
        (
            "flag_suppress_always_allow_rule",
            [false, true, false, false],
        ),
        (
            "flag_requires_user_interaction",
            [false, false, true, false],
        ),
        ("flag_matched_ask_rule", [false, false, false, false]),
        ("safety_check", [false, false, false, false]),
    ];

    for (name, [default_to_no, suppress, interaction, classifier]) in cases {
        let value = fixture_request(name);
        let id = value["tool_use_id"].as_str().unwrap().to_owned();
        rig.submit(&format!("cli-{name}"), value.clone());
        rig.wait_outcome(&id).await;

        let entries = rig.entries();
        let Event::Request {
            cli_request,
            flags,
            tool_name,
            input,
            ..
        } = &requests_for(&entries, &id)[0].event
        else {
            unreachable!()
        };
        assert_eq!(cli_request.as_ref(), Some(&without_input(&value)), "{name}");
        assert_eq!(tool_name, "Bash", "{name}");
        assert_eq!(input, &value["input"], "{name}");
        assert_eq!(
            flags.as_ref(),
            Some(&json!({
                "default_to_no": default_to_no,
                "suppress_always_allow_rule": suppress,
                "requires_user_interaction": interaction,
                "classifier_approvable": classifier,
            })),
            "{name}"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn the_logged_reason_explains_the_prompt() {
    let rig = Rig::new(Opts::default());
    for (name, kind, text) in [
        (
            "safety_check",
            "safety_check",
            "Command targets a protected path",
        ),
        (
            "settings_write",
            "settings_write",
            "Changes a Claude settings file",
        ),
        (
            "simple_rm",
            "ask_rule",
            "One of your Claude ask rules matched",
        ),
        ("flag_matched_ask_rule", "ask_rule", ""),
    ] {
        let value = fixture_request(name);
        let id = value["tool_use_id"].as_str().unwrap().to_owned();
        rig.submit(&format!("cli-{name}"), value);
        rig.wait_outcome(&id).await;
        let entries = rig.entries();
        let Event::Request { reason, .. } = &requests_for(&entries, &id)[0].event else {
            unreachable!()
        };
        let reason = reason
            .as_ref()
            .unwrap_or_else(|| panic!("{name}: no reason"));
        assert_eq!(reason["kind"], kind, "{name}");
        if text.is_empty() {
            let shown = reason["text"].as_str().unwrap_or_default();
            assert!(
                shown.contains("Bash(rm:*)") && shown.contains("userSettings"),
                "{name}: the CLI's rule and its source: {shown}"
            );
        } else {
            assert_eq!(reason["text"], text, "{name}");
        }
    }
}

#[tokio::test(start_paused = true)]
async fn the_logged_display_text_shows_hidden_characters_as_tokens() {
    let rig = Rig::new(Opts::default());
    rig.submit("cli-1", fixture_request("bidi"));
    rig.wait_outcome("toolu_bidi_0").await;

    let entries = rig.entries();
    let Event::Request {
        display_text,
        input,
        ..
    } = &requests_for(&entries, "toolu_bidi_0")[0].event
    else {
        unreachable!()
    };
    let text = display_text.as_deref().expect("display text");
    assert!(text.contains("\u{27E8}U+202E RLO\u{27E9}"), "{text:?}");
    assert!(
        !text.contains('\u{202E}'),
        "no raw bidi control in what a reader of the log sees: {text:?}"
    );
    assert!(
        input["command"].as_str().unwrap().contains('\u{202E}'),
        "the input itself is kept as received"
    );
}

#[tokio::test(start_paused = true)]
async fn a_subagent_s_request_names_the_subagent() {
    let rig = Rig::new(Opts::default());
    rig.submit("cli-1", fixture_request("subagent"));
    let outcome = rig.wait_outcome("toolu_subagent_0").await;

    let entries = rig.entries();
    let request = requests_for(&entries, "toolu_subagent_0")[0];
    for e in [request, &outcome] {
        assert_eq!(
            e.subagent.as_ref().map(|s| s["agent_id"].clone()),
            Some(json!("agent_abc123"))
        );
        assert_eq!(
            e.agent.as_deref(),
            Some("cody"),
            "the focus's own agent is still recorded"
        );
    }
}

// ── what the worker does not get to: the broker never makes the reader wait ───

#[test]
fn submitting_a_request_never_waits_for_the_broker() {
    // The worker is wedged inside the first request (the settings lookup waits for a gate).
    let gate = Gate::new();
    let rig = Rig::new(Opts {
        settings: Arc::new(SlowSettings(gate.clone())),
        ..Opts::default()
    });
    let start = Instant::now();

    for i in 0..50 {
        let id = format!("toolu_{i}");
        rig.submit(&format!("cli-{i}"), request_as("simple_rm", &id));
    }

    assert!(
        start.elapsed() < Duration::from_secs(5),
        "50 submits returned at once, whatever the worker is doing"
    );
    assert!(
        rig.writes().is_empty(),
        "nothing was answered while the worker is stuck"
    );
    gate.release();
}

// ── the guard comes first ─────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn the_guard_blocks_ecs_connect_before_anyone_is_asked_even_when_someone_could_be() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", fixture_request("guard_ecs_connect"));

    let outcome = rig.wait_outcome("toolu_guard_ecs_connect_0").await;

    assert_eq!(outcome_name(&outcome), "guard_blocked");
    assert_eq!(rig.writes(), [("cli-1".to_owned(), deny(GUARD_MESSAGE))]);
    assert_eq!(
        rig.presenter.asked(T),
        0,
        "the presenter is never consulted for a guarded call"
    );
    let rule = outcome_rule(&outcome)
        .expect("the outcome records which guard rule matched")
        .to_string();
    assert!(rule.contains(guard::RULE_COMMAND), "{rule}");
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn the_guard_blocks_typing_into_a_production_pane_using_the_injected_probe() {
    let rig = Rig::new(Opts {
        hold: true,
        pane_9: Some("production:portal:web".into()),
        ..Opts::default()
    });
    rig.submit("cli-1", fixture_request("guard_send_keys"));

    let outcome = rig.wait_outcome("toolu_guard_send_keys_0").await;

    assert_eq!(outcome_name(&outcome), "guard_blocked");
    assert_eq!(rig.writes(), [("cli-1".to_owned(), deny(GUARD_MESSAGE))]);
    assert_eq!(rig.presenter.asked(T), 0);
    assert!(
        rig.probed.lock().unwrap().iter().any(|t| t == "%9"),
        "the guard looked at pane %9 through the broker's probe"
    );
    let rule = outcome_rule(&outcome).expect("rule").to_string();
    assert!(rule.contains(guard::RULE_TMUX_INPUT), "{rule}");
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn typing_into_a_pane_that_is_not_remote_is_not_blocked() {
    let rig = Rig::new(Opts {
        hold: false,
        pane_9: Some("my local shell".into()),
        ..Opts::default()
    });
    rig.submit("cli-1", fixture_request("guard_send_keys"));

    let outcome = rig.wait_outcome("toolu_guard_send_keys_0").await;

    assert_eq!(
        outcome_name(&outcome),
        "approval_unavailable",
        "the guard only blocks what the probe says is a production shell"
    );
}

#[tokio::test(start_paused = true)]
async fn a_guarded_request_is_logged_as_a_request_and_one_outcome() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", fixture_request("guard_ecs_connect"));
    rig.wait_outcome("toolu_guard_ecs_connect_0").await;

    let entries = rig.entries();
    assert_eq!(requests_for(&entries, "toolu_guard_ecs_connect_0").len(), 1);
    assert_eq!(outcomes_for(&entries, "toolu_guard_ecs_connect_0").len(), 1);
}

// ── a request that cannot be read ─────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_request_that_cannot_be_parsed_is_denied_as_invalid_even_when_someone_could_be_asked() {
    let rig = Rig::new(holding());
    let malformed = fixture_request("malformed");

    rig.submit("cli-1", malformed.clone());
    let outcomes = wait_until("an outcome for the malformed request", || {
        let e: Vec<_> = rig
            .entries()
            .into_iter()
            .filter(|e| matches!(e.event, Event::Outcome { .. }))
            .collect();
        e.first().cloned()
    })
    .await;

    assert_eq!(outcome_name(&outcomes), "invalid_request");
    assert_eq!(
        rig.writes(),
        [("cli-1".to_owned(), deny(INVALID_REQUEST_MESSAGE))]
    );
    assert_eq!(
        rig.presenter.asked(T),
        0,
        "a request nobody can read is never put in front of a person"
    );
    let entries = rig.entries();
    let requests = request_entries(&entries);
    assert_eq!(requests.len(), 1, "it is logged all the same");
    let Event::Request { cli_request, .. } = &requests[0].event else {
        unreachable!()
    };
    assert_eq!(
        cli_request.as_ref(),
        Some(&without_input(&malformed)),
        "as it arrived, but for the input, which is the entry's own"
    );
    assert_eq!(requests[0].request_id, outcomes.request_id);
    assert_never_allowed(&rig.writes());
}

// ── holding a request for a human ─────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_held_request_is_asked_about_and_waits_without_an_answer() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    assert_eq!(rig.presenter.asked(T), 1);
    assert!(
        rig.writes().is_empty(),
        "nobody answered, so nothing was said to the agent"
    );
    assert!(rig.outcomes("toolu_1").is_empty());
    assert_eq!(
        requests_for(&rig.entries(), "toolu_1").len(),
        1,
        "but the request is on record"
    );
}

#[tokio::test(start_paused = true)]
async fn the_arrival_watchdog_does_not_end_a_request_that_is_being_held() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    tokio::time::advance(ARRIVAL_WATCHDOG * 30).await;
    settle().await;
    rig.barrier().await;

    assert!(rig.outcomes("toolu_1").is_empty());
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_request_is_denied_after_fifteen_minutes() {
    assert_eq!(APPROVAL_TIMEOUT, Duration::from_secs(15 * 60));
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    tokio::time::advance(APPROVAL_TIMEOUT - Duration::from_secs(1)).await;
    settle().await;
    assert!(rig.writes().is_empty(), "not yet: one second early");

    tokio::time::advance(Duration::from_secs(1)).await;
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "timed_out");
    assert!(
        !watchdog_flag(&outcome),
        "the ordinary deadline ended it, not the watchdog"
    );
    assert_eq!(
        rig.writes(),
        [("cli-1".to_owned(), deny(TIMED_OUT_MESSAGE))]
    );
    assert_eq!(
        TIMED_OUT_MESSAGE,
        "No one answered the approval request in Nostromo within 15 minutes, so it was denied. Don't retry it unless the user asks; tell them what you wanted to run."
    );
    rig.run_out_the_clock().await;
    assert_eq!(rig.writes().len(), 1, "a late timer adds nothing");
    assert_eq!(rig.outcomes("toolu_1").len(), 1);
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn the_timeout_is_whatever_the_broker_was_built_with() {
    let rig = Rig::new(Opts {
        hold: true,
        timeout: Duration::from_secs(30),
        ..Opts::default()
    });
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    tokio::time::advance(Duration::from_secs(30)).await;
    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "timed_out");
}

#[tokio::test(start_paused = true)]
async fn the_deadline_and_its_watchdog_firing_together_still_end_the_request_once() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    tokio::time::advance(APPROVAL_TIMEOUT + WATCHDOG_GRACE).await;
    rig.wait_outcome("toolu_1").await;
    settle().await;

    assert_eq!(
        rig.outcomes("toolu_1").len(),
        1,
        "exactly one outcome entry"
    );
    assert_eq!(rig.writes().len(), 1, "exactly one answer");
    assert_never_allowed(&rig.writes());
    // (The ordinary deadline and the watchdog are both armed at the same moment; which
    // of the two wins a tie is not specified, so only "once" is pinned here.)
}

// ── the watchdog: a stuck worker cannot strand a request ──────────────────────

#[tokio::test(start_paused = true)]
async fn a_request_the_worker_never_got_to_is_denied_by_the_watchdog_and_the_worker_adds_nothing_later(
) {
    for hold_when_released in [true, false] {
        let gate = Gate::new();
        let rig = Rig::new(Opts {
            hold: hold_when_released,
            gate: Some(gate.clone()),
            ..Opts::default()
        });
        rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
        wait_until("the worker to reach the presenter", || {
            (rig.presenter.entered.load(Ordering::SeqCst) > 0).then_some(())
        })
        .await;
        settle().await;

        tokio::time::advance(ARRIVAL_WATCHDOG - Duration::from_millis(1)).await;
        settle().await;
        assert!(
            rig.writes().is_empty(),
            "not before the watchdog's second is up"
        );

        tokio::time::advance(Duration::from_millis(1)).await;
        let outcome = rig.wait_outcome("toolu_1").await;
        assert_eq!(
            outcome_name(&outcome),
            "approval_unavailable",
            "force-denied the way an unattended request is"
        );
        assert!(
            watchdog_flag(&outcome),
            "and the log says the watchdog did it"
        );
        assert_eq!(rig.writes(), [("cli-1".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE))]);

        // The worker comes back: it finds nothing left to do.
        gate.release();
        rig.barrier().await;
        rig.run_out_the_clock().await;
        assert_eq!(
            rig.writes().len(),
            1,
            "exactly one response (hold={hold_when_released})"
        );
        assert_eq!(
            rig.outcomes("toolu_1").len(),
            1,
            "exactly one outcome (hold={hold_when_released})"
        );
        assert_never_allowed(&rig.writes());
    }
}

#[tokio::test(start_paused = true)]
async fn a_request_still_queued_when_the_watchdog_denies_it_is_logged_whole_and_only_once() {
    // The worker is stuck on request A, so request B has not even been looked at when the
    // watchdog denies both. The record must still show B's request, then its outcome.
    let gate = Gate::new();
    let rig = Rig::new(Opts {
        hold: true,
        gate: Some(gate.clone()),
        ..Opts::default()
    });
    let raw_b = request_as("compound", "toolu_b");
    rig.submit("cli-a", request_as("simple_rm", "toolu_a"));
    wait_until("the worker to get stuck on A", || {
        (rig.presenter.entered.load(Ordering::SeqCst) == 1).then_some(())
    })
    .await;
    rig.submit("cli-b", raw_b.clone());
    settle().await;
    assert!(
        requests_for(&rig.entries(), "toolu_b").is_empty(),
        "the worker has not got to B (that is the premise)"
    );

    tokio::time::advance(ARRIVAL_WATCHDOG).await;
    let outcome_b = rig.wait_outcome("toolu_b").await;
    let outcome_a = rig.wait_outcome("toolu_a").await;

    for outcome in [&outcome_a, &outcome_b] {
        assert_eq!(outcome_name(outcome), "approval_unavailable");
        assert!(watchdog_flag(outcome), "the log says the watchdog did it");
    }
    let mut writes = rig.writes();
    writes.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        writes,
        [
            ("cli-a".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE)),
            ("cli-b".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE))
        ]
    );
    let entries = rig.entries();
    let requests_b = requests_for(&entries, "toolu_b");
    assert_eq!(
        requests_b.len(),
        1,
        "B's request is on record although the worker never logged it"
    );
    let Event::Request {
        cli_request,
        tool_name,
        input,
        ..
    } = &requests_b[0].event
    else {
        unreachable!()
    };
    assert_eq!(
        cli_request.as_ref(),
        Some(&without_input(&raw_b)),
        "with the CLI's request as received (its input is the entry's own `input`)"
    );
    assert_eq!(tool_name, "Bash");
    assert_eq!(input, &raw_b["input"]);
    assert_eq!(
        requests_b[0].request_id, outcome_b.request_id,
        "the outcome belongs to that request"
    );
    assert_eq!(requests_b[0].session_id.as_deref(), Some("sid-t1"));
    assert_eq!(requests_b[0].agent.as_deref(), Some("cody"));
    assert!(
        requests_b[0].ts <= outcome_b.ts,
        "the request comes before its outcome"
    );
    assert_eq!(
        requests_for(&entries, "toolu_a").len(),
        1,
        "and A has its one request entry too"
    );

    // The worker comes back: it adds neither a second request entry nor a second outcome.
    gate.release();
    rig.barrier().await;
    rig.run_out_the_clock().await;
    let entries = rig.entries();
    for id in ["toolu_a", "toolu_b"] {
        assert_eq!(
            requests_for(&entries, id).len(),
            1,
            "{id}: one request entry"
        );
        assert_eq!(
            outcomes_for(&entries, id).len(),
            1,
            "{id}: one outcome entry"
        );
    }
    assert_eq!(rig.writes().len(), 2, "no further answer");
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn a_request_ended_by_a_cancel_before_the_worker_logged_it_is_still_logged_whole() {
    let gate = Gate::new();
    let rig = Rig::new(Opts {
        hold: true,
        gate: Some(gate.clone()),
        ..Opts::default()
    });
    rig.submit("cli-a", request_as("simple_rm", "toolu_a"));
    wait_until("the worker to get stuck on A", || {
        (rig.presenter.entered.load(Ordering::SeqCst) == 1).then_some(())
    })
    .await;
    let raw_b = request_as("compound", "toolu_b");
    rig.submit("cli-b", raw_b.clone());

    rig.broker.on_cancel(T, "cli-b");
    gate.release();
    rig.barrier().await;

    let entries = rig.entries();
    let requests_b = requests_for(&entries, "toolu_b");
    assert_eq!(requests_b.len(), 1);
    let Event::Request { cli_request, .. } = &requests_b[0].event else {
        unreachable!()
    };
    assert_eq!(cli_request.as_ref(), Some(&without_input(&raw_b)));
    let outcomes_b = outcomes_for(&entries, "toolu_b");
    assert_eq!(outcomes_b.len(), 1);
    assert_eq!(outcome_name(outcomes_b[0]), "withdrawn");
    assert_eq!(requests_b[0].request_id, outcomes_b[0].request_id);
}

#[tokio::test(start_paused = true)]
async fn the_watchdog_does_not_end_requests_the_worker_handled_in_time() {
    let rig = Rig::new(Opts::default());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    let outcome = rig.wait_outcome("toolu_1").await;
    assert!(!watchdog_flag(&outcome));
    settle().await;

    rig.run_out_the_clock().await;

    assert_eq!(rig.outcomes("toolu_1").len(), 1);
    assert_eq!(rig.writes().len(), 1);
}

// ── shutdown ──────────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn shutdown_denies_every_pending_request_restart_before_it_returns() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.submit("cli-2", request_as("compound", "toolu_2"));
    rig.arm().await;

    let written = rig.broker.deny_all_for_shutdown();

    let mut written_sorted = written.clone();
    written_sorted.sort();
    assert_eq!(
        written_sorted,
        [
            (T.to_owned(), "toolu_1".to_owned()),
            (T.to_owned(), "toolu_2".to_owned())
        ],
        "told which denies went out"
    );
    let mut writes = rig.writes();
    writes.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        writes,
        [
            ("cli-1".to_owned(), deny(RESTART_MESSAGE)),
            ("cli-2".to_owned(), deny(RESTART_MESSAGE))
        ],
        "the denies are already written when the call returns"
    );
    assert_eq!(
        RESTART_MESSAGE,
        "Nostromo restarted before anyone answered; this was not approved."
    );
    for id in ["toolu_1", "toolu_2"] {
        let outcomes = rig.outcomes(id);
        assert_eq!(outcomes.len(), 1, "{id}");
        assert_eq!(outcome_name(&outcomes[0]), "restart", "{id}");
    }
    rig.run_out_the_clock().await;
    assert_eq!(rig.writes().len(), 2, "no timer adds a third");
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn a_request_arriving_after_shutdown_began_is_denied_restart_too_even_if_someone_could_be_asked(
) {
    let rig = Rig::new(holding());
    assert!(
        rig.broker.deny_all_for_shutdown().is_empty(),
        "nothing pending, nothing written"
    );

    rig.submit("cli-late", request_as("simple_rm", "toolu_late"));
    let outcome = rig.wait_outcome("toolu_late").await;

    assert_eq!(outcome_name(&outcome), "restart");
    assert_eq!(
        rig.writes(),
        [("cli-late".to_owned(), deny(RESTART_MESSAGE))]
    );
    assert_never_allowed(&rig.writes());
}

#[tokio::test(start_paused = true)]
async fn shutdown_reports_only_the_denies_that_were_actually_written() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;
    rig.sink.die();

    let written = rig.broker.deny_all_for_shutdown();

    assert!(
        written.is_empty(),
        "the process is gone: no deny was written, so there is nothing to wait for"
    );
    assert!(rig.writes().is_empty());
    assert_eq!(outcome_name(&rig.outcomes("toolu_1")[0]), "cancelled");
}

// ── the CLI withdraws a request ───────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_withdrawn_request_ends_withdrawn_with_nothing_written() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    rig.broker.on_cancel(T, "cli-1");

    let outcome = rig.wait_outcome("toolu_1").await;
    assert_eq!(outcome_name(&outcome), "withdrawn");
    assert!(
        rig.writes().is_empty(),
        "the CLI cancelled it: there is no one waiting for an answer"
    );
    rig.run_out_the_clock().await;
    assert_eq!(rig.outcomes("toolu_1").len(), 1);
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_cancel_that_comes_through_the_queue_withdraws_the_request_too() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    let accepted = rig.broker.submit(Incoming::Cancel {
        tag: T.into(),
        cli_request_id: "cli-1".into(),
    });

    assert!(accepted.is_ok());
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "withdrawn"
    );
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn withdrawing_one_request_leaves_the_others_pending() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.submit("cli-2", request_as("compound", "toolu_2"));
    rig.arm().await;

    rig.broker.on_cancel(T, "cli-1");
    rig.wait_outcome("toolu_1").await;

    assert!(
        rig.outcomes("toolu_2").is_empty(),
        "the other request is untouched"
    );
    assert_eq!(
        rig.broker.deny_all_for_shutdown(),
        [(T.to_owned(), "toolu_2".to_owned())]
    );
    assert_eq!(rig.writes(), [("cli-2".to_owned(), deny(RESTART_MESSAGE))]);
}

#[tokio::test(start_paused = true)]
async fn withdrawing_something_unknown_or_already_ended_does_nothing() {
    let rig = Rig::new(Opts::default());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.wait_outcome("toolu_1").await;

    rig.broker.on_cancel(T, "cli-1"); // already ended no_app
    rig.broker.on_cancel(T, "never-heard-of-it");
    rig.broker.on_cancel("nobody", "cli-1");
    rig.barrier().await;

    assert_eq!(outcome_name(&rig.outcomes("toolu_1")[0]), "approval_unavailable");
    assert_eq!(rig.outcomes("toolu_1").len(), 1);
    assert_eq!(rig.writes().len(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_cancel_is_matched_by_session_as_well_as_request_id() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;

    rig.broker.on_cancel(BARRIER, "cli-1"); // another session's request with the same CLI id
    rig.barrier().await;

    assert!(rig.outcomes("toolu_1").is_empty());
}

// ── the session goes away (T-AP0a-2) ──────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn when_the_session_goes_its_pending_requests_end_cancelled_and_nothing_is_written() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.submit("cli-2", request_as("compound", "toolu_2"));
    rig.arm().await;

    rig.broker.on_session_gone(T, rig.generation, "stopped");

    for id in ["toolu_1", "toolu_2"] {
        assert_eq!(
            outcome_name(&rig.wait_outcome(id).await),
            "cancelled",
            "{id}"
        );
    }
    assert!(
        rig.writes().is_empty(),
        "never a word to a process that is gone"
    );
    // A late timer, deadline or watchdog does nothing either.
    rig.run_out_the_clock().await;
    assert!(rig.writes().is_empty());
    assert_eq!(rig.outcomes("toolu_1").len(), 1);
    assert_eq!(rig.outcomes("toolu_2").len(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_request_that_arrives_for_a_session_that_is_gone_is_cancelled_without_a_write() {
    let rig = Rig::new(Opts::default());
    rig.broker.on_session_gone(T, rig.generation, "exited");

    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));

    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "cancelled"
    );
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_process_that_has_exited_is_never_written_to_even_before_it_is_reported_gone() {
    let rig = Rig::new(Opts::default());
    rig.sink.die();

    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));

    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "cancelled"
    );
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_held_request_whose_process_died_is_cancelled_and_not_timed_out_into_a_dead_pipe() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.arm().await;
    rig.sink.die();

    tokio::time::advance(APPROVAL_TIMEOUT).await;

    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "cancelled"
    );
    assert!(rig.writes().is_empty());
}

async fn stale_generation_request_is_cancelled(hold: bool) {
    let rig = Rig::new(Opts {
        hold,
        ..Opts::default()
    });
    let new_sink = FakeSink::new();
    let new_generation = rig.broker.register_session(session(T), new_sink.clone());
    assert_ne!(
        new_generation, rig.generation,
        "a new process is a new generation"
    );

    // The old process's reader still holds the old generation.
    rig.submit_as(
        T,
        rig.generation,
        "cli-stale",
        request_as("simple_rm", "toolu_stale"),
    );

    let outcome = rig.wait_outcome("toolu_stale").await;
    assert_eq!(
        outcome_name(&outcome),
        "cancelled",
        "a stale request is ended at once, not held (hold={hold})"
    );
    assert!(
        rig.writes().is_empty() && new_sink.writes().is_empty(),
        "nothing written to either process (hold={hold})"
    );
    rig.run_out_the_clock().await;
    assert!(
        rig.writes().is_empty() && new_sink.writes().is_empty(),
        "hold={hold}"
    );
    assert_eq!(rig.outcomes("toolu_stale").len(), 1, "hold={hold}");
}

#[tokio::test(start_paused = true)]
async fn a_request_from_a_replaced_process_is_cancelled_without_a_write_to_either_process() {
    stale_generation_request_is_cancelled(false).await;
}

#[tokio::test(start_paused = true)]
async fn a_request_from_a_replaced_process_is_cancelled_at_once_even_when_someone_could_be_asked() {
    // A card for a process that is no longer there could only be answered into the wrong pipe.
    stale_generation_request_is_cancelled(true).await;
}

async fn unknown_session_request_is_cancelled(hold: bool) {
    let rig = Rig::new(Opts {
        hold,
        ..Opts::default()
    });

    rig.submit_as("stranger", 77, "cli-1", request_as("simple_rm", "toolu_1"));

    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "cancelled",
        "hold={hold}"
    );
    assert!(
        rig.writes().is_empty() && rig.barrier_sink.writes().is_empty(),
        "hold={hold}"
    );
}

#[tokio::test(start_paused = true)]
async fn a_request_for_a_session_the_broker_has_never_heard_of_is_cancelled_without_a_write() {
    unknown_session_request_is_cancelled(false).await;
}

#[tokio::test(start_paused = true)]
async fn a_request_for_a_session_the_broker_has_never_heard_of_is_cancelled_at_once_even_when_someone_could_be_asked(
) {
    unknown_session_request_is_cancelled(true).await;
}

/// The safety property under the two "at once" tests above: even if a request for a dead or
/// replaced process is held, the time it ends, it ends `cancelled` and nothing is written.
#[tokio::test(start_paused = true)]
async fn a_held_request_for_a_replaced_process_or_unknown_session_never_gets_a_write_even_at_its_deadline(
) {
    let rig = Rig::new(holding());
    let new_sink = FakeSink::new();
    rig.broker.register_session(session(T), new_sink.clone());
    rig.submit_as(
        T,
        rig.generation,
        "cli-stale",
        request_as("simple_rm", "toolu_stale"),
    );
    rig.submit_as(
        "stranger",
        77,
        "cli-unknown",
        request_as("compound", "toolu_unknown"),
    );
    rig.arm().await;

    tokio::time::advance(APPROVAL_TIMEOUT + WATCHDOG_GRACE).await;

    for id in ["toolu_stale", "toolu_unknown"] {
        assert_eq!(
            outcome_name(&rig.wait_outcome(id).await),
            "cancelled",
            "{id}"
        );
    }
    settle().await;
    assert!(
        rig.writes().is_empty() && new_sink.writes().is_empty(),
        "nothing written to either process of the focus"
    );
    assert!(
        rig.barrier_sink
            .writes()
            .iter()
            .all(|(id, _)| id.starts_with("barrier-")),
        "the other session heard only about its own requests"
    );
    assert_eq!(rig.outcomes("toolu_stale").len(), 1);
    assert_eq!(rig.outcomes("toolu_unknown").len(), 1);
}

#[tokio::test(start_paused = true)]
async fn an_old_generation_going_away_does_not_unregister_the_new_one() {
    let rig = Rig::new(Opts::default());
    let new_sink = FakeSink::new();
    let new_generation = rig.broker.register_session(session(T), new_sink.clone());

    rig.broker.on_session_gone(T, rig.generation, "exited"); // the old reader hits EOF late
    rig.submit_as(
        T,
        new_generation,
        "cli-new",
        request_as("simple_rm", "toolu_new"),
    );

    let outcome = rig.wait_outcome("toolu_new").await;
    assert_eq!(
        outcome_name(&outcome),
        "approval_unavailable",
        "the new process can still be answered"
    );
    assert_eq!(
        new_sink.writes(),
        [("cli-new".to_owned(), deny(APPROVAL_UNAVAILABLE_MESSAGE))]
    );
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn an_old_generation_going_away_does_not_cancel_the_new_one_s_pending_requests() {
    let rig = Rig::new(holding());
    let new_sink = FakeSink::new();
    let new_generation = rig.broker.register_session(session(T), new_sink.clone());
    rig.submit_as(
        T,
        new_generation,
        "cli-new",
        request_as("simple_rm", "toolu_new"),
    );
    rig.arm().await;

    rig.broker.on_session_gone(T, rig.generation, "exited");
    rig.barrier().await;

    assert!(rig.outcomes("toolu_new").is_empty(), "still pending");
    assert_eq!(
        rig.broker.deny_all_for_shutdown(),
        [(T.to_owned(), "toolu_new".to_owned())]
    );
    assert_eq!(
        new_sink.writes(),
        [("cli-new".to_owned(), deny(RESTART_MESSAGE))]
    );
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn two_sessions_do_not_affect_each_other() {
    let rig = Rig::new(holding());
    let other_sink = FakeSink::new();
    let other_generation = rig
        .broker
        .register_session(session("t2"), other_sink.clone());
    rig.submit("cli-a", request_as("simple_rm", "toolu_a"));
    rig.submit_as(
        "t2",
        other_generation,
        "cli-b",
        request_as("compound", "toolu_b"),
    );
    rig.arm().await;

    rig.broker.on_session_gone(T, rig.generation, "stopped");
    rig.wait_outcome("toolu_a").await;
    rig.barrier().await;
    assert!(
        rig.outcomes("toolu_b").is_empty(),
        "the other session's request is still pending"
    );

    rig.broker.on_cancel("t2", "cli-a"); // a CLI id of the first session means nothing to the second
    rig.barrier().await;
    assert!(rig.outcomes("toolu_b").is_empty());

    tokio::time::advance(APPROVAL_TIMEOUT).await;
    let outcome = rig.wait_outcome("toolu_b").await;
    assert_eq!(outcome_name(&outcome), "timed_out");
    assert_eq!(
        other_sink.writes(),
        [("cli-b".to_owned(), deny(TIMED_OUT_MESSAGE))]
    );
    assert!(rig.writes().is_empty(), "the stopped session heard nothing");
}

// ── the worker is gone: the caller must answer ────────────────────────────────

#[tokio::test(start_paused = true)]
async fn when_the_worker_is_gone_submit_gives_the_frame_back_so_the_caller_can_answer_it() {
    let rig = Rig::new(Opts::default());
    rig.broker.stop_worker_for_test();
    let value = request_as("simple_rm", "toolu_1");

    let request = rig.broker.submit(Incoming::Request {
        tag: T.into(),
        generation: rig.generation,
        cli_request_id: "cli-1".into(),
        value: value.clone(),
    });
    let cancel = rig.broker.submit(Incoming::Cancel {
        tag: T.into(),
        cli_request_id: "cli-1".into(),
    });
    let gone = rig.broker.submit(Incoming::Gone {
        tag: T.into(),
        generation: rig.generation,
        reason: "x".into(),
    });

    match request {
        Err(Incoming::Request {
            tag,
            generation,
            cli_request_id,
            value: back,
        }) => {
            assert_eq!(
                (tag.as_str(), generation, cli_request_id.as_str()),
                (T, rig.generation, "cli-1")
            );
            assert_eq!(back, value);
        }
        other => panic!("expected the request back, got {other:?}"),
    }
    assert!(matches!(cancel, Err(Incoming::Cancel { .. })), "{cancel:?}");
    assert!(matches!(gone, Err(Incoming::Gone { .. })), "{gone:?}");
    assert!(
        rig.writes().is_empty(),
        "the broker itself wrote nothing; the caller answers"
    );
}

#[tokio::test(start_paused = true)]
async fn a_request_the_caller_had_to_deny_itself_is_still_on_record_as_approval_unavailable() {
    let rig = Rig::new(Opts::default());
    rig.broker.stop_worker_for_test();
    let value = request_as("simple_rm", "toolu_1");

    rig.broker
        .record_unqueued_denial(T, rig.generation, &value, || Ok(()));

    let entries = rig.entries();
    let requests = requests_for(&entries, "toolu_1");
    let outcomes = outcomes_for(&entries, "toolu_1");
    assert_eq!((requests.len(), outcomes.len()), (1, 1));
    assert_eq!(outcome_name(outcomes[0]), "approval_unavailable");
    assert_eq!(requests[0].request_id, outcomes[0].request_id);
    let Event::Request { cli_request, .. } = &requests[0].event else {
        unreachable!()
    };
    assert_eq!(cli_request.as_ref(), Some(&without_input(&value)));
    assert_eq!(requests[0].session_id.as_deref(), Some("sid-t1"));
    assert!(
        rig.writes().is_empty(),
        "the caller writes the deny; the broker only records it"
    );
}

/// (request entries, outcome entries) on record for `tag` right now.
fn counts_for_tag(rig: &Rig, tag: &str) -> (usize, usize) {
    let entries = rig.entries();
    let mine = entries.iter().filter(|e| e.tag.as_deref() == Some(tag));
    let requests = mine.clone().filter(|e| matches!(e.event, Event::Request { .. })).count();
    let outcomes = mine.filter(|e| matches!(e.event, Event::Outcome { .. })).count();
    (requests, outcomes)
}

fn write_failed() -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::BrokenPipe, "the pipe is closed"))
}

#[tokio::test(start_paused = true)]
async fn the_readers_own_deny_is_logged_as_request_then_answer_then_outcome() {
    let rig = Rig::new(Opts::default());
    rig.broker.stop_worker_for_test();
    let value = request_as("simple_rm", "toolu_1");
    let seen = std::cell::Cell::new(None);
    let calls = std::cell::Cell::new(0);

    rig.broker.record_unqueued_denial(T, rig.generation, &value, || {
        calls.set(calls.get() + 1);
        seen.set(Some(counts_for_tag(&rig, T)));
        Ok(())
    });

    assert_eq!(calls.get(), 1, "the answer is written exactly once");
    assert_eq!(
        seen.get(),
        Some((1, 0)),
        "the request is on record before the answer is written, and the outcome only after"
    );
    assert_eq!(counts_for_tag(&rig, T), (1, 1));
}

#[tokio::test(start_paused = true)]
async fn a_readers_own_deny_that_could_not_be_written_is_logged_deny_write_failed() {
    let rig = Rig::new(Opts::default());
    rig.broker.stop_worker_for_test();
    let value = request_as("simple_rm", "toolu_1");

    rig.broker
        .record_unqueued_denial(T, rig.generation, &value, write_failed);

    let entries = rig.entries();
    let outcomes = outcomes_for(&entries, "toolu_1");
    assert_eq!(requests_for(&entries, "toolu_1").len(), 1);
    assert_eq!(outcomes.len(), 1);
    assert_eq!(outcome_name(outcomes[0]), "deny_write_failed");
    assert_eq!(
        outcome_rule(outcomes[0]),
        Some(json!({ "intended_outcome": "approval_unavailable" }))
    );
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_request_the_reader_denies_is_logged_as_request_then_answer_then_invalid_request() {
    let rig = Rig::new(Opts::default());
    let seen = std::cell::Cell::new(None);
    let calls = std::cell::Cell::new(0);

    rig.broker
        .record_unreadable_denial(T, rig.generation, Some("Bash"), || {
            calls.set(calls.get() + 1);
            seen.set(Some(counts_for_tag(&rig, T)));
            Ok(())
        });

    assert_eq!(calls.get(), 1, "one answer");
    assert_eq!(seen.get(), Some((1, 0)), "request first, outcome after the answer");
    let entries: Vec<Entry> = rig
        .entries()
        .into_iter()
        .filter(|e| e.tag.as_deref() == Some(T))
        .collect();
    let requests = request_entries(&entries);
    let outcomes: Vec<&Entry> = entries
        .iter()
        .filter(|e| matches!(e.event, Event::Outcome { .. }))
        .collect();
    assert_eq!((requests.len(), outcomes.len()), (1, 1));
    assert_eq!(outcome_name(outcomes[0]), "invalid_request");
    assert!(requests[0].request_id.is_some());
    assert_eq!(requests[0].request_id, outcomes[0].request_id);
    assert_ne!(requests[0].request_id.as_deref(), Some(""));
    let Event::Request { tool_name, .. } = &requests[0].event else {
        unreachable!()
    };
    assert_eq!(tool_name, "Bash", "the tool name the reader could still read");
    assert_eq!(requests[0].session_id.as_deref(), Some("sid-t1"));
    assert_eq!(requests[0].agent.as_deref(), Some("cody"));
    assert!(requests[0].ts <= outcomes[0].ts);
    assert!(rig.writes().is_empty(), "the caller writes the deny; the broker only records it");
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_request_with_no_readable_tool_name_is_recorded_as_unknown() {
    let rig = Rig::new(Opts::default());

    rig.broker
        .record_unreadable_denial(T, rig.generation, None, || Ok(()));

    let entries = rig.entries();
    let requests = request_entries(&entries);
    assert_eq!(requests.len(), 1);
    let Event::Request { tool_name, .. } = &requests[0].event else {
        unreachable!()
    };
    assert_eq!(tool_name, "unknown");
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_request_whose_deny_could_not_be_written_is_logged_deny_write_failed() {
    let rig = Rig::new(Opts::default());

    rig.broker
        .record_unreadable_denial(T, rig.generation, Some("Bash"), write_failed);

    let entries = rig.entries();
    let outcomes: Vec<&Entry> = entries
        .iter()
        .filter(|e| matches!(e.event, Event::Outcome { .. }))
        .collect();
    assert_eq!(request_entries(&entries).len(), 1);
    assert_eq!(outcomes.len(), 1);
    assert_eq!(outcome_name(outcomes[0]), "deny_write_failed");
    assert_eq!(
        outcome_rule(outcomes[0]),
        Some(json!({ "intended_outcome": "invalid_request" }))
    );
}

#[tokio::test(start_paused = true)]
async fn a_request_whose_id_could_not_be_read_leaves_one_request_unparseable_entry_and_nothing_else() {
    let rig = Rig::new(Opts::default());

    rig.broker.record_unparseable(T, rig.generation);

    let entries = rig.entries();
    assert_eq!(entries.len(), 1, "{entries:?}");
    let entry = &entries[0];
    assert_eq!(outcome_name(entry), "request_unparseable");
    assert_eq!(entry.tag.as_deref(), Some(T));
    assert_eq!(entry.request_id, None, "there is no request id to record");
    assert_eq!(entry.tool_use_id, None);
    assert!(rig.writes().is_empty(), "nothing can be written: there is no id to answer under");
}

#[tokio::test(start_paused = true)]
async fn cancel_and_session_gone_still_work_inline_after_the_worker_is_gone() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.submit("cli-2", request_as("compound", "toolu_2"));
    rig.arm().await;
    rig.broker.stop_worker_for_test();

    rig.broker.on_cancel(T, "cli-1");
    rig.broker.on_session_gone(T, rig.generation, "exited");

    assert_eq!(outcome_name(&rig.outcomes("toolu_1")[0]), "withdrawn");
    assert_eq!(outcome_name(&rig.outcomes("toolu_2")[0]), "cancelled");
    assert!(rig.writes().is_empty());
}

// ── a request that ends before the worker has looked at it ────────────────────

#[test]
fn a_request_that_ends_while_the_worker_is_busy_is_logged_whole_not_asked_about_and_not_answered() {
    // The worker is stuck on request A; B is still queued when the session goes away.
    let gate = Gate::new();
    let rig = Rig::new(Opts {
        hold: true,
        gate: Some(gate.clone()),
        ..Opts::default()
    });
    rig.submit("cli-a", request_as("simple_rm", "toolu_a"));
    poll_sync("the worker to get stuck on A", || {
        (rig.presenter.entered.load(Ordering::SeqCst) == 1).then_some(())
    });
    let raw_b = request_as("compound", "toolu_b");
    rig.submit("cli-b", raw_b.clone());
    rig.broker.on_session_gone(T, rig.generation, "stopped");
    gate.release();

    // Everything queued before this has been done.
    let id = "barrier-sync";
    rig.submit_as(
        BARRIER,
        rig.barrier_generation,
        id,
        request_as("simple_rm", id),
    );
    poll_sync("the barrier", || {
        (!rig.outcomes(id).is_empty()).then_some(())
    });

    let entries = rig.entries();
    for tool_use_id in ["toolu_a", "toolu_b"] {
        let outcomes = outcomes_for(&entries, tool_use_id);
        assert_eq!(outcomes.len(), 1, "{tool_use_id}");
        assert_eq!(outcome_name(outcomes[0]), "cancelled", "{tool_use_id}");
        assert_eq!(
            requests_for(&entries, tool_use_id).len(),
            1,
            "{tool_use_id}: one request entry"
        );
    }
    let Event::Request { cli_request, .. } = &requests_for(&entries, "toolu_b")[0].event else {
        unreachable!()
    };
    assert_eq!(cli_request.as_ref(), Some(&without_input(&raw_b)));
    assert!(rig.writes().is_empty());
    assert_eq!(
        rig.presenter.asked(T),
        1,
        "nobody is asked about a request that is already over"
    );
}

fn poll_sync<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < Duration::from_secs(20),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

// ── exactly once, even when everything races ──────────────────────────────────

#[test]
fn a_cancel_a_session_exit_and_a_shutdown_at_once_end_a_request_exactly_once() {
    for round in 0..40 {
        let rig = Rig::new(holding());
        let id = format!("toolu_{round}");
        rig.submit("cli-1", request_as("simple_rm", &id));
        poll_sync("the worker to ask", || {
            (rig.presenter.asked(T) > 0).then_some(())
        });

        let start = Arc::new(Barrier::new(3));
        std::thread::scope(|s| {
            s.spawn(|| {
                start.wait();
                rig.broker.on_cancel(T, "cli-1");
            });
            s.spawn(|| {
                start.wait();
                rig.broker.on_session_gone(T, rig.generation, "exited");
            });
            s.spawn(|| {
                start.wait();
                rig.broker.deny_all_for_shutdown();
            });
        });
        // Whatever order they ran in, the worker has finished with this request too.
        let barrier_id = format!("barrier-{round}");
        rig.submit_as(
            BARRIER,
            rig.barrier_generation,
            &barrier_id,
            request_as("simple_rm", &barrier_id),
        );
        poll_sync("the barrier", || {
            (!rig.outcomes(&barrier_id).is_empty()).then_some(())
        });

        let outcomes = rig.outcomes(&id);
        assert_eq!(
            outcomes.len(),
            1,
            "round {round}: exactly one outcome entry"
        );
        let name = outcome_name(&outcomes[0]).to_owned();
        assert!(
            ["withdrawn", "cancelled", "restart"].contains(&name.as_str()),
            "round {round}: {name}"
        );
        let writes = rig.writes();
        if name == "restart" {
            assert_eq!(
                writes,
                [("cli-1".to_owned(), deny(RESTART_MESSAGE))],
                "round {round}"
            );
        } else {
            assert!(
                writes.is_empty(),
                "round {round}: ended {name}, so nothing may be written: {writes:?}"
            );
        }
        assert_never_allowed(&writes);
    }
}

#[test]
fn many_requests_racing_with_a_shutdown_are_each_answered_at_most_once() {
    let rig = Rig::new(holding());
    let ids: Vec<String> = (0..30).map(|i| format!("toolu_{i}")).collect();
    for (i, id) in ids.iter().enumerate() {
        rig.submit(&format!("cli-{i}"), request_as("simple_rm", id));
    }

    std::thread::scope(|s| {
        s.spawn(|| {
            rig.broker.deny_all_for_shutdown();
        });
        s.spawn(|| {
            for i in 0..30 {
                rig.broker.on_cancel(T, &format!("cli-{i}"));
            }
        });
    });
    let barrier_id = "barrier-final";
    rig.submit_as(
        BARRIER,
        rig.barrier_generation,
        barrier_id,
        request_as("simple_rm", barrier_id),
    );
    poll_sync("the barrier", || {
        (!rig.outcomes(barrier_id).is_empty()).then_some(())
    });

    let writes = rig.writes();
    for (i, id) in ids.iter().enumerate() {
        let outcomes = rig.outcomes(id);
        assert_eq!(outcomes.len(), 1, "{id}: exactly one outcome");
        let answers = writes
            .iter()
            .filter(|(cli, _)| *cli == format!("cli-{i}"))
            .count();
        assert_eq!(
            answers,
            usize::from(outcome_name(&outcomes[0]) == "restart"),
            "{id}: {}",
            outcome_name(&outcomes[0])
        );
    }
    assert_never_allowed(&writes);
}

// ── T-AP0a-1: every ending, and not one allow ─────────────────────────────────

struct Run {
    writes: Vec<(String, Value)>,
    entries: Vec<Entry>,
}

async fn drive(ending: &str) -> Run {
    let tool_use_id = "toolu_1";
    match ending {
        "approval_unavailable" => {
            let rig = Rig::new(Opts::default());
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            rig.wait_outcome(tool_use_id).await;
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "timed_out" => {
            let rig = Rig::new(holding());
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            rig.arm().await;
            tokio::time::advance(APPROVAL_TIMEOUT).await;
            rig.wait_outcome(tool_use_id).await;
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "restart" => {
            let rig = Rig::new(holding());
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            rig.arm().await;
            rig.broker.deny_all_for_shutdown();
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "withdrawn" => {
            let rig = Rig::new(holding());
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            rig.arm().await;
            rig.broker.on_cancel(T, "cli-1");
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "cancelled" => {
            let rig = Rig::new(holding());
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            rig.arm().await;
            rig.broker.on_session_gone(T, rig.generation, "stopped");
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "guard_blocked" => {
            let rig = Rig::new(holding());
            rig.submit("cli-1", request_as("guard_ecs_connect", tool_use_id));
            rig.wait_outcome(tool_use_id).await;
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "invalid_request" => {
            let rig = Rig::new(holding());
            let mut malformed = fixture_request("malformed");
            malformed["tool_use_id"] = Value::Null; // there is no tool_use_id to find it by: look for any outcome
            rig.submit("cli-1", malformed);
            wait_until("an outcome", || {
                rig.entries()
                    .into_iter()
                    .find(|e| matches!(e.event, Event::Outcome { .. }))
            })
            .await;
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "watchdog" => {
            let gate = Gate::new();
            let rig = Rig::new(Opts {
                hold: true,
                gate: Some(gate.clone()),
                ..Opts::default()
            });
            rig.submit("cli-1", request_as("simple_rm", tool_use_id));
            wait_until("the worker to reach the presenter", || {
                (rig.presenter.entered.load(Ordering::SeqCst) > 0).then_some(())
            })
            .await;
            settle().await;
            tokio::time::advance(ARRIVAL_WATCHDOG).await;
            rig.wait_outcome(tool_use_id).await;
            gate.release();
            rig.barrier().await;
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        "restart_crash" => {
            let dir = tempfile::tempdir().unwrap();
            let log = AuditLog::open(dir.path()).unwrap();
            log.append(&pending_request_entry(
                "t1",
                "Bash",
                "req-crash",
                Utc::now() - ChronoDuration::hours(1),
            ))
            .unwrap();
            let rig = Rig::on_dir(dir, Opts::default());
            rig.broker.startup_reconcile(Utc::now()).unwrap();
            rig.run_out_the_clock().await;
            Run {
                writes: rig.writes(),
                entries: rig.entries(),
            }
        }
        other => panic!("unknown ending {other}"),
    }
}

#[tokio::test(start_paused = true)]
async fn every_ending_writes_the_right_deny_or_nothing_logs_one_outcome_and_never_allows() {
    // (ending, the outcome entry it leaves, what the agent is told, if anything)
    let table: [(&str, &str, Option<&str>); 9] = [
        ("approval_unavailable", "approval_unavailable", Some(APPROVAL_UNAVAILABLE_MESSAGE)),
        ("timed_out", "timed_out", Some(TIMED_OUT_MESSAGE)),
        ("restart", "restart", Some(RESTART_MESSAGE)),
        ("restart_crash", "restart_crash", None),
        ("withdrawn", "withdrawn", None),
        ("cancelled", "cancelled", None),
        ("guard_blocked", "guard_blocked", Some(GUARD_MESSAGE)),
        ("watchdog", "approval_unavailable", Some(APPROVAL_UNAVAILABLE_MESSAGE)),
        (
            "invalid_request",
            "invalid_request",
            Some(INVALID_REQUEST_MESSAGE),
        ),
    ];

    for (ending, outcome, message) in table {
        let run = drive(ending).await;

        let outcomes: Vec<&Entry> = run
            .entries
            .iter()
            .filter(|e| {
                matches!(e.event, Event::Outcome { .. })
                    && !e
                        .tool_use_id
                        .as_deref()
                        .unwrap_or("")
                        .starts_with("barrier-")
            })
            .collect();
        assert_eq!(
            outcomes.len(),
            1,
            "{ending}: exactly one outcome entry: {outcomes:?}"
        );
        assert_eq!(outcome_name(outcomes[0]), outcome, "{ending}");
        assert_eq!(watchdog_flag(outcomes[0]), ending == "watchdog", "{ending}");
        let ours: Vec<_> = run
            .writes
            .iter()
            .filter(|(id, _)| id.starts_with("cli-"))
            .collect();
        match message {
            Some(m) => assert_eq!(
                ours.iter().map(|(_, r)| r.clone()).collect::<Vec<_>>(),
                [deny(m)],
                "{ending}: exactly one response"
            ),
            None => assert!(ours.is_empty(), "{ending}: nothing is written: {ours:?}"),
        }
        assert_never_allowed(&run.writes);
        // No entry of any kind ever says an allow happened.
        for e in &run.entries {
            assert!(
                !serde_json::to_string(e)
                    .unwrap()
                    .contains("\"behavior\":\"allow\""),
                "{ending}: {e:?}"
            );
            if let Event::Outcome { outcome, .. } = &e.event {
                assert!(!outcome.starts_with("allow"), "{ending}: {outcome}");
            }
        }
    }
}

// ── a crash while a request was pending (PRD 5) ───────────────────────────────

fn pending_request_entry(tag: &str, tool: &str, request_id: &str, ts: DateTime<Utc>) -> Entry {
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
        ts,
    );
    e.request_id = Some(request_id.into());
    e.tag = Some(tag.into());
    e.tool_use_id = Some(format!("toolu_{request_id}"));
    e.session_id = Some("sid-crash".into());
    e.agent = Some("cody".into());
    e
}

fn outcome_entry(request_id: &str, outcome: &str, ts: DateTime<Utc>) -> Entry {
    let mut e = Entry::new(
        Event::Outcome {
            outcome: outcome.into(),
            rule: None,
            by_window: None,
            latency_ms: None,
            watchdog: false,
        },
        ts,
    );
    e.request_id = Some(request_id.into());
    e
}

fn broker_on(dir: &Path) -> ApprovalBroker {
    ApprovalBroker::new(
        AuditLog::open(dir).unwrap(),
        BrokerParts {
            presenters: Default::default(),
            presenter: Arc::new(TestPresenter {
                hold: false,
                gate: None,
                asked: Mutex::new(Vec::new()),
                entered: AtomicUsize::new(0),
            }),
            probe: Arc::new(|| {
                Box::new(FakeProbe {
                    pane_9: None,
                    seen: Arc::default(),
                })
            }),
            settings: Arc::new(NoRules),
            timeout: APPROVAL_TIMEOUT,
        },
    )
}

fn read_all(dir: &Path) -> Vec<Entry> {
    AuditLog::open(dir)
        .unwrap()
        .read(everything(), &AuditFilter::default())
        .unwrap()
}

#[test]
fn a_request_with_no_outcome_is_ended_restart_crash_when_the_daemon_starts() {
    let dir = tempfile::tempdir().unwrap();
    let log = AuditLog::open(dir.path()).unwrap();
    let asked_at = Utc::now() - ChronoDuration::minutes(5);
    log.append(&pending_request_entry("T", "Bash", "req-1", asked_at))
        .unwrap();
    let broker = broker_on(dir.path());
    let now = Utc::now();

    let reconciled = broker.startup_reconcile(now).unwrap();

    assert_eq!(reconciled, 1);
    let entries = read_all(dir.path());
    let outcomes: Vec<&Entry> = entries
        .iter()
        .filter(|e| matches!(e.event, Event::Outcome { .. }))
        .collect();
    assert_eq!(outcomes.len(), 1);
    assert_eq!(outcome_name(outcomes[0]), "restart_crash");
    assert_eq!(
        outcomes[0].request_id.as_deref(),
        Some("req-1"),
        "it closes that very request"
    );
    assert_eq!(outcomes[0].tag.as_deref(), Some("T"));
    assert_eq!(outcomes[0].tool_use_id.as_deref(), Some("toolu_req-1"));
    assert!(
        dir.path().join(RESTART_NOTES_FILE).exists(),
        "the focus is remembered in restart-notes.json"
    );
    assert_eq!(RESTART_NOTES_FILE, "restart-notes.json");
}

#[test]
fn reconciling_twice_or_over_requests_that_already_ended_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let log = AuditLog::open(dir.path()).unwrap();
    let t = Utc::now() - ChronoDuration::minutes(10);
    log.append(&pending_request_entry("T", "Bash", "ended", t))
        .unwrap();
    log.append(&outcome_entry(
        "ended",
        "no_app",
        t + ChronoDuration::seconds(1),
    ))
    .unwrap();
    let broker = broker_on(dir.path());

    assert_eq!(
        broker.startup_reconcile(Utc::now()).unwrap(),
        0,
        "a request that already has an outcome is not reconciled"
    );
    assert!(
        !dir.path().join(RESTART_NOTES_FILE).exists(),
        "and leaves no note"
    );
    assert_eq!(read_all(dir.path()).len(), 2);

    log.append(&pending_request_entry("T", "Bash", "open", t))
        .unwrap();
    assert_eq!(broker.startup_reconcile(Utc::now()).unwrap(), 1);
    assert_eq!(
        broker.startup_reconcile(Utc::now()).unwrap(),
        0,
        "the second pass finds nothing left open"
    );
    assert_eq!(
        read_all(dir.path())
            .iter()
            .filter(
                |e| matches!(&e.event, Event::Outcome { outcome, .. } if outcome == "restart_crash")
            )
            .count(),
        1
    );
}

#[test]
fn reconciling_an_empty_store_does_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let broker = broker_on(dir.path());

    assert_eq!(broker.startup_reconcile(Utc::now()).unwrap(), 0);
    assert!(!dir.path().join(RESTART_NOTES_FILE).exists());
    assert_eq!(broker.take_restart_note("T"), None);
}

#[test]
fn the_agent_is_told_once_and_only_once_what_was_pending() {
    let dir = tempfile::tempdir().unwrap();
    AuditLog::open(dir.path())
        .unwrap()
        .append(&pending_request_entry(
            "T",
            "Bash",
            "req-1",
            Utc::now() - ChronoDuration::minutes(5),
        ))
        .unwrap();
    let broker = broker_on(dir.path());
    broker.startup_reconcile(Utc::now()).unwrap();

    assert_eq!(
        broker.take_restart_note("other"),
        None,
        "another focus has nothing to be told"
    );
    let note = broker.take_restart_note("T").expect("a note for T");
    assert_eq!(
        note,
        "A permission request for Bash was pending when Nostromo restarted. It was not approved."
    );
    assert_eq!(note, restart_note_text("Bash"));
    assert_eq!(
        broker.take_restart_note("T"),
        None,
        "the second ask finds it gone"
    );
    let on_disk = std::fs::read_to_string(dir.path().join(RESTART_NOTES_FILE)).unwrap_or_default();
    assert!(
        !on_disk.contains("\"T\""),
        "taking it clears it from disk too: {on_disk:?}"
    );
}

#[test]
fn the_note_names_the_tool_that_was_pending() {
    let dir = tempfile::tempdir().unwrap();
    AuditLog::open(dir.path())
        .unwrap()
        .append(&pending_request_entry(
            "T",
            "mcp__slack__send_message",
            "req-1",
            Utc::now() - ChronoDuration::minutes(5),
        ))
        .unwrap();
    let broker = broker_on(dir.path());
    broker.startup_reconcile(Utc::now()).unwrap();

    assert_eq!(
        broker.take_restart_note("T").as_deref(),
        Some("A permission request for mcp__slack__send_message was pending when Nostromo restarted. It was not approved.")
    );
}

#[test]
fn the_note_survives_a_restart_of_the_broker_until_it_is_taken() {
    let dir = tempfile::tempdir().unwrap();
    AuditLog::open(dir.path())
        .unwrap()
        .append(&pending_request_entry(
            "T",
            "Bash",
            "req-1",
            Utc::now() - ChronoDuration::minutes(5),
        ))
        .unwrap();
    broker_on(dir.path()).startup_reconcile(Utc::now()).unwrap();

    // The daemon restarts again before anyone talked to T.
    let second = broker_on(dir.path());
    assert_eq!(
        second.startup_reconcile(Utc::now()).unwrap(),
        0,
        "nothing new to reconcile"
    );
    assert_eq!(
        second.take_restart_note("T").as_deref(),
        Some(restart_note_text("Bash").as_str())
    );
    drop(second);

    // Once taken, a later broker does not bring it back.
    assert_eq!(broker_on(dir.path()).take_restart_note("T"), None);
}

#[test]
fn several_pending_requests_of_several_focuses_each_leave_their_focus_one_note() {
    let dir = tempfile::tempdir().unwrap();
    let log = AuditLog::open(dir.path()).unwrap();
    let t = Utc::now() - ChronoDuration::minutes(5);
    log.append(&pending_request_entry("A", "Bash", "r1", t))
        .unwrap();
    log.append(&pending_request_entry("A", "Bash", "r2", t))
        .unwrap();
    log.append(&pending_request_entry("B", "Edit", "r3", t))
        .unwrap();
    let broker = broker_on(dir.path());

    assert_eq!(broker.startup_reconcile(Utc::now()).unwrap(), 3);

    assert_eq!(
        broker.take_restart_note("A").as_deref(),
        Some(restart_note_text("Bash").as_str())
    );
    assert_eq!(broker.take_restart_note("A"), None);
    assert_eq!(
        broker.take_restart_note("B").as_deref(),
        Some(restart_note_text("Edit").as_str())
    );
    let entries = read_all(dir.path());
    assert_eq!(
        entries
            .iter()
            .filter(
                |e| matches!(&e.event, Event::Outcome { outcome, .. } if outcome == "restart_crash")
            )
            .count(),
        3
    );
}

#[tokio::test(start_paused = true)]
async fn a_request_ended_by_the_broker_is_never_reconciled_as_a_crash() {
    let rig = Rig::new(Opts::default());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.wait_outcome("toolu_1").await;
    let before = rig.entries().len();

    assert_eq!(rig.broker.startup_reconcile(Utc::now()).unwrap(), 0);

    assert_eq!(rig.entries().len(), before);
    assert_eq!(rig.broker.take_restart_note(T), None);
}

// ── the store ─────────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn the_log_survives_a_restart_every_entry_is_still_there() {
    let rig = Rig::new(holding());
    rig.submit("cli-1", request_as("simple_rm", "toolu_1"));
    rig.submit("cli-2", request_as("guard_ecs_connect", "toolu_2"));
    rig.arm().await;
    rig.broker.deny_all_for_shutdown();
    rig.barrier().await;
    let before = rig.entries();
    let path = rig.dir.path().to_path_buf();
    let kept = rig.dir;
    drop(rig.broker);

    // A new process opens the same directory.
    let after = AuditLog::open(&path)
        .unwrap()
        .read(everything(), &AuditFilter::default())
        .unwrap();

    assert!(before.len() >= 6, "{} entries before", before.len());
    assert_eq!(
        after, before,
        "the new store reads back every entry as it was written"
    );
    drop(kept);
}

#[tokio::test(start_paused = true)]
async fn sweeping_through_the_broker_keeps_89_day_old_files_and_removes_91_day_old_ones() {
    let rig = Rig::new(Opts::default());
    let now = Utc::now();
    let log = AuditLog::open(rig.dir.path()).unwrap();
    for days in [89, 91] {
        log.append(&pending_request_entry(
            "T",
            "Bash",
            &format!("old-{days}"),
            now - ChronoDuration::days(days),
        ))
        .unwrap();
    }
    assert_eq!(RETENTION_DAYS, 90);

    let deleted = rig.broker.sweep(now).unwrap();

    assert_eq!(deleted, 1);
    let all_time = now - ChronoDuration::days(400)..now + ChronoDuration::days(1);
    let left: Vec<String> = log
        .read(all_time, &AuditFilter::default())
        .unwrap()
        .iter()
        .filter_map(|e| e.request_id.clone())
        .collect();
    assert_eq!(left, ["old-89"]);
}
