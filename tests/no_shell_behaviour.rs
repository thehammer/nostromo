//! Criterion 48b (PRD agent-tracker-pane, "Staged commands"): no tracker
//! operation, driven with every fixture command and every adversarial string,
//! puts a byte into a PTY. The surface half is `tests/no_shell_surface.rs`.
//!
//! A real PTY runs `cat >> $LOG` in raw mode in the same focus as the tracker.
//! Every tool op (`nostromo.tracker`: open, upsert, status, move, remove, log,
//! read, batches) and every pane op (`TrackerEdit`) is driven. Afterwards the
//! daemon's own count of bytes written to that PTY master is zero and the
//! child's log is empty. A positive control on a second PTY proves the same
//! detector sees a byte when one is written.
//!
//! Hermetic: temp git repo, state root and home; fake clock; no `claude`.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{ServerMsg, TrackerPaneOp};
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::{dispatch, ToolResult};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use nostromo::terminal::session::TerminalSession;
use nostromo::terminal::{TerminalAgentApi, TerminalManager};
use nostromo::tracker::{CallerFacts, FakeClock, RegistryParts, TrackerRegistry};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const COMMANDS_RAW: &str = include_str!("fixtures/tracker/commands.txt");
const HOSTILE_RAW: &str = include_str!("fixtures/tracker/hostile-text.txt");
const TAG: &str = "cody-focus";
const SESSION: &str = "sess-a";

/// The child: raw mode so a byte arrives at once, then everything it reads goes to `$LOG`.
const CHILD: &str = "stty raw -echo; : > \"$READY\"; exec cat >> \"$LOG\"";

fn decode(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('e') => out.push('\u{1b}'),
            Some('a') => out.push('\u{07}'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                assert_eq!(it.next(), Some('{'));
                let mut hex = String::new();
                for h in it.by_ref() {
                    if h == '}' {
                        break;
                    }
                    hex.push(h);
                }
                out.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
            }
            other => panic!("unknown escape {other:?}"),
        }
    }
    out
}

fn cases(raw: &str) -> Vec<(String, String)> {
    raw.lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let (name, payload) = l.split_once('\t').expect("NAME<TAB>PAYLOAD");
            (name.to_string(), decode(payload))
        })
        .collect()
}

fn commands() -> Vec<(String, String)> {
    cases(COMMANDS_RAW)
        .into_iter()
        .filter(|(n, _)| !n.starts_with("hostile_"))
        .collect()
}

/// Every adversarial string: the command fixtures' hostile set and the tracker's hostile-text corpus.
fn hostile() -> Vec<(String, String)> {
    let mut all: Vec<(String, String)> = cases(COMMANDS_RAW)
        .into_iter()
        .filter(|(n, _)| n.starts_with("hostile_"))
        .collect();
    all.extend(cases(HOSTILE_RAW));
    all
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git is installed");
    assert!(out.status.success(), "git {args:?}");
}

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Pty {
    session: Arc<TerminalSession>,
    log: PathBuf,
}

impl Pty {
    fn log(&self) -> Vec<u8> {
        std::fs::read(&self.log).unwrap_or_default()
    }
}

struct World {
    _tmp: TempDir,
    repo: PathBuf,
    registry: Arc<TrackerRegistry>,
    state: McpSharedState,
    terminals: Arc<Mutex<TerminalManager>>,
    sessions: Arc<Mutex<SessionManager>>,
    rx: Mutex<broadcast::Receiver<ServerMsg>>,
    tx: broadcast::Sender<ServerMsg>,
    spawned: Mutex<usize>,
}

