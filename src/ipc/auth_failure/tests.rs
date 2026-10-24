//! Behaviour of the auth-failure matcher and the per-turn tracker.
//!
//! Table-driven over `tests/fixtures/auth_failure/*.jsonl` (one stream-json turn
//! per file, all text synthetic), plus rows for the pattern list, the 512-char
//! window and the 64 KiB prefilter.

use super::*;
use crate::ipc::stream_json::{parse_line, ParsedLine};
use serde_json::json;
use std::sync::atomic::Ordering;

const FIXTURE_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/auth_failure");

const EXPIRED: &str = "Failed to authenticate: OAuth session expired and could not be refreshed";

// ---------------------------------------------------------------- helpers

fn fixture_lines(name: &str) -> Vec<String> {
    let path = format!("{FIXTURE_DIR}/{name}.jsonl");
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {path}: {e}"))
        .lines()
        .map(str::to_string)
        .collect()
}

/// A turn replayed the way the session reader sees it: `begin_turn` at the
/// replayed user echo, `feed(classify_line, parse_line)` for every line,
/// `finish` at the result line.
struct Replay {
    per_line: Vec<Option<AuthSignal>>,
    outcome: Option<(AuthSignal, bool)>,
}

fn replay_lines(lines: &[String]) -> Replay {
    let mut tracker = TurnAuthTracker::new();
    let mut per_line = Vec::new();
    let mut outcome = None;
    for line in lines {
        let parsed = parse_line(line);
        if let Some(ParsedLine::UserPrompt { is_replay: true, .. }) = &parsed {
            tracker.begin_turn();
        }
        let signal = classify_line(line);
        per_line.push(signal);
        tracker.feed(signal, parsed.as_ref());
        if let Some(ParsedLine::Result(_)) = &parsed {
            outcome = tracker.finish().map(|o| (o.signal, o.resendable));
        }
    }
    Replay { per_line, outcome }
}

fn replay(name: &str) -> Replay {
    replay_lines(&fixture_lines(name))
}

fn result_line(is_error: bool, text: &str) -> String {
    let subtype = if is_error { "error_during_execution" } else { "success" };
    json!({"type": "result", "subtype": subtype, "is_error": is_error, "result": text}).to_string()
}

fn synthetic_line(text: &str) -> String {
    json!({"type": "assistant", "message": {"model": "<synthetic>", "role": "assistant",
           "content": [{"type": "text", "text": text}]}})
    .to_string()
}

fn model_line(text: &str) -> String {
    json!({"type": "assistant", "message": {"model": "claude-haiku-4-5", "role": "assistant",
           "content": [{"type": "text", "text": text}]}})
    .to_string()
}

/// An S1 line padded (in a harmless top-level field) to exactly `total` bytes.
fn s1_line_of_len(total: usize) -> String {
    let head = r#"{"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired"}]},"padding":""#;
    let tail = r#""}"#;
    assert!(total > head.len() + tail.len());
    let line = format!("{head}{}{tail}", "x".repeat(total - head.len() - tail.len()));
    assert_eq!(line.len(), total);
    line
}

/// How many times `classify_line` JSON-parsed a line while `f` ran. The counter
/// is process-wide and only grows, so a concurrent test can only inflate it.
fn parses_during(f: impl FnOnce()) -> usize {
    let before = JSON_PARSES.load(Ordering::SeqCst);
    f();
    JSON_PARSES.load(Ordering::SeqCst).saturating_sub(before)
}

/// Asserts `f` parses no JSON. Retried a few times so another test that happens
/// to parse a line concurrently cannot make this flaky; a real parse inside `f`
/// shows up on every attempt.
fn assert_no_json_parse(what: &str, f: impl Fn()) {
    for _ in 0..8 {
        if parses_during(&f) == 0 {
            return;
        }
    }
    panic!("{what}: classify_line JSON-parsed the line");
}

