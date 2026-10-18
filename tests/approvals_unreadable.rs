//! A permission request the daemon cannot fully parse must still be answered
//! (PR #270 review fix-ups B1 and N3), through real `SessionManager` sessions
//! and the hermetic fake `claude` of `tests/support/fake_claude_perm.py`.
//!
//! The CLI waits forever for an answer to a `can_use_tool` request (it has no
//! timeout of its own), so a request the daemon silently drops hangs the
//! session. What these tests pin, from the outside:
//!
//! - a `can_use_tool` line that serde cannot parse (nested too deep, malformed,
//!   cut off, over the size cap, or with a non-string `request_id`) is still
//!   denied, once, under the id it arrived with (a number stays a number), and
//!   is on record as a `request` followed by an `outcome: invalid_request`;
//! - a request whose id cannot be recovered at all is not answered (there is no
//!   id to answer) and leaves one `request_unparseable` outcome entry;
//! - a line that is not a control request is ignored exactly as it always was
//!   (nothing written, nothing audited, transcript unchanged);
//! - a control request of any other subtype gets one `error` control_response;
//! - the session is never wedged by any of it: a normal prompt right after is
//!   still denied once.
//!
//! Only API that exists today is used (the new constants are written out as the
//! literals the fix-up plan fixes), so this file compiles against the current
//! code and fails there for the behavioural reason.
//!
//! Environment variables are process-wide and tests run on parallel threads, so
//! every test takes `ENV_LOCK` for its whole duration and builds its own paused
//! runtime.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    ApprovalBroker, BrokerParts, Incoming, Presenter, SessionInfo, SessionSink,
    INVALID_REQUEST_MESSAGE, REQUEST_TIMEOUT,
};
use nostromo::approvals::guard::{
    self, hook_settings_json, PaneInfo, PaneProbe, ProbeError, TmuxSocket,
};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::session_manager::{
    build_claude_args_with, SessionManager, SessionRestrictions, CLAUDE_BIN_ENV,
};
use nostromo::ipc::stream_json::SessionState;
use serde_json::{json, Value};

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);
const BARRIER: &str = "barrier";
const FOCUS: &str = "focus-1";
/// Text the fake puts only into lines the daemon must ignore.
const MARK: &str = "ZZ-GARBAGE-MARK-ZZ";

/// How long a deny may take, in real time. A request nobody answers hangs the
/// CLI forever, so on a broken daemon the wait fails fast instead.
const DENY_WITHIN: Duration = Duration::from_secs(6);
/// The same for the biggest lines (a 4 MiB line, a 100,000-deep input).
const BIG_WITHIN: Duration = Duration::from_secs(10);

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

/// "Can anyone be asked?" (`hold`, changeable mid-test). The barrier tag is always "no".
struct TestPresenter {
    hold: AtomicBool,
    asked: AtomicUsize,
}

