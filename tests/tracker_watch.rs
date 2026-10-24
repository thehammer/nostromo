//! File watching and attribution (slice T0b, PRD 7 daemon half, contract §3.1).
//!
//! The logic tests are deterministic: the test edits the board file through the
//! file system and tells the registry about it with
//! `TrackerRegistry::ingest_file_change(path)` followed by `flush`, exactly what
//! the watcher task does on a signal, so no FSEvents timing is involved. One
//! test at the bottom runs the real watcher (`start_watching`) against a real
//! temp directory with a generous timeout.
//!
//! Hermetic: a `FakeClock`, temp dirs for the repo, state root and home, no git
//! repo (so no subprocess), no real `~/.nostromo`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::protocol::ServerMsg;
use nostromo::tracker::view::{Banner, ViewItem, ViewNode};
use nostromo::tracker::{
    Author, FakeClock, Op, OpenArgs, ReadOutcome, RegistryParts, TrackerBoardView, TrackerRegistry,
    Upsert,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const WRITER: &str = "tag-w";
const WRITER_SESSION: &str = "sess-w";
const READER: &str = "tag-r";
const READER_SESSION: &str = "sess-r";
const FILE_LABEL: &str = "file (unknown editor)";

struct Rig {
    _tmp: TempDir,
    path: PathBuf,
    reg: Arc<TrackerRegistry>,
    tx: broadcast::Sender<ServerMsg>,
    rx: Mutex<broadcast::Receiver<ServerMsg>>,
}

fn writer() -> Author {
    Author::Agent {
        focus: WRITER.into(),
        session_id: WRITER_SESSION.into(),
        name: WRITER.into(),
    }
}

fn upsert(id: &str, section: &str, text: &str) -> Op {
    Op::Upsert(Upsert {
        id: Some(id.into()),
        section: Some(section.into()),
        text: Some(text.into()),
        ..Default::default()
    })
}

impl Rig {
    /// A board `watch` with four items, bound to a writer focus and a reader
    /// focus (two Claude sessions on one board).
    fn new() -> Rig {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let reg = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            base.join("state"),
            home,
            Arc::new(FakeClock::at_secs(1_760_540_000)),
        )));
        let args = OpenArgs {
            topic: Some("watch".into()),
            cwd: repo,
            ..Default::default()
        };
        let mut path = None;
        for (tag, session) in [(WRITER, WRITER_SESSION), (READER, READER_SESSION)] {
            path = Some(reg.open(tag, session, &args).expect("open").path);
        }
        let (tx, rx) = broadcast::channel(4096);
        let rig = Rig {
            _tmp: tmp,
            path: path.unwrap(),
            reg,
            tx,
            rx: Mutex::new(rx),
        };
        rig.reg
            .apply(
                WRITER,
                WRITER_SESSION,
                &[
                    upsert("alpha", "now", "Alpha task"),
                    upsert("beta", "now", "Beta task"),
                    upsert("gamma", "next", "Gamma task"),
                    upsert("delta", "next", "Delta task"),
                ],
                &writer(),
            )
            .expect("seed");
        rig.sync_reader();
        rig.reg.flush(&rig.tx);
        rig.drain();
        rig
    }

    fn text(&self) -> String {
        String::from_utf8(std::fs::read(&self.path).unwrap()).unwrap()
    }

    /// Reads (and so advances the cursor of) the reader session.
    fn sync_reader(&self) {
        let _ = self.reg.read(READER, READER_SESSION).expect("read");
    }

    fn reader_changes(&self) -> Vec<Value> {
        match self.reg.read(READER, READER_SESSION).expect("read") {
            ReadOutcome::Delta { changes, .. } => changes,
            ReadOutcome::Full { .. } => panic!("the reader has a cursor: expected a delta"),
        }
    }

    fn drain(&self) -> Vec<ServerMsg> {
        let mut rx = self.rx.lock().unwrap();
        let mut out = Vec::new();
        while let Ok(m) = rx.try_recv() {
            out.push(m);
        }
        out
    }

    /// An editor saves `edit(current text)` over the board and the watcher
    /// fires: returns the frames broadcast as a result.
    fn external_edit(&self, edit: impl FnOnce(&str) -> String) -> Vec<ServerMsg> {
        let before = self.text();
        let after = edit(&before);
        assert_ne!(before, after, "the test's edit must change the file");
        std::fs::write(&self.path, after).unwrap();
        assert!(
            self.reg.ingest_file_change(&self.path),
            "an external edit must be noticed"
        );
        self.reg.flush(&self.tx);
        self.drain()
    }
}