fn first_signal(per_line: &[Option<AuthSignal>]) -> Option<AuthSignal> {
    per_line.iter().flatten().next().copied()
}

// ------------------------------------------------------------ signal ids

#[test]
fn signal_ids_are_s1_s2_s3() {
    assert_eq!(AuthSignal::ErrorField.id(), "s1");
    assert_eq!(AuthSignal::SyntheticText.id(), "s2");
    assert_eq!(AuthSignal::ResultText.id(), "s3");
}

// ----------------------------------------------- fixtures: positive turns

/// (fixture, signal of the turn, resendable)
const POSITIVE: &[(&str, AuthSignal, bool)] = &[
    ("s1_error_field", AuthSignal::ErrorField, true),
    ("s2_synthetic_text_only", AuthSignal::SyntheticText, true),
    ("s3_result_only", AuthSignal::ResultText, true),
    ("invalid_api_key", AuthSignal::SyntheticText, true),
    ("oauth_token_expired", AuthSignal::SyntheticText, true),
    ("oauth_revoked", AuthSignal::SyntheticText, true),
    ("api_401_authentication_error", AuthSignal::SyntheticText, true),
    ("mid_turn_after_tool_call", AuthSignal::ErrorField, false),
];

#[test]
fn an_auth_failure_turn_is_detected_with_its_first_signal_and_resend_eligibility() {
    for (name, signal, resendable) in POSITIVE {
        let r = replay(name);
        assert_eq!(
            r.outcome,
            Some((*signal, *resendable)),
            "fixture {name}: per-line signals {:?}",
            r.per_line
        );
    }
}

#[test]
fn the_error_field_fixture_signals_s1_on_the_assistant_line_and_s3_on_the_result_line() {
    // S1 wins over S2 on the same line; the result line is its own S3 signal.
    let r = replay("s1_error_field");
    let signals: Vec<_> = r.per_line.iter().flatten().copied().collect();
    assert_eq!(signals, vec![AuthSignal::ErrorField, AuthSignal::ResultText]);
}

#[test]
fn the_synthetic_text_fixture_signals_s2_without_an_error_field() {
    let r = replay("s2_synthetic_text_only");
    let signals: Vec<_> = r.per_line.iter().flatten().copied().collect();
    assert_eq!(signals, vec![AuthSignal::SyntheticText, AuthSignal::ResultText]);
}

#[test]
fn a_result_line_alone_is_enough_to_detect_the_failure() {
    let r = replay("s3_result_only");
    let signals: Vec<_> = r.per_line.iter().flatten().copied().collect();
    assert_eq!(signals, vec![AuthSignal::ResultText]);
}

#[test]
fn every_positive_fixture_signals_on_some_line() {
    for (name, signal, _) in POSITIVE {
        let r = replay(name);
        assert_eq!(first_signal(&r.per_line), Some(*signal), "fixture {name}");
    }
}

// ----------------------------------------------- fixtures: negative turns

const NEGATIVE: &[&str] = &[
    "model_quotes_phrase",
    "rate_limit",
    "billing_error",
    "overloaded",
    "interrupted",
    "tool_result_mentions_login",
    "oversize_line",
];

#[test]
fn turns_that_are_not_auth_failures_signal_nothing_on_any_line() {
    for name in NEGATIVE {
        let r = replay(name);
        assert!(
            r.per_line.iter().all(Option::is_none),
            "fixture {name}: a line was classified: {:?}",
            r.per_line
        );
        assert_eq!(r.outcome, None, "fixture {name}");
    }
}

#[test]
fn the_oversize_fixture_really_has_a_line_over_64_kib() {
    let longest = fixture_lines("oversize_line").iter().map(String::len).max().unwrap();
    assert!(longest > 64 * 1024, "longest line is {longest} bytes");
}

// ------------------------------------------------------ AUTH_PATTERNS rows

