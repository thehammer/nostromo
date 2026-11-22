//! The bytes written to the CLI are unchanged by the message queue (S1).
//!
//! An idle send, a queued send, a typed slash command and an image message go
//! through a real `SessionManager` to the hermetic fake `claude`
//! (`tests/support/fake_claude_perm.py`, which logs every stdin line verbatim). The frames
//! must equal `tests/fixtures/session_queue/stdin_frames.jsonl`, which was captured by running
//! this same test on `main` before the queue existed (it only uses `send_user_message`, which
//! both have). Merging queued messages is not introduced: each message is its own frame.
//!
//! To recapture (on a checkout WITHOUT the queue change): `NOSTROMO_WRITE_BYTES_FIXTURE=1`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::ipc::session_manager::{SessionManager, CLAUDE_BIN_ENV};

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);
const GOLDEN: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/session_queue/stdin_frames.jsonl"
);
/// A fixed path, so the idle message's bytes are the same on every run and checkout.
const HOLD_FILE: &str = "/tmp/nostromo-session-queue-bytes-hold";
/// A one-pixel PNG.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

fn user_frames(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.contains("\"type\":\"user\""))
        .map(str::to_owned)
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_frames_written_for_an_idle_a_queued_a_command_and_an_image_message_are_unchanged() {
    // The only test in this binary, so the process-wide environment is ours.
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("HOME", &home);
    std::env::set_var(
        nostromo::approvals::APPROVALS_DIR_ENV,
        tmp.path().join("approvals"),
    );
    std::env::set_var(
        nostromo::approvals::guard::GUARD_BIN_ENV,
        env!("CARGO_BIN_EXE_nostromo-guard"),
    );
    let dir = tmp.path().join("fake");
    std::fs::create_dir_all(&dir).unwrap();
    let wrapper = dir.join("claude");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
            dir.display()
        ),
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
    let png: PathBuf = tmp.path().join("pixel.png");
    std::fs::write(&png, PNG).unwrap();
    let work = tmp.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let _ = std::fs::remove_file(HOLD_FILE);

    let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("daemon-sessions.json"),
    )));
    {
        let mut m = mgr.lock().unwrap();
        m.spawn_session(
            "cody-bytes".into(),
            "cody".into(),
            "View".into(),
            Some(work),
            None,
            false,
        )
        .expect("the session starts");
        // Idle: written at once, and its turn is held open by the fake.
        m.send_user_message("cody-bytes", &format!("idle first HOLD:{HOLD_FILE}"), &[])
            .unwrap();
        // Busy: each of these queues behind the held turn.
        m.send_user_message("cody-bytes", "queued second", &[])
            .unwrap();
        m.send_user_message("cody-bytes", "/compact keep the decisions", &[])
            .unwrap();
        m.send_user_message(
            "cody-bytes",
            "with a picture",
            &[png.to_string_lossy().into_owned()],
        )
        .unwrap();
    }
    std::fs::write(HOLD_FILE, "").unwrap();

    let log = dir.join("stdin.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    while user_frames(&log).len() < 4 {
        assert!(
            Instant::now() < deadline,
            "the fake read only {:#?}",
            user_frames(&log)
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    mgr.lock().unwrap().kill_all_on_shutdown();
    let _ = std::fs::remove_file(HOLD_FILE);
    let frames = user_frames(&log);
    assert_eq!(frames.len(), 4, "{frames:#?}");

    let joined = frames.join("\n") + "\n";
    if std::env::var_os("NOSTROMO_WRITE_BYTES_FIXTURE").is_some() {
        std::fs::write(GOLDEN, &joined).unwrap();
        return;
    }
    let golden = std::fs::read_to_string(GOLDEN).expect("the captured fixture");
    assert_eq!(joined, golden, "the bytes written to the CLI changed");
}
