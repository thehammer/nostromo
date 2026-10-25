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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use tempfile::TempDir;

use super::access::tests::cap as access_cap;
use super::audit::{AuditEvent, AuditLog, RefusalChannel};
use super::fanout::Fanout;
use super::session::{
    InputError, SignalOps, TerminalSession, MAX_INPUT_FRAME_BYTES, MAX_INPUT_QUEUED_BYTES,
    RING_MAX_BYTES, RING_MAX_NEWLINES,
};
use super::store::{self, TerminalRecord, TerminalStore};
use super::{
    OpenLocal, StreamBatch, Terminal, TerminalConfig, TerminalError, TerminalManager,
    MAX_TERMINALS, MAX_TERMINALS_PER_FOCUS,
};
use crate::ipc::orphans::{child_unreaped, Target};
use crate::ipc::pane_registry::{PaneRegistry, SplitPosition};
use crate::ipc::peer::SensitiveTags;
use crate::ipc::protocol::{
    PaneTree, ServerMsg, TerminalInfo, TerminalKind, TerminalRequester, TerminalStatus,
    TerminalTarget,
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

// ── audit: a flood of refusals is capped per channel ─────────────────────────

#[test]
fn a_flood_of_refusals_on_one_channel_is_capped_without_silencing_another() {
    use super::{TerminalConfig, TerminalManager, MAX_REFUSALS_PER_WINDOW};
    let (_tmp, dir) = scratch_dir();
    let path = dir.join("audit").join("terminal.jsonl");
    let mgr = TerminalManager::new(TerminalConfig {
        audit: AuditLog::open(&path).unwrap(),
        ..TerminalConfig::in_memory()
    });
    let mgr = mgr.lock().unwrap();
    let flood = MAX_REFUSALS_PER_WINDOW as usize + 30;
    // A peer-sent id that is not id-shaped is not written as given.
    let junk_id = "x".repeat(4096);
    for _ in 0..flood {
        mgr.audit_refused(
            RefusalChannel::Tcp,
            "input",
            None,
            Some(&junk_id),
            None,
            None,
        );
    }
    mgr.audit_refused(
        RefusalChannel::Ipc,
        "input",
        None,
        Some("t-9"),
        Some(4343),
        None,
    );

    let lines = jsonl(&path);
    let refused = |channel: &str| {
        lines
            .iter()
            .filter(|l| l["event"] == "refused" && l["channel"] == channel)
            .count()
    };
    assert_eq!(refused("tcp"), MAX_REFUSALS_PER_WINDOW as usize);
    assert_eq!(
        refused("ipc"),
        1,
        "the tcp flood must not use up the ipc budget"
    );
    assert_eq!(
        lines
            .iter()
            .filter(|l| l["event"] == "refusal_limit_reached" && l["channel"] == "tcp")
            .count(),
        1
    );
    assert!(lines.iter().all(|l| !l.to_string().contains(&junk_id)));
}

// ── signals: nothing is ever sent to a reaped child (T1F-1) ─────────────────────
//
// A terminal's child pid is only ours until the waiter reaps it: after that the
// kernel may hand the pid to a stranger. These tests simulate the worst case, a
// probe that still says "unreaped" (what a reused pid looks like), and require
// that no signal goes out anyway.

/// Every signal a session tried to send, in order, with when.
type Sent = Arc<Mutex<Vec<(Instant, Target, i32)>>>;

/// `SignalOps` that record each signal; with `forward` they also deliver it
/// (so the child really dies) using `unreaped` as the "still ours?" probe.
fn recording_ops(unreaped: fn(u32) -> bool, forward: bool) -> (Sent, SignalOps) {
    let sent: Sent = Arc::default();
    let log = Arc::clone(&sent);
    let ops = SignalOps::with(unreaped, move |target, sig| {
        log.lock().unwrap().push((Instant::now(), target, sig));
        if forward {
            target.signal(sig);
        }
    });
    (sent, ops)
}

fn signals_of(sent: &Sent) -> Vec<(Target, i32)> {
    sent.lock()
        .unwrap()
        .iter()
        .map(|(_, target, sig)| (*target, *sig))
        .collect()
}

/// A probe that always answers "still our unreaped child".
fn looks_unreaped(_pid: u32) -> bool {
    true
}

fn spawn_with(parts: &[&str], cwd: &Path, ops: SignalOps) -> Arc<TerminalSession> {
    TerminalSession::spawn_argv_with(&argv(parts), cwd, &[], 80, 24, ops).expect("spawn")
}

fn sh_with(script: &str, cwd: &Path, ops: SignalOps) -> Arc<TerminalSession> {
    spawn_with(&["/bin/sh", "-c", script], cwd, ops)
}

/// A session whose shell has exited and been reaped while a HUP-proof
/// background job still holds the terminal: for about a second the session is
/// reaped but not yet `exited`. (The job ends by itself after 3 s.)
fn reaped_but_not_exited(cwd: &Path, ops: SignalOps) -> Arc<TerminalSession> {
    let s = sh_with("trap '' HUP; sleep 3 & exit 0", cwd, ops);
    wait_until("the shell to be reaped", WAIT, || s.is_reaped());
    assert!(
        !s.is_exited(),
        "test precondition: the session must still be waiting for its output to drain"
    );
    s
}

/// The session has ended and its reader has stopped, so its kill thread has
/// run to the end of its decisions.
fn wait_closed(s: &TerminalSession) {
    assert!(s.wait_exit(WAIT).is_some(), "the session never ended");
    wait_until("the reader to stop", WAIT, || s.reader_finished());
}

#[test]
fn killing_a_session_whose_child_was_already_reaped_sends_no_signal_even_if_its_pid_looks_live() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(looks_unreaped, false);
    let s = reaped_but_not_exited(&cwd, ops);

    s.kill();
    wait_closed(&s);

    assert_eq!(
        signals_of(&sent),
        vec![],
        "a reaped child's pid may belong to a stranger now"
    );
}

