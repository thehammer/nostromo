//! Behavioural tests for the tracker board engine (slice T0a).
//!
//! Everything goes through the public API (`nostromo::tracker::...`). The
//! board file format, op semantics, change log, renders and quoting rules are
//! specified in `.claude/plans/agent-tracker-pane-design-contract.md` (§2, §3,
//! §4, §7, §8, §12). No wall clock, no home directory: every instant is a
//! fixed `DateTime`, and the 300 KB "oversize" boards are generated here
//! rather than committed.
//!
//! Fixtures live in `tests/fixtures/tracker/` (synthetic data only).

use std::collections::HashSet;
use std::path::PathBuf;

use chrono::{DateTime, Duration, FixedOffset, TimeZone, Utc};
use regex::Regex;
use serde_json::{json, Value};

use nostromo::tracker::changelog::{MAX_CURSOR_SESSIONS, MAX_ENTRIES};
use nostromo::tracker::format::serialise_item;
use nostromo::tracker::ops::{LinkInput, MAX_BOARD_BYTES, MAX_ITEMS};
use nostromo::tracker::view::{self, ViewNode};
use nostromo::tracker::{
    apply_batch, apply_to_file, compact_full, delta_entries, diff, merge_external, parse,
    quote_untrusted, splice, template, validate_command_text, Author, Board, Change, ChangeKind,
    ChangeLog, CommandTextError, Cursors, Env, FakeClock, Item, Kind, Link, LinkKind, Malformed,
    MalformedReason, Op, OpError, ParsedBoard, Since, Stamp, Status, TrackerBoardView, Upsert,
    ViewFacts, WriteError,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/tracker")
        .join(name)
}

fn fixture_bytes(name: &str) -> Vec<u8> {
    std::fs::read(fixture_path(name)).unwrap_or_else(|e| panic!("read fixture {name}: {e}"))
}

fn fixture_str(name: &str) -> String {
    String::from_utf8(fixture_bytes(name)).unwrap_or_else(|e| panic!("fixture {name} utf8: {e}"))
}

fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, mo, d, h, mi, s).unwrap()
}

/// 2025-10-16 08:15:00 UTC: after every timestamp in the fixtures.
fn now0() -> DateTime<Utc> {
    utc(2025, 10, 16, 8, 15, 0)
}

fn stamp0() -> Stamp {
    Stamp::utc(now0())
}

fn india() -> FixedOffset {
    FixedOffset::east_opt(5 * 3600 + 30 * 60).unwrap()
}

fn agent() -> Author {
    agent_session("sess-a")
}

fn agent_session(session: &str) -> Author {
    Author::Agent {
        focus: "focus-1".into(),
        session_id: session.into(),
        name: "cody-a".into(),
    }
}

fn parse_ok(bytes: &[u8]) -> ParsedBoard {
    parse(bytes).unwrap_or_else(|e| panic!("expected a readable board, got {e}"))
}

fn board60() -> (String, ParsedBoard) {
    let src = fixture_str("board-60.md");
    let parsed = parse_ok(src.as_bytes());
    (src, parsed)
}

/// A board file from lines (LF endings, final newline).
fn md(lines: &[&str]) -> String {
    let mut s = lines.join("\n");
    s.push('\n');
    s
}

fn upsert(id: &str) -> Upsert {
    Upsert {
        id: Some(id.to_string()),
        ..Default::default()
    }
}

fn status_op(id: &str, status: &str) -> Op {
    Op::Status {
        id: id.to_string(),
        status: status.to_string(),
    }
}

fn ids_of(board: &Board) -> Vec<String> {
    board.items.iter().map(|i| i.id.clone()).collect()
}

fn find_item<'a>(board: &'a Board, pred: impl Fn(&Item) -> bool) -> &'a Item {
    board
        .items
        .iter()
        .find(|i| pred(i))
        .expect("fixture has an item matching the predicate")
}

fn item_by_text<'a>(board: &'a Board, text: &str) -> &'a Item {
    board
        .items
        .iter()
        .find(|i| i.text == text)
        .unwrap_or_else(|| panic!("no item with text {text:?}"))
}

fn apply_ok(board: &Board, ops: &[Op], author: &Author) -> (Board, Vec<Change>) {
    apply_batch(board, ops, author, stamp0()).unwrap_or_else(|e| panic!("batch refused: {e}"))
}

/// Contract §8 hermetic token proxy.
fn est_tokens(s: &str) -> usize {
    (s.len() as f64 / 2.5).ceil() as usize
}

fn assert_bytes_eq(actual: &[u8], expected: &[u8], ctx: &str) {
    if actual == expected {
        return;
    }
    let at = actual
        .iter()
        .zip(expected)
        .position(|(a, b)| a != b)
        .unwrap_or_else(|| actual.len().min(expected.len()));
    let snip = |b: &[u8]| {
        let lo = at.saturating_sub(40).min(b.len());
        let hi = (at + 40).min(b.len());
        String::from_utf8_lossy(&b[lo..hi]).into_owned()
    };
    panic!(
        "{ctx}: bytes differ at offset {at} (actual {} bytes, expected {} bytes)\n  actual:   {:?}\n  expected: {:?}",
        actual.len(),
        expected.len(),
        snip(actual),
        snip(expected),
    );
}

/// The bytes of the item span inside `out`, where `out` is `src` with the
/// span `old` replaced (everything outside is expected to be identical).
fn replaced_span<'a>(out: &'a str, src: &str, old: &std::ops::Range<usize>) -> &'a str {
    let tail = src.len() - old.end;
    &out[old.start..out.len() - tail]
}

fn same_fields(a: &Item, b: &Item) -> bool {
    let mut a = a.clone();
    let mut b = b.clone();
    a.updated_at = None;
    b.updated_at = None;
    a == b
}

/// A valid board of `items` canonical items in one section, each followed by
/// `note_lines` 100-character note lines, then a Log.
fn synthetic_board(items: usize, note_lines: usize) -> String {
    let mut s = String::from("# Big board\n\n## Now\n");
    for i in 0..items {
        let secs = 1_760_540_000 + i as i64;
        let hhmm = Utc.timestamp_opt(secs, 0).unwrap().format("%H:%M");
        s.push_str(&format!(
            "- [ ] Task number {i} — todo · {hhmm} <!-- #t-{i} {secs} -->\n"
        ));
        for _ in 0..note_lines {
            s.push_str("  ");
            s.push_str(&"n".repeat(100));
            s.push('\n');
        }
    }
    s.push_str("\n## Log\n- 09:00 started\n");
    s
}

/// A > 256 KiB board that is still well under the item cap.
fn oversize_bytes_board() -> String {
    let s = synthetic_board(100, 30);
    assert!(s.len() > MAX_BOARD_BYTES, "helper must exceed the byte cap");
    s
}

// ---------------------------------------------------------------------------
// Fixture sanity and parse rules (contract §2)
// ---------------------------------------------------------------------------

#[test]
fn board_60_fixture_has_sixty_items_in_six_sections_and_a_log() {
    let (src, parsed) = board60();
    let b = &parsed.board;
    assert_eq!(b.title.as_deref(), Some("Synthetic release triage"));
    assert_eq!(b.items.len(), 60);
    let titles: Vec<&str> = b.sections.iter().map(|s| s.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Now", "Next", "Waiting on you", "Done", "Findings", "Loose ends"]
    );
    let section_ids: Vec<&str> = b.sections.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(
        section_ids,
        ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"]
    );
    assert_eq!(b.log.len(), 12);
    assert_eq!(ids_of(b).iter().collect::<HashSet<_>>().len(), 60);
    assert!(src.ends_with('\n') && !src.contains('\r'));
    // Every status and a few command items are exercised.
    let counts = b.counts();
    assert!(counts.todo > 0 && counts.in_progress > 0 && counts.blocked > 0);
    assert!(counts.needs_you > 0 && counts.done > 0);
    assert_eq!(
        counts.todo + counts.in_progress + counts.blocked + counts.needs_you + counts.done,
        60
    );
    assert!(b.items.iter().filter(|i| i.kind == Kind::Command).count() >= 3);
}

#[test]
fn board_60_items_are_in_canonical_form_so_regenerating_them_is_byte_identical() {
    let (src, parsed) = board60();
    for item in &parsed.board.items {
        let at = item.updated_at.expect("every fixture item has a marker time");
        let regenerated = serialise_item(item, Stamp::utc(at), "\n");
        let span = parsed.item_span(&item.id).unwrap();
        assert_eq!(
            regenerated,
            &src[span],
            "item {} does not regenerate to its own bytes",
            item.id
        );
    }
}

#[test]
fn parse_reads_sections_title_log_and_duplicate_section_ids() {
    let b = parse_ok(
        md(&[
            "# My title",
            "",
            "## Now",
            "## Now",
            "## Waiting on you",
            "## LOG",
            "- 10:42 started",
        ])
        .as_bytes(),
    )
    .board;
    assert_eq!(b.title.as_deref(), Some("My title"));
    let ids: Vec<&str> = b.sections.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["now", "now-2", "waiting-on-you"]);
    assert_eq!(b.log.len(), 1, "## LOG (any case) is the Log, not a section");
    assert_eq!(b.log[0].time, "10:42");
    assert_eq!(b.log[0].text, "started");

    let untitled = parse_ok(md(&["## Now"]).as_bytes()).board;
    assert_eq!(untitled.title, None);
}

#[test]
fn checkbox_and_tail_decide_status_owner_env_and_text() {
    let src = md(&[
        "## Now",
        "- [x] Ship one — blocked · cody · 10:00 <!-- #a-1 1760540000 -->",
        "- [ ] Ship two — done · 10:00 <!-- #a-2 1760540000 -->",
        "- [ ] Ship three <!-- #a-3 1760540000 -->",
        "- [ ] Ship four — in progress · PROD · Oct 5 10:42 <!-- #a-4 1760540000 -->",
        "- [ ] Fix a — b thing — blocked · cody · 10:00 <!-- #a-5 1760540000 -->",
        "- [ ] Ship six — todo · prod · 10:00 <!-- #a-6 1760540000 -->",
        "- [ ] Ship seven — see notes · and the ticket <!-- #a-7 1760540000 -->",
        "- [ ] Ship eight — an owner token that is longer than thirty-two chars <!-- #a-8 1760540000 -->",
        "- [X] Ship nine — todo <!-- #a-9 1760540000 -->",
    ]);
    let b = parse_ok(src.as_bytes()).board;
    let get = |id: &str| b.item(id).unwrap_or_else(|| panic!("item {id}"));

    let a1 = get("a-1");
    assert_eq!((a1.status, a1.owner.as_deref()), (Status::Done, Some("cody")));
    assert_eq!(a1.text, "Ship one");
    assert_eq!(get("a-2").status, Status::Todo, "unticked 'done' is todo");
    assert_eq!(get("a-3").status, Status::Todo);
    assert_eq!(get("a-3").text, "Ship three");
    let a4 = get("a-4");
    assert_eq!(a4.status, Status::InProgress);
    assert_eq!(a4.env, Some(Env::Prod));
    assert_eq!(a4.text, "Ship four");
    assert_eq!(get("a-5").text, "Fix a — b thing", "only the last ' — ' starts the tail");
    assert_eq!(get("a-5").status, Status::Blocked);
    let a6 = get("a-6");
    assert_eq!((a6.owner.as_deref(), a6.env), (Some("prod"), None), "env tokens are exact case");
    let a7 = get("a-7");
    assert_eq!(a7.text, "Ship seven — see notes · and the ticket", "two owner tokens: not a tail");
    assert_eq!(a7.owner, None);
    assert_eq!(
        get("a-8").text,
        "Ship eight — an owner token that is longer than thirty-two chars"
    );
    assert_eq!(get("a-9").status, Status::Done);
}

