//! Conversation compaction in a session's stream (Claude Code 2.1.318).
//!
//! Contract under test (see "Compact" in `docs/slash-commands.md`):
//!
//! * a `compact_boundary` line is read in both spellings (live
//!   `compact_metadata`/`pre_tokens`, stored `compactMetadata`/`preTokens`);
//!   a missing or non-numeric figure is `None`, unknown fields are ignored;
//! * a `system/status` line carrying `compact_result` is a compaction outcome
//!   (success or failure with its `compact_error`); a plain status such as
//!   `compacting` is not;
//! * a manual compaction ends in ONE `/compact` record whose `origin.compact`
//!   carries the tokens before and after (or that it failed and why), live and
//!   stored, after the summary marker; a boundary of any trigger sets the
//!   context figure to its `post_tokens`; a failure leaves it alone;
//! * an auto compaction makes no record and never leaves anything for a later
//!   `/compact` record to inherit; any other turn clears a waiting manual one;
//! * on the wire `compact` is omitted when absent, snake_case when set, and an
//!   origin written by an older daemon still reads.
//!
//! All text is fake.

use super::*;
use serde_json::{json, Value};

const LIVE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/stream_compact.jsonl"
));
const STORED: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/compact-session.jsonl"
));
const EMPTY_SESSION: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/stream_compact_failed.jsonl"
));

// ── builders ──────────────────────────────────────────────────────────────────

fn live_boundary(trigger: &str, pre: Option<u64>, post: Option<u64>) -> String {
    let mut meta = json!({"trigger": trigger});
    if let Some(p) = pre {
        meta["pre_tokens"] = json!(p);
    }
    if let Some(p) = post {
        meta["post_tokens"] = json!(p);
    }
    json!({"type": "system", "subtype": "compact_boundary", "session_id": "s",
           "compact_metadata": meta})
    .to_string()
}

fn status_result(result: &str, error: Option<&str>) -> String {
    let mut v = json!({"type": "system", "subtype": "status", "status": null,
                       "compact_result": result, "session_id": "s"});
    if let Some(e) = error {
        v["compact_error"] = json!(e);
    }
    v.to_string()
}

fn form_a_compact(stream: &str, text: &str) -> String {
    json!({
        "type": "assistant",
        "parent_tool_use_id": null,
        "local_command_source": format!("<local-command-{stream}>{text}</local-command-{stream}>"),
        "local_command_run": {"command": "compact", "args": ""},
        "message": {"model": "<synthetic>", "role": "assistant",
            "content": [{"type": "text", "text": text}]},
        "session_id": "s",
        "uuid": "u"
    })
    .to_string()
}

fn form_a_model() -> String {
    json!({
        "type": "assistant",
        "local_command_source": "<local-command-stdout>Set model</local-command-stdout>",
        "local_command_run": {"command": "model", "args": "haiku"},
        "message": {"role": "assistant", "content": [{"type": "text", "text": "Set model"}]}
    })
    .to_string()
}

fn user_text(content: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}}).to_string()
}

fn reply_with_context(text: &str, input_tokens: u64) -> String {
    json!({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "text", "text": text}],
        "usage": {"input_tokens": input_tokens, "output_tokens": 1,
                  "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
    .to_string()
}

const RESULT: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"total_cost_usd":0.0}"#;
const RESULT_LOCAL: &str = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":0,"num_turns":0,"total_cost_usd":0.0}"#;

type CompactionFields = (Option<String>, Option<u64>, Option<u64>, Option<bool>, Option<String>);

fn compaction_of(line: &str) -> CompactionFields {
    match parse_line(line) {
        Some(ParsedLine::Compaction {
            trigger,
            pre_tokens,
            post_tokens,
            succeeded,
            error,
        }) => (trigger, pre_tokens, post_tokens, succeeded, error),
        other => panic!("expected a compaction, got {other:?} for {line}"),
    }
}

/// A live transcript as the session reader drives it: a record that starts
/// answers the `/compact` the daemon wrote. Returns the transcript and every
/// completed turn's context figure, in order.
struct Run {
    t: SessionTranscript,
    completed_context: Vec<Option<u64>>,
}

impl Run {
    fn new() -> Self {
        let mut t = SessionTranscript::new();
        t.set_live(true);
        Run {
            t,
            completed_context: vec![],
        }
    }

