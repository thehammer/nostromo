//! "Allow for this session" rules (AP4), driven at the broker the way the server drives it.
//!
//! The socket-level halves (who may create or revoke a rule, which connection is sent what,
//! the real fake CLI) live in `tests/approvals_wire.rs` and `tests/ipc_peer_gating.rs`. The
//! matcher's own unit tests are in `src/approvals/rules.rs`; nothing here repeats them.
//!
//! What is pinned (PRD AP4):
//! - R1: which requests are offered a rule, and what the candidates look like on the wire;
//! - R2: a rule exists only because the human chose one of THIS request's candidates, with its
//!   exact text, and only if the allow was really written;
//! - R3: a later request is allowed without a card only when it matches, for the same session
//!   process, requester and focus, after the guard, while an app that can revoke is connected;
//! - R4: a rule dies with its session process, however that ends, and never outlives a restart
//!   of the daemon;
//! - R6: revoking (broker level), R13: nothing but the four known endings writes an allow and
//!   `updatedPermissions` is never sent, R14: the audit trail.
//!
//! Time: paused tokio time; the broker's worker is a plain thread, so effects are polled for
//! in real time with a cap (the same way `tests/approvals_answers.rs` does).

use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    AnswerResult, ApprovalBroker, ApprovalPresenters, BrokerParts, Incoming, RevokeResult,
    SessionInfo, SessionSink, APPROVAL_TIMEOUT, NO_APP_MESSAGE,
};
use nostromo::approvals::guard::{PaneInfo, PaneProbe, ProbeError, TmuxSocket};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::approvals::rules::{CandidateKind, SessionRule};
use nostromo::approvals::wire::{
    AnswerRefusal, ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind,
    SessionRuleCandidateWire, SessionRuleWire,
};
use nostromo::ipc::protocol::ServerMsg;
use serde_json::{json, Value};
use tokio::sync::broadcast;

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer; can be told to fail or to be dead.
struct FakeSink {
    live: AtomicBool,
    fail: AtomicBool,
    writes: Mutex<Vec<(String, Value)>>,
}

impl FakeSink {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            live: AtomicBool::new(true),
            fail: AtomicBool::new(false),
            writes: Mutex::new(Vec::new()),
        })
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
        if self.fail.load(Ordering::SeqCst) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "stdin closed"));
        }
        self.writes
            .lock()
            .unwrap()
            .push((cli_request_id.to_owned(), response.clone()));
        Ok(())
    }
}

/// tmux as the guard sees it: pane `%9` runs a production shell.
struct ProdPane;

impl PaneProbe for ProdPane {
    fn pane(&self, _socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        Ok((target == "%9").then(|| PaneInfo {
            pid: 4242,
            title: "production:portal:web".into(),
        }))
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
const T2: &str = "focus-2";
const BARRIER: &str = "barrier";
const CACHES_A: &str = "rm -rf ~/Library/Caches/a";

struct Rig {
    broker: ApprovalBroker,
    /// `T`'s stdin.
    sink: Arc<FakeSink>,
    /// `T2`'s stdin.
    sink2: Arc<FakeSink>,
    frames: broadcast::Receiver<ServerMsg>,
    /// Holds the approvals directory and the home directory `~/` means.
    root: Arc<tempfile::TempDir>,
    home: PathBuf,
    generation: u64,
    generation2: u64,
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

/// A `can_use_tool` request for `command`, as raised by an ask rule that matched.
fn ask_request(tool_use_id: &str, command: &str) -> Value {
    let mut v = bash_request(tool_use_id, command);
    v["matched_ask_rule"] =
        json!({ "source": "userSettings", "tool_name": "Bash", "rule_content": "rm:*" });
    v
}

/// A `can_use_tool` request the guard lets through (no matched rule named).
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

fn from_agent(mut request: Value, agent_id: &str) -> Value {
    request["agent_id"] = json!(agent_id);
    request
}

fn input_of(command: &str) -> Value {
    json!({ "command": command, "description": "d" })
}

fn allow_body(input: Value) -> Value {
    json!({ "behavior": "allow", "updatedInput": input })
}

fn decision_with(id: Option<&str>, text: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AllowSession,
        note: None,
        answers: None,
        candidate_id: id.map(str::to_owned),
        rule_text: text.map(str::to_owned),
    }
}

fn allow_session(c: &SessionRuleCandidateWire) -> ApprovalDecision {
    decision_with(Some(&c.id), Some(&c.rule_text))
}

fn allow_once() -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AllowOnce,
        note: None,
        answers: None,
        candidate_id: None,
        rule_text: None,
    }
}

fn deny() -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::Deny,
        note: None,
        answers: None,
        candidate_id: None,
        rule_text: None,
    }
}

fn candidate(wire: &ApprovalRequestWire, kind: CandidateKind) -> SessionRuleCandidateWire {
    wire.session_rule_candidates
        .iter()
        .find(|c| c.kind == kind)
        .unwrap_or_else(|| {
            panic!(
                "no {kind:?} candidate in {:?}",
                wire.session_rule_candidates
            )
        })
        .clone()
}

impl Rig {
    fn new() -> Self {
        Self::over(Arc::new(tempfile::tempdir().unwrap()))
    }

    /// A rig with the verified app connected as a presenter.
    fn with_app() -> Self {
        let rig = Self::new();
        rig.broker.presenter_connected("app");
        rig
    }

    /// A broker over `root`'s approvals directory: a second one is "the daemon, restarted".
    fn over(root: Arc<tempfile::TempDir>) -> Self {
        let home = root.path().join("home");
        std::fs::create_dir_all(home.join("Library/Caches")).unwrap();
        std::fs::create_dir_all(home.join("Elsewhere")).unwrap();
        let presenters = ApprovalPresenters::default();
        let broker = ApprovalBroker::new(
            AuditLog::open(&root.path().join("approvals")).unwrap(),
            BrokerParts {
                presenter: Arc::new(presenters.clone()),
                presenters: presenters.clone(),
                probe: Arc::new(|| Box::new(ProdPane)),
                settings: Arc::new(NoRules),
                timeout: APPROVAL_TIMEOUT,
            },
        );
        broker.set_home_for_test(home.clone());
        let (tx, frames) = broadcast::channel(8192);
        broker.configure_broadcast(tx);
        let sink = FakeSink::new();
        let sink2 = FakeSink::new();
        let generation = broker.register_session(session(T, true), sink.clone());
        let generation2 = broker.register_session(session(T2, true), sink2.clone());
        let barrier_generation = broker.register_session(session(BARRIER, false), FakeSink::new());
        Self {
            broker,
            sink,
            sink2,
            frames,
            root,
            home,
            generation,
            generation2,
            barrier_generation,
            barriers: AtomicUsize::new(0),
        }
    }

    fn submit_value(&self, tag: &str, generation: u64, tool_use_id: &str, value: Value) {
        let accepted = self.broker.submit(Incoming::Request {
            tag: tag.into(),
            generation,
            cli_request_id: format!("cli-{tool_use_id}"),
            value,
        });
        assert!(
            accepted.is_ok(),
            "the broker takes a request without waiting"
        );
    }

    /// Submit `value` for `T` and wait until the broker holds it.
    async fn hold_value(&self, tool_use_id: &str, value: Value) -> ApprovalRequestWire {
        self.hold_on(T, self.generation, tool_use_id, value).await
    }

    async fn hold_on(
        &self,
        tag: &str,
        generation: u64,
        tool_use_id: &str,
        value: Value,
    ) -> ApprovalRequestWire {
        self.submit_value(tag, generation, tool_use_id, value);
        wait_until(&format!("{tool_use_id} to be held"), || {
            self.broker
                .snapshot()
                .into_iter()
                .find(|w| w.tool_use_id == tool_use_id)
        })
        .await
    }

    /// An ask-rule request for `command`, held.
    async fn hold_ask(&self, tool_use_id: &str, command: &str) -> ApprovalRequestWire {
        self.hold_value(tool_use_id, ask_request(tool_use_id, command))
            .await
    }

    /// `command` must still be shown as a card (no rule covers it); the card is then denied.
    async fn assert_card(&self, tool_use_id: &str, command: &str) {
        let wire = self.hold_ask(tool_use_id, command).await;
        assert_eq!(
            self.broker
                .answer(&wire.request_id, &deny(), "w-clean", "app"),
            applied("denied"),
            "{command}"
        );
    }

