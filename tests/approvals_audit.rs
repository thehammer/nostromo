//! The approvals audit store (AP0g, design contract §7): append-only JSONL, one daily file per
//! UTC date, private to the user, safe for the daemon and the `nostromo-guard` hook process to
//! append to at the same time, and swept after 90 days.
//!
//! Nothing here touches process-wide env; the one subprocess gets its env through
//! `Command::env`. (`ApprovalsPaths::resolve` is in `tests/approvals_paths.rs`.)

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

use chrono::{DateTime, Duration, TimeZone, Utc};
use nostromo::approvals::audit::{
    sanitize_recorded, AuditFilter, AuditLog, Entry, Event, MAX_RECORDED_STRING_BYTES,
    RETENTION_DAYS,
};
use nostromo::data::work::is_invisible;
use serde_json::{json, Value};

fn at(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, mo, d, h, mi, s).unwrap()
}

fn blocked_event(command: &str) -> Event {
    Event::GuardBlocked {
        tool_name: "Bash".into(),
        input: json!({ "command": command, "description": "d" }),
        rule: "command".into(),
        detail: Some("ecs_connect".into()),
    }
}

fn blocked(ts: DateTime<Utc>, tag: Option<&str>) -> Entry {
    let mut e = Entry::new(blocked_event("ecs_connect ap production portal"), ts);
    e.tag = tag.map(String::from);
    e.session_id = Some("s-1".into());
    e.tool_use_id = Some("toolu_1".into());
    e
}

fn request(ts: DateTime<Utc>, tag: Option<&str>) -> Entry {
    let mut e = Entry::new(
        Event::Request {
            tool_name: "Bash".into(),
            input: json!({ "command": "ls" }),
            display_text: None,
            reason: None,
            flags: None,
            options: None,
            cli_request: None,
        },
        ts,
    );
    e.tag = tag.map(String::from);
    e
}

fn file_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn mode_of(p: &Path) -> u32 {
    std::fs::metadata(p).unwrap().permissions().mode() & 0o777
}

fn everything() -> std::ops::Range<DateTime<Utc>> {
    at(2000, 1, 1, 0, 0, 0)..at(2100, 1, 1, 0, 0, 0)
}

// ── layout and permissions ───────────────────────────────────────────────────────────────

#[test]
fn opening_the_store_creates_a_private_directory() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("nested").join("approvals");

    let log = AuditLog::open(&dir).expect("open creates the directory");

    assert!(dir.is_dir());
    assert_eq!(mode_of(&dir), 0o700);
    assert_eq!(log.dir(), dir);
    AuditLog::open(&dir).expect("opening an existing store is fine");
}

#[test]
fn an_entry_goes_to_the_daily_file_of_its_utc_date_with_mode_0600() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();

    let late = blocked(at(2026, 3, 4, 23, 59, 59), None);
    let early = blocked(at(2026, 3, 5, 0, 0, 0), None);
    log.append(&late).unwrap();
    log.append(&early).unwrap();

    assert_eq!(
        file_names(log.dir()),
        ["audit-2026-03-04.jsonl", "audit-2026-03-05.jsonl"]
    );
    assert_eq!(
        log.file_for(late.ts),
        log.dir().join("audit-2026-03-04.jsonl")
    );
    assert_eq!(
        log.file_for(early.ts),
        log.dir().join("audit-2026-03-05.jsonl")
    );
    for name in file_names(log.dir()) {
        assert_eq!(mode_of(&log.dir().join(&name)), 0o600, "{name}");
    }
}

#[test]
fn every_entry_is_one_line_and_earlier_lines_are_never_rewritten() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let path = log.file_for(at(2026, 3, 4, 12, 0, 0));

    log.append(&blocked(at(2026, 3, 4, 10, 0, 0), None))
        .unwrap();
    let after_one = std::fs::read_to_string(&path).unwrap();
    log.append(&blocked(at(2026, 3, 4, 11, 0, 0), None))
        .unwrap();
    log.append(&request(at(2026, 3, 4, 12, 0, 0), None))
        .unwrap();
    let after_three = std::fs::read_to_string(&path).unwrap();

    assert_eq!(after_one.lines().count(), 1);
    assert_eq!(after_three.lines().count(), 3);
    assert!(
        after_three.starts_with(&after_one),
        "the first line is untouched"
    );
    assert!(after_three.ends_with('\n'));
    for line in after_three.lines() {
        serde_json::from_str::<Entry>(line).expect("every line is an entry");
    }
}

// ── entry shape ──────────────────────────────────────────────────────────────────────────

#[test]
fn a_new_entry_is_v1_stamped_now_with_a_fresh_id_and_no_identity() {
    let now = at(2026, 3, 4, 10, 0, 0);

    let a = Entry::new(blocked_event("x"), now);
    let b = Entry::new(blocked_event("x"), now);

    assert_eq!(a.v, 1);
    assert_eq!(a.ts, now);
    assert!(!a.id.is_empty());
    assert_ne!(a.id, b.id);
    assert_eq!(
        (
            a.request_id,
            a.tag,
            a.session_id,
            a.tool_use_id,
            a.agent,
            a.subagent
        ),
        (None, None, None, None, None, None)
    );
}

#[test]
fn a_guard_blocked_entry_serializes_with_the_event_beside_the_common_fields() {
    let e = blocked(at(2026, 3, 4, 10, 0, 0), Some("focus-x"));

    let v: Value = serde_json::to_value(&e).unwrap();

    assert_eq!(v["v"], json!(1));
    assert_eq!(v["id"], json!(e.id));
    assert_eq!(v["event"], json!("guard_blocked"));
    assert_eq!(v["tool_name"], json!("Bash"));
    assert_eq!(
        v["input"],
        json!({ "command": "ecs_connect ap production portal", "description": "d" })
    );
    assert_eq!(v["rule"], json!("command"));
    assert_eq!(v["tag"], json!("focus-x"));
    assert_eq!(v["session_id"], json!("s-1"));
    assert_eq!(v["tool_use_id"], json!("toolu_1"));
    let ts = DateTime::parse_from_rfc3339(v["ts"].as_str().expect("ts is a string"))
        .expect("ts is RFC 3339");
    assert_eq!(ts.with_timezone(&Utc), e.ts);
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert!(
        !keys
            .iter()
            .any(|k| *k == "request_id" || *k == "agent" || *k == "subagent"),
        "absent fields are omitted: {keys:?}"
    );
}

