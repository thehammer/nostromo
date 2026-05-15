//! Embedded PTY support.
//!
//! - [`PtyHost`]        — in-process PTY (daemon not available).
//! - [`DaemonPtyClient`] — PTY owned by `nostromd` daemon.
//! - [`PtyBackend`]     — enum that unifies both variants behind a single interface.
//! - [`PtyFactory`]     — trait for spawning / reattaching PTYs.
//! - [`PtyWidget`]      — Ratatui widget that renders a `vt100::Parser` screen.

pub mod altscreen;
pub mod client;
pub mod host;
pub mod keys;
pub mod kitty;
pub mod widget;

pub use client::{DaemonPtyClient, DaemonPtyFactory, InProcessPtyFactory, PtyFactory};
pub use host::PtyHost;
pub use widget::PtyWidget;

use std::sync::{Arc, Mutex};

use crossterm::event::KeyEvent;

/// Uniform PTY handle usable by views regardless of where the PTY lives.
pub enum PtyBackend {
    /// PTY runs in this process (no daemon, or daemon unavailable).
    InProcess(PtyHost),
    /// PTY runs inside `nostromd`; this is a remote handle.
    Daemon(DaemonPtyClient),
}

impl PtyBackend {
    /// Resize the PTY.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        match self {
            PtyBackend::InProcess(h) => h.resize(cols, rows),
            PtyBackend::Daemon(c) => c.resize(cols, rows),
        }
    }

    /// Forward a key event to the PTY child.
    pub fn send_key(&mut self, key: &KeyEvent) {
        match self {
            PtyBackend::InProcess(h) => h.send_key(key),
            PtyBackend::Daemon(c) => c.send_key(key),
        }
    }

    /// Shared reference to the `vt100::Parser` for rendering.
    pub fn parser(&self) -> Arc<Mutex<vt100::Parser>> {
        match self {
            PtyBackend::InProcess(h) => Arc::clone(&h.parser),
            PtyBackend::Daemon(c) => Arc::clone(&c.parser),
        }
    }

    /// Current PTY size `(cols, rows)`.
    pub fn size(&self) -> (u16, u16) {
        match self {
            PtyBackend::InProcess(h) => h.size(),
            PtyBackend::Daemon(c) => c.size(),
        }
    }
}