/// A manager-owned terminal (hand-made, so no real shell is needed besides the
/// session itself). The session carries its own signal ops.
fn adopt(
    mgr: &mut TerminalManager,
    tag: &str,
    n: u32,
    status: TerminalStatus,
    session: Option<Arc<TerminalSession>>,
    cwd: &Path,
) -> String {
    let terminal_id = format!("hand-made-{tag}-{n}");
    let info = TerminalInfo {
        terminal_id: terminal_id.clone(),
        tag: tag.to_string(),
        pane_id: format!("terminal-{n:08x}"),
        kind: TerminalKind::Local,
        label: "Terminal".into(),
        cwd: Some(cwd.display().to_string()),
        target: None,
        status,
        exit_code: None,
        ended_reason: None,
        cols: 80,
        rows: 24,
        requested_by: requester(),
        opened_by_request: None,
    };
    let fanout = Fanout::idle(&terminal_id, Arc::new(Mutex::new(None)));
    mgr.terminals.insert(
        terminal_id.clone(),
        Terminal {
            info,
            session,
            fanout,
        },
    );
    terminal_id
}

fn session_of(mgr: &Arc<Mutex<TerminalManager>>, terminal_id: &str) -> Arc<TerminalSession> {
    mgr.lock()
        .unwrap()
        .terminals
        .get(terminal_id)
        .and_then(|t| t.session.clone())
        .expect("a terminal with a session")
}

/// Shut the manager down and wait for every shell it started to be gone.
fn shut_down(mgr: &Arc<Mutex<TerminalManager>>) {
    let sessions: Vec<Arc<TerminalSession>> = mgr
        .lock()
        .unwrap()
        .terminals
        .values()
        .filter_map(|t| t.session.clone())
        .collect();
    mgr.lock().unwrap().shutdown();
    for s in sessions {
        assert!(
            s.wait_exit(WAIT).is_some(),
            "a shell outlived the manager's shutdown"
        );
    }
}

#[test]
fn closing_a_terminal_whose_shell_was_already_reaped_sends_no_signal() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(looks_unreaped, false);
    let s = reaped_but_not_exited(&cwd, ops);
    let mgr = TerminalManager::in_memory();
    let id = adopt(
        &mut mgr.lock().unwrap(),
        "t",
        1,
        TerminalStatus::Running,
        Some(Arc::clone(&s)),
        &cwd,
    );

    mgr.lock()
        .unwrap()
        .close(&access_cap(), &id)
        .expect("close");
    wait_closed(&s);

    assert_eq!(signals_of(&sent), vec![]);
}

#[test]
fn shutting_down_with_a_terminal_whose_shell_was_already_reaped_sends_no_signal() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(looks_unreaped, false);
    let s = reaped_but_not_exited(&cwd, ops);
    let mgr = TerminalManager::in_memory();
    adopt(
        &mut mgr.lock().unwrap(),
        "t",
        1,
        TerminalStatus::Running,
        Some(Arc::clone(&s)),
        &cwd,
    );

    mgr.lock().unwrap().shutdown();
    wait_closed(&s);

    assert_eq!(signals_of(&sent), vec![]);
}

#[test]
fn restarting_an_ended_terminal_whose_shell_was_reaped_signals_nothing() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(looks_unreaped, false);
    let old = reaped_but_not_exited(&cwd, ops.clone());
    let mgr = TerminalManager::in_memory();
    let new_id = {
        let mut m = mgr.lock().unwrap();
        // The replacement shell also reports to the recorder, so it must not be
        // signalled either until the test stops it by hand below.
        m.signals = ops;
        let old_id = adopt(
            &mut m,
            "t",
            1,
            TerminalStatus::Ended,
            Some(Arc::clone(&old)),
            &cwd,
        );
        let fresh = m.restart(&access_cap(), &old_id).expect("restart");
        assert!(m.info(&old_id).is_none(), "the old id is gone");
        fresh.terminal_id
    };
    wait_closed(&old);
    let fresh = session_of(&mgr, &new_id);

    assert_eq!(
        signals_of(&sent),
        vec![],
        "restart must not signal the reaped shell it replaces"
    );

    // The replacement is a real shell of ours: end it directly (a recorder that
    // does not forward would swallow a close).
    let pid = fresh.pid().expect("the replacement has a pid");
    // SAFETY: `pid` is a child this test started and has not reaped.
    unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    assert!(fresh.wait_exit(WAIT).is_some());
}

#[test]
fn a_live_terminal_is_hung_up_through_its_group_and_pid_and_never_escalated_when_it_exits() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(child_unreaped, true);
    let s = spawn_with(&["/bin/cat"], &cwd, ops);
    let pid = s.pid().expect("pid");

    s.kill();
    assert!(
        s.wait_exit(WAIT).is_some(),
        "SIGHUP must end a shell that does not ignore it"
    );
    wait_closed(&s);
    // Longer than the kill grace: an escalation that was going to follow would
    // be sent by now.
    std::thread::sleep(Duration::from_millis(2500));

    let sent = sent.lock().unwrap();
    let signals: Vec<(Target, i32)> = sent.iter().map(|(_, t, sig)| (*t, *sig)).collect();
    assert!(
        signals.contains(&(Target::Group(pid), libc::SIGHUP)),
        "{signals:?}"
    );
    assert!(
        signals.contains(&(Target::Pid(pid), libc::SIGHUP)),
        "{signals:?}"
    );
    // A SIGKILL sweep of the group at the moment the shell exits is by design
    // (it takes whatever the shell left behind). What must not happen is the
    // grace escalation: a SIGKILL a grace period after the SIGHUP.
    let hup_at = sent
        .iter()
        .find(|(_, _, sig)| *sig == libc::SIGHUP)
        .map(|(at, _, _)| *at)
        .expect("a SIGHUP");
    for (at, _, sig) in sent.iter().filter(|(_, _, sig)| *sig != libc::SIGHUP) {
        assert_eq!(*sig, libc::SIGKILL, "{signals:?}");
        assert!(
            at.duration_since(hup_at) < Duration::from_millis(1500),
            "a shell that exited on SIGHUP was SIGKILLed a grace period later: {signals:?}"
        );
    }
}

