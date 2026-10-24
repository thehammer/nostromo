//! Crate-internal tests for the terminal core: who may hold an
//! [`OperatorCap`](super::OperatorCap), the audit trail's shape and rotation,
//! the PTY session's observable behaviour, daemon-restart reconciliation, and
//! the pane-registry helpers terminal leaves rely on.
//!
//! The wire behaviour (who may attach, what is broadcast, what TCP sees) is
//! pinned over real sockets in `tests/terminal_core.rs`; the tests here cover
//! the pieces that are easier to pin directly. Every shell these tests start
//! runs in a temp directory and is killed before the test ends.

use std::collections::BTreeSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use tempfile::TempDir;

use super::audit::{AuditEvent, AuditLog, RefusalChannel};
use super::session::{TerminalSession, RING_MAX_BYTES, RING_MAX_NEWLINES};
use super::store::{self, TerminalRecord, TerminalStore};
use crate::ipc::pane_registry::{PaneRegistry, SplitPosition};
use crate::ipc::protocol::{
    PaneTree, TerminalKind, TerminalRequester, TerminalStatus, TerminalTarget,
};

const WAIT: Duration = Duration::from_secs(20);

// ── helpers ───────────────────────────────────────────────────────────────────

fn wait_until(what: &str, timeout: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn count(hay: &[u8], needle: &str) -> usize {
    let needle = needle.as_bytes();
    if needle.is_empty() || hay.len() < needle.len() {
        return 0;
    }
    hay.windows(needle.len()).filter(|w| *w == needle).count()
}

fn contains(hay: &[u8], needle: &str) -> bool {
    count(hay, needle) > 0
}

/// A temp directory and its canonical path (macOS: `/var` is `/private/var`).
fn scratch_dir() -> (TempDir, PathBuf) {
    let dir = TempDir::new().expect("tempdir");
    let canonical = std::fs::canonicalize(dir.path()).expect("canonicalize");
    (dir, canonical)
}

fn argv(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

/// `/bin/sh -c script` at 80x24 in `cwd`.
fn spawn_sh(script: &str, cwd: &Path) -> Arc<TerminalSession> {
    TerminalSession::spawn_argv(&argv(&["/bin/sh", "-c", script]), cwd, &[], 80, 24)
        .expect("spawn /bin/sh")
}

/// Lines of `bytes` that are whole decimal numbers (CR stripped).
fn numbered_lines(bytes: &[u8]) -> BTreeSet<u32> {
    String::from_utf8_lossy(bytes)
        .split('\n')
        .filter_map(|l| l.trim_end_matches('\r').trim().parse::<u32>().ok())
        .collect()
}

// (`access::mint` is tested in `access.rs`'s own `#[cfg(test)]` module, so
// AP1's scan for `PeerTrust::OperatorApp` constructions reads it as test code.)

// ── audit: shape, modes, rotation ─────────────────────────────────────────────

fn opened(id: &str) -> AuditEvent {
    AuditEvent::Opened {
        terminal_id: id.into(),
        pane_id: "terminal-0a1b2c3d".into(),
        tag: "tag".into(),
        kind: TerminalKind::Local,
        requested_by: "user".into(),
        cwd: Some("/tmp".into()),
    }
}

fn fixed_clock(at: DateTime<Utc>) -> Arc<dyn Fn() -> DateTime<Utc> + Send + Sync> {
    Arc::new(move || at)
}

/// A clock that advances one second per reading.
fn ticking_clock(start: DateTime<Utc>) -> Arc<dyn Fn() -> DateTime<Utc> + Send + Sync> {
    let secs = Arc::new(AtomicI64::new(0));
    Arc::new(move || start + chrono::Duration::seconds(secs.fetch_add(1, Ordering::SeqCst)))
}

fn jsonl(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("not JSON: {l:?}: {e}")))
        .collect()
}

/// Every file in `dir` whose name starts with `terminal`.
fn audit_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("read audit dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("terminal") && n.ends_with(".jsonl"))
        })
        .collect();
    files.sort();
    files
}