    /// `command` must be allowed by a rule at once, without a card.
    async fn assert_allowed_by_rule(&self, tool_use_id: &str, command: &str) {
        self.submit_value(
            T,
            self.generation,
            tool_use_id,
            ask_request(tool_use_id, command),
        );
        let outcome = self.wait_outcome(tool_use_id).await;
        assert_eq!(
            outcome_name(&outcome),
            "allowed_by_session_rule",
            "{command}"
        );
        assert!(
            !self
                .broker
                .snapshot()
                .iter()
                .any(|w| w.tool_use_id == tool_use_id),
            "{command}: no card"
        );
    }

    /// Hold `value` on `tag`, choose its `kind` candidate; returns the wire and the rule created.
    async fn grant_value(
        &self,
        tag: &str,
        generation: u64,
        value: Value,
        kind: CandidateKind,
    ) -> (ApprovalRequestWire, SessionRuleWire) {
        let tool_use_id = value["tool_use_id"].as_str().unwrap().to_owned();
        let wire = self.hold_on(tag, generation, &tool_use_id, value).await;
        let c = candidate(&wire, kind);
        assert_eq!(
            self.broker
                .answer(&wire.request_id, &allow_session(&c), "w-grant", "app"),
            applied("allowed_for_session")
        );
        let rule = self
            .rules(tag)
            .into_iter()
            .find(|r| r.rule_text == c.rule_text)
            .expect("the rule exists after the grant");
        (wire, rule)
    }

    async fn grant(
        &self,
        tool_use_id: &str,
        command: &str,
        kind: CandidateKind,
    ) -> (ApprovalRequestWire, SessionRuleWire) {
        self.grant_value(T, self.generation, ask_request(tool_use_id, command), kind)
            .await
    }

    /// `tag`'s active rules, as the app is told them.
    fn rules(&self, tag: &str) -> Vec<SessionRuleWire> {
        match self.broker.session_rules_frame(tag) {
            ServerMsg::ApprovalSessionRules { tag: t, rules } => {
                assert_eq!(t, tag);
                rules
            }
            other => panic!("{other:?}"),
        }
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    fn entries_of(&self, kind: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| e.event.kind() == kind)
            .collect()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        self.entries_of("outcome")
            .into_iter()
            .filter(|e| e.tool_use_id.as_deref() == Some(tool_use_id))
            .collect()
    }

    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.outcomes(tool_use_id).into_iter().next()
        })
        .await
    }

    async fn wait_entries(&self, kind: &str, n: usize) -> Vec<Entry> {
        wait_until(&format!("{n} `{kind}` entries"), || {
            let v = self.entries_of(kind);
            (v.len() >= n).then_some(v)
        })
        .await
    }

    /// Returns once every job the worker had queued before this call is done.
    async fn barrier(&self) {
        let n = self.barriers.fetch_add(1, Ordering::SeqCst);
        let id = format!("barrier-{n}");
        self.submit_value(
            BARRIER,
            self.barrier_generation,
            &id,
            bash_request(&id, "ls"),
        );
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

    /// Frames until one satisfies `want`; everything read so far is returned.
    async fn frames_until(
        &mut self,
        what: &str,
        want: impl Fn(&ServerMsg) -> bool,
    ) -> Vec<ServerMsg> {
        let start = Instant::now();
        let mut all = Vec::new();
        loop {
            all.extend(self.frames());
            if all.iter().any(&want) {
                return all;
            }
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "no frame for {what}: {all:?}"
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.sink.writes()
    }

    /// What was written for the request with `tool_use_id` on `T`'s stdin.
    fn writes_for(&self, tool_use_id: &str) -> Vec<Value> {
        let id = format!("cli-{tool_use_id}");
        self.writes()
            .into_iter()
            .filter(|(r, _)| *r == id)
            .map(|(_, b)| b)
            .collect()
    }
}

fn everything() -> Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

/// Real-time polling that never parks the (paused) runtime.
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

fn outcome_rule(e: &Entry) -> Value {
    match &e.event {
        Event::Outcome { rule, .. } => rule.clone().expect("the outcome names a rule"),
        other => panic!("not an outcome: {other:?}"),
    }
}

fn rule_body(e: &Entry) -> &Value {
    match &e.event {
        Event::SessionRuleGranted { rule } | Event::SessionRuleRevoked { rule } => rule,
        other => panic!("not a rule entry: {other:?}"),
    }
}

fn applied(outcome: &str) -> AnswerResult {
    AnswerResult::Applied {
        outcome: outcome.to_owned(),
    }
}

fn rule_frames(frames: &[ServerMsg]) -> Vec<(&str, &Vec<SessionRuleWire>)> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalSessionRules { tag, rules } => Some((tag.as_str(), rules)),
            _ => None,
        })
        .collect()
}

fn operator() -> Value {
    json!({ "trust": "operator_app" })
}