fn every_event() -> Vec<(&'static str, Event)> {
    vec![
        (
            "request",
            Event::Request {
                tool_name: "Bash".into(),
                input: json!({ "command": "ls" }),
                display_text: Some("ls".into()),
                reason: Some(json!({ "kind": "x" })),
                flags: Some(json!(["a"])),
                options: Some(json!([{ "id": "once" }])),
                cli_request: Some(json!({ "subtype": "can_use_tool" })),
            },
        ),
        (
            "outcome",
            Event::Outcome {
                outcome: "allow_once".into(),
                rule: Some(json!({ "tool": "Bash" })),
                by_window: Some("w1".into()),
                latency_ms: Some(1234),
                watchdog: false,
            },
        ),
        (
            "refusal",
            Event::Refusal {
                refusal_code: "not_operator".into(),
                peer: Some(json!({ "trust": "local_other", "pid": 7 })),
                channel: None,
                control: None,
            },
        ),
        ("guard_blocked", blocked_event("ecs_connect")),
        (
            "session_rule_granted",
            Event::SessionRuleGranted {
                rule: json!({ "tool": "Bash" }),
            },
        ),
        (
            "session_rule_revoked",
            Event::SessionRuleRevoked {
                rule: json!({ "tool": "Bash" }),
            },
        ),
        (
            "rule_written",
            Event::RuleWritten {
                rule: json!({ "tool": "Bash" }),
            },
        ),
        (
            "rule_removed",
            Event::RuleRemoved {
                rule: json!({ "tool": "Bash" }),
            },
        ),
    ]
}

#[test]
fn every_event_kind_round_trips_through_json_under_its_snake_case_name() {
    for (name, event) in every_event() {
        assert_eq!(event.kind(), name);
        let entry = Entry::new(event, at(2026, 3, 4, 10, 0, 0));

        let json = serde_json::to_string(&entry).unwrap();
        let value: Value = serde_json::from_str(&json).unwrap();
        let back: Entry =
            serde_json::from_str(&json).unwrap_or_else(|e| panic!("{name}: {e}: {json}"));

        assert_eq!(value["event"], json!(name), "{json}");
        assert_eq!(back, entry, "{name}");
    }
}

#[test]
fn a_minimal_event_leaves_its_optional_fields_out() {
    let e = Entry::new(
        Event::Outcome {
            outcome: "deny".into(),
            rule: None,
            by_window: None,
            latency_ms: None,
            watchdog: false,
        },
        at(2026, 3, 4, 10, 0, 0),
    );

    let v: Value = serde_json::to_value(&e).unwrap();

    assert_eq!(v["event"], json!("outcome"));
    assert_eq!(v["outcome"], json!("deny"));
    assert!(
        v.get("by_window").is_none() && v.get("latency_ms").is_none(),
        "{v}"
    );
}

// ── reading ──────────────────────────────────────────────────────────────────────────────

#[test]
fn reading_returns_the_entries_in_a_half_open_time_range_oldest_first() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let t0 = at(2026, 3, 4, 23, 0, 0);
    let t1 = at(2026, 3, 5, 1, 0, 0); // the next UTC day
    let t2 = at(2026, 3, 5, 2, 0, 0);
    let t3 = at(2026, 3, 5, 3, 0, 0);
    // Appended out of order.
    for t in [t2, t0, t3, t1] {
        log.append(&blocked(t, None)).unwrap();
    }

    let all = log
        .read(t0..t3 + Duration::seconds(1), &AuditFilter::default())
        .unwrap();
    assert_eq!(
        all.iter().map(|e| e.ts).collect::<Vec<_>>(),
        [t0, t1, t2, t3],
        "oldest first, across files"
    );

    let half_open = log.read(t1..t3, &AuditFilter::default()).unwrap();
    assert_eq!(
        half_open.iter().map(|e| e.ts).collect::<Vec<_>>(),
        [t1, t2],
        "start is included, end is not"
    );

    assert!(
        log.read(t1..t1, &AuditFilter::default())
            .unwrap()
            .is_empty(),
        "an empty range is empty"
    );
    assert!(log
        .read(
            at(2027, 1, 1, 0, 0, 0)..at(2027, 2, 1, 0, 0, 0),
            &AuditFilter::default()
        )
        .unwrap()
        .is_empty());
}

#[test]
fn reading_can_be_filtered_by_focus_tag_and_by_event_kind() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let base = at(2026, 3, 4, 10, 0, 0);
    log.append(&blocked(base, Some("focus-x"))).unwrap();
    log.append(&blocked(base + Duration::minutes(1), Some("focus-y")))
        .unwrap();
    log.append(&request(base + Duration::minutes(2), Some("focus-x")))
        .unwrap();
    log.append(&request(base + Duration::minutes(3), None))
        .unwrap();

    let by_tag = log
        .read(
            everything(),
            &AuditFilter {
                tag: Some("focus-x".into()),
                event: None,
            },
        )
        .unwrap();
    assert_eq!(by_tag.len(), 2);
    assert!(by_tag.iter().all(|e| e.tag.as_deref() == Some("focus-x")));

    let by_kind = log
        .read(
            everything(),
            &AuditFilter {
                tag: None,
                event: Some("guard_blocked".into()),
            },
        )
        .unwrap();
    assert_eq!(by_kind.len(), 2);
    assert!(by_kind.iter().all(|e| e.event.kind() == "guard_blocked"));

    let both = log
        .read(
            everything(),
            &AuditFilter {
                tag: Some("focus-x".into()),
                event: Some("guard_blocked".into()),
            },
        )
        .unwrap();
    assert_eq!(both.len(), 1);
    assert_eq!(both[0].ts, base);

    assert_eq!(
        log.read(everything(), &AuditFilter::default())
            .unwrap()
            .len(),
        4,
        "an empty filter matches everything"
    );
}

#[test]
fn an_entry_read_back_is_the_entry_that_was_appended() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let mut entry = blocked(at(2026, 3, 4, 10, 0, 0), Some("focus-x"));
    entry.agent = Some("cody".into());
    entry.request_id = Some("req-1".into());
    log.append(&entry).unwrap();

    let back = log.read(everything(), &AuditFilter::default()).unwrap();

    assert_eq!(back, [entry]);
}