impl World {
    fn new() -> World {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        let state_root = base.join("state");
        for dir in [&repo, &home, &state_root] {
            std::fs::create_dir_all(dir).unwrap();
        }
        git(&repo, &["init", "-q"]);
        let excludes = base.join("global-excludes");
        std::fs::write(&excludes, "").unwrap();
        git(
            &repo,
            &["config", "core.excludesFile", excludes.to_str().unwrap()],
        );
        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let registry = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            state_root, home, clock,
        )));
        let sessions = Arc::new(Mutex::new(SessionManager::with_store_path(
            base.join("sessions.json"),
        )));
        let terminals = TerminalManager::in_memory();
        let (tx, rx) = broadcast::channel::<ServerMsg>(8192);
        let state = McpSharedState::for_daemon(DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
            session_mgr: Arc::clone(&sessions),
            broadcast_tx: tx.clone(),
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(
                nostromo::ipc::decisions::DecisionRegistry::default(),
            )),
            tickets: Default::default(),
            tracker: Arc::clone(&registry),
            terminals: TerminalAgentApi::new(Arc::clone(&terminals)),
        });
        registry.set_caller_facts(
            TAG,
            CallerFacts {
                cwd: Some(repo.clone()),
                session_id: Some(SESSION.to_string()),
            },
        );
        World {
            _tmp: tmp,
            repo,
            registry,
            state,
            terminals,
            sessions,
            rx: Mutex::new(rx),
            tx,
            spawned: Mutex::new(0),
        }
    }

    /// A local PTY of focus `tag` running [`CHILD`], logging to a temp file.
    fn pty(&self, tag: &str) -> Pty {
        let n = {
            let mut s = self.spawned.lock().unwrap();
            *s += 1;
            *s
        };
        let dir = self.repo.parent().unwrap();
        let ready = dir.join(format!("ready-{n}"));
        let log = dir.join(format!("log-{n}"));
        let argv = vec!["/bin/sh".to_string(), "-c".to_string(), CHILD.to_string()];
        let env = vec![
            ("READY".to_string(), ready.display().to_string()),
            ("LOG".to_string(), log.display().to_string()),
        ];
        let (_id, session) = self
            .terminals
            .lock()
            .unwrap()
            .open_argv_for_test(tag, &argv, dir, &env)
            .expect("spawn /bin/sh");
        wait_for("the child to be ready", || ready.exists());
        Pty { session, log }
    }

    async fn tool(&self, args: Value) -> Value {
        match dispatch("nostromo.tracker", Some(&args), &self.state, Some(TAG)).await {
            ToolResult::Ok(content) => {
                serde_json::from_str(content[0]["text"].as_str().expect("text")).expect("json")
            }
            _ => panic!("the tracker tool did not answer"),
        }
    }

    /// A pane edit against the board's current version; the outcome is the caller's to judge.
    fn pane(&self, ops: Vec<TrackerPaneOp>) -> bool {
        let version = self.registry.board_view(TAG).map_or(0, |b| b.version);
        self.registry.apply_pane_ops(TAG, version, &ops).is_ok()
    }

    fn board(&self) -> String {
        let path = self.registry.bound_path(TAG).expect("a bound board");
        String::from_utf8_lossy(&std::fs::read(path).expect("board file")).into_owned()
    }
}

fn pane_status(id: &str, status: &str) -> TrackerPaneOp {
    TrackerPaneOp::Status {
        id: id.into(),
        status: status.into(),
    }
}

/// Every text-carrying field of the tool, one call per field per string.
fn upserts_with(text: &str, id: &str) -> Vec<Value> {
    vec![
        json!({"op": "upsert", "id": id, "section": "now", "text": text}),
        json!({"op": "upsert", "id": id, "section": "now", "title": text}),
        json!({"op": "upsert", "id": id, "body": text}),
        json!({"op": "upsert", "id": id, "note": text}),
        json!({"op": "upsert", "id": id, "owner": text}),
        json!({"op": "upsert", "id": id, "section": text, "text": "in a hostile section"}),
        json!({"op": "upsert", "id": id, "links": [text, {"text": text, "url": text}]}),
        json!({"op": "upsert", "id": id, "bind": text}),
        json!({"op": "upsert", "id": format!("{id}-cmd"), "section": "now", "text": "stage", "kind": "command", "command": text}),
        json!({"op": "upsert", "id": format!("{id}-cmd"), "command": text, "env": "prod"}),
        json!({"op": "log", "text": text}),
        json!({"op": "status", "id": text, "status": "done"}),
        json!({"op": "move", "id": id, "section": text}),
        json!({"op": "remove", "id": text}),
        json!({"ops": [
            {"op": "log", "text": text},
            {"op": "upsert", "id": id, "title": text, "kind": "command", "command": text},
            {"op": "status", "id": id, "status": "in-progress"},
        ]}),
    ]
}