    fn feed(&mut self, line: &str) {
        for d in self.t.ingest_line(line) {
            match d {
                TurnDelta::TurnStarted { turn } if is_record(&turn) => {
                    let _ = self.t.adopt_written_command(&turn.id, "/compact");
                }
                TurnDelta::TurnCompleted { context_tokens, .. } => {
                    self.completed_context.push(context_tokens);
                }
                _ => {}
            }
        }
    }

    fn feed_all<S: AsRef<str>>(&mut self, lines: &[S]) {
        for l in lines {
            self.feed(l.as_ref());
        }
    }
}

fn is_record(t: &Turn) -> bool {
    matches!(t.origin, Some(TurnOrigin::LocalCommand { .. }))
}

fn compact_of(t: &Turn) -> Option<CompactInfo> {
    match &t.origin {
        Some(TurnOrigin::LocalCommand { compact, .. }) => compact.clone(),
        other => panic!("not a record: {other:?}"),
    }
}

fn is_summary_marker(t: &Turn) -> bool {
    matches!(&t.origin, Some(TurnOrigin::InjectedContext { kind, .. }) if kind == "summary")
}

fn info(pre: Option<u64>, post: Option<u64>) -> CompactInfo {
    CompactInfo {
        pre_tokens: pre,
        post_tokens: post,
        failed: false,
        error: None,
    }
}

// ── parsing: the boundary ─────────────────────────────────────────────────────

#[test]
fn a_live_boundary_reads_its_trigger_and_token_counts_from_compact_metadata() {
    let (trigger, pre, post, succeeded, error) =
        compaction_of(&live_boundary("manual", Some(3429), Some(643)));

    assert_eq!(trigger.as_deref(), Some("manual"));
    assert_eq!((pre, post), (Some(3429), Some(643)));
    assert_eq!(succeeded, None, "a boundary is not a status verdict");
    assert_eq!(error, None);
}

#[test]
fn a_stored_boundary_reads_the_same_figures_from_camel_case_compact_metadata() {
    let line = json!({"type": "system", "subtype": "compact_boundary",
        "content": "Conversation compacted",
        "compactMetadata": {"trigger": "auto", "preTokens": 150000, "postTokens": 9000,
                            "durationMs": 5, "cumulativeDroppedTokens": 1}})
    .to_string();

    let (trigger, pre, post, succeeded, _) = compaction_of(&line);

    assert_eq!(trigger.as_deref(), Some("auto"));
    assert_eq!((pre, post), (Some(150000), Some(9000)));
    assert_eq!(succeeded, None);
}

#[test]
fn a_boundary_missing_a_figure_reads_it_as_none_and_the_other_survives() {
    let (_, pre, post, _, _) = compaction_of(&live_boundary("manual", Some(3429), None));
    assert_eq!((pre, post), (Some(3429), None));

    let (_, pre, post, _, _) = compaction_of(&live_boundary("manual", None, Some(643)));
    assert_eq!((pre, post), (None, Some(643)));
}

#[test]
fn a_boundary_with_no_metadata_at_all_is_still_a_compaction_with_nothing_known() {
    let line = json!({"type": "system", "subtype": "compact_boundary"}).to_string();
    assert_eq!(compaction_of(&line), (None, None, None, None, None));
}

#[test]
fn a_boundary_with_figures_that_are_not_numbers_reads_them_as_none() {
    let line = json!({"type": "system", "subtype": "compact_boundary",
        "compact_metadata": {"trigger": "manual", "pre_tokens": "lots",
                             "post_tokens": -5}})
    .to_string();

    let (trigger, pre, post, _, _) = compaction_of(&line);

    assert_eq!(trigger.as_deref(), Some("manual"));
    assert_eq!((pre, post), (None, None));
}

#[test]
fn a_boundary_ignores_fields_this_build_does_not_know() {
    let line = json!({"type": "system", "subtype": "compact_boundary",
        "future_field": {"a": 1}, "logical_parent_uuid": "x",
        "compact_metadata": {"trigger": "manual", "pre_tokens": 10, "post_tokens": 4,
                             "something_new": [1, 2, 3], "duration_ms": 9}})
    .to_string();

    let (trigger, pre, post, _, _) = compaction_of(&line);

    assert_eq!(trigger.as_deref(), Some("manual"));
    assert_eq!((pre, post), (Some(10), Some(4)));
}

