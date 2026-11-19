//! `perri.record_verdict` under the daemon-hosted MCP server, from outside: a
//! real Unix socket, the real tool dispatch, and the verdict store the Merge
//! verb reads.
//!
//! * A good record is acknowledged and says whether the head is the one the
//!   daemon knows the PR to be at (`true`, `false`, or `"unknown"`).
//! * Anything off (repo, PR number, head, verdict, note, an unknown argument, no
//!   caller) is refused and nothing is recorded.
//! * It only records: no request ever goes to GitHub.
//! * A session a network peer is steering is not offered the tool, is refused
//!   when it calls it anyway, and nothing is recorded.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{TimeZone, Utc};
use nostromo::data::authored_prs::github::Api;
use nostromo::data::authored_prs::snapshot::*;
use nostromo::data::authored_prs::verdicts::{Verdict, VerdictStore};
use nostromo::data::authored_prs::{AuthoredPrActions, AuthoredPrsSource, Deps, TokioClock};
use nostromo::data::relay_client::RelayStatus;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, watch};
use wiremock::MockServer;

const TOOL: &str = "perri.record_verdict";
const REPO: &str = "canary-org/canary-repo";
const N: u64 = 424242;
const TAG: &str = "cody-ok";
const NET_TAG: &str = "cody-net";

fn sha(c: char) -> String {
    c.to_string().repeat(40)
}

// ── the PR list the daemon knows ──────────────────────────────────────────────

fn t0() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 14, 12, 0, 0).unwrap()
}

/// The PR `REPO#N` at head `aaaa…`, as the engine would list it.
fn pr() -> AuthoredPr {
    AuthoredPr {
        repo: REPO.into(),
        number: N,
        url: format!("https://github.com/{REPO}/pull/{N}"),
        title: "A change".into(),
        draft: false,
        updated_at: t0(),
        group: Group::Ready,
        lifecycle: Lifecycle::Open,
        ended_at: None,
        base_ref: None,
        details_unavailable: false,
        checks: Checks {
            state: ChecksState::Passing,
            passed: 1,
            failed: 0,
            pending: 0,
            failing_names: vec![],
        },
        review: Review {
            state: ReviewState::Approved,
            logins: vec!["alice".into()],
        },
        new_comments: 0,
        unresolved_threads: 0,
        threads_truncated: false,
        owner: Owner::unknown(),
        told: None,
        pill: false,
        head_sha_short: Some("aaaaaaaa".into()),
        perri: None,
        attention_key: String::new(),
    }
}

fn snapshot(prs: Vec<AuthoredPr>) -> AuthoredPrsSnapshot {
    let usage = UsageCounts::default();
    AuthoredPrsSnapshot {
        generated_at: t0(),
        token: TokenState::Connected,
        relay: RelayInfo {
            state: RelayState::NotConfigured,
            since: None,
            org: "Carefeed".into(),
        },
        poll: PollInfo {
            state: PollState::Ok,
            checked_at: None,
            interval_secs: 60,
            resumes_at: None,
            retry_at: None,
        },
        refresh_blocked: None,
        hidden_orgs: vec![],
        total_open: prs.len() as u32,
        shown: prs.len() as u32,
        prs,
        usage: UsageView {
            window_secs: 3600,
            window: usage,
            since_start: usage,
        },
    }
}

// ── the harness ───────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    dir: TempDir,
    verdicts: Arc<VerdictStore>,
    /// A GitHub that is never mounted on: the daemon's client points at it, so
    /// any request the tool made would be seen here.
    github: MockServer,
    _feed: watch::Sender<Option<AuthoredPrsSnapshot>>,
    _engine: tokio::task::JoinHandle<()>,
    _jobs: watch::Sender<Vec<nostromo::mother::MotherJob>>,
}

