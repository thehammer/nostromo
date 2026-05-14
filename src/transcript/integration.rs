//! `TranscriptPane` — view-agnostic helper that owns all transcript wiring.
//!
//! Each view that wants a Ctrl+T transcript overlay adds one field:
//! ```ignore
//! transcript: TranscriptPane,
//! ```
//! and delegates Ctrl+T, navigation keys, mouse events, and rendering to it.
//! The helper handles the reader lifecycle, interaction state, and render cache.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use ratatui::{
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget},
    Frame,
};
use tokio::sync::watch;

use crate::{
    transcript::{
        snapshot::{TranscriptEntry, TranscriptSnapshot},
        TranscriptReader,
    },
    ui::{
        theme,
        widgets::{
            syntect_cache::SyntectCache,
            transcript::TranscriptWidget,
            transcript_layout::{scroll_to_cursor, TranscriptInteraction},
        },
    },
};

// ── TranscriptPane ─────────────────────────────────────────────────────────────

/// Self-contained transcript pane widget.
///
/// Usage:
/// 1. Call `new()` at view construction time.
/// 2. At spawn time, generate a UUID, append `--session-id` to the args, and call
///    `set_session_context(cwd, sid)`.
/// 3. At reattach time, call `set_session_context` with the recovered sid.
/// 4. On `Ctrl+T` (nav mode only): call `bring_up_if_needed()` then `toggle_visible()`.
/// 5. In `on_event`, forward keys/mouse to `on_key` / `on_mouse` when visible and not
///    PTY-capturing; consume if they return `true`.
/// 6. In `render`, allocate a sub-rect and call `render(f, sub_rect)`.
pub struct TranscriptPane {
    /// CWD + session-id for the most-recently spawned or reattached PTY.
    pending_cwd: Option<PathBuf>,
    pending_session_id: Option<String>,
    /// CWD used when the current reader was started.
    active_cwd: Option<PathBuf>,
    /// Session-id used when the current reader was started.
    active_session_id: Option<String>,
    /// Live tail reader (present while transcript is visible and a sid is known).
    reader: Option<TranscriptReader>,
    /// Watch receiver for snapshots from the reader.
    rx: Option<watch::Receiver<TranscriptSnapshot>>,
    /// Whether the pane is currently shown.
    visible: bool,
    /// Top-of-viewport line offset (0 = top).
    scroll_offset: u16,
    /// Navigation cursor, expansion set, thinking toggle, tail-follow.
    interaction: TranscriptInteraction,
    /// Render cache keyed by `(entry_index, is_expanded)`.
    cache: HashMap<(usize, bool), Vec<ratatui::text::Line<'static>>>,
    /// Inner width at last render; used to detect resizes that require cache flush.
    last_width: u16,
    /// Entry count at last render; used for tail-follow detection.
    last_entry_count: usize,
    /// Inner rect of the pane as drawn last frame (for mouse hit-testing).
    area: Rect,
    /// Syntax-highlight cache (created once, used for every render).
    syntect: Arc<SyntectCache>,
}

impl TranscriptPane {
    /// Build a new pane (no session yet, invisible).
    ///
    /// Eagerly creates the `SyntectCache` so that the first render is fast.
    /// Falls back to a minimal stub if loading fails (this is non-fatal —
    /// syntax highlighting simply won't work).
    pub fn new() -> Self {
        // SyntectCache::load() is essentially infallible (uses bundled defaults).
        let syntect = Arc::new(
            SyntectCache::load().unwrap_or_else(|_| SyntectCache::empty()),
        );

        Self {
            pending_cwd: None,
            pending_session_id: None,
            active_cwd: None,
            active_session_id: None,
            reader: None,
            rx: None,
            visible: false,
            scroll_offset: 0,
            interaction: TranscriptInteraction::default(),
            cache: HashMap::new(),
            last_width: 0,
            last_entry_count: 0,
            area: Rect::default(),
            syntect,
        }
    }

    // ── Session context ───────────────────────────────────────────────────────

