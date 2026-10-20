//! `nostromo.tracker` end to end (slice T0b): the tool surface a daemon-hosted
//! agent session calls, over a real temp git repo and a real state root.
//!
//! Everything goes through the public MCP entry point
//! (`nostromo::mcp::tools::dispatch("nostromo.tracker", ...)`) plus the
//! registry's public API where a test needs to look at what the pane would show
//! (`board_view`) or to play the file watcher (`ingest_file_change`).
//!
//! Spec: `.claude/plans/agent-tracker-pane-design-contract.md` §0-§5, §7, §8,
//! §12 and the PRD criteria quoted in each test's heading
//! (`.claude/prds/agent-tracker-pane.md`).
//!
//! Hermetic (contract §12): a `FakeClock`, temp dirs for the repo, the state
//! root and the "home" (`~/.claude/wip/` is the injected home's), and a git
//! repo created by `git init` whose `core.excludesFile` points at a temp file so
//! the user's global gitignore never matters. No wall clock, no real
//! `~/.nostromo`, no spawned `claude`: a focus tag is made to act as a caller
//! with `TrackerRegistry::set_caller_facts`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{ServerMsg, TrackerCounts};
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::{dispatch, tool_descriptors, ToolResult};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use nostromo::sensitive_text::{scan, GuardConfig};
use nostromo::tracker::view::{Banner, ViewItem, ViewNode};
use nostromo::tracker::{
    parse, CallerFacts, FakeClock, RegistryParts, TrackerBoardView, TrackerRegistry,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/tracker")
        .join(name)
}

fn fixture_bytes(name: &str) -> Vec<u8> {
    std::fs::read(fixture_path(name)).unwrap_or_else(|e| panic!("read fixture {name}: {e}"))
}

const POSITIVES_RAW: &str = include_str!("fixtures/sensitive_text/positives.txt");
const HOSTILE_RAW: &str = include_str!("fixtures/tracker/hostile-text.txt");

/// `positives.txt` with the U+00A6 mask removed, as `sensitive_text_corpus.rs`
/// loads it: `(class, text)` for every non-comment line.
fn positives() -> Vec<(String, String)> {
    POSITIVES_RAW
        .replace('\u{a6}', "")
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|l| {
            let (class, text) = l.split_once('\t').expect("class<TAB>text");
            (class.to_string(), text.to_string())
        })
        .collect()
}

fn decode_escapes(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('e') => out.push('\u{1b}'),
            Some('a') => out.push('\u{07}'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                assert_eq!(it.next(), Some('{'), "\\u needs braces");
                let mut hex = String::new();
                loop {
                    match it.next() {
                        Some('}') => break,
                        Some(h) => hex.push(h),
                        None => panic!("unterminated \\u{{"),
                    }
                }
                out.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
            }
            other => panic!("unknown escape {other:?} in hostile fixture"),
        }
    }
    out
}

/// `(name, payload)` for every case in `hostile-text.txt`.
fn hostile_cases() -> Vec<(String, String)> {
    HOSTILE_RAW
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let (name, payload) = l.split_once('\t').expect("NAME<TAB>PAYLOAD");
            (name.to_string(), decode_escapes(payload))
        })
        .collect()
}

fn hostile(name: &str) -> String {
    hostile_cases()
        .into_iter()
        .find(|(n, _)| n == name)
        .unwrap_or_else(|| panic!("hostile case {name}"))
        .1
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const TAG_A: &str = "cody-a";
const TAG_B: &str = "cody-b";

struct Fx {
    _tmp: TempDir,
    /// Canonical path of the git repo the focuses work in.
    repo: PathBuf,
    /// The injected home: `<home>/.claude/wip/` is an allowed board location.
    home: PathBuf,
    base: PathBuf,
    registry: Arc<TrackerRegistry>,
    state: McpSharedState,
    tx: broadcast::Sender<ServerMsg>,
    rx: Mutex<broadcast::Receiver<ServerMsg>>,
    session_mgr: Arc<Mutex<SessionManager>>,
}

/// Runs a setup `git` command in `repo` (never the product's job: tests may
/// stage files in their own temp repo). The user's global and system config
/// are ignored.
fn git(repo: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git is installed");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

impl Fx {
    fn new() -> Fx {
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
        git(&repo, &["config", "core.excludesFile", excludes.to_str().unwrap()]);

        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let registry = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            state_root,
            home.clone(),
            clock.clone(),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            base.join("sessions.json"),
        )));
        let (tx, rx) = broadcast::channel::<ServerMsg>(8192);
        let state = McpSharedState::for_daemon(DaemonMcpBackend {
            pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
            session_mgr: Arc::clone(&session_mgr),
            broadcast_tx: tx.clone(),
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
            tracker: Arc::clone(&registry),
        });
        Fx {
            _tmp: tmp,
            repo,
            home,
            base,
            registry,
            state,
            tx,
            rx: Mutex::new(rx),
            session_mgr,
        }
    }

    /// Makes `tag` a caller working in the repo with the given Claude session id.
    fn seat(&self, tag: &str, session: &str) {
        self.registry.set_caller_facts(
            tag,
            CallerFacts {
                cwd: Some(self.repo.clone()),
                session_id: Some(session.to_string()),
            },
        );
    }

    async fn call(&self, tag: &str, args: Value) -> Value {
        self.call_as(Some(tag), &self.state, args).await
    }

    async fn call_as(&self, tag: Option<&str>, state: &McpSharedState, args: Value) -> Value {
        match dispatch("nostromo.tracker", Some(&args), state, tag).await {
            ToolResult::Ok(content) => {
                let text = content[0]["text"].as_str().expect("text content");
                serde_json::from_str(text).unwrap_or_else(|e| panic!("tool text is JSON ({e}): {text}"))
            }
            ToolResult::UnknownTool(n) => panic!("unknown tool {n}"),
            ToolResult::Forbidden(n) => panic!("forbidden tool {n}"),
        }
    }

    /// Opens (or re-opens) `topic` for `tag`; the response must be ok.
    async fn open(&self, tag: &str, topic: &str) -> Value {
        let res = self.call(tag, json!({"op": "open", "topic": topic})).await;
        assert_eq!(res["ok"], json!(true), "open {topic}: {res}");
        res
    }

    fn board_path(&self, topic: &str) -> PathBuf {
        self.repo
            .join(".claude")
            .join("wip")
            .join(topic)
            .join("index.md")
    }

    fn file(&self, topic: &str) -> Vec<u8> {
        std::fs::read(self.board_path(topic)).expect("board file")
    }

    fn file_str(&self, topic: &str) -> String {
        String::from_utf8(self.file(topic)).expect("utf8 board")
    }

    /// Every frame broadcast since the last drain.
    fn drain(&self) -> Vec<ServerMsg> {
        let mut rx = self.rx.lock().unwrap();
        let mut out = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(m) => out.push(m),
                Err(broadcast::error::TryRecvError::Empty) => return out,
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(broadcast::error::TryRecvError::Closed) => return out,
            }
        }
    }

    /// Plays the watcher: the file changed on disk, the daemon notices.
    fn file_changed(&self, topic: &str) -> bool {
        let changed = self.registry.ingest_file_change(&self.board_path(topic));
        self.registry.flush(&self.tx);
        changed
    }

    async fn add_item(&self, tag: &str, id: &str, section: &str, text: &str) -> Value {
        let res = self
            .call(
                tag,
                json!({"op": "upsert", "id": id, "section": section, "text": text}),
            )
            .await;
        assert_eq!(res["ok"], json!(true), "upsert {id}: {res}");
        res
    }
}