#[test]
fn item_blocks_hold_command_note_links_and_swallow_indented_task_lines() {
    let src = md(&[
        "## Now",
        "- [ ] Retry job — needs you · PROD · 10:44 <!-- #cmd-1 1760540000 cmd -->",
        "  ```sh",
        "  php artisan queue:retry 8812",
        "  ```",
        "  A note line.",
        "    indented more",
        "  Links: [PR #253](https://github.com/o/r/pull/253) · CORE-2841 · Sentry PORTAL-1F2 · run 9912 · index.md:42",
        "- [ ] Plain item <!-- #plain-1 1760540000 -->",
        "  - [ ] indented task is part of the note",
    ]);
    let b = parse_ok(src.as_bytes()).board;
    assert_eq!(b.items.len(), 2, "an indented task line is never an item");
    let cmd = b.item("cmd-1").unwrap();
    assert_eq!(cmd.kind, Kind::Command);
    assert_eq!(cmd.command.as_deref(), Some("php artisan queue:retry 8812"));
    assert_eq!(cmd.env, Some(Env::Prod));
    assert_eq!(cmd.status, Status::NeedsYou);
    assert_eq!(cmd.note.as_deref(), Some("A note line.\n  indented more"));
    assert_eq!(cmd.links.len(), 5);
    assert_eq!(
        cmd.links[0],
        Link::new("PR #253", Some("https://github.com/o/r/pull/253"))
    );
    let kinds: Vec<LinkKind> = cmd.links.iter().map(|l| l.kind).collect();
    assert_eq!(
        kinds,
        [LinkKind::Pr, LinkKind::Jira, LinkKind::Sentry, LinkKind::Run, LinkKind::File]
    );
    assert_eq!(
        b.item("plain-1").unwrap().note.as_deref(),
        Some("- [ ] indented task is part of the note")
    );
}

// ---------------------------------------------------------------------------
// Round trip (PRD 4 groundwork)
// ---------------------------------------------------------------------------

#[test]
fn unchanged_board_splices_back_to_identical_bytes_for_every_readable_fixture() {
    for name in ["board-60.md", "handwritten.md", "prose-only.md"] {
        let bytes = fixture_bytes(name);
        let parsed = parse_ok(&bytes);
        let out = splice(&parsed, &parsed.board, stamp0(), false);
        assert_bytes_eq(&out, &bytes, name);
    }
}

#[test]
fn round_trip_holds_for_a_template_board_and_for_crlf_and_missing_final_newline() {
    let tpl = template("Round trip", &[]);
    let variants: Vec<(&str, Vec<u8>)> = vec![
        ("template", tpl.clone().into_bytes()),
        ("template CRLF", tpl.replace('\n', "\r\n").into_bytes()),
        ("template no final newline", tpl.trim_end_matches('\n').as_bytes().to_vec()),
        ("board-60 no final newline", fixture_str("board-60.md").trim_end().as_bytes().to_vec()),
    ];
    for (name, bytes) in variants {
        let parsed = parse_ok(&bytes);
        assert_bytes_eq(&splice(&parsed, &parsed.board, stamp0(), false), &bytes, name);
    }
}

#[test]
fn template_has_the_default_sections_and_no_items_and_custom_sections_are_used() {
    let parsed = parse_ok(template("Sentry triage", &[]).as_bytes());
    assert_eq!(parsed.board.title.as_deref(), Some("Sentry triage"));
    let titles: Vec<&str> = parsed.board.sections.iter().map(|s| s.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Now", "Next", "Waiting on you", "Done", "Findings", "Loose ends"]
    );
    assert!(parsed.board.items.is_empty());

    let custom = parse_ok(template("T", &["Alpha", "Beta"]).as_bytes());
    let ids: Vec<&str> = custom.board.sections.iter().map(|s| s.id.as_str()).collect();
    assert!(ids.contains(&"alpha") && ids.contains(&"beta"));
}

// ---------------------------------------------------------------------------
// Byte preservation (PRD 4)
// ---------------------------------------------------------------------------

#[test]
fn marking_an_item_done_changes_only_that_items_bytes() {
    let (src, parsed) = board60();
    let item = find_item(&parsed.board, |i| {
        i.note.is_some() && !i.links.is_empty() && i.kind == Kind::Item && i.status != Status::Done
    });
    let span = parsed.item_span(&item.id).unwrap();

    let applied = apply_to_file(
        src.as_bytes(),
        &[status_op(&item.id, "done")],
        &agent(),
        stamp0(),
    )
    .unwrap();
    let out = String::from_utf8(applied.bytes).unwrap();

    assert_eq!(&out[..span.start], &src[..span.start], "bytes before the item");
    assert!(out.ends_with(&src[span.end..]), "bytes after the item");

    let new_span = replaced_span(&out, &src, &span);
    let (new_first, new_rest) = new_span.split_once('\n').unwrap();
    let (_, old_rest) = src[span.clone()].split_once('\n').unwrap();
    assert_eq!(new_rest, old_rest, "note and links lines are untouched");
    assert!(
        new_first.starts_with(&format!("- [x] {} — done", item.text)),
        "got {new_first:?}"
    );
    assert!(
        new_first.ends_with(&format!(
            " · 08:15 <!-- #{} {} -->",
            item.id,
            now0().timestamp()
        )),
        "got {new_first:?}"
    );
    let reparsed = parse_ok(out.as_bytes());
    assert_eq!(reparsed.board.item(&item.id).unwrap().status, Status::Done);
}

#[test]
fn upserting_only_a_note_changes_only_that_items_bytes() {
    let (src, parsed) = board60();
    let item = find_item(&parsed.board, |i| {
        i.note.is_none() && !i.links.is_empty() && i.kind == Kind::Item
    });
    let span = parsed.item_span(&item.id).unwrap();
    let op = Op::Upsert(Upsert {
        note: Some("A fresh note".into()),
        ..upsert(&item.id)
    });

    let out = String::from_utf8(
        apply_to_file(src.as_bytes(), &[op], &agent(), stamp0())
            .unwrap()
            .bytes,
    )
    .unwrap();

    assert_eq!(&out[..span.start], &src[..span.start]);
    assert!(out.ends_with(&src[span.end..]));
    let new_span = replaced_span(&out, &src, &span);
    let new_lines: Vec<&str> = new_span.lines().collect();
    let old_lines: Vec<&str> = src[span.clone()].lines().collect();
    assert_eq!(new_lines.len(), old_lines.len() + 1);
    assert_eq!(new_lines[1], "  A fresh note");
    assert_eq!(new_lines[2..], old_lines[1..], "links line kept, after the note");
    assert_eq!(
        new_lines[0].rsplit_once(" · ").unwrap().0,
        old_lines[0].rsplit_once(" · ").unwrap().0,
        "status, owner and text are as before; only the time changes"
    );
    assert!(new_lines[0].contains("08:15 <!-- #"));
}

#[test]
fn logging_appends_one_line_at_the_end_and_touches_nothing_else() {
    let (src, _) = board60();
    let op = Op::Log {
        text: "Cody: deployed the fix".into(),
    };
    let out = apply_to_file(src.as_bytes(), &[op], &agent(), stamp0())
        .unwrap()
        .bytes;
    let expected = format!("{src}- 08:15 Cody: deployed the fix\n");
    assert_bytes_eq(&out, expected.as_bytes(), "log append");

    let reparsed = parse_ok(&out);
    assert_eq!(reparsed.board.log.len(), 13);
    assert_eq!(reparsed.board.log.last().unwrap().time, "08:15");
    assert_eq!(reparsed.board.log.last().unwrap().text, "Cody: deployed the fix");
}

#[test]
fn logging_into_a_file_without_a_final_newline_keeps_it_that_way() {
    let src = fixture_str("board-60.md");
    let src = src.trim_end_matches('\n');
    let op = Op::Log {
        text: "no trailing newline".into(),
    };
    let out = apply_to_file(src.as_bytes(), &[op], &agent(), stamp0())
        .unwrap()
        .bytes;
    assert!(out.starts_with(src.as_bytes()));
    assert!(!out.ends_with(b"\n"));
    let reparsed = parse_ok(&out);
    assert_eq!(reparsed.board.log.last().unwrap().text, "no trailing newline");
    assert_eq!(reparsed.board.log.len(), 13);
}

#[test]
fn removing_an_item_drops_exactly_its_bytes() {
    let (src, parsed) = board60();
    let id = parsed.board.items[7].id.clone();
    let span = parsed.item_span(&id).unwrap();
    let out = apply_to_file(
        src.as_bytes(),
        &[Op::Remove { id: id.clone() }],
        &agent(),
        stamp0(),
    )
    .unwrap()
    .bytes;
    let expected = format!("{}{}", &src[..span.start], &src[span.end..]);
    assert_bytes_eq(&out, expected.as_bytes(), "remove");
    assert!(parse_ok(&out).board.item(&id).is_none());
}

#[test]
fn an_empty_batch_on_a_fully_marked_board_changes_nothing() {
    let (src, _) = board60();
    let applied = apply_to_file(src.as_bytes(), &[], &agent(), stamp0()).unwrap();
    assert_bytes_eq(&applied.bytes, src.as_bytes(), "empty batch");
    assert!(applied.changes.is_empty());
}

#[test]
fn a_status_op_with_the_current_status_changes_nothing() {
    let (src, parsed) = board60();
    let item = find_item(&parsed.board, |i| i.status == Status::InProgress);
    let (board, changes) = apply_ok(
        &parsed.board,
        &[status_op(&item.id, "in-progress")],
        &agent(),
    );
    assert!(changes.is_empty(), "no change recorded: {changes:?}");
    assert_eq!(board.item(&item.id), parsed.board.item(&item.id));

    let applied = apply_to_file(
        src.as_bytes(),
        &[status_op(&item.id, "in-progress")],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert_bytes_eq(&applied.bytes, src.as_bytes(), "same status");
}

// ---------------------------------------------------------------------------
// Property test: random single-item edits (PRD 4)
// ---------------------------------------------------------------------------

/// xorshift64*: deterministic, no crates, no wall clock.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len())]
    }
}

const WORDS: [&str; 14] = [
    "check", "retry", "review", "draft", "close", "deploy", "audit", "queue", "cache", "report",
    "sync", "login", "staging", "invoice",
];
const OWNERS: [&str; 7] = ["cody", "me", "redd", "ada", "archie", "claudia", "pat"];

fn random_words(rng: &mut Rng, min: usize, max: usize) -> String {
    let n = min + rng.below(max - min + 1);
    let words: Vec<&str> = (0..n).map(|_| *rng.pick(&WORDS)).collect();
    let mut s = words.join(" ");
    s[..1].make_ascii_uppercase();
    s
}

