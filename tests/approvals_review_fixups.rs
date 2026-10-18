//! PR #270 review fix-ups at the broker and audit level, written against API
//! that exists today (the new names the fix-up plan adds are written out as the
//! literals it fixes), so these compile on the current code and fail there for
//! the behavioural reason.
//!
//! - N2: the audit entry does not repeat `input` inside `cli_request`;
//!   `display_text` is sanitized and bounded; `startup_reconcile` copes with
//!   huge or corrupt lines in the audit files; `sweep` carries on past a file
//!   it cannot delete and says so.
//! - N4: what the agent is told when nobody can be asked in this slice is true
//!   in this slice, and AskUserQuestion / ExitPlanMode get the same text.
//! - N5: a deny that could not be written is logged `deny_write_failed`.
//!
//! The broker's worker is a plain thread, so effects are polled for in real
//! time with a cap, under a paused tokio clock that never moves on its own.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{
    AuditFilter, AuditLog, Entry, Event, MAX_RECORDED_STRING_BYTES, RETENTION_DAYS,
};
use nostromo::approvals::broker::{
    ApprovalBroker, BrokerParts, Incoming, NoPresenter, SessionInfo, SessionSink, APPROVAL_TIMEOUT,
};
use nostromo::approvals::guard::{PaneInfo, PaneProbe, ProbeError, TmuxSocket};
use nostromo::approvals::request::{AskRule, SettingsSource};
use serde_json::{json, Value};

/// The words an agent is told in this slice when nobody can be asked (N4).
const APPROVAL_UNAVAILABLE_TEXT: &str = "Nostromo's approval screen isn't available yet, so this was denied. Tell the user what you wanted to run and give them the exact command; do not retry it.";

// ── fixtures ──────────────────────────────────────────────────────────────────

fn fixture_request(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("tests/fixtures/approvals/{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture["requests"][0]["request"].clone()
}

fn bash_request(tool_use_id: &str, command: &str) -> Value {
    json!({
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "display_name": "Bash",
        "input": { "command": command, "description": "d" },
        "tool_use_id": tool_use_id,
    })
}

/// `request` without its `input` key.
fn without_input(request: &Value) -> Value {
    let mut v = request.clone();
    v.as_object_mut().unwrap().remove("input");
    v
}

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer; can be told to fail every write.
struct Sink {
    live: AtomicBool,
    fail: AtomicBool,
    writes: Mutex<Vec<(String, Value)>>,
}

impl Sink {
    fn new(fail: bool) -> Arc<Self> {
        Arc::new(Self {
            live: AtomicBool::new(true),
            fail: AtomicBool::new(fail),
            writes: Mutex::new(Vec::new()),
        })
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.writes.lock().unwrap().clone()
    }
}

impl SessionSink for Sink {
    fn live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn respond(&self, cli_request_id: &str, response: &Value) -> io::Result<()> {
        if self.fail.load(Ordering::SeqCst) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the pipe is full or closed"));
        }
        self.writes
            .lock()
            .unwrap()
            .push((cli_request_id.to_owned(), response.clone()));
        Ok(())
    }
}

struct NoPanes;

impl PaneProbe for NoPanes {
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

const T: &str = "t1";

struct Rig {
    broker: ApprovalBroker,
    sink: Arc<Sink>,
    _dir: tempfile::TempDir,
    generation: u64,
}

fn parts() -> BrokerParts {
    BrokerParts {
        presenters: Default::default(),
        presenter: Arc::new(NoPresenter),
        probe: Arc::new(|| Box::new(NoPanes)),
        settings: Arc::new(NoRules),
        timeout: APPROVAL_TIMEOUT,
    }
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
    fn new() -> Self {
        Self::with_sink(false)
    }

    /// A rig whose session's stdin refuses every write.
    fn with_failing_writes() -> Self {
        Self::with_sink(true)
    }

    fn with_sink(fail: bool) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let broker = ApprovalBroker::new(AuditLog::open(dir.path()).unwrap(), parts());
        let sink = Sink::new(fail);
        let generation = broker.register_session(session(T), sink.clone());
        Self {
            broker,
            sink,
            _dir: dir,
            generation,
        }
    }

