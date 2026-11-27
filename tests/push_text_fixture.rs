//! W16: the daemon's line extraction and the phone's line flattening agree.
//!
//! `tests/fixtures/push-detail/text_cases.json` lists inputs with what the daemon sends for each
//! (`first_line`) and what the phone shows for each (`NotificationContentComposer.flattened`, read by
//! `NotificationContentComposerTests`). Both sides read the same file, so a character one of them
//! learns to drop or to treat as a line break and the other does not fails a test on that side.

use nostromo::push::detail::first_line;
use serde_json::Value;

fn cases() -> Vec<Value> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/push-detail/text_cases.json");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    doc["cases"].as_array().unwrap().clone()
}

#[test]
fn first_line_gives_what_the_shared_fixture_says_for_every_input() {
    let cases = cases();
    assert!(cases.len() >= 30, "the fixture was read: {}", cases.len());
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let input = case["input"].as_str().unwrap();
        let expected = case["rust"].as_str().map(str::to_string);
        assert_eq!(first_line(input), expected, "{name}: {input:?}");
    }
}

#[test]
fn a_line_the_daemon_produced_is_a_fixed_point_of_first_line() {
    // Nothing is cut, dropped or split twice on the way (a line is stored once and served many times).
    for case in cases() {
        let Some(line) = case["rust"].as_str() else {
            continue;
        };
        let name = case["name"].as_str().unwrap();
        assert_eq!(
            first_line(line).as_deref(),
            Some(line),
            "{name}: idempotent"
        );
    }
}
