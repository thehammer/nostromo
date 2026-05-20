//! Integration tests for the kitty keyboard protocol and dim SGR rendering.
//!
//! Test 1: verifies that feeding a kitty push escape into [`KittyFlagsTracker`]
//! causes [`key_to_bytes_for`] to encode Enter as `\x1b[13u`, and that after
//! a pop it falls back to `\r`.
//!
//! Test 2: verifies that a vt100 SGR 2 (dim/faint) sequence painted through
//! [`PtyWidget`] produces a Ratatui cell with [`Modifier::DIM`] set.
//!
//! Tests 3–5: verify TERM env normalisation in PtyHost / PtyManager, and
//! kitty flag tracking through the daemon PTY reader.

use std::sync::{Arc, Mutex};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    backend::TestBackend,
    layout::Rect,
    style::Modifier,
    Terminal,
};

use nostromo::pty::{
    keys::key_to_bytes_for,
    kitty::KittyFlagsTracker,
    PtyWidget,
};

// ── Test 1 ───────────────────────────────────────────────────────────────────

/// Push kitty flags → Enter encodes as `\x1b[13u`.
/// Pop kitty flags → Enter falls back to `\r`.
#[test]
fn kitty_flag_push_routes_enter_through_csi_u_encoder() {
    let mut tracker = KittyFlagsTracker::new();
    let flags_handle = tracker.flags();

    let enter = KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE);

    // Before any push: legacy mode → Enter is `\r`.
    let flags = flags_handle.load(std::sync::atomic::Ordering::Relaxed);
    assert_eq!(flags, 0, "flags should start at 0");
    assert_eq!(
        key_to_bytes_for(&enter, flags),
        Some(b"\r".to_vec()),
        "legacy Enter should be \\r"
    );

    // Push kitty flag 1 (disambiguate escape codes).
    tracker.feed(b"\x1b[>1u");
    let flags = flags_handle.load(std::sync::atomic::Ordering::Relaxed);
    assert_eq!(flags, 1, "flags should be 1 after push");
    assert_eq!(
        key_to_bytes_for(&enter, flags),
        Some(b"\x1b[13u".to_vec()),
        "kitty Enter should be \\x1b[13u"
    );

    // Pop kitty flag → back to legacy.
    tracker.feed(b"\x1b[<u");
    let flags = flags_handle.load(std::sync::atomic::Ordering::Relaxed);
    assert_eq!(flags, 0, "flags should return to 0 after pop");
    assert_eq!(
        key_to_bytes_for(&enter, flags),
        Some(b"\r".to_vec()),
        "Enter should revert to \\r after pop"
    );
}

// ── Test 2 ───────────────────────────────────────────────────────────────────

/// `\x1b[2m` (SGR 2 = dim/faint) renders as `Modifier::DIM` in the Ratatui buffer.
#[test]
fn dim_sgr_cell_renders_with_modifier_dim() {
    // Feed dim SGR sequence followed by visible text followed by reset.
    let bytes = b"\x1b[2mfaint\x1b[m";
    let (cols, rows) = (20u16, 3u16);

    let mut parser = vt100::Parser::new(rows, cols, 0);
    parser.process(bytes);

    let backend = TestBackend::new(cols, rows);
    let mut terminal = Terminal::new(backend).unwrap();

    let parser_arc = Arc::new(Mutex::new(parser));

    terminal
        .draw(|f| {
            let guard = parser_arc.lock().unwrap();
            f.render_widget(PtyWidget::new(guard, 0), Rect::new(0, 0, cols, rows));
        })
        .unwrap();

    let buffer = terminal.backend().buffer().clone();

    // The first cell at (0, 0) should be 'f' from "faint" with DIM set.
    let cell = buffer.cell((0, 0)).expect("cell (0,0) must exist");
    assert_eq!(cell.symbol(), "f", "first cell should be 'f'");
    assert!(
        cell.style().add_modifier.contains(Modifier::DIM),
        "cell rendered from SGR 2 must have Modifier::DIM set, got: {:?}",
        cell.style()
    );

    // The reset should clear DIM — check a cell beyond "faint" (position 5+).
    // After \x1b[m, position 5 onward is blank with no modifiers.
    let cell_after = buffer.cell((5, 0)).expect("cell (5,0) must exist");
    assert!(
        !cell_after.style().add_modifier.contains(Modifier::DIM),
        "cell after SGR reset should not have Modifier::DIM"
    );
}

// ── Test 3 ───────────────────────────────────────────────────────────────────

