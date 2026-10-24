//! Token benchmark for `nostromo.tracker` (PRD criterion 30, contract §8).
//!
//! Drives the real `dispatch("nostromo.tracker", ...)` over the 60-item board
//! fixture (`tests/fixtures/tracker/board-60.md`): 30 status updates, 5 external
//! file edits (through the file system and `ingest_file_change`, as the watcher
//! does) and 6 reads. Every request (tool name + arguments, compact JSON) and
//! every response text is measured with the hermetic proxy
//! `est_tokens(s) = ceil(utf8_len(s) / 2.5)`.
//!
//! The baseline is the same 30 updates done the only way an agent can without
//! the tracker: a full-board `nostromo.set_pane_content` request (the whole
//! file as the text) plus its response.
//!
//! The measured numbers are printed (`cargo test --test tracker_token_bench --
//! --nocapture`). The ignored `dump` test writes every request and response to
//! `target/tracker-bench/*.json` for the user-run calibration script
//! (`scripts/tracker/token_bench.py`):
//!
//!   cargo test --test tracker_token_bench -- --ignored dump
//!
//! Each file is `{"label": ..., "kind": "request" | "response", "text": ...}`.
//! Labels start with `tracker/` (the tracker session), `baseline/` (the
//! full-board `set_pane_content` calls) or `descriptor/` (the tool's listing).
//!
//! Hermetic: a `FakeClock`, temp dirs for the repo, state root and home, no git.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::{dispatch, tool_descriptors, ToolResult};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use nostromo::tracker::{
    parse, CallerFacts, FakeClock, Kind, RegistryParts, Status, TrackerRegistry,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const TAG: &str = "cody-bench";
const SESSION: &str = "sess-bench";
const TOPIC: &str = "bench";

/// Contract §8 hermetic token proxy.
fn est_tokens(s: &str) -> usize {
    (s.len() as f64 / 2.5).ceil() as usize
}

fn board60() -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tracker/board-60.md"),
    )
    .expect("board-60.md")
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

struct Fx {
    _tmp: TempDir,
    repo: PathBuf,
    registry: Arc<TrackerRegistry>,
    state: McpSharedState,
    tx: broadcast::Sender<ServerMsg>,
    _rx: broadcast::Receiver<ServerMsg>,
    _session_mgr: Arc<Mutex<SessionManager>>,
}

impl Fx {
    /// A daemon-hosted MCP state with the 60-item board in place (not yet opened).
    fn new() -> Fx {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let registry = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            base.join("state"),
            home,
            Arc::new(FakeClock::at_secs(1_760_545_000)),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            base.join("sessions.json"),
        )));
        let (tx, rx) = broadcast::channel::<ServerMsg>(4096);
        let state = McpSharedState::for_daemon(DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
            session_mgr: Arc::clone(&session_mgr),
            broadcast_tx: tx.clone(),
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(
                nostromo::ipc::decisions::DecisionRegistry::default(),
            )),
            tickets: Default::default(),
            tracker: Arc::clone(&registry),
        });
        let fx = Fx {
            _tmp: tmp,
            repo,
            registry,
            state,
            tx,
            _rx: rx,
            _session_mgr: session_mgr,
        };
        fx.seat(SESSION);
        let path = fx.board_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, board60()).unwrap();
        fx
    }

    fn seat(&self, session: &str) {
        self.registry.set_caller_facts(
            TAG,
            CallerFacts {
                cwd: Some(self.repo.clone()),
                session_id: Some(session.to_string()),
            },
        );
    }

    fn board_path(&self) -> PathBuf {
        self.repo.join(".claude/wip").join(TOPIC).join("index.md")
    }

    fn file(&self) -> String {
        String::from_utf8(std::fs::read(self.board_path()).unwrap()).unwrap()
    }

    /// An editor flips the checkbox of item `id`; the watcher fires.
    fn external_toggle(&self, id: &str) {
        let needle = format!("#{id} ");
        let mut found = false;
        let edited: Vec<String> = self
            .file()
            .split('\n')
            .map(|line| {
                if line.contains(&needle) {
                    found = true;
                    if line.starts_with("- [ ] ") {
                        line.replacen("- [ ] ", "- [x] ", 1)
                    } else {
                        line.replacen("- [x] ", "- [ ] ", 1)
                            .replacen("- [X] ", "- [ ] ", 1)
                    }
                } else {
                    line.to_string()
                }
            })
            .collect();
        assert!(found, "no item line for {id}");
        std::fs::write(self.board_path(), edited.join("\n")).unwrap();
        assert!(self.registry.ingest_file_change(&self.board_path()));
        self.registry.flush(&self.tx);
    }
}