#[track_caller]
fn assert_no_updated_permissions(writes: &[(String, Value)]) {
    for (id, body) in writes {
        assert!(
            !body.to_string().contains("updatedPermissions"),
            "{id}: the CLI keeps its own rules, `updatedPermissions` is never sent: {body}"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// R1. What is offered
// ═════════════════════════════════════════════════════════════════════════════

// Fails on the old code: no `allow_session` option, `session_rule_candidates` always empty.
#[tokio::test(start_paused = true)]
async fn a_held_rm_in_the_users_cache_offers_allow_session_with_an_exact_and_a_path_prefix_candidate(
) {
    let mut rig = Rig::with_app();

    let wire = rig.hold_ask("toolu_1", CACHES_A).await;

    for o in ApprovalOption::ALL.iter() {
        assert!(wire.options.contains(o), "the usual options stay: {o:?}");
    }
    assert!(wire.options.contains(&ApprovalOption::AllowSession));
    let kinds: Vec<CandidateKind> = wire
        .session_rule_candidates
        .iter()
        .map(|c| c.kind)
        .collect();
    assert_eq!(kinds, [CandidateKind::Exact, CandidateKind::PathPrefix]);
    assert_eq!(
        wire.session_rule_candidates[0].rule_text,
        "Bash(rm -rf ~/Library/Caches/a)"
    );
    assert_eq!(
        wire.session_rule_candidates[1].rule_text,
        "Bash(rm -rf ~/Library/Caches/:*)"
    );
    for c in &wire.session_rule_candidates {
        assert!(!c.id.is_empty() && !c.summary.is_empty());
        assert_eq!(
            c.overrides.as_deref(),
            Some("Bash(rm:*)"),
            "an ask-rule request names the user's rule the session rule overrides"
        );
    }
    assert_ne!(
        wire.session_rule_candidates[0].id,
        wire.session_rule_candidates[1].id
    );
    // The same wire reaches the app by frame and by snapshot.
    let frames = rig.frames();
    assert!(frames
        .iter()
        .any(|m| matches!(m, ServerMsg::ApprovalRequest { request, .. } if *request == wire)));
    assert_eq!(rig.broker.snapshot(), vec![wire.clone()]);
    let json = serde_json::to_value(&wire).unwrap();
    let options = json["options"].as_array().unwrap();
    assert!(options.iter().any(|o| o == "allow_session"));
    assert_eq!(json["session_rule_candidates"][0]["kind"], "exact");
    assert_eq!(json["session_rule_candidates"][1]["kind"], "path_prefix");
}

// Fails if `overrides` is invented when no ask rule raised the request.
#[tokio::test(start_paused = true)]
async fn a_request_no_ask_rule_raised_names_nothing_its_candidates_override() {
    let rig = Rig::with_app();

    let wire = rig
        .hold_value("toolu_1", bash_request("toolu_1", CACHES_A))
        .await;

    assert_eq!(wire.session_rule_candidates.len(), 2);
    for c in &wire.session_rule_candidates {
        assert_eq!(c.overrides, None);
    }
    let json = serde_json::to_value(&wire).unwrap();
    assert!(json["session_rule_candidates"][0]
        .get("overrides")
        .is_none());
}

// Fails if a candidate id is derived from the command (a stale or guessed id would then work).
#[tokio::test(start_paused = true)]
async fn candidate_ids_are_fresh_for_every_request() {
    let rig = Rig::with_app();

    let first = rig.hold_ask("toolu_1", CACHES_A).await;
    let second = rig.hold_ask("toolu_2", CACHES_A).await;

    let ids: std::collections::HashSet<&str> = first
        .session_rule_candidates
        .iter()
        .chain(&second.session_rule_candidates)
        .map(|c| c.id.as_str())
        .collect();
    assert_eq!(ids.len(), 4, "no id is ever reused: {ids:?}");
}

// Fails if any of these gets a rule: a compound, a tool that is not Bash, tmux, ecs, a shell,
// a protected location, a safety check.
#[tokio::test(start_paused = true)]
async fn no_session_rule_is_offered_for_compound_edit_mcp_tmux_ecs_shell_protected_or_safety_check_requests(
) {
    let rig = Rig::with_app();
    let edit = json!({
        "subtype": "can_use_tool", "tool_name": "Edit", "display_name": "Edit",
        "input": { "file_path": "/tmp/x/a.txt", "old_string": "a", "new_string": "b" },
        "decision_reason_type": "rule", "tool_use_id": "toolu_edit",
    });
    let mcp = json!({
        "subtype": "can_use_tool", "tool_name": "mcp__slack__post_message", "display_name": "Slack",
        "input": { "text": "hi" }, "decision_reason_type": "rule", "tool_use_id": "toolu_mcp",
    });
    let mut safety = bash_request("toolu_safety", CACHES_A);
    safety["decision_reason_type"] = json!("safetyCheck");
    safety["decision_reason"] = json!("Changes something sensitive");
    let mut cases: Vec<(&str, Value)> =
        vec![("edit", edit), ("mcp", mcp), ("safety check", safety)];
    let commands = [
        ("compound &&", "rm -rf ~/Library/Caches/a && echo done"),
        ("compound ;", "rm -rf ~/Library/Caches/a; echo done"),
        ("pipe", "ls ~/Library/Caches/a | head"),
        ("quoted", "rm -rf \"~/Library/Caches/a\""),
        ("substitution", "rm -rf ~/Library/Caches/$X"),
        ("tmux", "tmux list-sessions"),
        ("ecs", "ecs_info"),
        ("ecs build", "ecs_build_command ap production portal"),
        ("aws ecs", "aws ecs list-tasks --cluster c"),
        ("shell", "bash -c ls"),
        ("ssh", "ssh host ls"),
        ("protected ssh", "rm -rf ~/.ssh/id_rsa"),
        ("protected etc", "cat /etc/hosts"),
    ];
    for (i, (label, command)) in commands.iter().enumerate() {
        cases.push((*label, ask_request(&format!("toolu_c{i}"), command)));
    }

    for (label, request) in cases {
        let tool_use_id = request["tool_use_id"].as_str().unwrap().to_owned();
        let wire = rig.hold_value(&tool_use_id, request).await;

        assert!(
            !wire.options.contains(&ApprovalOption::AllowSession),
            "{label}: allow_session must not be offered"
        );
        assert!(wire.session_rule_candidates.is_empty(), "{label}");
        let json = serde_json::to_value(&wire).unwrap();
        assert_eq!(json["session_rule_candidates"], json!([]), "{label}");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// R2. Creating a rule
// ═════════════════════════════════════════════════════════════════════════════

// Fails on the old code (allow_session does not exist) and if any field below is missing.
#[tokio::test(start_paused = true)]
async fn allow_session_allows_this_call_unchanged_creates_the_rule_logs_it_and_tells_the_app() {
    let mut rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    rig.frames();
    let c = candidate(&wire, CandidateKind::Exact);

    let result = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "win-9", "app");

    assert_eq!(result, applied("allowed_for_session"));
    assert_eq!(
        rig.writes(),
        [("cli-toolu_1".to_owned(), allow_body(input_of(CACHES_A)))],
        "exactly an allow with the input unchanged and nothing else"
    );
    assert_no_updated_permissions(&rig.writes());
    // The app is told: this request resolved, and the rule list.
    let frames = rig
        .frames_until("the rule list", |m| {
            matches!(m, ServerMsg::ApprovalSessionRules { .. })
        })
        .await;
    let resolved: Vec<_> = frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalResolved {
                outcome,
                by_window,
                tool_use_id,
                ..
            } => Some((
                outcome.as_str(),
                by_window.as_deref(),
                tool_use_id.as_deref(),
            )),
            _ => None,
        })
        .collect();
    assert_eq!(
        resolved,
        [("allowed_for_session", Some("win-9"), Some("toolu_1"))]
    );
    let lists = rule_frames(&frames);
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].0, T);
    assert_eq!(lists[0].1.len(), 1);
    let rule = &lists[0].1[0];
    assert!(!rule.id.is_empty());
    assert_eq!(rule.rule_text, c.rule_text);
    assert_eq!(rule.kind, CandidateKind::Exact);
    assert_eq!((rule.uses, rule.agent_id.clone()), (0, None));
    assert!(rule.created_at_ms > 0);
    // The audit log: outcome, and the grant with its full identity.
    let outcome = rig.wait_outcome("toolu_1").await;
    assert_eq!(outcome_name(&outcome), "allowed_for_session");
    let granted = rig.wait_entries("session_rule_granted", 1).await;
    assert_eq!(granted.len(), 1);
    let body = rule_body(&granted[0]);
    assert_eq!(body["id"], rule.id.as_str());
    assert_eq!(body["rule_text"], c.rule_text.as_str());
    assert_eq!(body["kind"], "exact");
    assert!(!body["summary"].as_str().unwrap().is_empty());
    assert_eq!(body["tag"], T);
    assert_eq!(body["generation"], rig.generation);
    assert_eq!(body["session_id"], "sid-focus-1");
    assert!(body["agent_id"].is_null());
    assert_eq!(body["granted_by_request_id"], wire.request_id.as_str());
    assert_eq!(body["granted_by_window"], "win-9");
    let created = DateTime::parse_from_rfc3339(body["created_at"].as_str().unwrap())
        .expect("created_at is RFC 3339");
    assert!(
        (Utc::now() - created.with_timezone(&Utc))
            .num_seconds()
            .abs()
            < 60
    );
    assert_eq!(granted[0].tag.as_deref(), Some(T));
}

// Fails if the path-prefix candidate does not make a path-prefix rule.
#[tokio::test(start_paused = true)]
async fn choosing_the_path_prefix_candidate_creates_a_path_prefix_rule() {
    let rig = Rig::with_app();

    let (_, rule) = rig
        .grant("toolu_1", CACHES_A, CandidateKind::PathPrefix)
        .await;

    assert_eq!(rule.kind, CandidateKind::PathPrefix);
    assert_eq!(rule.rule_text, "Bash(rm -rf ~/Library/Caches/:*)");
    assert_eq!(rig.rules(T), vec![rule]);
}

// Fails if a wrong id, wrong text, another request's candidate or a missing field is accepted,
// or if a refusal ends the request, writes to the CLI or leaves a rule.
#[tokio::test(start_paused = true)]
async fn an_allow_session_that_does_not_name_one_of_this_requests_candidates_is_refused_invalid_rule_and_changes_nothing(
) {
    let mut rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let other = rig.hold_ask("toolu_2", "rm -rf ~/Library/Caches/b").await;
    rig.frames();
    let exact = candidate(&wire, CandidateKind::Exact);
    let prefix = candidate(&wire, CandidateKind::PathPrefix);
    let theirs = candidate(&other, CandidateKind::Exact);
    let attempts: Vec<(&str, ApprovalDecision)> = vec![
        (
            "wrong candidate id",
            decision_with(Some("not-an-id"), Some(&exact.rule_text)),
        ),
        (
            "right id, the user's own ask rule text",
            decision_with(Some(&exact.id), Some("Bash(rm:*)")),
        ),
        (
            "right id, the broad text of the other candidate",
            decision_with(Some(&exact.id), Some(&prefix.rule_text)),
        ),
        (
            "right id, text with a trailing space",
            decision_with(Some(&exact.id), Some(&format!("{} ", exact.rule_text))),
        ),
        (
            "right id, text in another case",
            decision_with(Some(&exact.id), Some(&exact.rule_text.to_uppercase())),
        ),
        (
            "another held request's candidate",
            decision_with(Some(&theirs.id), Some(&theirs.rule_text)),
        ),
        (
            "another request's id, this request's text",
            decision_with(Some(&theirs.id), Some(&exact.rule_text)),
        ),
        (
            "no candidate id",
            decision_with(None, Some(&exact.rule_text)),
        ),
        ("no rule text", decision_with(Some(&exact.id), None)),
        ("nothing at all", decision_with(None, None)),
        ("empty strings", decision_with(Some(""), Some(""))),
    ];

    for (what, decision) in &attempts {
        let result = rig.broker.answer(&wire.request_id, decision, "w", "app");
        assert_eq!(result, AnswerResult::InvalidRule, "{what}");
        assert_eq!(
            result.refusal(),
            Some((AnswerRefusal::InvalidRule, None)),
            "{what}"
        );
        let frame = rig
            .broker
            .answer_or_refusal(&wire.request_id, decision, "w", "app", operator())
            .expect("a refusal frame for the answering window");
        match frame {
            ServerMsg::ApprovalAnswerRefused {
                request_id,
                code,
                outcome,
            } => {
                assert_eq!(request_id, wire.request_id);
                assert_eq!(code.as_str(), "invalid_rule");
                assert_eq!(outcome, None);
            }
            other => panic!("{what}: {other:?}"),
        }
    }

    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "nothing reached the CLI: {:?}",
        rig.writes()
    );
    assert!(rig.rules(T).is_empty(), "no rule");
    assert!(rig.entries_of("session_rule_granted").is_empty());
    assert_eq!(rig.broker.snapshot().len(), 2, "both requests stay held");
    assert!(
        rule_frames(&rig.frames()).is_empty(),
        "no rule list was broadcast"
    );
    let refusals = rig.entries_of("refusal");
    assert_eq!(refusals.len(), attempts.len(), "every refusal is logged");
    for e in &refusals {
        match &e.event {
            Event::Refusal { refusal_code, .. } => assert_eq!(refusal_code, "invalid_rule"),
            other => panic!("{other:?}"),
        }
        assert_eq!(e.request_id.as_deref(), Some(wire.request_id.as_str()));
    }
    // The request stayed answerable: the right choice still works.
    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &allow_session(&exact), "w", "app"),
        applied("allowed_for_session")
    );
}