#[test]
fn closing_or_shutting_down_a_live_terminal_through_the_manager_ends_its_process() {
    let (_dir, cwd) = scratch_dir();
    let closed = spawn_with(&["/bin/cat"], &cwd, SignalOps::real());
    let stopped = spawn_with(&["/bin/cat"], &cwd, SignalOps::real());
    let mgr = TerminalManager::in_memory();
    {
        let mut m = mgr.lock().unwrap();
        let a = adopt(
            &mut m,
            "t",
            1,
            TerminalStatus::Running,
            Some(Arc::clone(&closed)),
            &cwd,
        );
        adopt(
            &mut m,
            "t",
            2,
            TerminalStatus::Running,
            Some(Arc::clone(&stopped)),
            &cwd,
        );
        m.close(&access_cap(), &a).expect("close");
        m.shutdown();
    }
    assert!(closed.wait_exit(WAIT).is_some(), "close ends the process");
    assert!(
        stopped.wait_exit(WAIT).is_some(),
        "shutdown ends the process"
    );
}

#[test]
fn a_shell_that_ignores_hangup_is_sigkilled_through_its_group_after_the_grace() {
    let (_dir, cwd) = scratch_dir();
    let (sent, ops) = recording_ops(child_unreaped, true);
    // The trap is in place before READY is printed, so the HUP below is ignored.
    let s = sh_with("trap '' HUP; echo READY; sleep 300", &cwd, ops);
    wait_until("the shell to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });
    let pid = s.pid().expect("pid");

    s.kill();
    assert!(
        s.wait_exit(WAIT).is_some(),
        "SIGKILL must end a shell that ignores SIGHUP"
    );
    wait_closed(&s);

    let sent = sent.lock().unwrap();
    let first = |sig: i32| {
        sent.iter()
            .find(|(_, _, s)| *s == sig)
            .map(|(at, _, _)| *at)
            .unwrap_or_else(|| panic!("no signal {sig} was sent: {sent:?}"))
    };
    let (hup_at, kill_at) = (first(libc::SIGHUP), first(libc::SIGKILL));
    assert!(
        kill_at.duration_since(hup_at) >= Duration::from_millis(1500),
        "SIGKILL must wait out the grace after SIGHUP"
    );
    assert!(
        sent.iter()
            .any(|(_, t, s)| *t == Target::Group(pid) && *s == libc::SIGKILL),
        "the escalation goes to the whole group: {sent:?}"
    );
}

// ── closing ends the process group and the reader thread (T1F-4) ────────────────

/// Is `pid` gone: no such process, or a zombie its new parent has yet to reap?
fn process_is_gone(pid: u32) -> bool {
    // SAFETY: signal 0 only probes for existence.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc != 0 {
        return std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
    }
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|stat| {
            stat.rsplit_once(')')
                .map(|(_, rest)| rest.trim_start().starts_with('Z'))
        })
        .unwrap_or(false)
}

/// Kills a process the test started if it is still around when the test ends
/// (including when an assertion failed), so no long sleeper outlives the run.
struct StrayGuard(u32);

impl Drop for StrayGuard {
    fn drop(&mut self) {
        if !process_is_gone(self.0) {
            // SAFETY: a process this test started, seconds ago.
            unsafe { libc::kill(self.0 as libc::pid_t, libc::SIGKILL) };
        }
    }
}

/// The pid a script printed as `<label>=<pid>`.
fn printed_pid(s: &TerminalSession, label: &str) -> u32 {
    let needle = format!("{label}=");
    let mut pid = None;
    wait_until(&format!("the script to print {label}"), WAIT, || {
        let ring = String::from_utf8_lossy(&s.ring_bytes()).into_owned();
        pid = ring.split(needle.as_str()).nth(1).and_then(|rest| {
            let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
            // Only a complete number: something must follow its last digit.
            (rest.len() > digits.len())
                .then(|| digits.parse().ok())
                .flatten()
        });
        pid.is_some()
    });
    pid.expect("printed")
}

#[test]
fn closing_a_terminal_ends_its_background_job_and_stops_the_reader() {
    let (_dir, cwd) = scratch_dir();
    let s = sh_with("sleep 300 & echo SLEEPER=$!; wait", &cwd, SignalOps::real());
    let sleeper = printed_pid(&s, "SLEEPER");
    let _guard = StrayGuard(sleeper);

    s.kill();

    wait_until("the background job to be gone", WAIT, || {
        process_is_gone(sleeper)
    });
    wait_until("the reader thread to finish", WAIT, || s.reader_finished());
    assert!(s.wait_exit(WAIT).is_some());
}

#[test]
fn closing_a_terminal_sigkills_a_background_job_that_ignores_hangup() {
    let (_dir, cwd) = scratch_dir();
    // The shell dies of SIGHUP (it does not ignore it); the job does, so only a
    // SIGKILL to the group after the shell exits can end it.
    let s = sh_with(
        "(trap '' HUP; echo JOBREADY; exec sleep 300) & echo SLEEPER=$!; wait",
        &cwd,
        SignalOps::real(),
    );
    wait_until("the job to ignore HUP", WAIT, || {
        contains(&s.ring_bytes(), "JOBREADY")
    });
    let sleeper = printed_pid(&s, "SLEEPER");
    let _guard = StrayGuard(sleeper);

    s.kill();

    wait_until("the HUP-proof job to be gone", WAIT, || {
        process_is_gone(sleeper)
    });
    wait_until("the reader thread to finish", WAIT, || s.reader_finished());
}

#[test]
fn a_job_that_escaped_the_group_and_holds_the_tty_does_not_keep_the_reader_alive() {
    let (_dir, cwd) = scratch_dir();
    // `setsid` moves the job to its own session: no group signal reaches it,
    // yet it keeps the terminal's slave open, so the reader never sees EOF.
    let s = sh_with(
        "setsid sh -c 'echo ESCAPEE=$$; exec sleep 300' & wait",
        &cwd,
        SignalOps::real(),
    );
    let escapee = printed_pid(&s, "ESCAPEE");
    let _guard = StrayGuard(escapee);

    s.kill();

    wait_until("the reader thread to stop", WAIT, || s.reader_finished());
    assert!(s.wait_exit(WAIT).is_some());
    assert!(
        !process_is_gone(escapee),
        "test precondition: the escapee must have outlived the close, or this proves nothing"
    );
}

// ── input and terminal-count caps, with content-free refusals (T1F-3) ───────────