/// One random edit of `orig`: the op, and the item as it should read after.
fn random_edit(rng: &mut Rng, orig: &Item) -> (Op, Item) {
    let mut expected = orig.clone();
    let mut up = upsert(&orig.id);
    let op = match rng.below(7) {
        0 | 1 => {
            let s = *rng.pick(&Status::ALL);
            expected.status = s;
            status_op(&orig.id, s.wire())
        }
        2 => {
            let t = random_words(rng, 2, 5);
            expected.text = t.clone();
            up.text = Some(t);
            Op::Upsert(up)
        }
        3 => {
            let o = if rng.below(4) == 0 {
                String::new()
            } else {
                rng.pick(&OWNERS).to_string()
            };
            expected.owner = (!o.is_empty()).then(|| o.clone());
            up.owner = Some(o);
            Op::Upsert(up)
        }
        4 => {
            let n = if rng.below(4) == 0 {
                String::new()
            } else {
                let lines = 1 + rng.below(2);
                let ls: Vec<String> = (0..lines).map(|_| random_words(rng, 2, 5)).collect();
                ls.join("\n")
            };
            expected.note = (!n.is_empty()).then(|| n.clone());
            up.note = Some(n);
            Op::Upsert(up)
        }
        5 => {
            let e = *rng.pick(&Env::ALL);
            if rng.below(4) == 0 {
                expected.env = None;
                up.env = Some(String::new());
            } else {
                expected.env = Some(e);
                up.env = Some(e.wire().to_string());
            }
            Op::Upsert(up)
        }
        _ => {
            let pool = [
                LinkInput::Text("PR #253".into()),
                LinkInput::Full {
                    text: "PR #254".into(),
                    url: Some("https://github.com/example/repo/pull/254".into()),
                },
                LinkInput::Text("CORE-2841".into()),
                LinkInput::Text("Sentry PORTAL-1F2".into()),
                LinkInput::Text("run 9912".into()),
                LinkInput::Text("index.md:42".into()),
            ];
            let n = rng.below(4);
            let links: Vec<LinkInput> = (0..n).map(|_| rng.pick(&pool).clone()).collect();
            expected.links = links
                .iter()
                .map(|l| match l {
                    LinkInput::Text(t) => Link::new(t, None),
                    LinkInput::Full { text, url } => Link::new(text, url.as_deref()),
                })
                .collect();
            up.links = Some(links);
            Op::Upsert(up)
        }
    };
    (op, expected)
}

#[test]
fn two_hundred_random_single_item_edits_never_touch_bytes_outside_the_item() {
    let mut src = fixture_str("board-60.md");
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut now = utc(2025, 10, 16, 8, 0, 0);
    let original_ids = ids_of(&parse_ok(src.as_bytes()).board);
    let mut real_changes = 0;

    for step in 0..200 {
        let parsed = parse_ok(src.as_bytes());
        let orig = parsed.board.items[rng.below(parsed.board.items.len())].clone();
        let (op, expected) = random_edit(&mut rng, &orig);
        now += Duration::seconds(61);
        let offset = if rng.below(2) == 0 {
            FixedOffset::east_opt(0).unwrap()
        } else {
            FixedOffset::west_opt(7 * 3600).unwrap()
        };
        let stamp = Stamp::new(now, offset);
        let ctx = format!("step {step}: {op:?} on {}", orig.id);

        let span = parsed.item_span(&orig.id).unwrap();
        let applied = apply_to_file(src.as_bytes(), &[op], &agent(), stamp)
            .unwrap_or_else(|e| panic!("{ctx}: refused: {e}"));
        let out = applied.bytes;

        assert_bytes_eq(&out[..span.start], &src.as_bytes()[..span.start], &format!("{ctx}: prefix"));
        assert!(
            out.len() >= span.start && out.ends_with(&src.as_bytes()[span.end..]),
            "{ctx}: suffix after the item changed"
        );

        let reparsed = parse_ok(&out);
        assert_eq!(ids_of(&reparsed.board), original_ids, "{ctx}: item order/ids");
        assert_eq!(reparsed.board.sections, parsed.board.sections, "{ctx}");
        assert_eq!(reparsed.board.prose, parsed.board.prose, "{ctx}");
        assert_eq!(reparsed.board.log, parsed.board.log, "{ctx}");
        assert_eq!(reparsed.board.title, parsed.board.title, "{ctx}");
        for (before, after) in parsed.board.items.iter().zip(&reparsed.board.items) {
            if before.id == orig.id {
                assert!(
                    same_fields(after, &expected),
                    "{ctx}:\n  got      {after:?}\n  expected {expected:?}"
                );
            } else {
                assert_eq!(before, after, "{ctx}: another item changed");
            }
        }

        if !same_fields(&orig, &expected) {
            real_changes += 1;
            let got = reparsed.board.item(&orig.id).unwrap();
            assert_eq!(got.updated_at, Some(now), "{ctx}: updated-at is the stamp");
            assert!(!applied.changes.is_empty(), "{ctx}: a change was recorded");
            let new_span = std::str::from_utf8(
                &out[span.start..out.len() - (src.len() - span.end)],
            )
            .unwrap();
            let first = new_span.lines().next().unwrap();
            let box_ = if expected.status == Status::Done { "- [x] " } else { "- [ ] " };
            assert!(first.starts_with(box_), "{ctx}: {first:?}");
            assert!(
                first.contains(&format!(
                    "{} <!-- #{} {}",
                    stamp.hhmm(now),
                    orig.id,
                    now.timestamp()
                )),
                "{ctx}: local time and marker in {first:?}"
            );
        }
        src = String::from_utf8(out).unwrap();
    }
    assert!(real_changes > 150, "generator should mostly make real edits: {real_changes}");
}

// ---------------------------------------------------------------------------
// Adoption of human-written boards (PRD 2)
// ---------------------------------------------------------------------------

fn is_adoptable_task_line(line: &str) -> bool {
    line.starts_with("- [ ] ") || line.starts_with("- [x] ") || line.starts_with("- [X] ")
}

#[test]
fn handwritten_fixture_is_crlf_without_a_final_newline_and_is_readable() {
    let bytes = fixture_bytes("handwritten.md");
    let text = String::from_utf8(bytes.clone()).unwrap();
    assert!(text.contains("\r\n"));
    assert!(!text.replace("\r\n", "").contains('\n'), "CRLF throughout");
    assert!(!text.ends_with('\n'));

    let b = parse_ok(&bytes).board;
    assert_eq!(b.items.len(), 10);
    assert_eq!(b.title.as_deref(), Some("Handwritten notes"));
    let rotate = item_by_text(&b, "Rotate keys");
    assert_eq!((rotate.status, rotate.owner.as_deref()), (Status::Blocked, Some("pat")));
    assert_eq!(item_by_text(&b, "Send the weekly update").status, Status::Done);
    assert!(b
        .items
        .iter()
        .any(|i| i.text.starts_with("Archive old logs") && i.status == Status::Done));
    // A trailing segment that is not a tail stays part of the text.
    assert_eq!(
        item_by_text(&b, "Fix flaky test — see notes · and the ticket").owner,
        None
    );
    assert!(b
        .items
        .iter()
        .any(|i| i.text.starts_with("Draft the postmortem — a very long trailing remark")));
    // The fenced fake item and the indented child are not items.
    assert!(!b.items.iter().any(|i| i.text.contains("not an item")));
    assert!(!b.items.iter().any(|i| i.text.contains("indented child task")));
    let parent = item_by_text(&b, "Parent task with a child");
    assert!(parent.note.as_deref().unwrap().contains("- [ ] indented child task"));
    // Markerless lines still get unique, valid ids.
    let id_re = Regex::new(r"^[a-z0-9][a-z0-9-]{0,31}$").unwrap();
    let ids = ids_of(&b);
    assert!(ids.iter().all(|i| id_re.is_match(i)), "{ids:?}");
    assert_eq!(ids.iter().collect::<HashSet<_>>().len(), ids.len());
    assert!(parse_ok(&bytes).item_spans.iter().all(|s| !s.has_marker));
}

#[test]
fn first_tracker_write_only_appends_markers_to_column_zero_task_lines() {
    let src = fixture_str("handwritten.md");
    let applied = apply_to_file(src.as_bytes(), &[], &agent(), stamp0()).unwrap();
    let out = String::from_utf8(applied.bytes.clone()).unwrap();

    assert!(!out.ends_with('\n'), "still no final newline");
    assert!(!out.replace("\r\n", "").contains('\n'), "still CRLF throughout");

    let marker_re = Regex::new(r"^ <!-- #([a-z0-9][a-z0-9-]{0,31}) (\d+) -->$").unwrap();
    let src_lines: Vec<&str> = src.split("\r\n").collect();
    let out_lines: Vec<&str> = out.split("\r\n").collect();
    assert_eq!(src_lines.len(), out_lines.len(), "no line added or removed");

    let mut in_fence = false;
    let mut assigned = Vec::new();
    for (before, after) in src_lines.iter().zip(&out_lines) {
        if before.starts_with("```") {
            in_fence = !in_fence;
        }
        if !in_fence && is_adoptable_task_line(before) {
            assert!(after.starts_with(before), "{after:?} keeps {before:?}");
            let caps = marker_re
                .captures(&after[before.len()..])
                .unwrap_or_else(|| panic!("marker on {after:?}"));
            assert_eq!(caps[2].parse::<i64>().unwrap(), now0().timestamp());
            assigned.push(caps[1].to_string());
        } else {
            assert_eq!(before, after, "only task lines may change");
        }
    }
    assert_eq!(assigned.len(), 10);
    assert_eq!(assigned.iter().collect::<HashSet<_>>().len(), 10, "ids are unique");

    // The markers are real: re-reading finds the same ids, and a second
    // adoption is a no-op.
    let reparsed = parse_ok(&applied.bytes);
    assert_eq!(ids_of(&reparsed.board), assigned);
    assert!(reparsed.item_spans.iter().all(|s| s.has_marker));
    let again = apply_to_file(&applied.bytes, &[], &agent(), stamp0()).unwrap();
    assert_bytes_eq(&again.bytes, &applied.bytes, "second adoption");
}

#[test]
fn changing_a_human_item_keeps_crlf_and_the_missing_final_newline() {
    let src = fixture_str("handwritten.md");
    let board = parse_ok(src.as_bytes()).board;
    let id = item_by_text(&board, "Call the vendor about the invoice").id.clone();
    let out = apply_to_file(
        src.as_bytes(),
        &[
            status_op(&id, "in-progress"),
            Op::Upsert(Upsert {
                note: Some("first line\nsecond line".into()),
                ..upsert(&id)
            }),
        ],
        &agent(),
        stamp0(),
    )
    .unwrap()
    .bytes;
    let text = String::from_utf8(out).unwrap();
    assert!(!text.replace("\r\n", "").contains('\n'), "every line ending is CRLF");
    assert!(!text.ends_with('\n'));
    assert!(text.contains("  first line\r\n  second line\r\n"));
    let reparsed = parse_ok(text.as_bytes());
    let item = reparsed.board.item(&id).unwrap();
    assert_eq!(item.status, Status::InProgress);
    assert_eq!(item.note.as_deref(), Some("first line\nsecond line"));
}

// ---------------------------------------------------------------------------
// Atomic batches (PRD 5) and op semantics
// ---------------------------------------------------------------------------

fn five_op_batch_with_unknown_id(parsed: &ParsedBoard) -> Vec<Op> {
    let known = &parsed.board.items;
    vec![
        status_op(&known[0].id, "done"),
        Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("Brand new".into()),
            ..upsert("brand-new")
        }),
        Op::Log {
            text: "halfway".into(),
        },
        status_op("no-such-item", "done"),
        Op::Remove {
            id: known[1].id.clone(),
        },
    ]
}

#[test]
fn a_batch_with_one_unknown_id_is_refused_whole_and_leaves_the_board_unchanged() {
    let (src, parsed) = board60();
    let ops = five_op_batch_with_unknown_id(&parsed);
    let before = parsed.board.clone();

    let err = apply_batch(&parsed.board, &ops, &agent(), stamp0()).unwrap_err();
    assert_eq!(
        err,
        OpError::UnknownItem {
            index: 3,
            id: "no-such-item".into()
        }
    );
    assert_eq!(err.code(), "unknown_item");
    assert_eq!(parsed.board, before, "the input board is untouched");

    let file_err = apply_to_file(src.as_bytes(), &ops, &agent(), stamp0()).unwrap_err();
    assert!(
        matches!(&file_err, WriteError::Op(OpError::UnknownItem { index: 3, .. })),
        "{file_err:?}"
    );
}

