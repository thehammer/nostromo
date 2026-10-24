//! `parse_line` and a `control_request` it cannot fully parse (PR #270 review
//! fix-up B1).
//!
//! The CLI serialises with `JSON.stringify`, which has no depth limit, and then
//! waits forever for an answer to a `can_use_tool` request. `serde_json` stops at
//! 128 levels of nesting, so such a line used to parse to `None` and be dropped
//! unanswered. The contract tested here:
//!
//! - a line whose top-level `type` is `control_request` and that cannot be fully
//!   parsed (nested too deep, malformed, cut off, longer than
//!   [`MAX_CONTROL_REQUEST_PARSE_BYTES`], or with a `request_id` that is not a
//!   string) is `ParsedLine::UnreadableControlRequest`, carrying whatever a
//!   scan of the line recovered: the top-level `request_id` (a string or a
//!   number, as the same JSON value), `request.subtype` and `request.tool_name`;
//! - the scan never builds a JSON value of the line (a 100,000-deep one would
//!   overflow the stack when dropped) and takes linear time;
//! - ids/subtypes/tool names found deeper in the line (`input` can contain
//!   anything) are never mistaken for the request's own; a duplicate key means
//!   the last one wins, as in a full parse;
//! - a string never comes back half-read: a line cut off inside the id yields no id;
//! - every other line (any other type, valid or garbage) is parsed exactly as it
//!   always was, and a control request that parses with a string id is unchanged.

use std::time::{Duration, Instant};

use nostromo::ipc::stream_json::{parse_line, ParsedLine, MAX_CONTROL_REQUEST_PARSE_BYTES};
use serde_json::{json, Value};

// ── building lines (by concatenation: nothing here recurses) ──────────────────

fn nested_arrays(depth: usize) -> String {
    format!("{}{}", "[".repeat(depth), "]".repeat(depth))
}

fn nested_objects(depth: usize) -> String {
    format!("{}1{}", "{\"a\":".repeat(depth), "}".repeat(depth))
}

/// A `can_use_tool` line in the order the CLI writes its keys.
fn can_use_tool(id_json: &str, input_json: &str) -> String {
    format!(
        r#"{{"type":"control_request","request_id":{id_json},"request":{{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{input_json},"tool_use_id":"toolu_1"}}}}"#
    )
}

fn deep_input(depth: usize) -> String {
    format!(
        r#"{{"command":"rm -rf /tmp/x","n":{}}}"#,
        nested_arrays(depth)
    )
}

/// What a scan of an unreadable control request recovered.
#[derive(Debug, PartialEq)]
struct Hint {
    request_id: Option<Value>,
    subtype: Option<String>,
    tool_name: Option<String>,
}

fn hint(request_id: Option<Value>, subtype: Option<&str>, tool_name: Option<&str>) -> Hint {
    Hint {
        request_id,
        subtype: subtype.map(str::to_owned),
        tool_name: tool_name.map(str::to_owned),
    }
}

/// The start of a line, for a failure message (a line can be megabytes long).
fn snip(line: &str) -> String {
    let head: String = line.chars().take(160).collect();
    format!("{head}… ({} bytes)", line.len())
}

#[track_caller]
fn unreadable(line: &str) -> Hint {
    match parse_line(line) {
        Some(ParsedLine::UnreadableControlRequest {
            request_id,
            subtype,
            tool_name,
        }) => Hint {
            request_id,
            subtype,
            tool_name,
        },
        Some(_) => panic!("expected an unreadable control request for {}", snip(line)),
        None => panic!("the line was dropped (None): {}", snip(line)),
    }
}

#[track_caller]
fn assert_not_a_control_request(line: &str, why: &str) {
    match parse_line(line) {
        Some(ParsedLine::UnreadableControlRequest { .. }) => {
            panic!(
                "{why}: wrongly an unreadable control request: {}",
                snip(line)
            )
        }
        Some(ParsedLine::ControlRequest { .. }) => {
            panic!("{why}: wrongly a control request: {}", snip(line))
        }
        _ => {}
    }
}