fn is_rotated_name(path: &Path) -> bool {
    // terminal-<yyyymmddThhmmss>[-N].jsonl
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let Some(rest) = name
        .strip_prefix("terminal-")
        .and_then(|r| r.strip_suffix(".jsonl"))
    else {
        return false;
    };
    let (stamp, n) = match rest.split_once('-') {
        Some((stamp, n)) => (stamp, Some(n)),
        None => (rest, None),
    };
    let stamp_ok = stamp.len() == 15
        && stamp.as_bytes()[8] == b'T'
        && stamp
            .char_indices()
            .all(|(i, c)| i == 8 || c.is_ascii_digit());
    stamp_ok && n.is_none_or(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// How many bytes one `opened("t-0")` line takes under `ticking_clock`.
fn one_line_len() -> u64 {
    let (_dir, root) = scratch_dir();
    let path = root.join("audit").join("terminal.jsonl");
    let log = AuditLog::open(&path)
        .expect("open")
        .with_clock(ticking_clock(
            Utc.with_ymd_and_hms(2026, 3, 4, 5, 6, 7).unwrap(),
        ));
    log.append(&opened("t-0")).expect("append");
    std::fs::metadata(&path).expect("metadata").len()
}

#[test]
fn each_event_is_one_json_line_with_a_utc_timestamp_and_its_event_name() {
    let (_dir, root) = scratch_dir();
    let path = root.join("audit").join("terminal.jsonl");
    let at = Utc.with_ymd_and_hms(2026, 3, 4, 5, 6, 7).unwrap();
    let log = AuditLog::open(&path)
        .expect("open")
        .with_clock(fixed_clock(at));

    let events = [
        opened("t-1"),
        AuditEvent::Closed {
            terminal_id: "t-1".into(),
            pane_id: "terminal-0a1b2c3d".into(),
            tag: "tag".into(),
            kind: TerminalKind::Local,
            reason: "exited".into(),
            exit_code: Some(0),
        },
        AuditEvent::Ended {
            terminal_id: "t-2".into(),
            pane_id: "terminal-0a1b2c3e".into(),
            tag: "tag".into(),
            kind: TerminalKind::Local,
            exit_code: Some(3),
        },
        AuditEvent::Restarted {
            terminal_id: "t-3".into(),
            previous_terminal_id: "t-2".into(),
            pane_id: "terminal-0a1b2c3e".into(),
            tag: "tag".into(),
            kind: TerminalKind::Local,
        },
        AuditEvent::Refused {
            channel: RefusalChannel::Ipc,
            op: "input".into(),
            code: Some("terminal_input_forbidden".into()),
            terminal_id: Some("t-3".into()),
            focus: None,
            peer_pid: Some(4343),
            peer_exe: Some("/usr/bin/python3".into()),
            tool: None,
        },
    ];
    for e in &events {
        log.append(e).expect("append");
    }

    let raw = std::fs::read_to_string(&path).expect("read");
    assert!(raw.ends_with('\n'), "every line is newline-terminated");
    let lines = jsonl(&path);
    assert_eq!(lines.len(), events.len(), "one line per event");
    let names: Vec<&str> = lines.iter().map(|l| l["event"].as_str().unwrap()).collect();
    assert_eq!(names, ["opened", "closed", "ended", "restarted", "refused"]);
    for line in &lines {
        let ts = line["ts"].as_str().expect("ts is a string");
        let parsed = DateTime::parse_from_rfc3339(ts).expect("ts is RFC 3339");
        assert_eq!(
            parsed.with_timezone(&Utc),
            at,
            "ts comes from the log's clock"
        );
        assert!(
            ts.ends_with('Z') || ts.ends_with("+00:00"),
            "ts is UTC: {ts}"
        );
    }
}

#[test]
fn a_refused_line_names_the_channel_the_operation_the_code_and_the_peer() {
    let (_dir, root) = scratch_dir();
    let path = root.join("audit").join("terminal.jsonl");
    let log = AuditLog::open(&path).expect("open");
    log.append(&AuditEvent::Refused {
        channel: RefusalChannel::Ipc,
        op: "input".into(),
        code: Some("terminal_input_forbidden".into()),
        terminal_id: Some("t-9".into()),
        focus: None,
        peer_pid: Some(4343),
        peer_exe: Some("/usr/bin/python3".into()),
        tool: None,
    })
    .expect("append");
    log.append(&AuditEvent::Refused {
        channel: RefusalChannel::Tcp,
        op: "attach".into(),
        code: None,
        terminal_id: None,
        focus: None,
        peer_pid: None,
        peer_exe: None,
        tool: None,
    })
    .expect("append");

    let lines = jsonl(&path);
    assert_eq!(lines[0]["event"], "refused");
    assert_eq!(lines[0]["channel"], "ipc");
    assert_eq!(lines[0]["op"], "input");
    assert_eq!(lines[0]["code"], "terminal_input_forbidden");
    assert_eq!(lines[0]["terminal_id"], "t-9");
    assert_eq!(lines[0]["peer_pid"], 4343);
    assert_eq!(lines[0]["peer_exe"], "/usr/bin/python3");

    assert_eq!(lines[1]["channel"], "tcp");
    assert_eq!(lines[1]["op"], "attach");
    for absent in ["peer_pid", "peer_exe", "terminal_id", "tool", "focus"] {
        assert!(
            lines[1].get(absent).is_none_or(Value::is_null),
            "an unknown {absent} is omitted, not invented: {}",
            lines[1]
        );
    }
}

#[test]
fn the_audit_directory_is_private_to_the_user_and_so_is_the_file() {
    let (_dir, root) = scratch_dir();
    let dir = root.join("nested").join("audit");
    let path = dir.join("terminal.jsonl");
    let log = AuditLog::open(&path).expect("open creates the directory");
    log.append(&opened("t-1")).expect("append");

    let dir_mode = std::fs::metadata(&dir).expect("dir").permissions().mode() & 0o777;
    let file_mode = std::fs::metadata(&path).expect("file").permissions().mode() & 0o777;
    assert_eq!(dir_mode, 0o700, "audit directory mode");
    assert_eq!(file_mode, 0o600, "audit file mode");
}

#[test]
fn a_disabled_log_accepts_events_and_writes_nothing() {
    AuditLog::disabled()
        .append(&opened("t-1"))
        .expect("a disabled log never fails");
}

#[test]
fn a_full_file_moves_aside_to_a_timestamped_name_and_no_event_is_lost() {
    let line = one_line_len();
    let (_dir, root) = scratch_dir();
    let dir = root.join("audit");
    let path = dir.join("terminal.jsonl");
    // Two lines fit in a file, three do not.
    let max = line * 2 + line / 2;
    let log = AuditLog::open(&path)
        .expect("open")
        .with_clock(ticking_clock(
            Utc.with_ymd_and_hms(2026, 3, 4, 5, 6, 7).unwrap(),
        ))
        .with_rotation(max, 100);
    for i in 0..7 {
        log.append(&opened(&format!("t-{i}"))).expect("append");
    }

    let files = audit_files(&dir);
    let rotated: Vec<&PathBuf> = files.iter().filter(|p| is_rotated_name(p)).collect();
    assert!(
        rotated.len() >= 2,
        "7 lines at 2 per file must have rotated at least twice: {files:?}"
    );
    assert!(path.exists(), "the live file keeps its name");
    let mut ids = BTreeSet::new();
    for f in &files {
        let size = std::fs::metadata(f).expect("metadata").len();
        assert!(
            size <= max,
            "{f:?} is {size} bytes, over the {max} threshold"
        );
        for l in jsonl(f) {
            ids.insert(l["terminal_id"].as_str().unwrap().to_string());
        }
    }
    let expected: BTreeSet<String> = (0..7).map(|i| format!("t-{i}")).collect();
    assert_eq!(ids, expected, "rotation must not lose or tear a line");
}

#[test]
fn rotation_keeps_only_the_newest_files_and_deletes_the_oldest() {
    let line = one_line_len();
    let (_dir, root) = scratch_dir();
    let dir = root.join("audit");
    let log = AuditLog::open(&dir.join("terminal.jsonl"))
        .expect("open")
        .with_clock(ticking_clock(
            Utc.with_ymd_and_hms(2026, 3, 4, 5, 6, 7).unwrap(),
        ))
        // One line per file; keep 2 rotated files.
        .with_rotation(line + line / 2, 2);
    for i in 0..8 {
        log.append(&opened(&format!("t-{i}"))).expect("append");
    }

    let files = audit_files(&dir);
    let rotated = files.iter().filter(|p| is_rotated_name(p)).count();
    assert_eq!(rotated, 2, "only `keep` rotated files survive: {files:?}");
    let mut ids = BTreeSet::new();
    for f in &files {
        for l in jsonl(f) {
            ids.insert(l["terminal_id"].as_str().unwrap().to_string());
        }
    }
    let newest: BTreeSet<String> = (5..8).map(|i| format!("t-{i}")).collect();
    assert_eq!(
        ids, newest,
        "the live file plus the two newest rotated files"
    );
}

#[test]
fn several_rotations_within_one_second_never_overwrite_each_other() {
    let line = one_line_len();
    let (_dir, root) = scratch_dir();
    let dir = root.join("audit");
    let frozen = Utc.with_ymd_and_hms(2026, 3, 4, 5, 6, 7).unwrap();
    let log = AuditLog::open(&dir.join("terminal.jsonl"))
        .expect("open")
        .with_clock(fixed_clock(frozen))
        .with_rotation(line + line / 2, 100);
    for i in 0..6 {
        log.append(&opened(&format!("t-{i}"))).expect("append");
    }

    let files = audit_files(&dir);
    let total: usize = files.iter().map(|f| jsonl(f).len()).sum();
    assert_eq!(total, 6, "no line may be overwritten: {files:?}");
    assert_eq!(files.len(), 6, "one file per line: {files:?}");
}

// ── session: the PTY child ────────────────────────────────────────────────────

const _: () = assert!(RING_MAX_NEWLINES >= 10_000);
const _: () = assert!(RING_MAX_BYTES >= 4 * 1024 * 1024);

#[test]
fn a_child_that_exits_3_reports_exit_code_3() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("exit 3", &cwd);
    assert_eq!(s.wait_exit(WAIT), Some(Some(3)));
}

#[test]
fn a_child_that_exits_cleanly_reports_exit_code_0() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("exit 0", &cwd);
    assert_eq!(s.wait_exit(WAIT), Some(Some(0)));
}