#[test]
fn ops_in_a_batch_apply_in_order_so_later_ops_can_use_earlier_ones() {
    let (_, parsed) = board60();
    let ops = [
        Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("Fresh".into()),
            ..upsert("fresh-1")
        }),
        status_op("fresh-1", "done"),
    ];
    let (board, changes) = apply_ok(&parsed.board, &ops, &agent());
    assert_eq!(board.item("fresh-1").unwrap().status, Status::Done);
    assert!(!changes.is_empty());
}

#[test]
fn a_bad_status_string_is_invalid_status_with_the_failing_index() {
    let (_, parsed) = board60();
    let id = parsed.board.items[0].id.clone();
    let err = apply_batch(
        &parsed.board,
        &[
            status_op(&id, "done"),
            Op::Log { text: "x".into() },
            status_op(&id, "bogus"),
        ],
        &agent(),
        stamp0(),
    )
    .unwrap_err();
    assert_eq!(
        err,
        OpError::InvalidStatus {
            index: 2,
            value: "bogus".into()
        }
    );
    assert_eq!(err.code(), "invalid_status");

    let via_upsert = apply_batch(
        &parsed.board,
        &[Op::Upsert(Upsert {
            status: Some("finished".into()),
            ..upsert(&id)
        })],
        &agent(),
        stamp0(),
    )
    .unwrap_err();
    assert_eq!(via_upsert.code(), "invalid_status");
}

#[test]
fn an_item_id_that_is_not_a_valid_id_is_invalid_args() {
    let (_, parsed) = board60();
    let err = apply_batch(
        &parsed.board,
        &[Op::Upsert(Upsert {
            text: Some("x".into()),
            section: Some("now".into()),
            ..upsert("Bad_ID")
        })],
        &agent(),
        stamp0(),
    )
    .unwrap_err();
    assert_eq!(err.code(), "invalid_args");
}

#[test]
fn upsert_on_an_unknown_id_creates_the_item_at_the_end_of_the_named_section() {
    let (_, parsed) = board60();
    let (board, changes) = apply_ok(
        &parsed.board,
        &[Op::Upsert(Upsert {
            section: Some("Waiting on you".into()),
            text: Some("Fresh waiting item".into()),
            ..upsert("fresh-1")
        })],
        &agent(),
    );
    let item = board.item("fresh-1").unwrap();
    assert_eq!(item.section, "waiting-on-you");
    assert_eq!(item.text, "Fresh waiting item");
    assert_eq!(item.status, Status::Todo);
    assert_eq!(item.updated_at, Some(now0()));
    let last_in_section = board
        .items
        .iter()
        .filter(|i| i.section == "waiting-on-you")
        .last()
        .unwrap();
    assert_eq!(last_in_section.id, "fresh-1");
    assert_eq!(board.items.len(), 61);

    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Added);
    assert_eq!(changes[0].item_id.as_deref(), Some("fresh-1"));
    assert_eq!(changes[0].by, agent());
    assert_eq!(changes[0].at, now0());
}

#[test]
fn upsert_without_a_section_goes_to_the_first_section() {
    let (_, parsed) = board60();
    let (board, _) = apply_ok(
        &parsed.board,
        &[Op::Upsert(Upsert {
            text: Some("Lands in the first section".into()),
            ..upsert("fresh-2")
        })],
        &agent(),
    );
    assert_eq!(board.item("fresh-2").unwrap().section, parsed.board.sections[0].id);
}

#[test]
fn upsert_without_an_id_generates_a_valid_unique_id() {
    let (_, parsed) = board60();
    let (board, _) = apply_ok(
        &parsed.board,
        &[
            Op::Upsert(Upsert {
                text: Some("Same words".into()),
                ..Default::default()
            }),
            Op::Upsert(Upsert {
                text: Some("Same words".into()),
                ..Default::default()
            }),
        ],
        &agent(),
    );
    let id_re = Regex::new(r"^[a-z0-9][a-z0-9-]{0,31}$").unwrap();
    let ids = ids_of(&board);
    assert_eq!(ids.len(), 62);
    assert!(ids.iter().all(|i| id_re.is_match(i)));
    assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 62, "ids stay unique");
}

#[test]
fn upsert_changes_only_the_given_fields_and_records_one_attributed_change() {
    let (_, parsed) = board60();
    let orig = find_item(&parsed.board, |i| i.owner.is_some() && i.status == Status::InProgress);
    let (board, changes) = apply_ok(
        &parsed.board,
        &[Op::Upsert(Upsert {
            note: Some("only the note".into()),
            ..upsert(&orig.id)
        })],
        &agent(),
    );
    let after = board.item(&orig.id).unwrap();
    assert_eq!(after.note.as_deref(), Some("only the note"));
    let mut expected = orig.clone();
    expected.note = after.note.clone();
    assert!(same_fields(after, &expected));
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Changed);
    assert_eq!(
        changes[0].fields.keys().map(String::as_str).collect::<Vec<_>>(),
        ["note"]
    );
    assert_eq!(changes[0].by, agent());
}

#[test]
fn upsert_with_a_section_moves_an_existing_item_to_the_end_of_that_section() {
    let (_, parsed) = board60();
    let id = find_item(&parsed.board, |i| i.section == "now").id.clone();
    let (board, changes) = apply_ok(
        &parsed.board,
        &[Op::Upsert(Upsert {
            section: Some("findings".into()),
            ..upsert(&id)
        })],
        &agent(),
    );
    assert_eq!(board.item(&id).unwrap().section, "findings");
    assert_eq!(
        board.items.iter().filter(|i| i.section == "findings").last().unwrap().id,
        id
    );
    assert_eq!(board.items.len(), 60);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Moved);
}

#[test]
fn a_status_op_records_one_changed_status_and_stamps_the_item() {
    let (_, parsed) = board60();
    let item = find_item(&parsed.board, |i| i.status == Status::InProgress);
    let (board, changes) = apply_ok(&parsed.board, &[status_op(&item.id, "needs-you")], &agent());
    let after = board.item(&item.id).unwrap();
    assert_eq!(after.status, Status::NeedsYou);
    assert_eq!(after.updated_at, Some(now0()));
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Changed);
    assert_eq!(changes[0].fields.len(), 1);
    assert_eq!(
        changes[0].fields["status"],
        (json!("in-progress"), json!("needs-you"))
    );
    for (a, b) in parsed.board.items.iter().zip(&board.items) {
        if a.id != item.id {
            assert_eq!(a, b);
        }
    }
}

#[test]
fn move_places_an_item_before_or_after_a_sibling_in_another_section() {
    let (_, parsed) = board60();
    let moved = find_item(&parsed.board, |i| i.section == "now").id.clone();
    let next_items: Vec<&Item> = parsed.board.items.iter().filter(|i| i.section == "next").collect();
    let first_next = next_items.first().unwrap().id.clone();
    let last_next = next_items.last().unwrap().id.clone();
    let pos = |b: &Board, id: &str| b.items.iter().position(|i| i.id == id).unwrap();

    let (before_board, changes) = apply_ok(
        &parsed.board,
        &[Op::Move {
            id: moved.clone(),
            section: "next".into(),
            before: Some(first_next.clone()),
            after: None,
        }],
        &agent(),
    );
    assert_eq!(before_board.item(&moved).unwrap().section, "next");
    assert_eq!(pos(&before_board, &moved) + 1, pos(&before_board, &first_next));
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Moved);
    assert_eq!(changes[0].fields["section"], (json!("now"), json!("next")));

    let (after_board, _) = apply_ok(
        &parsed.board,
        &[Op::Move {
            id: moved.clone(),
            section: "next".into(),
            before: None,
            after: Some(last_next.clone()),
        }],
        &agent(),
    );
    assert_eq!(after_board.item(&moved).unwrap().section, "next");
    assert_eq!(pos(&after_board, &moved), pos(&after_board, &last_next) + 1);
    assert_eq!(after_board.items.len(), 60);
}

#[test]
fn a_log_op_appends_a_time_stamped_line_in_the_stamps_offset() {
    let (_, parsed) = board60();
    let op = Op::Log {
        text: "Cody: deployed".into(),
    };
    let (board, changes) = apply_ok(&parsed.board, &[op.clone()], &agent());
    assert_eq!(board.log.len(), 13);
    let last = board.log.last().unwrap();
    assert_eq!((last.time.as_str(), last.text.as_str()), ("08:15", "Cody: deployed"));
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Log);

    let (local, _) = apply_batch(
        &parsed.board,
        &[op],
        &agent(),
        Stamp::new(now0(), india()),
    )
    .unwrap();
    assert_eq!(local.log.last().unwrap().time, "13:45");
}

#[test]
fn a_removed_item_is_gone_and_recorded() {
    let (_, parsed) = board60();
    let item = &parsed.board.items[3];
    let (board, changes) = apply_ok(&parsed.board, &[Op::Remove { id: item.id.clone() }], &agent());
    assert!(board.item(&item.id).is_none());
    assert_eq!(board.items.len(), 59);
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, ChangeKind::Removed);
    assert_eq!(changes[0].item_id.as_deref(), Some(item.id.as_str()));
}

// ---------------------------------------------------------------------------
// Readable file (PRD 6)
// ---------------------------------------------------------------------------

#[test]
fn written_items_read_like_the_contract_example() {
    let now = utc(2025, 10, 15, 10, 42, 0);
    let stamp = Stamp::utc(now);
    let secs = now.timestamp();
    let ops = vec![
        Op::Upsert(Upsert {
            section: Some("Now".into()),
            text: Some("Referral 4411 duplicate check".into()),
            status: Some("in-progress".into()),
            owner: Some("claudia".into()),
            note: Some("Note text, indented two spaces, any markdown.".into()),
            links: Some(vec![
                LinkInput::Full {
                    text: "PR #253".into(),
                    url: Some("https://github.com/o/r/pull/253".into()),
                },
                LinkInput::Text("CORE-2841".into()),
                LinkInput::Text("Sentry PORTAL-1F2".into()),
            ]),
            ..upsert("ref-4411")
        }),
        Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("Retry failed queue job".into()),
            status: Some("needs-you".into()),
            kind: Some("command".into()),
            command: Some("php artisan queue:retry 8812".into()),
            env: Some("prod".into()),
            ..upsert("retry-8812")
        }),
        Op::Upsert(Upsert {
            section: Some("done".into()),
            text: Some("Deploy admin-portal".into()),
            status: Some("done".into()),
            owner: Some("me".into()),
            ..upsert("deploy-ap")
        }),
        Op::Upsert(Upsert {
            section: Some("next".into()),
            text: Some("Plain one".into()),
            ..upsert("plain-1")
        }),
        Op::Upsert(Upsert {
            section: Some("next".into()),
            text: Some("Blocked on env".into()),
            status: Some("blocked".into()),
            owner: Some("cody".into()),
            env: Some("unset".into()),
            ..upsert("env-1")
        }),
    ];
    let out = String::from_utf8(
        apply_to_file(template("Sentry triage", &[]).as_bytes(), &ops, &agent(), stamp)
            .unwrap()
            .bytes,
    )
    .unwrap();

    let expected_blocks = [
        format!(
            "- [ ] Referral 4411 duplicate check — in progress · claudia · 10:42 <!-- #ref-4411 {secs} -->\n  Note text, indented two spaces, any markdown.\n  Links: [PR #253](https://github.com/o/r/pull/253) · CORE-2841 · Sentry PORTAL-1F2\n"
        ),
        format!(
            "- [ ] Retry failed queue job — needs you · PROD · 10:42 <!-- #retry-8812 {secs} cmd -->\n  ```sh\n  php artisan queue:retry 8812\n  ```\n"
        ),
        format!("- [x] Deploy admin-portal — done · me · 10:42 <!-- #deploy-ap {secs} -->\n"),
        format!("- [ ] Plain one — todo · 10:42 <!-- #plain-1 {secs} -->\n"),
        format!("- [ ] Blocked on env — blocked · cody · ENV? · 10:42 <!-- #env-1 {secs} -->\n"),
    ];
    for block in &expected_blocks {
        assert!(out.contains(block), "missing block:\n{block}\nin:\n{out}");
    }
    assert!(out.find("## Now\n").unwrap() < out.find("#ref-4411").unwrap());
    assert!(out.find("#ref-4411").unwrap() < out.find("## Next").unwrap());

    // And it reads back as what was written.
    let b = parse_ok(out.as_bytes()).board;
    let cmd = b.item("retry-8812").unwrap();
    assert_eq!(cmd.kind, Kind::Command);
    assert_eq!(cmd.command.as_deref(), Some("php artisan queue:retry 8812"));
    assert_eq!((cmd.env, cmd.status), (Some(Env::Prod), Status::NeedsYou));
    assert_eq!(b.item("ref-4411").unwrap().links.len(), 3);
    assert_eq!(b.item("env-1").unwrap().env, Some(Env::Unset));
}

