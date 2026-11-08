//! "Always allow…" rules (AP6): persisted Nostromo rules, driven at the broker the way the
//! server drives it.
//!
//! The socket-level halves (who may create, remove, keep or discard; which connection is sent
//! what; the real fake CLI) live in `tests/approvals_wire.rs` and `tests/ipc_peer_gating.rs`. The
//! store's file handling is unit-tested in `src/approvals/persisted.rs` and `revalidate` in
//! `src/approvals/rules.rs`; this file pins the behaviour a person can see:
//!
//! - creating a rule (`allow_always`): only from the held request's own candidates, with a scope,
//!   written before the allow, and refused (request still held, nothing written) otherwise;
//! - matching: after the guard and the session rules, before a card, across focuses of one repo,
//!   never without an app that can remove rules, never from a quarantined or inactive rule;
//! - tampering: a rules file changed behind the daemon's back is off until a human keeps or
//!   discards it, and Keep never revives a hand-edited rule;
//! - the invariants: Claude settings are never touched, and only the six known endings allow.
//!
//! Time: paused tokio time; the broker's worker is a plain thread, so effects are polled for in
//! real time with a cap (the same way `tests/approvals_session_rules.rs` does).

use std::collections::BTreeMap;
use std::io;
use std::ops::Range;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    AnswerResult, ApprovalBroker, ApprovalPresenters, BrokerParts, Incoming, RulesChange,
    SessionInfo, SessionSink, APPROVAL_TIMEOUT,
};
use nostromo::approvals::guard::{PaneInfo, PaneProbe, ProbeError, TmuxSocket};
use nostromo::approvals::persisted::{PersistedRule, RulesStore, Scope, MAX_PERSISTED_RULES};
use nostromo::approvals::request::{AskRule, PermissionRequest, SettingsSource};
use nostromo::approvals::rules::{self, CandidateKind, SessionRule, Spec};
use nostromo::approvals::wire::{
    ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind, PersistedRuleWire,
    RuleScopeChoice, RulesQuarantineWire, SessionRuleCandidateWire,
};
use nostromo::ipc::protocol::ServerMsg;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::sync::broadcast;

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer; can be told to fail.
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

// ── the world on disk ─────────────────────────────────────────────────────────

const T: &str = "focus-1"; // proj/sub
const T2: &str = "focus-2"; // proj
const T3: &str = "focus-3"; // proj-two: another repository
const BARRIER: &str = "barrier"; // not guarded
const CACHES_A: &str = "rm -rf ~/Library/Caches/a";
const CACHES_B: &str = "rm -rf ~/Library/Caches/b";
const ELSEWHERE: &str = "rm -rf ~/Elsewhere/x";

/// Directories every rig of one `root` shares: a daemon "restarted" over the same root sees
/// the same repositories, home and approvals directory.
#[derive(Clone)]
struct Layout {
    home: PathBuf,
    approvals: PathBuf,
    /// A git repository.
    proj: PathBuf,
    /// A directory inside `proj`.
    proj_sub: PathBuf,
    /// Another git repository whose name starts with `proj`'s.
    proj_two: PathBuf,
    /// Not a git repository.
    plain: PathBuf,
}

impl Layout {
    fn create(root: &Path) -> Self {
        let l = Self {
            home: root.join("home"),
            approvals: root.join("approvals"),
            proj: root.join("proj"),
            proj_sub: root.join("proj/sub"),
            proj_two: root.join("proj-two"),
            plain: root.join("plain"),
        };
        std::fs::create_dir_all(l.home.join("Library/Caches")).unwrap();
        std::fs::create_dir_all(l.home.join("Elsewhere")).unwrap();
        std::fs::create_dir_all(l.proj.join(".git")).unwrap();
        std::fs::create_dir_all(&l.proj_sub).unwrap();
        std::fs::create_dir_all(l.proj_two.join(".git")).unwrap();
        std::fs::create_dir_all(&l.plain).unwrap();
        std::fs::create_dir_all(&l.approvals).unwrap();
        l
    }

    fn rules_json(&self) -> PathBuf {
        self.approvals.join("rules.json")
    }

    fn sidecar(&self) -> PathBuf {
        self.approvals.join("rules.json.sha256")
    }
}

