//! The sent ledger (`sent.json`) keeps what it was given: a file it cannot
//! understand is quarantined, never overwritten, and a focus marker follows
//! the focus it was recorded for (not whoever takes the tag next).
//!
//! Behavioural only, through `SentLedger::new` / `record` / `markers` and the
//! files on disk. Each test uses its own temp dir.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use chrono::Utc;
use nostromo::data::work::model::SentMarker;
use nostromo::data::work::sent::SentLedger;

fn marker(kind: &str, target: &str, nonce: Option<&str>) -> SentMarker {
    SentMarker {
        kind: kind.into(),
        target_id: target.into(),
        label: format!("label {target}"),
        created_at: Utc::now(),
        nonce: nonce.map(str::to_owned),
    }
}

fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    v.sort();
    v
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Restores a mode on drop so a failing test still lets its temp dir be removed.
struct Restore(PathBuf, u32);

impl Drop for Restore {
    fn drop(&mut self) {
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(self.1));
    }
}

// ── quarantine ────────────────────────────────────────────────────────────────

#[test]
fn a_corrupt_file_is_quarantined_with_its_bytes_and_the_next_record_does_not_destroy_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    let corrupt = "{\"todo:1\": [ {oops this is not json";
    std::fs::write(&path, corrupt).unwrap();

    let ledger = SentLedger::new(&path);

    assert!(
        ledger.item_ids().is_empty(),
        "a corrupt ledger starts empty"
    );
    assert_eq!(
        names(dir.path()),
        vec!["sent.json.corrupt-1".to_string()],
        "moved aside, not deleted"
    );
    assert_eq!(
        std::fs::read_to_string(dir.path().join("sent.json.corrupt-1")).unwrap(),
        corrupt
    );

    ledger
        .record("jira:A-1", marker("focus", "cody-a-1", Some("n1")))
        .unwrap();

    assert_eq!(
        std::fs::read_to_string(dir.path().join("sent.json.corrupt-1")).unwrap(),
        corrupt,
        "recording never touches the quarantined copy"
    );
    assert_eq!(
        names(dir.path()),
        vec!["sent.json".to_string(), "sent.json.corrupt-1".to_string()]
    );
    assert_eq!(
        SentLedger::new(&path).markers("jira:A-1").len(),
        1,
        "the new file is a valid ledger"
    );
}

#[test]
fn every_kind_of_unparseable_content_is_quarantined() {
    for (i, content) in [
        "{not json",
        "{\"a\":",
        "[]",
        "null",
        "42",
        "\"text\"",
        "{\"a\": 1}",
        "not json at all",
    ]
    .into_iter()
    .enumerate()
    {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.json");
        std::fs::write(&path, content).unwrap();

        let ledger = SentLedger::new(&path);

        assert!(ledger.item_ids().is_empty(), "case {i} {content:?}");
        assert_eq!(
            std::fs::read_to_string(dir.path().join("sent.json.corrupt-1")).unwrap_or_default(),
            content,
            "case {i}: {content:?} is kept as the `.corrupt-1` copy"
        );
    }
}

#[test]
fn a_second_corruption_gets_the_next_free_suffix_and_leaves_the_first_copy_alone() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    std::fs::write(&path, "first {corruption").unwrap();
    drop(SentLedger::new(&path));
    std::fs::write(&path, "second {corruption").unwrap();

    let ledger = SentLedger::new(&path);

    assert!(ledger.item_ids().is_empty());
    assert_eq!(
        std::fs::read_to_string(dir.path().join("sent.json.corrupt-1")).unwrap(),
        "first {corruption"
    );
    assert_eq!(
        std::fs::read_to_string(dir.path().join("sent.json.corrupt-2")).unwrap(),
        "second {corruption"
    );
    assert_eq!(
        names(dir.path()),
        vec![
            "sent.json.corrupt-1".to_string(),
            "sent.json.corrupt-2".to_string()
        ]
    );
}

