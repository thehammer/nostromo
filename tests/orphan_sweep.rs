//! The startup sweep: what a daemon that died without cleaning up left running is
//! stopped by the next one, and nothing else is ever touched.
//!
//! Every process signalled here is one the test started itself (a `/bin/sh`
//! running a script file in a temp dir). A guard kills them by exact pid or
//! group even when an assertion fails first. Nothing here reads `~/.nostromo`.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nostromo::ipc::orphans::{
    ledger_path_beside, read_ledger_file, sweep, write_ledger_file, ChildLedger, ChildRecord,
    LedgerFile, SweepReport,
};

const DEADLINE: Duration = Duration::from_secs(10);

// ── helpers ──────────────────────────────────────────────────────────────────

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// The process state letters (`S`, `R`, `Z`, ...), or `None` when there is no such process.
fn state_of(pid: u32) -> Option<String> {
    let out = Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// Gone, or a zombie waiting to be reaped (which is as good as gone).
fn is_gone(pid: u32) -> bool {
    state_of(pid).is_none_or(|s| s.starts_with('Z'))
}

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + DEADLINE;
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn pgid_of(pid: u32) -> i32 {
    // SAFETY: plain syscall.
    unsafe { libc::getpgid(pid as libc::pid_t) }
}

/// Which group a spawned script runs in.
#[derive(Clone, Copy)]
enum Group {
    /// Leads a new group of its own (pgid == pid).
    Own,
    /// Joins an existing group (one of ours).
    Join(u32),
}

/// A script the test started. Killed on drop if it is still around.
struct Proc {
    child: Child,
    pid: u32,
    script: PathBuf,
    bg_file: PathBuf,
    leads_group: bool,
    reaped: bool,
}

impl Proc {
    /// Reap the child if it has exited. True once it has been reaped.
    fn try_reap(&mut self) -> bool {
        if !self.reaped && matches!(self.child.try_wait(), Ok(Some(_))) {
            self.reaped = true;
        }
        self.reaped
    }

    /// The pid of the background `sleep` the script started (when it started one).
    fn bg_pid(&self) -> u32 {
        std::fs::read_to_string(&self.bg_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }

    fn assert_untouched(&mut self, why: &str) {
        assert!(
            !self.try_reap() && !is_gone(self.pid),
            "{why}: pid {} must still be running",
            self.pid
        );
    }

    fn record(&self) -> ChildRecord {
        ChildRecord {
            pid: self.pid,
            pgid: self.pid,
            own_group: true,
            started_at: now(),
            marker: "test-boot".into(),
            program: self.script.to_string_lossy().into_owned(),
        }
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        if !self.reaped {
            if self.leads_group {
                // SAFETY: the group is the one this test created for this child.
                unsafe {
                    libc::killpg(self.pid as libc::pid_t, libc::SIGKILL);
                }
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        } else if self.leads_group {
            // Its background children may outlive it; the group id is still ours while any remain.
            // SAFETY: as above.
            unsafe {
                libc::killpg(self.pid as libc::pid_t, libc::SIGKILL);
            }
        }
    }
}

/// A CLI that starts a background `sleep` and waits on it.
const LEADER_WITH_BG: &str = "sleep 300 &\necho $! > @BG@\necho ready > @READY@\nwait\n";
/// A CLI that, like its background child, ignores SIGTERM.
const STUBBORN: &str =
    "trap '' TERM\nsleep 300 &\necho $! > @BG@\necho ready > @READY@\nwhile :; do wait; done\n";

/// Run `template` as `/bin/sh <script file>` (so the script's path is on its command line) and
/// wait until it says it is ready.
fn spawn(dir: &Path, name: &str, template: &str, group: Group) -> Proc {
    let script = dir.join(format!("{name}.sh"));
    let ready = dir.join(format!("{name}.ready"));
    let bg_file = dir.join(format!("{name}.bg"));
    let text = template
        .replace("@READY@", ready.to_str().unwrap())
        .replace("@BG@", bg_file.to_str().unwrap());
    std::fs::write(&script, text).unwrap();
    let mut cmd = Command::new("/bin/sh");
    cmd.arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    cmd.process_group(match group {
        Group::Own => 0,
        Group::Join(g) => g as i32,
    });
    let child = cmd.spawn().expect("spawn the script");
    let pid = child.id();
    let proc = Proc {
        child,
        pid,
        script,
        bg_file,
        leads_group: matches!(group, Group::Own),
        reaped: false,
    };
    wait_until("the script to start", || ready.exists());
    proc
}

/// A pid that has just stopped existing.
fn dead_pid() -> u32 {
    let mut child = Command::new("/bin/sh")
        .args(["-c", "true"])
        .spawn()
        .unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

fn ledger_in(dir: &Path) -> PathBuf {
    dir.join("child-processes.json")
}

fn write(path: &Path, daemon_pid: u32, children: Vec<ChildRecord>) {
    write_ledger_file(
        path,
        &LedgerFile {
            version: 1,
            daemon_pid,
            marker: "boot-test".into(),
            children,
        },
    )
    .unwrap();
}

/// Run the sweep while reaping `procs` (they are children of this test; a real orphan is
/// reaped by init, and until then it would still look like a member of its group).
fn sweep_reaping(path: &Path, grace: Duration, procs: &mut [&mut Proc]) -> SweepReport {
    let p = path.to_path_buf();
    let handle = std::thread::spawn(move || sweep(&p, grace));
    while !handle.is_finished() {
        for pr in procs.iter_mut() {
            pr.try_reap();
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.join().expect("the sweep must not panic")
}

fn nothing_swept() -> SweepReport {
    SweepReport::default()
}

// ── a leftover CLI is stopped, with everything it started ────────────────────

fn assert_leftover_is_stopped(daemon_pid: u32) {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let bg = cli.bg_pid();
    write(&ledger, daemon_pid, vec![cli.record()]);

    let report = sweep_reaping(&ledger, Duration::from_secs(3), &mut [&mut cli]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![cli.pid],
            dropped: 0,
            previous_daemon_alive: false
        },
        "the verified leftover is the one thing stopped"
    );
    wait_until("the CLI to be gone", || cli.try_reap());
    wait_until("its background child to be gone", || is_gone(bg));
    assert!(!ledger.exists(), "a swept ledger is removed");
}

#[test]
fn a_leftover_cli_and_its_background_children_are_stopped_when_the_previous_daemon_is_dead() {
    assert_leftover_is_stopped(dead_pid());
}

#[test]
fn a_leftover_cli_is_stopped_when_the_record_names_this_very_process_as_its_daemon() {
    // A restarted daemon can come back with the pid its predecessor had.
    assert_leftover_is_stopped(std::process::id());
}

#[test]
fn a_leftover_that_ignores_sigterm_is_killed_once_the_grace_runs_out_and_the_sweep_stays_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut cli = spawn(dir.path(), "stubborn", STUBBORN, Group::Own);
    let bg = cli.bg_pid();
    write(&ledger, dead_pid(), vec![cli.record()]);
    let grace = Duration::from_secs(1);

    let started = Instant::now();
    let report = sweep_reaping(&ledger, grace, &mut [&mut cli]);
    let took = started.elapsed();

    assert_eq!(report.terminated, vec![cli.pid]);
    assert!(
        took < grace + Duration::from_millis(2500),
        "the sweep took {took:?} with a {grace:?} grace"
    );
    wait_until("the CLI to be gone", || cli.try_reap());
    wait_until("the SIGTERM-ignoring child to be gone", || is_gone(bg));
}

#[test]
fn a_record_written_by_the_daemons_ledger_is_one_the_sweep_recognises() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("sessions.json");
    let ledger_path = ledger_path_beside(&store);
    assert_eq!(
        ledger_path,
        ledger_in(dir.path()),
        "the ledger sits beside the session store"
    );
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let bg = cli.bg_pid();

    let ledger = ChildLedger::new(ledger_path.clone());
    ledger.record(cli.pid, true, &cli.script);
    let report = sweep_reaping(&ledger_path, Duration::from_secs(3), &mut [&mut cli]);

    assert_eq!(
        report.terminated,
        vec![cli.pid],
        "what the daemon records is what the next one can verify"
    );
    assert_eq!(report.dropped, 0);
    wait_until("the CLI to be gone", || cli.try_reap());
    wait_until("its background child to be gone", || is_gone(bg));
}

// ── a record that does not match a live process is never acted on ────────────

#[test]
fn a_pid_reused_by_an_unrelated_process_is_not_signalled() {
    // The record says the process started an hour ago; the live one started just now.
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut other = spawn(dir.path(), "unrelated", LEADER_WITH_BG, Group::Own);
    let mut record = other.record();
    record.started_at = now() - 3600;
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut other]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 1,
            previous_daemon_alive: false
        }
    );
    other.assert_untouched("a start time an hour off");
    assert!(!ledger.exists());
}