// ── parsing: the status verdict ───────────────────────────────────────────────

#[test]
fn a_status_line_with_a_successful_compact_result_is_a_success_verdict() {
    let (trigger, pre, post, succeeded, error) = compaction_of(&status_result("success", None));

    assert_eq!((trigger, pre, post, error), (None, None, None, None));
    assert_eq!(succeeded, Some(true));
}

#[test]
fn a_status_line_with_a_failed_compact_result_carries_its_error() {
    let (_, _, _, succeeded, error) = compaction_of(&status_result(
        "failed",
        Some("Not enough messages to compact."),
    ));

    assert_eq!(succeeded, Some(false));
    assert_eq!(error.as_deref(), Some("Not enough messages to compact."));
}

#[test]
fn a_failed_status_without_an_error_text_is_still_a_failure() {
    let (_, _, _, succeeded, error) = compaction_of(&status_result("failed", None));
    assert_eq!(succeeded, Some(false));
    assert_eq!(error, None);
}

#[test]
fn a_failure_text_is_one_line() {
    let (_, _, _, _, error) =
        compaction_of(&status_result("failed", Some("first\nsecond\r\nthird")));
    let error = error.expect("an error text");
    assert!(!error.contains('\n') && !error.contains('\r'), "{error:?}");
}

#[test]
fn a_status_of_compacting_is_not_a_compaction_outcome() {
    let compacting = json!({"type": "system", "subtype": "status", "status": "compacting",
                            "session_id": "s"})
    .to_string();
    assert!(
        matches!(parse_line(&compacting), Some(ParsedLine::SessionId(_)) | None),
        "{:?}",
        parse_line(&compacting)
    );

    let anonymous = json!({"type": "system", "subtype": "status", "status": "compacting"})
        .to_string();
    assert!(
        !matches!(parse_line(&anonymous), Some(ParsedLine::Compaction { .. })),
        "{:?}",
        parse_line(&anonymous)
    );
}

#[test]
fn a_status_of_compacting_opens_no_turn_and_changes_nothing() {
    let mut run = Run::new();
    run.feed(&json!({"type": "system", "subtype": "status", "status": "compacting",
                     "session_id": "s"})
    .to_string());
    assert_eq!(run.t.turn_count(), 0);
}

// ── transcript: a live manual compaction ──────────────────────────────────────

#[test]
fn a_live_manual_compaction_is_a_summary_marker_then_one_compact_record_with_the_tokens() {
    let mut run = Run::new();
    run.feed_all(&LIVE.lines().collect::<Vec<_>>());

    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 3, "prompt, summary marker, record: {turns:?}");
    assert_eq!(turns[0].user_input, "Say only: hi");
    assert!(is_summary_marker(&turns[1]), "{:?}", turns[1]);
    assert!(is_record(&turns[2]), "{:?}", turns[2]);
    assert_eq!(turns[2].user_input, "/compact");
    assert!(turns.iter().all(|t| t.is_complete));
    assert!(matches!(
        &turns[2].origin,
        Some(TurnOrigin::LocalCommand { command, .. }) if command == "compact"
    ));
    assert_eq!(compact_of(&turns[2]), Some(info(Some(3429), Some(643))));
    assert_eq!(run.t.prompt_count(), 1, "neither marker nor record is a prompt");
    assert_eq!(run.t.first_user_input(), Some("Say only: hi"));
}

#[test]
fn the_record_of_a_live_compaction_completes_with_the_context_at_its_post_compaction_size() {
    let mut run = Run::new();
    run.feed_all(&LIVE.lines().collect::<Vec<_>>());

    assert_eq!(
        run.completed_context,
        vec![Some(3400), Some(643)],
        "the prompt's turn ends at its own size, the compaction's at post_tokens"
    );
}

#[test]
fn a_compaction_before_its_record_is_not_a_turn_of_its_own() {
    let mut run = Run::new();
    run.feed(&live_boundary("manual", Some(100), Some(20)));
    run.feed(&status_result("success", None));
    assert_eq!(run.t.turn_count(), 0);
}