#[test]
fn a_damaged_line_is_skipped_and_does_not_hide_the_good_ones() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let first = blocked(at(2026, 3, 4, 10, 0, 0), None);
    let second = blocked(at(2026, 3, 4, 11, 0, 0), None);
    log.append(&first).unwrap();
    let path = log.file_for(first.ts);
    let mut text = std::fs::read_to_string(&path).unwrap();
    text.push_str("{ this line was cut off\n");
    std::fs::write(&path, text).unwrap();
    log.append(&second).unwrap();

    let back = log.read(everything(), &AuditFilter::default()).unwrap();

    assert_eq!(back, [first, second]);
}

#[test]
fn reading_an_empty_store_returns_nothing() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    assert!(log
        .read(everything(), &AuditFilter::default())
        .unwrap()
        .is_empty());
}

// ── concurrent appenders ─────────────────────────────────────────────────────────────────

#[test]
fn the_daemon_and_the_guard_hook_can_append_at_the_same_time_without_corrupting_a_line() {
    const EACH: usize = 40;
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("approvals");
    let log = AuditLog::open(&dir).unwrap();
    // Big enough entries (about 20 KB) that an interleaved write would show.
    let padding = "p".repeat(20_000);

    std::thread::scope(|s| {
        for who in ["t1", "t2"] {
            let log = log.clone();
            let padding = padding.clone();
            s.spawn(move || {
                for i in 0..EACH {
                    let mut e = Entry::new(
                        Event::GuardBlocked {
                            tool_name: "Bash".into(),
                            input: json!({ "command": format!("{who}-{i}"), "pad": padding }),
                            rule: "command".into(),
                            detail: None,
                        },
                        Utc::now(),
                    );
                    e.tag = Some(who.into());
                    log.append(&e).expect("append");
                }
            });
        }
        s.spawn(|| {
            let mut cmd = Command::new(env!("CARGO_BIN_EXE_nostromo-guard"));
            cmd.arg("pre-tool-use")
                .env("NOSTROMO_APPROVALS_DIR", &dir)
                .env("HOME", root.path())
                .env("TMUX_TMPDIR", root.path())
                .env("NOSTROMO_FOCUS_TAG", "from-guard")
                .env_remove("TMUX")
                .env_remove("TMUX_PANE")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let mut child = cmd.spawn().unwrap();
            {
                use std::io::Write;
                let mut stdin = child.stdin.take().unwrap();
                stdin
                    .write_all(br#"{"session_id":"s","tool_use_id":"t","tool_name":"Bash","tool_input":{"command":"ecs_connect ap production portal"}}"#)
                    .unwrap();
            }
            let out = child.wait_with_output().unwrap();
            assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
        });
    });

    let mut lines = 0;
    let mut ids = std::collections::HashSet::new();
    for name in file_names(&dir) {
        assert!(
            name.starts_with("audit-") && name.ends_with(".jsonl"),
            "{name}"
        );
        for line in std::fs::read_to_string(dir.join(&name)).unwrap().lines() {
            let e: Entry = serde_json::from_str(line).unwrap_or_else(|err| {
                panic!("a corrupted line ({err}): {}", &line[..line.len().min(120)])
            });
            ids.insert(e.id);
            lines += 1;
        }
    }
    assert_eq!(lines, 2 * EACH + 1, "no entry lost or merged");
    assert_eq!(ids.len(), lines, "every entry kept its own id");
    let from_guard = log
        .read(
            everything(),
            &AuditFilter {
                tag: Some("from-guard".into()),
                event: None,
            },
        )
        .unwrap();
    assert_eq!(from_guard.len(), 1);
}

// ── retention ────────────────────────────────────────────────────────────────────────────

#[test]
fn sweeping_deletes_exactly_the_daily_files_dated_more_than_ninety_days_before_now() {
    assert_eq!(RETENTION_DAYS, 90);
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let now = at(2026, 10, 15, 12, 0, 0);
    for days in [0, 89, 90, 91, 200] {
        log.append(&blocked(now - Duration::days(days), None))
            .unwrap();
    }
    let unrelated = log.dir().join("notes.txt");
    std::fs::write(&unrelated, "keep me").unwrap();
    let name_of = |days: i64| {
        format!(
            "audit-{}.jsonl",
            (now - Duration::days(days)).format("%Y-%m-%d")
        )
    };
    assert_eq!(file_names(log.dir()).len(), 6);

    let deleted = log.sweep(now).unwrap();

    assert_eq!(deleted, 2);
    let mut expected = vec![
        name_of(0),
        name_of(89),
        name_of(90),
        "notes.txt".to_string(),
    ];
    expected.sort();
    assert_eq!(
        file_names(log.dir()),
        expected,
        "91 and 200 days old are gone; 90 days old is kept"
    );
    assert_eq!(std::fs::read_to_string(&unrelated).unwrap(), "keep me");
    assert_eq!(log.sweep(now).unwrap(), 0, "nothing more to delete");
    assert_eq!(
        log.read(everything(), &AuditFilter::default())
            .unwrap()
            .len(),
        3,
        "recent entries are intact"
    );
}

#[test]
fn sweeping_an_empty_store_deletes_nothing() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    assert_eq!(log.sweep(at(2026, 10, 15, 12, 0, 0)).unwrap(), 0);
}

// ── what a blocked tool input looks like once recorded ───────────────────────────────────
//
// The `nostromo-guard` binary records `sanitize_recorded(tool_input)`: whoever reads the log (a
// terminal, a review UI) must not be steered by hidden characters or flooded by a huge string.

/// The string that `sanitize_recorded` returns for `s`, wrapped as a top-level JSON string.
fn sanitized(s: &str) -> String {
    match sanitize_recorded(&json!(s)) {
        Value::String(out) => out,
        other => panic!("a string must stay a string, got {other:?}"),
    }
}

#[test]
fn bypass_invisible_and_bidi_characters_are_shown_as_their_code_point() {
    for (c, shown) in [
        ('\u{202E}', "\u{27E8}U+202E\u{27E9}"),
        ('\u{200B}', "\u{27E8}U+200B\u{27E9}"),
        ('\u{2066}', "\u{27E8}U+2066\u{27E9}"),
        ('\u{FEFF}', "\u{27E8}U+FEFF\u{27E9}"),
        ('\u{0007}', "\u{27E8}U+0007\u{27E9}"),
        ('\u{E0041}', "\u{27E8}U+E0041\u{27E9}"),
    ] {
        assert_eq!(
            sanitized(&format!("ecs{c}_connect")),
            format!("ecs{shown}_connect"),
            "U+{:04X}",
            c as u32
        );
    }
    assert_eq!(
        sanitized("a\u{202E}b\u{202E}c"),
        "a\u{27E8}U+202E\u{27E9}b\u{27E8}U+202E\u{27E9}c",
        "every occurrence"
    );
}

