//! Integration tests for the kitty keyboard protocol and dim SGR rendering.
//!
//! Test 1: verifies that feeding a kitty push escape into [`KittyFlagsTracker`]
//! causes [`key_to_bytes_for`] to encode Enter as `\x1b[13u`, and that after
//! a pop it falls back to `\r`.
//!
//! Test 2: verifies that a vt100 SGR 2 (dim/faint) sequence painted through
//! [`PtyWidget`] produces a Ratatui cell with [`Modifier::DIM`] set.

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