/// Bytes shaped like keystrokes a user would be upset to see leak.
fn secret_bytes(len: usize) -> Vec<u8> {
    b"SECRET-KEYSTROKES-"
        .iter()
        .copied()
        .cycle()
        .take(len)
        .collect()
}

#[test]
fn a_write_over_the_frame_limit_is_refused_and_queues_nothing_while_one_at_the_limit_is_taken() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("stty raw -echo; printf READY; exec cat", &cwd);
    wait_until("cat to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    let err = s
        .write(&secret_bytes(MAX_INPUT_FRAME_BYTES + 1))
        .expect_err("one byte over the frame limit");
    assert_eq!(err, InputError::TooLarge);
    assert!(
        !format!("{err:?}").contains("SECRET"),
        "the refusal must not carry the input"
    );

    s.write(&vec![b'a'; MAX_INPUT_FRAME_BYTES])
        .expect("a frame exactly at the limit is accepted");
    s.write(b"AFTER-9").expect("a small write still works");
    wait_until("cat to echo the later write", WAIT, || {
        contains(&s.ring_bytes(), "AFTER-9")
    });
    // `cat` handles input in order: had the refused frame been queued, its
    // echo would be here before AFTER-9.
    assert!(
        !contains(&s.ring_bytes(), "SECRET-KEYSTROKES"),
        "a refused write must queue nothing"
    );
    s.kill();
}

#[test]
fn input_queued_for_a_child_that_is_not_reading_is_capped_in_bytes_and_released_once_it_reads() {
    let (_dir, cwd) = scratch_dir();
    // Reads nothing for 3 s, then discards everything it is sent.
    let s = spawn_sh(
        "stty raw -echo; printf READY; sleep 3; exec cat >/dev/null",
        &cwd,
    );
    wait_until("the shell to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    // 200 KiB frames: the 256-write count limit could take 50 MiB of them.
    let frame = vec![b'q'; 200 * 1024];
    let mut accepted = 0usize;
    let refused = loop {
        match s.write(&frame) {
            Ok(()) => accepted += 1,
            Err(e) => break e,
        }
        assert!(
            accepted < 64,
            "{accepted} frames of 200 KiB were queued for a child that is not reading"
        );
    };
    assert_eq!(refused, InputError::Busy);
    assert!(
        accepted >= 1 && accepted * frame.len() <= MAX_INPUT_QUEUED_BYTES + 8 * 1024 * 1024,
        "accepted {accepted} frames before refusing"
    );

    wait_until("the queue to drain once the child reads", WAIT, || {
        s.write(&frame).is_ok()
    });
    s.kill();
}

#[test]
fn many_small_writes_to_a_child_that_is_not_reading_end_in_busy() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("stty raw -echo; printf READY; sleep 30", &cwd);
    wait_until("the shell to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });

    // 2 KiB frames: the 256-write count limit comes before the byte limit.
    let small = vec![b's'; 2048];
    let mut accepted = 0usize;
    loop {
        match s.write(&small) {
            Ok(()) => accepted += 1,
            Err(e) => {
                assert_eq!(e, InputError::Busy);
                break;
            }
        }
        assert!(
            accepted < 4000,
            "{accepted} small writes were queued for a child that is not reading"
        );
    }
    s.kill();
}

#[test]
fn the_manager_gives_oversized_and_backed_up_input_their_own_content_free_codes() {
    let (_dir, cwd) = scratch_dir();
    let s = spawn_sh("stty raw -echo; printf READY; sleep 30", &cwd);
    wait_until("the shell to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });
    let mgr = TerminalManager::in_memory();
    let id = adopt(
        &mut mgr.lock().unwrap(),
        "t",
        1,
        TerminalStatus::Running,
        Some(Arc::clone(&s)),
        &cwd,
    );
    let cap = access_cap();

    let too_large = mgr
        .lock()
        .unwrap()
        .input(&cap, &id, &secret_bytes(MAX_INPUT_FRAME_BYTES + 1))
        .expect_err("over the frame limit");
    assert_eq!(too_large, TerminalError::InputTooLarge);
    assert_eq!(too_large.code(), "terminal_input_too_large");

    let frame = secret_bytes(200 * 1024);
    let mut accepted = 0usize;
    let busy = loop {
        match mgr.lock().unwrap().input(&cap, &id, &frame) {
            Ok(()) => accepted += 1,
            Err(e) => break e,
        }
        assert!(accepted < 64, "no refusal after {accepted} frames");
    };
    assert_eq!(busy, TerminalError::InputBusy);
    assert_eq!(busy.code(), "terminal_input_busy");

    for refusal in [too_large, busy] {
        let shown = format!("{refusal:?} {}", refusal.code());
        assert!(!shown.contains("SECRET"), "{shown}");
    }
    s.kill();
}

fn open_in(cwd: &Path, tag: &str) -> OpenLocal {
    OpenLocal {
        tag: tag.into(),
        cwd: Some(cwd.display().to_string()),
        ..OpenLocal::default()
    }
}

#[test]
fn a_focus_may_have_eight_terminals_and_the_ninth_is_refused_without_a_leaf_or_a_process() {
    let (_tmp, cwd) = scratch_dir();
    let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    let mgr = TerminalManager::new(TerminalConfig {
        pane_registry: Some(Arc::clone(&panes)),
        ..TerminalConfig::in_memory()
    });
    let cap = access_cap();
    for i in 0..MAX_TERMINALS_PER_FOCUS {
        mgr.lock()
            .unwrap()
            .open_local(&cap, open_in(&cwd, "busy-focus"))
            .unwrap_or_else(|e| panic!("terminal {} of the focus was refused: {e:?}", i + 1));
    }
    let leaves = panes.lock().unwrap().pane_ids("busy-focus");
    assert_eq!(leaves.len(), MAX_TERMINALS_PER_FOCUS + 1, "repl plus 8");

    let refused = mgr
        .lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "busy-focus"))
        .expect_err("the ninth terminal for one focus");
    assert_eq!(refused, TerminalError::TooManyTerminals);
    assert_eq!(refused.code(), "terminal_limit_reached");
    let agent = mgr
        .lock()
        .unwrap()
        .open_local_for_agent("busy-focus", Some(cwd.clone()))
        .expect_err("an agent's open counts against the same limit");
    assert_eq!(agent, TerminalError::TooManyTerminals);

    assert_eq!(
        panes.lock().unwrap().pane_ids("busy-focus"),
        leaves,
        "a refused open places no leaf"
    );
    assert_eq!(
        mgr.lock().unwrap().list().len(),
        MAX_TERMINALS_PER_FOCUS,
        "a refused open starts no terminal"
    );

    // Another focus is unaffected, and closing one frees a slot.
    let other = mgr
        .lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "calm-focus"))
        .expect("a different focus can still open");
    assert_eq!(other.tag, "calm-focus");
    let victim = mgr
        .lock()
        .unwrap()
        .list()
        .into_iter()
        .find(|t| t.tag == "busy-focus")
        .expect("one of the busy focus's terminals")
        .terminal_id;
    mgr.lock().unwrap().close(&cap, &victim).expect("close");
    mgr.lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "busy-focus"))
        .expect("room again after a close");

    shut_down(&mgr);
}