fn board_frames(frames: &[ServerMsg], tag: &str) -> Vec<Option<TrackerBoardView>> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::TrackerBoard { tag: t, board } if t == tag => Some(board.clone()),
            _ => None,
        })
        .collect()
}

fn summary_frames(frames: &[ServerMsg], tag: &str) -> Vec<(bool, TrackerCounts)> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::TrackerSummary {
                tag: t,
                has_tracker,
                counts,
            } if t == tag => Some((*has_tracker, *counts)),
            _ => None,
        })
        .collect()
}

fn view_items(view: &TrackerBoardView) -> Vec<&ViewItem> {
    view.nodes
        .iter()
        .filter_map(|n| match n {
            ViewNode::Item(i) => Some(i),
            _ => None,
        })
        .collect()
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("not an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// Lines of `before` and `after` that differ (same line count required).
fn changed_lines(before: &str, after: &str) -> Vec<(usize, String, String)> {
    let b: Vec<&str> = before.split('\n').collect();
    let a: Vec<&str> = after.split('\n').collect();
    assert_eq!(
        b.len(),
        a.len(),
        "line count changed:\n--- before\n{before}\n--- after\n{after}"
    );
    b.iter()
        .zip(a.iter())
        .enumerate()
        .filter(|(_, (x, y))| x != y)
        .map(|(i, (x, y))| (i, x.to_string(), y.to_string()))
        .collect()
}

fn is_err(res: &Value, code: &str) {
    assert_eq!(res["ok"], json!(false), "expected an error: {res}");
    assert_eq!(res["error"], json!(code), "{res}");
}

fn dir_is_empty(dir: &Path) -> bool {
    std::fs::read_dir(dir).map(|mut d| d.next().is_none()).unwrap_or(true)
}

// ---------------------------------------------------------------------------
// PRD 1: open a new topic
// ---------------------------------------------------------------------------

#[tokio::test]
async fn opening_a_new_topic_creates_the_template_board_and_reports_counts_and_version() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let res = fx.open(TAG_A, "sentry-triage").await;

    let path = fx.board_path("sentry-triage");
    assert!(path.is_file(), "the board file was not created at {path:?}");
    assert_eq!(res["created"], json!(true), "{res}");
    assert_eq!(res["path"], json!(path.display().to_string()), "{res}");
    assert!(res["version"].is_u64(), "version is a number: {res}");
    assert!(res["visible"].is_boolean(), "visible is a boolean: {res}");
    assert_eq!(
        keys(&res["counts"]),
        set(&["todo", "in_progress", "blocked", "needs_you", "done"]),
        "counts has exactly the five status keys: {res}"
    );
    for k in ["todo", "in_progress", "blocked", "needs_you", "done"] {
        assert_eq!(res["counts"][k], json!(0), "a new board is empty: {res}");
    }

    let text = fx.file_str("sentry-triage");
    assert!(text.starts_with("# "), "the board starts with a title: {text:?}");
    let headings: Vec<&str> = text.lines().filter_map(|l| l.strip_prefix("## ")).collect();
    assert_eq!(
        headings,
        ["Now", "Next", "Waiting on you", "Done", "Findings", "Loose ends", "Log"],
        "template sections, in order: {text:?}"
    );
}

#[tokio::test]
async fn a_given_title_becomes_the_boards_first_line_and_given_sections_replace_the_template() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let res = fx
        .call(
            TAG_A,
            json!({"op": "open", "topic": "custom", "title": "Sentry triage", "sections": ["Doing", "Later"]}),
        )
        .await;
    assert_eq!(res["ok"], json!(true), "{res}");

    let text = fx.file_str("custom");
    assert_eq!(text.lines().next(), Some("# Sentry triage"), "{text:?}");
    let headings: Vec<&str> = text.lines().filter_map(|l| l.strip_prefix("## ")).collect();
    assert_eq!(headings, ["Doing", "Later"], "{text:?}");
}

#[tokio::test]
async fn the_first_open_of_a_session_returns_the_board_and_a_repeat_open_changes_nothing_and_adds_no_pane() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let first = fx.open(TAG_A, "sentry-triage").await;
    assert!(
        first["board"].as_str().is_some_and(|b| b.contains("## Now")),
        "the session's first open carries the compact board: {first}"
    );
    let before = fx.file("sentry-triage");
    fx.drain();

    let second = fx.open(TAG_A, "sentry-triage").await;

    assert_eq!(second["created"], json!(false), "{second}");
    assert_eq!(fx.file("sentry-triage"), before, "a repeat open must not touch the file");
    assert!(
        second.get("board").is_none(),
        "only the session's first open carries the board: {second}"
    );
    let frames = fx.drain();
    assert!(
        !frames.iter().any(|m| matches!(m, ServerMsg::FocusLayout { .. })),
        "a repeat open must not send a focus_layout frame: {frames:?}"
    );
}

#[tokio::test]
async fn opening_an_existing_board_from_a_second_focus_binds_it_and_hands_that_session_the_board() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "shared").await;
    fx.add_item(TAG_A, "ship-it", "now", "Ship the thing").await;
    let before = fx.file("shared");

    let res = fx.open(TAG_B, "shared").await;

    assert_eq!(res["created"], json!(false), "{res}");
    assert_eq!(fx.file("shared"), before, "opening an existing board writes nothing");
    let board = res["board"].as_str().expect("first open of session sess-b carries the board");
    assert!(board.contains("ship-it") && board.contains("Ship the thing"), "{board}");
    assert_eq!(
        fx.registry.bound_tags_for(&fx.board_path("shared")),
        vec![TAG_A.to_string(), TAG_B.to_string()]
    );
}

// ---------------------------------------------------------------------------
// PRD 2: adopting a hand-written board
// ---------------------------------------------------------------------------