fn sha_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// Write `bytes` the way the daemon would have (0600).
fn write_private(path: &Path, bytes: &[u8]) {
    std::fs::write(path, bytes).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// A `can_use_tool` request for `command`, as raised by an ask rule that matched.
fn ask_request(tool_use_id: &str, command: &str) -> Value {
    let mut v = bash_request(tool_use_id, command);
    v["matched_ask_rule"] =
        json!({ "source": "userSettings", "tool_name": "Bash", "rule_content": "rm:*" });
    v
}

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

fn input_of(command: &str) -> Value {
    json!({ "command": command, "description": "d" })
}

/// A rule as AP6 would have stored it for `command`, built from AP4's own candidate.
fn crafted(
    id: &str,
    home: &Path,
    command: &str,
    kind: CandidateKind,
    scope: Scope,
) -> PersistedRule {
    let req = PermissionRequest::from_cli(&ask_request("toolu_crafted", command)).unwrap();
    let reason = req.reason(None, &NoRules);
    let c = rules::candidates(&req, &reason, home, None)
        .into_iter()
        .find(|c| c.kind == kind)
        .unwrap_or_else(|| panic!("AP4 offers no {kind:?} candidate for {command}"));
    PersistedRule {
        id: id.to_owned(),
        rule_text: c.rule_text,
        summary: c.summary,
        kind: c.kind,
        spec: c.spec,
        source_command: command.to_owned(),
        scope,
        created_at_ms: 1_760_000_000_000,
        created_from_request_id: "req-crafted".into(),
        created_by_window: "w-crafted".into(),
        uses: 0,
    }
}

/// Put `rules` in `rules.json` through the real store (so the file is exactly as the daemon writes it).
fn seed(l: &Layout, rules: Vec<PersistedRule>) {
    let (store, report) = RulesStore::open(&l.approvals, &l.home);
    assert!(report.quarantined.is_none(), "{report:?}");
    for r in rules {
        store.add(r).expect("seeded");
    }
}

fn file_body(rules: &[PersistedRule]) -> Vec<u8> {
    serde_json::to_vec_pretty(&json!({ "v": 1, "rules": rules })).unwrap()
}

/// The three rules a hand edit might add to widen what a stored rule allows. Each keeps a
/// broad spec: if anything trusted the file's own spec, they would allow far more than the human did.
fn hand_edited_broad_rules(legit: &PersistedRule, home: &Path) -> Vec<PersistedRule> {
    let broad =
        |id: &str, text: &str, head: &[&str], prefix: &str, resolved: &Path| PersistedRule {
            id: id.into(),
            rule_text: text.into(),
            kind: CandidateKind::PathPrefix,
            spec: Spec::PathPrefix {
                head: head.iter().map(|s| s.to_string()).collect(),
                prefix: prefix.into(),
                resolved: resolved.to_path_buf(),
            },
            ..legit.clone()
        };
    vec![
        broad("evil-1", "Bash(rm:*)", &["rm"], "/", Path::new("/")),
        broad("evil-2", "Bash(rm -rf ~/:*)", &["rm", "-rf"], "~/", home),
        broad("evil-3", "Bash", &["rm", "-rf"], "~/", home),
    ]
}

// ── the rig ───────────────────────────────────────────────────────────────────

struct Rig {
    broker: ApprovalBroker,
    sink: Arc<FakeSink>,
    sink2: Arc<FakeSink>,
    frames: broadcast::Receiver<ServerMsg>,
    root: Arc<tempfile::TempDir>,
    l: Layout,
    g1: u64,
    g2: u64,
    g3: u64,
    barrier_generation: u64,
    barriers: AtomicUsize,
}

fn session(tag: &str, guarded: bool, cwd: &Path) -> SessionInfo {
    SessionInfo {
        tag: tag.into(),
        agent: "cody".into(),
        session_id: Some(format!("sid-{tag}")),
        cwd: Some(cwd.to_path_buf()),
        guarded,
    }
}

fn decision(
    kind: DecisionKind,
    id: Option<&str>,
    text: Option<&str>,
    scope: Option<RuleScopeChoice>,
) -> ApprovalDecision {
    ApprovalDecision {
        kind,
        note: None,
        answers: None,
        candidate_id: id.map(str::to_owned),
        rule_text: text.map(str::to_owned),
        scope,
    }
}

fn allow_always(c: &SessionRuleCandidateWire, scope: RuleScopeChoice) -> ApprovalDecision {
    decision(
        DecisionKind::AllowAlways,
        Some(&c.id),
        Some(&c.rule_text),
        Some(scope),
    )
}

fn deny() -> ApprovalDecision {
    decision(DecisionKind::Deny, None, None, None)
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

fn applied(outcome: &str) -> AnswerResult {
    AnswerResult::Applied {
        outcome: outcome.to_owned(),
    }
}

impl Rig {
    fn new() -> Self {
        Self::over(Arc::new(tempfile::tempdir().unwrap()))
    }

    fn with_app() -> Self {
        let rig = Self::new();
        rig.broker.presenter_connected("app");
        rig
    }

    /// A broker over `root`: a second one is "the daemon, restarted". The rules file is loaded
    /// (`attach_rules_store`) exactly as `nostromd` does at start.
    fn over(root: Arc<tempfile::TempDir>) -> Self {
        let l = Layout::create(root.path());
        let presenters = ApprovalPresenters::default();
        let broker = ApprovalBroker::new(
            AuditLog::open(&l.approvals).unwrap(),
            BrokerParts {
                presenter: Arc::new(presenters.clone()),
                presenters: presenters.clone(),
                probe: Arc::new(|| Box::new(ProdPane)),
                settings: Arc::new(NoRules),
                timeout: APPROVAL_TIMEOUT,
            },
        );
        broker.set_home_for_test(l.home.clone());
        broker
            .attach_rules_store()
            .expect("the rules store attaches");
        let (tx, frames) = broadcast::channel(8192);
        broker.configure_broadcast(tx);
        let (sink, sink2) = (FakeSink::new(), FakeSink::new());
        let g1 = broker.register_session(session(T, true, &l.proj_sub), sink.clone());
        let g2 = broker.register_session(session(T2, true, &l.proj), sink2.clone());
        let g3 = broker.register_session(session(T3, true, &l.proj_two), FakeSink::new());
        let barrier_generation =
            broker.register_session(session(BARRIER, false, &l.proj_two), FakeSink::new());
        Self {
            broker,
            sink,
            sink2,
            frames,
            root,
            l,
            g1,
            g2,
            g3,
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

    async fn hold_on(
        &self,
        tag: &str,
        generation: u64,
        tool_use_id: &str,
        command: &str,
    ) -> ApprovalRequestWire {
        self.submit_value(
            tag,
            generation,
            tool_use_id,
            ask_request(tool_use_id, command),
        );
        wait_until(&format!("{tool_use_id} to be held"), || {
            self.broker
                .snapshot()
                .into_iter()
                .find(|w| w.tool_use_id == tool_use_id)
        })
        .await
    }

    /// Hold `command` on `T`.
    async fn hold(&self, tool_use_id: &str, command: &str) -> ApprovalRequestWire {
        self.hold_on(T, self.g1, tool_use_id, command).await
    }

    /// `command` must be a card (no rule covers it); the card is then denied.
    async fn assert_card_on(&self, tag: &str, generation: u64, tool_use_id: &str, command: &str) {
        let wire = self.hold_on(tag, generation, tool_use_id, command).await;
        assert_eq!(
            self.broker
                .answer(&wire.request_id, &deny(), "w-clean", "app"),
            applied("denied"),
            "{command} on {tag}"
        );
    }

    async fn assert_card(&self, tool_use_id: &str, command: &str) {
        self.assert_card_on(T, self.g1, tool_use_id, command).await;
    }

    /// `command` must be allowed by the persisted rule at once, without a card; returns the outcome entry.
    async fn assert_allowed_by_your_rule_on(
        &self,
        tag: &str,
        generation: u64,
        tool_use_id: &str,
        command: &str,
    ) -> Entry {
        self.submit_value(
            tag,
            generation,
            tool_use_id,
            ask_request(tool_use_id, command),
        );
        let outcome = self.wait_outcome(tool_use_id).await;
        assert_eq!(
            outcome_name(&outcome),
            "allowed_by_your_rule",
            "{command} on {tag}"
        );
        assert!(
            !self
                .broker
                .snapshot()
                .iter()
                .any(|w| w.tool_use_id == tool_use_id),
            "{command}: no card"
        );
        outcome
    }

    async fn assert_allowed_by_your_rule(&self, tool_use_id: &str, command: &str) -> Entry {
        self.assert_allowed_by_your_rule_on(T, self.g1, tool_use_id, command)
            .await
    }

    /// Hold `command` on `T` and answer `allow_always` with its `kind` candidate; returns the
    /// request and the rule now listed for it.
    async fn always(
        &self,
        tool_use_id: &str,
        command: &str,
        kind: CandidateKind,
        scope: RuleScopeChoice,
    ) -> (ApprovalRequestWire, PersistedRuleWire) {
        let wire = self.hold(tool_use_id, command).await;
        let c = candidate(&wire, kind);
        assert_eq!(
            self.broker.answer(
                &wire.request_id,
                &allow_always(&c, scope),
                "w-always",
                "app"
            ),
            applied("allowed_always")
        );
        let rule = self
            .rules()
            .into_iter()
            .find(|r| r.rule_text == c.rule_text)
            .expect("the rule is listed after Always allow");
        (wire, rule)
    }

    fn rules_and_quarantine(
        &self,
    ) -> (Vec<PersistedRuleWire>, Option<RulesQuarantineWire>, String) {
        match self.broker.rules_frame() {
            ServerMsg::ApprovalRules {
                rules,
                quarantined,
                path,
            } => (rules, quarantined, path),
            other => panic!("{other:?}"),
        }
    }

    fn rules(&self) -> Vec<PersistedRuleWire> {
        self.rules_and_quarantine().0
    }

    fn quarantine(&self) -> Option<RulesQuarantineWire> {
        self.rules_and_quarantine().1
    }

    /// The rules file as JSON.
    fn file(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.l.rules_json()).unwrap()).unwrap()
    }

    fn file_bytes(&self) -> Option<Vec<u8>> {
        std::fs::read(self.l.rules_json()).ok()
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

    /// Everything written to `T`'s stdin for `tool_use_id`.
    fn writes_for(&self, tool_use_id: &str) -> Vec<Value> {
        let id = format!("cli-{tool_use_id}");
        self.sink
            .writes()
            .into_iter()
            .filter(|(r, _)| *r == id)
            .map(|(_, b)| b)
            .collect()
    }

    /// The request stays held: the proof is that a plain deny still ends it.
    fn assert_still_held_then_deny(&self, wire: &ApprovalRequestWire) {
        assert!(
            self.broker
                .snapshot()
                .iter()
                .any(|w| w.request_id == wire.request_id),
            "the request stays held"
        );
        assert_eq!(
            self.broker
                .answer(&wire.request_id, &deny(), "w-after", "app"),
            applied("denied")
        );
    }

    /// Nothing was written for rules: no file change, no `rule_written`, nothing to the CLI.
    fn assert_nothing_written(&self, file_before: &Option<Vec<u8>>) {
        assert_eq!(
            &self.file_bytes(),
            file_before,
            "the rules file is unchanged"
        );
        assert!(self.entries_of("rule_written").is_empty());
        assert!(
            !self
                .sink
                .writes()
                .iter()
                .any(|(_, b)| b["behavior"] == "allow"),
            "no allow reached the CLI"
        );
    }
}

fn everything() -> Range<DateTime<Utc>> {
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

fn index_of(entries: &[Entry], kind: &str) -> usize {
    entries
        .iter()
        .position(|e| e.event.kind() == kind)
        .unwrap_or_else(|| panic!("no `{kind}` entry"))
}

fn rules_frames(frames: &[ServerMsg]) -> Vec<&Vec<PersistedRuleWire>> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalRules { rules, .. } => Some(rules),
            _ => None,
        })
        .collect()
}

// ═════════════════════════════════════════════════════════════════════════════
// Creation: `allow_always`
// ═════════════════════════════════════════════════════════════════════════════

// Fails if a held request is not offered "Always allow…" next to the session option, or if the
// card cannot show the exact repository folder the rule would apply to.
#[tokio::test(start_paused = true)]
async fn a_held_request_with_candidates_is_offered_allow_always_and_names_its_repository_root() {
    let rig = Rig::with_app();

    let wire = rig.hold("toolu_1", CACHES_A).await;

    assert!(wire.options.contains(&ApprovalOption::AllowSession));
    assert!(wire.options.contains(&ApprovalOption::AllowAlways));
    let root = nostromo::tracker::paths::find_repo_root(&rig.l.proj_sub);
    assert_eq!(
        root.dir, rig.l.proj,
        "the session is inside the git repository"
    );
    assert_eq!(
        wire.repo_root,
        Some(root.dir.to_string_lossy().into_owned())
    );
    assert!(wire.repo_is_git);
    let json = serde_json::to_value(&wire).unwrap();
    assert!(json["options"]
        .as_array()
        .unwrap()
        .iter()
        .any(|o| o == "allow_always"));
    assert_eq!(json["repo_is_git"], true);
}

// Fails if a session outside any repository claims it is in one: the card must say the "repo"
// is only the working folder.
#[tokio::test(start_paused = true)]
async fn outside_a_git_repository_the_repo_root_is_the_working_folder_and_is_not_called_git() {
    let rig = Rig::with_app();
    let g = rig
        .broker
        .register_session(session("plain-focus", true, &rig.l.plain), FakeSink::new());

    let wire = rig.hold_on("plain-focus", g, "toolu_plain", CACHES_A).await;

    assert_eq!(
        wire.repo_root,
        Some(rig.l.plain.to_string_lossy().into_owned())
    );
    assert!(!wire.repo_is_git);
    let c = candidate(&wire, CandidateKind::Exact);
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(&c, RuleScopeChoice::Repo),
            "w",
            "app"
        ),
        applied("allowed_always")
    );
    let rule = rig.rules().remove(0);
    assert_eq!(rule.root, Some(rig.l.plain.to_string_lossy().into_owned()));
}