/// PtyHost injects `TERM=xterm-256color` and unsets `TERM_PROGRAM`.
#[tokio::test]
async fn pty_host_sets_term_xterm_256color() {
    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<nostromo::event::AppEvent>();
    let sock = std::path::Path::new("/tmp/nostromo_test_host.sock");

    let host = nostromo::pty::PtyHost::spawn_with_env(
        "sh",
        &[
            "-c",
            "printf 'TERM=%s TERM_PROGRAM=%s\\n' \"$TERM\" \"${TERM_PROGRAM:-UNSET}\"",
        ],
        (80, 3),
        tx,
        "test",
        sock,
        None,
    )
    .expect("PtyHost::spawn_with_env must succeed");

    // Give the child time to write output and exit.
    tokio::time::sleep(tokio::time::Duration::from_millis(400)).await;

    let contents = host.parser.lock().unwrap().screen().contents();
    assert!(
        contents.contains("TERM=xterm-256color"),
        "Expected TERM=xterm-256color in PTY output, got: {contents:?}"
    );
    assert!(
        contents.contains("TERM_PROGRAM=UNSET"),
        "Expected TERM_PROGRAM=UNSET in PTY output, got: {contents:?}"
    );
}

// ── Test 4 ───────────────────────────────────────────────────────────────────

/// PtyManager (daemon spawn path) injects `TERM=xterm-256color` and unsets
/// `TERM_PROGRAM`.
#[tokio::test]
async fn daemon_spawn_sets_term_xterm_256color() {
    use nostromo::ipc::{protocol::ServerMsg, PtyManager};

    let mut manager = PtyManager::new();

    // Register a fake client sender so `attach` can deliver scrollback.
    let (client_tx, mut client_rx) =
        tokio::sync::mpsc::unbounded_channel::<ServerMsg>();
    manager
        .client_sender_registry()
        .lock()
        .unwrap()
        .insert("test-client".to_string(), client_tx);

    let (pty_id, _, _) = manager
        .spawn_pty(
            "test-term-daemon".to_string(),
            "sh",
            &[
                "-c".to_string(),
                "printf 'TERM=%s TERM_PROGRAM=%s\\n' \"$TERM\" \"${TERM_PROGRAM:-UNSET}\""
                    .to_string(),
            ],
            80,
            3,
            None,
            "test-client".to_string(),
        )
        .expect("PtyManager::spawn_pty must succeed");

    // Give the child time to run, write output, and exit so the full result
    // lands in the scrollback buffer before we attach.
    tokio::time::sleep(tokio::time::Duration::from_millis(400)).await;

    // Attach: daemon drains scrollback into client_rx.
    manager
        .attach(&pty_id, "test-client")
        .expect("attach must succeed");

    // Give the forwarder task time to deliver any remaining PtyOutput frames
    // (in case the child hadn't fully exited at attach time).
    tokio::time::sleep(tokio::time::Duration::from_millis(300)).await;
    let mut output = Vec::new();
    while let Ok(msg) = client_rx.try_recv() {
        if let ServerMsg::PtyScrollback { bytes, .. }
        | ServerMsg::PtyOutput { bytes, .. } = msg
        {
            output.extend_from_slice(&bytes);
        }
    }

    let text = String::from_utf8_lossy(&output);
    assert!(
        text.contains("TERM=xterm-256color"),
        "Expected TERM=xterm-256color in daemon PTY output, got: {text:?}"
    );
    assert!(
        text.contains("TERM_PROGRAM=UNSET"),
        "Expected TERM_PROGRAM=UNSET in daemon PTY output, got: {text:?}"
    );
}

// ── Test 5 ───────────────────────────────────────────────────────────────────

/// Kitty flags pushed by the child process are tracked in `PtyManager`, and
/// once flags are non-zero `key_to_bytes_for` encodes Enter as `\x1b[13u`.
#[tokio::test]
async fn kitty_flags_tracked_in_daemon_pty() {
    use nostromo::ipc::PtyManager;

    let mut manager = PtyManager::new();

    // Spawn a child that pushes kitty flag 1 then stays alive long enough for
    // the reader task to observe it.
    let (pty_id, _, _) = manager
        .spawn_pty(
            "test-kitty-daemon".to_string(),
            "sh",
            &[
                "-c".to_string(),
                // Print kitty push then hold briefly so the reader task has
                // time to process the chunk before we check.
                "printf '\\033[>1u'; sleep 0.2".to_string(),
            ],
            80,
            24,
            None,
            "test".to_string(),
        )
        .expect("PtyManager::spawn_pty must succeed");

    // Give the reader task time to read and process the kitty push.
    tokio::time::sleep(tokio::time::Duration::from_millis(400)).await;

    let flags = manager
        .kitty_flags(&pty_id)
        .expect("pty_id must be known to manager");
    assert_eq!(flags, 1, "kitty flags should be 1 after push escape in output");

    // With flags == 1, Enter must be encoded in kitty form.
    let enter = KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE);
    assert_eq!(
        key_to_bytes_for(&enter, flags),
        Some(b"\x1b[13u".to_vec()),
        "Enter should encode as \\x1b[13u when kitty flags are active"
    );

    manager.kill_pty(&pty_id);
}