    /// Record the CWD + session-id for the most-recently spawned/reattached
    /// PTY.  The reader is not started yet — deferred until the first
    /// `bring_up_if_needed()` call.
    pub fn set_session_context(&mut self, cwd: PathBuf, session_id: String) {
        self.pending_cwd = Some(cwd);
        self.pending_session_id = Some(session_id);
    }

    /// Start the reader if it isn't already running for the pending session.
    ///
    /// - If the reader is already running for the same sid, this is a no-op.
    /// - If the sid changed, tears down the old reader and starts a new one.
    /// - If no sid is pending, falls back to a CWD scan via
    ///   `find_latest_session_id_for_cwd`.
    pub fn bring_up(&mut self) {
        let sid = match &self.pending_session_id {
            Some(s) => s.clone(),
            None => {
                // Fallback: scan the CWD for the most-recent JSONL.
                let cwd = self.pending_cwd
                    .clone()
                    .or_else(|| std::env::current_dir().ok());
                match cwd.as_deref().and_then(crate::transcript::find_latest_session_id_for_cwd) {
                    Some(found) => found,
                    None => return, // nothing to tail
                }
            }
        };

        let cwd = self
            .pending_cwd
            .clone()
            .or_else(|| std::env::current_dir().ok())
            .unwrap_or_else(|| PathBuf::from("/tmp"));

        // Idempotent: same sid already running.
        if self.active_session_id.as_deref() == Some(&sid)
            && self.active_cwd.as_deref() == Some(cwd.as_path())
            && self.reader.is_some()
        {
            return;
        }

        // Tear down old reader before starting a new one.
        self.tear_down_reader();

        let (reader, rx) = TranscriptReader::spawn(cwd.clone(), sid.clone());
        self.reader = Some(reader);
        self.rx = Some(rx);
        self.active_cwd = Some(cwd);
        self.active_session_id = Some(sid);
        self.scroll_offset = 0;
        self.interaction = TranscriptInteraction::default();
        self.cache.clear();
        self.last_entry_count = 0;
        self.last_width = 0;
    }

    /// Drop the reader and clear cached state (called when the PTY exits).
    pub fn tear_down(&mut self) {
        self.tear_down_reader();
        self.pending_session_id = None;
        self.active_session_id = None;
    }

    fn tear_down_reader(&mut self) {
        self.reader = None;
        self.rx = None;
    }

    // ── Visibility ────────────────────────────────────────────────────────────

    /// Toggle the pane on/off.  Calls `bring_up` when turning on so the
    /// reader is started lazily on the first toggle.
    pub fn toggle_visible(&mut self) {
        self.visible = !self.visible;
        if self.visible {
            self.bring_up();
        }
    }

    /// Whether the transcript pane is currently visible.
    pub fn is_visible(&self) -> bool {
        self.visible
    }

    // ── Key handling ──────────────────────────────────────────────────────────

    /// Handle a key event.
    ///
    /// Returns `true` if the key was consumed by the transcript.  The caller
    /// should only forward events here when the transcript is visible and the
    /// PTY is not capturing.
    ///
    /// Handled keys (matching Perri's phase-3 bindings):
    /// - `j` / `↓`    — next entry
    /// - `k` / `↑`    — previous entry
    /// - `g` / `Home` — first entry
    /// - `G` / `End`  — last entry (re-engages tail-follow)
    /// - `o` / `Enter`— toggle expand current entry
    /// - `T`          — toggle thinking visibility
    /// - `PageUp`     — move cursor back by half pane height
    /// - `PageDown`   — move cursor forward by half pane height
    pub fn on_key(&mut self, key: &KeyEvent) -> bool {
        let snap_opt = self.rx.as_ref().map(|rx| rx.borrow().clone());

        match key.code {
            KeyCode::Char('j') | KeyCode::Down => {
                if let Some(snap) = snap_opt { self.cursor_next(&snap); }
                true
            }
            KeyCode::Char('k') | KeyCode::Up => {
                if let Some(snap) = snap_opt { self.cursor_prev(&snap); }
                true
            }
            KeyCode::Char('g') | KeyCode::Home => {
                if let Some(snap) = snap_opt { self.cursor_first(&snap); }
                true
            }
            KeyCode::Char('G') | KeyCode::End => {
                if let Some(snap) = snap_opt { self.cursor_last(&snap); }
                true
            }
            KeyCode::Char('o') | KeyCode::Enter => {
                self.toggle_expand();
                true
            }
            KeyCode::Char('T') if key.modifiers == KeyModifiers::SHIFT
                || key.modifiers == KeyModifiers::NONE =>
            {
                if let Some(snap) = snap_opt { self.toggle_thinking(&snap); }
                true
            }
            KeyCode::PageUp => {
                let half = (self.area.height / 2).max(1) as isize;
                if let Some(snap) = snap_opt { self.cursor_by(&snap, -half); }
                true
            }
            KeyCode::PageDown => {
                let half = (self.area.height / 2).max(1) as isize;
                if let Some(snap) = snap_opt { self.cursor_by(&snap, half); }
                true
            }
            _ => false,
        }
    }