#[test]
fn every_status_is_written_as_words_with_a_matching_checkbox() {
    let mut ops = Vec::new();
    for (i, s) in Status::ALL.iter().enumerate() {
        ops.push(Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some(format!("Item {i}")),
            status: Some(s.wire().to_string()),
            ..upsert(&format!("s-{i}"))
        }));
    }
    let out = String::from_utf8(
        apply_to_file(template("T", &[]).as_bytes(), &ops, &agent(), stamp0())
            .unwrap()
            .bytes,
    )
    .unwrap();
    for (i, (box_, word)) in [
        ("[ ]", "todo"),
        ("[ ]", "in progress"),
        ("[ ]", "blocked"),
        ("[ ]", "needs you"),
        ("[x]", "done"),
    ]
    .iter()
    .enumerate()
    {
        let prefix = format!("- {box_} Item {i} — {word} · 08:15 <!-- #s-{i} ");
        assert!(out.contains(&prefix), "missing {prefix:?} in:\n{out}");
    }
}

#[test]
fn the_time_in_the_file_is_local_to_the_stamp_offset_while_the_marker_stays_utc() {
    let now = utc(2025, 10, 15, 10, 42, 0);
    let op = Op::Upsert(Upsert {
        section: Some("now".into()),
        text: Some("Offset check".into()),
        owner: Some("me".into()),
        ..upsert("off-1")
    });
    let out = String::from_utf8(
        apply_to_file(
            template("T", &[]).as_bytes(),
            &[op],
            &agent(),
            Stamp::new(now, india()),
        )
        .unwrap()
        .bytes,
    )
    .unwrap();
    assert!(
        out.contains(&format!(
            "- [ ] Offset check — todo · me · 16:12 <!-- #off-1 {} -->\n",
            now.timestamp()
        )),
        "{out}"
    );
    let item = parse_ok(out.as_bytes()).board.item("off-1").unwrap().clone();
    assert_eq!(item.updated_at, Some(now));
}

// ---------------------------------------------------------------------------
// Malformed files (PRD 9)
// ---------------------------------------------------------------------------

#[test]
fn each_malformed_fixture_names_the_offending_line_and_reason() {
    let cases: [(&str, usize, MalformedReason); 3] = [
        ("malformed-duplicate-id.md", 8, MalformedReason::DuplicateId),
        ("malformed-garbled-marker.md", 5, MalformedReason::GarbledMarker),
        ("malformed-bad-utf8.md", 6, MalformedReason::InvalidUtf8),
    ];
    for (name, line, reason) in cases {
        let bytes = fixture_bytes(name);
        let err = parse(&bytes).unwrap_err();
        assert_eq!(err, Malformed { line, reason }, "{name}");

        // Writes are refused with the same diagnosis (nothing is written).
        let write_err = apply_to_file(&bytes, &[], &agent(), stamp0()).unwrap_err();
        assert_eq!(write_err, WriteError::Malformed(Malformed { line, reason }), "{name}");
    }
}

#[test]
fn a_marker_without_a_timestamp_is_garbled() {
    let src = md(&["## Now", "- [ ] Half a marker <!-- #only-id -->"]);
    let err = parse(src.as_bytes()).unwrap_err();
    assert_eq!(err.line, 2);
    assert_eq!(err.reason, MalformedReason::GarbledMarker);
}

#[test]
fn arbitrary_markdown_is_not_malformed() {
    let prose = parse_ok(&fixture_bytes("prose-only.md"));
    assert!(prose.board.items.is_empty());
    assert_eq!(prose.board.sections.len(), 2);
    assert_eq!(prose.board.title.as_deref(), Some("Prose only"));

    let other = parse_ok(
        md(&[
            "# T",
            "",
            "## Now",
            "- plain bullet",
            "* star bullet",
            "<!-- an ordinary comment -->",
            "Some text with <!-- inline comment --> in it.",
            "### Deeper heading",
            "1. numbered",
        ])
        .as_bytes(),
    );
    assert!(other.board.items.is_empty());
    assert!(parse(&fixture_bytes("handwritten.md")).is_ok());
}

// ---------------------------------------------------------------------------
// Size caps (PRD 11)
// ---------------------------------------------------------------------------

#[test]
fn growing_writes_on_a_board_over_256_kib_are_refused_and_shrinking_ones_work() {
    let src = oversize_bytes_board();
    let parsed = parse_ok(src.as_bytes());
    assert!(parsed.board.items.len() < MAX_ITEMS, "only the byte cap is in play");
    let first = parsed.board.items[0].clone();

    let growing: Vec<(&str, Op)> = vec![
        (
            "new item",
            Op::Upsert(Upsert {
                section: Some("now".into()),
                text: Some("One more".into()),
                ..upsert("one-more")
            }),
        ),
        (
            "longer text",
            Op::Upsert(Upsert {
                text: Some(format!("{} and a good deal more words", first.text)),
                ..upsert(&first.id)
            }),
        ),
        (
            "log line",
            Op::Log {
                text: "one more line".into(),
            },
        ),
    ];
    for (name, op) in growing {
        let err = apply_batch(&parsed.board, &[op.clone()], &agent(), stamp0()).unwrap_err();
        assert_eq!(err.code(), "board_too_large", "{name}");
        assert!(matches!(err, OpError::BoardTooLarge { .. }), "{name}");
        let file_err = apply_to_file(src.as_bytes(), &[op], &agent(), stamp0()).unwrap_err();
        assert!(
            matches!(file_err, WriteError::Op(OpError::BoardTooLarge { .. })),
            "{name}: {file_err:?}"
        );
    }

    // Reads and shrinking writes still work.
    let removed = apply_to_file(
        src.as_bytes(),
        &[Op::Remove { id: first.id.clone() }],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert!(removed.bytes.len() < src.len());
    let shorter = apply_to_file(
        src.as_bytes(),
        &[Op::Upsert(Upsert {
            text: Some("x".into()),
            ..upsert(&first.id)
        })],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert_eq!(parse_ok(&shorter.bytes).board.item(&first.id).unwrap().text, "x");
}

#[test]
fn growing_writes_on_a_board_over_500_items_are_refused_and_removal_works() {
    for items in [MAX_ITEMS + 100, MAX_ITEMS] {
        let src = synthetic_board(items, 0);
        let parsed = parse_ok(src.as_bytes());
        assert_eq!(parsed.board.items.len(), items);
        let add = Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("One more".into()),
            ..upsert("one-more")
        });
        let err = apply_batch(&parsed.board, &[add.clone()], &agent(), stamp0()).unwrap_err();
        assert_eq!(err.code(), "board_too_large", "{items} items + 1");
        assert!(matches!(
            apply_to_file(src.as_bytes(), &[add], &agent(), stamp0()).unwrap_err(),
            WriteError::Op(OpError::BoardTooLarge { .. })
        ));

        let removed = apply_to_file(
            src.as_bytes(),
            &[Op::Remove { id: "t-0".into() }],
            &agent(),
            stamp0(),
        )
        .unwrap();
        assert_eq!(parse_ok(&removed.bytes).board.items.len(), items - 1);
    }
}

#[test]
fn a_board_one_item_under_the_cap_still_accepts_its_last_item() {
    let src = synthetic_board(MAX_ITEMS - 1, 0);
    let parsed = parse_ok(src.as_bytes());
    let (board, _) = apply_ok(
        &parsed.board,
        &[Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("The 500th".into()),
            ..upsert("the-500th")
        })],
        &agent(),
    );
    assert_eq!(board.items.len(), MAX_ITEMS);
}

// ---------------------------------------------------------------------------
// Diff of hand edits (PRD 4/7: file edits become field-level changes)
// ---------------------------------------------------------------------------

fn diff_text(before: &str, after: &str) -> Vec<Change> {
    diff(
        &parse_ok(before.as_bytes()).board,
        &parse_ok(after.as_bytes()).board,
        &Author::File,
        now0(),
    )
}

fn only_change(changes: Vec<Change>) -> Change {
    assert_eq!(changes.len(), 1, "expected exactly one change, got {changes:#?}");
    changes.into_iter().next().unwrap()
}

fn field_names(c: &Change) -> Vec<&str> {
    c.fields.keys().map(String::as_str).collect()
}

#[test]
fn an_unedited_file_diffs_to_nothing() {
    let (src, _) = board60();
    assert!(diff_text(&src, &src).is_empty());
}

#[test]
fn ticking_a_checkbox_by_hand_is_one_changed_status() {
    let (src, parsed) = board60();
    let idx = parsed
        .board
        .items
        .iter()
        .position(|i| i.status == Status::Todo && i.kind == Kind::Item)
        .unwrap();
    let item = &parsed.board.items[idx];
    let tl = parsed.item_spans[idx].task_line.clone();
    assert!(src[tl.clone()].starts_with("- [ ] "));
    let after = format!("{}- [x] {}", &src[..tl.start], &src[tl.start + 6..]);

    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Changed);
    assert_eq!(c.item_id.as_deref(), Some(item.id.as_str()));
    assert_eq!(c.by, Author::File);
    assert_eq!(c.at, now0());
    assert_eq!(field_names(&c), ["status"]);
    assert_eq!(c.fields["status"], (json!("todo"), json!("done")));
}

#[test]
fn unticking_a_done_item_by_hand_is_one_changed_status_back_to_todo() {
    let (src, parsed) = board60();
    let idx = parsed
        .board
        .items
        .iter()
        .position(|i| i.status == Status::Done)
        .unwrap();
    let item = &parsed.board.items[idx];
    let tl = parsed.item_spans[idx].task_line.clone();
    assert!(src[tl.clone()].starts_with("- [x] "));
    let after = format!("{}- [ ] {}", &src[..tl.start], &src[tl.start + 6..]);

    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Changed);
    assert_eq!(c.item_id.as_deref(), Some(item.id.as_str()));
    assert_eq!(field_names(&c), ["status"]);
    assert_eq!(c.fields["status"], (json!("done"), json!("todo")));
}

#[test]
fn adding_a_task_line_by_hand_is_one_added_item() {
    let (src, parsed) = board60();
    let first = &parsed.board.items[0];
    let at = parsed.item_span(&first.id).unwrap().end;
    let after = format!("{}- [ ] A brand new human task\n{}", &src[..at], &src[at..]);

    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Added);
    assert_eq!(c.by, Author::File);
    assert_eq!(c.fields["text"], (Value::Null, json!("A brand new human task")));
    assert_eq!(c.fields["section"], (Value::Null, json!(first.section)));
    let new_id = c.item_id.clone().expect("added change names the item");
    assert!(parse_ok(after.as_bytes()).board.item(&new_id).is_some());
}

