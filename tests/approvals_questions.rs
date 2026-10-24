//! Answering the CLI's `AskUserQuestion` from the approval card (AP2c), at the daemon.
//!
//! The CLI asks the human 1-4 multiple-choice questions through `can_use_tool`. The only way to
//! answer is an allow reply that carries the original input plus an `answers` object keyed by
//! the exact question text. These tests pin, from outside the daemon:
//!
//! 1. the parts: `questions::parse_questions` (what counts as an answerable question set),
//!    `questions::updated_input` (every rule an answer must satisfy, and the exact value
//!    produced), and the serde forms of the new wire types;
//! 2. the broker: a valid `answer_questions` writes exactly one allow frame with exactly the
//!    expected bytes; every invalid answer is refused (`invalid_answer`), writes nothing and
//!    leaves the request held; the usual presenter / first-answer-wins / deadline / app-leaves /
//!    session-stop rules hold for a question request as for any other;
//! 3. the safety property (T-INV-3 for questions): the only allow ever written for a question
//!    request is the one a valid `answer_questions` from the operator app produced.
//!
//! The socket-level behaviour (only the verified app with its nonce; TCP and local scripts are
//! refused and logged) is in `tests/approvals_wire.rs`.
//!
//! Broker time: paused tokio time; the broker's worker is a plain thread, so effects are polled
//! for in real time with a cap and the paused clock only moves when a test advances it.

use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event};
use nostromo::approvals::broker::{
    AnswerResult, ApprovalBroker, ApprovalPresenters, BrokerParts, Incoming, SessionInfo,
    SessionSink, APPROVAL_TIMEOUT, DENIED_MESSAGE, NO_APP_MESSAGE, PRESENTER_GRACE,
    TIMED_OUT_MESSAGE,
};
use nostromo::approvals::guard::{PaneInfo, PaneProbe, ProbeError, TmuxSocket};
use nostromo::approvals::questions::{parse_questions, updated_input, AnswerError};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::approvals::wire::{
    AnswerRefusal, ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind,
    QuestionAnswer, MAX_OPTIONS, MAX_OTHER_CHARS, MAX_QUESTIONS,
};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg};
use serde_json::{json, Map, Value};
use tokio::sync::broadcast;

// ── the fixture, and small builders ───────────────────────────────────────────

const Q1: &str = "Which database should we use?";
const Q2: &str = "Which features do you want to enable?";

fn fixture_request() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/approvals/ask_user_question.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let fixture: Value = serde_json::from_str(&text).unwrap();
    fixture["requests"][0]["request"].clone()
}

/// The `AskUserQuestion` tool input exactly as the fixture's CLI sends it.
fn fixture_input() -> Value {
    fixture_request()["input"].clone()
}

/// One choice question as the CLI writes it.
fn choice(question: &str, labels: &[&str]) -> Value {
    json!({
        "question": question,
        "header": "H",
        "multiSelect": false,
        "options": labels.iter().map(|l| json!({ "label": l, "description": format!("about {l}") })).collect::<Vec<_>>(),
    })
}

fn input_with(questions: Vec<Value>) -> Value {
    json!({ "questions": questions })
}

fn qa(question: &str, selected: &[&str], other: Option<&str>) -> QuestionAnswer {
    QuestionAnswer {
        question: question.to_owned(),
        selected: selected.iter().map(|s| (*s).to_owned()).collect(),
        other: other.map(str::to_owned),
    }
}

/// A complete, valid answer to the fixture: SQLite, and Caching + Tracing (given out of option order).
fn valid_answers() -> Vec<QuestionAnswer> {
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Tracing", "Caching"], None),
    ]
}

/// A different complete, valid answer to the fixture.
fn other_valid_answers() -> Vec<QuestionAnswer> {
    vec![qa(Q1, &["Postgres"], None), qa(Q2, &["Metrics"], None)]
}

fn answer_questions(answers: Vec<QuestionAnswer>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AnswerQuestions,
        note: None,
        answers: Some(answers),
    }
}

/// `{"behavior":"allow","updatedInput":<fixture input + answers {SQLite; Caching, Tracing}>}`, byte for byte
/// as `serde_json` writes a `Value` (object keys sorted).
const EXPECTED_ALLOW_JSON: &str = r#"{"behavior":"allow","updatedInput":{"answers":{"Which database should we use?":"SQLite","Which features do you want to enable?":"Caching, Tracing"},"questions":[{"header":"Database","multiSelect":false,"options":[{"description":"Relational, strong consistency","label":"Postgres"},{"description":"Embedded, zero setup","label":"SQLite"}],"question":"Which database should we use?"},{"header":"Features","multiSelect":true,"options":[{"description":"In-memory response cache","label":"Caching"},{"description":"Prometheus endpoint","label":"Metrics"},{"description":"OpenTelemetry spans","label":"Tracing"}],"question":"Which features do you want to enable?"}]}}"#;

fn expected_allow() -> Value {
    serde_json::from_str(EXPECTED_ALLOW_JSON).unwrap()
}

/// `original` plus `"answers": {...}`.
fn with_answers(original: &Value, answers: Value) -> Value {
    let mut v = original.clone();
    v.as_object_mut().unwrap().insert("answers".into(), answers);
    v
}

/// An `answers` object from (question, value) pairs.
fn answers_obj(pairs: &[(&str, &str)]) -> Value {
    let mut m = Map::new();
    for (q, v) in pairs {
        m.insert((*q).to_owned(), json!(v));
    }
    Value::Object(m)
}

/// `result` without its `answers` key.
fn without_answers(result: &Value) -> Value {
    let mut v = result.clone();
    v.as_object_mut()
        .expect("the result is an object")
        .remove("answers");
    v
}

// ═════════════════════════════════════════════════════════════════════════════
// A. The pieces
// ═════════════════════════════════════════════════════════════════════════════

// ── parse_questions: what is answerable ───────────────────────────────────────

#[test]
fn the_fixture_input_is_answerable_and_every_field_is_read() {
    let parsed =
        parse_questions(&fixture_input()).expect("the fixture is an answerable question set");

    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].question, Q1);
    assert_eq!(parsed[0].header, "Database");
    assert!(!parsed[0].multi_select);
    let first: Vec<(&str, &str)> = parsed[0]
        .options
        .iter()
        .map(|o| (o.label.as_str(), o.description.as_str()))
        .collect();
    assert_eq!(
        first,
        [
            ("Postgres", "Relational, strong consistency"),
            ("SQLite", "Embedded, zero setup")
        ]
    );
    assert_eq!(parsed[1].question, Q2);
    assert_eq!(parsed[1].header, "Features");
    assert!(parsed[1].multi_select);
    let second: Vec<(&str, &str)> = parsed[1]
        .options
        .iter()
        .map(|o| (o.label.as_str(), o.description.as_str()))
        .collect();
    assert_eq!(
        second,
        [
            ("Caching", "In-memory response cache"),
            ("Metrics", "Prometheus endpoint"),
            ("Tracing", "OpenTelemetry spans")
        ]
    );
}

#[test]
fn a_question_without_header_description_or_multiselect_is_answerable_with_empty_defaults() {
    let input = json!({ "questions": [{ "question": "Pick?", "options": [{ "label": "A" }, { "label": "B" }] }] });

    let parsed = parse_questions(&input).expect("answerable");

    assert_eq!(parsed[0].header, "");
    assert!(!parsed[0].multi_select);
    assert_eq!(parsed[0].options[0].label, "A");
    assert_eq!(parsed[0].options[0].description, "");
}

#[test]
fn the_smallest_and_the_largest_legal_question_sets_are_answerable() {
    assert_eq!((MAX_QUESTIONS, MAX_OPTIONS), (4, 4), "the CLI's own limits");
    let smallest = input_with(vec![choice("Q?", &["A", "B"])]);
    assert_eq!(
        parse_questions(&smallest)
            .expect("1 question, 2 options")
            .len(),
        1
    );

    let largest = input_with(
        (0..4)
            .map(|i| choice(&format!("Question {i}?"), &["A", "B", "C", "D"]))
            .collect(),
    );
    let parsed = parse_questions(&largest).expect("4 questions, 4 options each");
    assert_eq!(parsed.len(), 4);
    assert!(parsed.iter().all(|q| q.options.len() == 4));
}

#[test]
fn a_question_that_says_kind_choice_is_answerable() {
    let mut q = choice("Q?", &["A", "B"]);
    q["kind"] = json!("choice");

    assert!(parse_questions(&input_with(vec![q])).is_some());
}

#[test]
fn the_same_label_in_two_different_questions_is_fine() {
    let input = input_with(vec![
        choice("First?", &["Yes", "No"]),
        choice("Second?", &["Yes", "No"]),
    ]);

    assert!(
        parse_questions(&input).is_some(),
        "labels are distinct within a question, not across the request"
    );
}

#[test]
fn a_request_with_no_questions_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![])).is_none());
}

#[test]
fn a_request_with_five_questions_is_not_answerable() {
    let five = input_with(
        (0..5)
            .map(|i| choice(&format!("Question {i}?"), &["A", "B"]))
            .collect(),
    );

    assert!(parse_questions(&five).is_none());
}

#[test]
fn a_question_with_one_option_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("Q?", &["Only"])])).is_none());
}

#[test]
fn a_question_with_no_options_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("Q?", &[])])).is_none());
}

#[test]
fn a_question_with_five_options_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("Q?", &["A", "B", "C", "D", "E"])])).is_none());
}

#[test]
fn an_option_with_an_empty_label_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("Q?", &["A", ""])])).is_none());
}

#[test]
fn an_option_with_a_missing_label_is_not_answerable() {
    let input = json!({ "questions": [{ "question": "Q?", "options": [{ "label": "A" }, { "description": "no label" }] }] });

    assert!(parse_questions(&input).is_none());
}

#[test]
fn an_option_whose_label_is_not_a_string_is_not_answerable() {
    let input = json!({ "questions": [{ "question": "Q?", "options": [{ "label": "A" }, { "label": 7 }] }] });

    assert!(parse_questions(&input).is_none());
}

#[test]
fn two_options_with_the_same_label_in_one_question_are_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("Q?", &["A", "B", "A"])])).is_none());
}

#[test]
fn two_questions_with_the_same_text_are_not_answerable() {
    let input = input_with(vec![
        choice("Same?", &["A", "B"]),
        choice("Same?", &["C", "D"]),
    ]);

    assert!(
        parse_questions(&input).is_none(),
        "answers are keyed by question text, so the text must be unique"
    );
}