    fn submit(&self, cli_request_id: &str, value: Value) {
        let accepted = self.broker.submit(Incoming::Request {
            tag: T.into(),
            generation: self.generation,
            cli_request_id: cli_request_id.into(),
            value,
        });
        assert!(accepted.is_ok(), "the broker takes a request without waiting");
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    /// Wait (real time, capped) for the request carrying `tool_use_id` to have an outcome entry.
    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.entries().into_iter().find(|e| {
                matches!(e.event, Event::Outcome { .. })
                    && e.tool_use_id.as_deref() == Some(tool_use_id)
            })
        })
        .await
    }

    /// The `request` entry of `tool_use_id`, once its outcome is in.
    async fn request_entry(&self, tool_use_id: &str) -> Entry {
        self.wait_outcome(tool_use_id).await;
        let mut found: Vec<Entry> = self
            .entries()
            .into_iter()
            .filter(|e| {
                matches!(e.event, Event::Request { .. })
                    && e.tool_use_id.as_deref() == Some(tool_use_id)
            })
            .collect();
        assert_eq!(found.len(), 1, "one request entry for {tool_use_id}");
        found.remove(0)
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
            start.elapsed() < Duration::from_secs(20),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(5));
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

fn deny(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

// ── N2a: the request entry does not say the input twice ───────────────────────

#[tokio::test(start_paused = true)]
async fn the_request_entry_keeps_the_full_input_once_and_cli_request_does_not_repeat_it() {
    let rig = Rig::new();
    let all = fixture_request("all_fields");
    rig.submit("cli-1", all.clone());

    let entry = rig.request_entry("toolu_all_fields_0").await;

    let Event::Request {
        input, cli_request, ..
    } = &entry.event
    else {
        unreachable!()
    };
    assert_eq!(input, &all["input"], "the full input, as received");
    let cli_request = cli_request.as_ref().expect("the CLI's request is recorded");
    assert!(
        cli_request.get("input").is_none(),
        "cli_request does not repeat the input: {cli_request}"
    );
    assert_eq!(
        cli_request,
        &without_input(&all),
        "every other field the CLI sent is still there, as received"
    );
}

#[tokio::test(start_paused = true)]
async fn a_request_that_cannot_be_read_also_keeps_its_input_once() {
    let rig = Rig::new();
    let malformed = fixture_request("malformed"); // input is a string, not an object
    let mut with_id = malformed.clone();
    with_id["tool_use_id"] = json!("toolu_bad_input");
    rig.submit("cli-1", with_id.clone());

    let entry = rig.request_entry("toolu_bad_input").await;

    let Event::Request {
        input, cli_request, ..
    } = &entry.event
    else {
        unreachable!()
    };
    assert_eq!(input, &with_id["input"], "what was received, in `input`");
    let cli_request = cli_request.as_ref().unwrap();
    assert!(cli_request.get("input").is_none(), "{cli_request}");
    assert_eq!(cli_request, &without_input(&with_id));
}

// ── N2b: display_text is sanitized and bounded like every recorded string ─────

#[tokio::test(start_paused = true)]
async fn display_text_of_a_huge_command_is_cut_at_the_recorded_string_limit_but_input_stays_whole() {
    let rig = Rig::new();
    // Over the recorded-string limit, under the display cap (32 KiB), so it is
    // displayed in full and the log cuts the text.
    let command = "echo hello world\n".repeat(1_800); // 30 600 bytes
    assert!(command.len() > MAX_RECORDED_STRING_BYTES);
    assert!(command.len() < nostromo::approvals::display::MAX_DISPLAY_COMMAND_BYTES);
    rig.submit("cli-1", bash_request("toolu_huge", &command));

    let entry = rig.request_entry("toolu_huge").await;

    let Event::Request {
        input,
        display_text,
        ..
    } = &entry.event
    else {
        unreachable!()
    };
    let display_text = display_text.as_deref().expect("a display text");
    assert!(
        display_text.len() <= MAX_RECORDED_STRING_BYTES + 64,
        "display_text is bounded like every recorded string: {} bytes",
        display_text.len()
    );
    assert!(display_text.starts_with("echo hello world"), "{display_text:.80}");
    assert!(
        display_text.contains("truncated"),
        "and says it was cut: ...{}",
        &display_text[display_text.len().saturating_sub(40)..]
    );
    assert_eq!(
        input["command"].as_str(),
        Some(command.as_str()),
        "the PRD's full input as received is untouched"
    );
}

#[tokio::test(start_paused = true)]
async fn display_text_of_a_huge_file_write_is_bounded_too() {
    let rig = Rig::new();
    let content = "line of content\n".repeat(10_000);
    rig.submit(
        "cli-1",
        json!({
            "subtype": "can_use_tool",
            "tool_name": "Write",
            "input": { "file_path": "/tmp/big.txt", "content": content },
            "tool_use_id": "toolu_big_write",
        }),
    );

    let entry = rig.request_entry("toolu_big_write").await;

    let Event::Request { display_text, .. } = &entry.event else {
        unreachable!()
    };
    let len = display_text.as_deref().expect("a display text").len();
    assert!(len <= MAX_RECORDED_STRING_BYTES + 64, "{len} bytes");
}

#[tokio::test(start_paused = true)]
async fn display_text_shows_a_bidi_control_as_a_visible_token_never_as_the_raw_character() {
    let rig = Rig::new();
    rig.submit(
        "cli-1",
        bash_request("toolu_bidi", "echo safe \u{202E}txet nedih"),
    );

    let entry = rig.request_entry("toolu_bidi").await;

    let Event::Request { display_text, .. } = &entry.event else {
        unreachable!()
    };
    let display_text = display_text.as_deref().expect("a display text");
    assert!(
        display_text.contains("\u{27E8}U+202E"),
        "the control shows as a ⟨U+202E…⟩ token: {display_text:?}"
    );
    assert!(
        !display_text.contains('\u{202E}'),
        "never the raw character: {display_text:?}"
    );
}

// ── N2c: startup_reconcile and files it cannot read as one string ─────────────

fn pending_request_entry(request_id: &str, ts: DateTime<Utc>) -> Entry {
    let mut e = Entry::new(
        Event::Request {
            tool_name: "Bash".into(),
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
    e.tag = Some("T".into());
    e.tool_use_id = Some(format!("toolu_{request_id}"));
    e
}

fn broker_on(dir: &Path) -> ApprovalBroker {
    ApprovalBroker::new(AuditLog::open(dir).unwrap(), parts())
}

/// Append `bytes` + newline to the audit file `ts` belongs to.
fn append_raw_line(log: &AuditLog, ts: DateTime<Utc>, bytes: &[u8]) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log.file_for(ts))
        .unwrap();
    file.write_all(bytes).unwrap();
    file.write_all(b"\n").unwrap();
}

#[test]
fn a_64_mib_line_of_junk_in_the_audit_file_does_not_stop_an_open_request_being_reconciled() {
    let dir = tempfile::tempdir().unwrap();
    let log = AuditLog::open(dir.path()).unwrap();
    let asked_at = Utc::now() - ChronoDuration::minutes(5);
    let mut junk = Vec::with_capacity(64 * 1024 * 1024 + 16);
    junk.extend_from_slice(b"{\"v\":1,\"id\":\"");
    junk.resize(64 * 1024 * 1024, b'x');
    append_raw_line(&log, asked_at, &junk);
    drop(junk);
    log.append(&pending_request_entry("req-open", asked_at))
        .unwrap();
    let broker = broker_on(dir.path());

    let started = Instant::now();
    let reconciled = broker.startup_reconcile(Utc::now()).unwrap();
    let took = started.elapsed();

    assert_eq!(reconciled, 1, "the open request is closed as a crash");
    assert!(
        took < Duration::from_secs(20),
        "a single huge line is read in modest time: {took:?}"
    );
    let ended: Vec<String> = log
        .read(everything(), &AuditFilter::default())
        .unwrap()
        .into_iter()
        .filter(|e| matches!(&e.event, Event::Outcome { outcome, .. } if outcome == "restart_crash"))
        .filter_map(|e| e.request_id)
        .collect();
    assert_eq!(ended, ["req-open"]);
    assert_eq!(
        broker.startup_reconcile(Utc::now()).unwrap(),
        0,
        "and it stays closed"
    );
}

#[test]
fn a_corrupt_line_that_is_not_text_does_not_stop_an_open_request_being_reconciled() {
    let dir = tempfile::tempdir().unwrap();
    let log = AuditLog::open(dir.path()).unwrap();
    let asked_at = Utc::now() - ChronoDuration::minutes(5);
    append_raw_line(&log, asked_at, &[0xff, 0xfe, 0x80, b'{', 0xc3, 0x28, 0xa0, 0xa1]);
    log.append(&pending_request_entry("req-open", asked_at))
        .unwrap();
    append_raw_line(&log, asked_at, &[0xf0, 0x28, 0x8c, 0xbc]);
    let broker = broker_on(dir.path());

    let reconciled = broker
        .startup_reconcile(Utc::now())
        .expect("one unreadable line is skipped, as a line that is not JSON is");

    assert_eq!(reconciled, 1);
    // (Every daily file: the outcome goes to the file of the day it is written.)
    let mut raw = Vec::new();
    for file in std::fs::read_dir(dir.path()).unwrap() {
        let path = file.unwrap().path();
        if path.extension().is_some_and(|e| e == "jsonl") {
            raw.extend(std::fs::read(path).unwrap());
        }
    }
    let text = String::from_utf8_lossy(&raw);
    assert!(
        text.contains("\"outcome\":\"restart_crash\"") && text.contains("req-open"),
        "the crash outcome was appended"
    );
}

// ── N2d: sweep carries on past a file it cannot delete ────────────────────────

#[test]
fn sweeping_carries_on_past_a_file_that_cannot_be_deleted_and_reports_the_failure() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("audit")).unwrap();
    let now = Utc::now();
    assert_eq!(RETENTION_DAYS, 90);
    let old = |days: i64| now - ChronoDuration::days(days);
    let file_of = |days: i64| log.file_for(old(days));
    // Three "files" that cannot be unlinked: directories with the daily files' names.
    // One is made first, one last and one in between, so whichever order the
    // directory is listed in (oldest first, newest first, hashed) a sweep that
    // gives up at its first failure leaves some deletable file behind.
    let stuck_dir = |days: i64| {
        let path = file_of(days);
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("inside"), "x").unwrap();
        path
    };
    let mut stuck = vec![stuck_dir(120)];
    let mut deletable = Vec::new();
    for days in 91..=110 {
        log.append(&pending_request_entry(&format!("old-{days}"), old(days)))
            .unwrap();
        deletable.push(file_of(days));
        if days == 100 {
            stuck.push(stuck_dir(130));
        }
    }
    stuck.push(stuck_dir(140));
    log.append(&pending_request_entry("recent", old(89))).unwrap();
    log.append(&pending_request_entry("today", now)).unwrap();

    let result = log.sweep(now);

    assert!(
        result.is_err(),
        "the failure is reported (Ok would hide a file that was kept): {result:?}"
    );
    for path in &deletable {
        assert!(
            !path.exists(),
            "{} should have been deleted although another file could not be",
            path.display()
        );
    }
    for path in &stuck {
        assert!(path.exists(), "{} is still there", path.display());
    }
    assert!(log.file_for(old(89)).exists(), "89 days old is within retention");
    assert!(log.file_for(now).exists(), "today's file is untouched");
}