/// The last board the frames carried for `tag`.
fn board_in(frames: &[ServerMsg], tag: &str) -> TrackerBoardView {
    frames
        .iter()
        .rev()
        .find_map(|m| match m {
            ServerMsg::TrackerBoard {
                tag: t,
                board: Some(b),
            } if t == tag => Some(b.clone()),
            _ => None,
        })
        .unwrap_or_else(|| panic!("no tracker_board frame with a board for {tag}: {frames:?}"))
}

fn item<'a>(view: &'a TrackerBoardView, id: &str) -> Option<&'a ViewItem> {
    view.nodes.iter().find_map(|n| match n {
        ViewNode::Item(i) if i.id == id => Some(i),
        _ => None,
    })
}

fn item_with_text<'a>(view: &'a TrackerBoardView, text: &str) -> Option<&'a ViewItem> {
    view.nodes.iter().find_map(|n| match n {
        ViewNode::Item(i) if format!("{:?}", i.text_spans).contains(text) => Some(i),
        _ => None,
    })
}

/// `text` with the line containing `needle` replaced by `f(line)`.
fn map_line(text: &str, needle: &str, f: impl Fn(&str) -> String) -> String {
    let mut found = false;
    let out: Vec<String> = text
        .split('\n')
        .map(|l| {
            if l.contains(needle) {
                found = true;
                f(l)
            } else {
                l.to_string()
            }
        })
        .collect();
    assert!(found, "no line contains {needle:?} in:\n{text}");
    out.join("\n")
}

fn line_with<'a>(text: &'a str, needle: &str) -> &'a str {
    text.split('\n')
        .find(|l| l.contains(needle))
        .unwrap_or_else(|| panic!("no line contains {needle:?}"))
}

/// Every change in `changes` is attributed to the file.
fn assert_all_by_file(changes: &[Value]) {
    assert!(!changes.is_empty());
    for c in changes {
        assert_eq!(c["by"], json!(FILE_LABEL), "{c}");
    }
}

// ---------------------------------------------------------------------------
// External edits: tick, new line, text change, move, delete
// ---------------------------------------------------------------------------

#[test]
fn ticking_an_item_in_an_editor_is_broadcast_and_read_as_a_file_change() {
    let rig = Rig::new();
    let version_before = board_in(&rig.reg.frames_for_tag(READER), READER).version;

    let frames =
        rig.external_edit(|t| map_line(t, "#alpha ", |l| l.replacen("- [ ] ", "- [x] ", 1)));

    for tag in [READER, WRITER] {
        let view = board_in(&frames, tag);
        assert!(view.version > version_before, "{tag}: the version moves on");
        let alpha = item(&view, "alpha").expect("alpha is still there");
        assert_eq!(
            format!("{:?}", alpha.status),
            "Done",
            "{tag}: the pane shows it done"
        );
        assert_eq!(
            format!("{:?}", item(&view, "beta").unwrap().status),
            "Todo",
            "{tag}"
        );
    }
    let summary = frames
        .iter()
        .rev()
        .find_map(|m| match m {
            ServerMsg::TrackerSummary { tag, counts, .. } if tag == READER => Some(*counts),
            _ => None,
        })
        .expect("a tracker_summary for the reader's focus");
    assert_eq!((summary.done, summary.todo), (1, 3));

    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("alpha"));
    assert_eq!(changes[0]["status"], json!(["todo", "done"]));
}