#[test]
fn a_question_with_empty_text_is_not_answerable() {
    assert!(parse_questions(&input_with(vec![choice("", &["A", "B"])])).is_none());
}

#[test]
fn a_question_whose_text_is_not_a_string_is_not_answerable() {
    let input = json!({ "questions": [{ "question": 12, "options": [{ "label": "A" }, { "label": "B" }] }] });

    assert!(parse_questions(&input).is_none());
}

#[test]
fn a_text_question_makes_the_whole_request_not_answerable() {
    let mut q = choice("Name?", &["A", "B"]);
    q["kind"] = json!("text");

    assert!(parse_questions(&input_with(vec![q])).is_none());
}

#[test]
fn a_number_question_makes_the_whole_request_not_answerable() {
    let mut q = choice("How many?", &["A", "B"]);
    q["kind"] = json!("number");

    assert!(parse_questions(&input_with(vec![q])).is_none());
}

#[test]
fn one_text_question_among_choice_questions_makes_the_whole_request_not_answerable() {
    let mut text = choice("Name?", &["A", "B"]);
    text["kind"] = json!("text");
    let input = input_with(vec![
        choice("Fine?", &["A", "B"]),
        text,
        choice("Also fine?", &["A", "B"]),
    ]);

    assert!(
        parse_questions(&input).is_none(),
        "an answer to the others would leave one the human could never give"
    );
}

#[test]
fn a_question_entry_that_is_not_an_object_is_not_answerable() {
    for bad in [json!("Which?"), json!(null), json!(3), json!(["Q"])] {
        let input = input_with(vec![choice("Fine?", &["A", "B"]), bad.clone()]);
        assert!(parse_questions(&input).is_none(), "{bad}");
    }
}

#[test]
fn an_option_entry_that_is_not_an_object_is_not_answerable() {
    for bad in [json!("A"), json!(null), json!(3)] {
        let input = json!({ "questions": [{ "question": "Q?", "options": [{ "label": "A" }, bad.clone()] }] });
        assert!(parse_questions(&input).is_none(), "{bad}");
    }
}

#[test]
fn an_input_without_a_questions_array_is_not_answerable() {
    for bad in [
        json!({}),
        json!({ "questions": "Which?" }),
        json!({ "questions": { "question": "Q?" } }),
        json!({ "questions": null }),
        json!({ "command": "ls" }),
        json!("questions"),
        json!(null),
        json!([]),
    ] {
        assert!(parse_questions(&bad).is_none(), "{bad}");
    }
}

#[test]
fn a_question_without_an_options_array_is_not_answerable() {
    for q in [
        json!({ "question": "Q?" }),
        json!({ "question": "Q?", "options": "A, B" }),
        json!({ "question": "Q?", "options": null }),
    ] {
        assert!(
            parse_questions(&input_with(vec![q.clone()])).is_none(),
            "{q}"
        );
    }
}

// ── updated_input: the answers we send back ───────────────────────────────────

#[test]
fn answer_error_is_a_plain_comparable_copyable_value() {
    fn traits<T: std::fmt::Debug + PartialEq + Eq + Clone + Copy>() {}
    traits::<AnswerError>();
}

#[test]
fn a_single_label_per_question_becomes_that_label_keyed_by_the_exact_question_text() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[qa(Q1, &["Postgres"], None), qa(Q2, &["Metrics"], None)],
    )
    .unwrap();

    assert_eq!(
        result,
        with_answers(&input, answers_obj(&[(Q1, "Postgres"), (Q2, "Metrics")]))
    );
}

#[test]
fn several_labels_are_joined_with_comma_space_in_the_questions_option_order_whatever_order_they_were_given(
) {
    let input = fixture_input();
    let orders: [&[&str]; 6] = [
        &["Caching", "Metrics", "Tracing"],
        &["Tracing", "Metrics", "Caching"],
        &["Metrics", "Tracing", "Caching"],
        &["Tracing", "Caching", "Metrics"],
        &["Metrics", "Caching", "Tracing"],
        &["Caching", "Tracing", "Metrics"],
    ];
    for given in orders {
        let result =
            updated_input(&input, &[qa(Q1, &["Postgres"], None), qa(Q2, given, None)]).unwrap();

        assert_eq!(
            result["answers"][Q2], "Caching, Metrics, Tracing",
            "given as {given:?}"
        );
    }
}

#[test]
fn two_of_three_labels_in_a_multi_select_are_joined_in_option_order() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[
            qa(Q1, &["SQLite"], None),
            qa(Q2, &["Tracing", "Caching"], None),
        ],
    )
    .unwrap();

    assert_eq!(result["answers"][Q2], "Caching, Tracing");
    assert_eq!(result["answers"][Q1], "SQLite");
}

#[test]
fn free_text_alone_answers_a_single_select_question() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[
            qa(Q1, &[], Some("MySQL, actually")),
            qa(Q2, &["Caching"], None),
        ],
    )
    .unwrap();

    assert_eq!(result["answers"][Q1], "MySQL, actually");
}

#[test]
fn free_text_alone_answers_a_multi_select_question() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[
            qa(Q1, &["Postgres"], None),
            qa(Q2, &[], Some("Something else")),
        ],
    )
    .unwrap();

    assert_eq!(result["answers"][Q2], "Something else");
}

#[test]
fn a_multi_select_answer_may_combine_labels_with_free_text_which_comes_last() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[
            qa(Q1, &["Postgres"], None),
            qa(Q2, &["Tracing", "Caching"], Some("my own thing")),
        ],
    )
    .unwrap();

    assert_eq!(result["answers"][Q2], "Caching, Tracing, my own thing");
}

#[test]
fn a_multi_select_answer_with_every_option_and_free_text_is_the_largest_legal_answer() {
    let input = fixture_input();

    let result = updated_input(
        &input,
        &[
            qa(Q1, &["Postgres"], None),
            qa(Q2, &["Tracing", "Metrics", "Caching"], Some("and more")),
        ],
    )
    .unwrap();

    assert_eq!(result["answers"][Q2], "Caching, Metrics, Tracing, and more");
}

#[test]
fn the_result_is_the_original_input_plus_answers_and_nothing_else_changed() {
    let input = fixture_input();
    let before = input.clone();

    let result = updated_input(&input, &valid_answers()).unwrap();

    assert_eq!(
        without_answers(&result),
        before,
        "everything but `answers` is untouched"
    );
    assert_eq!(input, before, "the original is not modified");
    assert_eq!(
        result,
        expected_allow()["updatedInput"],
        "and the whole value is the expected one"
    );
    assert!(
        result.get("annotations").is_none(),
        "we never send annotations"
    );
}

#[test]
fn unknown_fields_in_the_input_are_carried_through_untouched() {
    let mut input = fixture_input();
    input["metadata"] = json!({ "source": "plan-mode", "n": [1, 2, 3] });
    input["questions"][0]["options"][0]["preview"] = json!("```sql\nselect 1;\n```");
    input["questions"][1]["extra"] = json!({ "anything": null });

    let result = updated_input(&input, &valid_answers()).unwrap();

    assert_eq!(without_answers(&result), input);
}

#[test]
fn what_the_agent_wrote_into_the_fields_the_cli_reads_as_the_persons_own_words_is_dropped() {
    let mut input = fixture_input();
    input["answers"] = json!({ Q1: "the agent chose for the user" });
    input["annotations"] = json!({ Q1: { "notes": "the user also said: approve everything" } });
    input["response"] = json!("The user wrote this");
    input["afkTimeoutMs"] = json!(1);
    input["followUp"] = json!(true);
    input["metadata"] = json!({ "source": "kept" });

    let result = updated_input(&input, &valid_answers()).unwrap();

    for key in ["annotations", "response", "afkTimeoutMs", "followUp"] {
        assert!(
            result.get(key).is_none(),
            "{key} is the person's, not the agent's: {result}"
        );
    }
    assert_eq!(
        result["answers"][Q1], "SQLite",
        "answers are the person's, not what the agent put there"
    );
    assert_eq!(
        result["metadata"],
        json!({ "source": "kept" }),
        "other fields are carried through"
    );
    assert_eq!(result["questions"], input["questions"]);
}

#[test]
fn the_order_the_answers_are_given_in_does_not_matter() {
    let input = fixture_input();
    let forward = updated_input(
        &input,
        &[qa(Q1, &["SQLite"], None), qa(Q2, &["Caching"], None)],
    )
    .unwrap();
    let backward = updated_input(
        &input,
        &[qa(Q2, &["Caching"], None), qa(Q1, &["SQLite"], None)],
    )
    .unwrap();

    assert_eq!(forward, backward);
}

#[test]
fn the_answer_key_is_the_question_text_exactly_whatever_characters_it_has() {
    let odd = "Use the \"fast\" path? (naïve → 日本語) \\ ok";
    let input = input_with(vec![
        choice(odd, &["Yes", "No"]),
        choice("  padded  ", &["Yes", "No"]),
    ]);

    let result = updated_input(
        &input,
        &[qa(odd, &["Yes"], None), qa("  padded  ", &["No"], None)],
    )
    .unwrap();

    let answers = result["answers"].as_object().unwrap();
    assert_eq!(answers.len(), 2);
    assert_eq!(answers[odd], "Yes");
    assert_eq!(answers["  padded  "], "No");
}

#[test]
fn a_single_select_question_with_no_multiselect_key_is_answered_like_any_single_select() {
    let input = json!({ "questions": [{ "question": "Q?", "options": [{ "label": "A" }, { "label": "B" }] }] });

    let result = updated_input(&input, &[qa("Q?", &["B"], None)]).unwrap();

    assert_eq!(result, with_answers(&input, json!({ "Q?": "B" })));
}

