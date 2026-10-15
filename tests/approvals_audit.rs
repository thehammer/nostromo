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
use nostromo::approvals::audit::{AuditFilter, AuditLog, Entry, Event, RETENTION_DAYS};
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
        },
        ts,
    );
    e.tag = tag.map(String::from);
    e
}

fn file_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> =
        std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
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

    assert_eq!(file_names(log.dir()), ["audit-2026-03-04.jsonl", "audit-2026-03-05.jsonl"]);
    assert_eq!(log.file_for(late.ts), log.dir().join("audit-2026-03-04.jsonl"));
    assert_eq!(log.file_for(early.ts), log.dir().join("audit-2026-03-05.jsonl"));
    for name in file_names(log.dir()) {
        assert_eq!(mode_of(&log.dir().join(&name)), 0o600, "{name}");
    }
}

#[test]
fn every_entry_is_one_line_and_earlier_lines_are_never_rewritten() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let path = log.file_for(at(2026, 3, 4, 12, 0, 0));

    log.append(&blocked(at(2026, 3, 4, 10, 0, 0), None)).unwrap();
    let after_one = std::fs::read_to_string(&path).unwrap();
    log.append(&blocked(at(2026, 3, 4, 11, 0, 0), None)).unwrap();
    log.append(&request(at(2026, 3, 4, 12, 0, 0), None)).unwrap();
    let after_three = std::fs::read_to_string(&path).unwrap();

    assert_eq!(after_one.lines().count(), 1);
    assert_eq!(after_three.lines().count(), 3);
    assert!(after_three.starts_with(&after_one), "the first line is untouched");
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
    assert_eq!((a.request_id, a.tag, a.session_id, a.tool_use_id, a.agent, a.subagent), (None, None, None, None, None, None));
}

#[test]
fn a_guard_blocked_entry_serializes_with_the_event_beside_the_common_fields() {
    let e = blocked(at(2026, 3, 4, 10, 0, 0), Some("focus-x"));

    let v: Value = serde_json::to_value(&e).unwrap();

    assert_eq!(v["v"], json!(1));
    assert_eq!(v["id"], json!(e.id));
    assert_eq!(v["event"], json!("guard_blocked"));
    assert_eq!(v["tool_name"], json!("Bash"));
    assert_eq!(v["input"], json!({ "command": "ecs_connect ap production portal", "description": "d" }));
    assert_eq!(v["rule"], json!("command"));
    assert_eq!(v["tag"], json!("focus-x"));
    assert_eq!(v["session_id"], json!("s-1"));
    assert_eq!(v["tool_use_id"], json!("toolu_1"));
    let ts = DateTime::parse_from_rfc3339(v["ts"].as_str().expect("ts is a string")).expect("ts is RFC 3339");
    assert_eq!(ts.with_timezone(&Utc), e.ts);
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert!(!keys.iter().any(|k| *k == "request_id" || *k == "agent" || *k == "subagent"), "absent fields are omitted: {keys:?}");
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
            },
        ),
        (
            "outcome",
            Event::Outcome { outcome: "allow_once".into(), rule: Some(json!({ "tool": "Bash" })), by_window: Some("w1".into()), latency_ms: Some(1234) },
        ),
        ("refusal", Event::Refusal { refusal_code: "not_operator".into(), peer: Some(json!({ "trust": "local_other", "pid": 7 })) }),
        ("guard_blocked", blocked_event("ecs_connect")),
        ("session_rule_granted", Event::SessionRuleGranted { rule: json!({ "tool": "Bash" }) }),
        ("session_rule_revoked", Event::SessionRuleRevoked { rule: json!({ "tool": "Bash" }) }),
        ("rule_written", Event::RuleWritten { rule: json!({ "tool": "Bash" }) }),
        ("rule_removed", Event::RuleRemoved { rule: json!({ "tool": "Bash" }) }),
    ]
}

#[test]
fn every_event_kind_round_trips_through_json_under_its_snake_case_name() {
    for (name, event) in every_event() {
        assert_eq!(event.kind(), name);
        let entry = Entry::new(event, at(2026, 3, 4, 10, 0, 0));

        let json = serde_json::to_string(&entry).unwrap();
        let value: Value = serde_json::from_str(&json).unwrap();
        let back: Entry = serde_json::from_str(&json).unwrap_or_else(|e| panic!("{name}: {e}: {json}"));

        assert_eq!(value["event"], json!(name), "{json}");
        assert_eq!(back, entry, "{name}");
    }
}