#[tokio::test]
async fn opening_a_hand_written_board_adopts_it_and_only_adds_id_markers_to_task_lines() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let original = fixture_bytes("handwritten.md");
    let path = fx.board_path("notes");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, &original).unwrap();

    let res = fx.open(TAG_A, "notes").await;

    assert_eq!(res["created"], json!(false), "an existing file is adopted, not created: {res}");
    let after = fx.file_str("notes");
    let original_str = String::from_utf8(original.clone()).unwrap();

    // Removing the id markers gives back the original bytes.
    let marker = regex::Regex::new(r" <!-- #[a-z0-9][a-z0-9-]{0,31} [0-9]+( [^ ]+)? -->").unwrap();
    let stripped = marker.replace_all(&after, "");
    assert_eq!(
        stripped.as_ref(),
        original_str,
        "adoption must only add markers.\n--- after\n{after}"
    );

    // The markers are on column-0 task lines, and on nothing else.
    // The fixture is CRLF throughout and has no final newline.
    let before_lines: Vec<&str> = original_str.split("\r\n").collect();
    let after_lines: Vec<&str> = after.split("\r\n").collect();
    assert_eq!(before_lines.len(), after_lines.len());
    let mut marked = 0;
    for (b, a) in before_lines.iter().zip(after_lines.iter()) {
        if b == a {
            continue;
        }
        marked += 1;
        assert!(
            b.starts_with("- [ ] ") || b.starts_with("- [x] ") || b.starts_with("- [X] "),
            "a non-task line was changed: {b:?} -> {a:?}"
        );
    }
    assert_eq!(marked, 10, "ten column-0 task items in the fixture:\n{after}");
    assert!(
        after_lines.contains(&"- [ ] not an item"),
        "a task-looking line inside a fenced block is prose and stays as it was"
    );
    assert!(
        after_lines.contains(&"  - [ ] indented child task"),
        "an indented task line belongs to its parent's note and stays as it was"
    );

    // The adopted board reads back with the statuses the file already said.
    assert_eq!(
        res["counts"],
        json!({"todo": 7, "in_progress": 0, "blocked": 1, "needs_you": 0, "done": 2}),
        "{res}"
    );
    // Every added id is unique (two identical `Follow up` lines).
    let ids: Vec<String> = parse(after.as_bytes())
        .expect("the adopted board parses")
        .board
        .items
        .iter()
        .map(|i| i.id.clone())
        .collect();
    let unique: BTreeSet<&String> = ids.iter().collect();
    assert_eq!(unique.len(), ids.len(), "ids are unique: {ids:?}");

    // Adopting twice changes nothing more.
    fx.open(TAG_A, "notes").await;
    assert_eq!(fx.file_str("notes"), after);
}

// ---------------------------------------------------------------------------
// PRD 3: path policy
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_path_outside_the_repo_and_the_homes_wip_dir_is_refused_and_creates_nothing() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let outside = fx.base.join("outside");
    std::fs::create_dir_all(&outside).unwrap();

    let attempts = [
        // Absolute path outside both roots.
        outside.join("x.md").display().to_string(),
        // The injected home, but not under `.claude/wip/`.
        fx.home.join("notes.md").display().to_string(),
        // `..` out of the repo (the intermediate directories don't exist).
        fx.repo
            .join(".claude/wip/../../../outside/x.md")
            .display()
            .to_string(),
        // Relative `..` escape.
        "../outside/x.md".to_string(),
        "docs/../../outside/x.md".to_string(),
        // Not a markdown file.
        fx.repo.join("notes.txt").display().to_string(),
        "notes.txt".to_string(),
        fx.repo.join(".claude/wip/t/index.markdown").display().to_string(),
    ];
    for path in &attempts {
        let res = fx.call(TAG_A, json!({"op": "open", "path": path})).await;
        assert_eq!(res["ok"], json!(false), "{path}: {res}");
        assert_eq!(res["error"], json!("path_not_allowed"), "{path}: {res}");
    }
    assert!(dir_is_empty(&outside), "nothing may be created outside: {:?}", std::fs::read_dir(&outside).map(|d| d.count()));
    assert!(!fx.repo.join("notes.txt").exists());
    assert!(!fx.repo.join("docs").exists(), "no directories are created for a refused path");
    assert!(!fx.repo.join(".claude").exists(), "no directories are created for a refused path");
    assert!(!fx.home.join("notes.md").exists());
    assert!(!fx.home.join(".claude").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn a_symlink_that_escapes_the_repo_is_refused_and_writes_nothing_through_it() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let outside = fx.base.join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    let victim = outside.join("victim.md");
    std::fs::write(&victim, "# Not a board of ours\n\n## Now\n").unwrap();
    let victim_bytes = std::fs::read(&victim).unwrap();

    // A directory symlink inside the repo pointing out of it.
    std::fs::create_dir_all(fx.repo.join(".claude/wip")).unwrap();
    std::os::unix::fs::symlink(&outside, fx.repo.join(".claude/wip/link")).unwrap();
    // A file symlink inside the repo pointing at an existing outside file.
    std::os::unix::fs::symlink(&victim, fx.repo.join("board.md")).unwrap();
    // A dangling file symlink: writing through it would create the target.
    std::os::unix::fs::symlink(outside.join("dangling.md"), fx.repo.join("dangling.md")).unwrap();

    for path in [
        fx.repo.join(".claude/wip/link/x.md"),
        fx.repo.join(".claude/wip/link/victim.md"),
        fx.repo.join("board.md"),
        fx.repo.join("dangling.md"),
    ] {
        let res = fx
            .call(TAG_A, json!({"op": "open", "path": path.display().to_string()}))
            .await;
        assert_eq!(res["ok"], json!(false), "{path:?}: {res}");
        assert_eq!(res["error"], json!("path_not_allowed"), "{path:?}: {res}");
    }

    assert_eq!(std::fs::read(&victim).unwrap(), victim_bytes, "the outside file was touched");
    assert!(!outside.join("x.md").exists());
    assert!(!outside.join("dangling.md").exists());
    let names: BTreeSet<String> = std::fs::read_dir(&outside)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, set(&["victim.md"]), "nothing new appeared outside the repo");
}

#[tokio::test]
async fn an_explicit_md_path_in_the_repo_or_under_the_homes_claude_wip_is_allowed() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let in_repo = fx.call(TAG_A, json!({"op": "open", "path": "docs/plan.md"})).await;
    assert_eq!(in_repo["ok"], json!(true), "{in_repo}");
    assert_eq!(in_repo["created"], json!(true), "{in_repo}");
    assert!(fx.repo.join("docs/plan.md").is_file());

    let home_board = fx.home.join(".claude/wip/shared/index.md");
    let in_home = fx
        .call(
            TAG_A,
            json!({"op": "open", "path": home_board.display().to_string()}),
        )
        .await;
    assert_eq!(in_home["ok"], json!(true), "{in_home}");
    assert_eq!(in_home["created"], json!(true), "{in_home}");
    assert!(home_board.is_file(), "the board was created under the injected home");
}

#[tokio::test]
async fn an_invalid_topic_is_refused_with_invalid_args_and_creates_nothing() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    for topic in ["Bad Topic", "../escape", "-lead", "UPPER", &"a".repeat(49)] {
        let res = fx.call(TAG_A, json!({"op": "open", "topic": topic})).await;
        is_err(&res, "invalid_args");
    }
    assert!(!fx.repo.join(".claude").exists());
}

// ---------------------------------------------------------------------------
// PRD 4 / 5: single ops and atomic batches
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_status_op_changes_only_that_items_line() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t4").await;
    fx.add_item(TAG_A, "first-1", "now", "First thing").await;
    fx.add_item(TAG_A, "second-2", "next", "Second thing").await;
    fx.add_item(TAG_A, "third-3", "now", "Third thing").await;
    let before = fx.file_str("t4");

    let res = fx
        .call(TAG_A, json!({"op": "status", "id": "second-2", "status": "in-progress"}))
        .await;

    assert_eq!(res["ok"], json!(true), "{res}");
    assert!(res["version"].is_u64() && res["visible"].is_boolean() && res["user_changes"].is_u64(), "{res}");
    let after = fx.file_str("t4");
    let diff = changed_lines(&before, &after);
    assert_eq!(diff.len(), 1, "exactly one line may change: {diff:?}");
    assert!(
        diff[0].1.contains("#second-2 ") && diff[0].2.contains("#second-2 "),
        "the changed line is the item's: {diff:?}"
    );
    assert!(diff[0].2.contains("in progress"), "{diff:?}");
}