impl Presenter for TestPresenter {
    fn can_present(&self, tag: &str) -> bool {
        if tag == BARRIER {
            return false;
        }
        self.asked.fetch_add(1, Ordering::SeqCst);
        self.hold.load(Ordering::SeqCst)
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

// ── the world a test runs in ──────────────────────────────────────────────────

#[derive(Default)]
struct Opts {
    hold: bool,
}

/// A manager that kills every fake it started when it goes out of scope, a failed
/// assertion included.
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

        let presenter = Arc::new(TestPresenter {
            hold: AtomicBool::new(opts.hold),
            asked: AtomicUsize::new(0),
        });
        let broker = ApprovalBroker::new(
            AuditLog::open(&approvals_dir).unwrap(),
            BrokerParts {
                presenter: presenter.clone(),
                probe: Arc::new(|| Box::new(NoPanes)),
                settings: Arc::new(NoRules),
                timeout: REQUEST_TIMEOUT,
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
    fn spawn(&mut self, tag: &str) -> Fake {
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
                false,
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

    /// Entries of the focus under test (not the barrier's).
    fn focus_entries(&self) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| e.tag.as_deref() == Some(FOCUS))
            .collect()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| is_outcome(e) && e.tool_use_id.as_deref() == Some(tool_use_id))
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

    /// The transcript clients are sent when they attach, as JSON (one element per turn).
    fn transcript(&mut self, client: &str) -> Value {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ServerMsg>();
        self.mgr
            .client_sender_registry()
            .lock()
            .unwrap()
            .insert(client.into(), tx);
        self.mgr.attach(FOCUS, client).expect("attach");
        let mut turns = None;
        while let Ok(msg) = rx.try_recv() {
            if let ServerMsg::SessionTurns { turns: t, .. } = msg {
                turns = Some(serde_json::to_value(&t).unwrap());
            }
        }
        self.mgr.detach(FOCUS, client);
        turns.expect("a snapshot is sent on attach")
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
    /// `tool_use_id` is only set when the answer carried an id the fake had issued.
    fn responses(&self) -> Vec<Value> {
        self.read_lines("responses.jsonl")
    }

    /// Every line the daemon wrote to the fake's stdin, as written.
    fn raw_stdin(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("stdin.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The `control_response` frames the daemon wrote.
    fn control_frames(&self) -> Vec<Value> {
        self.read_lines("stdin.jsonl")
            .into_iter()
            .filter(|f| f["type"] == "control_response")
            .collect()
    }

    async fn argv(&self) -> Vec<String> {
        wait_until("the fake to record its argv", || {
            let text = std::fs::read_to_string(self.dir.join("argv.json")).ok()?;
            serde_json::from_str::<Vec<String>>(&text).ok()
        })
        .await
    }

    async fn wait_responses(&self, n: usize, limit: Duration) -> Vec<Value> {
        wait_until_for(&format!("{n} answer(s) to reach the fake"), limit, || {
            let r = self.responses();
            (r.len() >= n).then_some(r)
        })
        .await
    }

    /// T-AP0a-1, widened for the error answers: every `control_response` the
    /// daemon ever wrote is a deny (success + `behavior: deny`) or an `error`
    /// (no behavior at all), never an allow.
    #[track_caller]
    fn assert_never_allowed(&self) {
        let raw = std::fs::read_to_string(self.dir.join("stdin.jsonl")).unwrap_or_default();
        for frame in self.control_frames() {
            match frame["response"]["subtype"].as_str() {
                Some("error") => {
                    assert!(
                        !frame.to_string().contains("behavior"),
                        "an error answer carries no behavior: {frame}"
                    );
                }
                _ => {
                    assert_eq!(frame["response"]["response"]["behavior"], "deny", "{frame}");
                    assert!(
                        frame["response"]["response"].get("updatedInput").is_none(),
                        "{frame}"
                    );
                }
            }
        }
        assert!(
            !raw.contains("\"behavior\":\"allow\"") && !raw.contains("\"behavior\": \"allow\""),
            "an allow was written to the CLI"
        );
    }
}

fn everything() -> std::ops::Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

async fn wait_until<R>(what: &str, ready: impl FnMut() -> Option<R>) -> R {
    wait_until_for(what, Duration::from_secs(30), ready).await
}

async fn wait_until_for<R>(what: &str, limit: Duration, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < limit,
            "timed out (real time, {limit:?}) waiting for {what}"
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

fn is_request(e: &Entry) -> bool {
    matches!(e.event, Event::Request { .. })
}

fn is_outcome(e: &Entry) -> bool {
    matches!(e.event, Event::Outcome { .. })
}

fn outcome_name(e: &Entry) -> &str {
    match &e.event {
        Event::Outcome { outcome, .. } => outcome,
        other => panic!("not an outcome: {other:?}"),
    }
}

fn request_tool(e: &Entry) -> &str {
    match &e.event {
        Event::Request { tool_name, .. } => tool_name,
        other => panic!("not a request: {other:?}"),
    }
}

/// The frame the CLI must receive to be told no, with `message`, under `id`
/// (a JSON value: a string, or a number if that is what the CLI sent).
fn deny_frame_for(id: &Value, message: &str) -> Value {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": id,
            "response": { "behavior": "deny", "message": message }
        }
    })
}

// ── shared checks ─────────────────────────────────────────────────────────────

/// The `nth` (1-based) answered request of this session was an unreadable one:
/// it was denied once, as invalid, under `id` (or, with `None`, under the id the
/// CLI issued for the tool use `tool_use_id`), and is on record as a `request`
/// with its `outcome: invalid_request`. Nothing else was written or logged.
async fn expect_unreadable_denied(
    w: &mut World,
    fake: &Fake,
    nth: usize,
    id: Option<&Value>,
    tool_use_id: &str,
    tool: &str,
    limit: Duration,
) {
    let responses = fake.wait_responses(nth, limit).await;
    w.wait_idle(FOCUS).await;
    w.barrier().await;
    settle().await;

    let recorded = &fake.responses()[nth - 1];
    let id = match id {
        Some(id) => id.clone(),
        None => {
            assert_eq!(
                recorded["tool_use_id"], tool_use_id,
                "the answer carries the very id the CLI sent: {recorded}"
            );
            recorded["request_id"].clone()
        }
    };
    assert_eq!(
        responses.len(),
        fake.responses().len(),
        "no further answer arrived"
    );
    let frames = fake.control_frames();
    assert_eq!(
        frames.len(),
        nth,
        "exactly one answer for each request: {frames:?}"
    );
    assert_eq!(
        frames[nth - 1],
        deny_frame_for(&id, INVALID_REQUEST_MESSAGE),
        "a deny in the usual wrapper, under the original id, saying the request could not be read"
    );

    let entries = w.focus_entries();
    let requests: Vec<&Entry> = entries.iter().filter(|e| is_request(e)).collect();
    let outcomes: Vec<&Entry> = entries.iter().filter(|e| is_outcome(e)).collect();
    assert_eq!(
        (requests.len(), outcomes.len()),
        (nth, nth),
        "one request entry and one outcome entry per request: {entries:?}"
    );
    let (request, outcome) = (requests[nth - 1], outcomes[nth - 1]);
    assert_eq!(outcome_name(outcome), "invalid_request");
    assert!(
        request.request_id.is_some() && request.request_id == outcome.request_id,
        "the two entries are one request: {request:?} {outcome:?}"
    );
    if let Some(cli_id) = id.as_str() {
        assert_ne!(
            request.request_id.as_deref(),
            Some(cli_id),
            "the log's id is Nostromo's own"
        );
    }
    assert_eq!(request.tag.as_deref(), Some(FOCUS));
    assert_eq!(outcome.tag.as_deref(), Some(FOCUS));
    assert_eq!(request_tool(request), tool);
    assert!(request.ts <= outcome.ts);
    fake.assert_never_allowed();
}

/// A normal prompt after all that is still answered, once: the session is not wedged.
async fn expect_session_still_flows(w: &mut World, fake: &Fake, answers_before: usize) {
    w.presenter.hold.store(false, Ordering::SeqCst);
    w.say(FOCUS, "FIXTURE:simple_rm");
    let responses = fake.wait_responses(answers_before + 1, DENY_WITHIN).await;
    let last = &responses[answers_before];
    assert_eq!(last["tool_use_id"], "toolu_simple_rm_0");
    assert_eq!(last["response"]["response"]["response"]["behavior"], "deny");
    w.wait_outcome("toolu_simple_rm_0").await;
    w.wait_idle(FOCUS).await;
    settle().await;
    assert_eq!(
        w.outcomes("toolu_simple_rm_0").len(),
        1,
        "one outcome for the prompt after it"
    );
    assert_eq!(
        fake.responses().len(),
        answers_before + 1,
        "and one answer"
    );
    fake.assert_never_allowed();
}

fn deep_case(depth: usize, limit: Duration) {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        let started = Instant::now();

        w.say(FOCUS, &format!("RAW:deep:{depth}"));
        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            None,
            &format!("toolu_deep_{depth}"),
            "Bash",
            limit,
        )
        .await;
        let took = started.elapsed();

        assert!(
            took < limit,
            "a {depth}-deep request is denied in bounded time: {took:?}"
        );
        expect_session_still_flows(&mut w, &fake, 1).await;
    });
}