#[test]
fn a_minimal_event_leaves_its_optional_fields_out() {
    let e = Entry::new(Event::Outcome { outcome: "deny".into(), rule: None, by_window: None, latency_ms: None }, at(2026, 3, 4, 10, 0, 0));

    let v: Value = serde_json::to_value(&e).unwrap();

    assert_eq!(v["event"], json!("outcome"));
    assert_eq!(v["outcome"], json!("deny"));
    assert!(v.get("by_window").is_none() && v.get("latency_ms").is_none(), "{v}");
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

    let all = log.read(t0..t3 + Duration::seconds(1), &AuditFilter::default()).unwrap();
    assert_eq!(all.iter().map(|e| e.ts).collect::<Vec<_>>(), [t0, t1, t2, t3], "oldest first, across files");

    let half_open = log.read(t1..t3, &AuditFilter::default()).unwrap();
    assert_eq!(half_open.iter().map(|e| e.ts).collect::<Vec<_>>(), [t1, t2], "start is included, end is not");

    assert!(log.read(t1..t1, &AuditFilter::default()).unwrap().is_empty(), "an empty range is empty");
    assert!(log.read(at(2027, 1, 1, 0, 0, 0)..at(2027, 2, 1, 0, 0, 0), &AuditFilter::default()).unwrap().is_empty());
}

#[test]
fn reading_can_be_filtered_by_focus_tag_and_by_event_kind() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    let base = at(2026, 3, 4, 10, 0, 0);
    log.append(&blocked(base, Some("focus-x"))).unwrap();
    log.append(&blocked(base + Duration::minutes(1), Some("focus-y"))).unwrap();
    log.append(&request(base + Duration::minutes(2), Some("focus-x"))).unwrap();
    log.append(&request(base + Duration::minutes(3), None)).unwrap();

    let by_tag = log.read(everything(), &AuditFilter { tag: Some("focus-x".into()), event: None }).unwrap();
    assert_eq!(by_tag.len(), 2);
    assert!(by_tag.iter().all(|e| e.tag.as_deref() == Some("focus-x")));

    let by_kind = log.read(everything(), &AuditFilter { tag: None, event: Some("guard_blocked".into()) }).unwrap();
    assert_eq!(by_kind.len(), 2);
    assert!(by_kind.iter().all(|e| e.event.kind() == "guard_blocked"));

    let both = log.read(everything(), &AuditFilter { tag: Some("focus-x".into()), event: Some("guard_blocked".into()) }).unwrap();
    assert_eq!(both.len(), 1);
    assert_eq!(both[0].ts, base);

    assert_eq!(log.read(everything(), &AuditFilter::default()).unwrap().len(), 4, "an empty filter matches everything");
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
    assert!(log.read(everything(), &AuditFilter::default()).unwrap().is_empty());
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
        assert!(name.starts_with("audit-") && name.ends_with(".jsonl"), "{name}");
        for line in std::fs::read_to_string(dir.join(&name)).unwrap().lines() {
            let e: Entry = serde_json::from_str(line).unwrap_or_else(|err| panic!("a corrupted line ({err}): {}", &line[..line.len().min(120)]));
            ids.insert(e.id);
            lines += 1;
        }
    }
    assert_eq!(lines, 2 * EACH + 1, "no entry lost or merged");
    assert_eq!(ids.len(), lines, "every entry kept its own id");
    let from_guard = log.read(everything(), &AuditFilter { tag: Some("from-guard".into()), event: None }).unwrap();
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
        log.append(&blocked(now - Duration::days(days), None)).unwrap();
    }
    let unrelated = log.dir().join("notes.txt");
    std::fs::write(&unrelated, "keep me").unwrap();
    let name_of = |days: i64| format!("audit-{}.jsonl", (now - Duration::days(days)).format("%Y-%m-%d"));
    assert_eq!(file_names(log.dir()).len(), 6);

    let deleted = log.sweep(now).unwrap();

    assert_eq!(deleted, 2);
    let mut expected = vec![name_of(0), name_of(89), name_of(90), "notes.txt".to_string()];
    expected.sort();
    assert_eq!(file_names(log.dir()), expected, "91 and 200 days old are gone; 90 days old is kept");
    assert_eq!(std::fs::read_to_string(&unrelated).unwrap(), "keep me");
    assert_eq!(log.sweep(now).unwrap(), 0, "nothing more to delete");
    assert_eq!(log.read(everything(), &AuditFilter::default()).unwrap().len(), 3, "recent entries are intact");
}

#[test]
fn sweeping_an_empty_store_deletes_nothing() {
    let root = tempfile::tempdir().unwrap();
    let log = AuditLog::open(&root.path().join("a")).unwrap();
    assert_eq!(log.sweep(at(2026, 10, 15, 12, 0, 0)).unwrap(), 0);
}