// Fails if the rule is not written (0600, with its hash sidecar) before the allow ends the
// request, if the audit trail is out of order, or if the CLI is told anything but a plain allow.
#[tokio::test(start_paused = true)]
async fn always_allow_writes_the_rule_then_logs_it_then_allows_this_call_once_and_tells_the_app() {
    let mut rig = Rig::with_app();
    let wire = rig.hold("toolu_1", CACHES_A).await;
    rig.frames();
    let c = candidate(&wire, CandidateKind::Exact);

    let result = rig.broker.answer(
        &wire.request_id,
        &allow_always(&c, RuleScopeChoice::Repo),
        "w-always",
        "app",
    );

    assert_eq!(result, applied("allowed_always"));
    // The file: one rule, exactly the candidate's text, scoped to the daemon-computed repo root.
    let file = rig.file();
    assert_eq!(file["rules"].as_array().unwrap().len(), 1);
    let stored = &file["rules"][0];
    assert_eq!(stored["rule_text"], c.rule_text.as_str());
    assert_eq!(stored["kind"], "exact");
    assert_eq!(stored["scope"]["type"], "repo");
    assert_eq!(
        stored["scope"]["root"],
        rig.l.proj.to_string_lossy().into_owned()
    );
    assert_eq!(stored["created_from_request_id"], wire.request_id.as_str());
    let mode = std::fs::metadata(rig.l.rules_json())
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    assert_eq!(
        std::fs::read_to_string(rig.l.sidecar()).unwrap().trim(),
        sha_hex(&rig.file_bytes().unwrap())
    );
    // The audit trail: the rule, then the outcome.
    let entries = rig.entries();
    assert!(index_of(&entries, "rule_written") < index_of(&entries, "outcome"));
    let written = &rig.entries_of("rule_written")[0];
    match &written.event {
        Event::RuleWritten { rule } => {
            assert_eq!(rule["rule_text"], c.rule_text.as_str());
            assert_eq!(rule["id"], stored["id"]);
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        written.request_id.as_deref(),
        Some(wire.request_id.as_str())
    );
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_1").await),
        "allowed_always"
    );
    // The CLI: exactly one allow, the input unchanged, and no permission update.
    let writes = rig.writes_for("toolu_1");
    assert_eq!(
        writes,
        vec![json!({ "behavior": "allow", "updatedInput": input_of(CACHES_A) })]
    );
    // The app is told the whole list, and the request is resolved.
    let frames = rig
        .frames_until("the rules list", |m| {
            matches!(m, ServerMsg::ApprovalRules { .. })
        })
        .await;
    assert!(rules_frames(&frames)
        .iter()
        .any(|r| r.len() == 1 && r[0].rule_text == c.rule_text));
    assert!(frames.iter().any(|m| matches!(
        m,
        ServerMsg::ApprovalResolved { outcome, .. } if outcome == "allowed_always"
    )));
    assert!(!rig
        .sink
        .writes()
        .iter()
        .any(|(_, b)| b.to_string().contains("updatedPermissions")));
}

// Fails if the prefix candidate cannot be made a rule, or its scope choice is not honoured.
#[tokio::test(start_paused = true)]
async fn a_path_prefix_candidate_with_the_all_repos_scope_is_stored_without_a_root() {
    let rig = Rig::with_app();

    let (_, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::AllRepos,
        )
        .await;

    assert_eq!(rule.rule_text, "Bash(rm -rf ~/Library/Caches/:*)");
    assert_eq!(rule.kind, CandidateKind::PathPrefix);
    assert_eq!(rule.scope, RuleScopeChoice::AllRepos);
    assert_eq!(rule.root, None);
    assert!(rule.active);
    assert_eq!(rig.file()["rules"][0]["scope"]["type"], "all_repos");
}

// Fails if any of these is accepted: an id the request never offered, edited text, a missing id or
// text, another request's candidate, or no scope. In every case the request stays held and
// nothing is written.
#[tokio::test(start_paused = true)]
async fn an_allow_always_that_is_not_one_of_this_requests_own_candidates_is_refused_and_writes_nothing(
) {
    let rig = Rig::with_app();
    let other = rig.hold("toolu_other", "ls /tmp/cap/other").await;
    assert_eq!(
        rig.broker.answer(&other.request_id, &deny(), "w", "app"),
        applied("denied")
    );
    let wire = rig.hold("toolu_1", CACHES_A).await;
    let exact = candidate(&wire, CandidateKind::Exact);
    let before = rig.file_bytes();
    let scope = Some(RuleScopeChoice::AllRepos);

    let cases: Vec<(&str, ApprovalDecision)> = vec![
        (
            "an id nobody offered",
            decision(
                DecisionKind::AllowAlways,
                Some("not-an-id"),
                Some(&exact.rule_text),
                scope,
            ),
        ),
        (
            "edited text: whole command word",
            decision(
                DecisionKind::AllowAlways,
                Some(&exact.id),
                Some("Bash(rm:*)"),
                scope,
            ),
        ),
        (
            "edited text: wider prefix",
            decision(
                DecisionKind::AllowAlways,
                Some(&exact.id),
                Some("Bash(rm -rf ~/:*)"),
                scope,
            ),
        ),
        (
            "edited text: one byte added",
            decision(
                DecisionKind::AllowAlways,
                Some(&exact.id),
                Some(&format!("{} ", exact.rule_text)),
                scope,
            ),
        ),
        (
            "the prefix text under the exact id",
            decision(
                DecisionKind::AllowAlways,
                Some(&exact.id),
                Some(&candidate(&wire, CandidateKind::PathPrefix).rule_text),
                scope,
            ),
        ),
        (
            "no id",
            decision(
                DecisionKind::AllowAlways,
                None,
                Some(&exact.rule_text),
                scope,
            ),
        ),
        (
            "no text",
            decision(DecisionKind::AllowAlways, Some(&exact.id), None, scope),
        ),
        (
            "neither",
            decision(DecisionKind::AllowAlways, None, None, scope),
        ),
    ];
    for (what, d) in cases {
        assert_eq!(
            rig.broker.answer(&wire.request_id, &d, "w", "app"),
            AnswerResult::InvalidRule,
            "{what}"
        );
    }
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(
                &candidate(&other, CandidateKind::Exact),
                RuleScopeChoice::AllRepos
            ),
            "w",
            "app"
        ),
        AnswerResult::InvalidRule,
        "another (ended) request's candidate"
    );
    match rig.broker.answer(
        &wire.request_id,
        &decision(
            DecisionKind::AllowAlways,
            Some(&exact.id),
            Some(&exact.rule_text),
            None,
        ),
        "w",
        "app",
    ) {
        AnswerResult::RuleRefused(why) => assert!(!why.is_empty(), "the card is told why"),
        other => panic!("a missing scope must be refused as rule_refused, got {other:?}"),
    }

    rig.assert_nothing_written(&before);
    rig.assert_still_held_then_deny(&wire);
}