/// One measured exchange.
#[derive(Debug, Clone)]
struct Record {
    label: String,
    kind: &'static str,
    text: String,
}

#[derive(Default)]
struct Log {
    records: Vec<Record>,
}

impl Log {
    fn push(&mut self, label: &str, kind: &'static str, text: &str) {
        self.records.push(Record {
            label: label.to_string(),
            kind,
            text: text.to_string(),
        });
    }
}

/// Calls the tool, logs the request and response, and returns
/// `(parsed response, request tokens, response tokens)`.
async fn call(fx: &Fx, log: &mut Log, label: &str, args: Value) -> (Value, usize, usize) {
    let request = json!({"name": "nostromo.tracker", "arguments": args}).to_string();
    let response = match dispatch("nostromo.tracker", Some(&args), &fx.state, Some(TAG)).await {
        ToolResult::Ok(content) => content[0]["text"].as_str().expect("text").to_string(),
        _ => panic!("the tracker tool is not available"),
    };
    log.push(label, "request", &request);
    log.push(label, "response", &response);
    let parsed: Value = serde_json::from_str(&response).expect("JSON response");
    (parsed, est_tokens(&request), est_tokens(&response))
}

fn descriptor_json() -> String {
    let all = tool_descriptors();
    let d = all
        .iter()
        .find(|d| d["name"] == json!("nostromo.tracker"))
        .expect("the tracker descriptor");
    serde_json::to_string(d).unwrap()
}

// ---------------------------------------------------------------------------
// The benchmark
// ---------------------------------------------------------------------------

struct Bench {
    log: Log,
    /// Whole tracker session: every request and response.
    session_tokens: usize,
    baseline_tokens: usize,
    file_tokens: usize,
    open_response_tokens: usize,
    first_read_response_tokens: usize,
    max_status_request: usize,
    max_status_response: usize,
    /// Response tokens of each of the six reads, with the number of changes it carried.
    reads: Vec<(usize, usize)>,
    descriptor_tokens: usize,
    descriptor_bytes: usize,
}

/// Item ids of the board that are plain items (a command item can't be set
/// done by an agent), with their current status, in file order.
fn plain_items() -> Vec<(String, Status)> {
    let parsed = parse(&board60()).expect("board-60 parses");
    parsed
        .board
        .items
        .iter()
        .filter(|i| i.kind != Kind::Command)
        .map(|i| (i.id.clone(), i.status))
        .collect()
}

/// The first status of `in-progress`, `blocked`, `needs-you`, `done` that
/// differs from `current`, so every update really changes the board.
fn different_status(current: Status) -> &'static str {
    ["in-progress", "blocked", "needs-you", "done"]
        .into_iter()
        .find(|s| Status::from_wire(s) != Some(current))
        .unwrap()
}

