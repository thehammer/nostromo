//! The terminal-conversation index, on synthetic transcripts only (no `claude`, no network).

use super::first_prompt::{FirstPrompt, Reason};
use super::outside::{path_beside, OutsideIndex, ScanEnv};
use super::transcript::bytes_read_on_this_thread;
use serde_json::json;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const NOW: i64 = 1_800_000_000_000;

fn secs(ms: i64) -> std::time::SystemTime {
    std::time::UNIX_EPOCH + std::time::Duration::from_millis(ms as u64)
}

fn rec(kind: &str, entrypoint: &str, cwd: &str, sidechain: bool, text: &str) -> String {
    let mut v = json!({
        "type": kind, "entrypoint": entrypoint, "cwd": cwd, "isSidechain": sidechain,
        "gitBranch": "main", "timestamp": "2027-01-15T08:00:00Z",
        "message": {"role": kind, "content": text, "model": "claude-x"},
    });
    if kind == "assistant" {
        v["message"]["content"] = json!([{"type": "text", "text": "ok"}]);
    }
    format!("{v}\n")
}

fn conversation(entrypoint: &str, cwd: &str, sidechain: bool, prompt: &str) -> String {
    rec("user", entrypoint, cwd, sidechain, prompt)
        + &rec("assistant", entrypoint, cwd, sidechain, "")
}

struct Rig {
    dir: tempfile::TempDir,
    projects: PathBuf,
}

impl Rig {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let projects = dir.path().join("projects");
        std::fs::create_dir_all(&projects).unwrap();
        Self { dir, projects }
    }

    /// A top-level transcript, last written `age_ms` before NOW.
    fn put(&self, sid: &str, body: &str, age_ms: i64) -> PathBuf {
        let folder = self.projects.join("-work-app");
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("{sid}.jsonl"));
        std::fs::write(&path, body).unwrap();
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(secs(NOW - age_ms))
            .unwrap();
        path
    }

    fn scan(&self, index: &OutsideIndex, known: &[&str]) {
        let known: HashSet<String> = known.iter().map(|s| (*s).to_owned()).collect();
        assert!(index.try_begin());
        self.scan_claimed_known(index, &known);
    }

    /// Scan with the claim already taken; returns whether the list changed.
    fn scan_claimed(&self, index: &OutsideIndex) -> bool {
        self.scan_claimed_known(index, &HashSet::new())
    }

    fn scan_claimed_known(&self, index: &OutsideIndex, known: &HashSet<String>) -> bool {
        let sensitive = |agent: Option<&str>| agent == Some("fred");
        index.scan_and_store(&ScanEnv {
            projects_dir: &self.projects,
            known,
            first_prompts_enabled: true,
            is_sensitive: &sensitive,
            now_ms: NOW,
        })
    }

    fn scan_changed(&self, index: &OutsideIndex) -> bool {
        assert!(index.try_begin());
        self.scan_claimed(index)
    }

    fn sids(&self, index: &OutsideIndex) -> Vec<String> {
        let mut v: Vec<String> = index.entries().into_iter().map(|e| e.sid).collect();
        v.sort();
        v
    }
}