/// The spec's plain phrases that the 64 KiB / needle prefilter passes on its own.
const NEEDLE_COVERED_PHRASES: &[&str] = &[
    "failed to authenticate",
    "oauth session expired",
    "oauth token has expired",
    "oauth token revoked",
    "invalid api key",
    "run /login",
    "authentication_error",
];
/// Phrases that contain none of the prefilter's five spec needles; they must still match.
const NEEDLE_FREE_PHRASES: &[&str] = &["could not be refreshed", "not logged in"];

fn all_phrases() -> impl Iterator<Item = &'static str> {
    NEEDLE_COVERED_PHRASES.iter().chain(NEEDLE_FREE_PHRASES.iter()).copied()
}

fn variants(p: &str) -> Vec<String> {
    let mut mixed = p.to_string();
    mixed.get_mut(0..1).unwrap().make_ascii_uppercase();
    vec![p.to_string(), p.to_uppercase(), mixed]
}

#[test]
fn the_pattern_list_holds_every_phrase_of_the_spec() {
    for p in all_phrases() {
        assert!(AUTH_PATTERNS.contains(&p), "AUTH_PATTERNS is missing {p:?}");
    }
}

#[test]
fn every_phrase_matches_case_insensitively_in_a_result_line() {
    for p in all_phrases() {
        for text in variants(p) {
            let line = result_line(true, &format!("Error: {text} (try again)"));
            assert_eq!(classify_line(&line), Some(AuthSignal::ResultText), "{text:?}");
        }
    }
}

#[test]
fn every_phrase_matches_case_insensitively_in_a_synthetic_assistant_line() {
    for p in all_phrases() {
        for text in variants(p) {
            let line = synthetic_line(&format!("Error: {text} (try again)"));
            assert_eq!(classify_line(&line), Some(AuthSignal::SyntheticText), "{text:?}");
        }
    }
}

#[test]
fn every_entry_of_the_pattern_list_matches_itself() {
    for p in AUTH_PATTERNS.iter().filter(|p| !p.contains("401")) {
        let line = result_line(true, &format!("x {p} x"));
        assert_eq!(classify_line(&line), Some(AuthSignal::ResultText), "pattern {p:?}");
    }
}

#[test]
fn a_401_with_unauthorized_or_authentication_matches() {
    for text in [
        "HTTP 401 Unauthorized",
        "401 unauthorized",
        "Request failed with status 401: authentication required",
        "unauthorized (401)",
        "API Error: 401 AUTHENTICATION failed upstream",
    ] {
        let line = result_line(true, text);
        assert_eq!(classify_line(&line), Some(AuthSignal::ResultText), "{text:?}");
    }
}

#[test]
fn a_401_alone_or_unauthorized_alone_does_not_match() {
    for text in [
        "Error 401",
        "wrote 401 lines",
        "unauthorized",
        "authentication required",
        "Unauthorized access attempt logged",
    ] {
        assert_eq!(classify_line(&result_line(true, text)), None, "{text:?}");
        assert_eq!(classify_line(&synthetic_line(text)), None, "{text:?}");
    }
}

#[test]
fn a_phrase_ending_exactly_at_char_512_still_matches() {
    for p in all_phrases() {
        let text = format!("{}{p}", "x".repeat(512 - p.chars().count()));
        assert_eq!(text.chars().count(), 512);
        assert_eq!(
            classify_line(&result_line(true, &text)),
            Some(AuthSignal::ResultText),
            "{p:?}"
        );
    }
}

#[test]
fn a_phrase_starting_after_char_512_does_not_match() {
    for p in all_phrases() {
        let text = format!("{}{p}", "x".repeat(513));
        assert_eq!(classify_line(&result_line(true, &text)), None, "{p:?}");
        assert_eq!(classify_line(&synthetic_line(&text)), None, "{p:?}");
    }
}

#[test]
fn the_window_counts_characters_not_bytes() {
    // 300 two-byte characters put the phrase past byte 512 but well inside char 512.
    let text = format!("{}failed to authenticate", "é".repeat(300));
    assert!(text.len() > 512);
    assert_eq!(
        classify_line(&result_line(true, &text)),
        Some(AuthSignal::ResultText)
    );
}

