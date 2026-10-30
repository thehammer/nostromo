//! Golden wire frames for command staging (slice S1a).
//!
//! `tests/fixtures/terminal_staging/frame-terminal-staging-list-{active,frozen,none}.json`
//! are the exact bytes serde produces for a `terminal_staging_list` frame, and
//! `client-terminal-staging-{inserted,remove,clear}.json` for the three client
//! frames. The Mac's contract tests (slice S1b) read the same files, so they are
//! never edited by hand: after an intended change to the wire shape regenerate
//! them with
//!
//!   UPDATE_GOLDEN=1 cargo test --test terminal_staging_wire_golden
//!
//! and review the diff (the Swift side must still decode them).
//!
//! Everything is fixed (timestamps included), so the output is reproducible.

use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, StagedEntryWire};
use serde::Serialize;

const TERMINAL: &str = "5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11";
const PANE: &str = "terminal-00000001";

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/terminal_staging")
        .join(name)
}

fn entries() -> Vec<StagedEntryWire> {
    let staged = Utc.with_ymd_and_hms(2026, 10, 30, 15, 4, 5).unwrap();
    vec![
        StagedEntryWire {
            id: "s-00000001".into(),
            number: 1,
            command: "git status --short".into(),
            note: Some("see what changed".into()),
            staged_at: staged,
            changed_at: staged,
            inserted_count: 0,
            last_inserted_at: None,
        },
        StagedEntryWire {
            id: "s-00000002".into(),
            number: 2,
            command: "ls -la src/terminal".into(),
            note: None,
            staged_at: staged,
            changed_at: Utc.with_ymd_and_hms(2026, 10, 30, 15, 6, 1).unwrap(),
            inserted_count: 2,
            last_inserted_at: Some(Utc.with_ymd_and_hms(2026, 10, 30, 15, 7, 30).unwrap()),
        },
    ]
}

fn list_frame(state: &str, revision: u64, entries: Vec<StagedEntryWire>) -> ServerMsg {
    ServerMsg::TerminalStagingList {
        terminal_id: TERMINAL.into(),
        pane_id: PANE.into(),
        state: state.into(),
        owner_tag: "cody-fixture".into(),
        agent_name: "Cody".into(),
        revision,
        entries,
    }
}

fn none_frame() -> ServerMsg {
    ServerMsg::TerminalStagingList {
        terminal_id: TERMINAL.into(),
        pane_id: PANE.into(),
        state: "none".into(),
        owner_tag: String::new(),
        agent_name: String::new(),
        revision: 9,
        entries: Vec::new(),
    }
}

/// Pretty JSON with a trailing newline: the committed form.
fn rendered<T: Serialize>(msg: &T) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

/// Compares `msg`'s rendering with the committed file, or writes the file when
/// `UPDATE_GOLDEN=1`. The file's text.
fn check_golden<T: Serialize>(name: &str, msg: &T) -> String {
    let want = rendered(msg);
    let path = fixture_path(name);
    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &want).unwrap_or_else(|e| panic!("write {path:?}: {e}"));
        return want;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{path:?} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test terminal_staging_wire_golden")
    });
    assert!(
        have == want,
        "{name} drifted from what serde produces; if the change is intended, regenerate with \
         UPDATE_GOLDEN=1 cargo test --test terminal_staging_wire_golden and review the diff\n--- file\n{have}\n--- serde\n{want}"
    );
    have
}

#[test]
fn the_active_frame_matches_its_golden_file() {
    check_golden(
        "frame-terminal-staging-list-active.json",
        &list_frame("active", 7, entries()),
    );
}

#[test]
fn the_frozen_frame_matches_its_golden_file() {
    check_golden(
        "frame-terminal-staging-list-frozen.json",
        &list_frame("frozen", 8, entries()),
    );
}

#[test]
fn the_none_frame_matches_its_golden_file_and_carries_no_entries() {
    let text = check_golden("frame-terminal-staging-list-none.json", &none_frame());
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["state"], "none");
    assert_eq!(value["entries"], serde_json::json!([]));
}

#[test]
fn optional_fields_are_omitted_when_absent() {
    let text = rendered(&list_frame("active", 1, entries()));
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert!(value["entries"][0].get("last_inserted_at").is_none());
    assert!(value["entries"][1].get("note").is_none());
    assert_eq!(value["type"], "terminal_staging_list");
    let back: ServerMsg = serde_json::from_str(&text).unwrap();
    assert_eq!(rendered(&back), text);
}

#[test]
fn the_client_frames_match_their_golden_files_and_decode() {
    let inserted = ClientMsg::TerminalStagingInserted {
        terminal_id: TERMINAL.into(),
        entry_id: "s-00000002".into(),
        bytes: 19,
        confirmed: false,
    };
    let remove = ClientMsg::TerminalStagingRemove {
        terminal_id: TERMINAL.into(),
        entry_id: "s-00000001".into(),
    };
    let clear = ClientMsg::TerminalStagingClear {
        terminal_id: TERMINAL.into(),
    };
    for (name, msg, verb) in [
        (
            "client-terminal-staging-inserted.json",
            &inserted,
            "terminal_staging_inserted",
        ),
        (
            "client-terminal-staging-remove.json",
            &remove,
            "terminal_staging_remove",
        ),
        (
            "client-terminal-staging-clear.json",
            &clear,
            "terminal_staging_clear",
        ),
    ] {
        let text = check_golden(name, msg);
        let decoded: ClientMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(rendered(&decoded), text, "{name} round-trips");
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["type"], verb);
    }
}

#[test]
fn an_older_app_that_omits_confirmed_decodes_it_as_false() {
    let msg: ClientMsg = serde_json::from_str(
        r#"{"type":"terminal_staging_inserted","terminal_id":"t","entry_id":"s-00000001","bytes":4}"#,
    )
    .unwrap();
    match msg {
        ClientMsg::TerminalStagingInserted {
            confirmed, bytes, ..
        } => {
            assert!(!confirmed);
            assert_eq!(bytes, 4);
        }
        other => panic!("{other:?}"),
    }
}