#[tokio::test]
async fn an_upsert_that_changes_one_field_changes_only_that_items_line() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t4b").await;
    fx.add_item(TAG_A, "first-1", "now", "First thing").await;
    fx.add_item(TAG_A, "second-2", "now", "Second thing").await;
    let before = fx.file_str("t4b");

    let res = fx
        .call(TAG_A, json!({"op": "upsert", "id": "first-1", "text": "First thing, reworded"}))
        .await;

    assert_eq!(res["ok"], json!(true), "{res}");
    let diff = changed_lines(&before, &fx.file_str("t4b"));
    assert_eq!(diff.len(), 1, "{diff:?}");
    assert!(diff[0].2.contains("First thing, reworded") && diff[0].2.contains("#first-1 "), "{diff:?}");
}

#[tokio::test]
async fn a_five_op_batch_with_one_unknown_id_writes_nothing_and_names_the_failing_op() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t5").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;
    fx.add_item(TAG_A, "c-3", "now", "Gamma").await;
    let before = fx.file("t5");

    let res = fx
        .call(
            TAG_A,
            json!({"ops": [
                {"op": "status", "id": "a-1", "status": "done"},
                {"op": "upsert", "id": "new-1", "section": "next", "text": "Brand new"},
                {"op": "log", "text": "about to fail"},
                {"op": "status", "id": "no-such-item", "status": "done"},
                {"op": "remove", "id": "c-3"},
            ]}),
        )
        .await;

    is_err(&res, "unknown_item");
    assert_eq!(res["index"], json!(3), "{res}");
    assert_eq!(fx.file("t5"), before, "an atomic batch that fails writes nothing");
}

#[tokio::test]
async fn a_valid_batch_applies_every_op_in_order() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t5ok").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;

    let res = fx
        .call(
            TAG_A,
            json!({"ops": [
                {"op": "status", "id": "a-1", "status": "done"},
                {"op": "upsert", "id": "new-1", "section": "next", "text": "Brand new"},
                {"op": "log", "text": "batch applied"},
            ]}),
        )
        .await;

    assert_eq!(res["ok"], json!(true), "{res}");
    let text = fx.file_str("t5ok");
    assert!(text.contains("- [x] Alpha"), "{text}");
    assert!(text.contains("Brand new"), "{text}");
    assert!(text.contains("batch applied"), "{text}");
}

#[tokio::test]
async fn an_invalid_status_is_refused_naming_the_op_and_changes_nothing() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t5s").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;
    let before = fx.file("t5s");

    let res = fx
        .call(TAG_A, json!({"op": "status", "id": "a-1", "status": "almost-done"}))
        .await;

    is_err(&res, "invalid_status");
    assert_eq!(fx.file("t5s"), before);
}

#[tokio::test]
async fn a_write_with_no_tracker_open_for_the_focus_is_refused_no_tracker() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let res = fx
        .call(TAG_A, json!({"op": "status", "id": "a-1", "status": "done"}))
        .await;
    is_err(&res, "no_tracker");
    let res = fx.call(TAG_A, json!({"op": "read"})).await;
    is_err(&res, "no_tracker");
}

// ---------------------------------------------------------------------------
// PRD 8: reads are deltas through the session's own cursor
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_new_sessions_first_read_is_the_board_and_a_second_read_is_empty() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t8").await;
    fx.add_item(TAG_A, "x-1", "now", "Investigate the thing").await;
    // The same focus, resumed as a different Claude session: no cursor yet.
    fx.seat(TAG_A, "sess-a2");

    let first = fx.call(TAG_A, json!({"op": "read"})).await;
    assert!(first["version"].is_u64(), "{first}");
    let board = first["board"].as_str().unwrap_or_else(|| panic!("a first read returns the board: {first}"));
    assert!(board.contains("x-1") && board.contains("Investigate the thing"), "{board}");
    assert!(first.get("changes").is_none(), "{first}");

    let second = fx.call(TAG_A, json!({"op": "read"})).await;
    assert_eq!(
        second,
        json!({"version": first["version"], "changes": []}),
        "an unchanged board reads as an empty delta"
    );
}

#[tokio::test]
async fn a_sessions_own_write_is_not_echoed_back_to_it_but_another_session_sees_it() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "t8b").await;
    fx.add_item(TAG_A, "x-1", "now", "Investigate the thing").await;
    fx.open(TAG_B, "t8b").await;

    let write = fx
        .call(TAG_A, json!({"op": "status", "id": "x-1", "status": "done"}))
        .await;
    assert_eq!(write["ok"], json!(true), "{write}");

    let own = fx.call(TAG_A, json!({"op": "read"})).await;
    assert_eq!(
        own["changes"],
        json!([]),
        "the writer's read must not include its own change: {own}"
    );
    assert_eq!(own["version"], write["version"], "{own} vs {write}");

    let other = fx.call(TAG_B, json!({"op": "read"})).await;
    let changes = other["changes"].as_array().unwrap_or_else(|| panic!("a delta: {other}"));
    assert_eq!(changes.len(), 1, "{other}");
    assert_eq!(changes[0]["id"], json!("x-1"), "{other}");
    assert!(
        changes[0]["by"].as_str().is_some_and(|b| b.starts_with("agent ")),
        "another agent's change is attributed to an agent: {other}"
    );
    assert_eq!(changes[0]["status"][1], json!("done"), "{other}");

    let again = fx.call(TAG_B, json!({"op": "read"})).await;
    assert_eq!(again["changes"], json!([]), "a read advances the cursor: {again}");
}

// ---------------------------------------------------------------------------
// PRD 9: malformed boards
// ---------------------------------------------------------------------------