#[tokio::test]
async fn driving_every_tracker_op_with_every_command_and_hostile_string_writes_no_byte_to_the_pty()
{
    let w = World::new();
    let pty = w.pty(TAG);
    assert_eq!(pty.session.input_bytes_written(), 0, "a fresh PTY");

    let opened = w
        .tool(json!({"op": "open", "topic": "no-shell", "sections": ["now", "next"]}))
        .await;
    assert_eq!(opened["ok"], json!(true), "{opened}");

    // Every fixture command is staged, accepted and stored exactly as given.
    for (i, (name, command)) in commands().iter().enumerate() {
        let id = format!("cmd-{i}");
        let res = w
            .tool(
                json!({"op": "upsert", "id": id, "section": "now", "text": format!("Stage {name}"),
                         "kind": "command", "command": command, "env": "prod"}),
            )
            .await;
        assert_eq!(res["ok"], json!(true), "{name} must be accepted: {res}");
        let view = w.registry.board_view(TAG).expect("board");
        let stored = view
            .nodes
            .iter()
            .find_map(|n| match n {
                nostromo::tracker::view::ViewNode::Item(item) if item.id == id => {
                    Some(item.clone())
                }
                _ => None,
            })
            .unwrap_or_else(|| panic!("{name}: item not on the board"));
        assert_eq!(stored.command.as_deref(), Some(command.as_str()), "{name}");
        assert!(!stored.ran, "{name}: staging never marks a command run");
    }
    // The agent still cannot mark one done, and every other status is fine.
    let refused = w
        .tool(json!({"op": "status", "id": "cmd-0", "status": "done"}))
        .await;
    assert_eq!(refused["error"], json!("not_permitted"), "{refused}");
    for status in ["todo", "in-progress", "blocked", "needs-you"] {
        let res = w
            .tool(json!({"op": "status", "id": "cmd-0", "status": status}))
            .await;
        assert_eq!(res["ok"], json!(true), "{status}: {res}");
    }

    // Hostile command text is refused and the board does not change.
    for (name, text) in hostile().iter().filter(|(n, _)| n.starts_with("hostile_")) {
        let before = w.board();
        let res = w
            .tool(json!({"op": "upsert", "id": "evil", "section": "now", "text": "x", "kind": "command", "command": text}))
            .await;
        assert_eq!(res["error"], json!("invalid_command_text"), "{name}: {res}");
        assert_eq!(w.board(), before, "{name}: nothing written");
    }

    // Every op with every string in every text field (accepted or refused, never a byte to the PTY).
    for (name, text) in hostile() {
        for (n, args) in upserts_with(&text, "victim").into_iter().enumerate() {
            let res = w.tool(args.clone()).await;
            assert!(
                res.get("ok").is_some(),
                "{name}/{n}: an answer, not a crash: {res}"
            );
        }
    }
    // Clean items so the ops below have something real to act on.
    for args in [
        json!({"op": "upsert", "id": "plain", "section": "now", "text": "A plain item"}),
        json!({"op": "status", "id": "plain", "status": "in-progress"}),
        json!({"op": "move", "id": "plain", "section": "next"}),
        json!({"op": "log", "text": "driven"}),
        json!({"ops": [{"op": "log", "text": "batch"}, {"op": "status", "id": "plain", "status": "blocked"}]}),
        json!({"op": "remove", "id": "plain"}),
        json!({"op": "open", "topic": "no-shell"}),
    ] {
        let res = w.tool(args.clone()).await;
        assert_eq!(res["ok"], json!(true), "{args}: {res}");
    }

    // Every pane op (T3a), including the user's "Ran it" tick, with hostile text too.
    assert!(
        w.pane(vec![pane_status("cmd-1", "done")]),
        "the user may tick a command"
    );
    for (_, text) in hostile() {
        w.pane(vec![
            TrackerPaneOp::Add {
                section: "now".into(),
                title: text.clone(),
                body: Some(text.clone()),
                before: None,
                after: None,
            },
            TrackerPaneOp::Edit {
                id: "cmd-2".into(),
                title: Some(text.clone()),
                text: None,
                body: Some(text.clone()),
            },
            TrackerPaneOp::RestoreText {
                id: "cmd-2".into(),
                text: text.clone(),
            },
            TrackerPaneOp::Restore {
                source: format!("- [ ] {text}\n"),
                section: "now".into(),
                before: None,
                after: None,
            },
        ]);
    }
    w.pane(vec![TrackerPaneOp::Move {
        id: "cmd-3".into(),
        section: "next".into(),
        before: None,
        after: None,
    }]);
    w.pane(vec![TrackerPaneOp::ClearBadge { id: "cmd-3".into() }]);
    w.pane(vec![TrackerPaneOp::AckDropped { id: "cmd-3".into() }]);
    w.pane(vec![pane_status("cmd-1", "todo")]);
    w.pane(vec![TrackerPaneOp::Remove { id: "cmd-4".into() }]);
    // A file edit ticking a command, as the user's editor would.
    let path = w.registry.bound_path(TAG).unwrap();
    std::fs::write(&path, w.board().replacen("- [ ]", "- [x]", 1)).unwrap();
    w.registry.ingest_file_change(&path);
    w.registry.flush(&w.tx);
    // The agent's next read sees the user's changes; still nothing reaches a shell.
    let read = w.tool(json!({"op": "read"})).await;
    assert!(read["changes"].is_array(), "{read}");
    let _ = w.rx.lock().unwrap().try_recv();

    // The daemon's own count of bytes written to the PTY master: zero. The child received nothing.
    assert_eq!(
        pty.session.input_bytes_written(),
        0,
        "the daemon wrote to the PTY"
    );
    std::thread::sleep(Duration::from_millis(200));
    assert!(pty.log().is_empty(), "the child received {:?}", pty.log());
    // No agent session was reached either: none was ever started, and no tracker op started one.
    assert!(
        w.sessions.lock().unwrap().list().is_empty(),
        "a tracker op reached a session"
    );
}

