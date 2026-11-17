//! The pane's board frame stays under the wire limit even in the worst case
//! (the frame carries raw `text`/`note`, every losing value of every conflict
//! and every removed item's markdown).

use nostromo::ipc::protocol::{ServerMsg, MAX_FRAME_LEN};
use nostromo::tracker::view::{build, ViewConflict, ViewRemovedConflict};
use nostromo::tracker::{parse, ViewFacts};

/// The board holds at most this many conflicts in all (field values and
/// removed items together).
const BOARD_CAP: usize = 50;

/// The frame for `board_md` with `fields` field conflicts (each a maximum-size
/// 8,000-character value of 3-byte characters) and `removed_n` removed items
/// (each 9,000 bytes of characters JSON escapes), plus the view it carries.
fn frame(
    board_md: &str,
    fields: usize,
    removed_n: usize,
) -> (usize, nostromo::tracker::TrackerBoardView) {
    assert!(fields + removed_n <= BOARD_CAP, "more than the board keeps");
    let parsed = parse(board_md.as_bytes()).expect("parses");
    let at = chrono::DateTime::from_timestamp(1_760_540_500, 0).unwrap();
    let ids: Vec<String> = parsed.board.items.iter().map(|i| i.id.clone()).collect();
    let mut conflicts: std::collections::HashMap<String, Vec<ViewConflict>> = Default::default();
    let mut removed = Vec::new();
    for (k, id) in ids.iter().take(fields).enumerate() {
        conflicts.insert(
            id.clone(),
            vec![ViewConflict {
                conflict_id: format!("7.{k}"),
                field: "note".into(),
                losing: "漢".repeat(8_000),
                losing_by: "agent claudia".into(),
                winning_by: "pane (you)".into(),
                at,
                index: 0,
            }],
        );
    }
    for k in 0..removed_n {
        removed.push(ViewRemovedConflict {
            conflict_id: format!("8.{k}"),
            item_id: format!("gone-{k}"),
            title: "x".repeat(500),
            losing_by: "pane (you)".into(),
            winning_by: "agent cody".into(),
            at,
            source: "\"\n".repeat(4_500),
        });
    }
    let view = build(
        &parsed,
        &ViewFacts {
            path: "/repo/.claude/wip/t/index.md".into(),
            topic: "t".into(),
            version: 1,
            file_mtime: None,
            banner: None,
            committable: None,
            hidden_by_user: false,
            bound: Default::default(),
            conflicts,
            removed_conflicts: removed,
            sensitive: Default::default(),
            dropped: Default::default(),
        },
    );
    let len = serde_json::to_vec(&ServerMsg::TrackerBoard {
        tag: "t".into(),
        board: Some(view.clone()),
    })
    .unwrap()
    .len();
    (len, view)
}

/// A board of `count` items of `text` (the format's whole-board cap is
/// 256 KiB and 500 items; these stay at both).
fn board_of(text: &str, count: usize) -> String {
    let mut md = String::from("# T\n\n## Now\n\n");
    for n in 0..count {
        md.push_str(&format!("- [ ] {text} <!-- #i{n:04} 1760540000 -->\n"));
    }
    md
}

/// A margin under the wire limit for the envelope and anything added later.
const MARGIN: usize = 150_000;

#[test]
fn the_worst_case_frame_on_a_maximum_size_board_fits_the_wire_with_margin() {
    // Markup-heavy text is what makes the rendered spans, the raw text and the
    // item's source add up the most. Every conflict is at its caps: the board
    // keeps 50 in all, so the worst frames hold 50 values of 8,000 characters,
    // 50 removed items of 9 KB, or a mix of both.
    let shapes = [
        ("plain", "plain words ".repeat(40)),
        ("bold", "**b** ".repeat(80)),
        ("code", "`c` ".repeat(120)),
        ("links", "[l](http://a.b) ".repeat(30)),
    ];
    for (name, text) in shapes {
        let md = board_of(&text, 500);
        assert!(md.len() <= 256 * 1024 + 1_024, "{name}: board {}", md.len());
        for (fields, removed) in [(BOARD_CAP, 0), (0, BOARD_CAP), (25, 25)] {
            let (len, _) = frame(&md, fields, removed);
            assert!(
                len < MAX_FRAME_LEN - MARGIN,
                "{name} with {fields} values and {removed} removed items: the frame is {len} bytes, the limit {MAX_FRAME_LEN}"
            );
        }
    }
}

#[test]
fn a_view_that_had_to_be_slimmed_says_so() {
    let md = board_of(&"**b** ".repeat(80), 500);
    let (_, view) = frame(&md, 25, 25);
    let trimmed = view.trimmed.expect("the worst case is slimmed");
    assert!(trimmed.conflict_values > 0, "{trimmed:?}");
    assert!(
        view.removed_conflicts
            .iter()
            .any(|r| r.source.contains("too large to show")),
        "a removed item's markdown that was left out says how long it was"
    );
}

#[test]
fn an_ordinary_board_with_conflicts_is_sent_whole() {
    let md = board_of("plain words", 20);
    let (len, view) = frame(&md, 3, 3);
    assert!(view.trimmed.is_none());
    assert!(len < 1_000_000);
    assert!(view
        .removed_conflicts
        .iter()
        .all(|r| r.source.len() == 9_000));
}