// ── transcript: a live failure ────────────────────────────────────────────────

#[test]
fn a_failed_live_compaction_is_a_record_marked_failed_with_its_error_and_no_token_change() {
    let mut run = Run::new();
    run.feed_all(&[
        user_text("hello"),
        reply_with_context("hi", 5000),
        RESULT.to_owned(),
    ]);
    run.feed_all(&[
        status_result("failed", Some("Not enough messages to compact.")),
        form_a_compact("stderr", "Error: Not enough messages to compact."),
        RESULT_LOCAL.to_owned(),
    ]);

    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert!(is_record(&turns[1]));
    assert_eq!(turns[1].user_input, "/compact");
    assert!(turns[1].is_complete);
    let c = compact_of(&turns[1]).expect("the record says what happened");
    assert!(c.failed);
    assert_eq!(c.error.as_deref(), Some("Not enough messages to compact."));
    assert_eq!((c.pre_tokens, c.post_tokens), (None, None));
    assert_eq!(
        run.completed_context,
        vec![Some(5000), Some(5000)],
        "a failure leaves the context figure where it was"
    );
}

#[test]
fn a_compact_in_an_empty_session_is_an_ordinary_error_record_without_compaction_figures() {
    let mut run = Run::new();
    run.feed_all(&EMPTY_SESSION.lines().collect::<Vec<_>>());

    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert!(is_record(&turns[0]));
    assert!(matches!(
        &turns[0].origin,
        Some(TurnOrigin::LocalCommand { command, stream, output, .. })
            if command == "compact" && stream == "stderr"
                && output == "Error: No messages to compact"
    ));
    assert_eq!(compact_of(&turns[0]), None);
    assert_eq!(run.t.prompt_count(), 0);
}

// ── transcript: stored replay ─────────────────────────────────────────────────

#[test]
fn a_stored_compaction_replays_as_the_same_summary_marker_and_compact_record() {
    let t = transcript_from_jsonl(STORED, 100);

    let turns = t.snapshot();
    let record = turns
        .iter()
        .find(|t| is_record(t))
        .unwrap_or_else(|| panic!("no record in {turns:?}"));
    assert_eq!(record.user_input, "/compact");
    assert!(record.is_complete);
    assert_eq!(compact_of(record), Some(info(Some(3429), Some(643))));
    assert_eq!(turns.iter().filter(|t| is_record(t)).count(), 1);
    let marker = turns.iter().position(is_summary_marker).expect("summary marker");
    let rec = turns.iter().position(is_record).unwrap();
    assert!(marker < rec, "the summary precedes the record: {turns:?}");
    assert!(turns.iter().all(|t| t.is_complete));
    assert_eq!(t.prompt_count(), 1, "only the first prompt counts");
    assert_eq!(t.first_user_input(), Some("Say only: hi"));
}

// ── transcript: auto and stale pending ────────────────────────────────────────

#[test]
fn an_auto_boundary_mid_turn_makes_no_record_and_moves_the_context_figure() {
    let mut run = Run::new();
    run.feed_all(&[
        user_text("work"),
        reply_with_context("working", 190_000),
        live_boundary("auto", Some(190_000), Some(8_000)),
        reply_with_context("done", 9_000),
        RESULT.to_owned(),
    ]);
    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 1, "no record, no turn of its own: {turns:?}");
    assert!(!is_record(&turns[0]));

    // And with nothing after the boundary, the turn ends at the new size.
    let mut run = Run::new();
    run.feed_all(&[
        user_text("work"),
        reply_with_context("working", 190_000),
        live_boundary("auto", Some(190_000), Some(8_000)),
        RESULT.to_owned(),
    ]);
    assert_eq!(run.completed_context, vec![Some(8_000)]);
}

#[test]
fn an_auto_boundary_leaves_nothing_for_a_later_compact_record_to_inherit() {
    let mut run = Run::new();
    run.feed_all(&[
        user_text("work"),
        reply_with_context("working", 190_000),
        live_boundary("auto", Some(190_000), Some(8_000)),
        RESULT.to_owned(),
    ]);
    // No turn starts in between that would clear it by itself.
    run.feed_all(&[
        form_a_compact("stderr", "Error: No messages to compact"),
        RESULT_LOCAL.to_owned(),
    ]);

    let turns = run.t.snapshot();
    let record = turns.last().unwrap();
    assert!(is_record(record));
    assert_eq!(compact_of(record), None);
}