#[test]
fn wait_exit_times_out_while_the_child_runs_and_kill_ends_it() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("sleep 30", &cwd);
    assert_eq!(
        s.wait_exit(Duration::from_millis(200)),
        None,
        "still running at the timeout"
    );
    s.kill();
    assert!(
        s.wait_exit(WAIT).is_some(),
        "a killed child must be reported as exited"
    );
}

#[test]
fn cat_echoes_what_is_written_to_it() {
    let (_dir, cwd) = scratch_dir();
    let s = TerminalSession::spawn_argv(&argv(&["/bin/cat"]), &cwd, &[], 80, 24).expect("spawn");
    s.write(b"hello-cat\n").expect("write");
    wait_until("cat's echo", WAIT, || {
        contains(&s.ring_bytes(), "hello-cat")
    });
    s.kill();
}

#[test]
fn input_written_to_a_session_reaches_the_process_exactly_once_per_write() {
    let (_dir, cwd) = scratch_dir();
    // Raw and without tty echo, so the only copy of a byte on the output is
    // the one `cat` writes.
    let s = spawn_sh("stty raw -echo; printf READY; exec cat", &cwd);
    wait_until("cat to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    s.write(b"ZZ9").expect("write");
    wait_until("the first echo", WAIT, || contains(&s.ring_bytes(), "ZZ9"));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(count(&s.ring_bytes(), "ZZ9"), 1, "one write, one copy");

    s.write(b"ZZ9").expect("write");
    wait_until("the second echo", WAIT, || {
        count(&s.ring_bytes(), "ZZ9") == 2
    });
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(count(&s.ring_bytes(), "ZZ9"), 2, "two writes, two copies");
    s.kill();
}

#[test]
fn a_reader_hook_sees_what_the_child_prints_from_then_on() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("stty raw -echo; printf READY; exec cat", &cwd);
    wait_until("cat to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    let seen = Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
    let sink = Arc::clone(&seen);
    s.add_reader_hook(Box::new(move |chunk| {
        sink.lock().unwrap().extend_from_slice(chunk)
    }));
    s.write(b"HOOK-1").expect("write");
    wait_until("the hook to see the echo", WAIT, || {
        contains(&seen.lock().unwrap(), "HOOK-1")
    });
    assert!(
        !contains(&seen.lock().unwrap(), "READY"),
        "a hook sees only output from after it was added"
    );
    s.kill();
}

#[test]
fn the_child_starts_in_the_requested_directory() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("printf 'WHERE:%s\\n' \"$(pwd -P)\"; sleep 30", &cwd);
    let want = format!("WHERE:{}", cwd.display());
    wait_until("the child to print its directory", WAIT, || {
        contains(&s.ring_bytes(), &want)
    });
    s.kill();
}