#[test]
fn a_line_typed_into_the_file_appears_in_the_view_and_reads_as_an_added_item() {
    let rig = Rig::new();

    let frames = rig.external_edit(|t| {
        t.replacen(
            line_with(t, "#beta "),
            &format!("{}\n- [ ] Human typed this", line_with(t, "#beta ")),
            1,
        )
    });

    let view = board_in(&frames, READER);
    let added = item_with_text(&view, "Human typed this").expect("the new line is on the board");
    assert_eq!(added.section, "now");
    assert_eq!(format!("{:?}", added.status), "Todo");

    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(
        changes[0]["added"]["text"],
        json!("Human typed this"),
        "{changes:?}"
    );
    assert_eq!(changes[0]["added"]["section"], json!("now"), "{changes:?}");
}

#[test]
fn editing_an_items_text_in_the_file_reads_as_a_text_change() {
    let rig = Rig::new();

    let frames = rig.external_edit(|t| t.replace("Gamma task", "Gamma task, reworded by hand"));

    let view = board_in(&frames, READER);
    assert!(
        item_with_text(&view, "Gamma task, reworded by hand").is_some_and(|i| i.id == "gamma"),
        "the pane shows the new text on the same item"
    );
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("gamma"));
    assert_eq!(
        changes[0]["text"],
        json!(["Gamma task", "Gamma task, reworded by hand"])
    );
}

#[test]
fn moving_an_items_line_to_another_section_reads_as_a_move() {
    let rig = Rig::new();

    let frames = rig.external_edit(|t| {
        let gamma = line_with(t, "#gamma ").to_string();
        let without = t.replacen(&format!("{gamma}\n"), "", 1);
        let alpha = line_with(&without, "#alpha ").to_string();
        without.replacen(&alpha, &format!("{alpha}\n{gamma}"), 1)
    });

    let view = board_in(&frames, READER);
    assert_eq!(item(&view, "gamma").expect("gamma").section, "now");
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("gamma"));
    assert_eq!(changes[0]["moved"], json!(["next", "now"]));
}

#[test]
fn deleting_an_items_line_from_the_file_removes_it_from_the_view_and_reads_as_removed() {
    let rig = Rig::new();

    let frames = rig.external_edit(|t| {
        let beta = line_with(t, "#beta ").to_string();
        t.replacen(&format!("{beta}\n"), "", 1)
    });

    let view = board_in(&frames, READER);
    assert!(item(&view, "beta").is_none(), "beta is gone from the pane");
    assert!(item(&view, "alpha").is_some() && item(&view, "gamma").is_some());
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("beta"));
    assert_eq!(changes[0]["removed"], json!("Beta task"));
}

#[test]
fn an_edit_to_the_free_prose_reaches_the_pane_without_inventing_item_changes() {
    let rig = Rig::new();

    let frames = rig
        .external_edit(|t| t.replacen("## Now", "Remember to ask about the rollout.\n\n## Now", 1));

    let view = board_in(&frames, READER);
    assert!(
        view.nodes.iter().any(|n| matches!(n, ViewNode::Prose { source, .. } if source.contains("ask about the rollout"))),
        "the prose is on the pane"
    );
    let changes = rig.reader_changes();
    assert!(
        changes.iter().all(|c| c.get("id").is_none()),
        "no item changed: {changes:?}"
    );
}

#[test]
fn several_external_edits_each_read_as_their_own_file_change_in_order() {
    let rig = Rig::new();

    rig.external_edit(|t| map_line(t, "#alpha ", |l| l.replacen("- [ ] ", "- [x] ", 1)));
    rig.external_edit(|t| t.replace("Delta task", "Delta task v2"));

    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 2, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("alpha"));
    assert_eq!(changes[1]["id"], json!("delta"));
}