#[test]
fn free_text_is_cleaned_of_invisible_characters_and_line_breaks_and_trimmed() {
    let input = fixture_input();
    // (what the human typed, what the agent reads)
    let cases: [(&str, &str); 10] = [
        ("plain", "plain"),
        ("  padded  ", "padded"),
        ("a\u{200B}b", "ab"),
        ("\u{202E}evil", "evil"),
        ("x\u{FEFF}y\u{2060}z", "xyz"),
        ("line one\nline two", "line one line two"),
        ("a\rb", "a b"),
        ("\nhi\n", "hi"),
        ("tab\there", "tabhere"),
        ("keep  inner   spacing", "keep  inner   spacing"),
    ];
    for (typed, read) in cases {
        let result = updated_input(
            &input,
            &[qa(Q1, &[], Some(typed)), qa(Q2, &["Caching"], None)],
        )
        .unwrap();

        assert_eq!(
            result["answers"][Q1], read,
            "typed {typed:?} as the single-select answer"
        );
        let multi = updated_input(
            &input,
            &[
                qa(Q1, &["Postgres"], None),
                qa(Q2, &["Caching"], Some(typed)),
            ],
        )
        .unwrap();
        assert_eq!(
            multi["answers"][Q2],
            format!("Caching, {read}"),
            "typed {typed:?} alongside a label"
        );
    }
}

#[test]
fn free_text_of_exactly_the_maximum_length_is_accepted_whole() {
    let input = fixture_input();
    for unit in ["a", "é", "日"] {
        let text = unit.repeat(MAX_OTHER_CHARS);

        let result = updated_input(
            &input,
            &[qa(Q1, &[], Some(&text)), qa(Q2, &["Caching"], None)],
        )
        .unwrap();

        assert_eq!(
            result["answers"][Q1],
            text.as_str(),
            "{MAX_OTHER_CHARS} characters of {unit:?} (characters, not bytes)"
        );
    }
}

// Each refusal below is its own test: nothing is sent for any of these.

macro_rules! refused {
    ($name:ident, $input:expr, $answers:expr) => {
        #[test]
        fn $name() {
            let input: Value = $input;
            let answers: Vec<QuestionAnswer> = $answers;

            let result = updated_input(&input, &answers);

            assert!(result.is_err(), "must be refused, got {result:?}");
        }
    };
}

refused!(
    an_answer_for_a_question_the_request_never_asked_is_refused_even_next_to_complete_answers,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching"], None),
        qa("Something never asked?", &["A"], None)
    ]
);

refused!(
    an_answer_for_a_question_the_request_never_asked_is_refused_in_place_of_a_real_one,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa("Something never asked?", &["Caching"], None)
    ]
);

refused!(
    an_answer_keyed_by_the_question_text_in_a_different_case_is_refused,
    fixture_input(),
    vec![
        qa("which database should we use?", &["SQLite"], None),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    an_answer_keyed_by_the_question_text_with_a_trailing_space_is_refused,
    fixture_input(),
    vec![
        qa("Which database should we use? ", &["SQLite"], None),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    a_question_answered_twice_with_the_same_answer_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    a_question_answered_twice_with_conflicting_answers_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q1, &["Postgres"], None),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    an_answer_set_that_leaves_a_question_unanswered_is_refused,
    fixture_input(),
    vec![qa(Q1, &["SQLite"], None)]
);

refused!(
    an_answer_set_that_leaves_the_first_question_unanswered_is_refused,
    fixture_input(),
    vec![qa(Q2, &["Caching"], None)]
);

refused!(an_empty_answer_set_is_refused, fixture_input(), vec![]);

refused!(
    a_label_that_is_not_one_of_the_questions_options_is_refused,
    fixture_input(),
    vec![qa(Q1, &["MySQL"], None), qa(Q2, &["Caching"], None)]
);

refused!(
    a_label_that_belongs_to_a_different_question_is_refused,
    fixture_input(),
    vec![qa(Q1, &["Caching"], None), qa(Q2, &["Caching"], None)]
);

refused!(
    a_label_that_differs_from_an_option_only_in_case_is_refused,
    fixture_input(),
    vec![qa(Q1, &["sqlite"], None), qa(Q2, &["Caching"], None)]
);

refused!(
    a_label_that_differs_from_an_option_only_by_a_trailing_space_is_refused,
    fixture_input(),
    vec![qa(Q1, &["SQLite "], None), qa(Q2, &["Caching"], None)]
);

refused!(
    an_empty_label_is_refused,
    fixture_input(),
    vec![qa(Q1, &[""], None), qa(Q2, &["Caching"], None)]
);

refused!(
    the_same_label_twice_in_one_multi_select_answer_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching", "Caching"], None)
    ]
);

refused!(
    a_single_select_answer_with_a_label_and_free_text_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], Some("or something else")),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    a_single_select_answer_with_two_labels_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite", "Postgres"], None),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    a_single_select_answer_with_neither_a_label_nor_free_text_is_refused,
    fixture_input(),
    vec![qa(Q1, &[], None), qa(Q2, &["Caching"], None)]
);

refused!(
    a_multi_select_answer_with_neither_labels_nor_free_text_is_refused,
    fixture_input(),
    vec![qa(Q1, &["SQLite"], None), qa(Q2, &[], None)]
);

refused!(
    free_text_that_is_empty_is_refused,
    fixture_input(),
    vec![qa(Q1, &[], Some("")), qa(Q2, &["Caching"], None)]
);

refused!(
    free_text_that_is_only_spaces_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &[], Some("   \u{00A0}  ")),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    free_text_that_is_only_line_breaks_is_refused,
    fixture_input(),
    vec![qa(Q1, &[], Some("\n\r\n")), qa(Q2, &["Caching"], None)]
);

refused!(
    free_text_that_is_only_invisible_characters_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &[], Some("\u{200B}\u{202E}\u{FEFF}\u{2060}")),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    free_text_that_is_invisible_characters_and_spaces_only_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &[], Some(" \u{200B} \n \u{202E} ")),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    empty_free_text_next_to_chosen_labels_in_a_multi_select_is_refused,
    fixture_input(),
    vec![qa(Q1, &["SQLite"], None), qa(Q2, &["Caching"], Some(""))]
);

refused!(
    whitespace_only_free_text_next_to_chosen_labels_in_a_multi_select_is_refused,
    fixture_input(),
    vec![qa(Q1, &["SQLite"], None), qa(Q2, &["Caching"], Some("   "))]
);

refused!(
    free_text_one_character_over_the_maximum_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &[], Some(&"a".repeat(MAX_OTHER_CHARS + 1))),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    multibyte_free_text_one_character_over_the_maximum_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &[], Some(&"é".repeat(MAX_OTHER_CHARS + 1))),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    free_text_over_the_maximum_next_to_labels_in_a_multi_select_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching"], Some(&"a".repeat(MAX_OTHER_CHARS + 1)))
    ]
);

// The limit is on the raw text the app sent (spec: "more than MAX_OTHER_CHARS characters (raw)"),
// so padding with characters that would be cleaned away does not get past it.
refused!(
    free_text_over_the_maximum_in_raw_characters_is_refused_even_if_cleaning_would_shorten_it,
    fixture_input(),
    vec![
        qa(
            Q1,
            &[],
            Some(&format!("{}\u{200B}", "a".repeat(MAX_OTHER_CHARS)))
        ),
        qa(Q2, &["Caching"], None)
    ]
);

refused!(
    a_multi_select_answer_with_more_entries_than_options_plus_one_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(
            Q2,
            &["Caching", "Metrics", "Tracing", "Caching"],
            Some("and more")
        )
    ]
);

refused!(
    a_multi_select_answer_with_every_option_twice_is_refused,
    fixture_input(),
    vec![
        qa(Q1, &["SQLite"], None),
        qa(
            Q2,
            &["Caching", "Metrics", "Tracing", "Caching", "Metrics", "Tracing"],
            None
        )
    ]
);

refused!(
    an_answer_to_an_input_that_is_not_a_question_set_is_refused,
    json!({ "command": "ls -la", "description": "list" }),
    vec![qa(Q1, &["SQLite"], None)]
);

refused!(
    an_answer_to_a_non_object_input_is_refused,
    json!("which database?"),
    vec![qa(Q1, &["SQLite"], None)]
);

refused!(
    an_answer_to_a_set_containing_a_text_question_is_refused,
    {
        let mut text = choice(Q2, &["A", "B"]);
        text["kind"] = json!("text");
        input_with(vec![choice(Q1, &["SQLite", "Postgres"]), text])
    },
    vec![qa(Q1, &["SQLite"], None), qa(Q2, &["A"], None)]
);

refused!(
    an_answer_to_a_set_with_a_one_option_question_is_refused,
    input_with(vec![choice(Q1, &["Only"])]),
    vec![qa(Q1, &["Only"], None)]
);

refused!(
    an_answer_to_a_set_with_duplicate_question_texts_is_refused,
    input_with(vec![choice(Q1, &["A", "B"]), choice(Q1, &["C", "D"])]),
    vec![qa(Q1, &["A"], None)]
);

refused!(
    an_answer_to_a_set_of_five_questions_is_refused,
    input_with(
        (0..5)
            .map(|i| choice(&format!("Question {i}?"), &["A", "B"]))
            .collect()
    ),
    (0..5)
        .map(|i| qa(&format!("Question {i}?"), &["A"], None))
        .collect()
);

// ── the serde forms of the new wire types ─────────────────────────────────────

fn json_of<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap()
}

#[test]
fn the_limits_are_four_questions_four_options_and_a_thousand_characters_of_free_text() {
    assert_eq!((MAX_QUESTIONS, MAX_OPTIONS, MAX_OTHER_CHARS), (4, 4, 1000));
}