#[test]
fn the_child_gets_the_terminal_environment_and_any_extra_variables() {
    let (_dir, cwd) = scratch_dir();
    let s = TerminalSession::spawn_argv(
        &argv(&[
            "/bin/sh",
            "-c",
            "echo \"V=$REDD_EXTRA T=$TERM/$COLORTERM/$TERM_PROGRAM\"; sleep 30",
        ]),
        &cwd,
        &[("REDD_EXTRA".to_string(), "bar42".to_string())],
        80,
        24,
    )
    .expect("spawn");
    wait_until("the environment line", WAIT, || {
        contains(
            &s.ring_bytes(),
            "V=bar42 T=xterm-256color/truecolor/Nostromo",
        )
    });
    s.kill();
}

#[test]
fn resizing_changes_what_the_child_sees_and_what_size_reports() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("printf READY; read x; stty size; sleep 30", &cwd);
    assert_eq!(s.size(), (80, 24), "size is (cols, rows)");
    wait_until("the child to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    s.resize(100, 30).expect("resize");
    assert_eq!(s.size(), (100, 30));
    s.write(b"\n").expect("write");
    // `stty size` prints "<rows> <cols>".
    wait_until("the child to report the new size", WAIT, || {
        contains(&s.ring_bytes(), "30 100")
    });
    s.kill();
}

