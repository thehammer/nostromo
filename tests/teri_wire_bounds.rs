//! Todo bodies are free text of any size. They must never push the legacy
//! `TeriState` frame past what a connection can carry:
//!
//! - `TeriTodosSnapshot::for_wire()` is what may go on the wire: every body is
//!   cut (on a character boundary) to `WIRE_BODY_MAX_BYTES`, and the whole
//!   serialized frame stays under `TERI_STATE_MAX_BYTES` (< `MAX_FRAME_LEN`).
//! - The SQL read caps what is kept in memory at `STORE_BODY_MAX_CHARS`.

use std::time::Duration;

use chrono::Utc;
use nostromo::data::teri_todos::{
    TeriTodo, TeriTodosNativeSource, TeriTodosSnapshot, STORE_BODY_MAX_CHARS, TERI_STATE_MAX_BYTES,
    WIRE_BODY_MAX_BYTES,
};
use nostromo::ipc::protocol::{ServerMsg, MAX_FRAME_LEN};
use rusqlite::Connection;

fn todo(id: i64, title: String, body: Option<String>) -> TeriTodo {
    TeriTodo {
        id,
        title,
        status: if id % 2 == 0 { "in_progress".into() } else { "open".into() },
        priority: (id % 5) as u8 + 1,
        due_date: Some("2026-10-20".into()),
        jira_key: Some(format!("CORE-{id}")),
        body,
    }
}

fn snapshot(items: Vec<TeriTodo>) -> TeriTodosSnapshot {
    TeriTodosSnapshot { generated_at: Some(Utc::now()), items, ..Default::default() }
}

/// A distinctive start (so a prefix check means something) then `filler`
/// repeated until the body is at least `bytes` long.
fn body_of(tag: usize, filler: &str, bytes: usize) -> String {
    let mut s = format!("body-of-todo-{tag}: ");
    while s.len() < bytes {
        s.push_str(filler);
    }
    s
}

fn frame_len(snap: TeriTodosSnapshot) -> usize {
    serde_json::to_vec(&ServerMsg::TeriState { todos: snap }).unwrap().len()
}

fn assert_bodies_bounded_and_faithful(original: &TeriTodosSnapshot, wire: &TeriTodosSnapshot) {
    assert_eq!(wire.items.len(), original.items.len(), "no todo may be dropped at this size");
    for (orig, got) in original.items.iter().zip(&wire.items) {
        assert_eq!(got.id, orig.id);
        assert_eq!(got.title, orig.title, "titles are untouched");
        assert_eq!(got.priority, orig.priority);
        assert_eq!(got.status, orig.status);
        assert_eq!(got.due_date, orig.due_date);
        assert_eq!(got.jira_key, orig.jira_key);
        let (orig_body, got_body) = (orig.body.as_deref().unwrap(), got.body.as_deref().unwrap());
        assert!(
            got_body.len() <= WIRE_BODY_MAX_BYTES,
            "wire body of todo {} is {} bytes, over the {WIRE_BODY_MAX_BYTES}-byte budget",
            got.id,
            got_body.len()
        );
        // (A `String` is valid UTF-8 by construction; a byte cut through a
        // multibyte char would have panicked or produced U+FFFD.)
        assert!(!got_body.contains('\u{FFFD}'), "a cut must not mangle characters");
        let head = |s: &str| s.chars().take(100).collect::<String>();
        assert_eq!(head(got_body), head(orig_body), "the wire body keeps the start of the original");
    }
}

#[test]
fn five_hundred_ten_kb_ascii_bodies_fit_the_legacy_frame_and_each_body_is_capped() {
    let original = snapshot(
        (1..=500).map(|i| todo(i, format!("Todo {i}"), Some(body_of(i as usize, "lorem ipsum ", 10 * 1024)))).collect(),
    );
    assert!(frame_len(original.clone()) > MAX_FRAME_LEN, "fixture must overflow a frame unbounded");

    let wire = original.for_wire();

    let len = frame_len(wire.clone());
    assert!(len < MAX_FRAME_LEN, "TeriState frame is {len} bytes, over MAX_FRAME_LEN {MAX_FRAME_LEN}");
    assert!(len <= TERI_STATE_MAX_BYTES, "TeriState frame is {len} bytes, over TERI_STATE_MAX_BYTES");
    assert_bodies_bounded_and_faithful(&original, &wire);
    assert_eq!(wire.generated_at, original.generated_at);
}