#[test]
fn a_process_whose_command_line_does_not_name_the_recorded_program_is_not_signalled() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut other = spawn(dir.path(), "unrelated", LEADER_WITH_BG, Group::Own);
    let mut record = other.record();
    record.program = "/opt/not-this-program/claude-xyz".into();
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut other]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 1,
            previous_daemon_alive: false
        }
    );
    other.assert_untouched("a different program");
}

#[test]
fn a_process_in_a_different_group_than_recorded_is_not_signalled() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut other = spawn(dir.path(), "unrelated", LEADER_WITH_BG, Group::Own);
    let mut record = other.record();
    record.pgid = other.pid + 1; // the live pgid is the pid
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut other]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 1,
            previous_daemon_alive: false
        }
    );
    other.assert_untouched("a different group");
}

#[test]
fn a_record_claiming_its_own_group_for_a_process_that_only_joined_one_signals_nobody() {
    // B sits in A's group but the record says B led it: a group signal would hit A too.
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut a = spawn(dir.path(), "leader", LEADER_WITH_BG, Group::Own);
    let mut b = spawn(dir.path(), "member", LEADER_WITH_BG, Group::Join(a.pid));
    assert_eq!(pgid_of(b.pid), a.pid as i32, "setup: b joined a's group");
    let mut record = b.record();
    record.pgid = a.pid;
    record.own_group = true;
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut a, &mut b]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 1,
            previous_daemon_alive: false
        }
    );
    a.assert_untouched("the group's leader");
    b.assert_untouched("the member");
}