#[test]
fn the_replay_is_the_ring_followed_by_the_repaint_of_the_screen() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("printf 'AAA\\nBBB\\n'; sleep 30", &cwd);
    wait_until("the output", WAIT, || contains(&s.ring_bytes(), "BBB"));
    std::thread::sleep(Duration::from_millis(200));

    let mut expected = s.ring_bytes();
    expected.extend(s.repaint_bytes());
    assert_eq!(s.replay_bytes(), expected);
    assert!(
        !s.repaint_bytes().is_empty(),
        "a screen with text has a repaint"
    );
    s.kill();
}

#[test]
fn the_ring_keeps_at_least_the_last_ten_thousand_lines() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("seq 1 10500; printf 'FINISHED-RING'; sleep 30", &cwd);
    wait_until("the output to finish", WAIT, || {
        contains(&s.ring_bytes(), "FINISHED-RING")
    });

    let lines = numbered_lines(&s.replay_bytes());
    let missing: Vec<u32> = (501..=10_500)
        .filter(|n| !lines.contains(n))
        .take(5)
        .collect();
    assert!(
        missing.is_empty(),
        "the replay must retain lines 501..=10500; first missing: {missing:?}"
    );
    s.kill();
}

#[test]
fn the_ring_is_bounded_in_bytes_even_when_output_has_no_newlines() {
    let (_dir, cwd) = scratch_dir();
    let total = RING_MAX_BYTES + RING_MAX_BYTES / 8;
    let s = spawn_sh(
        &format!("head -c {total} /dev/zero | tr '\\0' x; printf 'END-OF-FLOOD'; sleep 30"),
        &cwd,
    );
    wait_until("the flood to finish", Duration::from_secs(60), || {
        contains(&s.ring_bytes(), "END-OF-FLOOD")
    });

    let ring = s.ring_bytes().len();
    assert!(
        ring <= RING_MAX_BYTES,
        "the ring holds {ring} bytes, over RING_MAX_BYTES {RING_MAX_BYTES}"
    );
    assert!(
        ring >= RING_MAX_BYTES - 64 * 1024,
        "the ring should fill to about RING_MAX_BYTES, held {ring}"
    );
    s.kill();
}