// Fails if a request with no candidates (a compound command) is offered Always allow, or can be
// answered with one.
#[tokio::test(start_paused = true)]
async fn a_request_with_no_candidates_is_not_offered_allow_always_and_cannot_be_answered_with_it() {
    let rig = Rig::with_app();
    let wire = rig
        .hold("toolu_1", "rm -rf ~/Library/Caches/a && echo done")
        .await;

    assert!(wire.session_rule_candidates.is_empty());
    assert!(!wire.options.contains(&ApprovalOption::AllowAlways));
    assert!(!wire.options.contains(&ApprovalOption::AllowSession));
    let made_up = decision(
        DecisionKind::AllowAlways,
        Some("made-up"),
        Some("Bash(rm -rf ~/Library/Caches/a && echo done)"),
        Some(RuleScopeChoice::AllRepos),
    );
    assert_eq!(
        rig.broker.answer(&wire.request_id, &made_up, "w", "app"),
        AnswerResult::InvalidRule
    );
    rig.assert_nothing_written(&None);
    rig.assert_still_held_then_deny(&wire);
}

// Fails if the guard is not consulted again when the rule is chosen: it may have started to block
// the command (or the command the rule stands for) since the card was shown.
#[tokio::test(start_paused = true)]
async fn an_allow_always_for_a_command_the_guard_now_blocks_is_refused_and_writes_nothing() {
    let rig = Rig::with_app();
    let wire = rig.hold("toolu_guard_later", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    let before = rig.file_bytes();

    nostromo::approvals::broker::force_guard_block_for_test("toolu_guard_later");
    let result = rig.broker.answer(
        &wire.request_id,
        &allow_always(&c, RuleScopeChoice::AllRepos),
        "w",
        "app",
    );

    match result {
        AnswerResult::RuleRefused(why) => assert!(!why.is_empty()),
        other => panic!("expected rule_refused, got {other:?}"),
    }
    rig.assert_nothing_written(&before);
    assert!(rig.rules().is_empty());
}

// Fails if a full file, a quarantined file, or a write that cannot happen lets the allow through
// anyway (the human's choice is all-or-nothing: no rule, no allow).
#[tokio::test(start_paused = true)]
async fn a_rule_that_cannot_be_kept_is_refused_with_its_own_code_and_the_request_stays_held() {
    // The limit: 200 rules already stored (loaded at start).
    let root = Arc::new(tempfile::tempdir().unwrap());
    let l = Layout::create(root.path());
    seed(
        &l,
        (0..MAX_PERSISTED_RULES)
            .map(|i| {
                crafted(
                    &format!("r{i}"),
                    &l.home,
                    CACHES_A,
                    CandidateKind::Exact,
                    Scope::AllRepos,
                )
            })
            .collect(),
    );
    let rig = Rig::over(root);
    rig.broker.presenter_connected("app");
    assert_eq!(rig.rules().len(), MAX_PERSISTED_RULES);
    let wire = rig.hold("toolu_limit", CACHES_B).await;
    let c = candidate(&wire, CandidateKind::Exact);
    let before = rig.file_bytes();
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(&c, RuleScopeChoice::AllRepos),
            "w",
            "app"
        ),
        AnswerResult::RuleLimit
    );
    rig.assert_nothing_written(&before);
    assert_eq!(rig.rules().len(), MAX_PERSISTED_RULES);
    rig.assert_still_held_then_deny(&wire);

    // Quarantined.
    let rig = Rig::with_app();
    rig.always(
        "toolu_seed",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    tamper_content(&rig);
    rig.broker.rules_external_check();
    assert!(rig.quarantine().is_some());
    let wire = rig.hold("toolu_q", CACHES_B).await;
    let c = candidate(&wire, CandidateKind::Exact);
    let before = rig.file_bytes();
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(&c, RuleScopeChoice::AllRepos),
            "w",
            "app"
        ),
        AnswerResult::RulesQuarantined
    );
    assert_eq!(rig.file_bytes(), before);
    assert_eq!(
        rig.entries_of("rule_written").len(),
        1,
        "only the seeding rule was ever written"
    );
    rig.assert_still_held_then_deny(&wire);

    // The file cannot be written (something that is not a file sits where it goes).
    let rig = Rig::with_app();
    let wire = rig.hold("toolu_w", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    std::fs::create_dir(rig.l.rules_json()).unwrap();
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(&c, RuleScopeChoice::AllRepos),
            "w",
            "app"
        ),
        AnswerResult::RuleWriteFailed
    );
    assert!(rig.entries_of("rule_written").is_empty());
    assert!(rig.sink.writes().is_empty(), "no write, no allow");
    assert!(rig.rules().is_empty(), "the rule is not listed");
    rig.assert_still_held_then_deny(&wire);
}