// Fails if allow_session works for a request that listed no candidates (e.g. with a guessed or
// borrowed candidate).
#[tokio::test(start_paused = true)]
async fn allow_session_on_a_request_that_lists_no_candidates_is_refused_invalid_rule() {
    let rig = Rig::with_app();
    let compound = rig
        .hold_ask("toolu_c", "rm -rf ~/Library/Caches/a && echo done")
        .await;
    let simple = rig.hold_ask("toolu_s", CACHES_A).await;
    assert!(compound.session_rule_candidates.is_empty());
    let borrowed = candidate(&simple, CandidateKind::Exact);

    for decision in [
        allow_session(&borrowed),
        decision_with(
            Some(&borrowed.id),
            Some("Bash(rm -rf ~/Library/Caches/a && echo done)"),
        ),
        decision_with(Some("anything"), Some("Bash(anything)")),
    ] {
        assert_eq!(
            rig.broker
                .answer(&compound.request_id, &decision, "w", "app"),
            AnswerResult::InvalidRule
        );
    }

    rig.barrier().await;
    assert!(rig.writes().is_empty());
    assert!(rig.rules(T).is_empty());
    assert_eq!(rig.broker.snapshot().len(), 2);
    // The compound command still gets a card each time: nothing was created.
    rig.assert_card("toolu_c2", "rm -rf ~/Library/Caches/a && echo done")
        .await;
}

// Fails if a connection that is not a presenter can create a rule.
#[tokio::test(start_paused = true)]
async fn allow_session_from_a_connection_that_is_not_a_presenter_creates_no_rule() {
    let rig = Rig::with_app();
    rig.broker.app_connected("operator-only");
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);

    for conn in ["operator-only", "stranger"] {
        let result = rig
            .broker
            .answer(&wire.request_id, &allow_session(&c), "w", conn);
        assert_eq!(result, AnswerResult::NotPresenter, "{conn}");
        assert_eq!(
            result.refusal(),
            Some((AnswerRefusal::NotOperatorApp, None)),
            "{conn}"
        );
    }

    rig.barrier().await;
    assert!(rig.writes().is_empty());
    assert!(rig.rules(T).is_empty());
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
}

// Fails if a rule is created for a session that was stopped between the hold and the answer.
#[tokio::test(start_paused = true)]
async fn allow_session_after_the_session_stopped_creates_no_rule_and_writes_nothing() {
    let rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    rig.broker.on_session_gone(T, rig.generation, "stopped");
    rig.wait_outcome("toolu_1").await;

    let result = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "w", "app");

    assert_eq!(
        result,
        AnswerResult::AlreadyResolved {
            outcome: "cancelled".into()
        }
    );
    assert!(rig.writes().is_empty());
    assert!(rig.rules(T).is_empty());
    assert!(rig.entries_of("session_rule_granted").is_empty());
}

// Fails if the rule is created before the allow is known to have been written, or onto a
// session process that is not the one registered any more.
#[tokio::test(start_paused = true)]
async fn no_rule_is_created_when_the_allow_cannot_be_written_or_the_process_was_replaced() {
    // The CLI's stdin is broken.
    let rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    rig.sink.fail.store(true, Ordering::SeqCst);
    let result = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "w", "app");
    assert_eq!(result, applied("deny_write_failed"));
    assert!(rig.writes().is_empty());
    assert!(rig.rules(T).is_empty());
    assert!(rig.entries_of("session_rule_granted").is_empty());

    // The process died without a gone report: the allow is not written, so no rule.
    let rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    rig.sink.live.store(false, Ordering::SeqCst);
    let result = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "w", "app");
    assert_eq!(result, applied("cancelled"));
    assert!(rig.writes().is_empty());
    assert!(rig.rules(T).is_empty());

    // The focus got a newer process without the old one being reported gone.
    let rig = Rig::with_app();
    let wire = rig.hold_ask("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    let new_sink = FakeSink::new();
    let new_generation = rig
        .broker
        .register_session(session(T, true), new_sink.clone());
    let _ = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "w", "app");
    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "nothing is written to the old process"
    );
    assert!(new_sink.writes().is_empty(), "nor to the new one");
    assert!(rig.rules(T).is_empty(), "no rule on the new process");
    assert!(rig.entries_of("session_rule_granted").is_empty());
    assert!(new_generation > rig.generation);
    rig.assert_card_on(T, new_generation, "toolu_new", CACHES_A)
        .await;
}

impl Rig {
    async fn assert_card_on(&self, tag: &str, generation: u64, tool_use_id: &str, command: &str) {
        let wire = self
            .hold_on(
                tag,
                generation,
                tool_use_id,
                ask_request(tool_use_id, command),
            )
            .await;
        assert_eq!(
            self.broker
                .answer(&wire.request_id, &deny(), "w-clean", "app"),
            applied("denied"),
            "{command}"
        );
    }
}

// Fails if the cap of 32 rules per session is not enforced, or if a refused 33rd rule also
// refuses the plain allow.
#[tokio::test(start_paused = true)]
async fn the_33rd_rule_of_a_session_is_refused_invalid_rule_and_the_request_stays_held() {
    let rig = Rig::with_app();
    for i in 0..32 {
        rig.grant(
            &format!("toolu_g{i}"),
            &format!("ls /tmp/cap/f{i}"),
            CandidateKind::Exact,
        )
        .await;
    }
    assert_eq!(rig.rules(T).len(), 32);
    let wire = rig.hold_ask("toolu_33", "ls /tmp/cap/f33").await;
    let c = candidate(&wire, CandidateKind::Exact);

    let result = rig
        .broker
        .answer(&wire.request_id, &allow_session(&c), "w", "app");

    assert_eq!(result, AnswerResult::InvalidRule);
    assert_eq!(rig.rules(T).len(), 32);
    assert!(rig.writes_for("toolu_33").is_empty());
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
    // The human can still allow it once.
    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &allow_once(), "w", "app"),
        applied("allowed_once")
    );
    assert_eq!(rig.rules(T).len(), 32);
}