#[test]
fn a_missing_file_is_an_empty_ledger_and_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = SentLedger::new(dir.path().join("sent.json"));
    assert!(ledger.item_ids().is_empty());
    assert!(names(dir.path()).is_empty(), "{:?}", names(dir.path()));

    let nowhere = SentLedger::new(dir.path().join("not-yet").join("sent.json"));
    assert!(nowhere.item_ids().is_empty());
    assert!(names(dir.path()).is_empty(), "{:?}", names(dir.path()));
}

#[test]
fn a_valid_file_loads_untouched_and_is_not_quarantined() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    SentLedger::new(&path)
        .record("jira:A-1", marker("focus", "cody-a-1", Some("n1")))
        .unwrap();
    let before = std::fs::read(&path).unwrap();

    let reopened = SentLedger::new(&path);

    assert_eq!(reopened.markers("jira:A-1").len(), 1);
    assert_eq!(names(dir.path()), vec!["sent.json".to_string()]);
    assert_eq!(
        std::fs::read(&path).unwrap(),
        before,
        "loading never rewrites"
    );
}

#[test]
fn a_file_written_before_markers_had_a_nonce_still_loads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    std::fs::write(
        &path,
        r#"{"todo:1":[{"kind":"focus","target_id":"cody-old","label":"Old","created_at":"2026-01-01T00:00:00Z"}]}"#,
    )
    .unwrap();

    let ledger = SentLedger::new(&path);

    let m = ledger.markers("todo:1");
    assert_eq!(m.len(), 1, "an old-format file is valid, not corrupt");
    assert_eq!(
        (m[0].target_id.as_str(), m[0].nonce.as_deref()),
        ("cody-old", None)
    );
    assert_eq!(names(dir.path()), vec!["sent.json".to_string()]);
}

#[test]
fn a_marker_nonce_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    SentLedger::new(&path)
        .record("jira:A-1", marker("focus", "cody-a-1", Some("nonce-123")))
        .unwrap();
    assert_eq!(
        SentLedger::new(&path).markers("jira:A-1")[0]
            .nonce
            .as_deref(),
        Some("nonce-123")
    );
}

#[test]
fn an_unreadable_file_is_quarantined_too() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    SentLedger::new(&path)
        .record("jira:A-1", marker("focus", "cody-a-1", None))
        .unwrap();
    let original = std::fs::read(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
    let quarantined = dir.path().join("sent.json.corrupt-1");
    let _restore = (
        Restore(path.clone(), 0o600),
        Restore(quarantined.clone(), 0o600),
    );
    if std::fs::read(&path).is_ok() {
        eprintln!("skipped: permissions do not stop this user (root?) from reading the file");
        return;
    }

    let ledger = SentLedger::new(&path);

    assert!(ledger.item_ids().is_empty());
    assert!(!path.exists(), "the unreadable file was moved aside");
    assert!(quarantined.exists(), "{:?}", names(dir.path()));
    std::fs::set_permissions(&quarantined, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        std::fs::read(&quarantined).unwrap(),
        original,
        "its bytes are preserved"
    );
}

#[test]
fn when_the_corrupt_file_cannot_be_moved_aside_record_fails_and_never_overwrites_it() {
    let dir = tempfile::tempdir().unwrap();
    let teri = dir.path().join("teri");
    std::fs::create_dir(&teri).unwrap();
    let path = teri.join("sent.json");
    let corrupt = "{this is the only copy";
    std::fs::write(&path, corrupt).unwrap();
    std::fs::set_permissions(&teri, std::fs::Permissions::from_mode(0o500)).unwrap();
    let _restore = Restore(teri.clone(), 0o700);
    if std::fs::File::create(teri.join("probe")).is_ok() {
        eprintln!("skipped: directory permissions do not stop this user (root?) from writing");
        return;
    }

    let ledger = SentLedger::new(&path);
    let result = ledger.record("jira:A-1", marker("focus", "cody-a-1", Some("n1")));
    std::fs::set_permissions(&teri, std::fs::Permissions::from_mode(0o700)).unwrap();

    assert!(
        result.is_err(),
        "a ledger whose corrupt file could not be preserved must not write"
    );
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        corrupt,
        "sent.json is exactly as it was"
    );
    assert_eq!(
        names(&teri),
        vec!["sent.json".to_string()],
        "no copy, no temp file left"
    );
    assert_eq!(
        ledger.markers("jira:A-1").len(),
        1,
        "this run's duplicate protection still holds in memory"
    );
}

