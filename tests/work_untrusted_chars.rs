//! Characters a reader cannot see but a model can read: variation selectors, the whole Unicode tag
//! block, blank "filler" letters and the like. They must be stripped from every piece of third-party
//! text on its way to an agent (a title or field in the list, a detail's title and body) and from a
//! reason an agent publishes, while ordinary visible text, emoji included, comes through intact.
//!
//! The scanner in `support/fence_scan.rs` asks the daemon's own predicate what is invisible, so these
//! tests and the sanitiser cannot share a blind spot; the list of code points here is the independent
//! statement of what must be covered.

use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use chrono::Utc;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::picks::sanitize_reason;
use nostromo::data::work::{SourceState, WorkSource};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mcp::tools::teri::{get_work_item, list_work_items, publish_picks};
use nostromo::mcp::tools::{dispatch, ToolResult};
use nostromo::mcp::McpSharedState;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, watch};

#[allow(dead_code)]
#[path = "support/fence_scan.rs"]
mod fence_scan;

const WAIT: Duration = Duration::from_secs(5);

// ── what must be stripped ─────────────────────────────────────────────────────

/// Every code point that must never reach an agent, spelled out here on purpose.
fn invisible_code_points() -> Vec<char> {
    let mut v: Vec<char> = Vec::new();
    v.extend('\u{FE00}'..='\u{FE0F}'); // variation selectors
    v.extend('\u{E0100}'..='\u{E01EF}'); // variation selectors supplement
    v.extend('\u{E0000}'..='\u{E00FF}'); // the whole tag block
    v.extend(['\u{0890}', '\u{0891}', '\u{110CD}']); // Arabic number marks, Kaithi number sign above
    v.extend('\u{13430}'..='\u{1343F}'); // Egyptian hieroglyph format controls
    v.extend(['\u{115F}', '\u{1160}', '\u{3164}', '\u{FFA0}', '\u{034F}']); // blank fillers and CGJ
    v.extend(['\u{202E}', '\u{200B}', '\u{E0041}']); // the classics
    v
}

/// Text that has to come through untouched (already in NFKC form: a reason is normalised, so
/// half-width kana, compatibility jamo and combining sequences would come back rewritten).
const VISIBLE: &str = "Caf\u{e9} \u{1F680} \u{2705} \u{65E5}\u{672C}\u{8A9E} \u{D55C}\u{AD6D}\u{C5B4} \
                       \u{30AB}\u{30BF}\u{30AB}\u{30CA} \u{F1} \u{AC00} \u{B7} \u{2014} (3 of 5)";

fn all_invisible() -> String {
    invisible_code_points().into_iter().collect()
}

/// "Hello" and "World" with every invisible code point between them.
fn hostile(a: &str, b: &str) -> String {
    format!("{a}{}{b}", all_invisible())
}

fn survivors(text: &str) -> Vec<String> {
    let bad = invisible_code_points();
    text.chars().filter(|c| bad.contains(c)).map(|c| format!("U+{:04X}", c as u32)).collect()
}

#[test]
fn the_list_of_code_points_is_what_the_task_says_it_is() {
    // 16 + 240 + 256 + 3 + 16 + 5 + 3, with U+E0041 (inside the tag block) counted twice.
    assert_eq!(invisible_code_points().len(), 16 + 240 + 256 + 3 + 16 + 5 + 3);
}

#[test]
fn the_scanner_treats_every_one_of_them_as_forbidden() {
    let missed: Vec<String> = invisible_code_points()
        .into_iter()
        .filter(|c| !fence_scan::is_forbidden(*c))
        .map(|c| format!("U+{:04X}", c as u32))
        .collect();
    assert!(missed.is_empty(), "the daemon's predicate misses {missed:?}");
    for visible in VISIBLE.chars().filter(|c| *c != ' ') {
        assert!(!fence_scan::is_forbidden(visible), "U+{:04X} is visible text", visible as u32);
    }
}

// ── a reason an agent publishes ───────────────────────────────────────────────