// Fails if allow once, deny or a timeout leave a rule behind.
#[tokio::test(start_paused = true)]
async fn allow_once_and_deny_create_no_rule_so_the_next_request_is_a_card_again() {
    let rig = Rig::with_app();
    let first = rig.hold_ask("toolu_1", CACHES_A).await;
    assert_eq!(
        rig.broker
            .answer(&first.request_id, &allow_once(), "w", "app"),
        applied("allowed_once")
    );
    let second = rig.hold_ask("toolu_2", CACHES_A).await;
    assert_eq!(
        rig.broker.answer(&second.request_id, &deny(), "w", "app"),
        applied("denied")
    );

    rig.assert_card("toolu_3", CACHES_A).await;
    assert!(rig.rules(T).is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// R3. Using a rule
// ═════════════════════════════════════════════════════════════════════════════

// Fails on the old code (the second request is held) and if any detail of the use is missing.
#[tokio::test(start_paused = true)]
async fn a_second_matching_request_is_allowed_by_the_rule_with_its_own_input_and_never_becomes_a_card(
) {
    let mut rig = Rig::with_app();
    let (granting, rule) = rig.grant("toolu_1", CACHES_A, CandidateKind::Exact).await;
    rig.frames();
    let mut again = ask_request("toolu_2", CACHES_A);
    again["input"]["description"] = json!("a different description");

    rig.submit_value(T, rig.generation, "toolu_2", again.clone());
    let outcome = rig.wait_outcome("toolu_2").await;

    assert_eq!(outcome_name(&outcome), "allowed_by_session_rule");
    assert_eq!(
        rig.writes_for("toolu_2"),
        [allow_body(again["input"].clone())],
        "the request's own input, unchanged"
    );
    assert_no_updated_permissions(&rig.writes());
    assert!(rig.broker.snapshot().is_empty(), "never held");
    // The audit trail: the request, and an outcome naming the rule.
    let mine: Vec<Entry> = rig
        .entries()
        .into_iter()
        .filter(|e| e.tool_use_id.as_deref() == Some("toolu_2"))
        .collect();
    let kinds: Vec<&str> = mine.iter().map(|e| e.event.kind()).collect();
    assert_eq!(kinds, ["request", "outcome"]);
    let named = outcome_rule(&mine[1]);
    let keys: std::collections::BTreeSet<&str> = named
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        [
            "granted_at_ms",
            "granted_by_request_id",
            "kind",
            "rule_id",
            "rule_text"
        ]
        .into_iter()
        .collect()
    );
    assert_eq!(named["rule_id"], rule.id.as_str());
    assert_eq!(named["rule_text"], rule.rule_text.as_str());
    assert_eq!(named["kind"], "exact");
    assert_eq!(named["granted_at_ms"], rule.created_at_ms);
    assert_eq!(named["granted_by_request_id"], granting.request_id.as_str());
    // The app: a resolution that names the tool use, and the rule list with one more use.
    let frames = rig
        .frames_until("the use count", |m| {
            matches!(m, ServerMsg::ApprovalSessionRules { rules, .. } if rules.iter().any(|r| r.uses == 1))
        })
        .await;
    assert!(
        !frames
            .iter()
            .any(|m| matches!(m, ServerMsg::ApprovalRequest { .. })),
        "no card was shown: {frames:?}"
    );
    let resolved: Vec<_> = frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalResolved {
                tag,
                request_id,
                outcome,
                by_window,
                tool_use_id,
                ..
            } => Some((
                tag.as_str(),
                request_id.as_str(),
                outcome.as_str(),
                by_window.as_deref(),
                tool_use_id.as_deref(),
            )),
            _ => None,
        })
        .collect();
    assert_eq!(resolved.len(), 1);
    assert_eq!(
        (resolved[0].0, resolved[0].2, resolved[0].3, resolved[0].4),
        (T, "allowed_by_session_rule", None, Some("toolu_2"))
    );
    assert_eq!(mine[1].request_id.as_deref(), Some(resolved[0].1));
    let lists = rule_frames(&frames);
    let last = lists.last().unwrap();
    assert_eq!(last.0, T);
    assert_eq!(
        (last.1.len(), last.1[0].id.as_str(), last.1[0].uses),
        (1, rule.id.as_str(), 1)
    );
    // A second use counts again.
    rig.assert_allowed_by_rule("toolu_3", CACHES_A).await;
    rig.frames_until("two uses", |m| {
        matches!(m, ServerMsg::ApprovalSessionRules { rules, .. } if rules.iter().any(|r| r.uses == 2))
    })
    .await;
}

// Fails if the prefix rule is looser (other prefix, flags, extra paths, symlinks, compound) or
// tighter (other paths inside the prefix) than the rule the human was shown.
#[tokio::test(start_paused = true)]
async fn a_path_prefix_rule_covers_other_paths_inside_its_prefix_and_nothing_else() {
    let rig = Rig::with_app();
    rig.grant("toolu_g", CACHES_A, CandidateKind::PathPrefix)
        .await;
    std::os::unix::fs::symlink(
        rig.home.join("Elsewhere"),
        rig.home.join("Library/Caches/escape"),
    )
    .unwrap();
    let covered = [
        "rm -rf ~/Library/Caches/b",
        "rm -rf ~/Library/Caches/b ~/Library/Caches/c",
        "rm -rf ~/Library/Caches/a/deep/er",
    ];
    let not_covered = [
        "rm -rf ~/Library/Caches",
        "rm -rf ~/Library/Caches/",
        "rm -rf ~/Library/Other/a",
        "rm -rf ~/Library/Cachesbogus/a",
        "rm -rf ~/Library/Caches/a ~/Library/Other/a",
        "rm -rf ~/Library/Caches/../Other/a",
        "rm -r ~/Library/Caches/a",
        "rm ~/Library/Caches/a",
        "rm -rf ~/Library/Caches/a -v",
        "ls ~/Library/Caches/a",
        "rm -rf ~/Library/Caches/a && echo done",
        "rm -rf ~/Library/Caches/a; echo done",
        "rm -rf ~/Library/Caches/$X",
        "rm -rf ~/Library/Caches/escape/x",
    ];

    for (i, command) in covered.iter().enumerate() {
        rig.assert_allowed_by_rule(&format!("toolu_y{i}"), command)
            .await;
    }
    for (i, command) in not_covered.iter().enumerate() {
        rig.assert_card(&format!("toolu_n{i}"), command).await;
    }

    assert_eq!(rig.rules(T)[0].uses, covered.len() as u64);
    let allows: Vec<_> = rig
        .writes()
        .into_iter()
        .filter(|(_, b)| b["behavior"] == "allow")
        .collect();
    assert_eq!(
        allows.len(),
        1 + covered.len(),
        "the grant and the covered ones only"
    );
}

// Fails if an exact rule covers a different path or an extra flag, or a compound command.
#[tokio::test(start_paused = true)]
async fn an_exact_rule_covers_only_that_exact_command() {
    let rig = Rig::with_app();
    rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;

    for (i, command) in [
        "rm -rf ~/Library/Caches/b",
        "rm -rf ~/Library/Caches/a -v",
        "rm -rf ~/Library/Caches/a ~/Library/Caches/b",
        "rm -rf ~/Library/Caches/a && echo done",
        "rm -rf ~/Library/Caches/a | cat",
        "rm -r ~/Library/Caches/a",
    ]
    .iter()
    .enumerate()
    {
        rig.assert_card(&format!("toolu_n{i}"), command).await;
    }
    rig.assert_allowed_by_rule("toolu_same", CACHES_A).await;
}

// Fails if a rule granted to the session's own agent also covers a sub-agent (or the reverse).
#[tokio::test(start_paused = true)]
async fn a_rule_covers_only_the_agent_it_was_granted_to() {
    let mut rig = Rig::with_app();
    rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;

    let wire = rig
        .hold_value(
            "toolu_sub",
            from_agent(ask_request("toolu_sub", CACHES_A), "agent-sub-1"),
        )
        .await;
    assert_eq!(
        rig.broker.answer(&wire.request_id, &deny(), "w", "app"),
        applied("denied"),
        "the same command from a sub-agent is a card"
    );
    rig.assert_allowed_by_rule("toolu_main", CACHES_A).await;

    // A rule the sub-agent was granted covers that sub-agent only.
    let (_, rule) = rig
        .grant_value(
            T,
            rig.generation,
            from_agent(ask_request("toolu_g2", "ls /tmp/sub/a"), "agent-sub-1"),
            CandidateKind::Exact,
        )
        .await;
    assert_eq!(rule.agent_id.as_deref(), Some("agent-sub-1"));
    rig.frames();
    rig.submit_value(
        T,
        rig.generation,
        "toolu_s1",
        from_agent(ask_request("toolu_s1", "ls /tmp/sub/a"), "agent-sub-1"),
    );
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_s1").await),
        "allowed_by_session_rule"
    );
    for (i, request) in [
        ask_request("toolu_x0", "ls /tmp/sub/a"),
        from_agent(ask_request("toolu_x1", "ls /tmp/sub/a"), "agent-sub-2"),
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("toolu_x{i}");
        let wire = rig.hold_value(&id, request).await;
        assert_eq!(
            rig.broker.answer(&wire.request_id, &deny(), "w", "app"),
            applied("denied")
        );
    }
}