#[test]
fn multibyte_bodies_are_cut_on_a_character_boundary() {
    for filler in ["é", "日本語", "🦀🎉", "a🦀"] {
        let original = snapshot(
            (1..=500).map(|i| todo(i, format!("Todo {i}"), Some(body_of(i as usize, filler, 10 * 1024)))).collect(),
        );

        let wire = original.for_wire();

        let len = frame_len(wire.clone());
        assert!(len < MAX_FRAME_LEN, "{filler:?}: frame is {len} bytes");
        assert_bodies_bounded_and_faithful(&original, &wire);
    }
}

#[test]
fn bodies_under_the_cap_are_sent_unchanged() {
    let short = "Check the retry backoff in the worker.".to_string();
    let just_under = body_of(2, "é", WIRE_BODY_MAX_BYTES - 8);
    assert!(just_under.len() < WIRE_BODY_MAX_BYTES);
    let original = snapshot(vec![
        todo(1, "short".into(), Some(short)),
        todo(2, "just under".into(), Some(just_under)),
        todo(3, "empty".into(), Some(String::new())),
        todo(4, "none".into(), None),
    ]);

    let wire = original.for_wire();

    assert_eq!(wire.items, original.items, "nothing under the cap may be altered");
}

#[test]
fn for_wire_leaves_the_original_snapshot_alone() {
    let original = snapshot(vec![todo(1, "Big".into(), Some(body_of(1, "x", 50_000)))]);
    let before = original.items.clone();

    let _ = original.for_wire();

    assert_eq!(original.items, before, "the hub-side snapshot keeps the full body");
}

#[test]
fn an_enormous_snapshot_is_still_brought_under_the_limit_keeping_the_leading_todos() {
    // 5,000 todos, 4 KB bodies, 1 KB titles: even with every body dropped the
    // titles alone are over the limit, so items must be trimmed from the end.
    let original = snapshot(
        (1..=5000)
            .map(|i| todo(i, body_of(i as usize, "t", 1024), Some(body_of(i as usize, "b", 4096))))
            .collect(),
    );

    let wire = original.for_wire();

    let len = frame_len(wire.clone());
    assert!(len <= TERI_STATE_MAX_BYTES, "TeriState frame is {len} bytes, over TERI_STATE_MAX_BYTES");
    assert!(len < MAX_FRAME_LEN);
    assert!(!wire.items.is_empty(), "trimming keeps some todos");
    assert!(wire.items.len() < original.items.len(), "something had to give");
    let kept: Vec<i64> = wire.items.iter().map(|t| t.id).collect();
    let want: Vec<i64> = original.items.iter().take(kept.len()).map(|t| t.id).collect();
    assert_eq!(kept, want, "the kept todos are the leading ones, in the original order");
}

// ── the SQL read caps stored bodies ──────────────────────────────────────────

const TODOS_DDL: &str = "
CREATE TABLE todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT,
  status TEXT NOT NULL DEFAULT 'open', priority INTEGER NOT NULL DEFAULT 3,
  due_date TEXT, jira_key TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
  snoozed_until TEXT
);";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_huge_stored_body_is_capped_when_read_and_small_bodies_are_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("teri.db");
    let huge = body_of(1, "é", 200 * 1024); // 200 KB, ~100k characters
    assert!(huge.chars().count() > STORE_BODY_MAX_CHARS);
    let small = "A short note.".to_string();
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(TODOS_DDL).unwrap();
        for (title, body) in [("Huge", &huge), ("Small", &small)] {
            conn.execute("INSERT INTO todos (title, body, priority) VALUES (?1, ?2, ?3)", rusqlite::params![title, body, if title == "Huge" { 1 } else { 2 }])
                .unwrap();
        }
    }

    let mut rx = TeriTodosNativeSource::spawn_at(path);
    let snap = tokio::time::timeout(Duration::from_secs(5), rx.wait_for(|s| s.is_some()))
        .await
        .expect("a first snapshot within 5s")
        .unwrap()
        .clone()
        .unwrap();

    assert_eq!(snap.error, None, "{snap:?}");
    let by_title = |t: &str| snap.items.iter().find(|i| i.title == t).unwrap_or_else(|| panic!("{t} missing: {snap:?}"));
    let got = by_title("Huge").body.as_deref().expect("body present");
    let chars = got.chars().count();
    assert!(chars <= STORE_BODY_MAX_CHARS, "stored body is {chars} chars, over STORE_BODY_MAX_CHARS {STORE_BODY_MAX_CHARS}");
    assert!(got.starts_with("body-of-todo-1: éé"), "the kept part is the start of the body");
    assert_eq!(by_title("Small").body.as_deref(), Some(small.as_str()));
}