// ---------------------------------------------------------------------------
// The daemon's own writes are not external edits
// ---------------------------------------------------------------------------

#[test]
fn the_daemons_own_write_produces_no_file_change() {
    let rig = Rig::new();

    rig.reg
        .apply(
            WRITER,
            WRITER_SESSION,
            &[Op::Status {
                id: "alpha".into(),
                status: "in-progress".into(),
            }],
            &writer(),
        )
        .expect("write");
    rig.reg.flush(&rig.tx);
    rig.drain();

    // The watcher fires for the daemon's own rename.
    assert!(
        !rig.reg.ingest_file_change(&rig.path),
        "the daemon's own bytes are not an external edit"
    );
    rig.reg.flush(&rig.tx);
    assert!(rig.drain().is_empty(), "nothing new to tell the clients");

    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert!(
        changes[0]["by"]
            .as_str()
            .is_some_and(|b| b.starts_with("agent ")),
        "only the agent's own authorship is recorded: {changes:?}"
    );
    assert!(
        !changes.iter().any(|c| c["by"] == json!(FILE_LABEL)),
        "{changes:?}"
    );
}

#[test]
fn a_file_signal_with_unchanged_bytes_changes_nothing() {
    let rig = Rig::new();
    assert!(!rig.reg.ingest_file_change(&rig.path));
    rig.reg.flush(&rig.tx);
    assert!(rig.drain().is_empty());
    assert_eq!(rig.reader_changes(), Vec::<Value>::new());
}

// ---------------------------------------------------------------------------
// Delete and recreate
// ---------------------------------------------------------------------------

#[test]
fn deleting_the_file_shows_a_missing_banner_and_putting_the_same_content_back_clears_it() {
    let rig = Rig::new();
    let bytes = std::fs::read(&rig.path).unwrap();
    let nodes_before = board_in(&rig.reg.frames_for_tag(READER), READER).nodes;

    std::fs::remove_file(&rig.path).unwrap();
    assert!(rig.reg.ingest_file_change(&rig.path));
    rig.reg.flush(&rig.tx);
    let frames = rig.drain();
    let view = board_in(&frames, READER);
    assert!(
        matches!(view.banner, Some(Banner::Missing { .. })),
        "{:?}",
        view.banner
    );
    assert_eq!(view.nodes, nodes_before, "the pane keeps what it had");

    std::fs::write(&rig.path, &bytes).unwrap();
    assert!(rig.reg.ingest_file_change(&rig.path), "the banner clears");
    rig.reg.flush(&rig.tx);
    let view = board_in(&rig.drain(), READER);
    assert_eq!(view.banner, None);
    assert_eq!(view.nodes, nodes_before);
    assert_eq!(
        rig.reader_changes(),
        Vec::<Value>::new(),
        "restoring the same bytes is not an edit"
    );
}

#[test]
fn recreating_the_file_with_an_edit_clears_the_banner_and_reads_the_edit_as_a_file_change() {
    let rig = Rig::new();
    let bytes = rig.text();

    std::fs::remove_file(&rig.path).unwrap();
    assert!(rig.reg.ingest_file_change(&rig.path));
    rig.reg.flush(&rig.tx);
    rig.drain();

    std::fs::write(
        &rig.path,
        bytes.replace("Alpha task", "Alpha task, from a restored backup"),
    )
    .unwrap();
    assert!(rig.reg.ingest_file_change(&rig.path));
    rig.reg.flush(&rig.tx);
    let view = board_in(&rig.drain(), READER);

    assert_eq!(view.banner, None);
    assert!(item_with_text(&view, "from a restored backup").is_some_and(|i| i.id == "alpha"));
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
    assert_eq!(changes[0]["id"], json!("alpha"));
}

// ---------------------------------------------------------------------------
// Read-modify-write
// ---------------------------------------------------------------------------