// Fails if the rule outlives an allow that was never written (the CLI's stdin is closed).
#[tokio::test(start_paused = true)]
async fn no_rule_is_kept_when_the_allow_itself_cannot_be_written() {
    let rig = Rig::with_app();
    let wire = rig.hold("toolu_1", CACHES_A).await;
    let c = candidate(&wire, CandidateKind::Exact);
    rig.sink.live.store(false, Ordering::SeqCst);

    let result = rig.broker.answer(
        &wire.request_id,
        &allow_always(&c, RuleScopeChoice::AllRepos),
        "w",
        "app",
    );

    assert!(
        matches!(&result, AnswerResult::Applied { outcome } if outcome != "allowed_always"),
        "{result:?}"
    );
    assert!(rig.sink.writes().is_empty());
    assert!(
        rig.rules().is_empty(),
        "a rule exists only because its allow was written"
    );
    assert!(rig.file()["rules"].as_array().unwrap().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// Matching
// ═════════════════════════════════════════════════════════════════════════════

// Fails if a persisted match is not an outcome of its own naming the rule, or its use is not counted
// and broadcast, or the use is written to disk on every call.
#[tokio::test(start_paused = true)]
async fn a_later_matching_request_is_allowed_without_a_card_by_a_named_rule_and_its_use_is_counted()
{
    let mut rig = Rig::with_app();
    let (wire, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::Repo,
        )
        .await;
    rig.frames();

    let outcome = rig.assert_allowed_by_your_rule("toolu_2", CACHES_B).await;

    let named = outcome_rule(&outcome);
    assert_eq!(named["rule_id"], rule.id.as_str());
    assert_eq!(named["rule_text"], rule.rule_text.as_str());
    assert!(named["created_at"].as_str().is_some_and(|s| !s.is_empty()));
    assert_eq!(named["created_from_request_id"], wire.request_id.as_str());
    assert_eq!(
        rig.writes_for("toolu_2"),
        vec![json!({ "behavior": "allow", "updatedInput": input_of(CACHES_B) })],
        "the agent's own input, unchanged"
    );
    assert_eq!(rig.rules()[0].uses, 1);
    let frames = rig
        .frames_until("the use count", |m| {
            matches!(m, ServerMsg::ApprovalRules { rules, .. } if rules.first().is_some_and(|r| r.uses == 1))
        })
        .await;
    assert!(frames.iter().any(|m| matches!(
        m,
        ServerMsg::ApprovalResolved { outcome, .. } if outcome == "allowed_by_your_rule"
    )));
    // Lazy: the file is not rewritten per use, but a shutdown writes the count (and the daemon's
    // own write never looks like tampering).
    assert_eq!(rig.file()["rules"][0]["uses"], 0);
    rig.broker.deny_all_for_shutdown();
    assert_eq!(rig.file()["rules"][0]["uses"], 1);
    assert_eq!(
        std::fs::read_to_string(rig.l.sidecar()).unwrap().trim(),
        sha_hex(&rig.file_bytes().unwrap())
    );
    rig.broker.rules_external_check();
    assert!(rig.quarantine().is_none());
}

// The order, in code: guard, then session rule, then persisted rule, then a card.
#[tokio::test(start_paused = true)]
async fn the_guard_comes_first_then_a_session_rule_then_a_persisted_rule_then_a_card() {
    let rig = Rig::with_app();
    let (_, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::AllRepos,
        )
        .await;
    rig.assert_allowed_by_your_rule("toolu_control", CACHES_B)
        .await;

    // 1. Guard first: the same request with the guard forced to block is guard_blocked.
    nostromo::approvals::broker::force_guard_block_for_test("toolu_forced");
    rig.submit_value(
        T,
        rig.g1,
        "toolu_forced",
        ask_request("toolu_forced", CACHES_B),
    );
    let outcome = rig.wait_outcome("toolu_forced").await;
    assert_eq!(outcome_name(&outcome), "guard_blocked");
    assert_eq!(rig.writes_for("toolu_forced").len(), 1);
    assert_eq!(rig.writes_for("toolu_forced")[0]["behavior"], "deny");

    // 2. A session rule that also matches wins, and the persisted rule is not used.
    let mut session_rule = SessionRule::exact_for_test(CACHES_B, &rig.l.home, None);
    session_rule.session_id = Some(format!("sid-{T}"));
    rig.broker
        .inject_session_rule_for_test(T, rig.g1, session_rule);
    rig.submit_value(T, rig.g1, "toolu_both", ask_request("toolu_both", CACHES_B));
    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_both").await),
        "allowed_by_session_rule"
    );
    assert_eq!(
        rig.rules().iter().find(|r| r.id == rule.id).unwrap().uses,
        1,
        "only the control request used the persisted rule"
    );

    // 3. Neither: a card.
    rig.assert_card("toolu_elsewhere", ELSEWHERE).await;
}

// Scope: Repo{root} covers sessions whose folder is root or below (compared after resolving
// symlinks), not another repository, not a folder that merely starts with the same letters.
#[tokio::test(start_paused = true)]
async fn a_repo_rule_covers_sessions_inside_that_repository_and_no_other() {
    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::PathPrefix,
        RuleScopeChoice::Repo,
    )
    .await;
    let link = rig.root.path().join("link-into-proj");
    std::os::unix::fs::symlink(&rig.l.proj_sub, &link).unwrap();
    let via_link = rig
        .broker
        .register_session(session("focus-link", true, &link), FakeSink::new());

    // Below the root, at the root, and through a symlink into the repo: allowed.
    rig.assert_allowed_by_your_rule_on(T, rig.g1, "toolu_below", CACHES_B)
        .await;
    rig.assert_allowed_by_your_rule_on(T2, rig.g2, "toolu_root", CACHES_B)
        .await;
    rig.assert_allowed_by_your_rule_on("focus-link", via_link, "toolu_link", CACHES_B)
        .await;
    // Another repository whose name merely starts with this one's: a card.
    rig.assert_card_on(T3, rig.g3, "toolu_other_repo", CACHES_B)
        .await;
}

// A dotfiles repository at `~/.git` makes the "repository" the home folder: no saved rule may
// be scoped to it (the card's "All repositories" is the explicit, wider choice).
#[tokio::test(start_paused = true)]
async fn a_repository_that_is_the_home_folder_cannot_hold_a_saved_rule() {
    let rig = Rig::with_app();
    std::fs::create_dir_all(rig.l.home.join(".git")).unwrap();
    let generation = rig
        .broker
        .register_session(session("focus-home", true, &rig.l.home), FakeSink::new());
    let wire = rig
        .hold_on("focus-home", generation, "toolu_home", CACHES_A)
        .await;
    let c = candidate(&wire, CandidateKind::PathPrefix);

    match rig.broker.answer(
        &wire.request_id,
        &allow_always(&c, RuleScopeChoice::Repo),
        "w-always",
        "app",
    ) {
        AnswerResult::RuleRefused(why) => assert!(!why.is_empty()),
        other => panic!("a home-folder repository must be refused, got {other:?}"),
    }

    assert!(rig.rules().is_empty(), "nothing was written");
}

#[tokio::test(start_paused = true)]
async fn an_all_repos_rule_covers_every_repository() {
    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::PathPrefix,
        RuleScopeChoice::AllRepos,
    )
    .await;

    rig.assert_allowed_by_your_rule_on(T3, rig.g3, "toolu_other_repo", CACHES_B)
        .await;
    rig.assert_allowed_by_your_rule_on(T2, rig.g2, "toolu_this_repo", CACHES_B)
        .await;
}

// The point of "Always": a rule written in one focus covers another focus of the same repository,
// and a request it does not cover is still a card.
#[tokio::test(start_paused = true)]
async fn a_rule_written_in_one_focus_allows_a_matching_request_in_another_and_not_a_different_one()
{
    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::PathPrefix,
        RuleScopeChoice::Repo,
    )
    .await;

    rig.assert_allowed_by_your_rule_on(T2, rig.g2, "toolu_b", CACHES_B)
        .await;
    assert_eq!(rig.sink2.writes().len(), 1, "focus B's own CLI was told");
    assert_eq!(rig.sink2.writes()[0].1["behavior"], "allow");
    rig.assert_card_on(T2, rig.g2, "toolu_elsewhere", ELSEWHERE)
        .await;
    rig.assert_card_on(T2, rig.g2, "toolu_flag", "rm -rf -v ~/Library/Caches/b")
        .await;
    rig.assert_card_on(
        T2,
        rig.g2,
        "toolu_compound",
        "rm -rf ~/Library/Caches/b && echo done",
    )
    .await;
}

// Fails if remove does not take effect at once, or an unknown id / a non-presenter changes anything.
#[tokio::test(start_paused = true)]
async fn removing_a_rule_takes_effect_at_once_is_logged_and_the_next_request_is_a_card() {
    let mut rig = Rig::with_app();
    let (_, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::AllRepos,
        )
        .await;
    rig.assert_allowed_by_your_rule("toolu_use", CACHES_B).await;
    let before = rig.file_bytes();
    rig.frames();

    // Refused: nothing changes.
    assert_eq!(
        rig.broker.remove_persisted_rule("no-such-rule", "app", "w"),
        RulesChange::Unknown
    );
    assert_eq!(
        rig.broker
            .remove_persisted_rule(&rule.id, "not-a-presenter", "w"),
        RulesChange::NotPresenter
    );
    assert_eq!(rig.rules().len(), 1);
    assert_eq!(rig.file_bytes(), before);
    assert!(rig.entries_of("rule_removed").is_empty());
    rig.assert_allowed_by_your_rule("toolu_still", CACHES_B)
        .await;

    // Applied.
    assert_eq!(
        rig.broker
            .remove_persisted_rule(&rule.id, "app", "w-remove"),
        RulesChange::Applied
    );
    assert!(rig.rules().is_empty());
    assert!(rig.file()["rules"].as_array().unwrap().is_empty());
    assert_eq!(
        std::fs::read_to_string(rig.l.sidecar()).unwrap().trim(),
        sha_hex(&rig.file_bytes().unwrap())
    );
    let removed = rig.entries_of("rule_removed");
    assert_eq!(removed.len(), 1);
    match &removed[0].event {
        Event::RuleRemoved { rule: body } => {
            assert_eq!(body["id"], rule.id.as_str());
            assert_eq!(body["reason"], "user");
        }
        other => panic!("{other:?}"),
    }
    let frames = rig.frames();
    assert!(
        rules_frames(&frames).iter().any(|r| r.is_empty()),
        "the app is told: {frames:?}"
    );
    rig.assert_card("toolu_after", CACHES_B).await;
    // The daemon's own removal is not tampering.
    rig.broker.rules_external_check();
    assert!(rig.quarantine().is_none());
}