// ── B1: a request serde cannot parse is still denied ──────────────────────────

#[test]
fn a_request_nested_100_deep_still_parses_and_is_answered_the_normal_way() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        w.say(FOCUS, "RAW:deep:100");
        let responses = fake.wait_responses(1, DENY_WITHIN).await;
        w.wait_idle(FOCUS).await;
        let outcome = w.wait_outcome("toolu_deep_100").await;

        assert_eq!(
            responses[0]["tool_use_id"], "toolu_deep_100",
            "the answer carries the CLI's id"
        );
        let frame = &responses[0]["response"];
        assert_eq!(frame["response"]["response"]["behavior"], "deny");
        assert_ne!(
            frame["response"]["response"]["message"], INVALID_REQUEST_MESSAGE,
            "it was read fine: it is denied by the ordinary route, not as unreadable"
        );
        assert!(
            ["no_app", "approval_unavailable"].contains(&outcome_name(&outcome)),
            "the ordinary outcome, not invalid_request: {}",
            outcome_name(&outcome)
        );
        let entries = w.focus_entries();
        assert_eq!(entries.iter().filter(|e| is_request(e)).count(), 1);
        assert_eq!(entries.iter().filter(|e| is_outcome(e)).count(), 1);
        assert_eq!(fake.control_frames().len(), 1);
        fake.assert_never_allowed();
    });
}