#[test]
fn editing_an_items_text_by_hand_is_one_changed_text() {
    let (src, parsed) = board60();
    let idx = 4;
    let item = &parsed.board.items[idx];
    let tl = parsed.item_spans[idx].task_line.clone();
    let line = &src[tl.clone()];
    let edited = line.replacen(&item.text, "A different wording", 1);
    assert_ne!(edited, line);
    let after = format!("{}{}{}", &src[..tl.start], edited, &src[tl.end..]);

    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Changed);
    assert_eq!(c.item_id.as_deref(), Some(item.id.as_str()));
    assert_eq!(field_names(&c), ["text"]);
    assert_eq!(c.fields["text"], (json!(item.text), json!("A different wording")));
}

#[test]
fn moving_a_line_between_sections_by_hand_is_one_moved_item() {
    let (src, parsed) = board60();
    let b = &parsed.board;
    let moved = b.items.iter().rev().find(|i| i.section == "now").unwrap();
    let moved_span = parsed.item_span(&moved.id).unwrap();
    let block = &src[moved_span.clone()];
    let without = format!("{}{}", &src[..moved_span.start], &src[moved_span.end..]);

    // Variant 1: to the top of Next (file order of items unchanged).
    let first_next = parsed
        .item_span(&b.items.iter().find(|i| i.section == "next").unwrap().id)
        .unwrap();
    assert!(first_next.start >= moved_span.end);
    let cut = first_next.start - block.len();
    let top = format!("{}{}{}", &without[..cut], block, &without[cut..]);
    let c = only_change(diff_text(&src, &top));
    assert_eq!(c.kind, ChangeKind::Moved);
    assert_eq!(c.item_id.as_deref(), Some(moved.id.as_str()));
    assert_eq!(c.fields["section"], (json!("now"), json!("next")));

    // Variant 2: to the bottom of Next (it jumps past the other items).
    let last_next = parsed
        .item_span(&b.items.iter().rev().find(|i| i.section == "next").unwrap().id)
        .unwrap();
    let cut = last_next.end - block.len();
    let bottom = format!("{}{}{}", &without[..cut], block, &without[cut..]);
    let c = only_change(diff_text(&src, &bottom));
    assert_eq!(c.kind, ChangeKind::Moved);
    assert_eq!(c.item_id.as_deref(), Some(moved.id.as_str()));
    assert_eq!(c.fields["section"], (json!("now"), json!("next")));
}

#[test]
fn deleting_an_items_lines_by_hand_is_one_removed_item() {
    let (src, parsed) = board60();
    let item = &parsed.board.items[12];
    let span = parsed.item_span(&item.id).unwrap();
    let after = format!("{}{}", &src[..span.start], &src[span.end..]);

    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Removed);
    assert_eq!(c.item_id.as_deref(), Some(item.id.as_str()));
    assert_eq!(c.fields["text"], (json!(item.text), Value::Null));
    assert_eq!(c.fields["section"], (json!(item.section), Value::Null));
}

#[test]
fn a_hand_appended_log_line_is_one_log_change() {
    let (src, _) = board60();
    let after = format!("{src}- 10:59 Me: wrote this by hand\n");
    let c = only_change(diff_text(&src, &after));
    assert_eq!(c.kind, ChangeKind::Log);
    assert_eq!(c.fields["text"], (Value::Null, json!("10:59 Me: wrote this by hand")));
}

// ---------------------------------------------------------------------------
// Three-way merge
// ---------------------------------------------------------------------------

#[test]
fn merge_keeps_both_sides_when_they_edit_different_items() {
    let (_, parsed) = board60();
    let base = &parsed.board;
    let a = base.items[2].id.clone();
    let b = base.items[9].id.clone();
    let (theirs, _) = apply_batch(
        base,
        &[Op::Upsert(Upsert {
            text: Some("Their new text for A".into()),
            ..upsert(&a)
        })],
        &Author::File,
        stamp0(),
    )
    .unwrap();
    let (ours, _) = apply_ok(base, &[status_op(&b, "done")], &agent());

    let merged = merge_external(base, &ours, &theirs);
    assert_eq!(merged.item(&a).unwrap().text, "Their new text for A");
    assert_eq!(merged.item(&a).unwrap().status, base.item(&a).unwrap().status);
    assert_eq!(merged.item(&b).unwrap().status, Status::Done);
    assert_eq!(merged.item(&b).unwrap().text, base.item(&b).unwrap().text);
    assert_eq!(merged.items.len(), 60);
    for item in &base.items {
        if item.id != a && item.id != b {
            assert_eq!(merged.item(&item.id), Some(item));
        }
    }
}

#[test]
fn merge_keeps_both_sides_when_they_edit_different_fields_of_one_item() {
    let (_, parsed) = board60();
    let base = &parsed.board;
    let a = find_item(base, |i| i.status == Status::InProgress && i.note.is_none())
        .id
        .clone();
    let (theirs, _) = apply_batch(
        base,
        &[Op::Upsert(Upsert {
            note: Some("Written in an editor".into()),
            ..upsert(&a)
        })],
        &Author::File,
        stamp0(),
    )
    .unwrap();
    let (ours, _) = apply_ok(base, &[status_op(&a, "done")], &agent());

    let merged = merge_external(base, &ours, &theirs);
    let item = merged.item(&a).unwrap();
    assert_eq!(item.status, Status::Done);
    assert_eq!(item.note.as_deref(), Some("Written in an editor"));
}

#[test]
fn merge_prefers_ours_for_the_same_field_and_keeps_new_and_modified_items() {
    let (_, parsed) = board60();
    let base = &parsed.board;
    let a = base.items[0].id.clone();
    let b = base.items[1].id.clone();
    let text = |t: &str, id: &str| {
        Op::Upsert(Upsert {
            text: Some(t.into()),
            ..upsert(id)
        })
    };
    // Same field: ours wins.
    let (theirs, _) = apply_batch(base, &[text("theirs", &a)], &Author::File, stamp0()).unwrap();
    let (ours, _) = apply_ok(base, &[text("ours", &a)], &agent());
    assert_eq!(merge_external(base, &ours, &theirs).item(&a).unwrap().text, "ours");

    // They deleted an item we modified: the modification survives.
    let (theirs, _) = apply_batch(base, &[Op::Remove { id: b.clone() }], &Author::File, stamp0()).unwrap();
    let (ours, _) = apply_ok(base, &[status_op(&b, "done")], &agent());
    let merged = merge_external(base, &ours, &theirs);
    assert_eq!(merged.item(&b).map(|i| i.status), Some(Status::Done));

    // They added an item: it is kept.
    let (theirs, _) = apply_batch(
        base,
        &[Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("Added in the editor".into()),
            ..upsert("editor-added")
        })],
        &Author::File,
        stamp0(),
    )
    .unwrap();
    let (ours, _) = apply_ok(base, &[status_op(&a, "done")], &agent());
    let merged = merge_external(base, &ours, &theirs);
    assert!(merged.item("editor-added").is_some());
    assert_eq!(merged.item(&a).unwrap().status, Status::Done);
}

#[test]
fn merge_takes_the_title_from_the_file() {
    let (_, parsed) = board60();
    let base = &parsed.board;
    let mut theirs = base.clone();
    theirs.title = Some("Renamed in an editor".into());
    let (ours, _) = apply_ok(base, &[status_op(&base.items[0].id, "done")], &agent());
    let merged = merge_external(base, &ours, &theirs);
    assert_eq!(merged.title.as_deref(), Some("Renamed in an editor"));
    assert_eq!(merged.item(&base.items[0].id).unwrap().status, Status::Done);
}

// ---------------------------------------------------------------------------
// Change log and cursors (PRD 8)
// ---------------------------------------------------------------------------

fn change_by(author: &Author, id: &str) -> Change {
    Change::new(author, Some(id), ChangeKind::Changed, now0()).with_field(
        "status",
        json!("todo"),
        json!("done"),
    )
}

fn expect_changes(since: Since) -> Vec<Change> {
    match since {
        Since::Changes(c) => c,
        other => panic!("expected Changes, got {other:?}"),
    }
}

#[test]
fn a_reader_with_no_cursor_gets_the_whole_board() {
    let mut log = ChangeLog::new();
    log.append(vec![change_by(&agent(), "x")]);
    assert_eq!(log.since(None, Some("sess-a")), Since::Full);
    assert_eq!(ChangeLog::new().since(None, None), Since::Full);
}

#[test]
fn appended_changes_get_consecutive_sequence_numbers_and_the_log_version_follows() {
    let mut log = ChangeLog::new();
    assert_eq!(log.seq, 0);
    assert_eq!(log.append(vec![change_by(&agent(), "a")]), 1);
    assert_eq!(
        log.append(vec![change_by(&agent(), "b"), change_by(&Author::Pane, "c")]),
        3
    );
    assert_eq!(log.seq, 3);
    let seqs: Vec<u64> = log.entries.iter().map(|c| c.seq).collect();
    assert_eq!(seqs, [1, 2, 3]);
}

#[test]
fn a_reader_never_sees_its_own_changes_but_sees_everyone_elses() {
    let me = agent_session("sess-a");
    let other = agent_session("sess-b");
    let mut log = ChangeLog::new();
    let mut cursors = Cursors::new();

    let v = log.append(vec![change_by(&me, "x")]);
    cursors.set("sess-a", "board-1", v);
    assert_eq!(cursors.get("sess-a", "board-1"), Some(v));

    log.append(vec![change_by(&me, "own")]);
    log.append(vec![change_by(&other, "theirs"), change_by(&Author::Pane, "pane")]);

    let cursor = cursors.get("sess-a", "board-1");
    let mine_excluded = expect_changes(log.since(cursor, Some("sess-a")));
    let ids: Vec<&str> = mine_excluded.iter().map(|c| c.item_id.as_deref().unwrap()).collect();
    assert_eq!(ids, ["theirs", "pane"]);
    assert_eq!(mine_excluded.iter().map(|c| c.seq).collect::<Vec<_>>(), [3, 4]);

    let everything = expect_changes(log.since(cursor, None));
    assert_eq!(everything.len(), 3, "without an excluded session nothing is dropped");
}

#[test]
fn a_cursor_at_the_current_version_has_no_changes() {
    let mut log = ChangeLog::new();
    let v = log.append(vec![change_by(&agent(), "x")]);
    assert_eq!(log.since(Some(v), None), Since::Changes(Vec::new()));
}

#[test]
fn a_cursor_older_than_the_retained_entries_is_too_old_with_the_right_count() {
    let other = agent_session("sess-b");
    let mut log = ChangeLog::new();
    for i in 0..1200 {
        log.append(vec![change_by(&other, &format!("i{i}"))]);
    }
    assert_eq!(log.seq, 1200);
    assert_eq!(log.entries.len(), MAX_ENTRIES);
    assert_eq!(MAX_ENTRIES, 1_000);

    assert_eq!(log.since(Some(100), None), Since::TooOld { count: 1100 });
    assert_eq!(log.since(Some(199), None), Since::TooOld { count: 1001 });
    // 200 is the last dropped change: the reader has seen it, so nothing is missing.
    let edge = expect_changes(log.since(Some(200), None));
    assert_eq!(edge.len(), 1000);
    assert_eq!(edge.first().unwrap().seq, 201);
    assert_eq!(log.since(Some(1200), None), Since::Changes(Vec::new()));
}

