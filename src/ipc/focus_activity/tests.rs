//! What the daemon's per-focus activity counters count, driven the way
//! `run_reader` drives them: each raw stdout line is parsed, offered to the
//! tally BEFORE the transcript takes it in, and every delta the transcript
//! makes is offered after it (with the turn's sign-in verdict at a turn end).
//!
//! Contract under test (see the module docs):
//!
//! * turn: a `result` ending a turn the reader saw start; a `result` with no
//!   live turn open, and a turn the operator interrupted, are nothing;
//! * message: one per main-thread assistant record with a non-empty text block
//!   while a turn is open; never tool-only, thinking-only, subagent, synthetic
//!   or user-role lines; partial `stream_event` lines are ignored;
//! * problem: at most one per turn, by kind, the newest as `last_problem`;
//! * a replayed transcript counts nothing; a changed session id is a new epoch.
//!
//! All text here is fake.

use super::*;
use crate::ipc::auth_failure::{classify_line, TurnAuthTracker};
use crate::ipc::stream_json::{parse_line, transcript_from_jsonl, SessionTranscript, TurnDelta};
use serde_json::{json, Value};

// ── rig ───────────────────────────────────────────────────────────────────────

/// A sentinel "line": the operator pressed Stop (`SessionManager::interrupt`).
const INTERRUPT: &str = "#interrupt-requested";

struct Rig {
    activity: Arc<FocusActivity>,
    tally: ActivityTally,
    transcript: SessionTranscript,
    auth: TurnAuthTracker,
}

impl Rig {
    fn new() -> Self {
        let activity = Arc::new(FocusActivity::new("sid-1"));
        let mut transcript = SessionTranscript::new();
        transcript.set_live(true);
        Rig {
            tally: ActivityTally::new(Arc::clone(&activity)),
            activity,
            transcript,
            auth: TurnAuthTracker::new(),
        }
    }

    /// One stdout line, exactly as `run_reader` handles it.
    fn feed(&mut self, line: &str) {
        if line == INTERRUPT {
            self.transcript.mark_interrupt_requested();
            return;
        }
        let parsed = parse_line(line);
        self.auth.feed(classify_line(line), parsed.as_ref());
        let Some(parsed) = parsed else { return };
        self.tally.on_line(line, &parsed);
        for delta in self.transcript.ingest_parsed(parsed) {
            let verdict = match &delta {
                TurnDelta::TurnStarted { .. } => {
                    self.auth.begin_turn();
                    None
                }
                TurnDelta::TurnCompleted { .. }
                | TurnDelta::TurnErrored {
                    discarded: false, ..
                } => self.auth.finish().map(|o| o.signal),
                _ => None,
            };
            self.tally.on_delta(&delta, verdict);
        }
    }

    fn feed_all(&mut self, lines: &[String]) {
        for line in lines {
            self.feed(line);
        }
    }

    fn snap(&self) -> ActivitySnapshot {
        self.activity.snapshot()
    }
}

fn run(lines: &[String]) -> ActivitySnapshot {
    let mut rig = Rig::new();
    rig.feed_all(lines);
    rig.snap()
}

type Expect = (u64, u64, u64, Option<ProblemKind>);

fn got(s: &ActivitySnapshot) -> Expect {
    (
        s.agent_turns,
        s.agent_messages,
        s.agent_problems,
        s.last_problem,
    )
}

// ── line builders ─────────────────────────────────────────────────────────────

/// The echo of a message the daemon wrote on stdin (a typed message).
fn typed(text: &str) -> String {
    json!({"type": "user", "isReplay": true, "message": {"role": "user", "content": text}})
        .to_string()
}