// Fails if the rules do not survive a restart of the daemon (the whole point of persisting), or
// if the reload loses a rule whose source operands no longer exist (the `rm` already ran).
#[tokio::test(start_paused = true)]
async fn a_rule_survives_a_restart_even_when_the_paths_it_was_made_from_are_gone() {
    let rig = Rig::with_app();
    let target = rig.l.home.join("Library/Caches/a");
    let other = rig.l.home.join("Elsewhere/x");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    let (_, exact) = rig
        .always(
            "toolu_1",
            ELSEWHERE,
            CandidateKind::Exact,
            RuleScopeChoice::AllRepos,
        )
        .await;
    let (_, prefix) = rig
        .always(
            "toolu_2",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::Repo,
        )
        .await;
    // The command the human allowed has now run.
    std::fs::remove_dir_all(&target).unwrap();
    std::fs::remove_dir_all(&other).unwrap();
    let root = rig.root.clone();
    drop(rig);

    let rig = Rig::over(root);
    rig.broker.presenter_connected("app");

    let listed = rig.rules();
    assert_eq!(listed.len(), 2);
    for r in &listed {
        assert!(r.active, "{r:?}");
        assert_eq!(r.inactive_reason, None);
    }
    assert!(listed.iter().any(|r| r.id == exact.id) && listed.iter().any(|r| r.id == prefix.id));
    assert!(rig.quarantine().is_none());
    rig.assert_allowed_by_your_rule("toolu_again", ELSEWHERE)
        .await;
    rig.assert_allowed_by_your_rule("toolu_other", CACHES_A)
        .await;
    rig.assert_allowed_by_your_rule("toolu_sibling", CACHES_B)
        .await;
    let loaded = rig.entries_of("rules_loaded");
    match &loaded.last().unwrap().event {
        Event::RulesLoaded {
            active,
            inactive,
            quarantined,
        } => {
            assert_eq!((*active, *inactive, *quarantined), (2, 0, false));
        }
        other => panic!("{other:?}"),
    }
}

// Fails if a rule persisted for one repository is applied after its working folder is not covered,
// or a hand-moved operand (a symlink where the directory was) still matches.
#[tokio::test(start_paused = true)]
async fn a_rule_whose_pinned_directory_became_a_symlink_does_not_allow_anything_after_a_restart() {
    let rig = Rig::with_app();
    let dir = rig.l.home.join("Library/Caches/pinned");
    std::fs::create_dir_all(&dir).unwrap();
    rig.always(
        "toolu_1",
        "rm -rf ~/Library/Caches/pinned",
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    std::fs::remove_dir_all(&dir).unwrap();
    std::os::unix::fs::symlink(rig.l.home.join("Elsewhere"), &dir).unwrap();
    let root = rig.root.clone();
    drop(rig);

    let rig = Rig::over(root);
    rig.broker.presenter_connected("app");

    let listed = rig.rules();
    assert_eq!(listed.len(), 1);
    assert!(!listed[0].active, "{:?}", listed[0]);
    assert!(listed[0].inactive_reason.is_some());
    rig.assert_card("toolu_after", "rm -rf ~/Library/Caches/pinned")
        .await;
}

// Fails if the rules apply without a presenter that could remove them, or reach a session that is not guarded.
#[tokio::test(start_paused = true)]
async fn a_rule_never_applies_without_the_app_or_to_a_session_that_is_not_guarded() {
    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::PathPrefix,
        RuleScopeChoice::AllRepos,
    )
    .await;
    rig.assert_allowed_by_your_rule("toolu_control", CACHES_B)
        .await;

    rig.broker.app_disconnected("app");
    rig.submit_value(
        T,
        rig.g1,
        "toolu_noapp",
        ask_request("toolu_noapp", CACHES_B),
    );
    let outcome = rig.wait_outcome("toolu_noapp").await;
    assert_eq!(outcome_name(&outcome), "no_app");
    assert_eq!(rig.writes_for("toolu_noapp")[0]["behavior"], "deny");

    rig.broker.presenter_connected("app");
    rig.submit_value(
        BARRIER,
        rig.barrier_generation,
        "toolu_unguarded",
        ask_request("toolu_unguarded", CACHES_B),
    );
    let outcome = rig.wait_outcome("toolu_unguarded").await;
    assert!(
        !outcome_name(&outcome).starts_with("allowed"),
        "an unguarded session is never allowed by a rule: {}",
        outcome_name(&outcome)
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Hand-edited rules: revalidation decides, the file never does
// ═════════════════════════════════════════════════════════════════════════════

// Fails if a rule text AP4 would not offer for its source command (a wider prefix, the whole
// command word, the whole tool) is ever active, at load or after Keep.
#[tokio::test(start_paused = true)]
async fn hand_edited_broader_rules_are_listed_inactive_and_never_match_even_after_keep() {
    for via_quarantine in [false, true] {
        let root = Arc::new(tempfile::tempdir().unwrap());
        let l = Layout::create(root.path());
        let legit = crafted(
            "legit",
            &l.home,
            CACHES_A,
            CandidateKind::PathPrefix,
            // Not all repositories: a kept file never revives one of those unconfirmed.
            Scope::Repo {
                root: l.proj.clone(),
            },
        );
        let mut all = vec![legit.clone()];
        all.extend(hand_edited_broad_rules(&legit, &l.home));
        seed(&l, vec![legit.clone()]);
        let rig;
        if via_quarantine {
            // The file is edited while the daemon runs: quarantined, then the human keeps it.
            rig = Rig::over(root);
            rig.broker.presenter_connected("app");
            write_private(&l.rules_json(), &file_body(&all));
            rig.broker.rules_external_check();
            let q = rig.quarantine().expect("an edited file is quarantined");
            assert!(rig.rules().is_empty());
            let in_file: Vec<(&str, bool)> = q
                .rules_in_file
                .iter()
                .map(|r| (r.id.as_str(), r.active))
                .collect();
            assert!(in_file.contains(&("legit", true)), "{in_file:?}");
            for evil in ["evil-1", "evil-2", "evil-3"] {
                assert!(
                    in_file.contains(&(evil, false)),
                    "the review shows {evil} would stay off: {in_file:?}"
                );
            }
            assert_eq!(
                rig.broker.keep_quarantined(&q.file_sha256, "app", "w"),
                RulesChange::Applied
            );
        } else {
            write_private(&l.rules_json(), &file_body(&all));
            write_private(
                &l.sidecar(),
                format!("{}\n", sha_hex(&file_body(&all))).as_bytes(),
            );
            rig = Rig::over(root);
            rig.broker.presenter_connected("app");
        }

        let listed = rig.rules();
        assert_eq!(listed.len(), 4, "via_quarantine={via_quarantine}");
        for r in &listed {
            if r.id == "legit" {
                assert!(r.active);
            } else {
                assert!(!r.active, "{} must be inactive: {r:?}", r.id);
                assert_eq!(r.inactive_reason.as_deref(), Some("no_longer_offered"));
            }
        }
        // What the broad rules would have allowed is still a card; the real rule still works.
        rig.assert_card("toolu_home", ELSEWHERE).await;
        rig.assert_card("toolu_flag", "rm -f ~/Library/Caches/b")
            .await;
        rig.assert_card("toolu_etc", "rm -rf /tmp/anything/at/all")
            .await;
        rig.assert_allowed_by_your_rule("toolu_legit", CACHES_B)
            .await;
        let named = outcome_rule(&rig.outcomes("toolu_legit")[0]);
        assert_eq!(named["rule_id"], "legit");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Tamper: a changed file is off until a human reviews it
// ═════════════════════════════════════════════════════════════════════════════

/// Rewrite the rules file without telling the daemon (and without touching its sidecar).
fn tamper_content(rig: &Rig) {
    let mut file = rig.file();
    file["rules"][0]["created_by_window"] = json!("edited-by-hand");
    std::fs::write(
        rig.l.rules_json(),
        serde_json::to_vec_pretty(&file).unwrap(),
    )
    .unwrap();
}

/// The common truth of a quarantined file: no rule matches, the app is told, a new rule is refused.
async fn assert_quarantined_and_inert(rig: &mut Rig, matching_command: &str, expect_frame: bool) {
    let q = rig.quarantine().expect("quarantined");
    assert!(rig.rules().is_empty(), "no persisted rule is active");
    assert!(!q.reason.is_empty());
    assert!(
        rig.entries_of("rules_quarantined").iter().any(|e| matches!(
            &e.event,
            Event::RulesQuarantined { reason, .. } if *reason == q.reason
        )),
        "a rules_quarantined entry names the reason"
    );
    if expect_frame {
        let frames = rig.frames();
        assert!(
            frames.iter().any(|m| matches!(
                m,
                ServerMsg::ApprovalRules {
                    quarantined: Some(_),
                    ..
                }
            )),
            "the app is told: {frames:?}"
        );
    }
    // The replay a presenter gets on connect says the same.
    assert!(rig.broker.rules_replay().iter().any(|m| matches!(
        m,
        ServerMsg::ApprovalRules {
            quarantined: Some(_),
            ..
        }
    )));
    rig.assert_card("toolu_q_card", matching_command).await;
    let wire = rig.hold("toolu_q_new", ELSEWHERE).await;
    let c = candidate(&wire, CandidateKind::Exact);
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &allow_always(&c, RuleScopeChoice::AllRepos),
            "w",
            "app"
        ),
        AnswerResult::RulesQuarantined
    );
    assert_eq!(
        rig.broker.remove_persisted_rule("legit", "app", "w"),
        RulesChange::Quarantined
    );
    rig.assert_still_held_then_deny(&wire);
}

// Fails if an edit of the file while the daemon runs leaves its rules matching.
#[tokio::test(start_paused = true)]
async fn an_external_edit_while_the_daemon_runs_turns_every_rule_off_and_tells_the_app() {
    let mut rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    rig.assert_allowed_by_your_rule("toolu_control", CACHES_A)
        .await;
    rig.frames();

    tamper_content(&rig);
    rig.broker.rules_external_check();

    assert_quarantined_and_inert(&mut rig, CACHES_A, true).await;
}

// Fails if the real watcher does not notice an edit (the daemon relies on it, not on a poll).
#[tokio::test(start_paused = true)]
async fn the_file_watcher_notices_an_external_edit_within_seconds() {
    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    let _watcher = rig
        .broker
        .start_rules_watcher()
        .expect("the watcher starts");
    // The daemon's own writes while watched never quarantine.
    rig.assert_allowed_by_your_rule("toolu_control", CACHES_A)
        .await;
    rig.always(
        "toolu_2",
        CACHES_B,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    rig.barrier().await;
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        rig.quarantine().is_none(),
        "the daemon's own writes are not tampering"
    );

    tamper_content(&rig);

    let start = Instant::now();
    while rig.quarantine().is_none() {
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "the watcher never quarantined the edited file"
        );
        std::thread::sleep(Duration::from_millis(20));
        tokio::task::yield_now().await;
    }
    // The log entry follows the quarantine by a moment (the rules are judged in between).
    while rig.entries_of("rules_quarantined").is_empty() {
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "no rules_quarantined entry"
        );
        std::thread::sleep(Duration::from_millis(20));
        tokio::task::yield_now().await;
    }
    rig.assert_card("toolu_after", CACHES_A).await;
}