#[track_caller]
fn assert_fast<R>(what: &str, limit: Duration, f: impl FnOnce() -> R) -> R {
    let started = Instant::now();
    let out = f();
    let took = started.elapsed();
    assert!(took < limit, "{what}: took {took:?} (limit {limit:?})");
    out
}

// ── what still parses is unchanged ────────────────────────────────────────────

const SPIKE_CAN_USE_TOOL: &str = r#"{"type":"control_request","request_id":"315e4b2d-d8ae-4f3e-b81a-fc597edca048","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"rm -rf /tmp/archie-spike/work/victim/a","description":"remove a"},"description":"remove a","decision_reason_type":"rule","tool_use_id":"toolu_spike_0"}}"#;

#[test]
fn a_permission_prompt_that_parses_is_still_a_control_request_carrying_the_request_as_received() {
    let frame: Value = serde_json::from_str(SPIKE_CAN_USE_TOOL).unwrap();

    match parse_line(SPIKE_CAN_USE_TOOL) {
        Some(ParsedLine::ControlRequest {
            request_id,
            subtype,
            request,
        }) => {
            assert_eq!(request_id, "315e4b2d-d8ae-4f3e-b81a-fc597edca048");
            assert_eq!(subtype, "can_use_tool");
            assert_eq!(request, frame["request"]);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_control_request_of_another_subtype_that_parses_is_still_a_control_request() {
    let line = r#"{"type":"control_request","request_id":"r1","request":{"subtype":"hook_callback","callback_id":"hook_0"}}"#;

    match parse_line(line) {
        Some(ParsedLine::ControlRequest {
            request_id,
            subtype,
            request,
        }) => {
            assert_eq!(
                (request_id.as_str(), subtype.as_str()),
                ("r1", "hook_callback")
            );
            assert_eq!(request["callback_id"], "hook_0");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_line_with_surrounding_whitespace_is_read_like_the_bare_line() {
    let padded = format!("  \t{SPIKE_CAN_USE_TOOL}\r");
    assert_eq!(parse_line(&padded), parse_line(SPIKE_CAN_USE_TOOL));
    let deep = can_use_tool(r#""r-ws""#, &deep_input(300));
    assert_eq!(
        unreadable(&format!(" {deep}\r")),
        hint(Some(json!("r-ws")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn every_recorded_request_still_parses_and_its_deep_twin_is_unreadable_with_the_same_hints() {
    let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approvals");
    let mut seen = 0;
    for file in std::fs::read_dir(&dir).unwrap() {
        let path = file.unwrap().path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let request = doc["requests"][0]["request"].clone();
        let id = format!("rid-{name}");
        seen += 1;

        // As recorded: unchanged.
        let line = format!(
            r#"{{"type":"control_request","request_id":"{id}","request":{}}}"#,
            serde_json::to_string(&request).unwrap()
        );
        match parse_line(&line) {
            Some(ParsedLine::ControlRequest {
                request_id,
                subtype,
                request: parsed,
            }) => {
                assert_eq!(request_id, id, "{name}");
                assert_eq!(subtype, request["subtype"].as_str().unwrap(), "{name}");
                assert_eq!(parsed, request, "{name}");
            }
            other => panic!("{name}: {other:?}"),
        }

        // The same request with its input replaced by a 500-deep one.
        let mut bare = request.clone();
        bare.as_object_mut().unwrap().remove("input");
        let bare = serde_json::to_string(&bare).unwrap();
        let spliced = if bare == "{}" {
            format!(r#"{{"input":{}}}"#, deep_input(500))
        } else {
            format!(
                r#"{},"input":{}}}"#,
                &bare[..bare.len() - 1],
                deep_input(500)
            )
        };
        let deep =
            format!(r#"{{"type":"control_request","request_id":"{id}","request":{spliced}}}"#);
        assert_eq!(
            unreadable(&deep),
            hint(
                Some(json!(id)),
                request["subtype"].as_str(),
                request["tool_name"].as_str()
            ),
            "{name}"
        );
    }
    assert!(seen >= 25, "the fixture set went missing: {seen}");
}

// ── a request id that is not a string ─────────────────────────────────────────

#[test]
fn a_readable_request_with_a_numeric_id_is_unreadable_and_keeps_the_number() {
    for (id_json, id) in [
        ("7", json!(7)),
        ("0", json!(0)),
        ("-3", json!(-3)),
        ("1.5", json!(1.5)),
        ("18446744073709551615", json!(u64::MAX)),
    ] {
        let line = can_use_tool(id_json, r#"{"command":"ls"}"#);
        assert_eq!(
            unreadable(&line),
            hint(Some(id), Some("can_use_tool"), Some("Bash")),
            "request_id {id_json}"
        );
    }
}

#[test]
fn a_request_id_that_is_neither_a_string_nor_a_number_cannot_be_recovered() {
    for id_json in ["true", "null", "[1,2]", r#"{"a":1}"#, "[]", "{}"] {
        let line = can_use_tool(id_json, r#"{"command":"ls"}"#);
        let h = unreadable(&line);
        assert_eq!(h.request_id, None, "request_id {id_json}");
    }
}

#[test]
fn a_control_request_without_any_request_id_cannot_be_answered_and_is_reported_unreadable() {
    let line =
        r#"{"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#;

    let h = unreadable(line);

    assert_eq!(h.request_id, None);
}

// ── too deep for serde ────────────────────────────────────────────────────────

#[test]
fn a_deep_request_is_never_dropped_whatever_the_depth() {
    // Around serde's limit of 128 and well past it: either the line parses (and
    // is an ordinary control request with its id) or it is unreadable with the id.
    for depth in (90..=140).chain([200, 500, 5_000]) {
        let line = can_use_tool(r#""req-1""#, &deep_input(depth));
        match parse_line(&line) {
            Some(ParsedLine::ControlRequest { request_id, .. }) => {
                assert_eq!(request_id, "req-1", "depth {depth}");
                assert!(depth < 128, "depth {depth} parsed fully?");
            }
            Some(ParsedLine::UnreadableControlRequest {
                request_id,
                subtype,
                tool_name,
            }) => {
                assert_eq!(
                    (request_id, subtype.as_deref(), tool_name.as_deref()),
                    (Some(json!("req-1")), Some("can_use_tool"), Some("Bash")),
                    "depth {depth}"
                );
            }
            other => panic!(
                "depth {depth}: dropped or misread: {:?}",
                other.map(|_| "some")
            ),
        }
    }
}

#[test]
fn depths_127_128_500_and_100000_are_unreadable_with_everything_recovered() {
    for depth in [127, 128, 500, 100_000] {
        let line = can_use_tool(r#""req-1""#, &deep_input(depth));
        assert_eq!(
            unreadable(&line),
            hint(Some(json!("req-1")), Some("can_use_tool"), Some("Bash")),
            "depth {depth}"
        );
    }
}

#[test]
fn deeply_nested_objects_are_handled_like_deeply_nested_arrays() {
    let input = format!(r#"{{"command":"ls","n":{}}}"#, nested_objects(100_000));
    let line = can_use_tool(r#""req-9""#, &input);

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("req-9")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn a_hundred_thousand_levels_is_scanned_without_a_stack_overflow_in_bounded_time() {
    // The test thread has a small stack: anything recursive (a parse into a
    // JSON value, or dropping one) overflows it long before 100,000 levels.
    let arrays = can_use_tool(r#""req-1""#, &deep_input(100_000));
    let objects = can_use_tool(
        r#""req-2""#,
        &format!(r#"{{"n":{}}}"#, nested_objects(100_000)),
    );
    for (line, id) in [(&arrays, "req-1"), (&objects, "req-2")] {
        let h = assert_fast("a 100,000-deep line", Duration::from_secs(5), || {
            unreadable(line)
        });
        assert_eq!(h.request_id, Some(json!(id)));
    }
}

#[test]
fn the_scan_is_linear_a_million_levels_and_a_line_over_the_cap_are_still_quick() {
    // 2 MB of nesting (under the cap), and 6 MB (over it), id first and id last.
    let under = 1_000_000;
    let over = 3_000_000;
    assert!(2 * under < MAX_CONTROL_REQUEST_PARSE_BYTES);
    assert!(2 * over > MAX_CONTROL_REQUEST_PARSE_BYTES);
    for depth in [under, over] {
        let first = can_use_tool(r#""req-first""#, &deep_input(depth));
        let h = assert_fast("id before the payload", Duration::from_secs(10), || {
            unreadable(&first)
        });
        assert_eq!(h.request_id, Some(json!("req-first")), "depth {depth}");

        let last = format!(
            r#"{{"type":"control_request","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{}}},"request_id":"req-last"}}"#,
            deep_input(depth)
        );
        let h = assert_fast("id after the payload", Duration::from_secs(10), || {
            unreadable(&last)
        });
        assert_eq!(
            h,
            hint(Some(json!("req-last")), Some("can_use_tool"), Some("Bash")),
            "depth {depth}"
        );
    }
}

#[test]
fn many_unclosed_brackets_in_a_row_are_scanned_in_linear_time() {
    // A line that opens 3 million levels and never closes them.
    let line = format!(
        r#"{{"type":"control_request","request_id":"req-open","request":{{"subtype":"can_use_tool","input":{}"#,
        "[".repeat(3_000_000)
    );

    let h = assert_fast("unclosed nesting", Duration::from_secs(10), || {
        unreadable(&line)
    });

    assert_eq!(h.request_id, Some(json!("req-open")));
    assert_eq!(h.subtype.as_deref(), Some("can_use_tool"));
}

// ── where the keys are ────────────────────────────────────────────────────────

#[test]
fn the_top_level_keys_may_come_in_any_order() {
    let deep = deep_input(500);
    let expected = hint(Some(json!("r1")), Some("can_use_tool"), Some("Bash"));
    let lines = [
        // type last
        format!(
            r#"{{"request_id":"r1","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{deep}}},"type":"control_request"}}"#
        ),
        // request first, id last
        format!(
            r#"{{"type":"control_request","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{deep}}},"request_id":"r1"}}"#
        ),
        // subtype and tool_name after the (deep) input
        format!(
            r#"{{"type":"control_request","request_id":"r1","request":{{"input":{deep},"tool_name":"Bash","subtype":"can_use_tool"}}}}"#
        ),
        // everything reversed
        format!(
            r#"{{"request":{{"tool_name":"Bash","subtype":"can_use_tool","input":{deep}}},"request_id":"r1","type":"control_request"}}"#
        ),
    ];
    for (i, line) in lines.iter().enumerate() {
        assert_eq!(unreadable(line), expected, "ordering {i}");
    }
}

#[test]
fn spaces_between_tokens_do_not_matter() {
    let deep = deep_input(500);
    let line = format!(
        "{{ \"type\" : \"control_request\" ,\t\"request_id\" : \"r1\" , \"request\" : {{ \"subtype\" : \"can_use_tool\" , \"tool_name\" : \"Bash\" , \"input\" : {deep} }} }}"
    );

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("r1")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn a_later_duplicate_key_wins_as_in_a_full_parse() {
    let deep = nested_arrays(500);
    let line = format!(
        r#"{{"type":"control_request","request_id":"first","request":{{"subtype":"elicitation","tool_name":"Old","n":{deep},"subtype":"can_use_tool","tool_name":"Bash"}},"request_id":"second"}}"#
    );

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("second")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn a_later_duplicate_type_decides_whether_it_is_a_control_request() {
    let deep = nested_arrays(500);
    // control_request, then assistant: an assistant line (dropped, as before).
    let to_assistant = format!(
        r#"{{"type":"control_request","request_id":"r","type":"assistant","message":{{"n":{deep}}}}}"#
    );
    assert_eq!(parse_line(&to_assistant), None);
    // assistant, then control_request: a control request.
    let to_request = format!(
        r#"{{"type":"assistant","request_id":"r","type":"control_request","request":{{"subtype":"can_use_tool"}},"n":{deep}}}"#
    );
    assert_eq!(
        unreadable(&to_request),
        hint(Some(json!("r")), Some("can_use_tool"), None)
    );
}

#[test]
fn ids_subtypes_and_tool_names_nested_inside_the_input_are_not_the_requests_own() {
    let deep = nested_arrays(500);
    let decoys = format!(
        r#"{{"request_id":"evil","subtype":"elicitation","tool_name":"Evil","type":"assistant","request":{{"subtype":"hook_callback","tool_name":"Worse"}},"n":{deep}}}"#
    );
    let expected = hint(Some(json!("real")), Some("can_use_tool"), Some("Bash"));
    // Decoys before the real values, after them, and with the real id last.
    let lines = [
        format!(
            r#"{{"type":"control_request","request_id":"real","request":{{"input":{decoys},"subtype":"can_use_tool","tool_name":"Bash"}}}}"#
        ),
        format!(
            r#"{{"type":"control_request","request_id":"real","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{decoys}}}}}"#
        ),
        format!(
            r#"{{"type":"control_request","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{decoys}}},"request_id":"real"}}"#
        ),
        format!(
            r#"{{"decoy":{decoys},"type":"control_request","request_id":"real","request":{{"subtype":"can_use_tool","tool_name":"Bash"}}}}"#
        ),
    ];
    for (i, line) in lines.iter().enumerate() {
        assert_eq!(unreadable(line), expected, "layout {i}");
    }
}

#[test]
fn a_top_level_subtype_or_tool_name_outside_request_is_not_the_requests() {
    let deep = nested_arrays(500);
    let line = format!(
        r#"{{"type":"control_request","subtype":"top","tool_name":"Top","request_id":"r1","request":{{"n":{deep}}}}}"#
    );

    assert_eq!(unreadable(&line), hint(Some(json!("r1")), None, None));
}

#[test]
fn a_request_that_is_not_an_object_has_no_subtype_or_tool_name_but_keeps_its_id() {
    let deep = nested_arrays(500);
    for request in [
        r#""just text""#.to_owned(),
        format!("[{deep}]"),
        "null".to_owned(),
        "7".to_owned(),
    ] {
        let line = format!(
            r#"{{"type":"control_request","request_id":"r1","request":{request},"n":{deep}}}"#
        );
        assert_eq!(
            unreadable(&line),
            hint(Some(json!("r1")), None, None),
            "{}",
            snip(&request)
        );
    }
}

#[test]
fn a_tool_name_is_only_recovered_when_it_is_short_enough_to_be_a_name() {
    let deep = nested_arrays(500);
    let make = |name: &str| {
        format!(
            r#"{{"type":"control_request","request_id":"r1","request":{{"subtype":"can_use_tool","tool_name":"{name}","input":{deep}}}}}"#
        )
    };
    let name_256 = "t".repeat(256);
    assert_eq!(
        unreadable(&make(&name_256)).tool_name.as_deref(),
        Some(name_256.as_str()),
        "256 bytes is recovered whole"
    );
    let long = "t".repeat(100_000);
    let h = unreadable(&make(&long));
    assert!(
        h.tool_name.as_ref().is_none_or(|t| t.len() <= 256),
        "a tool name is never recorded longer than 256 bytes: {} bytes",
        h.tool_name.as_ref().map_or(0, String::len)
    );
    assert_eq!(h.request_id, Some(json!("r1")));
    assert_eq!(h.subtype.as_deref(), Some("can_use_tool"));
}

// ── ids full of escapes and non-ASCII ─────────────────────────────────────────

#[test]
fn an_id_with_json_escapes_is_decoded_exactly() {
    let cases = [
        (r#""a\"b\\c\/d""#, "a\"b\\c/d"),
        (r#""line\nbreak\ttab\r""#, "line\nbreak\ttab\r"),
        (r#""café""#, "caf\u{e9}"),
        (r#""😀 smile""#, "\u{1F600} smile"),
        (r#""AB""#, "AB"),
        (r#""ends with backslash \\""#, "ends with backslash \\"),
        (r#""""#, ""),
    ];
    let deep = deep_input(500);
    for (id_json, decoded) in cases {
        let line = can_use_tool(id_json, &deep);
        assert_eq!(
            unreadable(&line).request_id,
            Some(json!(decoded)),
            "{id_json}"
        );
    }
}

#[test]
fn an_id_with_raw_non_ascii_text_is_kept_as_is() {
    let line = can_use_tool("\"r\u{e9}q-\u{1F600}-\u{4e2d}\"", &deep_input(500));

    assert_eq!(
        unreadable(&line).request_id,
        Some(json!("r\u{e9}q-\u{1F600}-\u{4e2d}"))
    );
}

#[test]
fn an_escaped_quote_inside_the_input_does_not_end_a_string_early() {
    // A string full of \" and \\ that, read wrongly, would make the scanner see
    // a fake `"request_id":"evil"` key and value, or lose track of nesting.
    let input = r#"{"command":"echo \"request_id\":\"evil\" \\","n":[[[[[1]]]]],"tail":"\\\"}]}"}"#;
    let long_nest = nested_arrays(500);
    let line = format!(
        r#"{{"type":"control_request","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{input},"x":{long_nest}}},"request_id":"real"}}"#
    );

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("real")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn brackets_and_braces_inside_strings_are_not_nesting() {
    let input = format!(
        r#"{{"command":"{}","n":{}}}"#,
        "[[[[{{{{".repeat(5_000),
        nested_arrays(300)
    );
    let line = can_use_tool(r#""r1""#, &input);

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("r1")), Some("can_use_tool"), Some("Bash"))
    );
}

// ── broken lines ──────────────────────────────────────────────────────────────

#[test]
fn malformed_json_after_the_id_is_unreadable_with_what_came_before_the_break() {
    let expected = hint(Some(json!("r1")), Some("can_use_tool"), Some("Bash"));
    let lines = [
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":}}"#,
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash",,}}"#,
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash"}} trailing garbage"#,
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}}"#,
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{'command':'ls'}}}"#,
        r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},}}"#,
    ];
    for (i, line) in lines.iter().enumerate() {
        assert_eq!(unreadable(line), expected, "variant {i}: {line}");
    }
}

#[test]
fn a_line_cut_off_anywhere_is_unreadable_and_never_yields_a_half_read_string() {
    let line = r#"{"type":"control_request","request_id":"req-42","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /tmp/x"}}}"#;
    let end_of = |needle: &str| line.find(needle).expect(needle) + needle.len();
    let (type_end, id_end, sub_end, tool_end) = (
        end_of(r#""type":"control_request""#),
        end_of(r#""request_id":"req-42""#),
        end_of(r#""subtype":"can_use_tool""#),
        end_of(r#""tool_name":"Bash""#),
    );

    for cut in 0..line.len() {
        let prefix = &line[..cut];
        let parsed = parse_line(prefix);
        // Too little to know it is a control request: left alone, as before.
        if cut + 2 <= type_end {
            assert_eq!(parsed, None, "cut at {cut}: {prefix}");
            continue;
        }
        // (Right at the end of the type value it may go either way.)
        if cut <= type_end {
            continue;
        }
        let Some(ParsedLine::UnreadableControlRequest {
            request_id,
            subtype,
            tool_name,
        }) = parsed
        else {
            panic!("cut at {cut}: expected an unreadable control request: {prefix}");
        };
        let recovered = |end: usize| cut > end;
        let not_yet = |end: usize| cut + 2 <= end;
        if recovered(id_end) {
            assert_eq!(request_id, Some(json!("req-42")), "cut at {cut}: {prefix}");
        } else if not_yet(id_end) {
            assert_eq!(request_id, None, "cut at {cut}: {prefix}");
        }
        if recovered(sub_end) {
            assert_eq!(
                subtype.as_deref(),
                Some("can_use_tool"),
                "cut at {cut}: {prefix}"
            );
        } else if not_yet(sub_end) {
            assert_eq!(subtype, None, "cut at {cut}: {prefix}");
        }
        if recovered(tool_end) {
            assert_eq!(tool_name.as_deref(), Some("Bash"), "cut at {cut}: {prefix}");
        } else if not_yet(tool_end) {
            assert_eq!(tool_name, None, "cut at {cut}: {prefix}");
        }
    }
    assert!(matches!(
        parse_line(line),
        Some(ParsedLine::ControlRequest { .. })
    ));
}

#[test]
fn a_numeric_id_cut_off_in_the_middle_of_its_digits_is_not_guessed() {
    // "request_id":75 cut after the 7 could be 7, 75 or 7500: nothing to answer under.
    let line =
        r#"{"type":"control_request","request_id":7500,"request":{"subtype":"can_use_tool"}}"#;
    let cut = line.find("7500").unwrap() + 1;

    let h = unreadable(&line[..cut]);

    assert_eq!(h.request_id, None);
    let h = unreadable(&line[..line.find("7500").unwrap() + 4 + 1]);
    assert_eq!(
        h.request_id,
        Some(json!(7500)),
        "once the number has ended it is whole"
    );
}

#[test]
fn a_request_cut_off_before_its_id_is_unreadable_without_one() {
    let line = r#"{"type":"control_request","request":{"subtype":"can_use_tool","#;

    assert_eq!(
        unreadable(line),
        hint(None, Some("can_use_tool"), None),
        "no id to answer under, but what was seen is reported"
    );
}

// ── the size cap ──────────────────────────────────────────────────────────────

/// A readable can_use_tool line exactly `total` bytes long.
fn sized_request(total: usize, id_json: &str) -> String {
    let head = format!(
        r#"{{"type":"control_request","request_id":{id_json},"request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{{"command":""#
    );
    let tail = r#""}}}"#;
    let fill = total - head.len() - tail.len();
    let line = format!("{head}{}{tail}", "x".repeat(fill));
    assert_eq!(line.len(), total);
    line
}

#[test]
fn a_cap_of_four_mib() {
    assert_eq!(MAX_CONTROL_REQUEST_PARSE_BYTES, 4 * 1024 * 1024);
}

#[test]
fn a_valid_line_just_under_the_cap_is_an_ordinary_control_request() {
    let line = sized_request(MAX_CONTROL_REQUEST_PARSE_BYTES - 1, r#""r-big""#);

    match parse_line(&line) {
        Some(ParsedLine::ControlRequest {
            request_id,
            subtype,
            ..
        }) => assert_eq!(
            (request_id.as_str(), subtype.as_str()),
            ("r-big", "can_use_tool")
        ),
        other => panic!("{:?}", other.map(|_| "something else")),
    }
}

#[test]
fn a_valid_line_longer_than_the_cap_is_unreadable_with_its_id_recovered() {
    let line = sized_request(MAX_CONTROL_REQUEST_PARSE_BYTES + 1, r#""r-big""#);

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("r-big")), Some("can_use_tool"), Some("Bash"))
    );
    // The same with a number for an id.
    assert_eq!(
        unreadable(&sized_request(MAX_CONTROL_REQUEST_PARSE_BYTES + 1, "7")).request_id,
        Some(json!(7))
    );
}

#[test]
fn an_oversize_line_with_the_id_after_the_payload_still_gives_the_id() {
    let fill = "x".repeat(MAX_CONTROL_REQUEST_PARSE_BYTES + 1000);
    let line = format!(
        r#"{{"type":"control_request","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{{"command":"{fill}"}}}},"request_id":"r-last"}}"#
    );

    assert_eq!(
        unreadable(&line),
        hint(Some(json!("r-last")), Some("can_use_tool"), Some("Bash"))
    );
}

#[test]
fn an_oversize_line_that_is_not_a_control_request_is_left_alone_as_before() {
    let fill = "x".repeat(MAX_CONTROL_REQUEST_PARSE_BYTES + 1000);
    let assistant = format!(
        r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{fill}"}}]}}}}"#
    );
    assert_not_a_control_request(&assistant, "an oversize assistant line");
    assert_not_a_control_request(&format!("not json {fill}"), "oversize garbage");
    assert_eq!(parse_line(&format!("not json {fill}")), None);
    let looks_like = format!(
        r#"{{"type":"assistant","request_id":"r","request":{{"subtype":"can_use_tool"}},"pad":"{fill}"}}"#
    );
    assert_not_a_control_request(&looks_like, "an oversize line of another type");
}

// ── everything else behaves as before ─────────────────────────────────────────

#[test]
fn lines_that_are_not_control_requests_are_parsed_exactly_as_before() {
    let deep = nested_arrays(500);
    let very_deep = nested_arrays(100_000);
    let dropped = [
        "".to_owned(),
        "   ".to_owned(),
        "this is not json at all {{{".to_owned(),
        "[1,2,3]".to_owned(),
        "7".to_owned(),
        r#""control_request""#.to_owned(),
        "null".to_owned(),
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"cut off"#.to_owned(),
        r#"{"type":"frobnicate","request_id":"x","request":{"subtype":"can_use_tool"}}"#.to_owned(),
        format!(r#"{{"type":"assistant","message":{{"content":[],"n":{deep}}}}}"#),
        format!(r#"{{"type":"assistant","message":{{"content":[],"n":{very_deep}}}}}"#),
        format!(r#"{{"type":"user","message":{{"content":"x","n":{deep}}}}}"#),
        format!(r#"{{"type":"system","subtype":"init","n":{deep}}}"#),
        format!(r#"{{"type":"result","n":{deep}}}"#),
        format!(r#"{{"type":"control_cancel_request","request_id":"r1","n":{deep}}}"#),
        // Near misses of the type name.
        format!(r#"{{"type":"control_request_extra","request_id":"r1","request":{{"subtype":"can_use_tool"}},"n":{deep}}}"#),
        format!(r#"{{"type":"Control_Request","request_id":"r1","request":{{"subtype":"can_use_tool"}},"n":{deep}}}"#),
        format!(r#"{{"type":"control_request ","request_id":"r1","request":{{"subtype":"can_use_tool"}},"n":{deep}}}"#),
        // Not a string type.
        format!(r#"{{"type":5,"request_id":"r1","request":{{"subtype":"can_use_tool"}},"n":{deep}}}"#),
        format!(r#"{{"type":["control_request"],"request_id":"r1","n":{deep}}}"#),
        // `control_request` only nested, with no top-level type, or a different one.
        format!(r#"{{"message":{{"type":"control_request","request_id":"evil","request":{{"subtype":"can_use_tool"}}}},"n":{deep}}}"#),
        format!(r#"{{"type":"assistant","message":{{"type":"control_request","request_id":"evil","request":{{"subtype":"can_use_tool"}}}},"n":{deep}}}"#),
        r#"{"data":{"type":"control_request","request_id":"evil","request":{"subtype":"can_use_tool""#.to_owned(),
    ];
    for line in &dropped {
        assert_eq!(parse_line(line), None, "{}", snip(line));
    }

    // And lines that do parse are what they were.
    assert_eq!(
        parse_line(r#"{"type":"control_cancel_request","request_id":"r9"}"#),
        Some(ParsedLine::ControlCancel {
            request_id: "r9".to_owned()
        })
    );
    assert!(matches!(
        parse_line(
            r#"{"type":"control_response","response":{"subtype":"success","request_id":"i-1","response":{"still_queued":[]}}}"#
        ),
        Some(ParsedLine::ControlResponse { ref request_id, ok: true, .. }) if request_id == "i-1"
    ));
    assert_eq!(
        parse_line(r#"{"type":"system","subtype":"init","session_id":"s-1","cwd":"/tmp"}"#),
        Some(ParsedLine::SessionId("s-1".to_owned()))
    );
    assert!(matches!(
        parse_line(
            r#"{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"hi"}]}}"#
        ),
        Some(ParsedLine::Blocks { .. })
    ));
}