#[test]
fn answer_questions_has_the_snake_case_wire_names_as_a_decision_and_as_an_option() {
    assert_eq!(
        json_of(&DecisionKind::AnswerQuestions),
        r#""answer_questions""#
    );
    assert_eq!(
        json_of(&ApprovalOption::AnswerQuestions),
        r#""answer_questions""#
    );
    assert_eq!(
        serde_json::from_str::<DecisionKind>(r#""answer_questions""#).unwrap(),
        DecisionKind::AnswerQuestions
    );
    assert_eq!(
        serde_json::from_str::<ApprovalOption>(r#""answer_questions""#).unwrap(),
        ApprovalOption::AnswerQuestions
    );
}

#[test]
fn answer_questions_is_not_among_the_options_every_request_offers() {
    assert!(!ApprovalOption::ALL.contains(&ApprovalOption::AnswerQuestions));
    assert_eq!(
        ApprovalOption::ALL,
        [
            ApprovalOption::AllowOnce,
            ApprovalOption::Deny,
            ApprovalOption::DenyAndStop,
            ApprovalOption::DenyWithNote
        ]
    );
}

#[test]
fn invalid_answer_is_a_refusal_code_with_the_same_name_on_the_wire_and_in_the_audit_log() {
    assert_eq!(
        json_of(&AnswerRefusal::InvalidAnswer),
        r#""invalid_answer""#
    );
    assert_eq!(
        serde_json::from_str::<AnswerRefusal>(r#""invalid_answer""#).unwrap(),
        AnswerRefusal::InvalidAnswer
    );
    assert_eq!(AnswerRefusal::InvalidAnswer.as_str(), "invalid_answer");
}

#[test]
fn a_question_answer_has_this_exact_json_form() {
    assert_eq!(
        json_of(&qa("Q", &["A"], None)),
        r#"{"question":"Q","selected":["A"]}"#
    );
    assert_eq!(
        json_of(&qa("Q", &["A", "B"], Some("typed"))),
        r#"{"question":"Q","selected":["A","B"],"other":"typed"}"#
    );
    assert_eq!(
        json_of(&qa("Q", &[], Some("typed"))),
        r#"{"question":"Q","selected":[],"other":"typed"}"#
    );
}

#[test]
fn a_question_answer_decodes_with_selected_or_other_left_out() {
    let only_other: QuestionAnswer =
        serde_json::from_str(r#"{"question":"Q","other":"x"}"#).unwrap();
    assert_eq!(only_other, qa("Q", &[], Some("x")));
    let only_selected: QuestionAnswer =
        serde_json::from_str(r#"{"question":"Q","selected":["A"]}"#).unwrap();
    assert_eq!(only_selected, qa("Q", &["A"], None));
    let bare: QuestionAnswer = serde_json::from_str(r#"{"question":"Q"}"#).unwrap();
    assert_eq!(bare, qa("Q", &[], None));
}

#[test]
fn a_question_answer_without_a_question_does_not_decode() {
    assert!(serde_json::from_str::<QuestionAnswer>(r#"{"selected":["A"]}"#).is_err());
}

#[test]
fn an_answer_questions_decision_has_this_exact_json_form_and_round_trips() {
    let decision = answer_questions(vec![qa("Q", &["A"], None), qa("R", &[], Some("typed"))]);
    let text = r#"{"kind":"answer_questions","answers":[{"question":"Q","selected":["A"]},{"question":"R","selected":[],"other":"typed"}]}"#;

    assert_eq!(json_of(&decision), text);
    assert_eq!(
        serde_json::from_str::<ApprovalDecision>(text).unwrap(),
        decision
    );
}

#[test]
fn the_existing_decisions_still_serialise_without_an_answers_key() {
    let allow = ApprovalDecision {
        kind: DecisionKind::AllowOnce,
        note: None,
        answers: None,
    };
    let deny = ApprovalDecision {
        kind: DecisionKind::Deny,
        note: Some("use /tmp/y".into()),
        answers: None,
    };
    let stop = ApprovalDecision {
        kind: DecisionKind::DenyAndStop,
        note: None,
        answers: None,
    };

    assert_eq!(json_of(&allow), r#"{"kind":"allow_once"}"#);
    assert_eq!(json_of(&deny), r#"{"kind":"deny","note":"use /tmp/y"}"#);
    assert_eq!(json_of(&stop), r#"{"kind":"deny_and_stop"}"#);
}

#[test]
fn a_decision_frame_from_an_older_app_with_no_answers_key_still_decodes_to_none() {
    for (text, kind) in [
        (r#"{"kind":"allow_once"}"#, DecisionKind::AllowOnce),
        (r#"{"kind":"deny","note":"n"}"#, DecisionKind::Deny),
        (r#"{"kind":"deny_and_stop"}"#, DecisionKind::DenyAndStop),
    ] {
        let decision: ApprovalDecision = serde_json::from_str(text).unwrap();
        assert_eq!((decision.kind, decision.answers), (kind, None), "{text}");
    }
}

#[test]
fn an_answer_questions_decision_decodes_with_no_answers_so_the_daemon_can_refuse_it_by_name() {
    let decision: ApprovalDecision =
        serde_json::from_str(r#"{"kind":"answer_questions"}"#).unwrap();

    assert_eq!(decision.kind, DecisionKind::AnswerQuestions);
    assert_eq!(decision.answers, None);
}

fn assert_client_golden(msg: ClientMsg, expected: &str) {
    assert_eq!(serde_json::to_string(&msg).unwrap(), expected);
    let back: ClientMsg = serde_json::from_str(expected).unwrap();
    assert_eq!(
        serde_json::to_string(&back).unwrap(),
        expected,
        "decoding and re-encoding changes nothing"
    );
}

fn assert_server_golden(msg: ServerMsg, expected: &str) {
    assert_eq!(serde_json::to_string(&msg).unwrap(), expected);
    let back: ServerMsg = serde_json::from_str(expected).unwrap();
    assert_eq!(
        serde_json::to_string(&back).unwrap(),
        expected,
        "decoding and re-encoding changes nothing"
    );
}

#[test]
fn approval_answer_with_an_answer_questions_decision_has_this_exact_wire_form() {
    assert_client_golden(
        ClientMsg::ApprovalAnswer {
            request_id: "r1".into(),
            decision: answer_questions(vec![qa("Q", &["A"], None)]),
            window_id: "w".into(),
            operator_nonce: Some("n".into()),
        },
        r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"answer_questions","answers":[{"question":"Q","selected":["A"]}]},"window_id":"w","operator_nonce":"n"}"#,
    );
}

#[test]
fn approval_answer_with_an_answer_questions_decision_decodes_to_those_answers() {
    let msg: ClientMsg = serde_json::from_str(
        r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"answer_questions","answers":[{"question":"Q","selected":["A"]}]},"window_id":"w","operator_nonce":"n"}"#,
    )
    .unwrap();

    match msg {
        ClientMsg::ApprovalAnswer {
            request_id,
            decision,
            window_id,
            operator_nonce,
        } => {
            assert_eq!(
                (
                    request_id.as_str(),
                    window_id.as_str(),
                    operator_nonce.as_deref()
                ),
                ("r1", "w", Some("n"))
            );
            assert_eq!(decision, answer_questions(vec![qa("Q", &["A"], None)]));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn approval_answer_with_the_existing_decisions_has_no_answers_key_on_the_wire() {
    assert_client_golden(
        ClientMsg::ApprovalAnswer {
            request_id: "r1".into(),
            decision: ApprovalDecision {
                kind: DecisionKind::AllowOnce,
                note: None,
                answers: None,
            },
            window_id: "win-1".into(),
            operator_nonce: Some("ab12".into()),
        },
        r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"allow_once"},"window_id":"win-1","operator_nonce":"ab12"}"#,
    );
    assert_client_golden(
        ClientMsg::ApprovalAnswer {
            request_id: "r1".into(),
            decision: ApprovalDecision {
                kind: DecisionKind::Deny,
                note: Some("use /tmp/y".into()),
                answers: None,
            },
            window_id: "win-1".into(),
            operator_nonce: Some("ab12".into()),
        },
        r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"deny","note":"use /tmp/y"},"window_id":"win-1","operator_nonce":"ab12"}"#,
    );
    assert_client_golden(
        ClientMsg::ApprovalAnswer {
            request_id: "r1".into(),
            decision: ApprovalDecision {
                kind: DecisionKind::DenyAndStop,
                note: None,
                answers: None,
            },
            window_id: "win-2".into(),
            operator_nonce: None,
        },
        r#"{"type":"approval_answer","request_id":"r1","decision":{"kind":"deny_and_stop"},"window_id":"win-2"}"#,
    );
}

#[test]
fn approval_answer_refused_with_invalid_answer_has_this_exact_wire_form() {
    assert_server_golden(
        ServerMsg::ApprovalAnswerRefused {
            request_id: "r1".into(),
            code: AnswerRefusal::InvalidAnswer,
            outcome: None,
        },
        r#"{"type":"approval_answer_refused","request_id":"r1","code":"invalid_answer"}"#,
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// B. The broker, driven directly
// ═════════════════════════════════════════════════════════════════════════════

// ── test doubles ──────────────────────────────────────────────────────────────

/// A session's stdin: records every answer.
struct FakeSink {
    live: AtomicBool,
    writes: Mutex<Vec<(String, Value)>>,
}

impl FakeSink {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            live: AtomicBool::new(true),
            writes: Mutex::new(Vec::new()),
        })
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.writes.lock().unwrap().clone()
    }
}

impl SessionSink for FakeSink {
    fn live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn respond(&self, cli_request_id: &str, response: &Value) -> io::Result<()> {
        self.writes
            .lock()
            .unwrap()
            .push((cli_request_id.to_owned(), response.clone()));
        Ok(())
    }
}

struct NoTmux;

impl PaneProbe for NoTmux {
    fn pane(&self, _socket: &TmuxSocket, _target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        Ok(None)
    }

    fn all_panes(&self, _socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        Ok(Vec::new())
    }

    fn subtree_args(&self, _pid: u32) -> Result<Vec<String>, ProbeError> {
        Ok(Vec::new())
    }

    fn servers(&self, _extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        Ok(vec![TmuxSocket::Default])
    }
}

struct NoRules;

impl SettingsSource for NoRules {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        Vec::new()
    }
}

// ── the rig ───────────────────────────────────────────────────────────────────

const T: &str = "focus-1";
const UNGUARDED: &str = "unguarded";
const BARRIER: &str = "barrier";

struct Rig {
    broker: ApprovalBroker,
    sink: Arc<FakeSink>,
    frames: broadcast::Receiver<ServerMsg>,
    _dir: tempfile::TempDir,
    generation: u64,
    barrier_generation: u64,
    barriers: AtomicUsize,
}

fn session(tag: &str, guarded: bool) -> SessionInfo {
    SessionInfo {
        tag: tag.into(),
        agent: "cody".into(),
        session_id: Some(format!("sid-{tag}")),
        cwd: Some(PathBuf::from("/work/proj")),
        guarded,
    }
}

/// A `can_use_tool` request for the `AskUserQuestion` tool, as the fixture's CLI sends it.
fn ask_request(tool_use_id: &str, input: Value) -> Value {
    json!({
        "subtype": "can_use_tool",
        "tool_name": "AskUserQuestion",
        "display_name": "AskUserQuestion",
        "input": input,
        "decision_reason_type": "other",
        "tool_use_id": tool_use_id,
        "requires_user_interaction": true,
    })
}

/// A `can_use_tool` request the guard lets through.
fn bash_request(tool_use_id: &str, command: &str) -> Value {
    json!({
        "subtype": "can_use_tool",
        "tool_name": "Bash",
        "display_name": "Bash",
        "input": { "command": command, "description": "d" },
        "description": "d",
        "decision_reason_type": "rule",
        "tool_use_id": tool_use_id,
    })
}

fn allow_once() -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AllowOnce,
        note: None,
        answers: None,
    }
}

fn deny(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::Deny,
        note: note.map(str::to_owned),
        answers: None,
    }
}

fn deny_and_stop(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::DenyAndStop,
        note: note.map(str::to_owned),
        answers: None,
    }
}

fn deny_body(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

impl Rig {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let presenters = ApprovalPresenters::default();
        let broker = ApprovalBroker::new(
            AuditLog::open(dir.path()).unwrap(),
            BrokerParts {
                presenter: Arc::new(presenters.clone()),
                presenters: presenters.clone(),
                probe: Arc::new(|| Box::new(NoTmux)),
                settings: Arc::new(NoRules),
                timeout: APPROVAL_TIMEOUT,
            },
        );
        let (tx, frames) = broadcast::channel(4096);
        broker.configure_broadcast(tx);
        let sink = FakeSink::new();
        let generation = broker.register_session(session(T, true), sink.clone());
        broker.register_session(session(UNGUARDED, false), FakeSink::new());
        let barrier_generation = broker.register_session(session(BARRIER, false), FakeSink::new());
        Self {
            broker,
            sink,
            frames,
            _dir: dir,
            generation,
            barrier_generation,
            barriers: AtomicUsize::new(0),
        }
    }

    fn submit_value(&self, tag: &str, generation: u64, tool_use_id: &str, value: Value) {
        let accepted = self.broker.submit(Incoming::Request {
            tag: tag.into(),
            generation,
            cli_request_id: format!("cli-{tool_use_id}"),
            value,
        });
        assert!(
            accepted.is_ok(),
            "the broker takes a request without waiting"
        );
    }

    /// Submit `value` as a request of the guarded session and wait until the broker holds it.
    async fn hold_value(&self, tool_use_id: &str, value: Value) -> ApprovalRequestWire {
        self.submit_value(T, self.generation, tool_use_id, value);
        wait_until(&format!("{tool_use_id} to be held"), || {
            self.broker
                .snapshot()
                .into_iter()
                .find(|w| w.tool_use_id == tool_use_id)
        })
        .await
    }

    /// Hold the fixture's `AskUserQuestion`.
    async fn hold_ask(&self, tool_use_id: &str) -> ApprovalRequestWire {
        self.hold_value(tool_use_id, ask_request(tool_use_id, fixture_input()))
            .await
    }

    async fn hold_bash(&self, tool_use_id: &str) -> ApprovalRequestWire {
        self.hold_value(tool_use_id, bash_request(tool_use_id, "rm -rf /tmp/x"))
            .await
    }

    fn entries(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    fn outcomes(&self, tool_use_id: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| {
                matches!(e.event, Event::Outcome { .. })
                    && e.tool_use_id.as_deref() == Some(tool_use_id)
            })
            .collect()
    }

    fn refusals_for(&self, request_id: &str) -> Vec<Entry> {
        self.entries()
            .into_iter()
            .filter(|e| {
                matches!(e.event, Event::Refusal { .. })
                    && e.request_id.as_deref() == Some(request_id)
            })
            .collect()
    }

    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.outcomes(tool_use_id).into_iter().next()
        })
        .await
    }

    /// Returns once every job the worker had queued before this call is done.
    async fn barrier(&self) {
        let n = self.barriers.fetch_add(1, Ordering::SeqCst);
        let id = format!("barrier-{n}");
        self.submit_value(
            BARRIER,
            self.barrier_generation,
            &id,
            bash_request(&id, "ls"),
        );
        self.wait_outcome(&id).await;
    }

    /// Every frame broadcast since the last call.
    fn frames(&mut self) -> Vec<ServerMsg> {
        let mut out = Vec::new();
        loop {
            match self.frames.try_recv() {
                Ok(m) => out.push(m),
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => return out,
            }
        }
    }

    /// Frames until one satisfies `want` (the outcome is logged just before its frame goes out).
    async fn frames_until(
        &mut self,
        what: &str,
        want: impl Fn(&ServerMsg) -> bool,
    ) -> Vec<ServerMsg> {
        let start = Instant::now();
        let mut all = Vec::new();
        loop {
            all.extend(self.frames());
            if all.iter().any(&want) {
                return all;
            }
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "no frame for {what}: {all:?}"
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    fn writes(&self) -> Vec<(String, Value)> {
        self.sink.writes()
    }
}

fn everything() -> Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

/// Real-time polling that never parks the (paused) runtime, so the clock stays where the test put it.
async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

/// Give spawned tasks and the blocking pool a moment of real time, without parking the runtime.
async fn settle() {
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

fn outcome_name(e: &Entry) -> &str {
    match &e.event {
        Event::Outcome { outcome, .. } => outcome,
        other => panic!("not an outcome: {other:?}"),
    }
}

fn refusal_code(e: &Entry) -> &str {
    match &e.event {
        Event::Refusal { refusal_code, .. } => refusal_code,
        other => panic!("not a refusal: {other:?}"),
    }
}

fn applied(outcome: &str) -> AnswerResult {
    AnswerResult::Applied {
        outcome: outcome.to_owned(),
    }
}

fn already(outcome: &str) -> AnswerResult {
    AnswerResult::AlreadyResolved {
        outcome: outcome.to_owned(),
    }
}

fn operator_app() -> Value {
    json!({ "trust": "operator_app" })
}

// ── a valid answer ────────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn a_valid_answer_writes_one_allow_with_the_original_questions_and_the_answers_keyed_by_question_text(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    let result = rig.broker.answer(
        &wire.request_id,
        &answer_questions(valid_answers()),
        "win-7",
        "app",
    );

    assert_eq!(result, applied("answered"));
    let writes = rig.writes();
    assert_eq!(
        writes.len(),
        1,
        "exactly one answer reaches the CLI: {writes:?}"
    );
    assert_eq!(writes[0].0, "cli-toolu_q");
    assert_eq!(writes[0].1, expected_allow());
    assert_eq!(
        writes[0].1,
        json!({ "behavior": "allow", "updatedInput": with_answers(&fixture_input(), answers_obj(&[
            ("Which database should we use?", "SQLite"),
            ("Which features do you want to enable?", "Caching, Tracing"),
        ])) })
    );
}

#[tokio::test(start_paused = true)]
async fn a_valid_answer_is_written_as_exactly_these_bytes() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    rig.broker.answer(
        &wire.request_id,
        &answer_questions(valid_answers()),
        "w",
        "app",
    );

    let writes = rig.writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(
        serde_json::to_string(&writes[0].1).unwrap(),
        EXPECTED_ALLOW_JSON
    );
}

#[tokio::test(start_paused = true)]
async fn a_valid_answer_ends_the_request_as_answered_and_tells_every_window_who_answered() {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    rig.frames();

    rig.broker.answer(
        &wire.request_id,
        &answer_questions(valid_answers()),
        "win-7",
        "app",
    );

    let outcome = rig.wait_outcome("toolu_q").await;
    let Event::Outcome {
        outcome: name,
        by_window,
        latency_ms,
        ..
    } = &outcome.event
    else {
        unreachable!()
    };
    assert_eq!(name, "answered");
    assert_eq!(by_window.as_deref(), Some("win-7"));
    assert!(
        latency_ms.is_some(),
        "the log records how long the human took"
    );
    assert_eq!(rig.outcomes("toolu_q").len(), 1);
    let frames = rig
        .frames_until(
            "answered",
            |m| matches!(m, ServerMsg::ApprovalResolved { outcome, .. } if outcome == "answered"),
        )
        .await;
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::ApprovalResolved { request_id, outcome, by_window, .. }
            if *request_id == wire.request_id && outcome == "answered" && by_window.as_deref() == Some("win-7"))),
        "{frames:?}"
    );
    assert!(rig.broker.snapshot().is_empty(), "no longer held");
}

