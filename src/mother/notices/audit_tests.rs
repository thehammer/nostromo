//! What the notice engine leaves in the audit file and the log (SR8,
//! MF2a-12): ids, tags, enums and counts only, never a title, a question or
//! a PR URL.

use super::*;

use std::collections::BTreeSet;
use std::io::Write;

use crate::mother::notices::NoticeScope;

/// Every key a notice audit line may carry (plus MF1's origin events, which
/// share the file).
const ALLOWED_KEYS: [&str; 13] = [
    "ts", "event", "job_ids", "focus", "wake", "combined", "reason", "scope", "mode", "enabled",
    "peer", "job", "via",
];

const NOTICE_EVENTS: [&str; 5] = [
    "job_notice_delivered",
    "job_notice_held",
    "job_notice_dropped",
    "mother_notice_settings_changed",
    "mother_notice_settings_refused",
];

/// Drives F through a wake, G through a hold (no session), H through a drop
/// (focus off) and an expiry, F through the cap, plus a settings change and a
/// refusal; every job carries `marker` in its title, question and PR URL.
fn drive_everything(r: &Rig, marker: &str) {
    let title = format!("{marker}-TITLE");
    let question = format!("{marker}-Q which way?");
    let pr = format!("https://example.invalid/{marker}-PR");
    let rich = |tag: &str, id: &str, state: &str| {
        job(tag, id, state)
            .titled(&title)
            .asking(&question)
            .with_pr(&pr)
            .failing_with(&format!("{marker}-FAILURE"))
    };

    // A wake (and five more notice turns, to reach the cap).
    for k in 0..6 {
        r.jobs(&[rich(
            F,
            &format!("w{k}"),
            if k % 2 == 0 { "awaiting" } else { "failed" },
        )]);
        r.after(30 * SEC);
        r.notice_turn(F);
    }
    // The cap.
    r.jobs(&[rich(F, "capped", "succeeded")]);
    r.after(30 * SEC);
    // The user's next turn lifts the cap; that delivery runs as a notice turn.
    r.reply(F, Reply::Queued);
    r.user_turn_starts(F);
    r.turn_ends(F);
    r.notice_turn(F);

    // A hold: no session for G.
    r.reply(G, Reply::Down);
    r.jobs(&[rich(G, "down", "awaiting")]);
    r.after(30 * SEC);

    // A drop: H is off.
    let h = "focus-h";
    r.engine
        .apply_settings(NoticeScope::Focus, Some(h), Some(NotifyLevel::Off), None)
        .unwrap();
    r.jobs(&[rich(h, "off", "succeeded")]);
    r.after(30 * SEC);
    r.engine.audit_settings_refused("local_other");

    // An expiry: G's hold passes 24 h.
    r.after(25 * HOUR);
}

#[test]
fn the_audit_has_each_notice_event_with_ids_tags_enums_and_counts_only() {
    let r = Rig::new();
    drive_everything(&r, "CANARY");

    let raw = std::fs::read_to_string(r.audit_path()).expect("the audit file");
    assert!(
        !raw.contains("CANARY"),
        "content leaked into the audit:\n{raw}"
    );
    assert!(!raw.contains("example.invalid"), "{raw}");
    assert!(!raw.contains("which way"), "{raw}");

    let lines = r.audit();
    let events: BTreeSet<&str> = lines.iter().filter_map(|l| l["event"].as_str()).collect();
    for event in NOTICE_EVENTS {
        assert!(events.contains(event), "{event} is audited: {events:?}");
    }
    for line in &lines {
        for key in line.as_object().expect("a JSON object").keys() {
            assert!(
                ALLOWED_KEYS.contains(&key.as_str()),
                "unexpected audit key {key}: {line}"
            );
        }
    }

    let delivered = r.audit_events("job_notice_delivered");
    let first = &delivered[0];
    assert_eq!(first["job_ids"], serde_json::json!(["w0"]));
    assert_eq!(first["focus"], F);
    assert_eq!(first["wake"], true);
    assert_eq!(first["combined"], 1);

    let held: Vec<(String, String)> = r
        .audit_events("job_notice_held")
        .iter()
        .map(|l| {
            (
                l["focus"].as_str().unwrap().to_owned(),
                l["reason"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert!(held.contains(&(F.to_owned(), "cap".to_owned())), "{held:?}");
    assert!(
        held.contains(&(G.to_owned(), "session_not_running".to_owned())),
        "{held:?}"
    );

    let dropped: Vec<(String, String)> = r
        .audit_events("job_notice_dropped")
        .iter()
        .map(|l| {
            (
                l["focus"].as_str().unwrap().to_owned(),
                l["reason"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert!(
        dropped.contains(&("focus-h".to_owned(), "focus_off".to_owned())),
        "{dropped:?}"
    );
    assert!(
        dropped.contains(&(G.to_owned(), "expired".to_owned())),
        "{dropped:?}"
    );
}

#[test]
fn the_engine_is_audited_only_into_the_mother_audit_file() {
    let r = Rig::new();
    r.jobs(&[job(F, "a", "succeeded")]);
    r.after(30 * SEC);
    let audit_dir = r.audit_path().parent().unwrap().to_owned();
    let names: Vec<String> = std::fs::read_dir(&audit_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["mother.jsonl".to_owned()]);
}

// ── SR8: the TRACE canary ────────────────────────────────────────────────────

#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

#[test]
fn nothing_the_engine_logs_at_trace_or_audits_carries_a_title_question_or_pr() {
    let captured = Captured::default();
    let writer = captured.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .finish();
    let _guard = tracing::subscriber::set_default(subscriber);
    tracing::trace!("notice-canary-capture-check");

    let r = Rig::with_store();
    r.jobs(&[]);
    drive_everything(&r, "SECRET");
    // A restart, so loading and saving the store are covered too.
    let r = r.restart();
    r.jobs(&[job(F, "after-restart", "succeeded").titled("SECRET-TITLE")]);
    r.after(30 * SEC);

    let logged = captured.text();
    assert!(
        logged.contains("notice-canary-capture-check"),
        "the capture works: {logged}"
    );
    let audit = std::fs::read_to_string(r.audit_path()).unwrap_or_default();
    for sentinel in ["SECRET-TITLE", "SECRET-Q", "SECRET-PR", "SECRET-FAILURE"] {
        assert!(
            !logged.contains(sentinel),
            "{sentinel} in the log:\n{logged}"
        );
        assert!(
            !audit.contains(sentinel),
            "{sentinel} in the audit:\n{audit}"
        );
    }
}