// Fails if rules are shared between focuses.
#[tokio::test(start_paused = true)]
async fn a_rule_covers_only_the_focus_it_was_granted_in() {
    let rig = Rig::with_app();
    rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;

    let wire = rig
        .hold_on(
            T2,
            rig.generation2,
            "toolu_other",
            ask_request("toolu_other", CACHES_A),
        )
        .await;

    assert_eq!(wire.tag, T2);
    assert_eq!(
        rig.broker.answer(&wire.request_id, &deny(), "w", "app"),
        applied("denied")
    );
    assert!(rig.rules(T2).is_empty());
    assert_eq!(rig.rules(T).len(), 1);
    assert!(
        rig.sink2
            .writes()
            .iter()
            .all(|(_, b)| b["behavior"] == "deny"),
        "nothing was allowed in the other focus"
    );
}

// Fails if a rule answers when nobody who can see and revoke it is connected.
#[tokio::test(start_paused = true)]
async fn without_an_app_that_renders_approvals_a_matching_request_is_denied_as_before() {
    let rig = Rig::with_app();
    let (_, rule) = rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;

    // No presenter at all.
    rig.broker.app_disconnected("app");
    rig.submit_value(
        T,
        rig.generation,
        "toolu_1",
        ask_request("toolu_1", CACHES_A),
    );
    assert_eq!(outcome_name(&rig.wait_outcome("toolu_1").await), "no_app");
    assert_eq!(
        rig.writes_for("toolu_1"),
        [json!({ "behavior": "deny", "message": NO_APP_MESSAGE })]
    );

    // An app that cannot show a rule is no better.
    rig.broker.app_connected("mac-today");
    rig.submit_value(
        T,
        rig.generation,
        "toolu_2",
        ask_request("toolu_2", CACHES_A),
    );
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_2").await),
        "approval_unavailable"
    );
    assert!(rig.writes_for("toolu_2")[0]["behavior"] == "deny");

    // The rule itself is not lost: when the app is back it applies again.
    rig.broker.presenter_connected("app-again");
    assert_eq!(rig.rules(T), vec![rule]);
    rig.assert_allowed_by_rule("toolu_3", CACHES_A).await;
}

// A hand-built rule whose text equals a guarded command must not turn a guard block into an
// allow. Note: `rules::eligible` also refuses every one of these commands (tmux, ecs_, aws ecs),
// so this pins the end result (`guard_blocked`), not the guard-before-rule order by itself; the
// order is `process` running `guard_block` before `matching_session_rule`.
#[tokio::test(start_paused = true)]
async fn a_rule_never_overrides_the_guard() {
    let mut rig = Rig::with_app();
    for (i, command) in [
        "tmux send-keys -t %9 ls",
        "ecs_connect ap production portal",
        "aws ecs execute-command --cluster c --task t --interactive --command sh",
    ]
    .into_iter()
    .enumerate()
    {
        rig.broker.inject_session_rule_for_test(
            T,
            rig.generation,
            SessionRule::exact_for_test(command, None),
        );
        let tool_use_id = format!("toolu_guard{i}");
        rig.frames();

        rig.submit_value(
            T,
            rig.generation,
            &tool_use_id,
            ask_request(&tool_use_id, command),
        );

        let outcome = rig.wait_outcome(&tool_use_id).await;
        assert_eq!(outcome_name(&outcome), "guard_blocked", "{command}");
        let writes = rig.writes_for(&tool_use_id);
        assert_eq!(writes.len(), 1, "{command}");
        assert_eq!(writes[0]["behavior"], "deny", "{command}");
        rig.frames_until("a guard block", |m| {
            matches!(m, ServerMsg::ApprovalGuardBlocked { .. })
        })
        .await;
    }
}