async fn a_malformed_file_keeps_the_last_good_view_and_refuses_writes(fixture: &str, line: usize) {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let opened = fx.open(TAG_A, "m9").await;
    let path = PathBuf::from(opened["path"].as_str().unwrap());
    fx.add_item(TAG_A, "good-1", "now", "A good item").await;
    fx.add_item(TAG_A, "other-2", "next", "Another good item").await;
    let good_bytes = fx.file("m9");
    let good_view = fx.registry.board_view(TAG_A).expect("a board view");
    fx.drain();

    // Someone saves a broken file over the board.
    let bad = fixture_bytes(fixture);
    std::fs::write(&path, &bad).unwrap();
    assert!(fx.file_changed("m9"), "{fixture}: ingesting an unreadable file changes what the pane shows");

    let view = fx.registry.board_view(TAG_A).expect("the view is kept");
    match &view.banner {
        Some(Banner::Unreadable { line: l, reason, .. }) => {
            assert_eq!(*l, line, "{fixture}: the banner names the offending line");
            assert!(!reason.is_empty(), "{fixture}: the banner carries a reason");
        }
        other => panic!("{fixture}: expected an unreadable banner, got {other:?}"),
    }
    assert_eq!(view.title, good_view.title, "{fixture}");
    assert_eq!(view.nodes, good_view.nodes, "{fixture}: the pane keeps the last good board");
    let frames = fx.drain();
    let sent = board_frames(&frames, TAG_A);
    let last = sent.last().and_then(|b| b.as_ref()).unwrap_or_else(|| panic!("{fixture}: a tracker_board frame: {frames:?}"));
    assert!(matches!(last.banner, Some(Banner::Unreadable { line: l, .. }) if l == line), "{fixture}");
    assert_eq!(last.nodes, good_view.nodes, "{fixture}");

    // Every write is refused with the line, and the file is never touched.
    let writes = [
        json!({"op": "status", "id": "good-1", "status": "done"}),
        json!({"op": "upsert", "id": "new-1", "section": "now", "text": "New"}),
        json!({"op": "remove", "id": "other-2"}),
        json!({"op": "move", "id": "good-1", "section": "next"}),
        json!({"op": "log", "text": "hello"}),
        json!({"ops": [
            {"op": "status", "id": "good-1", "status": "blocked"},
            {"op": "log", "text": "batch"},
        ]}),
    ];
    for args in writes {
        let res = fx.call(TAG_A, args.clone()).await;
        assert_eq!(res["ok"], json!(false), "{fixture}: {args} => {res}");
        assert_eq!(res["error"], json!("board_unreadable"), "{fixture}: {args} => {res}");
        assert_eq!(res["line"], json!(line), "{fixture}: {args} => {res}");
        assert_eq!(fx.file("m9"), bad, "{fixture}: {args} must not touch the file");
    }
    // Neither does an open or a read.
    let _ = fx.call(TAG_A, json!({"op": "open", "topic": "m9"})).await;
    assert_eq!(fx.file("m9"), bad, "{fixture}: open must not touch an unreadable file");
    let _ = fx.call(TAG_A, json!({"op": "read"})).await;
    assert_eq!(fx.file("m9"), bad, "{fixture}: read must not touch an unreadable file");

    // Restoring the last good bytes clears the banner.
    std::fs::write(&path, &good_bytes).unwrap();
    assert!(fx.file_changed("m9"), "{fixture}: the banner clears on the next ingest");
    assert_eq!(fx.registry.board_view(TAG_A).unwrap().banner, None, "{fixture}");

    // So does writing a different valid board, whose edit is then ingested.
    std::fs::write(&path, &bad).unwrap();
    assert!(fx.file_changed("m9"));
    let fixed = String::from_utf8(good_bytes.clone())
        .unwrap()
        .replace("A good item", "A good item, repaired by hand");
    std::fs::write(&path, &fixed).unwrap();
    assert!(fx.file_changed("m9"), "{fixture}");
    let view = fx.registry.board_view(TAG_A).unwrap();
    assert_eq!(view.banner, None, "{fixture}: a fixed file clears the banner");
    assert!(
        view_items(&view)
            .iter()
            .any(|i| i.id == "good-1" && format!("{:?}", i.text_spans).contains("repaired by hand")),
        "{fixture}: the fixed content is what the pane shows"
    );
    // And writes work again.
    let res = fx.call(TAG_A, json!({"op": "log", "text": "back to normal"})).await;
    assert_eq!(res["ok"], json!(true), "{fixture}: {res}");
}

#[tokio::test]
async fn a_duplicate_id_file_shows_the_last_good_board_with_a_banner_and_refuses_writes() {
    a_malformed_file_keeps_the_last_good_view_and_refuses_writes("malformed-duplicate-id.md", 8).await;
}

#[tokio::test]
async fn a_garbled_marker_file_shows_the_last_good_board_with_a_banner_and_refuses_writes() {
    a_malformed_file_keeps_the_last_good_view_and_refuses_writes("malformed-garbled-marker.md", 5).await;
}

#[tokio::test]
async fn a_bad_utf8_file_shows_the_last_good_board_with_a_banner_and_refuses_writes() {
    a_malformed_file_keeps_the_last_good_view_and_refuses_writes("malformed-bad-utf8.md", 6).await;
}

// ---------------------------------------------------------------------------
// PRD 10: a missing board file
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_deleted_board_file_shows_a_missing_banner_refuses_writes_and_open_recreates_it_from_last_good() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    let opened = fx.open(TAG_A, "t10").await;
    let path = PathBuf::from(opened["path"].as_str().unwrap());
    fx.add_item(TAG_A, "keep-1", "now", "Keep this item").await;
    fx.add_item(TAG_A, "keep-2", "next", "And this one").await;
    let last_good = fx.file("t10");
    let good_view = fx.registry.board_view(TAG_A).unwrap();

    std::fs::remove_file(&path).unwrap();
    assert!(fx.file_changed("t10"));

    let view = fx.registry.board_view(TAG_A).expect("the view is kept");
    assert!(matches!(view.banner, Some(Banner::Missing { .. })), "{:?}", view.banner);
    assert_eq!(view.nodes, good_view.nodes, "the pane keeps the last good board");

    for args in [
        json!({"op": "status", "id": "keep-1", "status": "done"}),
        json!({"op": "log", "text": "hi"}),
        json!({"ops": [{"op": "remove", "id": "keep-2"}]}),
    ] {
        let res = fx.call(TAG_A, args.clone()).await;
        assert_eq!(res["ok"], json!(false), "{args} => {res}");
        assert_eq!(res["error"], json!("board_missing"), "{args} => {res}");
        assert!(!path.exists(), "a refused write must not recreate the file ({args})");
    }

    let res = fx.open(TAG_A, "t10").await;
    assert_eq!(res["recreated"], json!(true), "{res}");
    assert_eq!(res["created"], json!(false), "{res}");
    assert_eq!(std::fs::read(&path).unwrap(), last_good, "recreated from the last good copy");
    assert_eq!(fx.registry.board_view(TAG_A).unwrap().banner, None);
    let res = fx.call(TAG_A, json!({"op": "log", "text": "back"})).await;
    assert_eq!(res["ok"], json!(true), "{res}");
}

// ---------------------------------------------------------------------------
// PRD 11: size caps
// ---------------------------------------------------------------------------

#[tokio::test]
async fn growing_past_five_hundred_items_is_refused_board_too_large_while_reads_and_shrinking_work() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t11a").await;

    let mut n = 0;
    for _ in 0..3 {
        let ops: Vec<Value> = (0..200.min(500 - n))
            .map(|i| json!({"op": "upsert", "id": format!("item-{}", n + i), "section": "now", "text": format!("Item number {}", n + i)}))
            .collect();
        let count = ops.len();
        if count == 0 {
            break;
        }
        let res = fx.call(TAG_A, json!({"ops": ops})).await;
        assert_eq!(res["ok"], json!(true), "filling to {n}+{count}: {res}");
        n += count;
    }
    assert_eq!(n, 500);
    let before = fx.file("t11a");

    let res = fx
        .call(TAG_A, json!({"op": "upsert", "id": "one-too-many", "section": "now", "text": "Over the cap"}))
        .await;
    is_err(&res, "board_too_large");
    assert_eq!(fx.file("t11a"), before, "a refused growing write changes nothing");

    let read = fx.call(TAG_A, json!({"op": "read"})).await;
    assert!(read["version"].is_u64(), "reads still work: {read}");

    let res = fx.call(TAG_A, json!({"op": "remove", "id": "item-0"})).await;
    assert_eq!(res["ok"], json!(true), "shrinking still works: {res}");
    let res = fx.call(TAG_A, json!({"op": "upsert", "id": "fits-now", "section": "now", "text": "Room again"})).await;
    assert_eq!(res["ok"], json!(true), "{res}");
}