#[test]
fn the_401_combo_also_obeys_the_512_char_window() {
    let text = format!("{}401 unauthorized", "x".repeat(513));
    assert_eq!(classify_line(&result_line(true, &text)), None);
}

// ----------------------------------------------- what must not match

#[test]
fn a_real_models_text_quoting_the_phrase_is_not_an_auth_failure() {
    for p in all_phrases() {
        assert_eq!(classify_line(&model_line(&format!("The CLI said: {p}"))), None, "{p:?}");
    }
}

#[test]
fn a_matching_result_text_without_is_error_is_not_an_auth_failure() {
    assert_eq!(classify_line(&result_line(false, EXPIRED)), None);
}

#[test]
fn an_error_result_with_unrelated_text_is_not_an_auth_failure() {
    assert_eq!(classify_line(&result_line(true, "Rate limit reached")), None);
    let no_text = r#"{"type":"result","subtype":"error_during_execution","is_error":true}"#;
    assert_eq!(classify_line(no_text), None);
    let numeric = r#"{"type":"result","is_error":true,"result":401}"#;
    assert_eq!(classify_line(numeric), None);
}

#[test]
fn only_assistant_and_result_lines_can_signal() {
    let user = json!({"type": "user", "message": {"role": "user", "content": EXPIRED}}).to_string();
    let tool_result = json!({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t", "content": "please run /login", "is_error": true}]}})
    .to_string();
    let system = json!({"type": "system", "subtype": "init", "model": EXPIRED}).to_string();
    for line in [user, tool_result, system] {
        assert_eq!(classify_line(&line), None, "{line}");
    }
}

#[test]
fn non_auth_api_errors_are_not_auth_failures() {
    for (error, text) in [
        ("rate_limit", "Rate limit reached. Please try again later."),
        ("billing_error", "Credit balance is too low"),
        ("overloaded", "API Error: 529 overloaded_error"),
    ] {
        let line = json!({"type": "assistant", "error": error, "isApiErrorMessage": true,
            "message": {"model": "<synthetic>", "role": "assistant",
                        "content": [{"type": "text", "text": text}]}})
        .to_string();
        assert_eq!(classify_line(&line), None, "{error}");
    }
}

#[test]
fn the_error_field_alone_is_signal_s1_on_an_assistant_line() {
    let line = json!({"type": "assistant", "error": "authentication_failed",
        "message": {"model": "<synthetic>", "role": "assistant", "content": []}})
    .to_string();
    assert_eq!(classify_line(&line), Some(AuthSignal::ErrorField));
}

#[test]
fn the_error_field_wins_when_the_text_also_matches() {
    let line = json!({"type": "assistant", "error": "authentication_failed",
        "message": {"model": "<synthetic>", "role": "assistant",
                    "content": [{"type": "text", "text": EXPIRED}]}})
    .to_string();
    assert_eq!(classify_line(&line), Some(AuthSignal::ErrorField));
}

#[test]
fn an_error_field_with_another_value_is_not_s1() {
    for value in [json!("rate_limit"), json!(true), json!(null), json!(401)] {
        let line = json!({"type": "assistant", "error": value,
            "message": {"model": "<synthetic>", "role": "assistant",
                        "content": [{"type": "text", "text": "hello"}]}})
        .to_string();
        assert_eq!(classify_line(&line), None, "{value}");
    }
}

#[test]
fn garbage_that_mentions_the_phrases_never_panics_and_is_not_a_match() {
    for line in [
        "",
        "   ",
        "not json at all: Failed to authenticate",
        r#"{"type":"assistant","error":"authentication_failed""#, // truncated
        r#"["Failed to authenticate"]"#,
        r#""OAuth session expired""#,
        r#"{"type":"assistant"}"#,
        r#"{"type":"assistant","message":"Failed to authenticate"}"#,
    ] {
        assert_eq!(classify_line(line), None, "{line:?}");
    }
}

// ------------------------------------------------------- 64 KiB prefilter

#[test]
fn a_line_of_exactly_64_kib_can_still_match() {
    assert_eq!(
        classify_line(&s1_line_of_len(64 * 1024)),
        Some(AuthSignal::ErrorField)
    );
}

#[test]
fn a_line_longer_than_64_kib_never_matches() {
    assert_eq!(classify_line(&s1_line_of_len(64 * 1024 + 1)), None);
    assert_eq!(classify_line(&s1_line_of_len(70_000)), None);
    // Neither does a result line that is otherwise a textbook S3 match.
    let big = format!("{}{EXPIRED}", "x".repeat(70_000));
    assert_eq!(classify_line(&result_line(true, &big)), None);
}

#[test]
fn a_four_mib_line_is_rejected_without_json_parsing() {
    let huge = s1_line_of_len(4 * 1024 * 1024);
    assert_no_json_parse("4 MiB line", || assert_eq!(classify_line(&huge), None));
}

#[test]
fn a_line_just_over_64_kib_is_rejected_without_json_parsing() {
    let line = s1_line_of_len(64 * 1024 + 1);
    assert_no_json_parse("64 KiB + 1 line", || assert_eq!(classify_line(&line), None));
}

#[test]
fn a_line_with_none_of_the_needles_is_not_json_parsed() {
    let benign = json!({"type": "assistant", "message": {"model": "claude-haiku-4-5",
        "role": "assistant", "content": [{"type": "text", "text": "All done, nothing to see here."}]}})
    .to_string();
    assert_no_json_parse("benign line", || assert_eq!(classify_line(&benign), None));
    let result = result_line(false, "done");
    assert_no_json_parse("benign result", || assert_eq!(classify_line(&result), None));
}

#[test]
fn a_small_matching_line_is_json_parsed() {
    let line = s1_line_of_len(2_000);
    let parses = parses_during(|| assert_eq!(classify_line(&line), Some(AuthSignal::ErrorField)));
    assert!(parses >= 1, "a matching line must be parsed to be classified");
}

#[test]
fn the_prefilter_needles_are_ascii_case_insensitive() {
    for text in ["FAILED TO AUTHENTICATE", "oAuth Session Expired", "RUN /LOGIN", "INVALID API KEY"] {
        assert_eq!(
            classify_line(&result_line(true, text)),
            Some(AuthSignal::ResultText),
            "{text:?}"
        );
    }
}

// -------------------------------------------- patterns beyond the needles

#[test]
fn phrases_that_contain_no_prefilter_needle_still_match() {
    for p in NEEDLE_FREE_PHRASES {
        assert_eq!(
            classify_line(&result_line(true, &format!("Error: {p}"))),
            Some(AuthSignal::ResultText),
            "{p:?}"
        );
        assert_eq!(
            classify_line(&synthetic_line(&format!("Error: {p}"))),
            Some(AuthSignal::SyntheticText),
            "{p:?}"
        );
    }
}

// ------------------------------------------------------------------ tracker

fn feed_line(tracker: &mut TurnAuthTracker, line: &str) {
    tracker.feed(classify_line(line), parse_line(line).as_ref());
}

fn outcome(tracker: &mut TurnAuthTracker) -> Option<(AuthSignal, bool)> {
    tracker.finish().map(|o| (o.signal, o.resendable))
}

fn echo_line() -> String {
    json!({"type": "user", "isReplay": true, "message": {"role": "user", "content": "hello"}}).to_string()
}

#[test]
fn a_turn_with_no_signal_finishes_with_none() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &echo_line());
    feed_line(&mut t, &model_line("hi"));
    feed_line(&mut t, &result_line(false, "done"));
    assert_eq!(outcome(&mut t), None);
}