#[test]
fn bypass_no_invisible_character_survives_sanitizing() {
    // Every code point `is_invisible` knows (newline, tab and carriage return are left to the
    // implementation: a multi-line command is legitimate).
    let hidden: Vec<char> = (0..=0x10FFFFu32)
        .filter_map(char::from_u32)
        .filter(|c| is_invisible(*c) && !matches!(c, '\n' | '\t' | '\r'))
        .collect();
    assert!(
        hidden.len() > 100,
        "the predicate covers many code points: {}",
        hidden.len()
    );
    // The predicate now covers several thousand code points (the whole tag block up to U+E0FFF), more than
    // one recorded string can hold: check them in chunks, each one under the cap. Every code point is still
    // checked, through the same sanitizer.
    for chunk in hidden.chunks(1000) {
        let input: String = chunk.iter().map(|c| format!("[{c}]")).collect();
        let expected: String = chunk
            .iter()
            .map(|c| format!("[\u{27E8}U+{:04X}\u{27E9}]", *c as u32))
            .collect();

        assert!(
            input.len() < MAX_RECORDED_STRING_BYTES && expected.len() < MAX_RECORDED_STRING_BYTES,
            "the cap is not in play here"
        );

        let out = sanitized(&input);

        assert_eq!(out, expected);
    }
}

#[test]
fn sanitizing_reaches_every_string_in_nested_objects_and_arrays_and_leaves_the_rest_alone() {
    let input = json!({
        "command": "ls\u{202E}",
        "nested": { "list": ["a\u{200B}b", 5, null, true, 1.5, ["deep\u{2066}"], { "k": "v\u{202E}" }] },
        "number": 7,
        "flag": false,
        "nothing": null,
        "empty": "",
    });

    let out = sanitize_recorded(&input);

    assert_eq!(
        out,
        json!({
            "command": "ls\u{27E8}U+202E\u{27E9}",
            "nested": { "list": ["a\u{27E8}U+200B\u{27E9}b", 5, null, true, 1.5, ["deep\u{27E8}U+2066\u{27E9}"], { "k": "v\u{27E8}U+202E\u{27E9}" }] },
            "number": 7,
            "flag": false,
            "nothing": null,
            "empty": "",
        })
    );
}

#[test]
fn ordinary_strings_and_values_are_recorded_unchanged() {
    let input = json!({
        "command": "git commit -m \"fix: h\u{e9}llo \u{2713} \u{65e5}\u{672c}\u{8a9e} \u{1F680}\" && echo 'a\\b' $HOME",
        "description": "plain text, with: punctuation (and) {braces} [brackets] <angles>",
        "n": [1, 2, 3],
    });
    assert_eq!(sanitize_recorded(&input), input);
    assert_eq!(sanitize_recorded(&json!({})), json!({}));
    assert_eq!(sanitize_recorded(&json!(null)), json!(null));
}

#[test]
fn a_string_of_exactly_the_cap_is_unchanged_and_one_byte_more_is_cut_with_a_note() {
    let at_cap = "a".repeat(MAX_RECORDED_STRING_BYTES);
    assert_eq!(sanitized(&at_cap), at_cap);

    let over = "a".repeat(MAX_RECORDED_STRING_BYTES + 1);
    let out = sanitized(&over);
    assert_ne!(out, over);
    let note_at = out
        .find("\u{2026}[truncated")
        .expect("a note starting `\u{2026}[truncated`");
    assert!(out[..note_at].chars().all(|c| c == 'a'));
    assert!(
        note_at <= MAX_RECORDED_STRING_BYTES,
        "at most the cap is kept: {note_at}"
    );
    assert!(
        note_at > MAX_RECORDED_STRING_BYTES / 2,
        "the text is kept, not just a note: {note_at}"
    );
    assert!(
        out.len() <= MAX_RECORDED_STRING_BYTES + 64,
        "the note is short: {} bytes",
        out.len()
    );
}

#[test]
fn a_long_string_deep_in_the_value_is_cut_too() {
    let long = "z".repeat(5 * MAX_RECORDED_STRING_BYTES);
    let out = sanitize_recorded(&json!({ "a": [{ "b": long }], "short": "ok" }));
    let cut = out["a"][0]["b"].as_str().unwrap();
    assert!(cut.len() <= MAX_RECORDED_STRING_BYTES + 64, "{}", cut.len());
    assert!(cut.contains("\u{2026}[truncated"));
    assert_eq!(out["short"], json!("ok"));
}

#[test]
fn cutting_never_splits_a_multibyte_character() {
    // 3-byte and 4-byte characters, with the cap landing inside one of them.
    for c in ['\u{65e5}', '\u{1F680}', '\u{e9}'] {
        for lead in 0..4 {
            let text = format!(
                "{}{}",
                "a".repeat(lead),
                c.to_string().repeat(MAX_RECORDED_STRING_BYTES)
            );
            let out = sanitized(&text);
            let note_at = out
                .find("\u{2026}[truncated")
                .unwrap_or_else(|| panic!("{c:?}+{lead}: no note"));
            let kept = &out[..note_at];
            assert!(
                kept.len() <= MAX_RECORDED_STRING_BYTES,
                "{c:?}+{lead}: {} bytes kept",
                kept.len()
            );
            assert!(kept.len() > MAX_RECORDED_STRING_BYTES / 2, "{c:?}+{lead}");
            assert!(
                kept.chars().skip(lead).all(|k| k == c),
                "{c:?}+{lead}: whole characters only"
            );
            assert!(out.len() <= MAX_RECORDED_STRING_BYTES + 64, "{c:?}+{lead}");
        }
    }
}

#[test]
fn a_long_run_of_hidden_characters_is_shown_and_cut_not_passed_through() {
    // Each one becomes a 12-byte marker, so this is far over the cap once shown.
    let out = sanitized(&"\u{202E}".repeat(MAX_RECORDED_STRING_BYTES));
    assert!(!out.contains('\u{202E}'), "no raw U+202E survives");
    assert!(out.contains("\u{27E8}U+202E\u{27E9}"));
    assert!(
        out.len() <= MAX_RECORDED_STRING_BYTES + 64,
        "{} bytes",
        out.len()
    );
    assert!(out.contains("\u{2026}[truncated"));
}