#[test]
fn a_request_nested_127_deep_is_denied_by_its_original_id_and_recorded_as_invalid() {
    deep_case(127, DENY_WITHIN);
}

#[test]
fn a_request_nested_128_deep_is_denied_by_its_original_id_and_recorded_as_invalid() {
    deep_case(128, DENY_WITHIN);
}

#[test]
fn a_request_nested_500_deep_is_denied_by_its_original_id_and_recorded_as_invalid() {
    deep_case(500, DENY_WITHIN);
}

#[test]
fn a_request_nested_100000_deep_is_denied_within_ten_seconds_without_overflowing_the_stack() {
    deep_case(100_000, BIG_WITHIN);
}

#[test]
fn a_deep_request_is_denied_whichever_order_its_top_level_keys_come_in() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        for (i, kind) in ["deep_id_last", "deep_type_last", "deep_subtype_last"]
            .iter()
            .enumerate()
        {
            w.say(FOCUS, &format!("RAW:{kind}:500"));
            expect_unreadable_denied(
                &mut w,
                &fake,
                i + 1,
                None,
                &format!("toolu_{kind}_500"),
                "Bash",
                DENY_WITHIN,
            )
            .await;
        }
        expect_session_still_flows(&mut w, &fake, 3).await;
    });
}

#[test]
fn decoy_ids_subtypes_and_tool_names_inside_a_deep_input_are_not_taken_for_the_requests_own() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        // `input` carries "request_id":"evil-id", "subtype":"elicitation", "tool_name":"Evil".
        w.say(FOCUS, "RAW:deep_decoys:500");

        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            None,
            "toolu_deep_decoys_500",
            "Bash",
            DENY_WITHIN,
        )
        .await;
        let frames = fake.control_frames();
        assert_ne!(
            frames[0]["response"]["request_id"], "evil-id",
            "answered under the request's own id"
        );
        assert_eq!(
            frames[0]["response"]["subtype"], "success",
            "treated as the can_use_tool it is, not as the elicitation the decoy claims"
        );
    });
}