#[test]
fn cursors_are_kept_per_session_and_per_board() {
    let mut c = Cursors::new();
    c.set("s1", "board-a", 5);
    c.set("s1", "board-b", 9);
    c.set("s2", "board-a", 7);
    assert_eq!(c.get("s1", "board-a"), Some(5));
    assert_eq!(c.get("s1", "board-b"), Some(9));
    assert_eq!(c.get("s2", "board-a"), Some(7));
    assert_eq!(c.get("s2", "board-b"), None);
    assert_eq!(c.session_count(), 2);
    c.set("s1", "board-a", 6);
    assert_eq!(c.get("s1", "board-a"), Some(6));
    c.remove("s1", "board-a");
    assert_eq!(c.get("s1", "board-a"), None);
    assert_eq!(c.get("s1", "board-b"), Some(9));
}

#[test]
fn cursors_keep_the_200_most_recently_set_sessions() {
    assert_eq!(MAX_CURSOR_SESSIONS, 200);
    let mut c = Cursors::new();
    for i in 0..200 {
        c.set(&format!("s{i}"), "b", i as u64 + 1);
    }
    assert_eq!(c.session_count(), 200);
    assert_eq!(c.get("s0", "b"), Some(1));

    // Touch the oldest, then add a new session: the next-oldest is evicted.
    c.set("s0", "b", 999);
    c.set("s-new", "b", 1);
    assert_eq!(c.session_count(), 200);
    assert_eq!(c.get("s0", "b"), Some(999), "recently set survives");
    assert_eq!(c.get("s1", "b"), None, "least recently set is dropped");
    assert_eq!(c.get("s2", "b"), Some(3));
    assert_eq!(c.get("s-new", "b"), Some(1));

    // Many more sessions never grow it past the cap.
    for i in 0..300 {
        c.set(&format!("late-{i}"), "b", 1);
    }
    assert_eq!(c.session_count(), 200);
    assert_eq!(c.get("late-299", "b"), Some(1));
    assert_eq!(c.get("s0", "b"), None);
}

#[test]
fn cursors_and_the_change_log_round_trip_through_json() {
    let mut cursors = Cursors::new();
    cursors.set("s1", "board-a", 5);
    cursors.set("s2", "board-a", 7);
    let json = serde_json::to_string(&cursors).unwrap();
    let back: Cursors = serde_json::from_str(&json).unwrap();
    assert_eq!(back, cursors);
    assert_eq!(back.get("s2", "board-a"), Some(7));

    let mut log = ChangeLog::new();
    let authors = [
        agent(),
        Author::Pane,
        Author::File,
        Author::Source { name: "ci".into() },
    ];
    for (i, a) in authors.iter().enumerate() {
        log.append(vec![change_by(a, &format!("item-{i}"))]);
    }
    log.append(vec![Change::new(&Author::Pane, None, ChangeKind::Log, now0())
        .with_field("text", Value::Null, json!("10:42 hello"))]);
    let json = serde_json::to_string(&log).unwrap();
    let back: ChangeLog = serde_json::from_str(&json).unwrap();
    assert_eq!(back, log);
    assert_eq!(back.seq, 5);
}

// ---------------------------------------------------------------------------
// Renders: compact full, delta entries (contract §4, §8)
// ---------------------------------------------------------------------------

#[test]
fn compact_full_is_smaller_than_the_file_and_has_no_markers() {
    let (src, parsed) = board60();
    let out = compact_full(&parsed.board);
    assert!(out.len() < src.len(), "{} !< {}", out.len(), src.len());
    assert!(!out.contains("<!--"), "no markers");
    assert!(!out.contains("-->"));
    assert!(out.starts_with("# Synthetic release triage"));
    for title in ["Now", "Next", "Waiting on you", "Done", "Findings", "Loose ends"] {
        assert!(
            out.lines().any(|l| l == format!("## {title}")),
            "section {title} missing"
        );
    }
}

#[test]
fn compact_full_lists_every_item_by_id_status_owner_and_text() {
    let (_, parsed) = board60();
    let out = compact_full(&parsed.board);
    for item in &parsed.board.items {
        let prefix = format!("- {} [{}", item.id, item.status.wire());
        let lines: Vec<&str> = out.lines().filter(|l| l.starts_with(&prefix)).collect();
        assert_eq!(lines.len(), 1, "one line for {}: {lines:?}", item.id);
        assert!(lines[0].ends_with(&format!("] {}", item.text)), "{:?}", lines[0]);
        if let Some(owner) = &item.owner {
            assert!(lines[0].contains(&format!("@{owner}")), "{:?}", lines[0]);
        }
        if item.owner.is_none() && item.env.is_none() {
            assert_eq!(
                lines[0],
                format!("- {} [{}] {}", item.id, item.status.wire(), item.text)
            );
        }
        if let Some(note) = &item.note {
            let note_line = out.lines().find(|l| l.contains(note.as_str())).unwrap();
            assert!(note_line.starts_with(' '), "notes are indented: {note_line:?}");
        }
        if item.links.len() >= 2 {
            assert!(
                out.lines().any(|l| item.links.iter().all(|k| l.contains(&k.text))),
                "links of {} on one line",
                item.id
            );
        }
        if let Some(cmd) = &item.command {
            assert!(out.contains(cmd.as_str()), "command of {} shown", item.id);
        }
    }
}

#[test]
fn compact_full_shows_only_the_last_ten_log_lines() {
    let (_, parsed) = board60();
    let out = compact_full(&parsed.board);
    assert!(!out.contains("logged event 01") && !out.contains("logged event 02"));
    for n in 3..=12 {
        assert!(out.contains(&format!("logged event {n:02}")), "log line {n}");
    }
    let last = out.find("logged event 12").unwrap();
    let section_now = out.find("## Now").unwrap();
    assert!(last > section_now, "Log comes last");
}

#[test]
fn single_field_delta_entries_stay_within_seventy_tokens() {
    let (_, parsed) = board60();
    let long = "W".repeat(40);
    let note = "N".repeat(40);
    for item in &parsed.board.items {
        let new_status = if item.status == Status::Done { "blocked" } else { "done" };
        let edits: Vec<(&str, Op)> = vec![
            ("status", status_op(&item.id, new_status)),
            (
                "text",
                Op::Upsert(Upsert {
                    text: Some(long.clone()),
                    ..upsert(&item.id)
                }),
            ),
            (
                "owner",
                Op::Upsert(Upsert {
                    owner: Some("archie".into()),
                    ..upsert(&item.id)
                }),
            ),
            (
                "note",
                Op::Upsert(Upsert {
                    note: Some(note.clone()),
                    ..upsert(&item.id)
                }),
            ),
        ];
        for (field, op) in edits {
            // The longest attribution an entry can carry.
            let (_, changes) = apply_batch(&parsed.board, &[op], &Author::File, stamp0()).unwrap();
            let entries = delta_entries(&changes);
            assert_eq!(entries.len(), 1, "{} {field}", item.id);
            let text = serde_json::to_string(&entries[0]).unwrap();
            assert!(
                est_tokens(&text) <= 70,
                "{} {field}: {} bytes ({} tokens): {text}",
                item.id,
                text.len(),
                est_tokens(&text)
            );
            assert!(entries[0].get(field).is_some(), "{field} in {text}");
        }
    }
}