#[test]
fn a_cli_that_did_not_lead_its_group_is_stopped_alone_and_its_group_is_left_running() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut a = spawn(dir.path(), "leader", LEADER_WITH_BG, Group::Own);
    let mut b = spawn(dir.path(), "member", LEADER_WITH_BG, Group::Join(a.pid));
    let mut record = b.record();
    record.pgid = a.pid;
    record.own_group = false;
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(3), &mut [&mut a, &mut b]);

    assert_eq!(report.terminated, vec![b.pid]);
    wait_until("the recorded process to be gone", || b.try_reap());
    a.assert_untouched("a process that merely shares the group");
}

#[test]
fn a_record_of_a_process_that_no_longer_exists_is_dropped_without_a_signal() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let gone = dead_pid();
    write(
        &ledger,
        dead_pid(),
        vec![ChildRecord {
            pid: gone,
            pgid: gone,
            own_group: true,
            started_at: now(),
            marker: "m".into(),
            program: "/bin/sh".into(),
        }],
    );

    let report = sweep(&ledger, Duration::from_secs(1));

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 1,
            previous_daemon_alive: false
        }
    );
    assert!(!ledger.exists());
}

#[test]
fn records_naming_pid_zero_or_one_are_dropped_and_do_not_stop_the_rest_from_being_swept() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let bg = cli.bg_pid();
    let bogus = |pid: u32| ChildRecord {
        pid,
        pgid: pid,
        own_group: true,
        started_at: now(),
        marker: "m".into(),
        program: "/sbin/init".into(),
    };
    write(&ledger, dead_pid(), vec![bogus(1), bogus(0), cli.record()]);

    let report = sweep_reaping(&ledger, Duration::from_secs(3), &mut [&mut cli]);

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![cli.pid],
            dropped: 2,
            previous_daemon_alive: false
        }
    );
    wait_until("the CLI to be gone", || cli.try_reap());
    wait_until("its background child to be gone", || is_gone(bg));
}