#[test]
fn the_daemon_wide_limit_refuses_a_terminal_past_the_total_whatever_the_focus() {
    let (_tmp, cwd) = scratch_dir();
    let mgr = TerminalManager::in_memory();
    {
        // One short of the total, spread so no focus is at its own limit (ended
        // terminals count: they keep a pane, a ring and a screen model).
        let mut m = mgr.lock().unwrap();
        for n in 0..(MAX_TERMINALS as u32 - 1) {
            adopt(
                &mut m,
                &format!("focus-{}", n % 8),
                n,
                TerminalStatus::Ended,
                None,
                &cwd,
            );
        }
    }
    let cap = access_cap();
    mgr.lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "fresh-focus"))
        .expect("the last slot is still available");

    let refused = mgr
        .lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "another-fresh-focus"))
        .expect_err("past the daemon-wide total");
    assert_eq!(refused, TerminalError::TooManyTerminals);
    assert_eq!(refused.code(), "terminal_limit_reached");
    let agent = mgr
        .lock()
        .unwrap()
        .open_local_for_agent("yet-another-focus", Some(cwd.clone()))
        .expect_err("an agent's open counts too");
    assert_eq!(agent, TerminalError::TooManyTerminals);
    assert_eq!(mgr.lock().unwrap().list().len(), MAX_TERMINALS);

    shut_down(&mgr);
}

// ── reconcile settles the records against the pane tree (T1F-5) ─────────────────
//
// The pane tree and the terminal store are written one after the other, so a
// crash can leave either one ahead of the other.

/// `tag` with a `repl` leaf and one terminal leaf per `leaves` entry.
fn registry_with_leaves(tag: &str, leaves: &[&str]) -> PaneRegistry {
    let mut panes = registry_with_repl(tag);
    for leaf in leaves {
        panes
            .insert_terminal_leaf(tag, "repl", SplitPosition::Below, leaf)
            .expect("insert leaf");
    }
    panes
}

#[test]
fn a_terminal_leaf_with_no_record_is_removed_from_the_tree_and_the_split_collapses() {
    // The daemon crashed after placing the leaf and before saving the record.
    let mut panes = registry_with_leaves("t", &["terminal-0000000a"]);
    panes.register_terminal_leaf("t", "terminal-0000000a");

    let out = store::reconcile(vec![], Some(&mut panes));

    assert!(out.ended.is_empty() && out.closed.is_empty(), "{out:?}");
    assert_eq!(
        panes.get("t"),
        Some(&PaneTree::repl_leaf()),
        "the orphan leaf is gone and the tree collapsed back to repl"
    );
    assert!(panes.terminal_leaves("t").is_empty());
}

#[test]
fn a_record_whose_leaf_is_not_in_the_tree_is_closed_pane_missing_and_not_ended() {
    // The daemon crashed after the leaf was removed and before the record was.
    let mut panes = registry_with_leaves("t", &["terminal-0000000a"]);
    let out = store::reconcile(
        vec![
            local_record("kept", "terminal-0000000a"),
            local_record("gone-local", "terminal-0000000b"),
            ecs_record("gone-ecs", "terminal-0000000c"),
        ],
        Some(&mut panes),
    );

    let ended: Vec<&str> = out.ended.iter().map(|t| t.terminal_id.as_str()).collect();
    assert_eq!(
        ended,
        ["kept"],
        "only the terminal whose leaf exists is ended"
    );
    let mut closed: Vec<(&str, &str)> = out
        .closed
        .iter()
        .map(|c| (c.terminal_id.as_str(), c.reason.as_str()))
        .collect();
    closed.sort();
    assert_eq!(
        closed,
        [("gone-ecs", "pane_missing"), ("gone-local", "pane_missing")],
        "a record without a leaf is closed pane_missing whatever its kind"
    );
    assert_eq!(store::PANE_MISSING, "pane_missing");
    assert_eq!(
        panes.get("t").expect("tree").pane_ids(),
        ["repl", "terminal-0000000a"],
        "the tree keeps the leaf that has a record"
    );
}

#[test]
fn a_record_for_a_focus_that_has_no_pane_tree_at_all_is_closed_pane_missing() {
    let mut panes = PaneRegistry::in_memory();
    let out = store::reconcile(
        vec![local_record("orphan", "terminal-0000000a")],
        Some(&mut panes),
    );
    assert!(out.ended.is_empty());
    assert_eq!(out.closed.len(), 1);
    assert_eq!(out.closed[0].reason, "pane_missing");
}

#[test]
fn reconcile_never_removes_a_pane_that_is_not_a_terminal_leaf() {
    let mut panes = registry_with_leaves("t", &["terminal-0000000a"]);
    for (pane, position) in [
        ("notes", SplitPosition::Right),
        // Terminal-looking, but not what the manager mints (`terminal-` + 8 hex).
        ("terminal-notes", SplitPosition::Right),
        ("terminal-1234567", SplitPosition::Below),
        ("terminal-123456789", SplitPosition::Below),
    ] {
        // `insert_terminal_leaf` is the manager's own placement: `create_pane`
        // refuses the reserved `terminal-` prefix to agents.
        panes
            .insert_terminal_leaf("t", "repl", position, pane)
            .expect("create pane");
    }

    // No record claims anything: only the real terminal leaf may go.
    store::reconcile(vec![], Some(&mut panes));

    let mut left = panes.get("t").expect("tree").pane_ids();
    left.sort();
    assert_eq!(
        left,
        [
            "notes",
            "repl",
            "terminal-1234567",
            "terminal-123456789",
            "terminal-notes"
        ]
    );
}