// ── the daily file is never a way to write somewhere else ────────────────────────────────

#[test]
fn bypass_appending_through_a_symlinked_daily_file_fails_and_leaves_the_target_alone() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("approvals")).unwrap();
    let entry = blocked(at(2026, 10, 16, 12, 0, 0), None);

    // The file exists: a link to something the user owns and cares about.
    let victim = root.path().join("victim.txt");
    std::fs::write(&victim, "keep me\n").unwrap();
    std::os::unix::fs::symlink(&victim, log.file_for(entry.ts)).unwrap();
    assert!(
        log.append(&entry).is_err(),
        "appending through a symlink must fail"
    );
    assert_eq!(
        std::fs::read_to_string(&victim).unwrap(),
        "keep me\n",
        "the target is untouched"
    );

    // The link dangles: the target must not be created through it either.
    let entry = blocked(at(2026, 10, 17, 12, 0, 0), None);
    let missing = root.path().join("not-created.txt");
    std::os::unix::fs::symlink(&missing, log.file_for(entry.ts)).unwrap();
    assert!(
        log.append(&entry).is_err(),
        "a dangling symlink is refused too"
    );
    assert!(!missing.exists(), "nothing was created through the link");

    // Other days are unaffected.
    log.append(&blocked(at(2026, 10, 18, 12, 0, 0), None))
        .expect("a normal file still works");
}

// ── AP5: the read-only query layer ──────────────────────────────────────────────────────────

mod query {
    use super::*;
    use nostromo::approvals::audit::{LogQuery, OutcomeFilter, RowKind};

    fn store() -> (tempfile::TempDir, AuditLog) {
        let dir = tempfile::tempdir().unwrap();
        let log = AuditLog::open(&dir.path().join("a")).unwrap();
        (dir, log)
    }

    fn req(ts: DateTime<Utc>, rid: &str, tag: &str, command: &str) -> Entry {
        let mut e = Entry::new(
            Event::Request {
                tool_name: "Bash".into(),
                input: json!({ "command": command }),
                display_text: None,
                reason: Some(json!({"kind": "ask"})),
                flags: None,
                options: None,
                cli_request: None,
            },
            ts,
        );
        e.request_id = Some(rid.into());
        e.tag = Some(tag.into());
        e.tool_use_id = Some(format!("toolu_{rid}"));
        e.agent = Some("main".into());
        e
    }

    fn outcome(ts: DateTime<Utc>, rid: Option<&str>, name: &str) -> Entry {
        let mut e = Entry::new(
            Event::Outcome {
                outcome: name.into(),
                rule: None,
                by_window: Some("w1".into()),
                latency_ms: Some(1234),
                watchdog: false,
            },
            ts,
        );
        e.request_id = rid.map(String::from);
        e
    }

    fn q(limit: usize) -> LogQuery {
        LogQuery {
            limit,
            ..Default::default()
        }
    }