#[test]
fn each_invisible_code_point_is_stripped_from_a_reason_on_its_own() {
    let mut kept: Vec<String> = Vec::new();
    for c in invisible_code_points() {
        if sanitize_reason(&format!("a{c}b")).as_deref() != Some("ab") {
            kept.push(format!("U+{:04X}", c as u32));
        }
    }
    assert!(kept.is_empty(), "these survive in a reason: {kept:?}");
}

#[test]
fn ordinary_visible_text_survives_in_a_reason_and_only_the_emoji_variation_selector_goes() {
    assert_eq!(sanitize_reason(VISIBLE).as_deref(), Some(VISIBLE));
    assert_eq!(sanitize_reason("\u{2705}\u{FE0F} \u{2764}\u{FE0F}").as_deref(), Some("\u{2705} \u{2764}"));
}

// ── through the daemon ────────────────────────────────────────────────────────

fn isolate_sent_ledger() {
    static DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("nostromo-work-untrusted-chars-teri-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("temp teri dir");
        std::env::set_var("NOSTROMO_TERI_DIR", &dir);
        nostromo::data::work::sent::install_ledger(std::sync::Arc::new(
            nostromo::data::work::sent::SentLedger::new(dir.join("sent.json")),
        ));
        dir
    });
}

struct Rig {
    state: McpSharedState,
    hub: std::sync::Arc<WorkHub>,
    _brx: broadcast::Receiver<ServerMsg>,
    _ttx: watch::Sender<Option<TeriTodosSnapshot>>,
    _dir: tempfile::TempDir,
}

fn todo(id: i64, title: String, due: Option<String>, body: Option<String>) -> TeriTodo {
    TeriTodo { id, title, status: "open".into(), priority: 2, due_date: due, jira_key: None, body }
}

async fn rig(todos: Vec<TeriTodo>) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let docs = dir.path().join("code");
    fs::create_dir_all(&docs).unwrap();
    let n = todos.len();
    let (btx, brx) = broadcast::channel(1024);
    let mut waiter = btx.subscribe();
    let (ttx, trx) = watch::channel(Some(TeriTodosSnapshot { generated_at: Some(Utc::now()), items: todos, ..Default::default() }));
    isolate_sent_ledger();
    let hub = WorkHub::spawn(HubDeps {
        repo_docs_root: Some(docs),
        picks_path: Some(dir.path().join("picks.json")),
        ..HubDeps::new(btx, trx)
    });
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let mut state = McpSharedState::for_test(event_tx);
    state.work_hub = Some(hub.clone());

    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(left, waiter.recv()).await.expect("hub never published todos") {
            Ok(ServerMsg::WorkSnapshot { source: WorkSource::Todos, items, .. }) if items.len() == n => break,
            _ => continue,
        }
    }
    while hub.status(WorkSource::RepoDocs).state == SourceState::Loading {
        assert!(tokio::time::Instant::now() < deadline + Duration::from_secs(25), "repo docs never settled");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Rig { state, hub, _brx: brx, _ttx: ttx, _dir: dir }
}

fn three_todos_with_first(first: TeriTodo) -> Vec<TeriTodo> {
    vec![
        first,
        todo(2, "Fix payment webhook".into(), None, None),
        todo(3, "Book travel".into(), None, None),
    ]
}