#[tokio::test]
async fn growing_a_board_past_256_kib_is_refused_board_too_large_while_reads_and_shrinking_work() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t11b").await;
    let note = "alpha beta gamma delta ".repeat(340); // ~7.8k chars, within the 8,000 cap

    let mut accepted = 0;
    let mut refused = None;
    for i in 0..80 {
        let res = fx
            .call(
                TAG_A,
                json!({"op": "upsert", "id": format!("big-{i}"), "section": "now", "text": format!("Big item {i}"), "note": note}),
            )
            .await;
        if res["ok"] == json!(true) {
            accepted += 1;
        } else {
            refused = Some(res);
            break;
        }
    }
    let refused = refused.expect("the byte cap must stop growth before 80 items of ~8 KB");
    assert_eq!(refused["error"], json!("board_too_large"), "{refused}");
    assert!(accepted >= 20, "only {accepted} items accepted before the cap");
    let size = fx.file("t11b").len();
    assert!(size <= 256 * 1024, "the file stays within the cap: {size}");

    let before = fx.file("t11b");
    let res = fx
        .call(TAG_A, json!({"op": "upsert", "id": "grow-more", "section": "now", "text": "More", "note": note}))
        .await;
    is_err(&res, "board_too_large");
    assert_eq!(fx.file("t11b"), before);

    let read = fx.call(TAG_A, json!({"op": "read"})).await;
    assert!(read["version"].is_u64(), "reads still work: {read}");
    let res = fx.call(TAG_A, json!({"op": "remove", "id": "big-0"})).await;
    assert_eq!(res["ok"], json!(true), "shrinking still works: {res}");
}

// ---------------------------------------------------------------------------
// PRD 33 (tool half): the sensitive-data guard
// ---------------------------------------------------------------------------

/// The request that puts `text` in `field`.
fn request_with(field: &str, text: &str) -> Value {
    match field {
        "text" => json!({"op": "upsert", "id": "guard-1", "section": "now", "text": text}),
        "note" => json!({"op": "upsert", "id": "guard-1", "section": "now", "text": "Plain", "note": text}),
        "owner" => json!({"op": "upsert", "id": "guard-1", "section": "now", "text": "Plain", "owner": text}),
        "links" => json!({"op": "upsert", "id": "guard-1", "section": "now", "text": "Plain", "links": [text]}),
        "command" => json!({"op": "upsert", "id": "guard-1", "section": "now", "text": "Plain", "kind": "command", "command": text}),
        "log" => json!({"op": "log", "text": text}),
        other => panic!("unknown field {other}"),
    }
}

/// Every 4+ character window of the text the guard matched, for each finding.
fn matched_windows(text: &str) -> Vec<String> {
    let mut windows = Vec::new();
    for finding in scan(text, &GuardConfig::default()) {
        let chars: Vec<char> = text[finding.range.clone()].chars().collect();
        for w in chars.windows(4) {
            windows.push(w.iter().collect::<String>());
        }
    }
    windows
}

/// The response without the fixed vocabulary of the refusal (error code,
/// field name and class name), which may legitimately resemble a match.
fn residual(res: &Value) -> String {
    let mut res = res.clone();
    if let Some(obj) = res.as_object_mut() {
        for k in ["error", "field", "class"] {
            obj.remove(k);
        }
    }
    res.to_string()
}

#[tokio::test]
async fn every_sensitive_corpus_line_is_refused_in_every_text_field_naming_the_field_and_class_and_never_echoing_it() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t33").await;
    fx.add_item(TAG_A, "baseline-1", "now", "A plain item").await;
    let before = fx.file("t33");
    fx.drain();

    let lines = positives();
    assert!(lines.len() >= 100, "the corpus loaded: {} lines", lines.len());
    let mut failures: Vec<String> = Vec::new();
    for (class, text) in &lines {
        let windows = matched_windows(text);
        for field in ["text", "note", "owner", "links", "command", "log"] {
            let res = fx.call(TAG_A, request_with(field, text)).await;
            let label = format!("[{class}] in `{field}`");
            if res["ok"] != json!(false)
                || res["error"] != json!("possible_sensitive_data")
                || res["field"] != json!(field)
                || res["class"] != json!(class)
            {
                failures.push(format!(
                    "{label}: expected possible_sensitive_data field={field} class={class}, got {res}"
                ));
                continue;
            }
            let rest = residual(&res);
            if let Some(w) = windows.iter().find(|w| rest.contains(w.as_str())) {
                failures.push(format!("{label}: the response echoes part of the matched value ({w:?}): {res}"));
            }
        }
    }
    assert!(failures.is_empty(), "{} failure(s):\n{}", failures.len(), failures.join("\n"));

    assert_eq!(fx.file("t33"), before, "a refused call must not touch the file");
    let frames = fx.drain();
    assert!(
        !frames.iter().any(|m| matches!(m, ServerMsg::TrackerBoard { .. })),
        "a refused call must not broadcast a tracker_board frame"
    );
}

#[tokio::test]
async fn a_sensitive_value_anywhere_in_a_batch_refuses_the_whole_batch_naming_the_op() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t33b").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;
    let before = fx.file("t33b");

    let res = fx
        .call(
            TAG_A,
            json!({"ops": [
                {"op": "status", "id": "a-1", "status": "done"},
                {"op": "log", "text": "Resident SSN was 219-09-9999"},
            ]}),
        )
        .await;

    is_err(&res, "possible_sensitive_data");
    assert_eq!(res["field"], json!("log"), "{res}");
    assert_eq!(res["class"], json!("ssn"), "{res}");
    assert_eq!(res["index"], json!(1), "{res}");
    assert!(!res.to_string().contains("9999"), "{res}");
    assert_eq!(fx.file("t33b"), before, "the first op of the batch must not have been applied");
}

#[tokio::test]
async fn sensitive_text_in_a_boards_title_or_topic_arguments_is_refused_before_anything_is_created() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let res = fx
        .call(
            TAG_A,
            json!({"op": "open", "topic": "plain", "title": "Chart for resident SSN 219-09-9999"}),
        )
        .await;

    is_err(&res, "possible_sensitive_data");
    assert_eq!(res["field"], json!("title"), "{res}");
    assert!(!fx.repo.join(".claude").exists(), "nothing is created for a refused open");
}

// ---------------------------------------------------------------------------
// PRD 35: committable warning
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_board_git_would_commit_warns_committable_and_shows_the_remote_without_credentials() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    git(
        &fx.repo,
        &["remote", "add", "origin", "https://uzer-cred:tokSECRETcred@github.com/o/r.git"],
    );

    let res = fx.open(TAG_A, "t35").await;

    assert_eq!(res["warnings"], json!(["committable"]), "{res}");
    let view = fx.registry.board_view(TAG_A).expect("a view");
    let committable = view.committable.clone().expect("the view carries committable");
    assert_eq!(committable.remote.as_deref(), Some("github.com/o/r"));

    let everything = format!(
        "{res} {} {:?}",
        serde_json::to_string(&view).unwrap(),
        serde_json::to_string(&fx.registry.frames_for_tag(TAG_A)).unwrap()
    );
    for secret in ["uzer-cred", "tokSECRETcred"] {
        assert!(!everything.contains(secret), "{secret} leaked: {everything}");
    }
    // The probe is read-only: it staged nothing and committed nothing.
    let status = Command::new("git")
        .arg("-C")
        .arg(&fx.repo)
        .args(["diff", "--cached", "--name-only"])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(status.stdout.is_empty(), "nothing may be staged: {:?}", String::from_utf8_lossy(&status.stdout));
}