#[test]
fn a_request_with_a_numeric_id_is_denied_with_that_same_number() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        w.say(FOCUS, "RAW:numid");
        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            Some(&json!(7)),
            "toolu_numid_0",
            "Bash",
            DENY_WITHIN,
        )
        .await;

        let raw: Vec<String> = fake
            .raw_stdin()
            .into_iter()
            .filter(|l| l.contains("control_response"))
            .collect();
        assert_eq!(raw.len(), 1, "{raw:?}");
        assert!(
            raw[0].contains("\"request_id\":7"),
            "the id is the JSON number 7 on the wire, not the string \"7\": {}",
            raw[0]
        );
        assert!(!raw[0].contains("\"request_id\":\"7\""), "{}", raw[0]);
        let frame: Value = serde_json::from_str(&raw[0]).unwrap();
        assert!(frame["response"]["request_id"].is_u64());
        expect_session_still_flows(&mut w, &fake, 1).await;
    });
}

#[test]
fn a_deep_request_with_a_numeric_id_is_denied_with_that_same_number() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        w.say(FOCUS, "RAW:numid_deep:500");

        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            Some(&json!(7)),
            "toolu_numid_deep_500",
            "Bash",
            DENY_WITHIN,
        )
        .await;
        assert!(fake.raw_stdin().iter().any(|l| l.contains("\"request_id\":7")));
        expect_session_still_flows(&mut w, &fake, 1).await;
    });
}

#[test]
fn a_request_over_the_four_mib_cap_is_denied_by_its_id_and_recorded_as_invalid() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        // A valid can_use_tool line a little over 4 MiB long (a huge command).
        w.say(FOCUS, "RAW:oversize");
        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            None,
            "toolu_oversize_0",
            "Bash",
            BIG_WITHIN,
        )
        .await;
        expect_session_still_flows(&mut w, &fake, 1).await;
    });
}

#[test]
fn a_request_cut_off_or_malformed_after_its_id_is_denied_by_that_id() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        // (cue, the tool name the daemon could still read)
        for (i, (kind, tool)) in [
            ("truncated", "Bash"),
            ("malformed", "Bash"),
            ("id_only", "unknown"),
        ]
        .iter()
        .enumerate()
        {
            w.say(FOCUS, &format!("RAW:{kind}"));
            expect_unreadable_denied(
                &mut w,
                &fake,
                i + 1,
                None,
                &format!("toolu_{kind}_0"),
                tool,
                DENY_WITHIN,
            )
            .await;
        }
        expect_session_still_flows(&mut w, &fake, 3).await;
    });
}

#[test]
fn an_id_full_of_json_escapes_comes_back_exactly_as_the_cli_sent_it() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        // ab"c\dé 😀 + newline, written with \" \\ é 😀 \n in the line.
        let decoded = json!("ab\"c\\d\u{e9} \u{1F600}\n");

        w.say(FOCUS, "RAW:escaped_id");

        expect_unreadable_denied(
            &mut w,
            &fake,
            1,
            Some(&decoded),
            "toolu_escaped_id_0",
            "Bash",
            DENY_WITHIN,
        )
        .await;
        assert_eq!(
            fake.responses()[0]["tool_use_id"], "toolu_escaped_id_0",
            "the CLI recognised the id as its own"
        );
    });
}

#[test]
fn a_request_whose_id_cannot_be_recovered_is_not_answered_and_leaves_one_unparseable_entry() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        // Cut off before request_id; and a request_id that is an object.
        for (i, kind) in ["no_id", "object_id"].iter().enumerate() {
            w.say(FOCUS, &format!("RAW:{kind}"));
            w.wait_idle(FOCUS).await;
            w.barrier().await;
            settle().await;

            assert!(
                fake.control_frames().is_empty(),
                "{kind}: there is no id to answer under, so nothing is written: {:?}",
                fake.raw_stdin()
            );
            let entries = w.focus_entries();
            assert_eq!(
                entries.len(),
                i + 1,
                "{kind}: exactly one more audit entry: {entries:?}"
            );
            let entry = &entries[i];
            assert_eq!(outcome_name(entry), "request_unparseable", "{kind}");
            assert!(
                entry.request_id.is_none() && entry.tool_use_id.is_none(),
                "{kind}: no ids to record: {entry:?}"
            );
            assert_eq!(entry.tag.as_deref(), Some(FOCUS), "{kind}");
        }
        assert_eq!(
            w.focus_entries().iter().filter(|e| is_request(e)).count(),
            0,
            "no request entry for what could not be read at all"
        );
        // The turns ended (the fake ended them) and the session carries on.
        expect_session_still_flows(&mut w, &fake, 0).await;
    });
}