#[test]
fn a_default_tracker_behaves_like_a_new_one() {
    let mut t = TurnAuthTracker::default();
    assert_eq!(outcome(&mut t), None);
    feed_line(&mut t, &synthetic_line(EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, true)));
}

#[test]
fn finish_resets_so_the_next_turn_starts_clean() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &result_line(true, EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::ResultText, true)));
    assert_eq!(outcome(&mut t), None, "finishing twice reports the failure once");
}

#[test]
fn a_new_turn_forgets_the_previous_turns_signal() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &result_line(true, EXPIRED));
    t.begin_turn();
    feed_line(&mut t, &model_line("fine"));
    assert_eq!(outcome(&mut t), None);
}

#[test]
fn begin_turn_also_forgets_activity_that_made_the_old_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &model_line("some real output"));
    t.begin_turn();
    feed_line(&mut t, &synthetic_line(EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, true)));
}

#[test]
fn the_signal_of_a_turn_is_its_first_signalling_line() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    t.feed(Some(AuthSignal::ResultText), None);
    t.feed(Some(AuthSignal::ErrorField), None);
    assert_eq!(outcome(&mut t), Some((AuthSignal::ResultText, true)));

    t.begin_turn();
    t.feed(Some(AuthSignal::SyntheticText), None);
    t.feed(Some(AuthSignal::ResultText), None);
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, true)));
}