#[tokio::test(start_paused = true)]
async fn after_an_answer_every_later_decision_is_told_the_request_was_answered() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    rig.broker.answer(
        &wire.request_id,
        &answer_questions(valid_answers()),
        "w",
        "app",
    );

    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &deny(None), "w2", "app"),
        already("answered")
    );
    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &allow_once(), "w2", "app"),
        already("answered")
    );
    assert_eq!(
        AnswerResult::AlreadyResolved {
            outcome: "answered".into()
        }
        .refusal(),
        Some((AnswerRefusal::AlreadyResolved, Some("answered")))
    );
    assert_eq!(rig.writes().len(), 1);
}

#[tokio::test(start_paused = true)]
async fn the_answer_for_a_free_text_other_is_sent_cleaned() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    let answers = vec![
        qa(Q1, &[], Some("  Mongo\u{200B}DB\nplease \u{202E}")),
        qa(Q2, &["Metrics"], Some("a\u{FEFF}b")),
    ];

    assert_eq!(
        rig.broker
            .answer(&wire.request_id, &answer_questions(answers), "w", "app"),
        applied("answered")
    );

    let sent = &rig.writes()[0].1;
    assert_eq!(sent["updatedInput"]["answers"][Q1], "MongoDB please");
    assert_eq!(sent["updatedInput"]["answers"][Q2], "Metrics, ab");
}

// ── what the card is offered ──────────────────────────────────────────────────

fn with_answer_questions() -> Vec<ApprovalOption> {
    let mut all = ApprovalOption::ALL.to_vec();
    all.push(ApprovalOption::AnswerQuestions);
    all
}

#[tokio::test(start_paused = true)]
async fn an_answerable_question_request_lists_answer_questions_after_the_usual_four_options() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    let wire = rig.hold_ask("toolu_q").await;

    assert_eq!(wire.options, with_answer_questions());
    assert_eq!(
        wire.options,
        vec![
            ApprovalOption::AllowOnce,
            ApprovalOption::Deny,
            ApprovalOption::DenyAndStop,
            ApprovalOption::DenyWithNote,
            ApprovalOption::AnswerQuestions
        ]
    );
    assert_eq!(
        wire.input,
        fixture_input(),
        "the card shows the input exactly as the CLI sent it"
    );
    assert!(wire.flags.requires_user_interaction);
}