// Fails if the matcher trusts a rule's text instead of re-checking the request: a hand-built
// rule for a compound command must not allow it.
#[tokio::test(start_paused = true)]
async fn a_hand_built_rule_for_a_compound_command_does_not_allow_it() {
    let rig = Rig::with_app();
    let command = "rm -rf ~/Library/Caches/a && echo done";
    rig.broker.inject_session_rule_for_test(
        T,
        rig.generation,
        SessionRule::exact_for_test(command, None),
    );

    rig.assert_card("toolu_1", command).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// R4. A rule dies with its session process
// ═════════════════════════════════════════════════════════════════════════════

// Fails if any ending of the process leaves a rule, or removes it silently.
#[tokio::test(start_paused = true)]
async fn a_rule_is_gone_when_its_session_process_goes_whatever_the_reason() {
    for reason in ["stopped", "restarted", "exited", "crashed"] {
        let mut rig = Rig::with_app();
        let (_, rule) = rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;
        rig.frames();

        rig.broker.on_session_gone(T, rig.generation, reason);

        let revoked = rig.wait_entries("session_rule_revoked", 1).await;
        assert_eq!(revoked.len(), 1, "{reason}");
        let body = rule_body(&revoked[0]);
        assert_eq!(body["reason"], "session_ended", "{reason}");
        assert_eq!(body["id"], rule.id.as_str(), "{reason}");
        assert_eq!(body["rule_text"], rule.rule_text.as_str(), "{reason}");
        assert_eq!(body["tag"], T);
        let frames = rig
            .frames_until(
                "the empty list",
                |m| matches!(m, ServerMsg::ApprovalSessionRules { rules, .. } if rules.is_empty()),
            )
            .await;
        let lists = rule_frames(&frames);
        assert_eq!(lists.len(), 1, "{reason}");
        assert_eq!((lists[0].0, lists[0].1.len()), (T, 0), "{reason}");
        assert!(rig.rules(T).is_empty(), "{reason}");
        assert!(rig.broker.session_rules_replay().is_empty(), "{reason}");
        // The focus gets a new process: the same command is a card again.
        let sink = FakeSink::new();
        let generation = rig.broker.register_session(session(T, true), sink.clone());
        rig.assert_card_on(T, generation, "toolu_again", CACHES_A)
            .await;
        assert!(
            sink.writes().iter().all(|(_, b)| b["behavior"] == "deny"),
            "{reason}: nothing was allowed by the old rule"
        );
    }
}

// Fails if rules are persisted or reloaded by a new broker over the same approvals directory.
#[tokio::test(start_paused = true)]
async fn a_new_daemon_over_the_same_approvals_directory_starts_with_no_rules() {
    let first = Rig::with_app();
    first.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;
    first
        .grant("toolu_g2", "ls /tmp/cap/f", CandidateKind::Exact)
        .await;
    assert_eq!(first.rules(T).len(), 2);

    let second = Rig::over(Arc::clone(&first.root));
    second.broker.presenter_connected("app");

    assert!(second.broker.session_rules_replay().is_empty());
    assert!(second.rules(T).is_empty());
    second.assert_card("toolu_1", CACHES_A).await;
    assert!(second.writes().iter().all(|(_, b)| b["behavior"] == "deny"));
}

// Fails if the rule is keyed by focus only: a rule of generation N must never match N+1,
// even when nobody reported N gone.
#[tokio::test(start_paused = true)]
async fn a_rule_of_one_generation_never_matches_the_next_even_if_the_old_process_was_never_reported_gone(
) {
    // (a) The natural path: the focus is registered again.
    let mut rig = Rig::with_app();
    let (_, rule) = rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;
    rig.frames();
    let sink = FakeSink::new();
    let next = rig.broker.register_session(session(T, true), sink.clone());
    assert!(next > rig.generation);

    let revoked = rig.wait_entries("session_rule_revoked", 1).await;
    assert_eq!(rule_body(&revoked[0])["reason"], "session_ended");
    assert_eq!(rule_body(&revoked[0])["id"], rule.id.as_str());
    rig.frames_until(
        "the empty list",
        |m| matches!(m, ServerMsg::ApprovalSessionRules { rules, .. } if rules.is_empty()),
    )
    .await;
    rig.assert_card_on(T, next, "toolu_1", CACHES_A).await;

    // (b) A rule left on the old generation's key (as if the drop never ran) still cannot match.
    let rig = Rig::with_app();
    let old = rig.generation;
    let sink = FakeSink::new();
    let next = rig.broker.register_session(session(T, true), sink.clone());
    rig.broker
        .inject_session_rule_for_test(T, old, SessionRule::exact_for_test(CACHES_A, None));
    assert!(rig.rules(T).is_empty(), "the new process lists no rules");
    rig.assert_card_on(T, next, "toolu_2", CACHES_A).await;
    assert!(sink.writes().iter().all(|(_, b)| b["behavior"] == "deny"));
}

// ═════════════════════════════════════════════════════════════════════════════
// R6. Revoking (broker level; the sockets are in approvals_wire.rs)
// ═════════════════════════════════════════════════════════════════════════════

// Fails if a revoke leaves the rule matching, is not logged with reason "user", or does not
// tell the app the tag's remaining rules.
#[tokio::test(start_paused = true)]
async fn revoking_a_rule_removes_it_at_once_logs_user_and_tells_the_app_the_remaining_rules() {
    let mut rig = Rig::with_app();
    let (_, keep) = rig
        .grant("toolu_k", "ls /tmp/cap/keep", CandidateKind::Exact)
        .await;
    let (_, gone) = rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;
    rig.frames();

    let result = rig.broker.revoke_session_rule(T, &gone.id, "app", "win-3");

    assert_eq!(result, RevokeResult::Revoked);
    assert_eq!(rig.rules(T), vec![keep.clone()]);
    let frames = rig.frames();
    let lists = rule_frames(&frames);
    assert_eq!(lists.len(), 1);
    assert_eq!((lists[0].0, lists[0].1.clone()), (T, vec![keep.clone()]));
    let revoked = rig.wait_entries("session_rule_revoked", 1).await;
    let body = rule_body(&revoked[0]);
    assert_eq!(body["id"], gone.id.as_str());
    assert_eq!(body["reason"], "user");
    assert_eq!(body["by_window"], "win-3");
    // The very next matching request is a card; the other rule still works.
    rig.assert_card("toolu_after", CACHES_A).await;
    rig.assert_allowed_by_rule("toolu_keep", "ls /tmp/cap/keep")
        .await;
}

// Fails if an unknown, foreign-focus or non-presenter revoke changes anything.
#[tokio::test(start_paused = true)]
async fn a_revoke_of_an_unknown_rule_another_focus_or_from_a_non_presenter_changes_nothing() {
    let mut rig = Rig::with_app();
    rig.broker.app_connected("operator-only");
    let (_, rule) = rig.grant("toolu_g", CACHES_A, CandidateKind::Exact).await;
    rig.frames();

    assert_eq!(
        rig.broker
            .revoke_session_rule(T, "no-such-rule", "app", "w"),
        RevokeResult::Unknown
    );
    assert_eq!(
        rig.broker.revoke_session_rule(T2, &rule.id, "app", "w"),
        RevokeResult::Unknown,
        "a rule id is only good in its own focus"
    );
    for conn in ["operator-only", "stranger"] {
        assert_eq!(
            rig.broker.revoke_session_rule(T, &rule.id, conn, "w"),
            RevokeResult::NotPresenter
        );
    }

    rig.barrier().await;
    assert_eq!(rig.rules(T), vec![rule]);
    assert!(
        rule_frames(&rig.frames()).is_empty(),
        "nothing was broadcast"
    );
    assert!(rig.entries_of("session_rule_revoked").is_empty());
    rig.assert_allowed_by_rule("toolu_still", CACHES_A).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// R13. Only four endings ever allow, and `updatedPermissions` is never sent
// ═════════════════════════════════════════════════════════════════════════════

const ALLOW_OUTCOMES: [&str; 4] = [
    "allowed_once",
    "answered",
    "allowed_for_session",
    "allowed_by_session_rule",
];

// T-INV-3 for rules. Fails if any other ending (timeout, guard, no app, a refused
// allow_session, a cancel) ever writes an allow, or if an allow is written that no allowing
// outcome accounts for.
#[tokio::test(start_paused = true)]
async fn the_only_allows_written_are_allowed_once_allowed_for_session_and_allowed_by_session_rule()
{
    let rig = Rig::with_app();
    // allowed_once, deny, a refused allow_session that is then denied
    let once = rig.hold_ask("toolu_once", "ls /tmp/cap/once").await;
    let denied = rig.hold_ask("toolu_denied", "ls /tmp/cap/denied").await;
    let refused = rig.hold_ask("toolu_refused", "ls /tmp/cap/refused").await;
    rig.hold_ask("toolu_timeout", "ls /tmp/cap/timeout").await;
    assert_eq!(
        rig.broker
            .answer(&once.request_id, &allow_once(), "w", "app"),
        applied("allowed_once")
    );
    assert_eq!(
        rig.broker.answer(&denied.request_id, &deny(), "w", "app"),
        applied("denied")
    );
    assert_eq!(
        rig.broker.answer(
            &refused.request_id,
            &decision_with(Some("bogus"), Some("Bash(ls:*)")),
            "w",
            "app"
        ),
        AnswerResult::InvalidRule
    );
    assert_eq!(
        rig.broker.answer(
            &refused.request_id,
            &allow_session(&candidate(&once, CandidateKind::Exact)),
            "w",
            "app"
        ),
        AnswerResult::InvalidRule,
        "another (ended) request's candidate"
    );
    // allowed_for_session then allowed_by_session_rule
    rig.grant("toolu_grant", "ls /tmp/cap/grant", CandidateKind::Exact)
        .await;
    rig.assert_allowed_by_rule("toolu_use", "ls /tmp/cap/grant")
        .await;
    // guard_blocked, even with a rule that would match
    rig.broker.inject_session_rule_for_test(
        T,
        rig.generation,
        SessionRule::exact_for_test("ecs_connect ap production portal", None),
    );
    rig.submit_value(
        T,
        rig.generation,
        "toolu_guard",
        ask_request("toolu_guard", "ecs_connect ap production portal"),
    );
    rig.wait_outcome("toolu_guard").await;
    // timed_out
    rig.barrier().await;
    tokio::time::advance(APPROVAL_TIMEOUT).await;
    rig.wait_outcome("toolu_timeout").await;
    rig.wait_outcome("toolu_refused").await;
    // no_app, with a matching rule
    rig.broker.app_disconnected("app");
    rig.submit_value(
        T,
        rig.generation,
        "toolu_noapp",
        ask_request("toolu_noapp", "ls /tmp/cap/grant"),
    );
    rig.wait_outcome("toolu_noapp").await;
    // cancelled
    rig.broker.presenter_connected("app-2");
    rig.hold_ask("toolu_cancelled", "ls /tmp/cap/cancelled")
        .await;
    rig.broker.on_session_gone(T, rig.generation, "stopped");
    rig.wait_outcome("toolu_cancelled").await;

    let entries = rig.entries();
    let outcome_of = |tool_use_id: &str| -> Option<String> {
        entries.iter().find_map(|e| match &e.event {
            Event::Outcome { outcome, .. } if e.tool_use_id.as_deref() == Some(tool_use_id) => {
                Some(outcome.clone())
            }
            _ => None,
        })
    };
    let writes = rig.writes();
    let mut allowing = 0;
    for (cli_id, body) in &writes {
        let tool_use_id = cli_id.strip_prefix("cli-").unwrap();
        let outcome = outcome_of(tool_use_id).unwrap_or_default();
        if body["behavior"] == "allow" {
            allowing += 1;
            assert!(
                ALLOW_OUTCOMES.contains(&outcome.as_str()),
                "{tool_use_id}: {outcome}"
            );
            let keys: Vec<&str> = body
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(
                keys.len(),
                2,
                "{tool_use_id}: only behavior and updatedInput: {body}"
            );
        } else {
            assert_eq!(body["behavior"], "deny", "{tool_use_id}");
            assert!(
                !ALLOW_OUTCOMES.contains(&outcome.as_str()),
                "{tool_use_id}: a deny logged as {outcome}"
            );
        }
    }
    for e in &entries {
        if let Event::Outcome { outcome, .. } = &e.event {
            if ALLOW_OUTCOMES.contains(&outcome.as_str()) {
                let id = format!("cli-{}", e.tool_use_id.as_deref().unwrap());
                assert!(
                    writes
                        .iter()
                        .any(|(r, b)| *r == id && b["behavior"] == "allow"),
                    "{outcome} without an allow written: {e:?}"
                );
            }
        }
    }
    assert_eq!(
        allowing, 3,
        "allowed_once, allowed_for_session, allowed_by_session_rule"
    );
    assert_eq!(outcome_of("toolu_guard").as_deref(), Some("guard_blocked"));
    assert_eq!(outcome_of("toolu_noapp").as_deref(), Some("no_app"));
    assert_eq!(outcome_of("toolu_timeout").as_deref(), Some("timed_out"));
    assert_eq!(outcome_of("toolu_cancelled").as_deref(), Some("cancelled"));
    assert_no_updated_permissions(&writes);
}

/// Removes comments from Rust source, keeping string and char literals (so a needle inside a
/// string literal is still "in the code").
fn without_comments(src: &str) -> String {
    let b: Vec<char> = src.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let next = b.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
        } else if c == '/' && next == Some('*') {
            let mut depth = 1;
            i += 2;
            while i < b.len() && depth > 0 {
                if b[i] == '/' && b.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if b[i] == '*' && b.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
        } else if c == 'r' && matches!(next, Some('"') | Some('#')) && {
            let mut j = i + 1;
            while b.get(j) == Some(&'#') {
                j += 1;
            }
            b.get(j) == Some(&'"')
        } {
            // A raw string: copy it through its closing quote and hashes.
            let mut j = i + 1;
            let mut hashes = 0;
            while b[j] == '#' {
                hashes += 1;
                j += 1;
            }
            j += 1;
            out.extend(&b[i..j]);
            i = j;
            while i < b.len() {
                if b[i] == '"' && (0..hashes).all(|k| b.get(i + 1 + k) == Some(&'#')) {
                    out.extend(&b[i..i + 1 + hashes]);
                    i += 1 + hashes;
                    break;
                }
                out.push(b[i]);
                i += 1;
            }
        } else if c == '"' {
            out.push(c);
            i += 1;
            while i < b.len() && b[i] != '"' {
                if b[i] == '\\' {
                    out.push(b[i]);
                    i += 1;
                }
                if i < b.len() {
                    out.push(b[i]);
                    i += 1;
                }
            }
            if i < b.len() {
                out.push('"');
                i += 1;
            }
        } else if c == '\'' {
            // A char literal ('x', '\n', '"') or a lifetime.
            if next == Some('\\') {
                let mut j = i + 2;
                while j < b.len() && b[j] != '\'' {
                    j += 1;
                }
                out.extend(&b[i..(j + 1).min(b.len())]);
                i = j + 1;
            } else if b.get(i + 2) == Some(&'\'') {
                out.extend(&b[i..i + 3]);
                i += 3;
            } else {
                out.push(c);
                i += 1;
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

// The scanner itself: a needle in any kind of comment is fine, anywhere else is not.
#[test]
fn the_comment_scanner_separates_comments_from_code() {
    let needle = "updatedPermissions";
    for ok in [
        format!("// {needle}\nlet a = 1;"),
        format!("//! `{needle}` is never sent\n"),
        format!("/// {needle}\nfn f() {{}}"),
        format!("/* {needle} */ let a = 1;"),
        format!("/* outer /* {needle} */ still comment {needle} */ let a = 1;"),
        format!("let s = \"quote \\\" \"; // {needle}"),
    ] {
        assert!(!without_comments(&ok).contains(needle), "{ok}");
    }
    for bad in [
        format!("let {needle} = 1;"),
        format!("let s = \"{needle}\";"),
        format!("let s = r#\"{needle}\"#;"),
        format!("let s = \"a // b\"; let t = \"{needle}\";"),
        format!("let c = '\"'; let s = \"{needle}\";"),
        format!("json!({{ \"{needle}\": [] }})"),
        format!("// first\nlet s = \"{needle}\";"),
    ] {
        assert!(without_comments(&bad).contains(needle), "{bad}");
    }
}

// Fails if any source file mentions the key in code (a body builder, a string, a test): the CLI
// keeps its own rules and Nostromo never sends them a permission update.
#[test]
fn updated_permissions_appears_nowhere_in_src_outside_comments() {
    let mut files = Vec::new();
    rust_files(
        &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    assert!(files.len() > 50, "the scan found the source tree");
    let mut hits = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        if without_comments(&text).contains("updatedPermissions") {
            hits.push(file.display().to_string());
        }
    }
    assert!(hits.is_empty(), "`updatedPermissions` in code: {hits:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// R14. The audit trail
// ═════════════════════════════════════════════════════════════════════════════

// Fails if a grant, a use or a revoke is not logged, in this order, with the rule's identity.
#[tokio::test(start_paused = true)]
async fn one_grant_two_uses_and_a_revoke_read_back_in_order_with_the_same_rule() {
    let rig = Rig::with_app();
    let (granting, rule) = rig.grant("toolu_1", CACHES_A, CandidateKind::Exact).await;
    rig.assert_allowed_by_rule("toolu_2", CACHES_A).await;
    rig.assert_allowed_by_rule("toolu_3", CACHES_A).await;
    assert_eq!(
        rig.broker.revoke_session_rule(T, &rule.id, "app", "win-5"),
        RevokeResult::Revoked
    );
    rig.wait_entries("session_rule_revoked", 1).await;

    let names: Vec<String> = rig
        .broker
        .audit()
        .read(everything(), &AuditFilter::default())
        .unwrap()
        .into_iter()
        .filter_map(|e| match &e.event {
            Event::SessionRuleGranted { .. } | Event::SessionRuleRevoked { .. } => {
                Some(e.event.kind().to_owned())
            }
            Event::Outcome { outcome, .. } if outcome == "allowed_by_session_rule" => {
                Some(format!("outcome:{outcome}"))
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        names,
        [
            "session_rule_granted",
            "outcome:allowed_by_session_rule",
            "outcome:allowed_by_session_rule",
            "session_rule_revoked"
        ]
    );
    let granted = rig.entries_of("session_rule_granted");
    let revoked = rig.entries_of("session_rule_revoked");
    let used: Vec<Entry> = rig
        .entries_of("outcome")
        .into_iter()
        .filter(|e| outcome_name(e) == "allowed_by_session_rule")
        .collect();
    assert_eq!((granted.len(), used.len(), revoked.len()), (1, 2, 1));
    assert_eq!(rule_body(&granted[0])["id"], rule.id.as_str());
    assert_eq!(rule_body(&granted[0])["uses"], 0);
    assert_eq!(
        rule_body(&granted[0])["granted_by_request_id"],
        granting.request_id.as_str()
    );
    for u in &used {
        assert_eq!(outcome_rule(u)["rule_id"], rule.id.as_str());
    }
    assert_ne!(used[0].request_id, used[1].request_id);
    assert_eq!(rule_body(&revoked[0])["id"], rule.id.as_str());
    assert_eq!(
        rule_body(&revoked[0])["uses"],
        2,
        "the revoke records how often it was used"
    );
    assert_eq!(rule_body(&revoked[0])["reason"], "user");
    assert!(
        granted[0].ts <= used[0].ts && used[0].ts <= used[1].ts && used[1].ts <= revoked[0].ts,
        "in order"
    );
}

// Fails if a string of the rule reaches the log with an invisible or bidi character in it.
#[tokio::test(start_paused = true)]
async fn every_string_of_a_rule_is_sanitized_in_the_audit_log() {
    let rig = Rig::with_app();
    let agent = "sub\u{200B}\u{202E}1";
    let window = "win\u{200B}\u{FEFF}7";
    let wire = rig
        .hold_value(
            "toolu_1",
            from_agent(ask_request("toolu_1", CACHES_A), agent),
        )
        .await;
    let c = candidate(&wire, CandidateKind::Exact);
    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &allow_session(&c), window, "app"),
        applied("allowed_for_session")
    );
    // The rule still binds the agent it was created for, byte for byte.
    rig.submit_value(
        T,
        rig.generation,
        "toolu_2",
        from_agent(ask_request("toolu_2", CACHES_A), agent),
    );
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_2").await),
        "allowed_by_session_rule"
    );
    let rule = rig.rules(T).remove(0);
    assert_eq!(
        rig.broker.revoke_session_rule(T, &rule.id, "app", window),
        RevokeResult::Revoked
    );

    let granted = rig.wait_entries("session_rule_granted", 1).await;
    let revoked = rig.wait_entries("session_rule_revoked", 1).await;
    for e in granted.iter().chain(&revoked) {
        let body = rule_body(e);
        assert_eq!(
            body["agent_id"],
            "sub\u{27E8}U+200B\u{27E9}\u{27E8}U+202E\u{27E9}1"
        );
        assert_eq!(
            body["granted_by_window"],
            "win\u{27E8}U+200B\u{27E9}\u{27E8}U+FEFF\u{27E9}7"
        );
    }
    assert_eq!(
        rule_body(&revoked[0])["by_window"],
        "win\u{27E8}U+200B\u{27E9}\u{27E8}U+FEFF\u{27E9}7"
    );
    // And nowhere in the files themselves.
    let dir = rig.root.path().join("approvals");
    for file in std::fs::read_dir(&dir).unwrap() {
        let path = file.unwrap().path();
        if path.extension().is_none_or(|e| e != "jsonl") {
            continue;
        }
        let text = std::fs::read_to_string(path).unwrap();
        for line in text.lines().filter(|l| {
            l.contains("\"session_rule_granted\"") || l.contains("\"session_rule_revoked\"")
        }) {
            for c in ['\u{200B}', '\u{202E}', '\u{FEFF}'] {
                assert!(!line.contains(c), "raw {c:?} in {line}");
            }
        }
    }
}
