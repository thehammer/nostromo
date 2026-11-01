//! Turn origin of a task wake (BA6a): when a background task finishes or a
//! Monitor emits an event, the CLI wakes the agent with a `<task-notification>`
//! user event and the agent answers it. That answer must not land on the
//! previous turn, and the notification must never be shown as something the
//! user typed.
//!
//! Contract under test (BA6a-1 .. BA6a-10):
//!
//! * a user event whose content (a string, or text blocks, after leading
//!   whitespace) starts `<task-notification>` opens a turn of its own with
//!   `TurnOrigin::TaskWake`; the reply and the `result` belong to it; the
//!   previous turn keeps exactly one result summary;
//! * the CLI's other injected user events (`<system-reminder>`,
//!   `<local-command-*>`, `<command-*>`) still make no turn;
//! * [`parse_task_wake`] reads only the metadata before a body: kind, outcome,
//!   description (between the summary prefix's quote and its last `"`), ids;
//!   bodies, output paths and summary tails are never kept; descriptions are
//!   sanitised and capped, ids restricted, items capped with an `omitted`
//!   count;
//! * the turn's `user_input` is a fallback line ([`task_wake_line`]), never
//!   the notification;
//! * two notifications with no reply between merge into the open wake turn
//!   (`take_origin_update` carries the full merged origin);
//! * a wake is not a prompt: `prompt_count` and the session title ignore it;
//! * ledger notes land on the same turn live and after a rebuild;
//! * the canonical wake turn and the origin-update frame are pinned in
//!   `tests/fixtures/background-activity/` (the Kit/Mac tests decode them).
//!   `UPDATE_GOLDEN=1` rewrites them.

use super::*;
use crate::model::notes::{LedgerNote, NoteKind};
use serde_json::{json, Value};

const SESSION: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/src/ipc/testdata/wake-session.jsonl"
));

// ── builders ──────────────────────────────────────────────────────────────────

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// A notification as the CLI writes it; `summary` is plain text, escaped here.
fn notification_full(
    task_id: &str,
    tool_use_id: &str,
    status: &str,
    summary: &str,
    tail: &str,
) -> String {
    let mut s = format!(
        "<task-notification>\n<task-id>{task_id}</task-id>\n<tool-use-id>{tool_use_id}</tool-use-id>\n<output-file>/tmp/claude-501/tasks/{task_id}.output</output-file>\n<status>{status}</status>\n<summary>{}</summary>",
        xml_escape(summary)
    );
    if !tail.is_empty() {
        s.push('\n');
        s.push_str(tail);
    }
    s.push_str("\n</task-notification>");
    s
}

fn notification(status: &str, summary: &str) -> String {
    notification_full("task1", "toolu_task1", status, summary, "")
}

/// A user event with string content, as a stored session holds it.
fn stored_user(content: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}}).to_string()
}

fn stored_user_at(content: &str, ts: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}, "timestamp": ts})
        .to_string()
}

/// As the live CLI echoes it.
fn live_user(content: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}, "isReplay": true})
        .to_string()
}