async fn harness(actions_wired: bool) -> Harness {
    let dir = TempDir::new().unwrap();
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let github = MockServer::start().await;
    let verdicts = Arc::new(VerdictStore::in_memory());
    // An engine with no token: it never asks GitHub anything. The list the
    // verbs see is fed by hand.
    let (jobs_tx, jobs_rx) = watch::channel(Vec::new());
    let engine = AuthoredPrsSource::spawn(Deps {
        state_root: None,
        api_base: github.uri(),
        github: None,
        token_resolver: None,
        relay_status: Arc::new(RelayStatus::new()),
        relay_configured: false,
        relay_rx: None,
        jobs_rx,
        focuses: Arc::new(Vec::new),
        projects_root: dir.path().join("projects"),
        clock: Arc::new(TokioClock::new(Utc::now())),
    });
    let (feed, rx) = watch::channel(Some(snapshot(vec![pr()])));
    if actions_wired {
        let api = Api::new(reqwest::Client::new(), "ghp_unused".into(), github.uri());
        let actions = AuthoredPrActions::from_parts(
            Arc::clone(&engine.demand),
            rx,
            Arc::clone(&engine.store),
            Arc::clone(&engine.memory),
            dir.path().join("projects"),
            dir.path().join("agents"),
            Arc::new(TokioClock::new(Utc::now())),
        )
        .with_merge(Arc::clone(&verdicts), Arc::new(Mutex::new(Some(api))));
        session_mgr
            .lock()
            .unwrap()
            .configure_authored_pr_actions(Arc::new(actions));
    }
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);
    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx,
        perri: PerriDaemonState {
            state_dir: Some(dir.path().join("perri-state")),
            pr_refresh_tx: None,
            queue_refresh_tx: None,
            selected_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            settle_timeout: Duration::from_millis(100),
        },
        decisions: Arc::new(Mutex::new(
            nostromo::ipc::decisions::DecisionRegistry::default(),
        )),
        tickets: Default::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    };
    let state = McpSharedState::for_daemon(backend);
    // A session a network peer has been steering.
    session_mgr
        .lock()
        .unwrap()
        .sensitive_tags()
        .mark_network_driven(NET_TAG);
    Harness {
        state,
        dir,
        verdicts,
        github,
        _feed: feed,
        _engine: engine.task,
        _jobs: jobs_tx,
    }
}

type Reader = BufReader<tokio::net::unix::OwnedReadHalf>;
type Writer = tokio::net::unix::OwnedWriteHalf;

async fn write_line(w: &mut Writer, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

async fn read_line(r: &mut Reader) -> Value {
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(10), r.read_line(&mut line))
        .await
        .expect("timed out waiting for the server")
        .unwrap();
    serde_json::from_str(line.trim()).expect("a JSON response")
}

struct Session {
    reader: Reader,
    writer: Writer,
    next_id: i64,
    _server: McpServer,
}

/// Connect as `tag` (no tag: no identified caller), initialised.
async fn connect(h: &Harness, tag: Option<&str>) -> Session {
    let socket = h
        .dir
        .path()
        .join(format!("mcp-{}.sock", tag.unwrap_or("anon")));
    let server = McpServer::bind(socket.clone(), h.state.clone())
        .await
        .expect("bind");
    let stream = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let hello = match tag {
        Some(t) => json!({"type": "hello", "pty_id": t}),
        None => json!({"type": "hello"}),
    };
    write_line(&mut writer, &hello).await;
    write_line(
        &mut writer,
        &json!({"jsonrpc":"2.0","id":1,"method":"initialize",
                "params":{"protocolVersion":"2024-11-05","capabilities":{},
                          "clientInfo":{"name":"t","version":"0"}}}),
    )
    .await;
    let _ = read_line(&mut reader).await;
    Session {
        reader,
        writer,
        next_id: 2,
        _server: server,
    }
}

impl Session {
    async fn rpc(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        write_line(
            &mut self.writer,
            &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
        )
        .await;
        read_line(&mut self.reader).await
    }

    /// The raw JSON-RPC response of a `tools/call`.
    async fn call_raw(&mut self, args: Value) -> Value {
        self.rpc("tools/call", json!({"name": TOOL, "arguments": args}))
            .await
    }

    /// The tool's own JSON answer; panics on a protocol-level refusal.
    async fn call(&mut self, args: Value) -> Value {
        let resp = self.call_raw(args).await;
        assert!(resp.get("error").is_none(), "refused outright: {resp}");
        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("no content: {resp}"));
        serde_json::from_str(text).expect("tool content is JSON")
    }

    async fn tool_names(&mut self) -> Vec<String> {
        let resp = self.rpc("tools/list", json!({})).await;
        resp["result"]["tools"]
            .as_array()
            .expect("a tool list")
            .iter()
            .filter_map(|t| t["name"].as_str().map(str::to_owned))
            .collect()
    }
}