#[test]
fn lines_that_are_not_control_requests_are_ignored_exactly_as_before() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        w.say(FOCUS, "hello baseline");
        w.wait_idle(FOCUS).await;
        let baseline = w.transcript("c0");
        let baseline_turn = baseline[0]["blocks"].clone();
        assert!(!baseline_turn.as_array().unwrap().is_empty());

        // Garbage; an assistant line cut off; a valid line of an unknown type that
        // merely looks like a request; deep assistant lines (serde cannot parse
        // them); an assistant line whose *nested* object looks like a control_request.
        let cues = [
            "RAW:garbage",
            "RAW:bad_assistant",
            "RAW:unknown_type",
            "RAW:deep_assistant:500",
            "RAW:deep_assistant:100000",
            "RAW:nested_type:500",
        ];
        for (i, cue) in cues.iter().enumerate() {
            w.say(FOCUS, cue);
            w.wait_idle(FOCUS).await;
            w.barrier().await;
            settle().await;

            assert!(
                fake.control_frames().is_empty(),
                "{cue}: nothing is written to the CLI: {:?}",
                fake.raw_stdin()
            );
            assert!(
                w.focus_entries().is_empty(),
                "{cue}: nothing is audited: {:?}",
                w.focus_entries()
            );
            let transcript = w.transcript(&format!("c{}", i + 1));
            assert_eq!(
                transcript.as_array().unwrap().len(),
                i + 2,
                "{cue}: one turn per message and no more"
            );
            assert_eq!(
                transcript[i + 1]["blocks"],
                baseline_turn,
                "{cue}: the line added nothing to the transcript"
            );
            assert!(!transcript.to_string().contains(MARK), "{cue}");
        }
        assert_eq!(
            w.entries().iter().filter(|e| e.tag.as_deref() != Some(BARRIER)).count(),
            0
        );
        expect_session_still_flows(&mut w, &fake, 0).await;
    });
}

#[test]
fn an_unreadable_request_is_denied_at_once_and_never_put_in_front_of_anyone() {
    run(
        Opts { hold: true },
        |mut w| async move {
            let fake = w.spawn(FOCUS);

            w.say(FOCUS, "RAW:deep:500");

            expect_unreadable_denied(
                &mut w,
                &fake,
                1,
                None,
                "toolu_deep_500",
                "Bash",
                DENY_WITHIN,
            )
            .await;
            assert_eq!(
                w.presenter.asked.load(Ordering::SeqCst),
                0,
                "a request nobody can read is never put in front of a person, even when someone could be asked"
            );
        },
    );
}

// ── N3: any other kind of control request gets an error answer ────────────────

/// The `nth` answer was an `error` for the request the CLI issued for `tool_use_id`;
/// nothing was audited. Returns its error text.
async fn expect_error_answer(w: &mut World, fake: &Fake, nth: usize, tool_use_id: &str) -> String {
    fake.wait_responses(nth, DENY_WITHIN).await;
    w.wait_idle(FOCUS).await;
    w.barrier().await;
    settle().await;

    let recorded = &fake.responses()[nth - 1];
    assert_eq!(
        recorded["tool_use_id"], tool_use_id,
        "the error is addressed to the request the CLI sent: {recorded}"
    );
    let frames = fake.control_frames();
    assert_eq!(frames.len(), nth, "exactly one answer each: {frames:?}");
    let response = &frames[nth - 1]["response"];
    assert_eq!(frames[nth - 1]["type"], "control_response");
    assert_eq!(response["subtype"], "error", "{response}");
    assert_eq!(response["request_id"], recorded["request_id"]);
    let error = response["error"]
        .as_str()
        .unwrap_or_else(|| panic!("an error text: {response}"));
    assert!(
        !error.is_empty() && error.len() <= 200,
        "a short fixed text: {error:?}"
    );
    assert!(
        w.focus_entries().is_empty(),
        "a request that is not a permission prompt leaves no audit entry: {:?}",
        w.focus_entries()
    );
    fake.assert_never_allowed();
    error.to_owned()
}