fn tool_json(result: ToolResult) -> Value {
    match result {
        ToolResult::Ok(content) => serde_json::from_str(content[0]["text"].as_str().expect("text")).expect("JSON text"),
        ToolResult::Forbidden(name) => panic!("tool {name} is forbidden"),
        ToolResult::UnknownTool(name) => panic!("unknown tool {name}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_title_loses_every_invisible_code_point_in_the_list_and_keeps_the_visible_text() {
    let rig = rig(three_todos_with_first(todo(1, hostile("Hello", "World"), None, None))).await;

    let result = list_work_items(&rig.state, &json!({"source": "todos"}));

    let nonce = fence_scan::assert_list_is_safe(&result);
    let titles = fence_scan::fenced_values(&result, &nonce);
    assert!(titles.iter().any(|t| t == "HelloWorld"), "{titles:?}");
    for t in &titles {
        assert!(survivors(t).is_empty(), "{:?} survived in {t:?}", survivors(t));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ordinary_visible_text_and_emoji_survive_in_a_list_title() {
    let rig = rig(three_todos_with_first(todo(1, format!("{VISIBLE} \u{2705}\u{FE0F}"), None, None))).await;

    let result = list_work_items(&rig.state, &json!({"source": "todos"}));

    let nonce = fence_scan::assert_list_is_safe(&result);
    let titles = fence_scan::fenced_values(&result, &nonce);
    assert!(titles.iter().any(|t| *t == format!("{VISIBLE} \u{2705}")), "the base emoji stays, its variation selector goes: {titles:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_detail_loses_every_invisible_code_point_from_its_title_fields_and_body() {
    let rig = rig(three_todos_with_first(todo(
        1,
        hostile("Hello", "World"),
        Some(hostile("2026-10-12", "")),
        Some(hostile("Body ", "text\n\nsecond paragraph")),
    )))
    .await;

    let d = get_work_item(&rig.state, &json!({"id": "todo:1"})).await;

    let detail = fence_scan::assert_detail_is_safe(&d);
    assert!(detail.header.starts_with("Title: HelloWorld"), "{}", detail.header);
    assert!(detail.header.lines().any(|l| l.starts_with("- Due: 2026-10-12")), "{}", detail.header);
    assert_eq!(detail.body, "Body text\n\nsecond paragraph");
    assert!(survivors(&detail.between).is_empty(), "{:?}", survivors(&detail.between));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ordinary_visible_text_and_emoji_survive_in_a_detail_body() {
    let rig = rig(three_todos_with_first(todo(1, "Plain".into(), None, Some(format!("{VISIBLE} \u{2705}\u{FE0F}\nsecond line"))))).await;

    let d = get_work_item(&rig.state, &json!({"id": "todo:1"})).await;

    let detail = fence_scan::assert_detail_is_safe(&d);
    assert_eq!(detail.body, format!("{VISIBLE} \u{2705}\nsecond line"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_published_reason_is_stored_and_read_back_without_any_of_them() {
    let rig = rig(three_todos_with_first(todo(1, "Write the report".into(), None, None))).await;
    let args = json!({"picks": [
        {"item_id": "todo:1", "reason": hostile("Hello", "World")},
        {"item_id": "todo:2", "reason": format!("{VISIBLE} \u{2705}\u{FE0F}")},
        {"item_id": "todo:3", "reason": "Plain reason"},
    ]});

    let out = publish_picks(&rig.state, &args);

    assert_eq!(out["ok"], true, "{out}");
    assert_eq!(out["picks"]["items"][0]["reason"], "HelloWorld");
    assert_eq!(out["picks"]["items"][1]["reason"], format!("{VISIBLE} \u{2705}"));
    let got = tool_json(dispatch("teri.get_picks", None, &rig.state, None).await);
    let nonce = fence_scan::assert_list_is_safe(&got);
    let reasons = fence_scan::fenced_values(&got, &nonce);
    assert!(reasons.iter().any(|r| r == "HelloWorld"), "{reasons:?}");
    assert!(reasons.iter().all(|r| survivors(r).is_empty()), "{reasons:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hub_title_full_of_them_becomes_a_clean_picks_title() {
    let rig = rig(three_todos_with_first(todo(1, hostile("Hello", "World"), None, None))).await;

    let snap = rig
        .hub
        .publish_picks(&[
            nostromo::data::work::picks::PickEntry { item_id: "todo:1".into(), reason: "first".into() },
            nostromo::data::work::picks::PickEntry { item_id: "todo:2".into(), reason: "second".into() },
            nostromo::data::work::picks::PickEntry { item_id: "todo:3".into(), reason: "third".into() },
        ])
        .unwrap();

    assert_eq!(snap.items[0].title, "HelloWorld");
}