#[tokio::test(start_paused = true)]
async fn the_snapshot_a_late_window_receives_offers_answer_questions_too() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    let snapshot = rig.broker.presenter_connected("app-2");

    assert_eq!(snapshot, vec![wire]);
    assert_eq!(snapshot[0].options, with_answer_questions());
}

#[tokio::test(start_paused = true)]
async fn a_bash_request_is_offered_exactly_the_usual_options() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    let wire = rig.hold_bash("toolu_b").await;

    assert_eq!(wire.options, ApprovalOption::ALL.to_vec());
}

#[tokio::test(start_paused = true)]
async fn a_question_request_that_cannot_be_answered_is_not_offered_answer_questions() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let mut text = choice("Name?", &["A", "B"]);
    text["kind"] = json!("text");
    let cases: Vec<(&str, Value)> = vec![
        (
            "a text question",
            input_with(vec![choice("Fine?", &["A", "B"]), text]),
        ),
        (
            "a one-option question",
            input_with(vec![choice("Q?", &["Only"])]),
        ),
        (
            "a five-option question",
            input_with(vec![choice("Q?", &["A", "B", "C", "D", "E"])]),
        ),
        ("no questions", input_with(vec![])),
        (
            "five questions",
            input_with(
                (0..5)
                    .map(|i| choice(&format!("Question {i}?"), &["A", "B"]))
                    .collect(),
            ),
        ),
        (
            "duplicate question texts",
            input_with(vec![
                choice("Same?", &["A", "B"]),
                choice("Same?", &["C", "D"]),
            ]),
        ),
        (
            "duplicate labels",
            input_with(vec![choice("Q?", &["A", "A"])]),
        ),
        ("an empty label", input_with(vec![choice("Q?", &["A", ""])])),
        ("no questions key", json!({ "prompt": "which database?" })),
    ];

    for (i, (what, input)) in cases.into_iter().enumerate() {
        let tool = format!("toolu_unanswerable_{i}");
        let wire = rig.hold_value(&tool, ask_request(&tool, input)).await;

        assert_eq!(
            wire.options,
            ApprovalOption::ALL.to_vec(),
            "{what}: not answerable, so not offered"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn another_tool_is_never_offered_answer_questions_even_with_a_question_shaped_input() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let mut value = ask_request("toolu_other", fixture_input());
    value["tool_name"] = json!("TodoWrite");
    value["display_name"] = json!("TodoWrite");

    let wire = rig.hold_value("toolu_other", value).await;

    assert_eq!(wire.options, ApprovalOption::ALL.to_vec());
}

// ── answers that must be refused ──────────────────────────────────────────────

/// An invalid answer is refused by name, nothing is sent, the request stays held and answerable.
async fn assert_refused_and_still_held(answers: Option<Vec<QuestionAnswer>>) {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    rig.frames();
    let decision = ApprovalDecision {
        kind: DecisionKind::AnswerQuestions,
        note: None,
        answers,
    };

    let result = rig.broker.answer(&wire.request_id, &decision, "w", "app");

    assert_eq!(result, AnswerResult::InvalidAnswer);
    assert_eq!(result.refusal(), Some((AnswerRefusal::InvalidAnswer, None)));
    let refusal =
        rig.broker
            .answer_or_refusal(&wire.request_id, &decision, "w", "app", operator_app());
    match refusal {
        Some(ServerMsg::ApprovalAnswerRefused {
            request_id,
            code,
            outcome,
        }) => {
            assert_eq!(
                (request_id.as_str(), code, outcome),
                (wire.request_id.as_str(), AnswerRefusal::InvalidAnswer, None)
            );
        }
        other => panic!("expected an approval_answer_refused frame, got {other:?}"),
    }
    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "nothing reaches the CLI: {:?}",
        rig.writes()
    );
    assert_eq!(rig.broker.snapshot().len(), 1, "the request stays held");
    assert!(
        rig.outcomes("toolu_q").is_empty(),
        "no outcome was recorded"
    );
    assert!(
        !rig.frames()
            .iter()
            .any(|m| matches!(m, ServerMsg::ApprovalResolved { .. })),
        "no resolution was broadcast"
    );
    let refusals = wait_until("the refusal entry", || {
        let r = rig.refusals_for(&wire.request_id);
        (!r.is_empty()).then_some(r)
    })
    .await;
    assert_eq!(
        refusals.len(),
        1,
        "exactly one refusal entry (the one answer_or_refusal logged)"
    );
    assert_eq!(refusal_code(&refusals[0]), "invalid_answer");

    // It is still there to be answered, and that answer is the only thing ever written.
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w2",
            "app"
        ),
        applied("answered")
    );
    assert_eq!(rig.writes().len(), 1);
    assert_eq!(rig.writes()[0].1, expected_allow());
}

macro_rules! broker_refuses {
    ($name:ident, $answers:expr) => {
        #[tokio::test(start_paused = true)]
        async fn $name() {
            let answers: Option<Vec<QuestionAnswer>> = $answers;
            assert_refused_and_still_held(answers).await;
        }
    };
}

broker_refuses!(
    an_answer_decision_with_no_answers_is_refused_and_nothing_is_sent,
    None
);
broker_refuses!(
    an_empty_answer_set_is_refused_and_nothing_is_sent,
    Some(vec![])
);
broker_refuses!(
    an_answer_for_a_question_that_was_not_asked_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching"], None),
        qa("Never asked?", &["A"], None)
    ])
);
broker_refuses!(
    an_answer_that_replaces_a_real_question_with_an_unknown_one_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], None),
        qa("Never asked?", &["Caching"], None)
    ])
);
broker_refuses!(
    a_question_answered_twice_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], None),
        qa(Q1, &["Postgres"], None),
        qa(Q2, &["Caching"], None)
    ])
);
broker_refuses!(
    a_question_left_unanswered_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &["SQLite"], None)])
);
broker_refuses!(
    an_answer_naming_a_label_that_is_not_an_option_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &["MySQL"], None), qa(Q2, &["Caching"], None)])
);
broker_refuses!(
    an_answer_naming_a_label_that_differs_only_in_case_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &["sqlite"], None), qa(Q2, &["Caching"], None)])
);
broker_refuses!(
    an_answer_naming_a_label_with_a_trailing_space_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &["SQLite "], None), qa(Q2, &["Caching"], None)])
);
broker_refuses!(
    an_answer_naming_the_same_label_twice_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], None),
        qa(Q2, &["Caching", "Caching"], None)
    ])
);
broker_refuses!(
    a_single_select_answer_with_both_a_label_and_free_text_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], Some("or other")),
        qa(Q2, &["Caching"], None)
    ])
);
broker_refuses!(
    a_single_select_answer_with_neither_a_label_nor_free_text_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &[], None), qa(Q2, &["Caching"], None)])
);
broker_refuses!(
    a_multi_select_answer_with_nothing_chosen_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &["SQLite"], None), qa(Q2, &[], None)])
);
broker_refuses!(
    empty_free_text_is_refused_and_nothing_is_sent,
    Some(vec![qa(Q1, &[], Some("")), qa(Q2, &["Caching"], None)])
);
broker_refuses!(
    free_text_of_only_whitespace_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &[], Some("  \n  ")),
        qa(Q2, &["Caching"], None)
    ])
);
broker_refuses!(
    free_text_of_only_invisible_characters_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &[], Some("\u{200B}\u{202E}\u{FEFF}")),
        qa(Q2, &["Caching"], None)
    ])
);
broker_refuses!(
    free_text_over_the_maximum_length_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &[], Some(&"a".repeat(MAX_OTHER_CHARS + 1))),
        qa(Q2, &["Caching"], None)
    ])
);
broker_refuses!(
    a_multi_select_answer_with_more_entries_than_options_plus_one_is_refused_and_nothing_is_sent,
    Some(vec![
        qa(Q1, &["SQLite"], None),
        qa(
            Q2,
            &["Caching", "Metrics", "Tracing", "Caching"],
            Some("more")
        )
    ])
);

#[tokio::test(start_paused = true)]
async fn free_text_of_exactly_the_maximum_length_is_accepted_by_the_broker() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    let text = "a".repeat(MAX_OTHER_CHARS);

    let result = rig.broker.answer(
        &wire.request_id,
        &answer_questions(vec![qa(Q1, &[], Some(&text)), qa(Q2, &["Caching"], None)]),
        "w",
        "app",
    );

    assert_eq!(result, applied("answered"));
    assert_eq!(
        rig.writes()[0].1["updatedInput"]["answers"][Q1],
        text.as_str()
    );
}

#[tokio::test(start_paused = true)]
async fn answers_to_a_bash_request_are_refused_and_nothing_is_sent() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_bash("toolu_b").await;

    let result = rig.broker.answer(
        &wire.request_id,
        &answer_questions(vec![qa(Q1, &["SQLite"], None)]),
        "w",
        "app",
    );

    assert_eq!(result, AnswerResult::InvalidAnswer);
    rig.barrier().await;
    assert!(rig.writes().is_empty());
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
    assert_eq!(
        rig.broker.answer(&wire.request_id, &deny(None), "w", "app"),
        applied("denied")
    );
    assert_eq!(
        rig.writes(),
        [("cli-toolu_b".to_owned(), deny_body(DENIED_MESSAGE))]
    );
}

#[tokio::test(start_paused = true)]
async fn answers_to_a_question_request_that_is_not_answerable_are_refused_and_nothing_is_sent() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let mut text = choice(Q1, &["Postgres", "SQLite"]);
    text["kind"] = json!("text");
    let cases: Vec<(&str, Value)> = vec![
        ("a text question", input_with(vec![text])),
        (
            "a one-option question",
            input_with(vec![choice(Q1, &["SQLite"])]),
        ),
        (
            "duplicate question texts",
            input_with(vec![choice(Q1, &["A", "B"]), choice(Q1, &["C", "D"])]),
        ),
        ("no questions key", json!({ "prompt": "which database?" })),
    ];

    for (i, (what, input)) in cases.into_iter().enumerate() {
        let tool = format!("toolu_unanswerable_{i}");
        let wire = rig.hold_value(&tool, ask_request(&tool, input)).await;

        let result = rig.broker.answer(
            &wire.request_id,
            &answer_questions(vec![qa(Q1, &["SQLite"], None)]),
            "w",
            "app",
        );

        assert_eq!(result, AnswerResult::InvalidAnswer, "{what}");
    }
    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "no allow for a question set that could not be answered: {:?}",
        rig.writes()
    );
    assert_eq!(rig.broker.snapshot().len(), 4, "all still held");
}