    /// Handle a mouse event.
    ///
    /// Returns `true` if the event was consumed.  The caller must provide the
    /// same `area` rect that was passed to the last `render` call so hit-testing
    /// works correctly.
    pub fn on_mouse(&mut self, ev: &MouseEvent, area: Rect) -> bool {
        if !rect_contains(area, ev.column, ev.row) {
            return false;
        }
        let snap_opt = self.rx.as_ref().map(|rx| rx.borrow().clone());
        match ev.kind {
            MouseEventKind::ScrollUp => {
                if let Some(snap) = snap_opt { self.cursor_prev(&snap); }
                true
            }
            MouseEventKind::ScrollDown => {
                if let Some(snap) = snap_opt { self.cursor_next(&snap); }
                true
            }
            MouseEventKind::Down(_) => {
                self.toggle_expand();
                true
            }
            _ => false,
        }
    }

    // ── Render ────────────────────────────────────────────────────────────────

    /// Render the transcript pane into `area`.
    ///
    /// Must be called every frame when `is_visible()` returns `true`.
    pub fn render(&mut self, f: &mut Frame, area: Rect) {
        let inner_w = area.width.saturating_sub(2);
        let inner_h = area.height.saturating_sub(2);

        // Flush the render cache on width change.
        if inner_w != self.last_width {
            self.cache.clear();
            self.last_width = inner_w;
        }

        self.area = Rect {
            x: area.x + 1,
            y: area.y + 1,
            width: inner_w,
            height: inner_h,
        };

        if let Some(rx) = &self.rx {
            let snap = rx.borrow().clone();

            // Tail-follow: advance cursor when the snapshot grows.
            let entry_count = snap.entries.len();
            if entry_count != self.last_entry_count {
                self.last_entry_count = entry_count;
                if self.interaction.following {
                    let nav = snap.navigable_entries(self.interaction.show_thinking);
                    if let Some(&last_nav) = nav.last() {
                        self.interaction.cursor = last_nav;
                    }
                }
            }

            let plan = crate::ui::widgets::transcript_layout::compute(
                &snap,
                &self.interaction,
                inner_w,
                &self.syntect,
                &mut self.cache,
            );
            self.scroll_offset = scroll_to_cursor(
                &plan.entry_rows,
                self.interaction.cursor,
                inner_h,
                self.scroll_offset,
            );

            TranscriptWidget::new(
                &snap,
                self.scroll_offset,
                &self.syntect,
                &mut self.cache,
                inner_w,
                &self.interaction,
            )
            .render(area, f.buffer_mut());
        } else {
            // Reader not yet started or no session-id available.
            let sid_hint = self
                .active_session_id
                .as_deref()
                .map(|s| format!(" ({}…)", &s[..s.len().min(8)]))
                .unwrap_or_default();
            let title = format!(" Transcript{sid_hint} ");

            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(theme::BORDER_ACTIVE))
                .title(Span::styled(
                    title,
                    Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
                ));
            let inner = block.inner(area);
            f.render_widget(block, area);
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    if self.pending_session_id.is_none() {
                        " No active session — start a REPL first"
                    } else {
                        " Starting transcript reader…"
                    },
                    theme::style_muted(),
                ))),
                inner,
            );
        }
    }

    // ── Cursor navigation helpers ─────────────────────────────────────────────

    fn cursor_next(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.interaction.show_thinking);
        if let Some(pos) = nav.iter().position(|&i| i == self.interaction.cursor) {
            if pos + 1 < nav.len() {
                self.interaction.cursor = nav[pos + 1];
            }
        } else if let Some(&first) = nav.first() {
            self.interaction.cursor = first;
        }
        let nav2 = snap.navigable_entries(self.interaction.show_thinking);
        self.interaction.following = nav2.last().copied() == Some(self.interaction.cursor);
    }

    fn cursor_prev(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.interaction.show_thinking);
        if let Some(pos) = nav.iter().position(|&i| i == self.interaction.cursor) {
            if pos > 0 {
                self.interaction.cursor = nav[pos - 1];
            }
        } else if let Some(&first) = nav.first() {
            self.interaction.cursor = first;
        }
        self.interaction.following = false;
    }

    fn cursor_by(&mut self, snap: &TranscriptSnapshot, delta: isize) {
        let nav = snap.navigable_entries(self.interaction.show_thinking);
        if nav.is_empty() { return; }
        let pos = nav
            .iter()
            .position(|&i| i == self.interaction.cursor)
            .unwrap_or(0);
        let new_pos = (pos as isize + delta).clamp(0, nav.len() as isize - 1) as usize;
        self.interaction.cursor = nav[new_pos];
        self.interaction.following = new_pos + 1 == nav.len();
    }

    fn cursor_first(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.interaction.show_thinking);
        if let Some(&first) = nav.first() {
            self.interaction.cursor = first;
        }
        self.interaction.following = false;
    }

    fn cursor_last(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.interaction.show_thinking);
        if let Some(&last) = nav.last() {
            self.interaction.cursor = last;
        }
        self.interaction.following = true;
    }

    fn toggle_expand(&mut self) {
        let idx = self.interaction.cursor;
        if self.interaction.expanded.contains(&idx) {
            self.interaction.expanded.remove(&idx);
        } else {
            self.interaction.expanded.insert(idx);
        }
        self.cache.remove(&(idx, true));
        self.cache.remove(&(idx, false));
    }

    fn toggle_thinking(&mut self, snap: &TranscriptSnapshot) {
        self.interaction.show_thinking = !self.interaction.show_thinking;
        self.cache.retain(|(idx, _), _| {
            !matches!(snap.entries.get(*idx), Some(TranscriptEntry::Thinking(_)))
        });
        if !self.interaction.show_thinking {
            if let Some(TranscriptEntry::Thinking(_)) = snap.entries.get(self.interaction.cursor) {
                let nav = snap.navigable_entries(false);
                let next = nav
                    .iter()
                    .find(|&&i| i > self.interaction.cursor)
                    .or_else(|| nav.first())
                    .copied();
                if let Some(next_idx) = next {
                    self.interaction.cursor = next_idx;
                }
            }
        }
    }

    // ── Accessors (also used by views) ────────────────────────────────────────

    /// Returns the active session-id if the reader is running.
    pub fn active_session_id(&self) -> Option<&str> {
        self.active_session_id.as_deref()
    }

    // ── Test helpers ──────────────────────────────────────────────────────────

    /// Returns the current interaction state (for tests).
    #[cfg(test)]
    pub fn interaction(&self) -> &TranscriptInteraction {
        &self.interaction
    }

    /// Returns whether the reader is currently active (for tests).
    #[cfg(test)]
    pub fn has_reader(&self) -> bool {
        self.reader.is_some()
    }
}

impl Default for TranscriptPane {
    fn default() -> Self {
        Self::new()
    }
}

// ── helper ────────────────────────────────────────────────────────────────────

fn rect_contains(r: Rect, col: u16, row: u16) -> bool {
    col >= r.x && col < r.x + r.width && row >= r.y && row < r.y + r.height
}