// Fails if replacing the file with a symlink while running leaves rules matching, or if
// deleting the file leaves its rules in force.
#[tokio::test(start_paused = true)]
async fn replacing_the_file_with_a_symlink_or_deleting_it_turns_the_rules_off() {
    let mut rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    let copy = rig.root.path().join("elsewhere-copy.json");
    write_private(&copy, &rig.file_bytes().unwrap());
    std::fs::remove_file(rig.l.rules_json()).unwrap();
    std::os::unix::fs::symlink(&copy, rig.l.rules_json()).unwrap();
    rig.broker.rules_external_check();
    assert_quarantined_and_inert(&mut rig, CACHES_A, false).await;

    let rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    std::fs::remove_file(rig.l.rules_json()).unwrap();
    rig.broker.rules_external_check();
    rig.assert_card("toolu_after_delete", CACHES_A).await;
}

// Fails if any of these ways a file can be untrustworthy at start leaves the rules in force.
#[tokio::test(start_paused = true)]
async fn a_rules_file_that_fails_its_checks_at_start_is_quarantined_and_matches_nothing() {
    type Break = Box<dyn Fn(&Layout)>;
    let variants: Vec<(&str, Break)> = vec![
        (
            "sidecar holds another hash",
            Box::new(|l: &Layout| {
                write_private(
                    &l.sidecar(),
                    format!("{}\n", sha_hex(b"something else")).as_bytes(),
                )
            }),
        ),
        (
            "sidecar is missing",
            Box::new(|l: &Layout| std::fs::remove_file(l.sidecar()).unwrap()),
        ),
        (
            "sidecar is empty",
            Box::new(|l: &Layout| write_private(&l.sidecar(), b"")),
        ),
        (
            "the file is corrupt JSON (hash matches)",
            Box::new(|l: &Layout| {
                let bytes = b"{ this is not json";
                write_private(&l.rules_json(), bytes);
                write_private(&l.sidecar(), format!("{}\n", sha_hex(bytes)).as_bytes());
            }),
        ),
        (
            "the file is a symlink to a valid file",
            Box::new(|l: &Layout| {
                let real = l.approvals.join("real-copy.json");
                std::fs::rename(l.rules_json(), &real).unwrap();
                std::os::unix::fs::symlink(&real, l.rules_json()).unwrap();
            }),
        ),
        (
            "the file is group/world readable",
            Box::new(|l: &Layout| {
                std::fs::set_permissions(l.rules_json(), std::fs::Permissions::from_mode(0o644))
                    .unwrap()
            }),
        ),
        (
            "the file is larger than 1 MiB",
            Box::new(|l: &Layout| {
                let mut bytes = std::fs::read(l.rules_json()).unwrap();
                bytes.extend(std::iter::repeat_n(b' ', 1024 * 1024 + 1));
                write_private(&l.rules_json(), &bytes);
                write_private(&l.sidecar(), format!("{}\n", sha_hex(&bytes)).as_bytes());
            }),
        ),
        (
            "the file holds 201 rules (hash matches)",
            Box::new(|l: &Layout| {
                let rule = crafted(
                    "x",
                    &l.home,
                    CACHES_A,
                    CandidateKind::Exact,
                    Scope::AllRepos,
                );
                let rules: Vec<PersistedRule> = (0..=MAX_PERSISTED_RULES)
                    .map(|i| PersistedRule {
                        id: format!("r{i}"),
                        ..rule.clone()
                    })
                    .collect();
                let bytes = file_body(&rules);
                write_private(&l.rules_json(), &bytes);
                write_private(&l.sidecar(), format!("{}\n", sha_hex(&bytes)).as_bytes());
            }),
        ),
    ];
    for (what, break_it) in variants {
        let root = Arc::new(tempfile::tempdir().unwrap());
        let l = Layout::create(root.path());
        seed(
            &l,
            vec![crafted(
                "legit",
                &l.home,
                CACHES_A,
                CandidateKind::Exact,
                Scope::AllRepos,
            )],
        );
        break_it(&l);

        let mut rig = Rig::over(root);
        rig.broker.presenter_connected("app");

        eprintln!("variant: {what}");
        assert_quarantined_and_inert(&mut rig, CACHES_A, false).await;
        match &rig.entries_of("rules_loaded").last().unwrap().event {
            Event::RulesLoaded { quarantined, .. } => assert!(*quarantined, "{what}"),
            other => panic!("{other:?}"),
        }
    }
}