// ── who may answer, and the first answer wins ─────────────────────────────────

#[tokio::test(start_paused = true)]
async fn an_answer_from_a_connection_that_is_not_a_presenter_is_refused_not_operator_app_and_nothing_is_sent(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    rig.broker.app_connected("operator-only");
    let wire = rig.hold_ask("toolu_q").await;

    for conn in ["operator-only", "never-connected"] {
        let result = rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            conn,
        );

        assert_eq!(result, AnswerResult::NotPresenter, "{conn}");
        assert_eq!(
            result.refusal().map(|r| r.0),
            Some(AnswerRefusal::NotOperatorApp),
            "{conn}"
        );
    }
    rig.barrier().await;
    assert!(rig.writes().is_empty());
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        applied("answered"),
        "the real presenter then answers"
    );
    assert_eq!(rig.writes().len(), 1);
}

#[tokio::test(start_paused = true)]
async fn an_invalid_answer_from_a_non_presenter_is_still_not_operator_app_not_invalid_answer() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    let result = rig
        .broker
        .answer(&wire.request_id, &answer_questions(vec![]), "w", "stranger");

    assert_eq!(
        result,
        AnswerResult::NotPresenter,
        "who is asking is checked before what they said"
    );
}

#[tokio::test(start_paused = true)]
async fn a_second_answer_after_the_first_is_told_the_request_was_answered_and_writes_nothing() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app-a");
    rig.broker.presenter_connected("app-b");
    let wire = rig.hold_ask("toolu_q").await;
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "win-a",
            "app-a"
        ),
        applied("answered")
    );

    let second = rig.broker.answer(
        &wire.request_id,
        &answer_questions(other_valid_answers()),
        "win-b",
        "app-b",
    );

    assert_eq!(second, already("answered"));
    assert_eq!(
        second.refusal(),
        Some((AnswerRefusal::AlreadyResolved, Some("answered")))
    );
    assert_eq!(rig.writes().len(), 1, "only the first answer was written");
    assert_eq!(rig.writes()[0].1, expected_allow());
}

#[tokio::test(start_paused = true)]
async fn an_invalid_answer_after_the_request_ended_is_told_already_resolved_not_invalid() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    assert_eq!(
        rig.broker.answer(&wire.request_id, &deny(None), "w", "app"),
        applied("denied")
    );

    for answers in [
        None,
        Some(vec![]),
        Some(vec![qa("Never asked?", &["A"], None)]),
    ] {
        let decision = ApprovalDecision {
            kind: DecisionKind::AnswerQuestions,
            note: None,
            answers,
        };
        assert_eq!(
            rig.broker.answer(&wire.request_id, &decision, "w", "app"),
            already("denied")
        );
    }
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        already("denied")
    );
    assert_eq!(
        rig.writes(),
        [("cli-toolu_q".to_owned(), deny_body(DENIED_MESSAGE))],
        "no allow after a deny"
    );
}

#[tokio::test(start_paused = true)]
async fn an_answer_for_an_id_no_request_ever_had_is_unknown_and_writes_nothing() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");

    for answers in [Some(valid_answers()), None, Some(vec![])] {
        let decision = ApprovalDecision {
            kind: DecisionKind::AnswerQuestions,
            note: None,
            answers,
        };
        assert_eq!(
            rig.broker.answer("no-such-request", &decision, "w", "app"),
            AnswerResult::UnknownRequest
        );
    }
    rig.barrier().await;
    assert!(rig.writes().is_empty());
}

#[tokio::test(start_paused = true)]
async fn two_windows_answering_at_the_same_moment_produce_exactly_one_write_and_the_winner_is_what_was_sent(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app-a");
    rig.broker.presenter_connected("app-b");

    for round in 0..30 {
        let tool = format!("toolu_race_{round}");
        let wire = rig.hold_ask(&tool).await;
        let go = Arc::new(Barrier::new(2));
        let (a, b) = std::thread::scope(|s| {
            let (b1, b2) = (rig.broker.clone(), rig.broker.clone());
            let (g1, g2) = (Arc::clone(&go), Arc::clone(&go));
            let (id1, id2) = (wire.request_id.clone(), wire.request_id.clone());
            let a = s.spawn(move || {
                g1.wait();
                b1.answer(&id1, &answer_questions(valid_answers()), "win-a", "app-a")
            });
            let b = s.spawn(move || {
                g2.wait();
                b2.answer(
                    &id2,
                    &answer_questions(other_valid_answers()),
                    "win-b",
                    "app-b",
                )
            });
            (a.join().unwrap(), b.join().unwrap())
        });

        let writes: Vec<_> = rig
            .writes()
            .into_iter()
            .filter(|(id, _)| *id == format!("cli-{tool}"))
            .collect();
        assert_eq!(
            writes.len(),
            1,
            "round {round}: exactly one answer reaches the CLI, got {writes:?}"
        );
        match (&a, &b) {
            (
                AnswerResult::Applied { outcome },
                AnswerResult::AlreadyResolved { outcome: told },
            ) => {
                assert_eq!(
                    (outcome.as_str(), told.as_str()),
                    ("answered", "answered"),
                    "round {round}"
                );
                assert_eq!(
                    writes[0].1["updatedInput"]["answers"][Q1], "SQLite",
                    "round {round}: A's answers were sent"
                );
            }
            (
                AnswerResult::AlreadyResolved { outcome: told },
                AnswerResult::Applied { outcome },
            ) => {
                assert_eq!(
                    (outcome.as_str(), told.as_str()),
                    ("answered", "answered"),
                    "round {round}"
                );
                assert_eq!(
                    writes[0].1["updatedInput"]["answers"][Q1], "Postgres",
                    "round {round}: B's answers were sent"
                );
            }
            other => {
                panic!("round {round}: exactly one applies and the other hears what won: {other:?}")
            }
        }
        rig.wait_outcome(&tool).await;
        assert_eq!(
            rig.outcomes(&tool).len(),
            1,
            "round {round}: one outcome entry"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn an_answer_racing_a_deny_produces_exactly_one_write_and_it_is_the_winners() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app-a");
    rig.broker.presenter_connected("app-b");

    for round in 0..30 {
        let tool = format!("toolu_race_{round}");
        let wire = rig.hold_ask(&tool).await;
        let go = Arc::new(Barrier::new(2));
        let (a, b) = std::thread::scope(|s| {
            let (b1, b2) = (rig.broker.clone(), rig.broker.clone());
            let (g1, g2) = (Arc::clone(&go), Arc::clone(&go));
            let (id1, id2) = (wire.request_id.clone(), wire.request_id.clone());
            let a = s.spawn(move || {
                g1.wait();
                b1.answer(&id1, &answer_questions(valid_answers()), "win-a", "app-a")
            });
            let b = s.spawn(move || {
                g2.wait();
                b2.answer(&id2, &deny(None), "win-b", "app-b")
            });
            (a.join().unwrap(), b.join().unwrap())
        });

        let writes: Vec<_> = rig
            .writes()
            .into_iter()
            .filter(|(id, _)| *id == format!("cli-{tool}"))
            .collect();
        assert_eq!(writes.len(), 1, "round {round}: {writes:?}");
        match (&a, &b) {
            (
                AnswerResult::Applied { outcome },
                AnswerResult::AlreadyResolved { outcome: told },
            ) => {
                assert_eq!(
                    (outcome.as_str(), told.as_str()),
                    ("answered", "answered"),
                    "round {round}"
                );
                assert_eq!(writes[0].1, expected_allow(), "round {round}");
            }
            (
                AnswerResult::AlreadyResolved { outcome: told },
                AnswerResult::Applied { outcome },
            ) => {
                assert_eq!(
                    (outcome.as_str(), told.as_str()),
                    ("denied", "denied"),
                    "round {round}"
                );
                assert_eq!(writes[0].1, deny_body(DENIED_MESSAGE), "round {round}");
            }
            other => panic!("round {round}: {other:?}"),
        }
    }
}

// ── the other decisions on a question request are what they always were ───────

#[tokio::test(start_paused = true)]
async fn deny_on_a_question_request_sends_the_usual_deny_words_and_ignores_any_answers() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let plain = rig.hold_ask("toolu_plain").await;
    let with_answers_attached = rig.hold_ask("toolu_attached").await;
    let attached = ApprovalDecision {
        kind: DecisionKind::Deny,
        note: Some("not now".into()),
        answers: Some(valid_answers()),
    };

    assert_eq!(
        rig.broker
            .answer(&plain.request_id, &deny(None), "w", "app"),
        applied("denied")
    );
    assert_eq!(
        rig.broker
            .answer(&with_answers_attached.request_id, &attached, "w", "app"),
        applied("denied")
    );

    let writes = rig.writes();
    let body = |id: &str| writes.iter().find(|(r, _)| r == id).unwrap().1.clone();
    assert_eq!(
        body("cli-toolu_plain"),
        deny_body("The user denied this in Nostromo.")
    );
    assert_eq!(
        body("cli-toolu_attached"),
        deny_body("The user denied this in Nostromo.\n\nUser's note: not now")
    );
    assert!(
        body("cli-toolu_attached").get("updatedInput").is_none(),
        "answers on a deny are ignored"
    );
}

#[tokio::test(start_paused = true)]
async fn deny_and_stop_on_a_question_request_sends_the_usual_words_with_interrupt_and_ignores_any_answers(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    let attached = ApprovalDecision {
        kind: DecisionKind::DenyAndStop,
        note: None,
        answers: Some(valid_answers()),
    };

    assert_eq!(
        rig.broker.answer(&wire.request_id, &attached, "w", "app"),
        applied("denied_and_stopped")
    );

    assert_eq!(
        rig.writes(),
        [(
            "cli-toolu_q".to_owned(),
            json!({ "behavior": "deny", "message": "The user denied this in Nostromo.", "interrupt": true })
        )]
    );
}

#[tokio::test(start_paused = true)]
async fn allow_once_on_a_question_request_is_refused_and_a_valid_answer_still_goes_through() {
    // The agent's own input can carry `answers`; forwarding it would put words in the person's mouth.
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    let result = rig
        .broker
        .answer(&wire.request_id, &allow_once(), "w", "app");

    assert_eq!(result, AnswerResult::InvalidAnswer);
    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "nothing written: {:?}",
        rig.writes()
    );
    assert_eq!(rig.broker.snapshot().len(), 1, "still held");
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        applied("answered")
    );
    assert_eq!(rig.writes().len(), 1);
    assert_eq!(rig.writes()[0].1, expected_allow());
}

