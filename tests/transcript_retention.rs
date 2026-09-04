//! Acceptance test: `SessionTranscript` retention is bounded at ≤ RETAINED_BYTES
//! and ≤ RETAINED_TURNS regardless of how much tool-call/tool-result volume a
//! live daemon session accumulates. This is the daemon-facing guard for the
//! unbounded-memory bug: a heavy agentic session must not let one session's
//! transcript grow without bound in a daemon that hosts every attached focus.

use nostromo::ipc::stream_json::{
    transcript_from_jsonl, SessionTranscript, RETAINED_BYTES, RETAINED_TURNS,
};

fn user_line(i: usize) -> String {
    format!(
        r#"{{"type":"user","message":{{"role":"user","content":"prompt {i}"}},"isReplay":true}}"#
    )
}

fn tool_result_line(bytes: usize) -> String {
    let content = "x".repeat(bytes);
    format!(
        r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{content}","is_error":false,"tool_use_id":"t"}}]}}}}"#
    )
}

fn result_line() -> &'static str {
    r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#
}

#[test]
fn ingest_2000_turns_with_large_tool_results_stays_bounded() {
    let mut t = SessionTranscript::new();
    for i in 0..2000 {
        t.ingest_line(&user_line(i));
        // Every 10th turn carries a much larger tool result, simulating an
        // occasional heavy tool call (e.g. a big file read) mixed into an
        // otherwise ordinary agentic session.
        let size = if i % 10 == 0 { 256 * 1024 } else { 64 * 1024 };
        t.ingest_line(&tool_result_line(size));
        t.ingest_line(result_line());
    }

    assert!(
        t.byte_len() <= RETAINED_BYTES,
        "byte_len {} must stay within RETAINED_BYTES {} after 2000 turns with large tool results",
        t.byte_len(),
        RETAINED_BYTES
    );
    assert!(
        t.turn_count() <= RETAINED_TURNS,
        "turn_count {} must stay within RETAINED_TURNS {} after 2000 turns",
        t.turn_count(),
        RETAINED_TURNS
    );
}

#[test]
fn ingest_5000_blocks_in_one_turn_stays_bounded() {
    let mut t = SessionTranscript::new();
    t.ingest_line(&user_line(0));
    // One mega-turn: 5000 separate tool-result blocks, never completed (kept
    // in-flight), each a modest 16 KiB — this is the "single giant turn"
    // shape rather than "many turns" shape of the previous test.
    for _ in 0..5000 {
        t.ingest_line(&tool_result_line(16 * 1024));
    }

    assert!(
        t.byte_len() <= RETAINED_BYTES,
        "byte_len {} must stay within RETAINED_BYTES {} even for one in-flight turn with 5000 blocks",
        t.byte_len(),
        RETAINED_BYTES
    );
    assert_eq!(
        t.turn_count(),
        1,
        "a single in-flight mega-turn must never be split or dropped as a whole turn"
    );
}

#[test]
fn bounds_hold_from_a_resumed_transcript() {
    // A tiny stored-session fixture, resumed via transcript_from_jsonl (the
    // path used when the daemon reattaches a session on restart).
    let fixture = concat!(
        r#"{"type":"user","message":{"role":"user","content":"resume prompt"},"timestamp":"2026-01-01T00:00:00.000Z"}"#,
        "\n",
        r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ack"}]}}"#,
        "\n",
    );
    let mut t = transcript_from_jsonl(fixture, RETAINED_TURNS);

    // Keep driving the SAME transcript well past both caps with more, larger
    // live turns, exactly as a resumed daemon session would.
    for i in 0..(2 * RETAINED_TURNS) {
        t.ingest_line(&user_line(i));
        t.ingest_line(&tool_result_line(64 * 1024));
        t.ingest_line(result_line());
    }

    assert!(
        t.byte_len() <= RETAINED_BYTES,
        "byte_len {} must stay within RETAINED_BYTES {} on a resumed transcript driven past both caps",
        t.byte_len(),
        RETAINED_BYTES
    );
    assert!(
        t.turn_count() <= RETAINED_TURNS,
        "turn_count {} must stay within RETAINED_TURNS {} on a resumed transcript driven past both caps",
        t.turn_count(),
        RETAINED_TURNS
    );
}