#[test]
fn the_replay_still_shows_the_alternate_screen_after_its_start_left_the_ring() {
    let (_dir, cwd) = scratch_dir();
    // Enter the alternate screen and paint ALT-SCREEN at the top, then write
    // more lines than the ring holds. Every filler line first moves the cursor
    // to row 5, so the screen never scrolls and ALT-SCREEN stays on row 1.
    let fillers = RING_MAX_NEWLINES + 1_500;
    let script = format!(
        "printf '\\033[?1049h\\033[2J\\033[HALT-SCREEN'; \
         i=0; while [ \"$i\" -lt {fillers} ]; do printf '\\033[5;1Hfiller\\n'; i=$((i+1)); done; \
         printf '\\033[10;1HFINISHED-ALT'; sleep 30"
    );
    let s = spawn_sh(&script, &cwd);
    wait_until("the output to finish", Duration::from_secs(60), || {
        contains(&s.ring_bytes(), "FINISHED-ALT")
    });

    assert!(
        !contains(&s.ring_bytes(), "ALT-SCREEN"),
        "test precondition: the ring must have evicted the start of the output"
    );

    let (cols, rows) = s.size();
    assert_eq!((cols, rows), (80, 24));
    let mut view = vt100::Parser::new(rows, cols, 0);
    view.process(&s.replay_bytes());
    assert!(
        view.screen().alternate_screen(),
        "the replay must leave a fresh terminal on the alternate screen"
    );
    let shown = view.screen().contents();
    assert!(
        shown.contains("ALT-SCREEN"),
        "a fresh terminal fed the replay must show the alternate screen's content, got: {shown:?}"
    );
    s.kill();
}

// ── store: reconciliation after a daemon stop ─────────────────────────────────

fn requester() -> TerminalRequester {
    TerminalRequester {
        kind: "user".into(),
        tag: None,
    }
}

fn local_record(id: &str, pane: &str) -> TerminalRecord {
    TerminalRecord {
        terminal_id: id.into(),
        tag: "t".into(),
        pane_id: pane.into(),
        kind: TerminalKind::Local,
        cwd: Some("/work".into()),
        label: "Terminal".into(),
        target: None,
        requested_by: requester(),
    }
}

fn ecs_target() -> TerminalTarget {
    TerminalTarget {
        project: "admin-portal".into(),
        environment: "production".into(),
        service: "scheduler".into(),
        shell_type: "shell".into(),
    }
}

fn ecs_record(id: &str, pane: &str) -> TerminalRecord {
    TerminalRecord {
        terminal_id: id.into(),
        tag: "t".into(),
        pane_id: pane.into(),
        kind: TerminalKind::Ecs,
        cwd: None,
        label: "admin-portal scheduler".into(),
        target: Some(ecs_target()),
        requested_by: requester(),
    }
}