async fn run_benchmark() -> Bench {
    let plain = plain_items();
    assert!(
        plain.len() >= 35,
        "the fixture has {} plain items",
        plain.len()
    );
    let updates: Vec<&(String, Status)> = plain[..30].iter().collect();
    let edits: Vec<&(String, Status)> = plain[30..35].iter().collect();

    let fx = Fx::new();
    let mut log = Log::default();
    let file_tokens = est_tokens(&fx.file());
    let mut session_tokens = 0;
    let mut baseline_tokens = 0;
    let mut tally = |req: usize, resp: usize| session_tokens += req + resp;

    // open: the session's first call, which carries the compact board.
    let (open, req, resp) = call(
        &fx,
        &mut log,
        "tracker/open",
        json!({"op": "open", "topic": TOPIC}),
    )
    .await;
    assert_eq!(open["ok"], json!(true), "{open}");
    assert!(
        open["board"].is_string(),
        "the first open carries the board: {open}"
    );
    let open_response_tokens = resp;
    tally(req, resp);

    let mut reads: Vec<(usize, usize)> = Vec::new();
    let mut max_status_request = 0;
    let mut max_status_response = 0;
    let mut next_update = 0;
    let mut next_edit = 0;

    // The timeline: reads (R) after batches of updates (U) and external edits (E).
    // Totals: 30 U, 5 E, 6 R.
    #[derive(Clone, Copy)]
    enum Ev {
        U(usize),
        E(usize),
        R(usize),
    }
    let timeline = [
        Ev::R(0),
        Ev::U(5),
        Ev::E(1),
        Ev::R(1),
        Ev::U(5),
        Ev::E(3),
        Ev::R(3),
        Ev::U(5),
        Ev::E(1),
        Ev::R(1),
        Ev::U(5),
        Ev::R(0),
        Ev::U(10),
        Ev::R(0),
    ];
    for ev in timeline {
        match ev {
            Ev::U(n) => {
                for _ in 0..n {
                    let (id, current) = updates[next_update];
                    let new_status = different_status(*current);
                    let label = format!("tracker/status-{next_update:02}");
                    let (res, req, resp) = call(
                        &fx,
                        &mut log,
                        &label,
                        json!({"op": "status", "id": id, "status": new_status}),
                    )
                    .await;
                    assert_eq!(res["ok"], json!(true), "{label}: {res}");
                    max_status_request = max_status_request.max(req);
                    max_status_response = max_status_response.max(resp);
                    tally(req, resp);

                    // The baseline: the whole board as the text of set_pane_content.
                    let board_now = fx.file();
                    let base_args = json!({
                        "view_id": TAG,
                        "pane_id": "tracker",
                        "content": {"type": "text", "text": board_now},
                    });
                    let base_req =
                        json!({"name": "nostromo.set_pane_content", "arguments": base_args})
                            .to_string();
                    let base_resp = json!({"ok": true}).to_string();
                    let base_label = format!("baseline/set_pane_content-{next_update:02}");
                    log.push(&base_label, "request", &base_req);
                    log.push(&base_label, "response", &base_resp);
                    baseline_tokens += est_tokens(&base_req) + est_tokens(&base_resp);
                    next_update += 1;
                }
            }
            Ev::E(k) => {
                for _ in 0..k {
                    fx.external_toggle(&edits[next_edit].0);
                    next_edit += 1;
                }
            }
            Ev::R(k) => {
                let label = format!("tracker/read-{}", reads.len());
                let (res, req, resp) = call(&fx, &mut log, &label, json!({"op": "read"})).await;
                let changes = res["changes"]
                    .as_array()
                    .unwrap_or_else(|| panic!("{label}: a delta was expected: {res}"));
                assert_eq!(changes.len(), k, "{label}: {res}");
                reads.push((k, resp));
                tally(req, resp);
            }
        }
    }
    assert_eq!((next_update, next_edit, reads.len()), (30, 5, 6));

    // A fresh Claude session on the same focus reads the whole board once.
    fx.seat("sess-bench-fresh");
    let (first, _req, first_read_response_tokens) =
        call(&fx, &mut log, "tracker/first-read", json!({"op": "read"})).await;
    assert!(first["board"].is_string(), "{first}");

    let descriptor = descriptor_json();
    log.push("descriptor/nostromo.tracker", "request", &descriptor);

    Bench {
        log,
        session_tokens,
        baseline_tokens,
        file_tokens,
        open_response_tokens,
        first_read_response_tokens,
        max_status_request,
        max_status_response,
        reads,
        descriptor_tokens: est_tokens(&descriptor),
        descriptor_bytes: descriptor.len(),
    }
}

/// Response tokens of a read that carries `k` external changes (fresh board).
async fn read_with_k_changes(k: usize) -> usize {
    let plain = plain_items();
    let fx = Fx::new();
    let mut log = Log::default();
    let (open, _, _) = call(&fx, &mut log, "open", json!({"op": "open", "topic": TOPIC})).await;
    assert_eq!(open["ok"], json!(true), "{open}");
    for (id, _) in plain[30..30 + k].iter() {
        fx.external_toggle(id);
    }
    let (res, _, resp) = call(&fx, &mut log, "read", json!({"op": "read"})).await;
    assert_eq!(res["changes"].as_array().map(Vec::len), Some(k), "{res}");
    resp
}