#[tokio::test]
async fn a_committable_board_in_a_repo_with_no_remote_warns_without_a_remote() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let res = fx.open(TAG_A, "t35c").await;

    assert_eq!(res["warnings"], json!(["committable"]), "{res}");
    let view = fx.registry.board_view(TAG_A).unwrap();
    let committable = view.committable.expect("committable");
    assert_eq!(committable.remote, None);
    let wire = serde_json::to_value(fx.registry.board_view(TAG_A).unwrap()).unwrap();
    assert!(wire["committable"].is_object(), "{wire}");
}

#[tokio::test]
async fn a_board_in_a_gitignored_directory_has_neither_the_warning_nor_committable() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    std::fs::write(fx.repo.join(".gitignore"), ".claude/wip/\n").unwrap();
    git(&fx.repo, &["remote", "add", "origin", "https://github.com/o/r.git"]);

    let res = fx.open(TAG_A, "t35i").await;

    assert!(res.get("warnings").is_none(), "an ignored board is not committable: {res}");
    let view = fx.registry.board_view(TAG_A).unwrap();
    assert!(view.committable.is_none(), "{:?}", view.committable);
    let wire = serde_json::to_value(&view).unwrap();
    assert!(wire.get("committable").is_none(), "{wire}");
}

#[tokio::test]
async fn an_ignored_board_that_is_nevertheless_tracked_is_committable() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    std::fs::write(fx.repo.join(".gitignore"), ".claude/wip/\n").unwrap();
    fx.open(TAG_A, "t35t").await;
    // Test setup only: force-add the board to this temp repo's index.
    git(&fx.repo, &["add", "-f", ".claude/wip/t35t/index.md"]);

    fx.seat(TAG_B, "sess-b");
    let res = fx.open(TAG_B, "t35t").await;

    assert_eq!(res["warnings"], json!(["committable"]), "a tracked board is committable whatever .gitignore says: {res}");
}

// ---------------------------------------------------------------------------
// Command items
// ---------------------------------------------------------------------------

fn command_item(command: &str) -> Value {
    json!({"op": "upsert", "id": "cmd-1", "section": "now", "text": "Stage this command", "kind": "command", "command": command})
}

#[tokio::test]
async fn command_text_with_control_escape_bidi_or_zero_width_characters_is_refused_invalid_command_text() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "tcmd").await;
    let before = fx.file("tcmd");

    for name in ["bidi_rlo", "zero_width", "bom", "ansi_csi", "osc_bel", "osc_st", "bare_cr", "c1_csi"] {
        let res = fx.call(TAG_A, command_item(&hostile(name))).await;
        assert_eq!(res["ok"], json!(false), "{name}: {res}");
        assert_eq!(res["error"], json!("invalid_command_text"), "{name}: {res}");
        assert_eq!(fx.file("tcmd"), before, "{name}: nothing is written");
    }
    // Inside a batch too, and nothing else of the batch lands.
    let res = fx
        .call(
            TAG_A,
            json!({"ops": [{"op": "log", "text": "first"}, command_item(&hostile("ansi_csi"))]}),
        )
        .await;
    is_err(&res, "invalid_command_text");
    assert_eq!(fx.file("tcmd"), before);
}

#[tokio::test]
async fn plain_and_note_closing_command_text_is_valid_and_reads_back_quoted() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "tcmd2").await;

    for name in ["note_close", "note_close_upper", "note_open"] {
        let payload = hostile(name);
        let res = fx
            .call(
                TAG_A,
                json!({"op": "upsert", "id": format!("c-{name}").replace('_', "-"), "section": "now", "text": "Stage it", "kind": "command", "command": payload}),
            )
            .await;
        assert_eq!(res["ok"], json!(true), "{name} is plain text, not invalid command text: {res}");
    }
    let long = hostile("long_10k");
    let res = fx.call(TAG_A, command_item(&long)).await;
    assert_ne!(
        res["error"],
        json!("invalid_command_text"),
        "plain 10 KB text is not invalid command text: {res}"
    );
    if res["ok"] != json!(true) {
        is_err(&res, "invalid_args"); // over the 4,000-character command cap
    }

    // The file keeps the user's bytes untouched; the pane view has the command verbatim.
    let view = fx.registry.board_view(TAG_A).unwrap();
    for (id, name) in [("c-note-close", "note_close"), ("c-note-open", "note_open")] {
        let item = view_items(&view)
            .into_iter()
            .find(|i| i.id == id)
            .unwrap_or_else(|| panic!("{id} is on the board"));
        assert_eq!(item.command.as_deref(), Some(hostile(name).as_str()), "{id}");
    }

    // What another agent reads is quoted: it can never close the note.
    fx.seat(TAG_B, "sess-b");
    let opened = fx.open(TAG_B, "tcmd2").await;
    let board = opened["board"].as_str().expect("the board");
    assert!(!board.to_lowercase().contains("</nostromo-note"), "{board}");
    assert!(board.contains("‹/nostromo-note"), "{board}");
}

#[tokio::test]
async fn a_valid_command_item_can_be_created_and_read_back() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "tcmd3").await;
    fx.open(TAG_B, "tcmd3").await;

    let res = fx
        .call(
            TAG_A,
            json!({"op": "upsert", "id": "retry-1", "section": "waiting-on-you", "text": "Retry the failed queue job",
                   "kind": "command", "command": "php artisan queue:retry 8812", "env": "prod", "status": "needs-you"}),
        )
        .await;
    assert_eq!(res["ok"], json!(true), "{res}");

    let view = fx.registry.board_view(TAG_A).unwrap();
    let item = view_items(&view).into_iter().find(|i| i.id == "retry-1").expect("item");
    assert_eq!(item.command.as_deref(), Some("php artisan queue:retry 8812"));
    assert!(item.owner.is_none());
    let text = fx.file_str("tcmd3");
    assert!(text.contains("php artisan queue:retry 8812"), "{text}");

    let delta = fx.call(TAG_B, json!({"op": "read"})).await;
    let changes = delta["changes"].as_array().unwrap();
    assert!(
        changes.iter().any(|c| c["id"] == json!("retry-1")),
        "another session is told about the new command item: {delta}"
    );
}

#[tokio::test]
async fn an_agent_cannot_mark_a_command_item_done_by_status_or_upsert_or_in_a_batch() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "tcmd4").await;
    let res = fx.call(TAG_A, command_item("php artisan queue:retry 8812")).await;
    assert_eq!(res["ok"], json!(true), "{res}");
    fx.add_item(TAG_A, "plain-1", "now", "A plain item").await;
    let before = fx.file("tcmd4");

    let attempts = [
        json!({"op": "status", "id": "cmd-1", "status": "done"}),
        json!({"op": "upsert", "id": "cmd-1", "status": "done"}),
        json!({"ops": [
            {"op": "log", "text": "about to run it"},
            {"op": "status", "id": "plain-1", "status": "done"},
            {"op": "status", "id": "cmd-1", "status": "done"},
        ]}),
        // A new command item created already done.
        json!({"op": "upsert", "id": "cmd-2", "section": "now", "text": "Another", "kind": "command",
               "command": "ls", "status": "done"}),
    ];
    for args in attempts {
        let res = fx.call(TAG_A, args.clone()).await;
        assert_eq!(res["ok"], json!(false), "{args} => {res}");
        assert_eq!(res["error"], json!("not_permitted"), "{args} => {res}");
        assert_eq!(fx.file("tcmd4"), before, "{args}: nothing is written, not even the batch's other ops");
    }

    // Controls: other statuses on a command item, and done on a plain item, are fine.
    let ok = fx.call(TAG_A, json!({"op": "status", "id": "cmd-1", "status": "blocked"})).await;
    assert_eq!(ok["ok"], json!(true), "{ok}");
    let ok = fx.call(TAG_A, json!({"op": "status", "id": "plain-1", "status": "done"})).await;
    assert_eq!(ok["ok"], json!(true), "{ok}");
}