/// The echo of a typed message with array content.
fn typed_array(text: &str) -> String {
    json!({"type": "user", "isReplay": true,
           "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
    .to_string()
}

/// A user line the CLI wrote on its own (no `isReplay`): a wake, a notice.
fn cli_user(text: &str) -> String {
    json!({"type": "user", "message": {"role": "user", "content": text}}).to_string()
}

fn text(t: &str) -> Value {
    json!({"type": "text", "text": t})
}

fn tool_use(id: &str) -> Value {
    json!({"type": "tool_use", "id": id, "name": "Bash", "input": {"command": "ls"}})
}

fn thinking() -> Value {
    json!({"type": "thinking", "thinking": "hmm", "signature": "sig"})
}

fn assistant(blocks: Vec<Value>) -> String {
    json!({"type": "assistant",
           "message": {"role": "assistant", "model": "claude-sonnet-4-6", "content": blocks}})
    .to_string()
}

fn assistant_text(t: &str) -> String {
    assistant(vec![text(t)])
}

fn assistant_tool() -> String {
    assistant(vec![tool_use("toolu_1")])
}

fn tool_result_line() -> String {
    json!({"type": "user", "message": {"role": "user", "content": [
        {"tool_use_id": "toolu_1", "type": "tool_result", "content": "out", "is_error": false}]}})
    .to_string()
}

/// A subagent's assistant line, tagged the way the CLI tags it.
fn subagent_text(t: &str) -> String {
    json!({"type": "assistant", "parent_tool_use_id": "toolu_sub", "isSidechain": true,
           "message": {"role": "assistant", "model": "claude-haiku-4-5", "content": [text(t)]}})
    .to_string()
}

/// A sidechain line that names no parent (`isSidechain` alone).
fn sidechain_text(t: &str) -> String {
    json!({"type": "assistant", "isSidechain": true,
           "message": {"role": "assistant", "model": "claude-haiku-4-5", "content": [text(t)]}})
    .to_string()
}

/// The CLI's own placeholder line (an API error, a limit notice).
fn synthetic(error: &str, body: &str) -> String {
    json!({"type": "assistant", "error": error, "isApiErrorMessage": true,
           "message": {"role": "assistant", "model": "<synthetic>", "content": [text(body)]}})
    .to_string()
}

fn ok_result() -> String {
    json!({"type": "result", "subtype": "success", "is_error": false, "duration_ms": 1,
           "total_cost_usd": 0.0, "result": "done"})
    .to_string()
}

fn error_result(body: &str) -> String {
    json!({"type": "result", "subtype": "error_during_execution", "is_error": true,
           "duration_ms": 1, "total_cost_usd": 0.0, "result": body})
    .to_string()
}

fn partial_delta(t: &str) -> String {
    json!({"type": "stream_event",
           "event": {"type": "content_block_delta", "index": 0,
                     "delta": {"type": "text_delta", "text": t}}})
    .to_string()
}

fn fixture(name: &str) -> Vec<String> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/auth_failure");
    std::fs::read_to_string(format!("{path}/{name}.jsonl"))
        .unwrap_or_else(|e| panic!("fixture {name}: {e}"))
        .lines()
        .map(str::to_owned)
        .collect()
}

fn notice_mother() -> String {
    cli_user("<nostromo-mother-job id=\"j\" state=\"succeeded\" title=\"fake job\" />")
}

fn notice_wake() -> String {
    cli_user(
        "<task-notification>\n<task-id>t1</task-id>\n<tool-use-id>toolu_t1</tool-use-id>\n\
         <output-file>/tmp/t1.output</output-file>\n<status>completed</status>\n\
         <summary>Background command \"fake\" completed</summary>\n</task-notification>",
    )
}

fn notice_peer() -> String {
    cli_user(
        "Another Claude session sent a message:\n<cross-session-message \
         from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Fake\" from-mode=\"bypass\">\nfake body\n\
         </cross-session-message>\n\nThis came from another Claude session.",
    )
}

fn notice_terminal() -> String {
    cli_user("<nostromo-terminal-output terminal_id=\"t\" pane=\"p\">\nfake output\n</nostromo-terminal-output>")
}

// ── one case per rule ─────────────────────────────────────────────────────────

macro_rules! case {
    ($name:ident, $lines:expr, $expect:expr) => {
        #[test]
        fn $name() {
            let snapshot = run(&$lines);
            assert_eq!(
                got(&snapshot),
                $expect,
                "(turns, messages, problems, last_problem)"
            );
        }
    };
}

use ProblemKind::*;

case!(
    a_normal_text_turn_is_one_turn_and_one_message_and_no_problem,
    [typed("hi"), assistant_text("hello"), ok_result()],
    (1, 1, 0, None)
);

case!(
    a_tool_only_turn_is_a_turn_with_no_message_and_a_no_text_problem,
    [
        typed("hi"),
        assistant_tool(),
        tool_result_line(),
        ok_result()
    ],
    (1, 0, 1, Some(NoText))
);

case!(
    two_text_records_in_one_turn_are_two_messages,
    [
        typed("hi"),
        assistant_text("first"),
        assistant_tool(),
        tool_result_line(),
        assistant_text("second"),
        ok_result()
    ],
    (1, 2, 0, None)
);

case!(
    one_record_with_two_text_blocks_is_one_message,
    [
        typed("hi"),
        assistant(vec![text("a"), text("b")]),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    a_record_with_text_and_a_tool_call_is_one_message,
    [
        typed("hi"),
        assistant(vec![text("on it"), tool_use("toolu_1")]),
        tool_result_line(),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    a_thinking_only_turn_has_no_message,
    [typed("hi"), assistant(vec![thinking()]), ok_result()],
    (1, 0, 1, Some(NoText))
);

case!(
    thinking_before_text_does_not_add_a_message,
    [
        typed("hi"),
        assistant(vec![thinking(), text("answer")]),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    an_empty_text_block_is_not_a_message,
    [typed("hi"), assistant(vec![text("")]), ok_result()],
    (1, 0, 1, Some(NoText))
);

case!(
    subagent_text_is_not_a_main_thread_message,
    [
        typed("hi"),
        assistant_tool(),
        subagent_text("sub says hi"),
        sidechain_text("sidechain says hi"),
        tool_result_line(),
        ok_result()
    ],
    (1, 0, 1, Some(NoText))
);

case!(
    only_the_main_threads_text_counts_when_a_subagent_also_talks,
    [
        typed("hi"),
        assistant_tool(),
        subagent_text("sub says hi"),
        tool_result_line(),
        assistant_text("main says hi"),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    a_user_typed_message_is_not_an_agent_message,
    [typed("a long typed message"), assistant_tool(), ok_result()],
    (1, 0, 1, Some(NoText))
);

case!(
    a_user_typed_array_message_is_not_an_agent_message,
    [
        typed_array("a long typed message"),
        assistant_tool(),
        ok_result()
    ],
    (1, 0, 1, Some(NoText))
);

case!(
    a_user_turn_with_no_assistant_line_is_a_no_text_turn,
    [typed("anyone there"), ok_result()],
    (1, 0, 1, Some(NoText))
);

case!(
    assistant_text_with_no_turn_open_is_not_counted,
    [assistant_text("stray")],
    (0, 0, 0, None)
);

// ── problems ──────────────────────────────────────────────────────────────────

case!(
    a_synthetic_api_error_line_and_an_error_result_is_an_api_error_and_not_a_message,
    [
        typed("hi"),
        synthetic("unknown", "Something went wrong upstream"),
        error_result("failed"),
    ],
    (1, 0, 1, Some(ApiError))
);

case!(
    an_error_result_that_says_api_error_is_an_api_error,
    [
        typed("hi"),
        error_result("API Error: 500 fake upstream failure")
    ],
    (1, 0, 1, Some(ApiError))
);

case!(
    an_overloaded_turn_from_the_cli_is_an_api_error,
    fixture("overloaded"),
    (1, 0, 1, Some(ApiError))
);

case!(
    an_auth_failure_with_the_error_field_is_a_login_hold,
    fixture("s1_error_field"),
    (1, 0, 1, Some(LoginHold))
);

case!(
    an_auth_failure_seen_only_in_the_result_is_a_login_hold,
    fixture("s3_result_only"),
    (1, 0, 1, Some(LoginHold))
);

case!(
    an_auth_failure_seen_only_in_synthetic_text_is_a_login_hold,
    fixture("s2_synthetic_text_only"),
    (1, 0, 1, Some(LoginHold))
);

case!(
    a_login_failure_is_one_problem_even_with_a_synthetic_error_line,
    [
        typed("hi"),
        synthetic("authentication_failed", "Failed to authenticate: fake"),
        error_result("Failed to authenticate: fake"),
    ],
    (1, 0, 1, Some(LoginHold))
);

case!(
    a_rate_limit_from_the_cli_is_rate_limited,
    fixture("rate_limit"),
    (1, 0, 1, Some(RateLimited))
);

case!(
    an_error_result_that_mentions_a_usage_limit_is_rate_limited,
    [
        typed("hi"),
        error_result("Claude usage limit reached, resets later")
    ],
    (1, 0, 1, Some(RateLimited))
);

case!(
    a_synthetic_rate_limit_line_makes_the_turn_rate_limited,
    [
        typed("hi"),
        synthetic("rate_limit", "You have hit your limit"),
        error_result("failed"),
    ],
    (1, 0, 1, Some(RateLimited))
);

case!(
    any_other_error_result_is_a_turn_error,
    [typed("hi"), assistant_text("partial"), error_result("boom")],
    (1, 1, 1, Some(TurnError))
);

// A billing error is the CLI's synthetic `isApiErrorMessage` line like any other
// API error that has no kind of its own.
case!(
    a_billing_error_from_the_cli_is_an_api_error,
    fixture("billing_error"),
    (1, 0, 1, Some(ApiError))
);

case!(
    an_interrupted_turn_is_neither_a_turn_nor_a_problem,
    [
        typed("hi"),
        assistant_tool(),
        INTERRUPT.to_owned(),
        error_result("interrupted by operator")
    ],
    (0, 0, 0, None)
);

case!(
    an_interrupt_applies_to_one_turn_only,
    [
        typed("first"),
        assistant_tool(),
        INTERRUPT.to_owned(),
        error_result("interrupted by operator"),
        typed("second"),
        assistant_text("done"),
        ok_result()
    ],
    (1, 1, 0, None)
);

// ── what opens a turn ─────────────────────────────────────────────────────────

#[test]
fn injected_notices_open_turns_and_the_agents_reply_counts_as_a_message() {
    let notices = [
        ("mother job notice", notice_mother()),
        ("task wake", notice_wake()),
        ("peer message", notice_peer()),
        ("terminal follow notice", notice_terminal()),
    ];
    for (what, notice) in notices {
        let s = run(&[notice, assistant_text("noted"), ok_result()]);
        assert_eq!(got(&s), (1, 1, 0, None), "{what}");
    }
}

#[test]
fn the_text_of_an_injected_notice_is_never_a_message() {
    let notices = [
        ("mother job notice", notice_mother()),
        ("task wake", notice_wake()),
        ("peer message", notice_peer()),
        ("terminal follow notice", notice_terminal()),
    ];
    for (what, notice) in notices {
        // The agent answers with a tool call only: the turn has no message.
        let s = run(&[notice, assistant_tool(), tool_result_line(), ok_result()]);
        assert_eq!(got(&s), (1, 0, 1, Some(NoText)), "{what}");
    }
}

#[test]
fn a_daemon_written_notice_echo_is_not_a_message_either() {
    let echo = json!({"type": "user", "isReplay": true, "message": {"role": "user",
        "content": "<nostromo-mother-job id=\"j\" state=\"succeeded\" title=\"fake job\" />"}})
    .to_string();
    let s = run(&[echo, assistant_tool(), ok_result()]);
    assert_eq!(got(&s), (1, 0, 1, Some(NoText)));
}

/// Guards the rig itself: every opener used above really starts a live turn in
/// the transcript, so a tally that counts nothing cannot hide behind a rig
/// that never opened one.
#[test]
fn every_turn_opener_used_here_starts_a_turn_in_the_transcript() {
    let openers = [
        ("typed", typed("hi")),
        ("typed array", typed_array("hi")),
        ("mother notice", notice_mother()),
        ("task wake", notice_wake()),
        ("peer message", notice_peer()),
        ("terminal notice", notice_terminal()),
    ];
    for (what, line) in openers {
        let mut transcript = SessionTranscript::new();
        transcript.set_live(true);
        let started = transcript
            .ingest_line(&line)
            .iter()
            .filter(|d| matches!(d, TurnDelta::TurnStarted { .. }))
            .count();
        assert_eq!(started, 1, "{what}");
    }
}

// ── a result with no live turn ────────────────────────────────────────────────

case!(
    a_result_with_no_turn_open_counts_nothing,
    [ok_result()],
    (0, 0, 0, None)
);

case!(
    an_error_result_with_no_turn_open_counts_no_problem,
    [error_result("API Error: 500 handshake")],
    (0, 0, 0, None)
);

case!(
    a_second_result_after_a_completed_turn_counts_nothing,
    [
        typed("hi"),
        assistant_text("hello"),
        ok_result(),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    a_resume_handshake_result_before_the_first_turn_is_not_a_turn,
    [
        r#"{"type":"system","subtype":"init","session_id":"s","model":"claude-sonnet-4-6"}"#
            .to_owned(),
        ok_result(),
        typed("hi"),
        assistant_text("hello"),
        ok_result()
    ],
    (1, 1, 0, None)
);

// ── streaming ─────────────────────────────────────────────────────────────────

case!(
    partial_stream_events_are_ignored_and_the_final_record_counts_once,
    [
        typed("hi"),
        partial_delta("hel"),
        partial_delta("lo"),
        assistant_text("hello"),
        ok_result()
    ],
    (1, 1, 0, None)
);

case!(
    partial_stream_events_alone_are_not_a_message,
    [
        typed("hi"),
        partial_delta("hel"),
        partial_delta("lo"),
        ok_result()
    ],
    (1, 0, 1, Some(NoText))
);

// ── accumulation ──────────────────────────────────────────────────────────────

#[test]
fn counters_accumulate_across_turns_and_last_problem_is_the_newest() {
    let mut rig = Rig::new();
    rig.feed_all(&[typed("1"), assistant_tool(), ok_result()]);
    assert_eq!(got(&rig.snap()), (1, 0, 1, Some(NoText)));
    rig.feed_all(&[typed("2"), error_result("boom")]);
    assert_eq!(got(&rig.snap()), (2, 0, 2, Some(TurnError)));
    rig.feed_all(&[typed("3"), assistant_text("fine"), ok_result()]);
    assert_eq!(
        got(&rig.snap()),
        (3, 1, 2, Some(TurnError)),
        "a good turn adds no problem and keeps the newest kind"
    );
}

fn mixed_session() -> Vec<String> {
    let mut all = Vec::new();
    all.extend([typed("a"), assistant_text("x"), ok_result()]);
    all.extend([
        typed("b"),
        assistant_tool(),
        tool_result_line(),
        ok_result(),
    ]);
    all.extend(fixture("rate_limit"));
    all.extend([notice_wake(), assistant_text("woke"), ok_result()]);
    all.extend([
        typed("c"),
        assistant_tool(),
        INTERRUPT.to_owned(),
        error_result("stop"),
    ]);
    all.extend([ok_result()]);
    all.extend(fixture("s1_error_field"));
    all.extend([
        typed("d"),
        partial_delta("p"),
        assistant_text("y"),
        error_result("boom"),
    ]);
    all.extend([notice_peer(), subagent_text("sub"), ok_result()]);
    all
}

#[test]
fn counters_never_decrease_and_a_turn_has_at_most_one_problem() {
    let mut rig = Rig::new();
    let epoch = rig.snap().epoch;
    let mut last = rig.snap();
    for _ in 0..3 {
        for line in mixed_session() {
            rig.feed(&line);
            let now = rig.snap();
            assert_eq!(now.epoch, epoch, "the epoch is stable within a session");
            assert!(now.agent_turns >= last.agent_turns);
            assert!(now.agent_messages >= last.agent_messages);
            assert!(now.agent_problems >= last.agent_problems);
            assert!(
                now.agent_problems <= now.agent_turns,
                "stream problems are one per turn at most"
            );
            last = now;
        }
    }
    // One round: a, b, rate_limit, wake, (c interrupted: none), s1, d, peer = 7 turns.
    assert_eq!(
        (last.agent_turns, last.agent_messages, last.agent_problems),
        (21, 9, 15),
        "three rounds of: a(1 msg) b(NoText) rate_limit wake(1 msg) c(interrupted) \
         s1 d(1 msg, TurnError) peer(NoText)"
    );
}

// ── replays count nothing ─────────────────────────────────────────────────────

const SCROLLBACK: &str = include_str!("../testdata/scrollback_session.jsonl");

#[test]
fn a_fresh_tracker_starts_at_zero_with_an_epoch() {
    let s = FocusActivity::new("sid-1").snapshot();
    assert_eq!(got(&s), (0, 0, 0, None));
    assert!(!s.epoch.is_empty());
}

#[test]
fn a_transcript_rebuilt_from_stored_history_counts_nothing() {
    let activity = FocusActivity::new("sid-1");
    let replayed = transcript_from_jsonl(SCROLLBACK, 1000);
    assert!(
        !replayed.snapshot().is_empty(),
        "the fixture has turns, so this is a real replay"
    );
    let mut again = SessionTranscript::new();
    for line in SCROLLBACK.lines().filter(|l| !l.trim().is_empty()) {
        again.ingest_line(line);
    }
    assert_eq!(got(&activity.snapshot()), (0, 0, 0, None));
}

#[test]
fn a_resumed_session_counts_only_the_live_turns_after_its_replay() {
    let mut rig = Rig::new();
    rig.transcript = transcript_from_jsonl(SCROLLBACK, 1000);
    rig.transcript.set_live(true);
    assert_eq!(got(&rig.snap()), (0, 0, 0, None));
    rig.feed_all(&[typed("hi"), assistant_text("hello"), ok_result()]);
    assert_eq!(got(&rig.snap()), (1, 1, 0, None));
}

// ── epochs ────────────────────────────────────────────────────────────────────

fn bump(a: &FocusActivity) {
    a.note_turn();
    a.note_message();
    a.note_problem(Crashed);
}

#[test]
fn the_same_session_id_keeps_the_epoch_and_the_counters() {
    let book = ActivityBook::default();
    let first = book.for_session("fred", "sid-1");
    bump(&first);
    let before = first.snapshot();
    let again = book.for_session("fred", "sid-1");
    assert_eq!(again.snapshot(), before);
    assert_eq!(before.last_problem, Some(Crashed));
    assert_eq!(
        (
            before.agent_turns,
            before.agent_messages,
            before.agent_problems
        ),
        (1, 1, 1)
    );
}

#[test]
fn another_session_id_starts_a_new_epoch_at_zero() {
    let book = ActivityBook::default();
    let tracker = book.for_session("fred", "sid-1");
    bump(&tracker);
    let old = tracker.snapshot();
    let fresh = book.for_session("fred", "sid-2").snapshot();
    assert_ne!(fresh.epoch, old.epoch);
    assert_eq!(got(&fresh), (0, 0, 0, None));
    // Binding the new id again changes nothing.
    assert_eq!(book.for_session("fred", "sid-2").snapshot(), fresh);
}

#[test]
fn two_tags_have_independent_counters_and_epochs() {
    let book = ActivityBook::default();
    let a = book.for_session("a", "sid-a");
    let b = book.for_session("b", "sid-b");
    bump(&a);
    assert_eq!(got(&b.snapshot()), (0, 0, 0, None));
    assert_ne!(a.snapshot().epoch, b.snapshot().epoch);
    // Rebasing one tag leaves the other alone.
    book.for_session("a", "sid-a2");
    bump(&b);
    assert_eq!(b.snapshot().agent_turns, 1);
}

#[test]
fn a_snapshot_is_stable_between_calls_and_the_epoch_is_a_uuid() {
    let a = FocusActivity::new("sid-1");
    bump(&a);
    let one = a.snapshot();
    assert_eq!(a.snapshot(), one);
    assert!(
        uuid::Uuid::parse_str(&one.epoch).is_ok(),
        "the epoch is a random id: {}",
        one.epoch
    );
    assert_ne!(
        FocusActivity::new("sid-1").snapshot().epoch,
        one.epoch,
        "a new tracker (a daemon restart) is a new epoch"
    );
}

// ── the problem kinds ─────────────────────────────────────────────────────────

fn wire(kind: ProblemKind) -> &'static str {
    // Exhaustive on purpose: a new kind fails to compile until it is listed here.
    match kind {
        Crashed => "crashed",
        Stopped => "stopped",
        CrashLoopGuard => "crash_loop_guard",
        TurnError => "turn_error",
        ApiError => "api_error",
        RateLimited => "rate_limited",
        LoginHold => "login_hold",
        SendRefused => "send_refused",
        NoText => "no_text",
        Unknown => "unknown",
    }
}

#[test]
fn problem_kinds_list_every_produced_kind_once_and_never_unknown() {
    let mut seen = std::collections::HashSet::new();
    for kind in ProblemKind::ALL {
        assert!(seen.insert(kind), "{kind:?} is listed twice");
        assert_ne!(kind, Unknown, "Unknown is never produced");
    }
    assert_eq!(seen.len(), 9);
}

#[test]
fn problem_kinds_are_snake_case_on_the_wire_and_round_trip() {
    for kind in ProblemKind::ALL {
        let encoded = serde_json::to_string(&kind).unwrap();
        assert_eq!(encoded, format!("\"{}\"", wire(kind)));
        assert_eq!(serde_json::from_str::<ProblemKind>(&encoded).unwrap(), kind);
    }
}

#[test]
fn a_kind_a_newer_daemon_added_decodes_as_unknown() {
    let kind: ProblemKind = serde_json::from_str("\"from_the_future\"").unwrap();
    assert_eq!(kind, Unknown);
}