// ── N4: what the agent is told is true in this slice ──────────────────────────

#[tokio::test(start_paused = true)]
async fn a_request_with_nobody_to_ask_is_told_the_approval_screen_is_not_available_yet() {
    let rig = Rig::new();
    rig.submit("cli-1", bash_request("toolu_1", "rm -rf /tmp/x/a"));

    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(
        rig.sink.writes(),
        [("cli-1".to_owned(), deny(APPROVAL_UNAVAILABLE_TEXT))]
    );
    assert_eq!(outcome_name(&outcome), "approval_unavailable");
    assert!(
        !APPROVAL_UNAVAILABLE_TEXT.contains("app is closed"),
        "the app may well be open in this slice: the text must not say it is closed"
    );
}

#[tokio::test(start_paused = true)]
async fn ask_user_question_and_exit_plan_mode_requests_get_the_same_text() {
    let rig = Rig::new();
    rig.submit(
        "cli-q",
        json!({
            "subtype": "can_use_tool",
            "tool_name": "AskUserQuestion",
            "input": { "questions": [{ "question": "Which one?", "options": [{ "label": "a" }, { "label": "b" }] }] },
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
        let outcome = rig.wait_outcome(id).await;
        assert_eq!(outcome_name(&outcome), "approval_unavailable", "{id}");
    }

    let mut writes = rig.sink.writes();
    writes.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        writes,
        [
            ("cli-p".to_owned(), deny(APPROVAL_UNAVAILABLE_TEXT)),
            ("cli-q".to_owned(), deny(APPROVAL_UNAVAILABLE_TEXT)),
        ],
        "the same path, the same words"
    );
}

// ── N5: a deny that could not be written is not recorded as a clean ending ────

#[tokio::test(start_paused = true)]
async fn a_deny_that_could_not_be_written_is_logged_deny_write_failed_with_the_outcome_it_would_have_had(
) {
    let rig = Rig::with_failing_writes();
    rig.submit("cli-1", bash_request("toolu_1", "rm -rf /tmp/x/a"));

    let outcome = rig.wait_outcome("toolu_1").await;

    assert_eq!(outcome_name(&outcome), "deny_write_failed");
    assert_eq!(
        outcome_rule(&outcome),
        Some(json!({ "intended_outcome": "approval_unavailable" })),
        "the entry says what the ending would have been"
    );
    assert!(rig.sink.writes().is_empty(), "nothing reached the session");
    let entries = rig.entries();
    assert_eq!(
        entries
            .iter()
            .filter(|e| matches!(e.event, Event::Outcome { .. }))
            .count(),
        1,
        "still exactly one outcome"
    );
    assert_eq!(
        entries
            .iter()
            .filter(|e| matches!(e.event, Event::Request { .. }))
            .count(),
        1
    );
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_request_whose_deny_could_not_be_written_says_so_and_names_what_it_would_have_been(
) {
    let rig = Rig::with_failing_writes();
    // The fixture has no tool_use_id: give it one to find its entries by, and take
    // the tool name away so that it cannot be read.
    let mut malformed = fixture_request("malformed");
    malformed["tool_use_id"] = json!("toolu_bad");
    malformed.as_object_mut().unwrap().remove("tool_name");
    rig.submit("cli-1", malformed);

    let outcome = rig.wait_outcome("toolu_bad").await;

    assert_eq!(outcome_name(&outcome), "deny_write_failed");
    assert_eq!(
        outcome_rule(&outcome),
        Some(json!({ "intended_outcome": "invalid_request" }))
    );
}