#[test]
fn the_index_keeps_an_interactive_conversation_and_drops_each_kind_that_is_not_one() {
    let rig = Rig::new();
    rig.put(
        "good",
        &conversation("cli", "/work/app", false, "fix the login bug"),
        1000,
    );
    // One discriminator at a time: each fixture differs from "good" in exactly one way.
    rig.put(
        "dash-p",
        &conversation("sdk-cli", "/work/app", false, "x"),
        1000,
    );
    rig.put(
        "sdk",
        &conversation("sdk-ts", "/work/app", false, "x"),
        1000,
    );
    rig.put(
        "mother",
        &conversation("cli", "/Users/me/.mother/work/job-1", false, "x"),
        1000,
    );
    rig.put(
        "sidechain",
        &conversation("cli", "/work/app", true, "x"),
        1000,
    );
    rig.put("held", &conversation("cli", "/work/app", false, "x"), 1000);
    rig.put(
        "old",
        &conversation("cli", "/work/app", false, "x"),
        31 * 24 * 3600 * 1000,
    );
    rig.put("empty", "", 1000);
    // A subagent's thread lives in a per-session subfolder.
    let sub = rig
        .projects
        .join("-work-app")
        .join("good")
        .join("subagents");
    std::fs::create_dir_all(&sub).unwrap();
    std::fs::write(
        sub.join("agent-a1.jsonl"),
        conversation("cli", "/work/app", false, "x"),
    )
    .unwrap();
    // A symlinked transcript is never followed.
    #[cfg(unix)]
    std::os::unix::fs::symlink(
        rig.projects.join("-work-app").join("good.jsonl"),
        rig.projects.join("-work-app").join("linked.jsonl"),
    )
    .unwrap();

    let index = OutsideIndex::in_memory();
    rig.scan(&index, &["held"]);
    assert_eq!(rig.sids(&index), vec!["good".to_owned()]);
    assert!(index.ready());
}

#[test]
fn a_file_is_read_within_its_head_and_tail_budget_and_an_unchanged_one_not_again() {
    let rig = Rig::new();
    let path = rig.put(
        "big",
        &conversation("cli", "/work/app", false, "big one"),
        1000,
    );
    // 100 MB, sparse: the head and one record near the end are real.
    let tail = rec("user", "cli", "/work/app", false, "later").replace("main", "topic");
    {
        use std::io::{Seek, SeekFrom, Write};
        let mut f = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        f.set_len(100 << 20).unwrap();
        f.seek(SeekFrom::Start((100 << 20) - 4096)).unwrap();
        f.write_all(b"\n").unwrap();
        f.write_all(tail.as_bytes()).unwrap();
        f.set_modified(secs(NOW - 1000)).unwrap();
    }
    rig.put(
        "sdk-big",
        &conversation("sdk-cli", "/work/app", false, "x"),
        1000,
    );
    let sdk = rig.projects.join("-work-app").join("sdk-big.jsonl");
    std::fs::OpenOptions::new()
        .write(true)
        .open(&sdk)
        .unwrap()
        .set_len(100 << 20)
        .unwrap();
    std::fs::File::options()
        .write(true)
        .open(&sdk)
        .unwrap()
        .set_modified(secs(NOW - 1000))
        .unwrap();

    let index = OutsideIndex::in_memory();
    let before = bytes_read_on_this_thread();
    rig.scan(&index, &[]);
    let read = bytes_read_on_this_thread() - before;
    assert!(
        read <= (512 + 256 + 512) << 10,
        "read {read} bytes of two 100 MB files"
    );
    let e = index.get("big").expect("indexed");
    assert_eq!(e.branch.as_deref(), Some("topic"), "the tail was read");

    let before = bytes_read_on_this_thread();
    rig.scan(&index, &[]);
    assert_eq!(
        bytes_read_on_this_thread() - before,
        0,
        "nothing changed: nothing re-read"
    );
}