/// A manager over a real audit file, a store holding `records` and `panes`.
struct Rig {
    mgr: Arc<Mutex<TerminalManager>>,
    store: TerminalStore,
    audit_path: PathBuf,
    _tmp: TempDir,
}

fn rig(records: &[TerminalRecord], panes: PaneRegistry) -> Rig {
    let (tmp, root) = scratch_dir();
    let audit_path = root.join("audit").join("terminal.jsonl");
    let store = TerminalStore::at(root.join("daemon-terminals.json"));
    store.save(records);
    let mgr = TerminalManager::new(TerminalConfig {
        audit: AuditLog::open(&audit_path).expect("open the audit log"),
        store: store.clone(),
        pane_registry: Some(Arc::new(Mutex::new(panes))),
    });
    Rig {
        mgr,
        store,
        audit_path,
        _tmp: tmp,
    }
}

#[test]
fn the_manager_reconciles_a_leafless_record_into_a_closed_terminal_audits_it_and_forgets_it() {
    let r = rig(
        &[
            local_record("kept", "terminal-0000000a"),
            local_record("gone", "terminal-0000000b"),
        ],
        registry_with_leaves("t", &["terminal-0000000a"]),
    );

    r.mgr.lock().unwrap().reconcile();

    let m = r.mgr.lock().unwrap();
    let listed: Vec<String> = m.list().into_iter().map(|t| t.terminal_id).collect();
    assert_eq!(
        listed,
        ["kept"],
        "no terminal is listed for the missing pane"
    );
    match m.terminal_list_msg() {
        ServerMsg::TerminalList { closed, .. } => {
            assert_eq!(closed.len(), 1);
            assert_eq!(closed[0].terminal_id, "gone");
            assert_eq!(closed[0].reason, "pane_missing");
        }
        other => panic!("not a terminal list: {other:?}"),
    }
    drop(m);

    let lines = jsonl(&r.audit_path);
    let closed: Vec<&Value> = lines.iter().filter(|l| l["event"] == "closed").collect();
    assert_eq!(closed.len(), 1, "{lines:?}");
    assert_eq!(closed[0]["terminal_id"], "gone");
    assert_eq!(closed[0]["reason"], "pane_missing");
    assert!(
        r.store.load().iter().all(|rec| rec.terminal_id != "gone"),
        "the closed record is not kept for the next start"
    );
}

#[test]
fn the_manager_reconciles_a_record_less_leaf_away_and_lists_no_terminal_for_it() {
    let r = rig(&[], registry_with_leaves("t", &["terminal-0000000a"]));
    let panes = {
        let m = r.mgr.lock().unwrap();
        Arc::clone(m.panes.as_ref().expect("a pane registry"))
    };

    r.mgr.lock().unwrap().reconcile();

    assert!(r.mgr.lock().unwrap().list().is_empty());
    assert_eq!(
        panes.lock().unwrap().get("t"),
        Some(&PaneTree::repl_leaf()),
        "the orphan leaf is removed from the tree"
    );
}

// ── audit: fail closed, daemon_stopped, sensitive tags (T1F-6) ──────────────────

#[test]
fn an_audit_log_that_cannot_be_opened_is_an_error_not_a_silent_no_op() {
    let (_tmp, root) = scratch_dir();

    // The live path is a directory.
    let live = root.join("audit").join("terminal.jsonl");
    std::fs::create_dir_all(&live).expect("make the live path a directory");
    assert!(AuditLog::open(&live).is_err());

    // The audit directory's parent is a regular file.
    let file = root.join("not-a-directory");
    std::fs::write(&file, b"x").expect("write");
    assert!(AuditLog::open(&file.join("terminal.jsonl")).is_err());
}

#[test]
fn opening_the_audit_log_creates_the_live_file_at_once_and_privately() {
    let (_tmp, root) = scratch_dir();
    let path = root.join("audit").join("terminal.jsonl");

    AuditLog::open(&path).expect("open");

    let mode = std::fs::metadata(&path)
        .expect("the file exists")
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn with_no_usable_audit_log_a_terminal_is_not_opened_for_the_app_or_for_an_agent() {
    let (_tmp, cwd) = scratch_dir();
    let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    let mgr = TerminalManager::new(TerminalConfig {
        audit: AuditLog::unavailable(),
        pane_registry: Some(Arc::clone(&panes)),
        ..TerminalConfig::in_memory()
    });
    let mut m = mgr.lock().unwrap();

    let app = m
        .open_local(&access_cap(), open_in(&cwd, "t"))
        .expect_err("the app's open needs an audit trail");
    assert_eq!(app, TerminalError::AuditUnavailable);
    assert_eq!(app.code(), "terminal_audit_unavailable");
    let agent = m
        .open_local_for_agent("t", Some(cwd.clone()))
        .expect_err("an agent's open needs one too");
    assert_eq!(agent, TerminalError::AuditUnavailable);

    assert!(m.list().is_empty(), "no terminal was started");
    assert!(
        panes
            .lock()
            .unwrap()
            .pane_ids("t")
            .iter()
            .all(|p| !p.starts_with("terminal-")),
        "no leaf was placed"
    );
}

#[test]
fn an_audit_file_that_becomes_unwritable_stops_new_terminals_until_it_is_writable_again() {
    let (_tmp, root) = scratch_dir();
    let cwd = root.join("work");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let audit_path = root.join("audit").join("terminal.jsonl");
    let mgr = TerminalManager::new(TerminalConfig {
        audit: AuditLog::open(&audit_path).expect("open the audit log"),
        ..TerminalConfig::in_memory()
    });
    let cap = access_cap();

    // Something replaces the live file with a directory.
    std::fs::remove_file(&audit_path).expect("remove the live file");
    std::fs::create_dir(&audit_path).expect("replace it with a directory");
    let refused = mgr
        .lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "t"))
        .expect_err("the audit file cannot be written");
    assert_eq!(refused, TerminalError::AuditUnavailable);
    assert!(mgr.lock().unwrap().list().is_empty());

    // Put things right: opening works again, and is audited.
    std::fs::remove_dir(&audit_path).expect("remove the directory");
    mgr.lock()
        .unwrap()
        .open_local(&cap, open_in(&cwd, "t"))
        .expect("a writable audit file lets terminals open again");
    assert!(jsonl(&audit_path).iter().any(|l| l["event"] == "opened"));

    shut_down(&mgr);
}