#[test]
fn an_edit_made_just_before_an_agent_write_is_ingested_first_and_both_survive() {
    let rig = Rig::new();

    // The user ticks alpha in their editor; the watcher has not fired yet.
    let edited = map_line(&rig.text(), "#alpha ", |l| {
        l.replacen("- [ ] ", "- [x] ", 1)
    });
    std::fs::write(&rig.path, &edited).unwrap();

    // The agent changes beta in the meantime.
    let outcome = rig
        .reg
        .apply(
            WRITER,
            WRITER_SESSION,
            &[Op::Status {
                id: "beta".into(),
                status: "blocked".into(),
            }],
            &writer(),
        )
        .expect("the agent's write lands on top of the user's edit");

    let text = rig.text();
    assert!(
        line_with(&text, "#alpha ").starts_with("- [x] "),
        "the user's tick survives the agent's write:\n{text}"
    );
    assert!(
        line_with(&text, "#beta ").contains("blocked"),
        "the agent's change is in the file:\n{text}"
    );
    assert_eq!(
        outcome.user_changes, 1,
        "the writer is told the user changed something"
    );

    // Attribution: the tick is the file's, the status is the agent's.
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 2, "{changes:?}");
    assert_eq!(changes[0]["by"], json!(FILE_LABEL), "{changes:?}");
    assert_eq!(changes[0]["id"], json!("alpha"));
    assert!(
        changes[1]["by"]
            .as_str()
            .is_some_and(|b| b.starts_with("agent ")),
        "{changes:?}"
    );
    assert_eq!(changes[1]["id"], json!("beta"));

    // Both changes are in what the clients see.
    rig.reg.flush(&rig.tx);
    let view = board_in(&rig.drain(), READER);
    assert_eq!(
        format!("{:?}", item(&view, "alpha").unwrap().status),
        "Done"
    );
    assert_eq!(
        format!("{:?}", item(&view, "beta").unwrap().status),
        "Blocked"
    );
}

#[test]
fn an_agent_write_over_an_unreadable_edit_changes_nothing_and_keeps_the_users_bytes() {
    let rig = Rig::new();
    let garbled = rig.text().replace("<!-- #beta ", "<!-- #Bad_ID ");
    std::fs::write(&rig.path, &garbled).unwrap();

    let err = rig
        .reg
        .apply(
            WRITER,
            WRITER_SESSION,
            &[Op::Status {
                id: "alpha".into(),
                status: "done".into(),
            }],
            &writer(),
        )
        .expect_err("the board is unreadable");

    assert_eq!(err.code(), "board_unreadable");
    assert_eq!(
        rig.text(),
        garbled,
        "the user's bytes are never overwritten"
    );
}

// ---------------------------------------------------------------------------
// The real watcher
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn with_the_real_watcher_an_external_edit_is_broadcast_without_any_call_from_the_test() {
    let rig = Rig::new();
    rig.reg.start_watching(rig.tx.clone());
    let mut rx = rig.tx.subscribe();
    // Let the watcher task finish its initial pass and register with the OS, so
    // the edit below is noticed by the watcher proper (notify, debounce, stat
    // poll) and not by the first full read it does when it starts.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // The edit changes the file's length as well as its mtime.
    let before = rig.text();
    std::fs::write(
        &rig.path,
        before.replace("Delta task", "Delta task, edited while the watcher runs"),
    )
    .unwrap();

    let seen = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match rx.recv().await {
                Ok(ServerMsg::TrackerBoard {
                    tag,
                    board: Some(board),
                }) if tag == READER => {
                    if item_with_text(&board, "edited while the watcher runs").is_some() {
                        return board;
                    }
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => panic!("the broadcast channel closed"),
            }
        }
    })
    .await
    .expect("an external edit must be broadcast by the watcher within the timeout");

    assert_eq!(
        item_with_text(&seen, "edited while the watcher runs")
            .unwrap()
            .id,
        "delta"
    );
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_all_by_file(&changes);
}