// ── a daemon that is still running keeps its children ────────────────────────

#[test]
fn nothing_is_touched_and_the_record_stays_when_the_daemon_that_wrote_it_is_alive() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut daemon = spawn(dir.path(), "daemon", LEADER_WITH_BG, Group::Own);
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let file = LedgerFile {
        version: 1,
        daemon_pid: daemon.pid,
        marker: "boot-test".into(),
        children: vec![cli.record()],
    };
    write_ledger_file(&ledger, &file).unwrap();

    let report = sweep(&ledger, Duration::from_secs(1));

    assert_eq!(
        report,
        SweepReport {
            terminated: vec![],
            dropped: 0,
            previous_daemon_alive: true
        }
    );
    cli.assert_untouched("a live daemon's child");
    daemon.assert_untouched("the live daemon");
    assert_eq!(
        read_ledger_file(&ledger),
        Some(file),
        "the live daemon's record is left exactly as it was"
    );
}

// ── a ledger nobody can read is no use, and does no harm ─────────────────────

#[test]
fn a_corrupt_ledger_is_ignored_and_removed() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    std::fs::write(&ledger, b"{ this is not json \x00\xff").unwrap();

    let report = sweep(&ledger, Duration::from_secs(1));

    assert_eq!(report, nothing_swept());
    assert!(
        !ledger.exists(),
        "a corrupt ledger is removed so it is not tripped over again"
    );
}

#[test]
fn an_empty_ledger_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    std::fs::write(&ledger, b"").unwrap();

    assert_eq!(sweep(&ledger, Duration::from_secs(1)), nothing_swept());
}

#[test]
fn a_ledger_of_another_version_is_ignored_and_none_of_its_records_are_acted_on() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let file = LedgerFile {
        version: 2,
        daemon_pid: dead_pid(),
        marker: "boot-test".into(),
        children: vec![cli.record()],
    };
    write_ledger_file(&ledger, &file).unwrap();

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut cli]);

    assert_eq!(report, nothing_swept());
    cli.assert_untouched("a record in a format this build does not know");
}

#[test]
fn a_missing_ledger_is_the_normal_case_and_sweeps_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("no-such-dir").join("child-processes.json");

    assert_eq!(sweep(&ledger, Duration::from_secs(1)), nothing_swept());
    assert!(!ledger.exists());
}

// ── the ledger file ──────────────────────────────────────────────────────────

#[test]
fn the_ledger_is_private_to_the_user_and_leaves_no_temp_files_behind() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = ledger_in(dir.path());
    let ledger = ChildLedger::new(ledger_path.clone());
    assert!(
        !ledger_path.exists(),
        "nothing is written until a child is recorded"
    );

    ledger.record(4242, true, Path::new("/opt/claude"));

    let mode = std::fs::metadata(&ledger_path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
    let names: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(
        names,
        vec![std::ffi::OsString::from("child-processes.json")],
        "the write is atomic: no temp file stays"
    );
    let file = read_ledger_file(&ledger_path).expect("a readable ledger");
    assert_eq!(file.daemon_pid, std::process::id());
    assert_eq!(file.children.len(), 1);
    let rec = &file.children[0];
    assert_eq!((rec.pid, rec.pgid, rec.own_group), (4242, 4242, true));
    assert_eq!(rec.program, "/opt/claude");
    assert!(rec.started_at.abs_diff(now()) <= 5);
}