#[test]
fn the_detector_sees_a_byte_when_one_is_written() {
    let w = World::new();
    let quiet = w.pty("quiet");
    let loud = w.pty("loud");
    loud.session.write(b"X").expect("write");
    wait_for("the byte to reach the child", || loud.log() == b"X");
    assert_eq!(loud.session.input_bytes_written(), 1);
    assert_eq!(quiet.session.input_bytes_written(), 0);
    assert!(quiet.log().is_empty());
}

#[test]
fn the_tracker_code_names_nothing_that_writes_to_a_terminal_or_a_session() {
    let forbidden = [
        "TerminalManager",
        "TerminalSession",
        "TerminalAgentApi",
        "OperatorCap",
        "PtyInput",
        "SessionSend",
        "input_via",
        "write_bytes",
        "input_bytes",
        "SessionManager",
        "ChildStdin",
        "tokio::process",
        "libc::write",
    ];
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files: Vec<PathBuf> = std::fs::read_dir(root.join("src/tracker"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    files.extend(
        std::fs::read_dir(root.join("src/mcp/tools"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("tracker")
            }),
    );
    let mut found = Vec::new();
    for file in files
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "rs"))
    {
        let text = std::fs::read_to_string(&file).unwrap();
        // Production code (before `#[cfg(test)]`) may run `git` with a null stdin, but may name none of these.
        let production = text.split("#[cfg(test)]").next().unwrap();
        for word in forbidden {
            if production.contains(word) {
                found.push(format!("{} names `{word}`", file.display()));
            }
        }
    }
    assert!(found.is_empty(), "{found:#?}");
}