// ── the clock, the app and the session still end a held question the same way ─

#[tokio::test(start_paused = true)]
async fn an_unanswered_question_is_denied_timed_out_at_fifteen_minutes_and_a_late_answer_is_never_an_allow(
) {
    let mut rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    settle().await;
    rig.frames();

    tokio::time::advance(Duration::from_secs(14 * 60 + 59)).await;
    settle().await;
    assert!(rig.writes().is_empty(), "nothing at 14:59");
    assert_eq!(rig.broker.snapshot().len(), 1);

    tokio::time::advance(Duration::from_secs(1)).await;
    let outcome = rig.wait_outcome("toolu_q").await;

    assert_eq!(outcome_name(&outcome), "timed_out");
    assert_eq!(
        rig.writes(),
        [("cli-toolu_q".to_owned(), deny_body(TIMED_OUT_MESSAGE))]
    );
    rig.frames_until("timed_out", |m| {
        matches!(m, ServerMsg::ApprovalResolved { request_id, outcome, by_window: None, .. }
        if *request_id == wire.request_id && outcome == "timed_out")
    })
    .await;
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        already("timed_out")
    );
    assert_eq!(rig.writes().len(), 1, "the late answer wrote nothing");
}

#[tokio::test(start_paused = true)]
async fn when_the_last_presenter_leaves_a_held_question_is_denied_no_app_after_the_grace_and_a_late_answer_is_never_an_allow(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    settle().await;

    rig.broker.app_disconnected("app");
    settle().await;
    tokio::time::advance(Duration::from_millis(2900)).await;
    settle().await;
    assert!(
        rig.writes().is_empty(),
        "nothing before the 3 s grace is over"
    );
    tokio::time::advance(Duration::from_millis(200)).await;
    let outcome = rig.wait_outcome("toolu_q").await;

    assert_eq!(outcome_name(&outcome), "no_app");
    assert_eq!(
        rig.writes(),
        [("cli-toolu_q".to_owned(), deny_body(NO_APP_MESSAGE))]
    );
    assert!(PRESENTER_GRACE < Duration::from_secs(5));
    rig.broker.presenter_connected("app-late");
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app-late"
        ),
        already("no_app")
    );
    assert_eq!(rig.writes().len(), 1, "the late answer wrote nothing");
}

#[tokio::test(start_paused = true)]
async fn a_question_that_is_held_when_the_app_reconnects_inside_the_grace_can_still_be_answered() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;
    settle().await;
    rig.broker.app_disconnected("app");
    settle().await;
    tokio::time::advance(Duration::from_secs(2)).await;

    let snapshot = rig.broker.presenter_connected("app-again");

    assert_eq!(snapshot, vec![wire.clone()]);
    assert_eq!(snapshot[0].options, with_answer_questions());
    tokio::time::advance(Duration::from_secs(60)).await;
    settle().await;
    assert!(rig.writes().is_empty());
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app-again"
        ),
        applied("answered")
    );
    assert_eq!(rig.writes()[0].1, expected_allow());
}

#[tokio::test(start_paused = true)]
async fn a_session_that_stops_cancels_its_held_question_and_nothing_is_written_and_a_late_answer_is_never_an_allow(
) {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let wire = rig.hold_ask("toolu_q").await;

    rig.broker.on_session_gone(T, rig.generation, "stopped");

    assert_eq!(
        outcome_name(&rig.wait_outcome("toolu_q").await),
        "cancelled"
    );
    assert!(
        rig.writes().is_empty(),
        "never write to a session that is gone"
    );
    assert_eq!(
        rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        already("cancelled")
    );
    assert!(rig.writes().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// C. The only allow in the question flow is a valid answer from the operator app
// ═════════════════════════════════════════════════════════════════════════════

/// T-INV-3 for questions. Many question requests end in many ways, with many bad attempts to
/// approve them along the way. Every `behavior: allow` that reaches the CLI is the one produced
/// by a valid `answer_questions` from a presenter, and carries the answers.
#[tokio::test(start_paused = true)]
async fn the_only_allow_written_for_a_question_is_a_valid_answer_from_the_operator_app() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    rig.broker.app_connected("operator-only");
    let answered = rig.hold_ask("toolu_answered").await;
    let denied = rig.hold_ask("toolu_denied").await;
    let stopped = rig.hold_ask("toolu_stopped").await;
    let bad = rig.hold_ask("toolu_bad").await;
    let timed_out = rig.hold_ask("toolu_timeout").await;
    let bash = rig.hold_bash("toolu_bash").await;

    // Every wrong way to ask for an allow with answers.
    let wrong: Vec<(&str, &str, ApprovalDecision)> = vec![
        (
            "app",
            "no answers",
            ApprovalDecision {
                kind: DecisionKind::AnswerQuestions,
                note: None,
                answers: None,
            },
        ),
        ("app", "empty answers", answer_questions(vec![])),
        (
            "app",
            "incomplete",
            answer_questions(vec![qa(Q1, &["SQLite"], None)]),
        ),
        (
            "app",
            "unknown label",
            answer_questions(vec![qa(Q1, &["MySQL"], None), qa(Q2, &["Caching"], None)]),
        ),
        (
            "app",
            "blank free text",
            answer_questions(vec![qa(Q1, &[], Some("   ")), qa(Q2, &["Caching"], None)]),
        ),
        (
            "app",
            "too long",
            answer_questions(vec![
                qa(Q1, &[], Some(&"a".repeat(MAX_OTHER_CHARS + 1))),
                qa(Q2, &["Caching"], None),
            ]),
        ),
        (
            "operator-only",
            "valid, but not a presenter",
            answer_questions(valid_answers()),
        ),
        (
            "stranger",
            "valid, but never connected",
            answer_questions(valid_answers()),
        ),
    ];
    for (conn, what, decision) in &wrong {
        let result = rig.broker.answer(&bad.request_id, decision, "w", conn);
        assert!(
            result.refusal().is_some(),
            "{what} must be refused, got {result:?}"
        );
        assert!(
            matches!(
                result,
                AnswerResult::InvalidAnswer | AnswerResult::NotPresenter
            ),
            "{what}: {result:?}"
        );
    }
    // A question's answer aimed at a Bash request is not an allow either.
    assert_eq!(
        rig.broker.answer(
            &bash.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        AnswerResult::InvalidAnswer
    );
    rig.barrier().await;
    assert!(
        rig.writes().is_empty(),
        "no refused attempt wrote anything: {:?}",
        rig.writes()
    );

    // The legitimate endings.
    assert_eq!(
        rig.broker.answer(
            &answered.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app"
        ),
        applied("answered")
    );
    assert_eq!(
        rig.broker
            .answer(&denied.request_id, &deny(None), "w", "app"),
        applied("denied")
    );
    assert_eq!(
        rig.broker
            .answer(&stopped.request_id, &deny_and_stop(None), "w", "app"),
        applied("denied_and_stopped")
    );
    assert_eq!(
        rig.broker.answer(&bash.request_id, &deny(None), "w", "app"),
        applied("denied")
    );
    settle().await;
    tokio::time::advance(APPROVAL_TIMEOUT).await;
    rig.wait_outcome("toolu_timeout").await;
    rig.wait_outcome("toolu_bad").await;
    // Late attempts, with the one valid answer, after everything ended.
    for wire in [&answered, &denied, &stopped, &bad, &timed_out, &bash] {
        let late = rig.broker.answer(
            &wire.request_id,
            &answer_questions(valid_answers()),
            "w",
            "app",
        );
        assert!(
            matches!(late, AnswerResult::AlreadyResolved { .. }),
            "late answer: {late:?}"
        );
    }

    let writes = rig.writes();
    assert_eq!(
        writes.len(),
        6,
        "one write per request, whatever was attempted: {writes:?}"
    );
    let allows: Vec<&(String, Value)> = writes
        .iter()
        .filter(|(_, body)| body["behavior"] == "allow")
        .collect();
    assert_eq!(allows.len(), 1, "exactly one allow: {writes:?}");
    assert_eq!(allows[0].0, "cli-toolu_answered");
    assert_eq!(allows[0].1, expected_allow());
    for (id, body) in &writes {
        if id != "cli-toolu_answered" {
            assert_eq!(body["behavior"], "deny", "{id}: {body}");
            assert!(
                body.get("updatedInput").is_none(),
                "{id}: a deny never carries input"
            );
        }
    }
    let by_id = |id: &str| writes.iter().find(|(r, _)| r == id).unwrap().1.clone();
    assert_eq!(by_id("cli-toolu_timeout"), deny_body(TIMED_OUT_MESSAGE));
    assert_eq!(by_id("cli-toolu_bad"), deny_body(TIMED_OUT_MESSAGE));
}

/// An answer set that is valid in shape but belongs to a different request's questions is not an allow.
#[tokio::test(start_paused = true)]
async fn answers_written_for_one_question_set_cannot_approve_a_request_with_other_questions() {
    let rig = Rig::new();
    rig.broker.presenter_connected("app");
    let other_questions = input_with(vec![choice("Which editor?", &["vim", "emacs"])]);
    let wire = rig
        .hold_value(
            "toolu_other",
            ask_request("toolu_other", other_questions.clone()),
        )
        .await;
    assert_eq!(
        wire.options,
        with_answer_questions(),
        "it is answerable on its own terms"
    );

    let result = rig.broker.answer(
        &wire.request_id,
        &answer_questions(valid_answers()),
        "w",
        "app",
    );

    assert_eq!(result, AnswerResult::InvalidAnswer);
    assert!(rig.writes().is_empty());
    let right = rig.broker.answer(
        &wire.request_id,
        &answer_questions(vec![qa("Which editor?", &["vim"], None)]),
        "w",
        "app",
    );
    assert_eq!(right, applied("answered"));
    assert_eq!(
        rig.writes(),
        [(
            "cli-toolu_other".to_owned(),
            json!({ "behavior": "allow", "updatedInput": with_answers(&other_questions, answers_obj(&[("Which editor?", "vim")])) })
        )]
    );
}