#[test]
fn the_ledger_lists_what_is_running_and_is_removed_when_cleared() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = ledger_in(dir.path());
    let ledger = ChildLedger::new(ledger_path.clone());
    ledger.record(4242, true, Path::new("/opt/claude"));
    ledger.record(4343, true, Path::new("/opt/claude"));

    ledger.forget(4242);

    let pids: Vec<u32> = read_ledger_file(&ledger_path)
        .unwrap()
        .children
        .iter()
        .map(|c| c.pid)
        .collect();
    assert_eq!(pids, vec![4343], "a stopped child is no longer listed");

    ledger.clear();
    assert!(!ledger_path.exists());
    ledger.clear(); // clearing twice is harmless
}

/// Two ledgers in one process stand for the old and the new daemon: same pid, different boot.
#[test]
fn an_old_daemons_final_clear_does_not_delete_the_file_a_newer_daemon_took_over() {
    let dir = tempfile::tempdir().unwrap();
    let path = ledger_in(dir.path());
    let old = ChildLedger::new(path.clone());
    old.record(4242, true, Path::new("/opt/claude"));

    // The new daemon starts while the old one is still shutting down, and records its first CLI.
    let new = ChildLedger::new(path.clone());
    new.record(5151, true, Path::new("/opt/claude"));

    old.forget(4242); // the old daemon is still stopping its sessions...
    old.clear(); // ...and finishes.

    let file = read_ledger_file(&path).expect("the new daemon's ledger is still there");
    assert_eq!(file.marker, new.marker());
    let pids: Vec<u32> = file.children.iter().map(|c| c.pid).collect();
    assert_eq!(pids, vec![5151], "the new daemon's record is untouched");

    new.clear();
    assert!(!path.exists(), "the owner still removes its own file");
}

#[test]
fn clear_leaves_a_file_that_carries_another_boots_marker() {
    let dir = tempfile::tempdir().unwrap();
    let path = ledger_in(dir.path());
    let mine = ChildLedger::new(path.clone());
    mine.record(4242, true, Path::new("/opt/claude"));
    write(&path, std::process::id(), vec![]); // someone else's boot, same pid, marker "boot-test"

    mine.clear();

    assert!(path.exists());
}

#[test]
fn a_ledger_file_that_was_written_reads_back_the_same_and_its_directory_is_created_on_demand() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir
        .path()
        .join("fresh")
        .join("state")
        .join("child-processes.json");
    let file = LedgerFile {
        version: 1,
        daemon_pid: 77,
        marker: "boot-test".into(),
        children: vec![ChildRecord {
            pid: 5,
            pgid: 5,
            own_group: true,
            started_at: 1_700_000_000,
            marker: "boot-1".into(),
            program: "/bin/sh".into(),
        }],
    };

    write_ledger_file(&path, &file).unwrap();

    assert_eq!(read_ledger_file(&path), Some(file));
}

// ── the CLI is gone but what it started is not ───────────────────────────────

/// Known limit: with the recorded leader gone there is nothing to prove who the group belongs to,
/// so the sweep drops the record and signals nobody.
#[test]
fn a_leftover_group_whose_cli_already_exited_is_not_signalled() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = ledger_in(dir.path());
    let mut cli = spawn(dir.path(), "cli", LEADER_WITH_BG, Group::Own);
    let bg = cli.bg_pid();
    let record = cli.record();
    // The CLI dies (as it does when a dead daemon's pipes close) and is reaped, so its pid is
    // free; the background child keeps the group alive.
    // SAFETY: the pid is this test's own child.
    unsafe {
        libc::kill(cli.pid as libc::pid_t, libc::SIGKILL);
    }
    wait_until("the CLI to be reaped", || cli.try_reap());
    assert!(!is_gone(bg), "the background child outlives its CLI");
    write(&ledger, dead_pid(), vec![record]);

    let report = sweep_reaping(&ledger, Duration::from_secs(1), &mut [&mut cli]);

    assert_eq!(report.terminated, Vec::<u32>::new());
    assert_eq!(report.dropped, 1);
    assert!(!is_gone(bg), "the group was not signalled");
}