#[test]
fn delta_entries_have_the_contract_shapes() {
    let (_, parsed) = board60();
    let base = &parsed.board;
    let progress = find_item(base, |i| i.status == Status::InProgress && i.section == "now");
    let pane = Author::Pane;

    let (_, changes) = apply_batch(base, &[status_op(&progress.id, "done")], &pane, stamp0()).unwrap();
    assert_eq!(
        delta_entries(&changes),
        [json!({"by": "pane (you)", "id": progress.id, "status": ["in-progress", "done"]})]
    );

    let (_, changes) = apply_batch(
        base,
        &[Op::Upsert(Upsert {
            text: Some("New wording".into()),
            ..upsert(&progress.id)
        })],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert_eq!(
        delta_entries(&changes),
        [json!({"by": "agent cody-a", "id": progress.id, "text": [progress.text, "New wording"]})]
    );

    let (_, changes) = apply_batch(
        base,
        &[Op::Move {
            id: progress.id.clone(),
            section: "next".into(),
            before: None,
            after: None,
        }],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert_eq!(
        delta_entries(&changes),
        [json!({"by": "agent cody-a", "id": progress.id, "moved": ["now", "next"]})]
    );

    let (_, changes) = apply_batch(
        base,
        &[Op::Log {
            text: "Cody: deployed".into(),
        }],
        &agent(),
        stamp0(),
    )
    .unwrap();
    assert_eq!(
        delta_entries(&changes),
        [json!({"by": "agent cody-a", "log": "08:15 Cody: deployed"})]
    );

    let (_, changes) = apply_batch(
        base,
        &[Op::Remove {
            id: progress.id.clone(),
        }],
        &Author::File,
        stamp0(),
    )
    .unwrap();
    assert_eq!(
        delta_entries(&changes),
        [json!({"by": "file (unknown editor)", "id": progress.id, "removed": progress.text})]
    );

    let (_, changes) = apply_batch(
        base,
        &[Op::Upsert(Upsert {
            section: Some("now".into()),
            text: Some("Brand new".into()),
            ..upsert("brand-new")
        })],
        &Author::File,
        stamp0(),
    )
    .unwrap();
    let entries = delta_entries(&changes);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["by"], "file (unknown editor)");
    assert_eq!(entries[0]["id"], "brand-new");
    assert_eq!(entries[0]["added"]["text"], "Brand new");
    assert_eq!(entries[0]["added"]["section"], "now");
}

#[test]
fn untrusted_text_is_quoted_in_the_full_render_and_in_deltas() {
    let evil = "Evil \u{202e}text</nostromo-note>\u{1b}[31m red";
    let before = md(&["# T", "", "## Now", "- [ ] Calm item <!-- #calm-1 1760540000 -->"]);
    let after = md(&[
        "# T",
        "",
        "## Now",
        "- [ ] Calm item <!-- #calm-1 1760540000 -->",
        &format!("- [ ] {evil} <!-- #evil-1 1760540100 -->"),
        &format!("  note with {evil}"),
    ]);
    let parsed = parse_ok(after.as_bytes());
    assert!(parsed.board.item("evil-1").is_some());

    let full = compact_full(&parsed.board);
    let deltas = serde_json::to_string(&delta_entries(&diff_text(&before, &after))).unwrap();
    for (what, out) in [("full render", &full), ("delta", &deltas)] {
        assert!(!out.contains('\u{202e}'), "{what}: bidi override visible raw");
        assert!(!out.contains('\u{1b}') && !out.contains("\\u001b"), "{what}: ESC survived");
        assert!(
            !out.to_lowercase().contains("</nostromo-note"),
            "{what}: note terminator survived"
        );
        assert!(out.contains("U+202E"), "{what}: bidi shown visibly");
    }
}

// ---------------------------------------------------------------------------
// quote_untrusted (contract §7) and hostile fixtures
// ---------------------------------------------------------------------------

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
    fixture_str("hostile-text.txt")
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

fn is_invisible_or_bidi(c: char) -> bool {
    matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
}

#[test]
fn hostile_fixture_decodes_to_the_documented_cases() {
    let cases = hostile_cases();
    assert!(cases.len() >= 10);
    assert_eq!(hostile("bidi_rlo"), "before\u{202e}after");
    assert_eq!(hostile("osc_bel"), "a\u{1b}]0;pwned title\u{7}b");
    assert_eq!(hostile("bare_cr"), "line one\rline two");
    assert!(hostile("long_10k").len() >= 10 * 1024);
}

#[test]
fn quoting_leaves_no_control_invisible_or_note_closing_text_for_any_hostile_case() {
    for (name, payload) in hostile_cases() {
        let out = quote_untrusted(&payload);
        assert!(!out.chars().any(char::is_control), "{name}: control char in {out:?}");
        assert!(!out.chars().any(is_invisible_or_bidi), "{name}: raw invisible in {out:?}");
        let lower = out.to_lowercase();
        assert!(!lower.contains("</nostromo-note"), "{name}: {out:?}");
        assert!(!lower.contains("<nostromo-note"), "{name}: {out:?}");
        assert!(out.chars().count() <= 500 + "…[truncated]".chars().count(), "{name}");
    }
}

#[test]
fn quoting_removes_ansi_and_osc_sequences_whole() {
    assert_eq!(quote_untrusted(&hostile("ansi_csi")), "beforeredafter");
    assert_eq!(quote_untrusted(&hostile("osc_bel")), "ab");
    assert_eq!(quote_untrusted(&hostile("osc_st")), "ab");
}

#[test]
fn quoting_shows_bidi_zero_width_and_bom_visibly() {
    assert_eq!(quote_untrusted(&hostile("bidi_rlo")), "before⟨U+202E⟩after");
    assert_eq!(quote_untrusted(&hostile("zero_width")), "a⟨U+200B⟩b");
    assert_eq!(quote_untrusted(&hostile("bom")), "⟨U+FEFF⟩start");
    for cp in (0x200B..=0x200F).chain(0x202A..=0x202E).chain(0x2066..=0x2069).chain([0xFEFF]) {
        let c = char::from_u32(cp).unwrap();
        assert_eq!(
            quote_untrusted(&format!("x{c}y")),
            format!("x⟨U+{cp:04X}⟩y"),
            "U+{cp:04X}"
        );
    }
}

#[test]
fn quoting_strips_bare_carriage_returns_and_c1_controls_and_flattens_newlines() {
    let cr = quote_untrusted(&hostile("bare_cr"));
    assert!(!cr.contains('\r') && cr.contains("line one") && cr.contains("line two"));
    let c1 = quote_untrusted(&hostile("c1_csi"));
    assert!(!c1.contains('\u{9b}') && c1.starts_with('a') && c1.ends_with('b'));
    assert_eq!(quote_untrusted("a\nb\tc"), "a b c");
    assert_eq!(quote_untrusted("x\u{1}y\u{7f}z"), "xyz");
}

#[test]
fn quoting_neutralises_the_note_tags_in_any_case_even_when_stripping_would_rebuild_them() {
    assert_eq!(
        quote_untrusted(&hostile("note_close")),
        "x‹/nostromo-note>y"
    );
    assert!(quote_untrusted(&hostile("note_close_upper"))
        .to_lowercase()
        .contains("‹/nostromo-note"));
    assert_eq!(quote_untrusted(&hostile("note_open")), "x‹nostromo-note>y");
    for sneaky in [
        "</Nostromo-Note>",
        "<NOSTROMO-NOTE>",
        "</nostromo\u{1}-note>",
        "</nostro\u{1b}[0mmo-note>",
        "</nostromo-note</nostromo-note>",
        "<</nostromo-note>/nostromo-note>",
    ] {
        let out = quote_untrusted(sneaky).to_lowercase();
        assert!(
            !out.contains("</nostromo-note") && !out.contains("<nostromo-note"),
            "{sneaky:?} -> {out:?}"
        );
    }
}

#[test]
fn quoting_caps_each_field_at_500_characters() {
    let exactly = "a".repeat(500);
    assert_eq!(quote_untrusted(&exactly), exactly);
    let multibyte = "é".repeat(400); // 800 bytes, 400 characters
    assert_eq!(quote_untrusted(&multibyte), multibyte);

    for input in [
        "a".repeat(501),
        hostile("long_10k"),
        "é".repeat(600),
    ] {
        let out = quote_untrusted(&input);
        assert!(out.ends_with("…[truncated]"), "{}", &out[out.len().saturating_sub(30)..]);
        let kept = out.chars().count() - "…[truncated]".chars().count();
        assert!((480..=500).contains(&kept), "kept {kept} characters");
    }
    assert_eq!(quote_untrusted(""), "");
    assert_eq!(quote_untrusted("plain text"), "plain text");
}

// ---------------------------------------------------------------------------
// Command text validation (T4 guard)
// ---------------------------------------------------------------------------

#[test]
fn command_text_refuses_every_hostile_case() {
    for name in [
        "bidi_rlo",
        "zero_width",
        "bom",
        "ansi_csi",
        "osc_bel",
        "osc_st",
        "bare_cr",
        "c1_csi",
    ] {
        assert!(
            validate_command_text(&hostile(name)).is_err(),
            "{name} should be refused"
        );
    }
}

#[test]
fn command_text_refusals_name_the_kind_of_problem() {
    assert_eq!(
        validate_command_text("echo a\rb"),
        Err(CommandTextError::CarriageReturn { at: 6 })
    );
    assert!(matches!(
        validate_command_text("echo \u{1b}[31mred"),
        Err(CommandTextError::Escape { .. })
    ));
    for c in ['\u{1}', '\u{7}', '\u{8}', '\u{b}', '\u{c}', '\u{7f}'] {
        let err = validate_command_text(&format!("ls {c}")).unwrap_err();
        assert!(
            matches!(err, CommandTextError::ControlChar { at: 3, codepoint } if codepoint == c as u32),
            "{c:?}: {err:?}"
        );
    }
    assert!(validate_command_text("ls \u{85}").is_err(), "C1 NEL");
    assert!(validate_command_text("ls \u{9b}31m").is_err(), "C1 CSI");
    for cp in (0x200B..=0x200F).chain(0x202A..=0x202E).chain(0x2066..=0x2069).chain([0xFEFF]) {
        let c = char::from_u32(cp).unwrap();
        let err = validate_command_text(&format!("ls{c}")).unwrap_err();
        assert!(
            matches!(err, CommandTextError::InvisibleChar { at: 2, codepoint } if codepoint == cp),
            "U+{cp:04X}: {err:?}"
        );
    }
}

#[test]
fn command_text_accepts_multi_line_commands_with_newlines_and_tabs() {
    assert_eq!(
        validate_command_text("set -e\nif true; then\n\techo \"héllo wörld\"\nfi"),
        Ok(())
    );
    assert_eq!(validate_command_text("php artisan queue:retry 8812"), Ok(()));
}

// ---------------------------------------------------------------------------
// View (the pane's wire model)
// ---------------------------------------------------------------------------

fn node_source(n: &ViewNode) -> &str {
    match n {
        ViewNode::Title { source, .. }
        | ViewNode::Section { source, .. }
        | ViewNode::LogHeading { source, .. }
        | ViewNode::Prose { source, .. }
        | ViewNode::LogLine { source, .. } => source,
        ViewNode::Item(item) => &item.source,
    }
}

fn facts() -> ViewFacts {
    ViewFacts {
        path: "/tmp/synthetic/.claude/wip/topic/index.md".into(),
        topic: "fallback-topic".into(),
        version: 7,
        ..Default::default()
    }
}

#[test]
fn view_node_sources_join_back_into_the_exact_file() {
    for name in ["board-60.md", "handwritten.md", "prose-only.md"] {
        let bytes = fixture_bytes(name);
        let parsed = parse_ok(&bytes);
        let view = view::build(&parsed, &facts());
        let joined: String = view.nodes.iter().map(node_source).collect();
        assert_bytes_eq(joined.as_bytes(), &bytes, &format!("{name}: joined node sources"));
    }
}

#[test]
fn view_items_carry_the_board_ids_in_file_order_and_prose_keys_are_unique() {
    for name in ["board-60.md", "handwritten.md"] {
        let parsed = parse_ok(&fixture_bytes(name));
        let view = view::build(&parsed, &facts());
        let ids: Vec<String> = view
            .nodes
            .iter()
            .filter_map(|n| match n {
                ViewNode::Item(i) => Some(i.id.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(ids, ids_of(&parsed.board), "{name}");
        let keys: Vec<&str> = view
            .nodes
            .iter()
            .filter_map(|n| match n {
                ViewNode::Prose { key, .. } => Some(key.as_str()),
                _ => None,
            })
            .collect();
        assert!(!keys.is_empty(), "{name} has prose");
        assert_eq!(keys.iter().collect::<HashSet<_>>().len(), keys.len(), "{name}: {keys:?}");
    }
}

#[test]
fn identical_prose_blocks_still_get_distinct_keys() {
    let src = md(&[
        "# T",
        "",
        "## One",
        "Same words here.",
        "",
        "## Two",
        "Same words here.",
        "",
        "## Three",
        "Same words here.",
    ]);
    let parsed = parse_ok(src.as_bytes());
    let view = view::build(&parsed, &facts());
    let keys: Vec<&str> = view
        .nodes
        .iter()
        .filter_map(|n| match n {
            ViewNode::Prose { key, .. } => Some(key.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(keys.len(), 3);
    assert_eq!(keys.iter().collect::<HashSet<_>>().len(), 3, "{keys:?}");
    let joined: String = view.nodes.iter().map(node_source).collect();
    assert_eq!(joined, src);
}

#[test]
fn view_reports_title_version_path_updated_time_and_log() {
    let (_, parsed) = board60();
    let view = view::build(&parsed, &facts());
    assert_eq!(view.title, "Synthetic release triage");
    assert_eq!(view.version, 7);
    assert_eq!(view.path, facts().path);
    assert_eq!(view.updated_at, parsed.board.updated_at());
    assert!(view.updated_at.is_some());
    assert_eq!(view.log.len(), 12);
    assert_eq!(view.log[0].time, "09:01");
    assert!(!view.hidden_by_user);

    let untitled = parse_ok(md(&["## Now", "- [ ] Item <!-- #a-1 1760540000 -->"]).as_bytes());
    assert_eq!(view::build(&untitled, &facts()).title, "fallback-topic");
}

#[test]
fn the_view_survives_a_json_round_trip() {
    let (_, parsed) = board60();
    let view = view::build(&parsed, &facts());
    let json = serde_json::to_string(&view).unwrap();
    let back: TrackerBoardView = serde_json::from_str(&json).unwrap();
    assert_eq!(back, view);
}

// ---------------------------------------------------------------------------
// The engine reads no clock (contract §12)
// ---------------------------------------------------------------------------

#[test]
fn only_clock_rs_reads_the_wall_clock() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/tracker");
    let mut scanned = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&path).unwrap();
        if name == "clock.rs" {
            assert!(text.contains("Utc::now"), "clock.rs is where the clock lives");
            continue;
        }
        scanned += 1;
        for (n, line) in text.lines().enumerate() {
            if line.trim_start().starts_with("//") {
                continue;
            }
            for needle in ["Utc::now", "SystemTime::now", "Local::now"] {
                assert!(
                    !line.contains(needle),
                    "{name}:{}: {needle} outside clock.rs",
                    n + 1
                );
            }
        }
    }
    assert!(scanned >= 8, "scanned {scanned} files");
}

#[test]
fn the_fake_clock_moves_only_when_told() {
    use nostromo::tracker::Clock;
    let clock = FakeClock::new(now0());
    assert_eq!(clock.now(), now0());
    assert_eq!(clock.now(), now0());
    clock.advance(Duration::seconds(90));
    assert_eq!(clock.now(), now0() + Duration::seconds(90));
    clock.set(utc(2030, 1, 1, 0, 0, 0));
    assert_eq!(clock.now(), utc(2030, 1, 1, 0, 0, 0));
    assert_eq!(FakeClock::at_secs(1_760_540_000).now().timestamp(), 1_760_540_000);
}