#[test]
fn after_a_daemon_stop_a_local_terminal_is_ended_and_keeps_its_pane_and_a_remote_one_is_closed() {
    let mut panes = PaneRegistry::in_memory();
    panes.get_or_init("t");
    panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Below, "terminal-00000001")
        .expect("insert local leaf");
    panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Right, "terminal-00000002")
        .expect("insert ecs leaf");
    // The remote leaf was registered by the previous daemon; the local one is
    // the reconciliation's to register.
    panes.register_terminal_leaf("t", "terminal-00000002");

    let out = store::reconcile(
        vec![
            local_record("local-1", "terminal-00000001"),
            ecs_record("ecs-1", "terminal-00000002"),
        ],
        Some(&mut panes),
    );

    assert_eq!(out.ended.len(), 1);
    let ended = &out.ended[0];
    assert_eq!(ended.terminal_id, "local-1");
    assert_eq!(ended.tag, "t");
    assert_eq!(ended.pane_id, "terminal-00000001");
    assert_eq!(ended.kind, TerminalKind::Local);
    assert_eq!(ended.label, "Terminal");
    assert_eq!(ended.status, TerminalStatus::Ended);
    assert_eq!(ended.ended_reason.as_deref(), Some("daemon_stopped"));
    assert_eq!(ended.exit_code, None, "nobody saw it exit");

    assert_eq!(out.closed.len(), 1);
    let closed = &out.closed[0];
    assert_eq!(closed.terminal_id, "ecs-1");
    assert_eq!(closed.pane_id, "terminal-00000002");
    assert_eq!(closed.kind, TerminalKind::Ecs);
    assert_eq!(closed.reason, "daemon_stopped");
    assert_eq!(closed.target, Some(ecs_target()));

    assert_eq!(
        panes.terminal_leaves("t"),
        vec!["terminal-00000001".to_string()],
        "the local leaf is registered, the remote one is not"
    );
    let ids = panes.get("t").expect("tree").pane_ids();
    assert!(ids.contains(&"terminal-00000001".to_string()), "{ids:?}");
    assert!(
        !ids.contains(&"terminal-00000002".to_string()),
        "the remote leaf is removed from the tree: {ids:?}"
    );
    assert!(ids.contains(&"repl".to_string()));
}

#[test]
fn reconciling_without_a_pane_registry_still_reports_both_kinds() {
    let out = store::reconcile(
        vec![
            local_record("local-1", "terminal-00000001"),
            ecs_record("ecs-1", "terminal-00000002"),
        ],
        None,
    );
    assert_eq!(out.ended.len(), 1);
    assert_eq!(out.closed.len(), 1);
}

#[test]
fn the_store_returns_what_was_saved_and_nothing_when_the_file_is_missing() {
    let (_dir, root) = scratch_dir();
    let store = TerminalStore::at(root.join("daemon-terminals.json"));
    assert!(store.load().is_empty(), "a missing file is an empty store");

    let records = vec![
        local_record("local-1", "terminal-00000001"),
        ecs_record("ecs-1", "terminal-00000002"),
    ];
    store.save(&records);
    assert_eq!(store.load(), records);
    store.save(&[]);
    assert!(store.load().is_empty());
}

#[test]
fn an_unreadable_store_loads_as_empty_instead_of_stopping_the_daemon() {
    let (_dir, root) = scratch_dir();
    let path = root.join("daemon-terminals.json");
    std::fs::write(&path, b"{ this is not json").expect("write garbage");
    assert!(TerminalStore::at(&path).load().is_empty());
}

// ── pane registry: terminal leaves ────────────────────────────────────────────

fn registry_with_repl(tag: &str) -> PaneRegistry {
    let mut panes = PaneRegistry::in_memory();
    panes.get_or_init(tag);
    panes
}

#[test]
fn a_terminal_leaf_is_inserted_below_repl_by_default_position() {
    let mut panes = registry_with_repl("t");
    let tree = panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Below, "terminal-0000abcd")
        .expect("insert");
    assert_eq!(tree.pane_ids(), ["repl", "terminal-0000abcd"]);
    assert_eq!(
        panes.get("t"),
        Some(&tree),
        "the registry holds the new tree"
    );
}

#[test]
fn a_terminal_leaf_can_go_left_or_above_a_pane() {
    for position in [SplitPosition::Left, SplitPosition::Above] {
        let mut panes = registry_with_repl("t");
        let tree = panes
            .insert_terminal_leaf("t", "repl", position, "terminal-0000abcd")
            .expect("insert");
        assert_eq!(
            tree.pane_ids(),
            ["terminal-0000abcd", "repl"],
            "{position:?} puts the new leaf first"
        );
    }
}

