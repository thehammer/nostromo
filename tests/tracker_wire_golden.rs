//! Golden wire frames for the tracker (slice T0b, contract §5 and §12).
//!
//! `tests/fixtures/tracker/frame-tracker-board.json` and
//! `frame-tracker-summary.json` are the exact bytes serde produces for a
//! `tracker_board` frame built from `board-60.md` and the matching
//! `tracker_summary`. The NostromoKit decode tests read the same files, so they
//! are never edited by hand: after an intended change to the wire shape,
//! regenerate them with
//!
//!   UPDATE_GOLDEN=1 cargo test --test tracker_wire_golden
//!
//! and review the diff (the Swift side must still decode them).
//!
//! Everything is fixed: the board comes from the fixture, the facts are
//! constants (no clock, no file system), so the output is reproducible.

use std::path::PathBuf;

use nostromo::ipc::protocol::ServerMsg;
use nostromo::tracker::view::{build, ViewNode};
use nostromo::tracker::{parse, ParsedBoard, ViewFacts};

const TAG: &str = "cody-fixture";
const BOARD_FRAME: &str = "frame-tracker-board.json";
const SUMMARY_FRAME: &str = "frame-tracker-summary.json";

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/tracker")
        .join(name)
}

fn board60_source() -> String {
    String::from_utf8(std::fs::read(fixture_path("board-60.md")).expect("board-60.md"))
        .expect("board-60.md is UTF-8")
}

fn parsed() -> ParsedBoard {
    parse(board60_source().as_bytes()).expect("board-60.md parses")
}

fn board_frame() -> ServerMsg {
    let parsed = parsed();
    let view = build(
        &parsed,
        &ViewFacts {
            path: "/repo/.claude/wip/sentry-triage/index.md".into(),
            topic: "sentry-triage".into(),
            version: 7,
            file_mtime: None,
            banner: None,
            committable: None,
            hidden_by_user: false,
        },
    );
    ServerMsg::TrackerBoard {
        tag: TAG.into(),
        board: Some(view),
    }
}

fn summary_frame() -> ServerMsg {
    ServerMsg::TrackerSummary {
        tag: TAG.into(),
        has_tracker: true,
        counts: parsed().board.counts(),
    }
}

/// Pretty JSON with a trailing newline: the committed form.
fn rendered(msg: &ServerMsg) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

/// Compares `msg`'s rendering with the committed file, or writes the file when
/// `UPDATE_GOLDEN=1`.
fn check_golden(name: &str, msg: &ServerMsg) {
    let want = rendered(msg);
    let path = fixture_path(name);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::write(&path, &want).unwrap_or_else(|e| panic!("write {path:?}: {e}"));
        return;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{path:?} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test tracker_wire_golden")
    });
    assert!(
        have == want,
        "{name} no longer matches what the daemon serialises. If the wire change is intended, \
         regenerate with UPDATE_GOLDEN=1 cargo test --test tracker_wire_golden and check the \
         Swift decode tests still pass.\n--- committed ({} bytes) vs produced ({} bytes)",
        have.len(),
        want.len()
    );
}

#[test]
fn the_tracker_board_frame_of_the_sixty_item_board_matches_the_committed_golden_file_byte_for_byte()
{
    check_golden(BOARD_FRAME, &board_frame());
}

#[test]
fn the_tracker_summary_frame_of_the_sixty_item_board_matches_the_committed_golden_file_byte_for_byte(
) {
    check_golden(SUMMARY_FRAME, &summary_frame());
}

#[test]
fn the_golden_board_frame_decodes_back_to_the_same_frame() {
    let text = std::fs::read_to_string(fixture_path(BOARD_FRAME)).expect("golden board frame");
    let msg: ServerMsg =
        serde_json::from_str(&text).expect("the golden frame decodes as a ServerMsg");
    match &msg {
        ServerMsg::TrackerBoard {
            tag,
            board: Some(board),
        } => {
            assert_eq!(tag, TAG);
            assert_eq!(board.version, 7);
            assert_eq!(board.title, "Synthetic release triage");
            assert_eq!(board.path, "/repo/.claude/wip/sentry-triage/index.md");
            assert_eq!(board.banner, None);
            assert!(
                board.updated_at.is_some(),
                "the board's updated time comes from its items"
            );
            let items = board
                .nodes
                .iter()
                .filter(|n| matches!(n, ViewNode::Item(_)))
                .count();
            assert_eq!(items, 60);
        }
        other => panic!("expected a tracker_board frame with a board, got {other:?}"),
    }
    assert_eq!(
        rendered(&msg),
        text,
        "decode then encode reproduces the file"
    );
}

#[test]
fn the_golden_summary_frame_decodes_back_to_the_same_frame() {
    let text = std::fs::read_to_string(fixture_path(SUMMARY_FRAME)).expect("golden summary frame");
    let msg: ServerMsg =
        serde_json::from_str(&text).expect("the golden frame decodes as a ServerMsg");
    match &msg {
        ServerMsg::TrackerSummary {
            tag,
            has_tracker,
            counts,
        } => {
            assert_eq!(tag, TAG);
            assert!(*has_tracker);
            assert_eq!(
                counts.todo + counts.in_progress + counts.blocked + counts.needs_you + counts.done,
                60
            );
            assert_eq!(*counts, parsed().board.counts());
        }
        other => panic!("expected a tracker_summary frame, got {other:?}"),
    }
    assert_eq!(rendered(&msg), text);
}

#[test]
fn the_golden_board_frame_shows_every_node_kind_the_clients_must_decode() {
    let text = std::fs::read_to_string(fixture_path(BOARD_FRAME)).expect("golden board frame");
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "tracker_board");
    let kinds: std::collections::BTreeSet<&str> = value["board"]["nodes"]
        .as_array()
        .expect("nodes")
        .iter()
        .map(|n| n["type"].as_str().expect("node type"))
        .collect();
    for kind in [
        "title",
        "section",
        "log_heading",
        "prose",
        "item",
        "log_line",
    ] {
        assert!(
            kinds.contains(kind),
            "the golden board has no `{kind}` node: {kinds:?}"
        );
    }
    // A command item (with its command) and a link are in the fixture, so the
    // clients' decoders see those keys too.
    let items: Vec<&serde_json::Value> = value["board"]["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["type"] == "item")
        .collect();
    assert!(items
        .iter()
        .any(|i| i["kind"] == "command" && i["command"].is_string()));
    assert!(items
        .iter()
        .any(|i| i["links"].as_array().is_some_and(|l| !l.is_empty())));
    assert!(items.iter().any(|i| i["owner"].is_string()));

    let summary: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(fixture_path(SUMMARY_FRAME)).unwrap())
            .unwrap();
    assert_eq!(summary["type"], "tracker_summary");
    let mut keys: Vec<&str> = summary
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["counts", "has_tracker", "tag", "type"]);
}

#[test]
fn joining_every_nodes_source_reproduces_the_board_file() {
    let ServerMsg::TrackerBoard {
        board: Some(board), ..
    } = board_frame()
    else {
        panic!("a board frame")
    };
    let joined: String = board.nodes.iter().map(ViewNode::source).collect();
    assert_eq!(
        joined,
        board60_source(),
        "Copy as Markdown is the file's own text"
    );
}