fn good(head: &str, verdict: &str) -> Value {
    json!({"repo": REPO, "pr": N, "head_sha": head, "verdict": verdict})
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_good_record_is_acknowledged_and_says_whether_the_head_is_the_current_one() {
    let h = harness(true).await;
    let mut s = connect(&h, Some(TAG)).await;

    // The head the daemon knows the PR to be at.
    let r = s.call(good(&sha('a'), "approved")).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["matches_current_head"], true, "{r}");
    assert_eq!(r["recorded"]["repo"], REPO);
    assert_eq!(r["recorded"]["pr"], N);
    assert_eq!(r["recorded"]["head_sha"], sha('a').as_str());
    assert_eq!(r["recorded"]["verdict"], "approved");

    // Another head of the same PR.
    let r = s.call(good(&sha('b'), "changes_requested")).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["matches_current_head"], false, "{r}");

    // A PR the daemon does not have in its list.
    let r = s
        .call(
            json!({"repo": "other-org/other-repo", "pr": 7, "head_sha": sha('a'),
                     "verdict": "comment", "note": "x".repeat(200)}),
        )
        .await;
    assert_eq!(r["ok"], true, "a 200 character note is allowed: {r}");
    assert_eq!(r["matches_current_head"], "unknown", "{r}");

    // The repo is acknowledged in lower case, as it is kept.
    let r = s
        .call(
            json!({"repo": REPO.to_uppercase(), "pr": N, "head_sha": sha('a'),
                     "verdict": "comment", "note": null}),
        )
        .await;
    assert_eq!(r["recorded"]["repo"], REPO, "{r}");
    assert_eq!(r["matches_current_head"], true, "{r}");

    // What the Merge verb will read.
    let rec = h.verdicts.for_head(REPO, N, &sha('b')).expect("recorded");
    assert_eq!(rec.verdict, Verdict::ChangesRequested);
    assert!(
        rec.by.as_deref().is_some_and(|b| b.contains(TAG)),
        "the record says which focus made it: {:?}",
        rec.by
    );
    assert_eq!(
        h.verdicts.for_head(REPO, N, &sha('a')).unwrap().verdict,
        Verdict::Comment,
        "the newest verdict for a head wins"
    );
}

#[tokio::test]
async fn anything_that_is_not_a_valid_record_is_refused_and_nothing_is_recorded() {
    let h = harness(true).await;
    let mut s = connect(&h, Some(TAG)).await;

    let with = |key: &str, value: Value| {
        let mut args = good(&sha('a'), "approved");
        args[key] = value;
        args
    };
    let without = |key: &str| {
        let mut args = good(&sha('a'), "approved");
        args.as_object_mut().unwrap().remove(key);
        args
    };
    let cases: Vec<(&str, Value)> = vec![
        ("a repo without a slash", with("repo", json!("canary-repo"))),
        ("an empty repo", with("repo", json!(""))),
        ("a repo with a path", with("repo", json!("a/b/c"))),
        ("a repo that is a number", with("repo", json!(5))),
        ("no repo", without("repo")),
        ("pr zero", with("pr", json!(0))),
        ("pr negative", with("pr", json!(-1))),
        ("pr as a string", with("pr", json!("424242"))),
        ("pr as a float", with("pr", json!(4.5))),
        ("pr as a whole float", with("pr", json!(1.0e3))),
        ("pr null", with("pr", Value::Null)),
        ("no pr", without("pr")),
        ("a short head", with("head_sha", json!("aaaaaaaa"))),
        ("a 39 digit head", with("head_sha", json!("a".repeat(39)))),
        ("a 41 digit head", with("head_sha", json!("a".repeat(41)))),
        ("an uppercase head", with("head_sha", json!("A".repeat(40)))),
        (
            "a head that is not hex",
            with("head_sha", json!("g".repeat(40))),
        ),
        (
            "a head with a space",
            with("head_sha", json!(format!(" {}", "a".repeat(39)))),
        ),
        ("a head that is a number", with("head_sha", json!(5))),
        ("no head", without("head_sha")),
        ("a verdict nobody knows", with("verdict", json!("merge"))),
        ("a verdict in capitals", with("verdict", json!("APPROVED"))),
        (
            "a verdict that is almost one",
            with("verdict", json!("approve")),
        ),
        ("an empty verdict", with("verdict", json!(""))),
        ("a verdict that is a number", with("verdict", json!(1))),
        ("no verdict", without("verdict")),
        (
            "a note of 201 characters",
            with("note", json!("n".repeat(201))),
        ),
        ("a note that is a number", with("note", json!(5))),
        ("a note that is a list", with("note", json!(["a"]))),
        ("an extra argument `merge`", with("merge", json!(true))),
        (
            "an extra argument `repo_path`",
            with("repo_path", json!("/tmp")),
        ),
        ("an extra argument `force`", with("force", json!(true))),
        ("an extra argument `by`", with("by", json!("someone-else"))),
        (
            "an extra argument `at`",
            with("at", json!("2020-01-01T00:00:00Z")),
        ),
    ];
    for (what, args) in cases {
        let r = s.call(args).await;
        assert_eq!(r["error"], "invalid_args", "{what}: {r}");
        assert!(r.get("ok").is_none(), "{what}: {r}");
        assert!(h.verdicts.is_empty(), "{what}: something was recorded");
    }

    // No arguments at all, and arguments that are not an object.
    for (what, params) in [
        ("no arguments", json!({"name": TOOL})),
        ("a list", json!({"name": TOOL, "arguments": []})),
        ("a string", json!({"name": TOOL, "arguments": "approved"})),
    ] {
        let resp = s.rpc("tools/call", params).await;
        let text = resp["result"]["content"][0]["text"].as_str().unwrap_or("");
        let r: Value = serde_json::from_str(text).unwrap_or(Value::Null);
        assert_eq!(r["error"], "invalid_args", "{what}: {resp}");
    }
    assert!(h.verdicts.is_empty());

    // The control: a 200 character note and a 40-hex head are fine.
    let mut args = good(&sha('a'), "approved");
    args["note"] = json!("n".repeat(200));
    assert_eq!(s.call(args).await["ok"], true);
    assert_eq!(h.verdicts.len(), 1);
}