fn reply(text: &str) -> String {
    json!({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
        .to_string()
}

fn result() -> &'static str {
    r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#
}

fn wake_item(kind: &str, outcome: &str, description: &str) -> TaskWakeItem {
    TaskWakeItem {
        task_id: None,
        tool_use_id: None,
        kind: kind.into(),
        outcome: outcome.into(),
        description: description.into(),
    }
}

/// Parse `content` as a user event's string content; it must be a wake.
fn wake_of(content: &str) -> (Vec<TaskWakeItem>, u32) {
    match parse_line(&stored_user(content)) {
        Some(ParsedLine::TaskWake { items, omitted, .. }) => (items, omitted),
        other => panic!("expected a wake, got {other:?}"),
    }
}

fn only_item(content: &str) -> TaskWakeItem {
    let (mut items, omitted) = wake_of(content);
    assert_eq!(omitted, 0);
    assert_eq!(items.len(), 1, "{items:?}");
    items.remove(0)
}

fn many(n: usize) -> String {
    (0..n)
        .map(|i| {
            notification_full(
                &format!("t{i}"),
                &format!("toolu_{i}"),
                "completed",
                &format!("Background command \"cmd {i}\" completed (exit code 0)"),
                "",
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn wake_origin(turn: &Turn) -> (&[TaskWakeItem], u32) {
    match &turn.origin {
        Some(TurnOrigin::TaskWake { items, omitted }) => (items, *omitted),
        other => panic!("a task wake origin, got {other:?}"),
    }
}

fn is_wake(turn: &Turn) -> bool {
    matches!(turn.origin, Some(TurnOrigin::TaskWake { .. }))
}

fn count_results(turn: &Turn) -> usize {
    turn.blocks
        .iter()
        .filter(|b| matches!(b, TurnBlock::ResultSummary { .. }))
        .count()
}

fn texts(turn: &Turn) -> Vec<String> {
    turn.blocks
        .iter()
        .filter_map(|b| match b {
            TurnBlock::Text { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn ingest_all(t: &mut SessionTranscript, lines: &[String]) -> Vec<TurnDelta> {
    lines.iter().flat_map(|l| t.ingest_line(l)).collect()
}

// ── BA6a-1: a wake opens a turn of its own ────────────────────────────────────

#[test]
fn a_live_wake_opens_its_own_turn_and_the_reply_and_result_belong_to_it() {
    let mut t = SessionTranscript::new();
    ingest_all(
        &mut t,
        &[live_user("check the build"), reply("fine"), result().into()],
    );

    let wake_deltas = t.ingest_line(&live_user(&notification(
        "completed",
        "Monitor event: \"CI for PR #251\"",
    )));
    let after = ingest_all(&mut t, &[reply("CI passed."), result().into()]);

    let started = match &wake_deltas[..] {
        [TurnDelta::TurnStarted { turn }] => turn.clone(),
        other => panic!("a wake opens exactly one turn and ends none: {other:?}"),
    };
    assert!(is_wake(&started));
    let turns = t.snapshot();
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[1].id, started.id);
    assert_eq!(texts(&turns[0]), vec!["fine"]);
    assert_eq!(texts(&turns[1]), vec!["CI passed."]);
    assert!(turns[0].is_complete && turns[1].is_complete);
    assert!(after.iter().all(|d| match d {
        TurnDelta::BlockAppended { turn_id, .. } | TurnDelta::TurnCompleted { turn_id, .. } =>
            *turn_id == started.id,
        _ => true,
    }));
}

#[test]
fn the_previous_turn_keeps_exactly_one_result_summary_and_completes_once() {
    let mut t = SessionTranscript::new();
    let mut deltas = ingest_all(&mut t, &[live_user("first"), reply("a"), result().into()]);
    deltas.extend(ingest_all(
        &mut t,
        &[
            live_user(&notification("completed", "Agent \"x\" completed")),
            reply("b"),
            result().into(),
        ],
    ));

    let turns = t.snapshot();
    assert_eq!(count_results(&turns[0]), 1);
    assert_eq!(count_results(&turns[1]), 1);
    let completed: Vec<&str> = deltas
        .iter()
        .filter_map(|d| match d {
            TurnDelta::TurnCompleted { turn_id, .. } => Some(turn_id.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        completed,
        vec![turns[0].id.as_str(), turns[1].id.as_str()],
        "one TurnCompleted per turn, the first not repeated"
    );
}

#[test]
fn a_stored_session_without_result_lines_splits_a_wake_off_the_previous_turn() {
    let jsonl = [
        stored_user("first"),
        reply("a"),
        stored_user(&notification("completed", "Agent \"x\" completed")),
        reply("b"),
    ]
    .join("\n");

    let turns = transcript_from_jsonl(&jsonl, 100).snapshot();

    assert_eq!(turns.len(), 2);
    assert_eq!(texts(&turns[0]), vec!["a"]);
    assert_eq!(texts(&turns[1]), vec!["b"]);
    assert!(turns[0].is_complete);
    assert_eq!(turns[0].origin, None);
    assert!(is_wake(&turns[1]));
}

#[test]
fn a_wake_is_recognised_in_text_blocks_and_after_leading_whitespace() {
    let n = notification("completed", "Agent \"x\" completed");
    let blocks = json!({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": n}]}})
        .to_string();
    let spaced = stored_user(&format!("\n\n  {n}"));
    let spaced_blocks = json!({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": format!("\n {n}")}]}})
        .to_string();

    for line in [blocks, spaced, spaced_blocks] {
        assert!(
            matches!(parse_line(&line), Some(ParsedLine::TaskWake { .. })),
            "{line}"
        );
    }
}

#[test]
fn the_wake_keeps_the_timestamp_of_its_event() {
    let n = notification("completed", "Agent \"x\" completed");

    match parse_line(&stored_user_at(&n, "2026-11-01T10:01:00.000Z")) {
        Some(ParsedLine::TaskWake { timestamp, .. }) => {
            assert_eq!(timestamp.as_deref(), Some("2026-11-01T10:01:00.000Z"))
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_scheduled_trigger_with_a_task_notification_origin_but_plain_content_is_a_prompt() {
    let line = json!({
        "type": "user",
        "message": {"role": "user", "content": "run the nightly check"},
        "origin": {"kind": "task-notification"},
    })
    .to_string();

    assert!(matches!(
        parse_line(&line),
        Some(ParsedLine::UserPrompt { text, .. }) if text == "run the nightly check"
    ));
}

// ── BA6a-2: the CLI's other injected events stay dropped ──────────────────────

#[test]
fn the_clis_other_injected_user_events_still_make_no_turn() {
    for content in [
        "<system-reminder>be careful</system-reminder>",
        "<local-command-caveat>Caveat: generated locally</local-command-caveat>",
        "<local-command-stdout>Set model to opus</local-command-stdout>",
        "<command-name>/model</command-name>\n<command-message>model</command-message>",
        "<command-message>model</command-message>",
        "<command-args>opus</command-args>",
    ] {
        assert_eq!(parse_line(&stored_user(content)), None, "{content}");
        let mut t = SessionTranscript::new();
        assert!(t.ingest_line(&stored_user(content)).is_empty());
        assert_eq!(t.turn_count(), 0);
    }
}

// ── BA6a-3: what a notification is read as ────────────────────────────────────

#[test]
fn the_summary_wording_decides_kind_outcome_and_description() {
    // (status, summary, kind, outcome, description)
    let rows = [
        (
            "completed",
            "Monitor event: \"CI for PR #251\"",
            "monitor",
            "new_output",
            "CI for PR #251",
        ),
        (
            "failed",
            "Monitor event: \"CI for PR #251\"",
            "monitor",
            "new_output",
            "CI for PR #251",
        ),
        (
            "completed",
            "Monitor \"deploy watch\" stream ended",
            "monitor",
            "ended",
            "deploy watch",
        ),
        (
            "failed",
            "Monitor \"deploy watch\" script failed (exit code 2)",
            "monitor",
            "failed",
            "deploy watch",
        ),
        (
            "killed",
            "Monitor \"deploy watch\" was stopped",
            "monitor",
            "stopped",
            "deploy watch",
        ),
        (
            "completed",
            "Monitor \"deploy watch\" timed out",
            "monitor",
            "completed",
            "deploy watch",
        ),
        (
            "completed",
            "Background command \"npm test\" completed (exit code 0)",
            "shell",
            "completed",
            "npm test",
        ),
        (
            "failed",
            "Background command \"npm test\" failed with exit code 1",
            "shell",
            "failed",
            "npm test",
        ),
        (
            "killed",
            "Background command \"sleep 600\" was stopped",
            "shell",
            "stopped",
            "sleep 600",
        ),
        (
            "stopped",
            "Background command \"sleep 600\" was stopped",
            "shell",
            "stopped",
            "sleep 600",
        ),
        (
            "completed",
            "Agent \"review the diff\" completed",
            "agent",
            "completed",
            "review the diff",
        ),
        (
            "failed",
            "Agent \"review the diff\" failed: boom",
            "agent",
            "failed",
            "review the diff",
        ),
        (
            "completed",
            "Background agent \"review\" completed",
            "agent",
            "completed",
            "review",
        ),
        (
            "failed",
            "Background agent \"review\" failed",
            "agent",
            "failed",
            "review",
        ),
        (
            "completed",
            "MCP task \"import\" completed",
            "other",
            "completed",
            "",
        ),
        (
            "failed",
            "Something nobody has heard of",
            "other",
            "failed",
            "",
        ),
    ];

    for (status, summary, kind, outcome, description) in rows {
        let got = only_item(&notification(status, summary));
        assert_eq!(
            (
                got.kind.as_str(),
                got.outcome.as_str(),
                got.description.as_str()
            ),
            (kind, outcome, description),
            "status {status:?}, summary {summary:?}"
        );
    }
}

#[test]
fn the_status_maps_to_the_outcome_when_the_summary_does_not_say() {
    for (status, outcome) in [
        ("completed", "completed"),
        ("failed", "failed"),
        ("killed", "stopped"),
        ("stopped", "stopped"),
        ("cancelled-by-a-newer-cli", "event"),
        ("", "event"),
    ] {
        let got = only_item(&notification(status, "MCP task \"x\" done"));
        assert_eq!(got.outcome, outcome, "status {status:?}");
    }
}

#[test]
fn a_notification_without_a_status_or_summary_is_a_plain_event() {
    let got = only_item("<task-notification>\n<task-id>abc123</task-id>\n</task-notification>");

    assert_eq!(
        got,
        TaskWakeItem {
            task_id: Some("abc123".into()),
            tool_use_id: None,
            kind: "other".into(),
            outcome: "event".into(),
            description: String::new(),
        }
    );
}

#[test]
fn a_notification_with_nothing_readable_is_still_one_other_event() {
    for content in [
        "<task-notification>",
        "<task-notification></task-notification>",
        "<task-notification>garbage with no elements",
    ] {
        let got = only_item(content);
        assert_eq!(
            (
                got.kind.as_str(),
                got.outcome.as_str(),
                got.description.as_str()
            ),
            ("other", "event", ""),
            "{content}"
        );
        assert_eq!((got.task_id, got.tool_use_id), (None, None));
    }
}

#[test]
fn a_resume_orphan_takes_the_first_real_task_id() {
    let content = "<task-notification>\n<task-id>__orphan_summary__:shell</task-id>\n<task-id>b9f3k2m</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n<status>completed</status>\n<summary>Background command &quot;ls&quot; completed (exit code 0)</summary>\n</task-notification>";

    let got = only_item(content);

    assert_eq!(got.task_id.as_deref(), Some("b9f3k2m"));
    assert_eq!(got.tool_use_id.as_deref(), Some("toolu_01"));
}

#[test]
fn an_orphan_with_no_real_id_has_no_task_id() {
    let content = "<task-notification>\n<task-id>__orphan_summary__:shell</task-id>\n<status>completed</status>\n</task-notification>";

    assert_eq!(only_item(content).task_id, None);
}

#[test]
fn ids_are_read_from_their_elements() {
    let got = only_item(&notification_full(
        "bq81n2xk",
        "toolu_01ABC",
        "completed",
        "Agent \"x\" completed",
        "",
    ));

    assert_eq!(got.task_id.as_deref(), Some("bq81n2xk"));
    assert_eq!(got.tool_use_id.as_deref(), Some("toolu_01ABC"));
}

#[test]
fn the_description_runs_to_the_last_quote_so_a_command_may_contain_quotes() {
    let got = only_item(&notification(
        "completed",
        "Background command \"echo \"hi\" && ls\" completed (exit code 0)",
    ));

    assert_eq!(got.description, "echo \"hi\" && ls");
}

#[test]
fn entities_in_the_summary_are_decoded() {
    let content = "<task-notification>\n<task-id>t1</task-id>\n<status>completed</status>\n<summary>Background command &quot;a &lt; b &amp;&amp; c &gt; d &apos;e&apos; &#65;&#x42;&quot; completed (exit code 0)</summary>\n</task-notification>";

    assert_eq!(only_item(content).description, "a < b && c > d 'e' AB");
}

#[test]
fn entities_are_decoded_exactly_once() {
    let content = "<task-notification>\n<task-id>t1</task-id>\n<status>completed</status>\n<summary>Background command &quot;&amp;lt;b&amp;gt; &amp;amp; &amp;quot;&quot; completed</summary>\n</task-notification>";

    assert_eq!(only_item(content).description, "&lt;b&gt; &amp; &quot;");
}

#[test]
fn several_notifications_in_one_event_are_items_in_message_order() {
    let content = [
        notification_full(
            "a",
            "toolu_a",
            "failed",
            "Background command \"one\" failed (exit code 1)",
            "",
        ),
        notification_full(
            "b",
            "toolu_b",
            "completed",
            "Monitor \"two\" stream ended",
            "",
        ),
        notification_full("c", "toolu_c", "completed", "Agent \"three\" completed", ""),
    ]
    .join("\n");

    let (items, omitted) = wake_of(&content);

    assert_eq!(omitted, 0);
    let seen: Vec<(&str, &str, &str)> = items
        .iter()
        .map(|i| {
            (
                i.task_id.as_deref().unwrap(),
                i.kind.as_str(),
                i.outcome.as_str(),
            )
        })
        .collect();
    assert_eq!(
        seen,
        vec![
            ("a", "shell", "failed"),
            ("b", "monitor", "ended"),
            ("c", "agent", "completed")
        ]
    );
}

// ── BA6a-4: nothing of a body, output file or tail is kept ────────────────────

const FORBIDDEN: &[&str] = &[
    "<task-notification>",
    "</task-notification>",
    "<event>",
    "<result>",
    "<note>",
    "<usage>",
    "<summary>",
    "<status>",
    "<task-id>",
    "<output-file>",
    "/tmp/claude",
    ".output",
    "exit code",
    "SECRET-",
];

fn assert_clean(what: &str, text: &str) {
    for bad in FORBIDDEN {
        assert!(!text.contains(bad), "{what} holds {bad:?}: {text}");
    }
}

#[test]
fn nothing_of_a_notifications_body_path_or_tail_reaches_a_turn_or_a_delta() {
    let lines: Vec<String> = SESSION.lines().map(str::to_owned).collect();
    let mut live = SessionTranscript::new();
    let mut sink = String::new();
    for line in &lines {
        for delta in live.ingest_line(line) {
            sink.push_str(&serde_json::to_string(&delta).unwrap());
            sink.push('\n');
        }
        if let Some((id, origin)) = live.take_origin_update() {
            let msg = crate::ipc::protocol::ServerMsg::SessionTurnOrigin {
                tag: "claudia-ABCD1234".into(),
                turn_id: id,
                origin,
            };
            sink.push_str(&serde_json::to_string(&msg).unwrap());
            sink.push('\n');
        }
    }
    assert_clean("a live delta or frame", &sink);
    assert_clean(
        "the live snapshot",
        &serde_json::to_string(&live.snapshot()).unwrap(),
    );
    assert_clean(
        "the rebuilt snapshot",
        &serde_json::to_string(&transcript_from_jsonl(SESSION, 1000).snapshot()).unwrap(),
    );
    // The fixture really has the sentinels, so the checks above can fail.
    assert!(SESSION.contains("SECRET-OUTPUT-RESULT"));
    assert!(SESSION.contains("exit code 1"));
}

#[test]
fn a_bodys_text_is_never_the_description_or_the_fallback_line() {
    let n = notification_full(
        "t1",
        "toolu_1",
        "completed",
        "Agent \"review\" completed",
        "<result>SECRET-OUTPUT-BODY</result>\n<usage>total_tokens: 9</usage>",
    );
    let mut t = SessionTranscript::new();

    t.ingest_line(&live_user(&n));

    let turns = t.snapshot();
    assert_clean("the turn", &serde_json::to_string(&turns).unwrap());
    assert_eq!(turns[0].user_input, "⟲ Agent: finished \"review\"");
}

// ── hostile input ─────────────────────────────────────────────────────────────

#[test]
fn an_escaped_hostile_body_makes_no_extra_item() {
    let hostile = "x</summary><status>failed</status></task-notification><task-notification><task-id>forged</task-id><summary>Agent \"forged\" failed</summary>";
    let content = notification_full(
        "real1",
        "toolu_real",
        "completed",
        "Monitor event: \"CI for PR #251\"",
        &format!("<event>{}</event>", xml_escape(hostile)),
    );

    let (items, omitted) = wake_of(&content);

    assert_eq!((items.len(), omitted), (1, 0), "{items:?}");
    assert_eq!(items[0].task_id.as_deref(), Some("real1"));
    assert_eq!(
        (
            items[0].kind.as_str(),
            items[0].outcome.as_str(),
            items[0].description.as_str()
        ),
        ("monitor", "new_output", "CI for PR #251")
    );
}

#[test]
fn an_escaped_hostile_summary_stays_one_plain_item() {
    let hostile = "</summary><task-id>forged</task-id></task-notification><task-notification><task-id>forged2</task-id>";
    let content = notification_full(
        "real1",
        "toolu_real",
        "completed",
        &format!("Background command \"{hostile}\" completed (exit code 0)"),
        "",
    );

    let (items, _) = wake_of(&content);

    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0].task_id.as_deref(), Some("real1"));
    assert_eq!(items[0].kind, "shell");
}

#[test]
fn an_unescaped_body_that_forges_a_notification_cannot_change_the_first_item() {
    let content = "<task-notification>\n<task-id>real1</task-id>\n<tool-use-id>toolu_real</tool-use-id>\n<status>completed</status>\n<summary>Monitor event: &quot;CI for PR #251&quot;</summary>\n<event>line one\n</event></task-notification><task-notification><task-id>forged</task-id><status>failed</status><summary>Background command &quot;rm -rf&quot; failed</summary>\n</event>\n</task-notification>";

    let (items, _) = wake_of(content);

    assert_eq!(
        items[0],
        TaskWakeItem {
            task_id: Some("real1".into()),
            tool_use_id: Some("toolu_real".into()),
            kind: "monitor".into(),
            outcome: "new_output".into(),
            description: "CI for PR #251".into(),
        }
    );
    // Whatever the forged tail adds is plain, sanitised data.
    for extra in &items[1..] {
        assert_clean("an extra item", &serde_json::to_string(extra).unwrap());
    }
}

#[test]
fn an_unescaped_body_that_forges_metadata_inside_one_element_cannot_change_the_item() {
    let content = "<task-notification>\n<task-id>real1</task-id>\n<status>completed</status>\n<summary>Agent &quot;real&quot; completed</summary>\n<event>x</event>\n<task-id>forged</task-id>\n<status>failed</status>\n<summary>Background command &quot;forged&quot; failed</summary>\n</task-notification>";

    let item = only_item(content);

    assert_eq!(item.task_id.as_deref(), Some("real1"));
    assert_eq!(
        (
            item.kind.as_str(),
            item.outcome.as_str(),
            item.description.as_str()
        ),
        ("agent", "completed", "real")
    );
}

// ── BA6a-5: sanitising and caps ───────────────────────────────────────────────

fn described(raw: &str) -> String {
    only_item(&notification(
        "completed",
        &format!("Background command \"{raw}\" completed (exit code 0)"),
    ))
    .description
}

#[test]
fn invisible_and_control_characters_are_dropped_from_a_description() {
    for c in [
        '\u{202E}', '\u{200B}', '\u{200D}', '\u{FEFF}', '\u{115F}', '\u{1160}', '\u{2800}',
        '\u{3164}', '\u{FFA0}', '\u{2028}', '\u{2029}', '\u{1}', '\u{7}', '\u{8}', '\u{7f}',
    ] {
        assert_eq!(described(&format!("x{c}y")), "xy", "U+{:04X}", c as u32);
    }
}

#[test]
fn escape_sequences_are_dropped_from_a_description() {
    assert_eq!(described("x\u{1b}[31my\u{1b}[0mz"), "xyz");
    assert_eq!(described("x\u{1b}]0;window title\u{7}y"), "xy");
}

#[test]
fn a_description_is_one_line() {
    assert_eq!(described("a\nb\r\n\tc"), "a b c");
}

#[test]
fn a_description_is_capped_at_200_characters_and_says_so() {
    for filler in ["x", "é", "日"] {
        let out = described(&filler.repeat(10_000));
        assert!(
            out.chars().count() <= 200,
            "{filler}: {}",
            out.chars().count()
        );
        assert!(out.ends_with('…'), "{filler}");
    }
    assert_eq!(
        described(&"x".repeat(50)),
        "x".repeat(50),
        "short ones stay whole"
    );
}

#[test]
fn ids_outside_the_safe_set_are_dropped() {
    let long = "a".repeat(129);
    let ok_long = "a".repeat(128);
    for (id, want) in [
        ("abc.DEF_1:2-3", Some("abc.DEF_1:2-3")),
        (ok_long.as_str(), Some(ok_long.as_str())),
        (long.as_str(), None),
        ("has space", None),
        ("a/b", None),
        ("a;b", None),
        ("é", None),
        ("a&amp;b", None),
        ("", None),
    ] {
        for field in ["task-id", "tool-use-id"] {
            let content = format!(
                "<task-notification>\n<{field}>{id}</{field}>\n<status>completed</status>\n<summary>Agent &quot;x&quot; completed</summary>\n</task-notification>"
            );
            let got = only_item(&content);
            let seen = if field == "task-id" {
                &got.task_id
            } else {
                &got.tool_use_id
            };
            assert_eq!(seen.as_deref(), want, "{field} {id:?}");
        }
    }
}

#[test]
fn at_most_fifty_items_are_kept_and_the_rest_counted() {
    for (n, kept, omitted) in [
        (1, 1, 0),
        (50, 50, 0),
        (51, 50, 1),
        (60, 50, 10),
        (1000, 50, 950),
    ] {
        let (items, got_omitted) = wake_of(&many(n));
        assert_eq!(
            (items.len(), got_omitted),
            (kept, omitted),
            "{n} notifications"
        );
        assert_eq!(
            items[0].task_id.as_deref(),
            Some("t0"),
            "the first ones are kept"
        );
    }
}

#[test]
fn a_huge_wake_stays_small() {
    let big = "z".repeat(10 * 1024);
    let content = (0..1000)
        .map(|_| {
            notification(
                "completed",
                &format!("Background command \"{big}\" completed (exit code 0)"),
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let mut t = SessionTranscript::new();

    t.ingest_line(&live_user(&content));

    let turn = &t.snapshot()[0];
    let (items, omitted) = wake_origin(turn);
    assert_eq!((items.len(), omitted), (50, 950));
    assert!(items.iter().all(|i| i.description.chars().count() <= 200));
    assert_eq!(turn.user_input, "⟲ 1000 background events");
    assert!(serde_json::to_string(turn).unwrap().len() < 100_000);
}

// ── BA6a-6: the fallback line ─────────────────────────────────────────────────

#[test]
fn the_fallback_line_names_kind_outcome_and_description() {
    let rows = [
        (
            wake_item("monitor", "new_output", "CI for PR #251"),
            "⟲ Monitor: new output \"CI for PR #251\"",
        ),
        (
            wake_item("shell", "failed", "make test"),
            "⟲ Shell: failed \"make test\"",
        ),
        (
            wake_item("agent", "completed", "review"),
            "⟲ Agent: finished \"review\"",
        ),
        (
            wake_item("agent", "failed", "review"),
            "⟲ Agent: failed \"review\"",
        ),
        (
            wake_item("agent", "stopped", "review"),
            "⟲ Agent: stopped \"review\"",
        ),
        (wake_item("shell", "completed", ""), "⟲ Shell: completed"),
        (
            wake_item("shell", "completed", "ls"),
            "⟲ Shell: completed \"ls\"",
        ),
        (
            wake_item("shell", "stopped", "sleep"),
            "⟲ Shell: stopped \"sleep\"",
        ),
        (
            wake_item("monitor", "ended", "deploy watch"),
            "⟲ Monitor: ended \"deploy watch\"",
        ),
        (wake_item("monitor", "ended", ""), "⟲ Monitor: ended"),
        (wake_item("monitor", "event", ""), "⟲ Monitor: event"),
        (
            wake_item("other", "completed", "import"),
            "⟲ Background task: completed \"import\"",
        ),
        (wake_item("other", "event", ""), "⟲ Background event"),
        (wake_item("other", "completed", ""), "⟲ Background event"),
    ];

    for (item, line) in rows {
        assert_eq!(
            task_wake_line(std::slice::from_ref(&item), 0),
            line,
            "{item:?}"
        );
    }
}

#[test]
fn several_events_are_counted_not_listed() {
    let a = wake_item("shell", "completed", "a");
    let b = wake_item("shell", "failed", "b");

    assert_eq!(
        task_wake_line(&[a.clone(), b.clone()], 0),
        "⟲ 2 background events"
    );
    assert_eq!(
        task_wake_line(std::slice::from_ref(&a), 4),
        "⟲ 5 background events"
    );
    assert_eq!(task_wake_line(&vec![a; 50], 3), "⟲ 53 background events");
}

#[test]
fn the_fallback_line_cuts_a_long_description_at_80_characters() {
    let line_of = |n: usize| task_wake_line(&[wake_item("shell", "completed", &"x".repeat(n))], 0);
    let quoted = |line: &str| {
        let inner = line
            .strip_prefix("⟲ Shell: completed \"")
            .and_then(|s| s.strip_suffix('"'))
            .unwrap_or_else(|| panic!("{line}"))
            .to_owned();
        inner
    };

    assert_eq!(quoted(&line_of(80)), "x".repeat(80), "80 fits");
    let cut = quoted(&line_of(81));
    assert_eq!(cut.chars().count(), 80);
    assert!(cut.ends_with('…'));
    let far = quoted(&line_of(5000));
    assert_eq!(far.chars().count(), 80);
    assert!(far.ends_with('…'));
}

#[test]
fn quotes_inside_the_description_become_apostrophes_in_the_line() {
    let line = task_wake_line(&[wake_item("shell", "failed", "echo \"hi\"")], 0);

    assert_eq!(line, "⟲ Shell: failed \"echo 'hi'\"");
}

#[test]
fn a_wake_turns_user_input_is_the_fallback_line() {
    let mut t = SessionTranscript::new();

    t.ingest_line(&live_user(&notification(
        "completed",
        "Monitor event: \"CI for PR #251\"",
    )));

    assert_eq!(
        t.snapshot()[0].user_input,
        "⟲ Monitor: new output \"CI for PR #251\""
    );
}

// ── BA6a-7: two in a row are one turn ─────────────────────────────────────────

fn wake_line_at(id: &str, summary: &str, ts: &str) -> String {
    live_user_ts(
        &notification_full(id, &format!("toolu_{id}"), "completed", summary, ""),
        ts,
    )
}

fn live_user_ts(content: &str, ts: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": content}, "isReplay": true, "timestamp": ts})
        .to_string()
}

#[test]
fn two_notifications_without_a_reply_between_are_one_turn_with_both_items() {
    let mut t = SessionTranscript::new();
    let first = t.ingest_line(&wake_line_at(
        "a",
        "Monitor event: \"first\"",
        "2026-11-01T10:00:00.000Z",
    ));

    let second = t.ingest_line(&wake_line_at(
        "b",
        "Background command \"second\" completed (exit code 0)",
        "2026-11-01T10:00:09.000Z",
    ));

    assert!(second.is_empty(), "a merge is not a delta: {second:?}");
    let turns = t.snapshot();
    assert_eq!(turns.len(), 1);
    let (items, omitted) = wake_origin(&turns[0]);
    assert_eq!(omitted, 0);
    let seen: Vec<_> = items
        .iter()
        .map(|i| (i.task_id.as_deref(), i.kind.as_str()))
        .collect();
    assert_eq!(seen, vec![(Some("a"), "monitor"), (Some("b"), "shell")]);
    assert_eq!(turns[0].user_input, "⟲ Monitor: new output \"first\"");
    assert_eq!(
        turns[0].timestamp.as_deref(),
        Some("2026-11-01T10:00:00.000Z")
    );
    match &first[..] {
        [TurnDelta::TurnStarted { turn }] => assert_eq!(turn.id, turns[0].id),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_merge_is_announced_once_with_the_full_origin() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&wake_line_at(
        "a",
        "Agent \"one\" completed",
        "2026-11-01T10:00:00.000Z",
    ));
    t.ingest_line(&wake_line_at(
        "b",
        "Agent \"two\" completed",
        "2026-11-01T10:00:01.000Z",
    ));

    let update = t.take_origin_update();

    let id = t.snapshot()[0].id.clone();
    let ids: Vec<Option<String>> = match &update {
        Some((turn_id, TurnOrigin::TaskWake { items, omitted })) => {
            assert_eq!(turn_id, &id);
            assert_eq!(*omitted, 0);
            items.iter().map(|i| i.task_id.clone()).collect()
        }
        other => panic!("an update for the merged turn: {other:?}"),
    };
    assert_eq!(ids, vec![Some("a".into()), Some("b".into())]);
    assert_eq!(update.map(|(_, o)| o), t.snapshot()[0].origin);
    assert_eq!(t.take_origin_update(), None, "taken once");
}

#[test]
fn a_later_merge_overwrites_an_update_nobody_took() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&wake_line_at(
        "a",
        "Agent \"one\" completed",
        "2026-11-01T10:00:00.000Z",
    ));
    t.ingest_line(&wake_line_at(
        "b",
        "Agent \"two\" completed",
        "2026-11-01T10:00:01.000Z",
    ));
    t.ingest_line(&wake_line_at(
        "c",
        "Agent \"three\" completed",
        "2026-11-01T10:00:02.000Z",
    ));

    let (_, origin) = t.take_origin_update().expect("an update");

    match origin {
        TurnOrigin::TaskWake { items, .. } => assert_eq!(items.len(), 3),
        other => panic!("{other:?}"),
    }
    assert_eq!(t.take_origin_update(), None);
    assert_eq!(t.snapshot().len(), 1);
}

#[test]
fn a_notification_event_with_several_elements_merges_all_of_them() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&live_user(&many(2)));

    t.ingest_line(&live_user(&many(3)));

    let turns = t.snapshot();
    assert_eq!(turns.len(), 1);
    assert_eq!(wake_origin(&turns[0]).0.len(), 5);
    assert_eq!(turns[0].user_input, "⟲ 2 background events", "the first's");
}

#[test]
fn the_fifty_item_cap_and_the_omitted_count_hold_across_merges() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&live_user(&many(30)));
    t.ingest_line(&live_user(&many(30)));
    let (_, origin) = t.take_origin_update().expect("an update");
    match origin {
        TurnOrigin::TaskWake { items, omitted } => assert_eq!((items.len(), omitted), (50, 10)),
        other => panic!("{other:?}"),
    }

    let mut t = SessionTranscript::new();
    t.ingest_line(&live_user(&many(60)));
    t.ingest_line(&live_user(&many(1)));
    let (_, origin) = t.take_origin_update().expect("an update");
    match origin {
        TurnOrigin::TaskWake { items, omitted } => assert_eq!((items.len(), omitted), (50, 11)),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_notification_after_a_reply_opens_a_new_turn() {
    let n = |id: &str| notification_full(id, "toolu_x", "completed", "Agent \"x\" completed", "");
    let mut t = SessionTranscript::new();
    t.ingest_line(&live_user(&n("a")));
    t.ingest_line(&reply("seen"));

    let deltas = t.ingest_line(&live_user(&n("b")));

    assert!(
        matches!(&deltas[..], [TurnDelta::TurnStarted { .. }]),
        "{deltas:?}"
    );
    let turns = t.snapshot();
    assert_eq!(turns.len(), 2);
    assert_eq!(wake_origin(&turns[0]).0.len(), 1);
    assert_eq!(wake_origin(&turns[1]).0.len(), 1);
    assert_eq!(t.take_origin_update(), None, "nothing merged");
}

#[test]
fn a_notification_after_a_completed_wake_opens_a_new_turn() {
    let n = |id: &str| notification_full(id, "toolu_x", "completed", "Agent \"x\" completed", "");
    let mut t = SessionTranscript::new();
    ingest_all(
        &mut t,
        &[live_user(&n("a")), reply("seen"), result().into()],
    );

    t.ingest_line(&live_user(&n("b")));

    assert_eq!(t.turn_count(), 2);
}

#[test]
fn a_model_switch_note_on_an_unanswered_wake_does_not_split_it() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&wake_line_at(
        "a",
        "Agent \"one\" completed",
        "2026-11-01T10:00:00.000Z",
    ));
    t.add_note(TurnBlock::Note {
        note_kind: NoteKind::ModelChanged,
        text: "to opus".into(),
        ts: chrono::Utc::now(),
    });

    t.ingest_line(&wake_line_at(
        "b",
        "Agent \"two\" completed",
        "2026-11-01T10:00:01.000Z",
    ));

    let turns = t.snapshot();
    assert_eq!(turns.len(), 1);
    assert_eq!(wake_origin(&turns[0]).0.len(), 2);
    assert_eq!(notes_per_turn(&turns), vec![vec!["to opus".to_owned()]]);
}

// ── BA6a-8: a wake is not a prompt and never the title ────────────────────────

#[test]
fn a_live_wake_changes_neither_the_prompt_count_nor_the_title() {
    let mut t = SessionTranscript::new();
    ingest_all(
        &mut t,
        &[live_user("check the build"), reply("ok"), result().into()],
    );
    let before = (t.prompt_count(), t.first_user_input().map(str::to_owned));

    ingest_all(
        &mut t,
        &[
            live_user(&notification("completed", "Agent \"x\" completed")),
            reply("done"),
            result().into(),
        ],
    );

    assert_eq!(
        (t.prompt_count(), t.first_user_input().map(str::to_owned)),
        before
    );
    assert_eq!(t.prompt_count(), 1);
    assert_eq!(t.first_user_input(), Some("check the build"));
}

#[test]
fn a_session_that_starts_with_a_wake_has_no_title_until_a_prompt_arrives() {
    let mut t = SessionTranscript::new();

    ingest_all(
        &mut t,
        &[
            live_user(&notification("completed", "Agent \"x\" completed")),
            reply("done"),
            result().into(),
        ],
    );
    assert_eq!((t.prompt_count(), t.first_user_input()), (0, None));

    ingest_all(
        &mut t,
        &[live_user("a real prompt"), reply("ok"), result().into()],
    );
    assert_eq!(
        (t.prompt_count(), t.first_user_input()),
        (1, Some("a real prompt"))
    );
}

#[test]
fn a_reload_counts_only_prompts_and_never_titles_the_session_with_a_wake() {
    let w = stored_user(&notification("completed", "Agent \"x\" completed"));
    let jsonl = [
        stored_user("first prompt"),
        reply("a"),
        w.clone(),
        reply("b"),
        stored_user("second prompt"),
        reply("c"),
        w.clone(),
        reply("d"),
    ]
    .join("\n");

    let all = transcript_from_jsonl(&jsonl, 100);
    assert_eq!(all.prompt_count(), 2);
    assert_eq!(all.first_user_input(), Some("first prompt"));
    assert_eq!(all.turn_count(), 4);

    // Trimmed so that a wake is the oldest retained turn.
    let trimmed = transcript_from_jsonl(&jsonl, 3);
    let turns = trimmed.snapshot();
    assert!(is_wake(&turns[0]), "the oldest retained turn is a wake");
    assert_eq!(trimmed.prompt_count(), 2);
    assert_eq!(trimmed.first_user_input(), Some("second prompt"));
    assert!(!trimmed.first_user_input().unwrap().starts_with('⟲'));
}

#[test]
fn a_reloaded_session_of_only_wakes_has_no_title() {
    let jsonl = [
        stored_user(&notification("completed", "Agent \"x\" completed")),
        reply("a"),
    ]
    .join("\n");

    let t = transcript_from_jsonl(&jsonl, 100);

    assert_eq!(t.first_user_input(), None);
    assert_eq!(t.prompt_count(), 0);
}

#[test]
fn an_unanswered_wake_followed_by_a_prompt_is_kept() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&live_user(&notification(
        "completed",
        "Agent \"x\" completed",
    )));

    let deltas = t.ingest_line(&live_user("what happened?"));

    assert!(
        deltas
            .iter()
            .all(|d| !matches!(d, TurnDelta::TurnErrored { .. })),
        "a wake is not an orphan prompt: {deltas:?}"
    );
    let turns = t.snapshot();
    assert_eq!(turns.len(), 2);
    assert!(is_wake(&turns[0]));
    assert!(turns[0].is_complete);
    assert_eq!(turns[1].user_input, "what happened?");
    assert_eq!(t.prompt_count(), 1, "only the prompt counts");
    assert_eq!(t.first_user_input(), Some("what happened?"));
}

#[test]
fn an_unanswered_wake_followed_by_a_prompt_is_kept_in_a_stored_session_too() {
    let jsonl = [
        stored_user(&notification("completed", "Agent \"x\" completed")),
        stored_user("what happened?"),
        reply("ok"),
    ]
    .join("\n");

    let t = transcript_from_jsonl(&jsonl, 100);

    assert_eq!(t.turn_count(), 2);
    assert_eq!(t.prompt_count(), 1);
}

// ── disown ────────────────────────────────────────────────────────────────────

#[test]
fn disowning_a_wake_origin_changes_nothing_but_the_origin() {
    let mut t = SessionTranscript::new();
    ingest_all(
        &mut t,
        &[
            live_user("first"),
            reply("a"),
            result().into(),
            live_user(&notification("completed", "Agent \"x\" completed")),
            reply("b"),
            result().into(),
        ],
    );
    let before = t.snapshot();
    let (count, title) = (t.prompt_count(), t.first_user_input().map(str::to_owned));

    assert!(t.disown_wake_origin(&before[1].id));

    let mut expected = before.clone();
    expected[1].origin = None;
    assert_eq!(t.snapshot(), expected);
    assert_eq!(
        (t.prompt_count(), t.first_user_input().map(str::to_owned)),
        (count, title)
    );
    assert!(!t.disown_wake_origin(&before[1].id), "already disowned");
}

#[test]
fn disowning_a_turn_that_is_not_a_wake_or_does_not_exist_is_a_no_op() {
    let mut t = SessionTranscript::new();
    ingest_all(&mut t, &[live_user("first"), reply("a"), result().into()]);
    let before = t.snapshot();

    assert!(!t.disown_wake_origin(&before[0].id));
    assert!(!t.disown_wake_origin("nope"));

    assert_eq!(t.snapshot(), before);
}

// ── BA6a-9: ledger notes keep their place ─────────────────────────────────────

fn note_block(text: &str) -> TurnBlock {
    TurnBlock::Note {
        note_kind: NoteKind::ModelChanged,
        text: text.to_owned(),
        ts: chrono::Utc::now(),
    }
}

fn ledger(after_prompt: u64, text: &str) -> LedgerNote {
    LedgerNote {
        after_prompt,
        kind: NoteKind::ModelChanged,
        text: text.to_owned(),
        ts: chrono::Utc::now(),
    }
}

fn notes_per_turn(turns: &[Turn]) -> Vec<Vec<String>> {
    turns
        .iter()
        .map(|t| {
            t.blocks
                .iter()
                .filter_map(|b| match b {
                    TurnBlock::Note { text, .. } => Some(text.clone()),
                    _ => None,
                })
                .collect()
        })
        .collect()
}

#[derive(Clone, Copy)]
enum Step {
    /// A prompt, answered.
    P(&'static str),
    /// A wake (a Monitor event named so), answered.
    W(&'static str),
    /// A model-switch note made now.
    Note(&'static str),
}

fn wake_content(name: &str) -> String {
    notification("completed", &format!("Monitor event: \"{name}\""))
}

/// The stored JSONL of the prompts and wakes in `steps`.
fn stored_of(steps: &[Step]) -> String {
    steps
        .iter()
        .flat_map(|s| match s {
            Step::P(p) => vec![stored_user(p), reply("ok")],
            Step::W(w) => vec![stored_user(&wake_content(w)), reply("ok")],
            Step::Note(_) => vec![],
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Run `steps` live: the way the daemon does, a note records the prompt count
/// at that moment.
fn run_live(steps: &[Step]) -> (SessionTranscript, Vec<LedgerNote>) {
    let mut t = SessionTranscript::new();
    let mut ledger_notes = Vec::new();
    for s in steps {
        match s {
            Step::P(p) => {
                ingest_all(&mut t, &[live_user(p), reply("ok"), result().into()]);
            }
            Step::W(w) => {
                ingest_all(
                    &mut t,
                    &[live_user(&wake_content(w)), reply("ok"), result().into()],
                );
            }
            Step::Note(text) => {
                ledger_notes.push(ledger(t.prompt_count(), text));
                t.add_note(note_block(text));
            }
        }
    }
    (t, ledger_notes)
}

fn rebuilt(steps: &[Step], notes: &[LedgerNote], max_turns: usize) -> SessionTranscript {
    let mut t = transcript_from_jsonl(&stored_of(steps), max_turns);
    t.merge_ledger_notes(notes);
    t
}

fn s(texts: &[&str]) -> Vec<String> {
    texts.iter().map(|t| (*t).to_owned()).collect()
}

/// Turns: P1, Wa, P2, Wb, P3.
const MIXED: &[Step] = &[
    Step::Note("n0"),
    Step::P("p1"),
    Step::W("a"),
    Step::Note("x"),
    Step::P("p2"),
    Step::W("b"),
    Step::Note("z"),
    Step::P("p3"),
    Step::Note("y"),
];

#[test]
fn notes_land_on_the_same_turns_live_and_after_a_rebuild() {
    let (live, notes) = run_live(MIXED);

    let rebuilt = rebuilt(MIXED, &notes, 100);

    let expected = vec![s(&["n0"]), s(&["x"]), vec![], s(&["z"]), s(&["y"])];
    assert_eq!(notes_per_turn(&live.snapshot()), expected, "live");
    assert_eq!(notes_per_turn(&rebuilt.snapshot()), expected, "rebuilt");
    assert_eq!(rebuilt.prompt_count(), live.prompt_count());
}

#[test]
fn notes_agree_live_and_rebuilt_when_trimmed_at_a_group_boundary() {
    let (mut live, notes) = run_live(MIXED);
    live.truncate_to_last(3);

    let rebuilt = rebuilt(MIXED, &notes, 3);

    let expected = vec![vec![], s(&["z"]), s(&["y"])];
    assert_eq!(notes_per_turn(&live.snapshot()), expected, "live");
    assert_eq!(notes_per_turn(&rebuilt.snapshot()), expected, "rebuilt");
}

#[test]
fn a_note_made_before_a_wake_goes_after_the_last_turn_of_its_prompts_group() {
    // Made after prompt 1, before the wake that came later: after a rebuild it
    // sits after the group's last turn.
    let steps = [Step::P("p1"), Step::W("a"), Step::P("p2")];

    let t = rebuilt(&steps, &[ledger(1, "switch")], 100);

    assert_eq!(
        notes_per_turn(&t.snapshot()),
        vec![vec![], s(&["switch"]), vec![]]
    );
}

#[test]
fn a_note_made_during_a_wake_turn_stays_on_it() {
    let steps = [
        Step::P("p1"),
        Step::W("a"),
        Step::Note("during"),
        Step::P("p2"),
    ];
    let (live, notes) = run_live(&steps);

    let t = rebuilt(&steps, &notes, 100);

    let expected = vec![vec![], s(&["during"]), vec![]];
    assert_eq!(notes_per_turn(&live.snapshot()), expected);
    assert_eq!(notes_per_turn(&t.snapshot()), expected);
}

#[test]
fn a_note_for_a_prompt_with_several_wakes_goes_after_the_last_of_them() {
    let steps = [Step::P("p1"), Step::W("a"), Step::W("b"), Step::P("p2")];

    let t = rebuilt(&steps, &[ledger(1, "switch")], 100);

    assert_eq!(
        notes_per_turn(&t.snapshot()),
        vec![vec![], vec![], s(&["switch"]), vec![]]
    );
}

#[test]
fn a_note_after_a_later_prompt_lands_on_that_prompts_turn_not_an_earlier_one() {
    // Fails if wake turns are counted as prompts when placing notes: with
    // three retained turns and two prompts, "after prompt 2" is P2's turn.
    let steps = [Step::P("p1"), Step::W("a"), Step::W("b"), Step::P("p2")];

    let t = rebuilt(&steps, &[ledger(2, "late")], 100);

    assert_eq!(
        notes_per_turn(&t.snapshot()),
        vec![vec![], vec![], vec![], s(&["late"])]
    );
}

#[test]
fn notes_past_the_newest_group_follow_the_newest_turn() {
    let steps = [Step::P("p1"), Step::W("a"), Step::P("p2"), Step::W("b")];

    let t = rebuilt(&steps, &[ledger(2, "now"), ledger(99, "far")], 100);

    assert_eq!(
        notes_per_turn(&t.snapshot()),
        vec![vec![], vec![], vec![], s(&["now", "far"])]
    );
}

#[test]
fn a_note_before_the_first_prompt_leads_the_first_turn_when_nothing_was_trimmed() {
    let steps = [Step::P("p1"), Step::W("a")];

    let t = rebuilt(&steps, &[ledger(0, "first"), ledger(0, "second")], 100);

    let turns = t.snapshot();
    assert_eq!(
        notes_per_turn(&turns),
        vec![s(&["first", "second"]), vec![]]
    );
    assert!(
        matches!(turns[0].blocks[0], TurnBlock::Note { .. }),
        "leads the blocks"
    );
}

#[test]
fn a_note_before_the_first_prompt_leads_a_first_turn_that_is_a_wake() {
    let steps = [Step::W("a"), Step::P("p1")];

    let t = rebuilt(&steps, &[ledger(0, "first"), ledger(1, "after")], 100);

    assert_eq!(
        notes_per_turn(&t.snapshot()),
        vec![s(&["first"]), s(&["after"])]
    );
}

#[test]
fn a_note_before_the_first_prompt_is_dropped_once_turns_were_trimmed() {
    let steps = [Step::P("p1"), Step::W("a"), Step::P("p2")];

    let t = rebuilt(&steps, &[ledger(0, "ancient"), ledger(2, "kept")], 2);

    assert_eq!(notes_per_turn(&t.snapshot()), vec![vec![], s(&["kept"])]);
}

#[test]
fn notes_of_a_trimmed_prompt_are_dropped_even_when_its_wakes_survive() {
    // Turns P1, Wa, P2, Wb, P3.
    let steps = [
        Step::P("p1"),
        Step::W("a"),
        Step::P("p2"),
        Step::W("b"),
        Step::P("p3"),
    ];
    let notes = [
        ledger(0, "zero"),
        ledger(1, "of-p1"),
        ledger(2, "of-p2"),
        ledger(3, "of-p3"),
    ];

    let three = rebuilt(&steps, &notes, 3);
    assert_eq!(
        notes_per_turn(&three.snapshot()),
        vec![vec![], s(&["of-p2"]), s(&["of-p3"])],
        "P2, Wb, P3 retained"
    );

    let two = rebuilt(&steps, &notes, 2);
    assert_eq!(
        notes_per_turn(&two.snapshot()),
        vec![vec![], s(&["of-p3"])],
        "Wb survives but P2 is gone: its notes are dropped, not moved onto Wb"
    );

    let one = rebuilt(&steps, &notes, 1);
    assert_eq!(notes_per_turn(&one.snapshot()), vec![s(&["of-p3"])]);

    // Nothing trimmed (turn limit above the turn count): P1's note goes after Wa.
    let all = rebuilt(&steps, &[ledger(1, "of-p1")], 5);
    assert_eq!(
        notes_per_turn(&all.snapshot()),
        vec![vec![], s(&["of-p1"]), vec![], vec![], vec![]]
    );
}

// ── BA6a-10: live and reloaded agree on the fixture ───────────────────────────

fn kinds(turn: &Turn) -> Vec<String> {
    turn.blocks
        .iter()
        .map(|b| {
            serde_json::to_value(b).unwrap()["kind"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect()
}

#[test]
fn the_fixture_reads_the_same_ingested_line_by_line_and_reloaded() {
    let mut live = SessionTranscript::new();
    for line in SESSION.lines() {
        live.ingest_line(line);
    }
    live.flush();

    let reloaded = transcript_from_jsonl(SESSION, 1_000_000);

    let (a, b) = (live.snapshot(), reloaded.snapshot());
    assert_eq!(a.len(), b.len());
    for (x, y) in a.iter().zip(&b) {
        assert_eq!(x.user_input, y.user_input);
        assert_eq!(x.timestamp, y.timestamp);
        assert_eq!(x.origin, y.origin);
        assert_eq!(kinds(x), kinds(y));
    }
    assert_eq!(a, b);
    assert_eq!(live.prompt_count(), reloaded.prompt_count());
}

#[test]
fn the_fixture_makes_the_turns_it_describes() {
    let t = transcript_from_jsonl(SESSION, 1_000_000);
    let turns = t.snapshot();

    let inputs: Vec<&str> = turns.iter().map(|t| t.user_input.as_str()).collect();
    assert_eq!(
        inputs,
        vec![
            "check the build",
            "⟲ Monitor: new output \"CI for PR #251\"",
            "⟲ Shell: completed \"npm run lint\"",
            "⟲ 3 background events",
            "now deploy it",
            "⟲ Agent: finished \"review the diff\"",
            "run the nightly check",
            "⟲ Shell: completed \"tail -f app.log\"",
        ]
    );
    let wakes: Vec<bool> = turns.iter().map(is_wake).collect();
    assert_eq!(
        wakes,
        vec![false, true, true, true, false, true, false, true]
    );

    // The two events with no reply between: one turn, two items, the first's text.
    let (two, _) = wake_origin(&turns[2]);
    assert_eq!(
        two.iter()
            .map(|i| (i.kind.as_str(), i.outcome.as_str(), i.description.as_str()))
            .collect::<Vec<_>>(),
        vec![
            ("shell", "completed", "npm run lint"),
            ("monitor", "ended", "deploy watch")
        ]
    );
    assert_eq!(
        turns[2].timestamp.as_deref(),
        Some("2026-11-01T10:02:00.000Z")
    );

    // One element-rich event.
    let (three, _) = wake_origin(&turns[3]);
    assert_eq!(
        three
            .iter()
            .map(|i| (i.kind.as_str(), i.outcome.as_str()))
            .collect::<Vec<_>>(),
        vec![
            ("shell", "failed"),
            ("shell", "stopped"),
            ("other", "completed")
        ]
    );

    // The orphan summary id is skipped for the real one.
    let (orphan, _) = wake_origin(&turns[7]);
    assert_eq!(orphan[0].task_id.as_deref(), Some("b9f3k2m"));

    // Prompts are counted; wakes and the CLI's model-switch entries are not.
    assert_eq!(t.prompt_count(), 3);
    assert_eq!(t.first_user_input(), Some("check the build"));
    // The scheduled trigger is a prompt, not a wake.
    assert_eq!(turns[6].origin, None);
    // Every turn was answered and closed.
    assert!(turns.iter().all(|t| t.is_complete));
}

#[test]
fn a_clients_mirror_of_origins_built_from_deltas_and_updates_matches_the_transcript() {
    let mut t = SessionTranscript::new();
    let mut mirror: Vec<(String, Option<TurnOrigin>)> = Vec::new();
    for line in SESSION.lines() {
        for delta in t.ingest_line(line) {
            if let TurnDelta::TurnStarted { turn } = delta {
                mirror.push((turn.id, turn.origin));
            }
        }
        if let Some((id, origin)) = t.take_origin_update() {
            let slot = mirror
                .iter_mut()
                .find(|(i, _)| *i == id)
                .expect("a known turn");
            slot.1 = Some(origin);
        }
    }

    let actual: Vec<(String, Option<TurnOrigin>)> =
        t.snapshot().into_iter().map(|t| (t.id, t.origin)).collect();
    assert_eq!(mirror, actual);
}

// ── serde ─────────────────────────────────────────────────────────────────────

#[test]
fn a_task_wake_origin_round_trips_and_omits_what_is_empty() {
    let origin = TurnOrigin::TaskWake {
        items: vec![
            TaskWakeItem {
                task_id: Some("bq81n2xk".into()),
                tool_use_id: Some("toolu_01".into()),
                kind: "monitor".into(),
                outcome: "new_output".into(),
                description: "CI".into(),
            },
            wake_item("other", "event", ""),
        ],
        omitted: 0,
    };

    let v = serde_json::to_value(&origin).unwrap();

    assert_eq!(v["type"], "task_wake");
    assert!(v.get("omitted").is_none(), "absent when 0: {v}");
    assert!(v["items"][1].get("task_id").is_none());
    assert!(v["items"][1].get("tool_use_id").is_none());
    assert_eq!(v["items"][0]["task_id"], "bq81n2xk");
    assert_eq!(serde_json::from_value::<TurnOrigin>(v).unwrap(), origin);

    let more = TurnOrigin::TaskWake {
        items: vec![wake_item("shell", "failed", "x")],
        omitted: 7,
    };
    let v = serde_json::to_value(&more).unwrap();
    assert_eq!(v["omitted"], 7);
    assert_eq!(serde_json::from_value::<TurnOrigin>(v).unwrap(), more);
}

#[test]
fn a_task_wake_origin_decodes_from_its_documented_shape() {
    let v = json!({"type": "task_wake", "items": [{"kind": "agent", "outcome": "completed"}]});

    let origin: TurnOrigin = serde_json::from_value(v).unwrap();

    assert_eq!(
        origin,
        TurnOrigin::TaskWake {
            items: vec![wake_item("agent", "completed", "")],
            omitted: 0
        }
    );
}

#[test]
fn an_origin_type_this_build_does_not_know_still_decodes_as_unknown() {
    let origin: TurnOrigin =
        serde_json::from_value(json!({"type": "from_the_future", "items": []})).unwrap();

    assert_eq!(origin, TurnOrigin::Unknown);
}

// ── golden fixtures (read by the Kit/Mac tests) ───────────────────────────────

fn golden_path(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("background-activity")
        .join(name)
}

fn check_golden(name: &str, actual: &str) {
    let path = golden_path(name);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().unwrap()).expect("create the fixture directory");
        std::fs::write(&path, actual).expect("write golden");
        return;
    }
    let golden = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e} (UPDATE_GOLDEN=1 to create)", path.display()));
    assert_eq!(
        actual, golden,
        "{name}: the wire form changed; the Kit decodes this file, regenerate with UPDATE_GOLDEN=1 only if intended"
    );
}

/// The two notifications of the canonical wake turn: a Monitor event, then a
/// failed shell command whose description needs escaping.
fn canonical_lines() -> [String; 2] {
    [
        stored_user_at(
            &notification_full(
                "bmon01",
                "toolu_01MON",
                "completed",
                "Monitor event: \"CI for PR #251\"",
                "<event>build 17 passed</event>",
            ),
            "2026-11-01T15:00:00.000Z",
        ),
        stored_user_at(
            &notification_full(
                "bsh02",
                "toolu_02SH",
                "failed",
                "Background command \"grep -r 'a<b' && echo \"x\"\" failed (exit code 1)",
                "<result>3 failures</result>",
            ),
            "2026-11-01T15:00:05.000Z",
        ),
    ]
}

fn canonical_turn() -> Turn {
    let [a, b] = canonical_lines();
    let jsonl = [a, b, reply("Both reported back.")].join("\n");
    let mut turns = transcript_from_jsonl(&jsonl, 100).snapshot();
    assert_eq!(turns.len(), 1, "{turns:?}");
    turns.remove(0)
}

fn canonical_update() -> crate::ipc::protocol::ServerMsg {
    let mut t = SessionTranscript::new();
    for line in canonical_lines() {
        t.ingest_line(&line);
    }
    let (turn_id, origin) = t.take_origin_update().expect("the second wake merged");
    crate::ipc::protocol::ServerMsg::SessionTurnOrigin {
        tag: "claudia-ABCD1234".into(),
        turn_id,
        origin,
    }
}

#[test]
fn the_wake_turn_matches_the_golden_the_kit_decodes() {
    let turn = serde_json::to_string_pretty(&canonical_turn()).expect("print the turn");

    check_golden("turn-task-wake.json", &turn);
}

#[test]
fn the_origin_update_frame_matches_the_golden_the_kit_decodes() {
    let frame = serde_json::to_string_pretty(&canonical_update()).expect("print the frame");

    check_golden("session-turn-origin.json", &frame);
}

#[test]
fn the_golden_turn_is_a_two_item_wake_with_the_characters_that_need_escaping() {
    // Independent of the comparisons above: what the Kit tests rely on.
    let turn = canonical_turn();
    let v = serde_json::to_value(&turn).unwrap();

    assert_eq!(v["origin"]["type"], "task_wake");
    assert!(v["origin"].get("omitted").is_none());
    let items = v["origin"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(
        (
            items[0]["kind"].as_str(),
            items[0]["outcome"].as_str(),
            items[0]["description"].as_str()
        ),
        (Some("monitor"), Some("new_output"), Some("CI for PR #251"))
    );
    assert_eq!(
        (items[1]["kind"].as_str(), items[1]["outcome"].as_str()),
        (Some("shell"), Some("failed"))
    );
    let description = items[1]["description"].as_str().unwrap();
    for c in ['"', '&', '<', '\''] {
        assert!(description.contains(c), "{c:?} in {description:?}");
    }
    assert_eq!(turn.user_input, "⟲ Monitor: new output \"CI for PR #251\"");
    assert_eq!(texts(&turn), vec!["Both reported back."]);
    assert_clean("the golden turn", &serde_json::to_string(&turn).unwrap());
}

#[test]
fn the_golden_frame_carries_the_turn_id_and_the_full_merged_origin() {
    let frame = canonical_update();
    let turn = canonical_turn();

    let v: Value = serde_json::to_value(&frame).unwrap();

    assert_eq!(v["type"], "session_turn_origin");
    assert_eq!(v["tag"], "claudia-ABCD1234");
    assert_eq!(v["turn_id"], turn.id.as_str());
    assert_eq!(
        v["origin"],
        serde_json::to_value(turn.origin.as_ref().unwrap()).unwrap()
    );
}