#[test]
fn the_failing_lines_own_text_does_not_make_the_turn_unresendable() {
    // The synthetic failure line parses into a text block; it must not count as output.
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &echo_line());
    let failing = synthetic_line(EXPIRED);
    assert!(
        matches!(parse_line(&failing), Some(ParsedLine::Blocks { ref blocks, .. }) if !blocks.is_empty()),
        "precondition: the failure line parses into blocks"
    );
    feed_line(&mut t, &failing);
    feed_line(&mut t, &result_line(true, EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, true)));
}

#[test]
fn real_assistant_output_before_the_failure_makes_the_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &echo_line());
    feed_line(&mut t, &model_line("Let me look into that."));
    feed_line(&mut t, &synthetic_line(EXPIRED));
    feed_line(&mut t, &result_line(true, EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, false)));
}

#[test]
fn real_assistant_output_after_the_failure_line_also_makes_the_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, &synthetic_line(EXPIRED));
    feed_line(&mut t, &model_line("Carrying on regardless."));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, false)));
}

#[test]
fn a_tool_call_makes_the_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    let tool_use = json!({"type": "assistant", "message": {"model": "claude-haiku-4-5", "role": "assistant",
        "content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}}]}})
    .to_string();
    feed_line(&mut t, &tool_use);
    feed_line(&mut t, &result_line(true, EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::ResultText, false)));
}

#[test]
fn a_tool_result_line_makes_the_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    let tool_result = json!({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_1", "content": "On branch main", "is_error": false}]}})
    .to_string();
    feed_line(&mut t, &tool_result);
    feed_line(&mut t, &synthetic_line(EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, false)));
}

#[test]
fn a_result_line_and_an_empty_blocks_line_do_not_make_the_turn_unresendable() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    let empty = ParsedLine::Blocks {
        blocks: vec![],
        context_tokens: Some(5),
        model: None,
        timestamp: None,
        parent_tool_use_id: None,
    };
    t.feed(None, Some(&empty));
    t.feed(None, None);
    feed_line(&mut t, &synthetic_line(EXPIRED));
    feed_line(&mut t, &result_line(true, EXPIRED));
    assert_eq!(outcome(&mut t), Some((AuthSignal::SyntheticText, true)));
}

#[test]
fn lines_that_parse_to_nothing_are_ignored_by_the_tracker() {
    let mut t = TurnAuthTracker::new();
    t.begin_turn();
    feed_line(&mut t, "not json");
    feed_line(&mut t, "");
    feed_line(&mut t, &json!({"type": "rate_limit_event"}).to_string());
    assert_eq!(outcome(&mut t), None);
}