#[tokio::test]
async fn a_caller_the_daemon_cannot_identify_records_nothing() {
    let h = harness(true).await;
    let mut anon = connect(&h, None).await;
    let r = anon.call(good(&sha('a'), "approved")).await;
    assert_eq!(r["error"], "unidentified_caller", "{r}");
    assert!(h.verdicts.is_empty());
}

#[tokio::test]
async fn without_the_authored_pr_list_the_tool_says_it_is_not_supported_and_records_nothing() {
    let h = harness(false).await;
    let mut s = connect(&h, Some(TAG)).await;
    let r = s.call(good(&sha('a'), "approved")).await;
    assert_eq!(r["error"], "not_supported", "{r}");
    assert!(h.verdicts.is_empty());
}

#[tokio::test]
async fn recording_never_sends_a_request_to_github() {
    let h = harness(true).await;
    let mut s = connect(&h, Some(TAG)).await;
    for (head, verdict) in [
        (sha('a'), "approved"),
        (sha('b'), "changes_requested"),
        (sha('a'), "comment"),
    ] {
        assert_eq!(s.call(good(&head, verdict)).await["ok"], true);
    }
    // A refused one, too.
    let r = s.call(good("nope", "approved")).await;
    assert_eq!(r["error"], "invalid_args");
    tokio::time::sleep(Duration::from_millis(200)).await;
    let seen = h.github.received_requests().await.expect("recording is on");
    assert!(seen.is_empty(), "the tool talked to GitHub: {seen:?}");
}

#[tokio::test]
async fn a_session_a_network_peer_is_steering_is_not_offered_the_tool_and_cannot_call_it() {
    let h = harness(true).await;

    // An ordinary session is offered it and can use it.
    let mut ordinary = connect(&h, Some(TAG)).await;
    assert!(
        ordinary.tool_names().await.iter().any(|n| n == TOOL),
        "control: the tool is offered"
    );

    let mut steered = connect(&h, Some(NET_TAG)).await;
    let names = steered.tool_names().await;
    assert!(!names.iter().any(|n| n == TOOL), "{names:?}");
    // The rest of the Perri tools are still there: only this one is withheld.
    assert!(
        names.iter().any(|n| n == "perri.get_selected_index"),
        "{names:?}"
    );

    // Calling it by name anyway is refused, with the code a withdrawn tool gets.
    let resp = steered.call_raw(good(&sha('a'), "approved")).await;
    assert_eq!(resp["error"]["code"], -32001, "{resp}");
    assert!(resp.get("result").is_none(), "{resp}");
    assert!(
        h.verdicts.is_empty(),
        "a network-driven call recorded something"
    );

    // Control: the ordinary session's record is kept.
    assert_eq!(ordinary.call(good(&sha('a'), "approved")).await["ok"], true);
    assert_eq!(h.verdicts.len(), 1);
}
