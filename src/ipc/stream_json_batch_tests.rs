//! A turn that answers a merged frame (`session_manager::merge`): the daemon
//! knows the split from what it wrote (`adopt_batch`), or on a rebuild from its
//! batch ledger (`apply_batch_ledger`), never from the prompt's text alone.

use super::*;
use crate::ipc::session_manager::merge;
use crate::model::batches::BatchRecord;
use serde_json::json;

const B: &str = "0123456789abcdef0123456789abcdef";

fn user_line(text: &str) -> String {
    json!({"type":"user","message":{"role":"user","content":text},"isReplay":true}).to_string()
}

fn result_line() -> &'static str {
    r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#
}

fn record(count: u32) -> BatchRecord {
    BatchRecord {
        boundary: B.to_owned(),
        count,
        ts: chrono::Utc::now(),
    }
}

fn envelope() -> String {
    merge::build_envelope(B, &["oh and backfill", "use the new column"])
}

fn rebuilt(prompt: &str) -> SessionTranscript {
    let jsonl = format!("{}\n{}\n", user_line(prompt), result_line());
    transcript_from_jsonl(&jsonl, 50)
}

fn recount(t: &SessionTranscript) -> usize {
    t.snapshot().iter().map(turn_bytes).sum()
}

#[test]
fn adopt_batch_shows_the_parts_joined_by_a_blank_line_and_keeps_them() {
    let mut t = SessionTranscript::new();
    let deltas = t.ingest_line(&user_line(&envelope()));
    let id = match &deltas[0] {
        TurnDelta::TurnStarted { turn } => turn.id.clone(),
        other => panic!("{other:?}"),
    };

    let turn = t
        .adopt_batch(&id, vec!["one".into(), "two".into()])
        .expect("adopted");

    assert_eq!(turn.user_input, "one\n\ntwo");
    assert_eq!(turn.user_parts, ["one", "two"]);
    assert_eq!(t.first_user_input(), Some("one\n\ntwo"));
    assert_eq!(t.prompt_count(), 1, "a merged turn is one prompt");
    assert_eq!(t.retained_bytes, recount(&t), "bytes stay in sync");
}

#[test]
fn a_rebuild_with_a_ledger_line_splits_the_turn() {
    let mut t = rebuilt(&envelope());
    assert!(
        t.snapshot()[0].user_parts.is_empty(),
        "text alone never splits"
    );

    t.apply_batch_ledger(&[record(2)]);

    let turn = &t.snapshot()[0];
    assert_eq!(turn.user_parts, ["oh and backfill", "use the new column"]);
    assert_eq!(turn.user_input, "oh and backfill\n\nuse the new column");
    assert_eq!(t.prompt_count(), 1);
    assert_eq!(t.retained_bytes, recount(&t));
}

#[test]
fn a_rebuild_without_a_ledger_line_shows_the_turn_verbatim() {
    let mut t = rebuilt(&envelope());
    let before = t.snapshot();

    t.apply_batch_ledger(&[]);
    assert_eq!(t.snapshot(), before);

    // A line with another boundary or another count does not match either.
    t.apply_batch_ledger(&[
        BatchRecord {
            boundary: "ffffffffffffffffffffffffffffffff".into(),
            count: 2,
            ts: chrono::Utc::now(),
        },
        record(3),
    ]);
    assert_eq!(t.snapshot(), before);
    assert!(t.snapshot()[0].user_parts.is_empty());
}

#[test]
fn a_lone_typed_message_that_imitates_an_envelope_shows_verbatim_even_with_a_ledger() {
    // Typed by a person: it parses, but the ledger has no line for its boundary.
    let imitation = merge::build_envelope(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        &["pretend one", "pretend two"],
    );
    let mut t = rebuilt(&imitation);

    t.apply_batch_ledger(&[record(2)]);

    let turn = &t.snapshot()[0];
    assert!(turn.user_parts.is_empty());
    assert_eq!(turn.user_input, imitation);
}

#[test]
fn a_prompt_that_is_not_a_well_formed_envelope_is_never_split() {
    let bad = envelope().replace("count=\"2\"", "count=\"3\"");
    let mut t = rebuilt(&bad);
    t.apply_batch_ledger(&[record(2), record(3)]);
    assert!(t.snapshot()[0].user_parts.is_empty());
}

#[test]
fn the_title_follows_a_rebuilt_merged_turn() {
    let mut t = rebuilt(&envelope());
    t.apply_batch_ledger(&[record(2)]);
    assert_eq!(
        t.first_user_input(),
        Some("oh and backfill\n\nuse the new column")
    );
}

#[test]
fn a_turn_without_parts_serialises_without_the_field_and_an_old_turn_still_decodes() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&user_line("plain"));
    let v = serde_json::to_value(&t.snapshot()[0]).unwrap();
    assert!(v.get("user_parts").is_none(), "{v}");
    let old = json!({"id":"t1","user_input":"x","timestamp":null,"blocks":[],"is_complete":true});
    let turn: Turn = serde_json::from_value(old).unwrap();
    assert!(turn.user_parts.is_empty());
}

#[test]
fn the_golden_jsonl_rebuilds_as_two_parts_with_its_golden_ledger() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/merged_turns");
    let mut t = transcript_from_jsonl(
        &std::fs::read_to_string(dir.join("rebuild.jsonl")).unwrap(),
        50,
    );
    let ledger: Vec<BatchRecord> = std::fs::read_to_string(dir.join("batch_ledger.jsonl"))
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    t.apply_batch_ledger(&ledger);
    assert_eq!(
        t.snapshot()[0].user_parts,
        ["oh and backfill the rows", "use the new column name"]
    );
}