    #[allow(non_snake_case)]
    fn NOW() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 7, 12, 0, 0).unwrap()
    }

    #[test]
    fn a_request_and_its_outcome_are_one_row_newest_first() {
        let (_d, log) = store();
        log.append(&req(at(2026, 11, 7, 10, 0, 0), "r1", "A", "ls"))
            .unwrap();
        log.append(&outcome(
            at(2026, 11, 7, 10, 0, 5),
            Some("r1"),
            "allowed_once",
        ))
        .unwrap();
        log.append(&req(at(2026, 11, 7, 11, 0, 0), "r2", "B", "rm x"))
            .unwrap();
        log.append(&outcome(at(2026, 11, 7, 11, 0, 5), Some("r2"), "denied"))
            .unwrap();
        let page = log.query(&q(50), NOW()).unwrap();
        assert_eq!(page.rows.len(), 2);
        assert_eq!(page.rows[0].request_id.as_deref(), Some("r2"));
        assert_eq!(page.rows[0].outcome.as_deref(), Some("denied"));
        assert_eq!(page.rows[0].summary, "rm x");
        assert_eq!(page.rows[0].latency_ms, Some(1234));
        assert_eq!(page.rows[0].by_window.as_deref(), Some("w1"));
        assert_eq!(page.rows[0].entry_ids.len(), 2);
        assert_eq!(page.rows[1].outcome.as_deref(), Some("allowed_once"));
        assert_eq!(page.rows[1].tool_use_id.as_deref(), Some("toolu_r1"));
        assert!(page.next_cursor.is_none());
    }

    #[test]
    fn a_request_with_no_outcome_yet_is_a_row_without_one() {
        let (_d, log) = store();
        log.append(&req(at(2026, 11, 7, 10, 0, 0), "r1", "A", "ls"))
            .unwrap();
        let page = log.query(&q(50), NOW()).unwrap();
        assert_eq!(page.rows.len(), 1);
        assert_eq!(page.rows[0].outcome, None);
    }

    #[test]
    fn the_merge_works_across_a_utc_day_boundary() {
        let (_d, log) = store();
        log.append(&req(at(2026, 11, 6, 23, 59, 50), "r1", "A", "ls"))
            .unwrap();
        log.append(&outcome(
            at(2026, 11, 7, 0, 0, 20),
            Some("r1"),
            "allowed_once",
        ))
        .unwrap();
        for limit in [1, 2, 50] {
            let page = log.query(&q(limit), NOW()).unwrap();
            assert_eq!(page.rows.len(), 1, "limit {limit}");
            assert_eq!(page.rows[0].outcome.as_deref(), Some("allowed_once"));
            assert_eq!(page.rows[0].ts, at(2026, 11, 6, 23, 59, 50));
        }
        log.append(&req(at(2026, 11, 7, 5, 0, 0), "r2", "A", "pwd"))
            .unwrap();
        let page = log.query(&q(1), NOW()).unwrap();
        assert_eq!(page.rows[0].request_id.as_deref(), Some("r2"));
        let page2 = log
            .query(
                &LogQuery {
                    limit: 5,
                    cursor: page.next_cursor,
                    ..Default::default()
                },
                NOW(),
            )
            .unwrap();
        assert_eq!(page2.rows.len(), 1);
        assert_eq!(page2.rows[0].request_id.as_deref(), Some("r1"));
        assert_eq!(page2.rows[0].outcome.as_deref(), Some("allowed_once"));
    }

    #[test]
    fn an_outcome_with_no_request_is_its_own_row() {
        let (_d, log) = store();
        log.append(&outcome(
            at(2026, 11, 7, 9, 0, 0),
            Some("gone"),
            "restart_crash",
        ))
        .unwrap();
        log.append(&outcome(
            at(2026, 11, 7, 9, 1, 0),
            None,
            "request_unparseable",
        ))
        .unwrap();
        let page = log.query(&q(50), NOW()).unwrap();
        assert_eq!(page.rows.len(), 2);
        assert_eq!(page.rows[0].outcome.as_deref(), Some("request_unparseable"));
        assert_eq!(page.rows[1].outcome.as_deref(), Some("restart_crash"));
        assert!(page.rows.iter().all(|r| r.kind == RowKind::Request));
    }

    #[test]
    fn every_other_entry_kind_is_a_row_including_an_unknown_one() {
        let (_d, log) = store();
        log.append(&blocked(at(2026, 11, 7, 8, 0, 0), Some("A")))
            .unwrap();
        let mut refusal = Entry::new(
            Event::Refusal {
                refusal_code: "not_operator_app".into(),
                peer: Some(json!({"kind": "local_other"})),
                channel: Some("app_control".into()),
                control: Some("allow".into()),
            },
            at(2026, 11, 7, 8, 1, 0),
        );
        refusal.tag = Some("A".into());
        log.append(&refusal).unwrap();
        log.append(&Entry::new(
            Event::SessionRuleGranted {
                rule: json!({"rule_text": "Bash(ls:*)"}),
            },
            at(2026, 11, 7, 8, 2, 0),
        ))
        .unwrap();
        log.append(&Entry::new(
            Event::RuleWritten {
                rule: json!({"rule_text": "Bash(pwd)"}),
            },
            at(2026, 11, 7, 8, 3, 0),
        ))
        .unwrap();
        let line = json!({"v": 1, "id": "u-1", "ts": "2026-11-07T08:04:00Z",
            "event": "from_the_future", "tag": "A"});
        let path = log.file_for(at(2026, 11, 7, 0, 0, 0));
        let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
        use std::io::Write;
        writeln!(f, "{line}").unwrap();

        let page = log.query(&q(50), NOW()).unwrap();
        let kinds: Vec<_> = page.rows.iter().map(|r| r.kind).collect();
        assert_eq!(
            kinds,
            [
                RowKind::Other,
                RowKind::Rule,
                RowKind::Rule,
                RowKind::Refusal,
                RowKind::GuardBlocked
            ]
        );
        assert_eq!(page.rows[0].summary, "from_the_future");
        assert_eq!(page.rows[2].rule_label.as_deref(), Some("Bash(ls:*)"));
        assert_eq!(
            page.rows[3].refusal_code.as_deref(),
            Some("not_operator_app")
        );
        assert_eq!(page.rows[4].outcome.as_deref(), Some("guard_blocked"));
        assert_eq!(page.rows[4].tool_name.as_deref(), Some("Bash"));
    }

    #[test]
    fn filters_by_focus_outcome_group_and_since() {
        let (_d, log) = store();
        let cases = [
            ("r1", "A", "allowed_once", 1),
            ("r2", "A", "allowed_by_session_rule", 2),
            ("r3", "B", "denied", 3),
            ("r4", "B", "denied_and_stopped", 4),
            ("r5", "A", "timed_out", 5),
            ("r6", "A", "no_app", 6),
            ("r7", "A", "answered", 7),
        ];
        for (rid, tag, name, h) in cases {
            log.append(&req(at(2026, 11, 7, h, 0, 0), rid, tag, "x"))
                .unwrap();
            log.append(&outcome(at(2026, 11, 7, h, 0, 9), Some(rid), name))
                .unwrap();
        }
        log.append(&blocked(at(2026, 11, 7, 8, 0, 0), Some("A")))
            .unwrap();
        let ids = |f: LogQuery| -> Vec<String> {
            log.query(&f, NOW())
                .unwrap()
                .rows
                .into_iter()
                .map(|r| r.request_id.unwrap_or(r.row_id))
                .collect()
        };
        let base = || q(50);
        assert_eq!(
            ids(LogQuery {
                tag: Some("B".into()),
                ..base()
            }),
            ["r4", "r3"]
        );
        assert_eq!(
            ids(LogQuery {
                outcome: Some(OutcomeFilter::Allowed),
                ..base()
            }),
            ["r7", "r2", "r1"]
        );
        assert_eq!(
            ids(LogQuery {
                outcome: Some(OutcomeFilter::Denied),
                ..base()
            }),
            ["r4", "r3"]
        );
        assert_eq!(
            ids(LogQuery {
                outcome: Some(OutcomeFilter::TimedOut),
                ..base()
            }),
            ["r6", "r5"]
        );
        assert_eq!(
            log.query(
                &LogQuery {
                    outcome: Some(OutcomeFilter::GuardBlocked),
                    ..base()
                },
                NOW()
            )
            .unwrap()
            .rows
            .len(),
            1
        );
        assert_eq!(
            ids(LogQuery {
                since: Some(at(2026, 11, 7, 6, 0, 0)),
                ..base()
            })
            .len(),
            3
        );
    }

    #[test]
    fn paging_has_no_duplicates_or_gaps_across_pages() {
        let (_d, log) = store();
        for i in 0..25u32 {
            let day = 5 + i / 10;
            let ts = at(2026, 11, day, i % 10, 0, 0);
            log.append(&req(ts, &format!("r{i:02}"), "A", "x")).unwrap();
            log.append(&outcome(
                ts + Duration::seconds(3),
                Some(&format!("r{i:02}")),
                "denied",
            ))
            .unwrap();
        }
        let mut seen = Vec::new();
        let mut cursor = None;
        let mut pages = 0;
        loop {
            let page = log
                .query(
                    &LogQuery {
                        limit: 10,
                        cursor: cursor.clone(),
                        ..Default::default()
                    },
                    NOW(),
                )
                .unwrap();
            pages += 1;
            assert!(page
                .rows
                .iter()
                .all(|r| r.outcome.as_deref() == Some("denied")));
            seen.extend(page.rows.iter().map(|r| r.request_id.clone().unwrap()));
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        assert_eq!(pages, 3);
        let mut expect: Vec<String> = (0..25).map(|i| format!("r{i:02}")).collect();
        expect.sort_by_key(|r| {
            let i: u32 = r[1..].parse().unwrap();
            std::cmp::Reverse((i / 10, i % 10))
        });
        assert_eq!(seen, expect);
    }

    #[test]
    fn limit_is_clamped_and_a_garbage_cursor_is_an_error_not_a_panic() {
        let (_d, log) = store();
        for i in 0..520u32 {
            log.append(&blocked(
                at(2026, 11, 7, 0, 0, 0) + Duration::seconds(i as i64),
                None,
            ))
            .unwrap();
        }
        assert_eq!(log.query(&q(10_000), NOW()).unwrap().rows.len(), 500);
        assert_eq!(log.query(&q(0), NOW()).unwrap().rows.len(), 1);
        for bad in ["", "!!!", "bm90LWEtY3Vyc29y", "Zm9vOmJhcg"] {
            let r = log.query(
                &LogQuery {
                    limit: 5,
                    cursor: Some(bad.into()),
                    ..Default::default()
                },
                NOW(),
            );
            assert!(r.is_err(), "cursor {bad:?}");
        }
    }

    #[test]
    fn old_entries_leave_the_query_after_a_sweep_and_a_reopened_store_returns_the_same_rows() {
        let (d, log) = store();
        let old = NOW() - Duration::days(RETENTION_DAYS + 5);
        log.append(&blocked(old, None)).unwrap();
        log.append(&blocked(NOW() - Duration::hours(1), None))
            .unwrap();
        assert_eq!(log.sweep(NOW()).unwrap(), 1);
        let page = log.query(&q(50), NOW()).unwrap();
        assert_eq!(page.rows.len(), 1);
        let again = AuditLog::open(&d.path().join("a"))
            .unwrap()
            .query(&q(50), NOW())
            .unwrap();
        assert_eq!(again.rows, page.rows);
    }

    #[test]
    fn entry_detail_returns_the_full_input_by_request_id_or_entry_id() {
        let (_d, log) = store();
        let big = "x".repeat(5000);
        let r = req(at(2026, 11, 7, 10, 0, 0), "r1", "A", &big);
        let entry_id = r.id.clone();
        log.append(&r).unwrap();
        log.append(&outcome(
            at(2026, 11, 7, 10, 0, 3),
            Some("r1"),
            "allowed_once",
        ))
        .unwrap();
        for id in ["r1", entry_id.as_str()] {
            let d = log.entry_detail(id, NOW()).unwrap().unwrap();
            assert_eq!(d.input.unwrap()["command"], json!(big));
            assert_eq!(d.reason, Some(json!({"kind": "ask"})));
        }
        let d = log.entry_detail("r1", NOW()).unwrap().unwrap();
        assert_eq!(d.outcome.as_deref(), Some("allowed_once"));
        assert!(log.entry_detail("nope", NOW()).unwrap().is_none());
    }

    // ── a query scans a big day without holding it ────────────────────────────────────────

    /// One expected row: its id, its time, and the outcome it should show.
    struct Expected {
        row_id: String,
        ts_ms: i64,
        outcome: Option<&'static str>,
    }

    /// `groups` groups of five rows written straight to the day's file (an append syncs every
    /// entry, too slow for tens of thousands): three requests answered 300 ms later, one guard
    /// block, one request still waiting. Eight entries per group. Returns the rows a query
    /// should show, newest first.
    fn write_day(log: &AuditLog, day: DateTime<Utc>, groups: u32) -> Vec<Expected> {
        use std::io::Write;
        let mut out = std::io::BufWriter::new(std::fs::File::create(log.file_for(day)).unwrap());
        let mut expected = Vec::new();
        let mut put = |e: &Entry| {
            serde_json::to_writer(&mut out, e).unwrap();
            out.write_all(b"\n").unwrap();
        };
        for g in 0..groups {
            for k in 0..5u32 {
                let u = g * 5 + k;
                let ts = day + Duration::seconds(u as i64);
                let rid = format!("r{u}");
                match k {
                    0..=2 => {
                        put(&req(ts, &rid, "A", "ls"));
                        put(&outcome(
                            ts + Duration::milliseconds(300),
                            Some(&rid),
                            "denied",
                        ));
                        expected.push(Expected {
                            row_id: rid,
                            ts_ms: ts.timestamp_millis(),
                            outcome: Some("denied"),
                        });
                    }
                    3 => {
                        let b = blocked(ts, Some("A"));
                        expected.push(Expected {
                            row_id: b.id.clone(),
                            ts_ms: ts.timestamp_millis(),
                            outcome: Some("guard_blocked"),
                        });
                        put(&b);
                    }
                    _ => {
                        put(&req(ts, &rid, "A", "ls"));
                        expected.push(Expected {
                            row_id: rid,
                            ts_ms: ts.timestamp_millis(),
                            outcome: None,
                        });
                    }
                }
            }
        }
        out.flush().unwrap();
        expected.sort_by_key(|e| std::cmp::Reverse(e.ts_ms));
        expected
    }

    /// What a scan for a page of `limit` rows may hold at once: twice what it keeps, plus the
    /// row that tips it over.
    fn held_bound(limit: usize) -> usize {
        2 * (limit + 1) + 1
    }

    fn assert_page_is(page: &nostromo::approvals::audit::LogPage, expected: &[Expected]) {
        let got: Vec<(&str, Option<&str>)> = page
            .rows
            .iter()
            .map(|r| (r.row_id.as_str(), r.outcome.as_deref()))
            .collect();
        let want: Vec<(&str, Option<&str>)> = expected
            .iter()
            .map(|e| (e.row_id.as_str(), e.outcome))
            .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn a_page_of_a_fifty_thousand_entry_day_is_read_holding_a_bounded_number_of_rows() {
        let (_d, log) = store();
        let day = at(2026, 11, 7, 0, 0, 0);
        let expected = write_day(&log, day, 6_250); // 50,000 entries, 31,250 rows
        assert_eq!(expected.len(), 31_250);

        let (first, stats) = log.query_with_stats(&q(50), NOW()).unwrap();
        assert_page_is(&first, &expected[..50]);
        assert!(first.next_cursor.is_some());
        assert!(
            stats.peak_rows_held <= held_bound(50),
            "held {} rows at once",
            stats.peak_rows_held
        );

        // A page deep in the day, reached by cursor, is just as small and just as right.
        let (second, stats) = log
            .query_with_stats(
                &LogQuery {
                    limit: 50,
                    cursor: first.next_cursor.clone(),
                    ..Default::default()
                },
                NOW(),
            )
            .unwrap();
        assert_page_is(&second, &expected[50..100]);
        assert!(
            stats.peak_rows_held <= held_bound(50),
            "held {} rows at once",
            stats.peak_rows_held
        );

        // A filter that drops most rows does not make the scan hold more.
        let denied: Vec<&Expected> = expected
            .iter()
            .filter(|e| e.outcome == Some("denied"))
            .collect();
        let (filtered, stats) = log
            .query_with_stats(
                &LogQuery {
                    limit: 50,
                    outcome: Some(OutcomeFilter::Denied),
                    ..Default::default()
                },
                NOW(),
            )
            .unwrap();
        let got: Vec<&str> = filtered.rows.iter().map(|r| r.row_id.as_str()).collect();
        let want: Vec<&str> = denied[..50].iter().map(|e| e.row_id.as_str()).collect();
        assert_eq!(got, want);
        assert!(
            stats.peak_rows_held <= held_bound(50),
            "held {} rows at once",
            stats.peak_rows_held
        );

        // The bound follows the page size, not the size of the day.
        let (big, stats) = log.query_with_stats(&q(500), NOW()).unwrap();
        assert_page_is(&big, &expected[..500]);
        assert!(
            stats.peak_rows_held <= held_bound(500),
            "held {} rows at once",
            stats.peak_rows_held
        );
    }

    #[test]
    fn paging_a_whole_busy_day_newest_first_has_no_gap_no_repeat_and_no_row_out_of_order() {
        let (_d, log) = store();
        let expected = write_day(&log, at(2026, 11, 7, 0, 0, 0), 250); // 2,000 entries, 1,250 rows
        assert_eq!(expected.len(), 1_250);

        let mut seen: Vec<(String, Option<String>)> = Vec::new();
        let mut cursor = None;
        let mut pages = 0;
        loop {
            let (page, stats) = log
                .query_with_stats(
                    &LogQuery {
                        limit: 50,
                        cursor: cursor.clone(),
                        ..Default::default()
                    },
                    NOW(),
                )
                .unwrap();
            pages += 1;
            assert!(page.rows.len() <= 50);
            assert!(
                stats.peak_rows_held <= held_bound(50),
                "page {pages} held {} rows at once",
                stats.peak_rows_held
            );
            seen.extend(
                page.rows
                    .iter()
                    .map(|r| (r.row_id.clone(), r.outcome.clone())),
            );
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
            assert!(pages < 100, "paging does not end");
        }
        assert_eq!(pages, 25);
        let want: Vec<(String, Option<String>)> = expected
            .iter()
            .map(|e| (e.row_id.clone(), e.outcome.map(String::from)))
            .collect();
        assert_eq!(
            seen, want,
            "every row once, newest first, each with its outcome"
        );
    }

    #[test]
    fn entry_detail_with_a_row_time_reads_only_the_days_around_it() {
        let (_d, log) = store();
        let old = req(at(2026, 11, 1, 10, 0, 0), "r-old", "A", "echo old");
        let old_entry_id = old.id.clone();
        log.append(&old).unwrap();
        log.append(&outcome(
            at(2026, 11, 1, 10, 0, 3),
            Some("r-old"),
            "allowed_once",
        ))
        .unwrap();
        log.append(&req(at(2026, 11, 7, 10, 0, 0), "r-new", "A", "echo new"))
            .unwrap();
        let found = |id: &str, near: Option<DateTime<Utc>>| {
            log.entry_detail_near(id, near, NOW()).unwrap().is_some()
        };

        // No hint: every day within retention is searched, as `entry_detail` does.
        assert!(found("r-old", None));
        assert!(log.entry_detail("r-old", NOW()).unwrap().is_some());
        // The row's own day, or a day beside it, finds it, by request id or by entry id.
        assert!(found("r-old", Some(at(2026, 11, 1, 23, 59, 0))));
        assert!(found(&old_entry_id, Some(at(2026, 11, 1, 10, 0, 0))));
        assert!(found("r-old", Some(at(2026, 11, 2, 0, 30, 0))));
        assert!(found("r-old", Some(at(2026, 10, 31, 12, 0, 0))));
        // A hint more than a day away does not reach it.
        assert!(!found("r-old", Some(at(2026, 11, 7, 10, 0, 0))));
        assert!(!found(&old_entry_id, Some(at(2026, 11, 7, 10, 0, 0))));
        assert!(!found("r-old", Some(at(2026, 11, 3, 10, 0, 0))));
        // The detail it finds is the whole entry, with its outcome.
        let d = log
            .entry_detail_near("r-old", Some(at(2026, 11, 1, 10, 0, 0)), NOW())
            .unwrap()
            .unwrap();
        assert_eq!(d.outcome.as_deref(), Some("allowed_once"));
        // The newer entry is found from its own day and not from the older one.
        assert!(found("r-new", Some(at(2026, 11, 7, 11, 0, 0))));
        assert!(!found("r-new", Some(at(2026, 11, 1, 10, 0, 0))));
        // An id nothing has is none, with a hint and without.
        assert!(!found("nope", None));
        assert!(!found("nope", Some(at(2026, 11, 7, 10, 0, 0))));
    }

    #[test]
    fn the_query_layer_has_no_way_to_edit_or_delete_an_entry() {
        let src = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/approvals/audit.rs"
        ))
        .unwrap();
        let mut kept = String::new();
        let mut skipping = false;
        for line in src.lines() {
            if line.starts_with("    pub fn sweep") || line.starts_with("    pub fn append") {
                skipping = true;
            } else if skipping && line == "    }" {
                skipping = false;
                continue;
            }
            if !skipping && !line.trim_start().starts_with("//") {
                kept.push_str(line);
                kept.push('\n');
            }
        }
        for banned in [
            "remove_file",
            "truncate(",
            "set_len",
            ".seek(",
            "write_at",
            "OpenOptions::new",
        ] {
            assert!(
                !kept.contains(banned),
                "audit.rs uses {banned} outside sweep/append"
            );
        }
    }
}