// ---------------------------------------------------------------------------
// Network-driven sessions, caller identity, argument errors, descriptor
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_network_driven_session_is_refused_requires_secure_connection_and_nothing_changes() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "tnet").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;
    let before = fx.file("tnet");
    fx.drain();
    fx.session_mgr.lock().unwrap().sensitive_tags().mark_network_driven(TAG_A);

    for args in [
        json!({"op": "status", "id": "a-1", "status": "done"}),
        json!({"op": "read"}),
        json!({"op": "open", "topic": "tnet-new"}),
        json!({"ops": [{"op": "log", "text": "x"}]}),
    ] {
        let res = fx.call(TAG_A, args.clone()).await;
        assert_eq!(res, json!({"ok": false, "error": "requires_secure_connection"}), "{args}");
    }
    assert_eq!(fx.file("tnet"), before);
    assert!(!fx.board_path("tnet-new").exists(), "a refused open creates nothing");
    assert!(
        !fx.drain().iter().any(|m| matches!(m, ServerMsg::TrackerBoard { .. })),
        "a refused call broadcasts nothing"
    );

    // Control: another session still has the tool.
    fx.open(TAG_B, "tnet").await;
    let res = fx.call(TAG_B, json!({"op": "status", "id": "a-1", "status": "done"})).await;
    assert_eq!(res["ok"], json!(true), "{res}");
}

#[tokio::test]
async fn a_call_with_no_pty_id_is_an_unidentified_caller() {
    let fx = Fx::new();
    let res = fx
        .call_as(None, &fx.state, json!({"op": "open", "topic": "nobody"}))
        .await;
    is_err(&res, "unidentified_caller");
    assert!(!fx.repo.join(".claude").exists());
}

#[tokio::test]
async fn a_tui_hosted_server_without_the_daemon_answers_not_supported() {
    let state = McpSharedState::for_test();
    assert!(state.daemon.is_none());
    let fx = Fx::new();
    let res = fx
        .call_as(Some("cody-a"), &state, json!({"op": "open", "topic": "nowhere"}))
        .await;
    is_err(&res, "not_supported");
}

#[tokio::test]
async fn an_unknown_op_and_a_missing_op_are_invalid_args() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "targs").await;
    let before = fx.file("targs");

    for args in [
        json!({"op": "explode"}),
        json!({}),
        json!({"ops": [{"op": "explode"}]}),
        json!({"ops": [{"op": "open", "topic": "inner"}]}),
        json!({"ops": []}),
        json!({"op": "status", "id": "a-1"}),
    ] {
        let res = fx.call(TAG_A, args.clone()).await;
        assert_eq!(res["ok"], json!(false), "{args} => {res}");
        assert_eq!(res["error"], json!("invalid_args"), "{args} => {res}");
    }
    assert_eq!(fx.file("targs"), before);
}

#[tokio::test]
async fn a_batch_of_more_than_200_ops_is_refused_invalid_args_before_any_op_runs() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "t200").await;
    let before = fx.file("t200");

    let ops: Vec<Value> = (0..201).map(|i| json!({"op": "log", "text": format!("line {i}")})).collect();
    let res = fx.call(TAG_A, json!({"ops": ops})).await;

    is_err(&res, "invalid_args");
    assert_eq!(res["index"], json!(200), "{res}");
    assert_eq!(fx.file("t200"), before, "no op ran");

    // The cap itself is allowed.
    let ops: Vec<Value> = (0..200).map(|i| json!({"op": "log", "text": format!("line {i}")})).collect();
    let res = fx.call(TAG_A, json!({"ops": ops})).await;
    assert_eq!(res["ok"], json!(true), "{res}");
}

#[test]
fn the_tracker_tool_is_listed_and_its_descriptor_fits_the_schema_budget() {
    let descriptors = tool_descriptors();
    let tracker = descriptors
        .iter()
        .find(|d| d["name"] == json!("nostromo.tracker"))
        .expect("nostromo.tracker is in tool_descriptors()");
    assert!(tracker["description"].as_str().is_some_and(|d| !d.is_empty()));
    assert_eq!(tracker["inputSchema"]["type"], json!("object"));
    let bytes = serde_json::to_string(tracker).unwrap().len();
    assert!(bytes <= 3_600, "descriptor is {bytes} bytes of compact JSON, budget 3,600");
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_write_broadcasts_a_board_and_a_summary_frame_for_every_focus_bound_to_the_board() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.seat("cody-other", "sess-o");
    fx.open(TAG_A, "tfr").await;
    fx.open(TAG_B, "tfr").await;
    fx.open("cody-other", "unrelated").await;
    fx.add_item(TAG_A, "a-1", "now", "Alpha").await;
    fx.drain();

    let res = fx
        .call(TAG_A, json!({"op": "status", "id": "a-1", "status": "in-progress"}))
        .await;
    assert_eq!(res["ok"], json!(true), "{res}");
    let frames = fx.drain();

    for tag in [TAG_A, TAG_B] {
        let boards = board_frames(&frames, tag);
        let board = boards
            .last()
            .unwrap_or_else(|| panic!("no tracker_board frame for {tag}: {frames:?}"))
            .as_ref()
            .unwrap_or_else(|| panic!("the board frame for {tag} carries a board"));
        assert_eq!(board.version, res["version"].as_u64().unwrap(), "{tag}");
        let item = view_items(board).into_iter().find(|i| i.id == "a-1").expect("a-1");
        assert_eq!(format!("{:?}", item.status).to_lowercase().replace('_', ""), "inprogress", "{tag}");

        let summaries = summary_frames(&frames, tag);
        let (has_tracker, counts) = summaries.last().unwrap_or_else(|| panic!("no tracker_summary for {tag}: {frames:?}"));
        assert!(*has_tracker, "{tag}");
        assert_eq!(counts.in_progress, 1, "{tag}");
        assert_eq!(counts.todo, 0, "{tag}");
    }
    assert!(
        board_frames(&frames, "cody-other").is_empty() && summary_frames(&frames, "cody-other").is_empty(),
        "a focus bound to another board gets nothing: {frames:?}"
    );
}

#[tokio::test]
async fn opening_a_board_broadcasts_its_view_and_summary_to_the_opening_focus() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.drain();

    fx.open(TAG_A, "topen").await;
    let frames = fx.drain();

    let boards = board_frames(&frames, TAG_A);
    assert!(boards.last().is_some_and(|b| b.is_some()), "{frames:?}");
    let summaries = summary_frames(&frames, TAG_A);
    assert_eq!(summaries.last().map(|s| s.0), Some(true), "{frames:?}");
}