#[test]
fn after_a_daemon_stop_each_terminal_is_audited_without_any_content() {
    let r = rig(
        &[
            local_record("local-1", "terminal-00000001"),
            ecs_record("ecs-1", "terminal-00000002"),
        ],
        registry_with_leaves("t", &["terminal-00000001", "terminal-00000002"]),
    );

    r.mgr.lock().unwrap().reconcile();

    let lines = jsonl(&r.audit_path);
    let stopped: Vec<&Value> = lines
        .iter()
        .filter(|l| l["event"] == "daemon_stopped")
        .collect();
    assert_eq!(stopped.len(), 1, "{lines:?}");
    assert_eq!(stopped[0]["terminal_id"], "local-1");
    assert_eq!(stopped[0]["pane_id"], "terminal-00000001");
    assert_eq!(stopped[0]["kind"], "local");

    let closed: Vec<&Value> = lines.iter().filter(|l| l["event"] == "closed").collect();
    assert_eq!(closed.len(), 1, "{lines:?}");
    assert_eq!(closed[0]["terminal_id"], "ecs-1");
    assert_eq!(closed[0]["reason"], "daemon_stopped");
    assert_eq!(closed[0]["kind"], "ecs");

    let allowed = [
        "ts",
        "event",
        "terminal_id",
        "pane_id",
        "tag",
        "kind",
        "reason",
        "exit_code",
    ];
    for line in &lines {
        for key in line.as_object().expect("an object").keys() {
            assert!(
                allowed.contains(&key.as_str()),
                "unexpected field {key:?} in {line}"
            );
        }
    }
}

#[test]
fn a_sensitive_focus_is_named_in_the_terminal_audit_only_by_its_opaque_tag() {
    let secret = "work-item-focus-7";
    let plain = "plain-focus-3";
    let tag_record = |tag: &str, id: &str, pane: &str| TerminalRecord {
        tag: tag.into(),
        ..local_record(id, pane)
    };
    let mut panes = registry_with_leaves(secret, &["terminal-0000000a"]);
    panes.get_or_init(plain);
    panes
        .insert_terminal_leaf(plain, "repl", SplitPosition::Below, "terminal-0000000b")
        .expect("leaf in the plain focus");
    let r = rig(
        &[
            tag_record(secret, "secret-term", "terminal-0000000a"),
            tag_record(plain, "plain-term", "terminal-0000000b"),
        ],
        panes,
    );
    let sensitive = SensitiveTags::in_memory();
    sensitive.mark_tag(secret);
    let opaque = sensitive.opaque_tag(secret);
    assert_ne!(opaque, secret);
    r.mgr.lock().unwrap().set_sensitive_tags(sensitive);

    // Reconcile writes `daemon_stopped` lines for both; then open and close one
    // terminal in the sensitive focus (`opened`, `closed`).
    r.mgr.lock().unwrap().reconcile();
    let (_cwd_dir, cwd) = scratch_dir();
    let opened = r
        .mgr
        .lock()
        .unwrap()
        .open_local(&access_cap(), open_in(&cwd, secret))
        .expect("open in the sensitive focus");
    let session = session_of(&r.mgr, &opened.terminal_id);
    r.mgr
        .lock()
        .unwrap()
        .close(&access_cap(), &opened.terminal_id)
        .expect("close");
    assert!(session.wait_exit(WAIT).is_some());

    let raw = std::fs::read_to_string(&r.audit_path).expect("audit file");
    assert!(
        !raw.contains(secret),
        "the sensitive tag must not appear by name in the audit trail:\n{raw}"
    );
    let lines = jsonl(&r.audit_path);
    let tags_of = |event: &str| -> Vec<String> {
        lines
            .iter()
            .filter(|l| l["event"] == event)
            .map(|l| l["tag"].as_str().expect("tag").to_string())
            .collect()
    };
    for event in ["daemon_stopped", "opened", "closed"] {
        assert!(
            tags_of(event).contains(&opaque),
            "{event} lines name the sensitive focus opaquely: {lines:?}"
        );
    }
    assert!(
        tags_of("daemon_stopped").contains(&plain.to_string()),
        "a non-sensitive focus is still named: {lines:?}"
    );
}

// ── a connection that fell behind is caught up with a fresh replay ──────────────