#[test]
fn a_waiting_manual_compaction_is_not_inherited_by_a_different_local_command() {
    let mut run = Run::new();
    run.feed_all(&[
        live_boundary("manual", Some(100), Some(20)),
        form_a_model(),
        RESULT_LOCAL.to_owned(),
    ]);
    // A later /compact that has nothing of its own must not pick up the old one.
    run.feed_all(&[
        form_a_compact("stderr", "Error: No messages to compact"),
        RESULT_LOCAL.to_owned(),
    ]);

    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_eq!(compact_of(&turns[0]), None, "/model is not a compaction");
    assert_eq!(compact_of(&turns[1]), None, "the stale one was spent");
}

#[test]
fn a_waiting_failure_or_manual_boundary_is_cleared_when_another_turn_starts_before_the_compact_record() {
    let mut run = Run::new();
    run.feed_all(&[
        status_result("failed", Some("boom")),
        user_text("an ordinary prompt"),
        reply_with_context("ok", 1000),
        RESULT.to_owned(),
        form_a_compact("stderr", "Error: No messages to compact"),
        RESULT_LOCAL.to_owned(),
    ]);

    let turns = run.t.snapshot();
    assert_eq!(turns.len(), 2, "{turns:?}");
    assert_eq!(compact_of(&turns[1]), None);
}

// ── the wire form ─────────────────────────────────────────────────────────────

fn record_origin(compact: Option<CompactInfo>) -> TurnOrigin {
    TurnOrigin::LocalCommand {
        command: "compact".into(),
        args: String::new(),
        output: "Compacted ".into(),
        stream: "stdout".into(),
        truncated: false,
        compact,
    }
}

#[test]
fn compact_is_left_out_of_the_wire_form_when_there_is_none() {
    let wire: Value = serde_json::to_value(record_origin(None)).unwrap();
    assert!(wire.get("compact").is_none(), "{wire}");
}

#[test]
fn a_successful_compaction_is_sent_with_snake_case_token_fields_only() {
    let wire: Value =
        serde_json::to_value(record_origin(Some(info(Some(3429), Some(643))))).unwrap();
    assert_eq!(wire["compact"], json!({"pre_tokens": 3429, "post_tokens": 643}));
}

#[test]
fn a_failed_compaction_is_sent_with_failed_true_and_its_error() {
    let c = CompactInfo {
        failed: true,
        error: Some("Not enough messages to compact.".into()),
        ..CompactInfo::default()
    };
    let wire: Value = serde_json::to_value(record_origin(Some(c))).unwrap();
    assert_eq!(
        wire["compact"],
        json!({"failed": true, "error": "Not enough messages to compact."})
    );
}

#[test]
fn a_record_origin_with_a_compaction_survives_a_round_trip() {
    for c in [
        info(Some(3429), Some(643)),
        info(None, None),
        CompactInfo {
            failed: true,
            error: Some("why".into()),
            ..CompactInfo::default()
        },
    ] {
        let origin = record_origin(Some(c));
        let back: TurnOrigin =
            serde_json::from_str(&serde_json::to_string(&origin).unwrap()).unwrap();
        assert_eq!(back, origin);
    }
}

#[test]
fn an_origin_from_before_compaction_existed_still_reads_with_no_compact() {
    let old = json!({"type": "local_command", "command": "compact", "args": "",
                     "output": "Compacted ", "stream": "stdout"});

    let origin: TurnOrigin = serde_json::from_value(old).unwrap();

    assert_eq!(origin, record_origin(None));
}

#[test]
fn a_compact_object_with_unknown_fields_still_reads() {
    let v = json!({"type": "local_command", "command": "compact", "args": "",
                   "output": "", "stream": "stdout",
                   "compact": {"pre_tokens": 5, "post_tokens": 2, "newer": true}});

    let origin: TurnOrigin = serde_json::from_value(v).unwrap();

    assert!(matches!(
        origin,
        TurnOrigin::LocalCommand { compact: Some(c), .. } if c == info(Some(5), Some(2))
    ));
}