// Fails if Keep accepts a file other than the one the human reviewed, or leaves the file off
// after a good Keep, or if the Keep is not logged with the hash.
#[tokio::test(start_paused = true)]
async fn keep_needs_the_reviewed_hash_then_revalidates_logs_and_turns_the_rules_back_on() {
    let rig = Rig::with_app();
    let (_, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::Exact,
            RuleScopeChoice::Repo,
        )
        .await;
    tamper_content(&rig);
    rig.broker.rules_external_check();
    let reviewed = rig.quarantine().unwrap().file_sha256;
    assert_eq!(
        reviewed,
        sha_hex(&rig.file_bytes().unwrap()),
        "the hash is of the file as found"
    );

    // The file changes again after the human looked at it.
    let mut file = rig.file();
    file["rules"][0]["created_by_window"] = json!("changed-again");
    std::fs::write(
        rig.l.rules_json(),
        serde_json::to_vec_pretty(&file).unwrap(),
    )
    .unwrap();
    assert_eq!(
        rig.broker.keep_quarantined(&reviewed, "app", "w"),
        RulesChange::Stale
    );
    assert!(rig.quarantine().is_some(), "still quarantined");
    assert!(rig.entries_of("rules_kept").is_empty());
    rig.assert_card("toolu_stale", CACHES_A).await;
    // Neither a made-up hash, an empty one, nor a non-presenter.
    assert_eq!(
        rig.broker.keep_quarantined("deadbeef", "app", "w"),
        RulesChange::Stale
    );
    assert_eq!(
        rig.broker.keep_quarantined("", "app", "w"),
        RulesChange::Stale
    );
    assert_eq!(
        rig.broker
            .keep_quarantined(&reviewed, "not-a-presenter", "w"),
        RulesChange::NotPresenter
    );
    assert!(rig.quarantine().is_some());

    // Put back what was reviewed: now Keep is the human's choice, and applies.
    let mut file = rig.file();
    file["rules"][0]["created_by_window"] = json!("edited-by-hand");
    std::fs::write(
        rig.l.rules_json(),
        serde_json::to_vec_pretty(&file).unwrap(),
    )
    .unwrap();
    assert_eq!(sha_hex(&rig.file_bytes().unwrap()), reviewed);
    assert_eq!(
        rig.broker.keep_quarantined(&reviewed, "app", "w"),
        RulesChange::Applied
    );

    assert!(rig.quarantine().is_none());
    assert_eq!(rig.rules().len(), 1);
    assert!(rig.rules()[0].active);
    let kept = rig.entries_of("rules_kept");
    assert_eq!(kept.len(), 1);
    match &kept[0].event {
        Event::RulesKept { file_sha256 } => assert_eq!(*file_sha256, reviewed),
        other => panic!("{other:?}"),
    }
    assert_eq!(
        std::fs::read_to_string(rig.l.sidecar()).unwrap().trim(),
        sha_hex(&rig.file_bytes().unwrap()),
        "the kept file is bound again"
    );
    let outcome = rig
        .assert_allowed_by_your_rule("toolu_back", CACHES_A)
        .await;
    assert_eq!(outcome_rule(&outcome)["rule_id"], rule.id.as_str());
    // And a restart agrees: the kept file loads clean.
    let root = rig.root.clone();
    drop(rig);
    let rig = Rig::over(root);
    rig.broker.presenter_connected("app");
    assert!(rig.quarantine().is_none());
    assert_eq!(rig.rules().len(), 1);
    // Keep or Discard with nothing quarantined is a refusal that changes nothing.
    assert_eq!(
        rig.broker.keep_quarantined(&reviewed, "app", "w"),
        RulesChange::NotQuarantined
    );
}

// Fails if Discard keeps any rule, does not log, or leaves the file unusable for new rules.
#[tokio::test(start_paused = true)]
async fn discard_replaces_the_file_with_no_rules_logs_it_and_new_rules_work_again() {
    let mut rig = Rig::with_app();
    rig.always(
        "toolu_1",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    assert_eq!(
        rig.broker.discard_quarantined("app", "w"),
        RulesChange::NotQuarantined
    );
    assert_eq!(
        rig.file()["rules"].as_array().unwrap().len(),
        1,
        "nothing to discard"
    );
    tamper_content(&rig);
    rig.broker.rules_external_check();
    assert_eq!(
        rig.broker.discard_quarantined("not-a-presenter", "w"),
        RulesChange::NotPresenter
    );
    assert!(rig.quarantine().is_some());
    rig.frames();

    assert_eq!(
        rig.broker.discard_quarantined("app", "w-discard"),
        RulesChange::Applied
    );

    assert!(rig.quarantine().is_none());
    assert!(rig.rules().is_empty());
    assert!(rig.file()["rules"].as_array().unwrap().is_empty());
    assert_eq!(
        std::fs::read_to_string(rig.l.sidecar()).unwrap().trim(),
        sha_hex(&rig.file_bytes().unwrap())
    );
    assert_eq!(rig.entries_of("rules_discarded").len(), 1);
    let frames = rig.frames();
    assert!(
        frames
            .iter()
            .any(|m| matches!(m, ServerMsg::ApprovalRules { rules, quarantined: None, .. } if rules.is_empty())),
        "{frames:?}"
    );
    rig.assert_card("toolu_gone", CACHES_A).await;
    rig.always(
        "toolu_new",
        CACHES_A,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    rig.assert_allowed_by_your_rule("toolu_new_use", CACHES_A)
        .await;
    rig.broker.rules_external_check();
    assert!(rig.quarantine().is_none());
}

// ═════════════════════════════════════════════════════════════════════════════
// AP6-2: Claude's own settings are never touched
// ═════════════════════════════════════════════════════════════════════════════

fn snapshot_dir(dir: &Path) -> BTreeMap<PathBuf, String> {
    fn walk(dir: &Path, out: &mut BTreeMap<PathBuf, String>) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else {
                out.insert(p.clone(), sha_hex(&std::fs::read(&p).unwrap_or_default()));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, &mut out);
    out
}

#[tokio::test(start_paused = true)]
async fn creating_matching_and_removing_rules_leaves_every_claude_settings_file_byte_identical() {
    let rig = Rig::with_app();
    let files = [
        rig.l.home.join(".claude/settings.json"),
        rig.l.proj.join(".claude/settings.json"),
        rig.l.proj.join(".claude/settings.local.json"),
    ];
    for (i, f) in files.iter().enumerate() {
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(
            f,
            format!(r#"{{"permissions":{{"allow":["Bash(ls:*)"],"ask":["Bash(rm:*)"]}},"n":{i}}}"#),
        )
        .unwrap();
    }
    let claude_dirs = [rig.l.home.join(".claude"), rig.l.proj.join(".claude")];
    let before: Vec<_> = claude_dirs.iter().map(|d| snapshot_dir(d)).collect();
    assert_eq!(before.iter().map(BTreeMap::len).sum::<usize>(), 3);

    let (_, rule) = rig
        .always(
            "toolu_1",
            CACHES_A,
            CandidateKind::PathPrefix,
            RuleScopeChoice::Repo,
        )
        .await;
    rig.always(
        "toolu_1b",
        ELSEWHERE,
        CandidateKind::Exact,
        RuleScopeChoice::AllRepos,
    )
    .await;
    rig.assert_allowed_by_your_rule("toolu_2", CACHES_B).await;
    rig.assert_allowed_by_your_rule_on(T2, rig.g2, "toolu_3", CACHES_B)
        .await;
    assert_eq!(
        rig.broker.remove_persisted_rule(&rule.id, "app", "w"),
        RulesChange::Applied
    );
    rig.assert_card("toolu_4", CACHES_B).await;
    tamper_content(&rig);
    rig.broker.rules_external_check();
    assert_eq!(
        rig.broker.discard_quarantined("app", "w"),
        RulesChange::Applied
    );

    let after: Vec<_> = claude_dirs.iter().map(|d| snapshot_dir(d)).collect();
    assert_eq!(
        before, after,
        "no Claude settings file was changed, and none was added"
    );
}

// The store never so much as names a Claude settings path.
#[test]
fn the_persisted_rules_module_never_mentions_a_claude_settings_location() {
    let src = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src/approvals/persisted.rs"),
    )
    .unwrap();
    assert!(
        !src.contains(".claude"),
        "src/approvals/persisted.rs must not contain the substring `.claude` (code or comments)"
    );
}