#[test]
fn inserting_a_terminal_leaf_relative_to_an_unknown_pane_or_with_a_taken_id_fails() {
    let mut panes = registry_with_repl("t");
    assert!(panes
        .insert_terminal_leaf(
            "t",
            "no-such-pane",
            SplitPosition::Below,
            "terminal-0000abcd"
        )
        .is_err());
    panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Below, "terminal-0000abcd")
        .expect("insert");
    assert!(panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Right, "terminal-0000abcd")
        .is_err());
    assert_eq!(
        panes.get("t").expect("tree").pane_ids(),
        ["repl", "terminal-0000abcd"],
        "a failed insert changes nothing"
    );
}

#[test]
fn removing_the_only_terminal_leaf_collapses_the_split_back_to_the_repl_leaf() {
    let mut panes = registry_with_repl("t");
    panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Below, "terminal-0000abcd")
        .expect("insert");

    let tree = panes
        .remove_terminal_leaf("t", "terminal-0000abcd")
        .expect("the leaf was there");
    assert_eq!(tree, PaneTree::repl_leaf());
    assert_eq!(panes.get("t"), Some(&PaneTree::repl_leaf()));
}

#[test]
fn removing_a_terminal_leaf_keeps_its_siblings_and_leaves_no_one_child_split() {
    let mut panes = registry_with_repl("t");
    panes
        .insert_terminal_leaf("t", "repl", SplitPosition::Below, "terminal-0000000a")
        .expect("insert a");
    panes
        .insert_terminal_leaf(
            "t",
            "terminal-0000000a",
            SplitPosition::Right,
            "terminal-0000000b",
        )
        .expect("insert b");

    let tree = panes
        .remove_terminal_leaf("t", "terminal-0000000a")
        .expect("the leaf was there");
    assert_eq!(tree.pane_ids(), ["repl", "terminal-0000000b"]);
    fn no_degenerate_split(node: &PaneTree) -> bool {
        match node {
            PaneTree::Leaf { .. } => true,
            PaneTree::Split {
                children, ratios, ..
            } => {
                children.len() >= 2
                    && ratios.len() == children.len()
                    && children.iter().all(no_degenerate_split)
            }
            PaneTree::Tabs { children, .. } => children.iter().all(no_degenerate_split),
        }
    }
    assert!(no_degenerate_split(&tree), "{tree:?}");
}

#[test]
fn removing_a_leaf_that_is_not_there_changes_nothing() {
    let mut panes = registry_with_repl("t");
    assert_eq!(panes.remove_terminal_leaf("t", "terminal-deadbeef"), None);
    assert_eq!(
        panes.remove_terminal_leaf("no-such-tag", "terminal-deadbeef"),
        None
    );
    assert_eq!(panes.get("t"), Some(&PaneTree::repl_leaf()));
}

#[test]
fn registered_terminal_leaves_are_listed_per_tag_until_unregistered() {
    let mut panes = PaneRegistry::in_memory();
    assert!(panes.terminal_leaves("t").is_empty());

    panes.register_terminal_leaf("t", "terminal-00000001");
    panes.register_terminal_leaf("t", "terminal-00000002");
    panes.register_terminal_leaf("other", "terminal-00000003");
    let mut mine = panes.terminal_leaves("t");
    mine.sort();
    assert_eq!(mine, ["terminal-00000001", "terminal-00000002"]);
    assert_eq!(panes.terminal_leaves("other"), ["terminal-00000003"]);

    panes.unregister_terminal_leaf("t", "terminal-00000001");
    assert_eq!(panes.terminal_leaves("t"), ["terminal-00000002"]);
    panes.unregister_terminal_leaf("t", "terminal-00000001"); // idempotent
    assert_eq!(panes.terminal_leaves("t"), ["terminal-00000002"]);
    assert_eq!(panes.terminal_leaves("other"), ["terminal-00000003"]);
}