#[test]
fn the_file_is_0600_the_directory_0700_and_no_temp_file_is_left_even_after_a_quarantine() {
    let dir = tempfile::tempdir().unwrap();
    let teri = dir.path().join("teri");
    std::fs::create_dir(&teri).unwrap();
    let path = teri.join("sent.json");
    std::fs::write(&path, "{broken").unwrap();

    let ledger = SentLedger::new(&path);
    ledger
        .record("jira:A-1", marker("focus", "cody-a-1", Some("n1")))
        .unwrap();

    assert_eq!(mode(&teri), 0o700);
    assert_eq!(mode(&path), 0o600);
    assert_eq!(
        names(&teri),
        vec!["sent.json".to_string(), "sent.json.corrupt-1".to_string()]
    );
}

// ── a focus marker follows its focus, not its tag ─────────────────────────────

#[test]
fn recording_a_focus_for_a_tag_supersedes_other_items_markers_for_that_tag_with_another_nonce() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sent.json");
    let ledger = SentLedger::new(&path);
    ledger
        .record("todo:A", marker("focus", "cody-x", Some("nonce-a")))
        .unwrap();
    ledger
        .record("todo:C", marker("focus", "cody-other", Some("nonce-c")))
        .unwrap();

    ledger
        .record("todo:B", marker("focus", "cody-x", Some("nonce-b")))
        .unwrap();

    for l in [&ledger, &SentLedger::new(&path)] {
        assert!(
            l.markers("todo:A").iter().all(|m| m.target_id != "cody-x"),
            "A pointed at an earlier focus that had this tag: {:?}",
            l.markers("todo:A")
        );
        assert_eq!(l.markers("todo:B").len(), 1);
        assert_eq!(l.markers("todo:B")[0].nonce.as_deref(), Some("nonce-b"));
        assert_eq!(l.markers("todo:C").len(), 1, "a different tag is untouched");
    }
}

#[test]
fn markers_for_the_same_focus_are_kept_and_other_kinds_are_not_superseded() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = SentLedger::new(dir.path().join("sent.json"));
    ledger
        .record("todo:A", marker("focus", "cody-x", Some("same-focus")))
        .unwrap();
    ledger
        .record("todo:B", marker("focus", "cody-x", Some("same-focus")))
        .unwrap();
    ledger
        .record("todo:C", marker("mother_job", "cody-x", None))
        .unwrap(); // a job id that happens to equal the tag

    ledger
        .record("todo:D", marker("focus", "cody-x", Some("a-later-focus")))
        .unwrap();

    assert!(ledger.markers("todo:A").is_empty(), "older focus");
    assert!(ledger.markers("todo:B").is_empty(), "older focus");
    assert_eq!(
        ledger.markers("todo:C").len(),
        1,
        "a Mother job marker is not a focus marker"
    );
    assert_eq!(ledger.markers("todo:D").len(), 1);

    let same = SentLedger::new(dir.path().join("same.json"));
    same.record("todo:A", marker("focus", "cody-y", Some("one-focus")))
        .unwrap();
    same.record("todo:B", marker("focus", "cody-y", Some("one-focus")))
        .unwrap();
    assert_eq!(
        same.markers("todo:A").len(),
        1,
        "same nonce: the same focus serves both items"
    );
    assert_eq!(same.markers("todo:B").len(), 1);
}