#[test]
fn a_control_request_that_is_not_a_permission_prompt_gets_one_error_answer_and_no_audit_entry() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        // A hook_callback (the repository fixture) and an elicitation.
        w.say(FOCUS, "FIXTURE:non_can_use_tool");
        let first = expect_error_answer(&mut w, &fake, 1, "toolu_non_can_use_tool_0").await;
        w.say(FOCUS, "RAW:other:elicitation");
        let second = expect_error_answer(&mut w, &fake, 2, "toolu_other_elicitation").await;

        assert_eq!(first, second, "the same fixed text for every subtype");
        assert!(
            fake.control_frames().iter().all(|f| f["response"]["subtype"] == "error"),
            "{:?}",
            fake.control_frames()
        );
        assert_eq!(w.presenter.asked.load(Ordering::SeqCst), 0);
        expect_session_still_flows(&mut w, &fake, 2).await;
    });
}

#[test]
fn an_unreadable_request_of_another_subtype_gets_the_same_error_answer() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);

        // Nested too deep to parse, but its subtype ("elicitation") can still be read.
        w.say(FOCUS, "FIXTURE:non_can_use_tool");
        let readable = expect_error_answer(&mut w, &fake, 1, "toolu_non_can_use_tool_0").await;
        w.say(FOCUS, "RAW:other_deep:elicitation");
        let unreadable = expect_error_answer(&mut w, &fake, 2, "toolu_other_deep_elicitation").await;

        assert_eq!(
            readable, unreadable,
            "not a deny and not an invalid_request: the same error as a readable one"
        );
        expect_session_still_flows(&mut w, &fake, 2).await;
    });
}

// ── T-AP0a-1, widened: no path writes an allow ────────────────────────────────

#[test]
fn every_answer_written_for_an_unreadable_or_unsupported_request_is_a_deny_or_an_error_never_an_allow(
) {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        let mut answered = 0;
        for cue in [
            "RAW:deep:500",
            "RAW:numid",
            "RAW:truncated",
            "RAW:no_id",
            "RAW:other:elicitation",
            "RAW:other_deep:elicitation",
            "FIXTURE:simple_rm",
        ] {
            w.say(FOCUS, cue);
            if cue != "RAW:no_id" {
                answered += 1;
                fake.wait_responses(answered, DENY_WITHIN).await;
            }
            w.wait_idle(FOCUS).await;
            settle().await;
        }

        let frames = fake.control_frames();
        let errors = frames
            .iter()
            .filter(|f| f["response"]["subtype"] == "error")
            .count();
        assert_eq!(frames.len(), 6, "one answer per request that had an id: {frames:?}");
        assert_eq!((frames.len() - errors, errors), (4, 2));
        fake.assert_never_allowed();
        for e in w.entries() {
            assert!(
                !serde_json::to_string(&e).unwrap().contains("\"behavior\":\"allow\""),
                "{e:?}"
            );
            if let Event::Outcome { outcome, .. } = &e.event {
                assert!(!outcome.starts_with("allow"), "{outcome}");
            }
        }
    });
}

/// The source lines of `src` that are code (not `//` comments).
fn code_lines(src: &str) -> impl Iterator<Item = (usize, &str)> {
    src.lines()
        .enumerate()
        .map(|(i, l)| (i + 1, l.trim_start()))
        .filter(|(_, l)| !l.starts_with("//"))
}