#[tokio::test]
async fn the_tracker_meets_the_token_targets_on_the_sixty_item_benchmark() {
    let bench = run_benchmark().await;

    let ratio = bench.session_tokens as f64 / bench.baseline_tokens as f64;
    println!("== tracker token benchmark (est_tokens = ceil(bytes / 2.5)) ==");
    println!(
        "file (board-60.md)                 : {} tokens",
        bench.file_tokens
    );
    println!(
        "open response (with board)         : {} tokens",
        bench.open_response_tokens
    );
    println!(
        "first read of a fresh session      : {} tokens",
        bench.first_read_response_tokens
    );
    println!(
        "status request, max of 30          : {} tokens (limit 80)",
        bench.max_status_request
    );
    println!(
        "status response, max of 30         : {} tokens (limit 50)",
        bench.max_status_response
    );
    for (i, (k, tokens)) in bench.reads.iter().enumerate() {
        println!(
            "read {i} with {k} change(s)           : {tokens} tokens (limit {})",
            40 + 70 * k
        );
    }
    for k in [1, 3, 5] {
        println!(
            "read with {k} change(s), fresh board  : {} tokens (limit {})",
            read_with_k_changes(k).await,
            40 + 70 * k
        );
    }
    println!(
        "tracker session total              : {} tokens",
        bench.session_tokens
    );
    println!(
        "full-board baseline total          : {} tokens",
        bench.baseline_tokens
    );
    println!(
        "tracker / baseline                 : {:.1}% (limit 15%)",
        ratio * 100.0
    );
    println!(
        "descriptor                         : {} tokens, {} bytes (limits 1500, 3600)",
        bench.descriptor_tokens, bench.descriptor_bytes
    );

    assert!(
        bench.max_status_request <= 80,
        "status request: {} tokens",
        bench.max_status_request
    );
    assert!(
        bench.max_status_response <= 50,
        "status response: {} tokens",
        bench.max_status_response
    );
    for (i, (k, tokens)) in bench.reads.iter().enumerate() {
        if *k == 0 {
            assert!(*tokens <= 40, "empty read {i}: {tokens} tokens");
        } else {
            assert!(
                *tokens <= 40 + 70 * k,
                "read {i} with {k} change(s): {tokens} tokens"
            );
        }
    }
    for k in [1, 3, 5] {
        let tokens = read_with_k_changes(k).await;
        assert!(
            tokens <= 40 + 70 * k,
            "read with {k} changes: {tokens} tokens"
        );
    }
    assert!(
        bench.first_read_response_tokens <= bench.file_tokens,
        "first full read {} tokens vs the file's {}",
        bench.first_read_response_tokens,
        bench.file_tokens
    );
    assert!(
        bench.open_response_tokens <= bench.file_tokens,
        "open with the board {} tokens vs the file's {}",
        bench.open_response_tokens,
        bench.file_tokens
    );
    assert!(
        ratio <= 0.15,
        "the session costs {:.1}% of the full-board baseline ({} vs {} tokens)",
        ratio * 100.0,
        bench.session_tokens,
        bench.baseline_tokens
    );
    assert!(
        bench.descriptor_tokens <= 1_500,
        "descriptor: {} tokens",
        bench.descriptor_tokens
    );
    assert!(
        bench.descriptor_bytes <= 3_600,
        "descriptor: {} bytes",
        bench.descriptor_bytes
    );
}

/// Writes every benchmark request and response to `target/tracker-bench/`.
#[tokio::test]
#[ignore = "writes target/tracker-bench for the user-run calibration script"]
async fn dump() {
    let bench = run_benchmark().await;
    let target = std::env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"));
    let dir = target.join("tracker-bench");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create target/tracker-bench");
    for (i, record) in bench.log.records.iter().enumerate() {
        let name = format!(
            "{i:03}-{}-{}.json",
            record.label.replace(['/', ' '], "_"),
            record.kind
        );
        let body = json!({"label": record.label, "kind": record.kind, "text": record.text});
        std::fs::write(dir.join(name), serde_json::to_vec_pretty(&body).unwrap()).expect("write");
    }
    println!(
        "wrote {} files to {}",
        bench.log.records.len(),
        dir.display()
    );
}