#[test]
fn a_flagged_first_prompt_is_withheld_and_its_text_is_in_no_file() {
    let rig = Rig::new();
    rig.put(
        "flagged",
        &conversation(
            "cli",
            "/work/app",
            false,
            "Call back, SSN was 219-09-9999 ok",
        ),
        1000,
    );
    rig.put(
        "plain",
        &conversation("cli", "/work/app", false, "tidy the readme"),
        2000,
    );
    let store = rig.dir.path().join("conversation-history.json");
    let file = path_beside(&store);
    let index = OutsideIndex::open(file.clone());
    rig.scan(&index, &[]);
    assert_eq!(
        index.get("flagged").unwrap().first_prompt,
        FirstPrompt::Withheld(Reason::LookedSensitive)
    );
    let bytes = std::fs::read(&file).unwrap();
    let text = String::from_utf8_lossy(&bytes);
    assert!(!text.contains("219-09-9999") && !text.contains("Call back"));
    assert!(
        text.contains("tidy the readme"),
        "an ordinary first prompt is kept"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn a_sensitive_agent_keeps_no_branch_and_no_prompt() {
    let rig = Rig::new();
    let body = "{\"type\":\"agent-name\",\"agentName\":\"fred\"}\n".to_owned()
        + &conversation("cli", "/work/app", false, "inbox triage");
    rig.put("fredsid", &body, 1000);
    let index = OutsideIndex::in_memory();
    rig.scan(&index, &[]);
    let e = index.get("fredsid").unwrap();
    assert!(e.sensitive && e.branch.is_none());
    assert_eq!(
        e.first_prompt,
        FirstPrompt::Withheld(Reason::SensitiveConversation)
    );
}

#[test]
fn clear_deletes_the_file_and_first_prompts_off_drops_the_texts() {
    let rig = Rig::new();
    rig.put(
        "a",
        &conversation("cli", "/work/app", false, "tidy the readme"),
        1000,
    );
    let file = path_beside(&rig.dir.path().join("conversation-history.json"));
    let index = OutsideIndex::open(file.clone());
    rig.scan(&index, &[]);
    index.withhold_first_prompts();
    assert!(!std::fs::read_to_string(&file)
        .unwrap()
        .contains("tidy the readme"));
    index.clear();
    assert!(!Path::new(&file).exists());
    assert!(index.is_empty() && !index.ready());
}

fn plain_rig() -> (Rig, PathBuf, OutsideIndex) {
    let rig = Rig::new();
    rig.put(
        "a",
        &conversation("cli", "/work/app", false, "tidy the readme"),
        1000,
    );
    let file = path_beside(&rig.dir.path().join("conversation-history.json"));
    let index = OutsideIndex::open(file.clone());
    (rig, file, index)
}

#[test]
fn a_scan_running_when_the_switch_goes_off_stores_nothing_and_writes_no_file() {
    let (rig, file, index) = plain_rig();
    assert!(index.try_begin());
    index.clear();
    rig.scan_claimed(&index);
    assert!(index.is_empty() && !index.ready(), "the result was dropped");
    assert!(!file.exists(), "no index file after the switch went off");
    // A restart finds nothing to reload.
    let reopened = OutsideIndex::open(file.clone());
    assert!(reopened.is_empty() && !reopened.ready());
    // The claim was released: the next scan (switch on again) works.
    rig.scan(&index, &[]);
    assert_eq!(rig.sids(&index), vec!["a".to_owned()]);
}

#[test]
fn a_scan_running_when_first_prompts_go_off_stores_no_prompt_text() {
    let (rig, file, index) = plain_rig();
    assert!(index.try_begin());
    index.withhold_first_prompts();
    // The scan was configured before the setting changed.
    rig.scan_claimed(&index);
    assert_eq!(
        index.get("a").unwrap().first_prompt,
        FirstPrompt::Withheld(Reason::Off)
    );
    let text = std::fs::read_to_string(&file).unwrap();
    assert!(!text.contains("tidy the readme"), "no prompt text on disk");
}

#[test]
fn a_scan_that_changes_nothing_says_so_and_a_restart_reuses_the_rejected_set() {
    let rig = Rig::new();
    rig.put(
        "a",
        &conversation("cli", "/work/app", false, "tidy the readme"),
        1000,
    );
    rig.put(
        "job",
        &conversation("sdk-cli", "/work/app", false, "x"),
        1000,
    );
    let file = path_beside(&rig.dir.path().join("conversation-history.json"));
    let index = OutsideIndex::open(file.clone());
    assert!(rig.scan_changed(&index), "the first scan changes the list");
    assert!(
        !rig.scan_changed(&index),
        "an identical scan changes nothing"
    );
    let text = std::fs::read_to_string(&file).unwrap();
    assert!(
        text.contains("job.jsonl"),
        "the rejected file is remembered"
    );
    assert!(!text.contains("\"x\""), "metadata only");

    // A daemon restart: nothing is read again, and the list is unchanged.
    let restarted = OutsideIndex::open(file);
    let before = bytes_read_on_this_thread();
    assert!(!rig.scan_changed(&restarted));
    assert_eq!(bytes_read_on_this_thread() - before, 0);
}