#[test]
fn a_connection_that_fell_behind_gets_a_fresh_replay_then_live_output_with_no_gap() {
    let (_dir, cwd) = scratch_dir();
    // READY; then on a newline: 200 numbered lines and a final mark; then on a
    // second newline: one more line. (No `raw`: LF stays CRLF on output.)
    let s = spawn_sh(
        "stty -echo; printf 'READY\\n'; read a; \
         i=0; while [ \"$i\" -lt 200 ]; do printf '%d\\n' \"$i\"; i=$((i+1)); done; \
         printf 'FINAL-SCREEN-MARK\\n'; read b; printf 'LIVE-AFTER-LAG\\n'; sleep 30",
        &cwd,
    );
    wait_until("the shell to be ready", WAIT, || {
        contains(&s.ring_bytes(), "READY")
    });
    let fanout = Fanout::start("lag-test", &s, Arc::new(Mutex::new(None)));

    // A stream that holds one batch and is not drained: the attach's replay
    // fills it, so the output that follows cannot be queued.
    let (tx, mut rx) = tokio::sync::mpsc::channel::<StreamBatch>(1);
    s.with_replay(|replay, size| fanout.attach("conn", tx, replay, size));
    s.write(b"\n").expect("write");
    wait_until("the output to be produced", WAIT, || {
        contains(&s.ring_bytes(), "FINAL-SCREEN-MARK")
    });

    // Now the connection catches up.
    let got: Arc<Mutex<Vec<ServerMsg>>> = Arc::default();
    let sink = Arc::clone(&got);
    let drain = std::thread::spawn(move || {
        while let Some(batch) = rx.blocking_recv() {
            sink.lock().unwrap().extend(batch);
        }
    });
    let replays = |frames: &[ServerMsg]| {
        frames
            .iter()
            .filter(|m| matches!(m, ServerMsg::TerminalReplay { .. }))
            .count()
    };
    wait_until("a fresh replay after the attach's", WAIT, || {
        replays(&got.lock().unwrap()) >= 2
    });

    {
        let frames = got.lock().unwrap();
        assert!(
            matches!(frames[0], ServerMsg::TerminalReplay { .. }),
            "the attach's own replay comes first"
        );
        assert!(
            matches!(frames[1], ServerMsg::TerminalReplay { .. }),
            "what the lagging connection missed is not sent as output with holes in it: {:?}",
            frames[1]
        );
        let ServerMsg::TerminalReplay { bytes, .. } = &frames[1] else {
            unreachable!()
        };
        let replay = base64::engine::general_purpose::STANDARD
            .decode(bytes)
            .expect("base64");
        let lines = numbered_lines(&replay);
        let missing: Vec<u32> = (0..200).filter(|n| !lines.contains(n)).take(5).collect();
        assert!(
            missing.is_empty(),
            "the fresh replay lost lines {missing:?}"
        );
        assert!(contains(&replay, "FINAL-SCREEN-MARK"));
    }

    // Live output resumes after the replay.
    s.write(b"\n").expect("write");
    let screen_of = |frames: &[ServerMsg]| {
        let mut view = vt100::Parser::new(24, 80, 0);
        for m in frames {
            match m {
                ServerMsg::TerminalReplay { bytes, .. }
                | ServerMsg::TerminalOutput { bytes, .. } => {
                    let raw = base64::engine::general_purpose::STANDARD
                        .decode(bytes)
                        .expect("base64");
                    view.process(&raw);
                }
                _ => {}
            }
        }
        view.screen().contents()
    };
    wait_until("the live output to reach the connection", WAIT, || {
        screen_of(&got.lock().unwrap()).contains("LIVE-AFTER-LAG")
    });
    let shown = screen_of(&got.lock().unwrap());
    assert!(
        shown.contains("FINAL-SCREEN-MARK") && shown.contains("LIVE-AFTER-LAG"),
        "the connection's screen has the earlier output and the live line: {shown:?}"
    );

    fanout.close();
    s.kill();
    drain.join().expect("drain thread");
}

// ── a focus going away closes its terminals ───────────────────────────────────

#[test]
fn closing_a_focus_ends_only_that_focuss_shells_and_leaves_and_audits_each_close() {
    let (dir, cwd) = scratch_dir();
    let audit_path = dir.path().join("audit").join("terminal.jsonl");
    let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    let mgr = TerminalManager::new(TerminalConfig {
        audit: AuditLog::open(&audit_path).expect("open the audit log"),
        store: TerminalStore::in_memory(),
        pane_registry: Some(Arc::clone(&panes)),
    });
    let gone_1 = spawn_with(&["/bin/cat"], &cwd, SignalOps::real());
    let gone_2 = spawn_with(&["/bin/cat"], &cwd, SignalOps::real());
    let stays = spawn_with(&["/bin/cat"], &cwd, SignalOps::real());
    let mut ids = Vec::new();
    {
        let mut m = mgr.lock().unwrap();
        for (tag, n, session) in [
            ("gone", 1, &gone_1),
            ("gone", 2, &gone_2),
            ("stays", 3, &stays),
        ] {
            let id = adopt(
                &mut m,
                tag,
                n,
                TerminalStatus::Running,
                Some(Arc::clone(session)),
                &cwd,
            );
            let pane = format!("terminal-{n:08x}");
            let mut reg = panes.lock().unwrap();
            reg.get_or_init(tag);
            reg.insert_terminal_leaf(tag, "repl", SplitPosition::Below, &pane)
                .expect("place the leaf");
            reg.register_terminal_leaf(tag, &pane);
            ids.push((tag, id, pane));
        }
    }

    mgr.lock().unwrap().close_focus("gone");

    // Its shells end; the other focus's shell runs on.
    assert!(gone_1.wait_exit(WAIT).is_some(), "the first shell must end");
    assert!(
        gone_2.wait_exit(WAIT).is_some(),
        "the second shell must end"
    );
    assert!(
        !stays.is_exited(),
        "another focus's shell must not be touched"
    );

    // Its records and leaves go; the other focus keeps both.
    let remaining: Vec<String> = mgr
        .lock()
        .unwrap()
        .list()
        .into_iter()
        .map(|t| t.terminal_id)
        .collect();
    assert_eq!(remaining, vec![ids[2].1.clone()]);
    {
        let reg = panes.lock().unwrap();
        assert!(reg.terminal_leaves("gone").is_empty());
        assert!(!reg
            .pane_ids("gone")
            .iter()
            .any(|p| p.starts_with("terminal-")));
        assert_eq!(reg.terminal_leaves("stays"), vec![ids[2].2.clone()]);
        assert!(reg.pane_ids("stays").contains(&ids[2].2));
    }

    // Each close is audited with its reason; the survivor has none.
    let lines = jsonl(&audit_path);
    for (_, id, _) in &ids[..2] {
        assert!(
            lines.iter().any(|l| l["event"] == "closed"
                && l["terminal_id"] == *id
                && l["reason"] == "focus_removed"),
            "no focus_removed close for {id}: {lines:#?}"
        );
    }
    assert!(
        !lines
            .iter()
            .any(|l| l["event"] == "closed" && l["terminal_id"] == ids[2].1),
        "{lines:#?}"
    );

    // A focus with no terminals (or no such focus) is a no-op.
    mgr.lock().unwrap().close_focus("never-had-one");
    assert_eq!(mgr.lock().unwrap().list().len(), 1);
    assert!(!stays.is_exited());

    shut_down(&mgr);
}
