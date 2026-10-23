//! A daemon session started the way production starts one (`spawn_session`, against a fake
//! `claude`) leads its own process group, is recorded for the next start, and is stopped with
//! everything it started when the daemon shuts down.
//!
//! The fake `claude` lives in a temp dir; the one process-wide setting here is the env var that
//! points the manager at it, which only this test binary reads. Nothing touches `~/.nostromo`.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::time::{Duration, Instant};

use nostromo::ipc::orphans::{ledger_path_beside, read_ledger_file};
use nostromo::ipc::session_manager::{SessionManager, CLAUDE_BIN_ENV};

const DEADLINE: Duration = Duration::from_secs(10);

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + DEADLINE;
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn read_pid(file: &Path) -> Option<u32> {
    std::fs::read_to_string(file).ok()?.trim().parse().ok()
}

fn is_gone(pid: u32) -> bool {
    let out = std::process::Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    let state = String::from_utf8_lossy(&out.stdout).trim().to_string();
    !out.status.success() || state.is_empty() || state.starts_with('Z')
}

/// Stops every session on drop, an assertion failure included.
struct Guard(SessionManager);

impl Drop for Guard {
    fn drop(&mut self) {
        self.0
            .kill_all_on_shutdown_with_grace(Duration::from_millis(300));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_started_session_leads_its_own_group_is_recorded_and_is_stopped_whole_at_shutdown() {
    let dir = tempfile::tempdir().unwrap();
    let pid_file = dir.path().join("cli.pid");
    let bg_file = dir.path().join("bg.pid");
    let term_file = dir.path().join("cli.term");
    let ready = dir.path().join("ready");
    let claude = dir.path().join("claude");
    std::fs::write(
        &claude,
        format!(
            "#!/bin/sh\n\
             trap 'echo got-term > {term}; exit 0' TERM\n\
             echo $$ > {pid}\n\
             sleep 300 &\n\
             echo $! > {bg}\n\
             echo ready > {ready}\n\
             while :; do wait; done\n",
            term = term_file.display(),
            pid = pid_file.display(),
            bg = bg_file.display(),
            ready = ready.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::env::set_var(CLAUDE_BIN_ENV, &claude);

    let store = dir.path().join("daemon-sessions.json");
    let mut mgr = Guard(SessionManager::with_store_path(store.clone()));
    mgr.0
        .spawn_session(
            "cody-plain".into(),
            "cody".into(),
            "plain-view".into(),
            Some(dir.path().to_path_buf()),
            None,
            false,
        )
        .expect("the session starts");
    wait_until("the fake claude to be up", || ready.exists());
    let cli = read_pid(&pid_file).unwrap();
    let bg = read_pid(&bg_file).unwrap();

    // Its own group, not the daemon's.
    // SAFETY: plain syscalls.
    let (cli_group, our_group) = unsafe { (libc::getpgid(cli as libc::pid_t), libc::getpgrp()) };
    assert_eq!(
        cli_group, cli as i32,
        "an ordinary session leads its own group"
    );
    assert_ne!(cli_group, our_group);

    // Recorded beside the session store, for a next start that finds it still there.
    let ledger = ledger_path_beside(&store);
    let file = read_ledger_file(&ledger).expect("a ledger beside the session store");
    let rec = file
        .children
        .iter()
        .find(|c| c.pid == cli)
        .expect("the session is recorded");
    assert_eq!((rec.pgid, rec.own_group), (cli, true));

    let started = Instant::now();
    mgr.0
        .kill_all_on_shutdown_with_grace(Duration::from_secs(2));
    let took = started.elapsed();

    assert!(
        term_file.exists(),
        "the CLI was asked to stop (SIGTERM) before anything was killed"
    );
    wait_until("the CLI to be gone", || is_gone(cli));
    wait_until("its background child to be gone", || is_gone(bg));
    assert!(took < Duration::from_secs(4), "shutdown took {took:?}");
    assert!(
        !ledger.exists(),
        "a clean shutdown leaves no ledger for the next start to sweep"
    );
}