#[test]
fn no_allow_answer_exists_anywhere_in_the_broker_or_the_reader_path() {
    // The deny-only guarantee of this slice, as a grep: no code in the broker, the
    // reader / answer path or the line parser can even spell an allow answer.
    for (name, src) in [
        ("src/approvals/broker.rs", include_str!("../src/approvals/broker.rs")),
        (
            "src/ipc/session_manager/mod.rs",
            include_str!("../src/ipc/session_manager/mod.rs"),
        ),
        ("src/ipc/stream_json.rs", include_str!("../src/ipc/stream_json.rs")),
    ] {
        for (n, line) in code_lines(src) {
            assert!(
                !line.contains("\"allow\"") && !line.contains("\\\"allow\\\""),
                "{name}:{n} can spell an allow answer: {line}"
            );
        }
    }
}

// ── N8: the restart (resume) arm of the real argv builder, end to end ─────────

fn flag_follows_guard_settings(argv: &[String], guard_settings: &str) {
    let at = argv
        .iter()
        .position(|a| a == "--settings")
        .unwrap_or_else(|| panic!("the guard's --settings: {argv:?}"));
    assert_eq!(argv[at + 1], guard_settings, "{argv:?}");
    assert_eq!(
        (argv[at + 2].as_str(), argv[at + 3].as_str()),
        ("--permission-prompt-tool", "stdio"),
        "the prompt flag comes right after the guard settings: {argv:?}"
    );
}

#[test]
fn a_restarted_session_is_resumed_with_the_prompt_flag_and_the_guard_settings() {
    run(Opts::default(), |mut w| async move {
        let fake = w.spawn(FOCUS);
        let first = fake.argv().await;
        assert!(first.iter().any(|a| a == "--session-id"), "{first:?}");

        w.mgr.restart(FOCUS).expect("restart");

        let argv = wait_until("the resumed process to record its argv", || {
            let text = std::fs::read_to_string(fake.dir.join("argv.json")).ok()?;
            let argv: Vec<String> = serde_json::from_str(&text).ok()?;
            argv.iter().any(|a| a == "--resume").then_some(argv)
        })
        .await;
        let guard_settings = hook_settings_json(w.mgr.guard_path());
        flag_follows_guard_settings(&argv, &guard_settings);
        assert_eq!(
            argv.iter().filter(|a| *a == "--permission-prompt-tool").count(),
            1,
            "{argv:?}"
        );
        let at = argv.iter().position(|a| a == "--resume").unwrap();
        assert_eq!(argv[at + 1], fake.session_id, "it resumes the same conversation");
        assert!(!argv.iter().any(|a| a == "--session-id"), "{argv:?}");

        // And the resumed process really does send its prompts to the daemon.
        w.say(FOCUS, "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1, DENY_WITHIN).await;
        assert_eq!(responses[0]["tool_use_id"], "toolu_simple_rm_0");
        fake.assert_never_allowed();
    });
}

#[test]
fn a_restarted_restricted_session_still_never_gets_the_prompt_flag() {
    run(Opts::default(), |mut w| async move {
        let restrictions = SessionRestrictions {
            builtin_tools: vec!["Read".into()],
            allowed_tools: vec!["Read".into()],
            max_budget_usd: Some(1.5),
        };
        w.mgr.restrict_tag("restricted-1", restrictions.clone());
        let fake = w.spawn("restricted-1");
        fake.argv().await;

        w.mgr.restart("restricted-1").expect("restart");

        let argv = wait_until("the resumed process to record its argv", || {
            let text = std::fs::read_to_string(fake.dir.join("argv.json")).ok()?;
            let argv: Vec<String> = serde_json::from_str(&text).ok()?;
            argv.iter().any(|a| a == "--resume").then_some(argv)
        })
        .await;
        let guard_settings = hook_settings_json(w.mgr.guard_path());
        assert_eq!(
            argv,
            build_claude_args_with(
                "cody",
                "view-restricted-1",
                false,
                &fake.session_id,
                true,
                Some(&restrictions),
                &guard_settings,
            ),
            "the restricted resume arm is what the builder gives without approvals"
        );
        assert!(!argv.iter().any(|a| a == "--permission-prompt-tool"), "{argv:?}");
        assert!(!argv.iter().any(|a| a == "stdio"), "{argv:?}");
    });
}
