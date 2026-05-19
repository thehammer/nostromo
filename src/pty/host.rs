//! `PtyHost` — owns the master PTY, child process, vt100 parser, and reader task.

use std::io::Write as _;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use crossterm::event::KeyEvent;
use portable_pty::{CommandBuilder, PtySize};
use tokio::sync::mpsc;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::event::AppEvent;
use crate::mcp::state::McpSharedState;

/// Env var keys injected into every spawned PTY subprocess.
pub const ENV_VIEW_ID: &str = "NOSTROMO_VIEW_ID";
pub const ENV_PTY_ID: &str = "NOSTROMO_PTY_ID";
pub const ENV_SESSION_ID: &str = "NOSTROMO_SESSION_ID";
pub const ENV_MCP_SOCKET: &str = "NOSTROMO_MCP_SOCKET";

/// Identifiers returned from a successful [`PtyHost::spawn`].
///
/// Both ids are also injected as env vars into the child process so the agent
/// running inside the PTY can report them back via the MCP bridge.
#[derive(Debug, Clone)]
pub struct PtySpawnIds {
    /// UUID injected as `NOSTROMO_PTY_ID`.
    pub nostromo_pty_id: String,
    /// UUID injected as `NOSTROMO_SESSION_ID`.
    pub nostromo_session_id: String,
}

/// Owns one embedded PTY session.
pub struct PtyHost {
    master: Box<dyn portable_pty::MasterPty + Send>,
    writer: Box<dyn std::io::Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    pub parser: Arc<Mutex<vt100::Parser>>,
    size: (u16, u16),
    _reader_task: tokio::task::JoinHandle<()>,
    /// Nostromo identity ids injected at spawn time.
    pub spawn_ids: PtySpawnIds,
    /// Shared MCP state; used on Drop to deregister the PTY.
    mcp_state: Option<Arc<McpSharedState>>,
    /// Current top-of-stack kitty keyboard flags for this PTY.
    /// `0` means legacy mode (no kitty protocol active).
    kitty_flags: Arc<AtomicU32>,
}

impl PtyHost {
    /// Spawn `cmd args` inside a new PTY of size `(cols, rows)`.
    ///
    /// Injects `NOSTROMO_VIEW_ID`, `NOSTROMO_PTY_ID`, `NOSTROMO_SESSION_ID`,
    /// and `NOSTROMO_MCP_SOCKET` into the child environment.  The generated
    /// ids are also available via `PtyHost::spawn_ids`.
    ///
    /// If `mcp_state` is provided the PTY is registered with the shared MCP
    /// state on spawn and deregistered automatically on `Drop`.
    ///
    /// `event_tx` is used to send `AppEvent::AgentUpdate` whenever new PTY
    /// data arrives so the main loop redraws without waiting for the next tick.
    pub fn spawn(
        cmd: &str,
        args: &[&str],
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
    ) -> Result<Self> {
        let mcp_socket = crate::mcp::socket::default_socket_path();
        Self::spawn_with_env(cmd, args, (cols, rows), event_tx, view_id, &mcp_socket, None)
    }

    /// Like [`spawn`] but registers the spawned PTY with `mcp_state`.
    pub fn spawn_with_mcp(
        cmd: &str,
        args: &[&str],
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
        mcp_state: Arc<McpSharedState>,
    ) -> Result<Self> {
        let mcp_socket = crate::mcp::socket::default_socket_path();
        Self::spawn_with_env(
            cmd,
            args,
            (cols, rows),
            event_tx,
            view_id,
            &mcp_socket,
            Some(mcp_state),
        )
    }

    /// Spawn with an explicit MCP socket path.
    ///
    /// Separated from `spawn` so callers (and tests) can override the socket
    /// path without touching the global env var.
    pub fn spawn_with_env(
        cmd: &str,
        args: &[&str],
        (cols, rows): (u16, u16),
        event_tx: mpsc::UnboundedSender<AppEvent>,
        view_id: &'static str,
        mcp_socket: &std::path::Path,
        mcp_state: Option<Arc<McpSharedState>>,
    ) -> Result<Self> {
        let nostromo_pty_id = Uuid::new_v4().to_string();
        let nostromo_session_id = Uuid::new_v4().to_string();

        let pty_system = portable_pty::native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let mut cmd_builder = CommandBuilder::new(cmd);
        for arg in args {
            cmd_builder.arg(arg);
        }
        if let Ok(cwd) = std::env::current_dir() {
            cmd_builder.cwd(cwd);
        }

        // Inject Nostromo identity env vars.
        cmd_builder.env(ENV_VIEW_ID, view_id);
        cmd_builder.env(ENV_PTY_ID, &nostromo_pty_id);
        cmd_builder.env(ENV_SESSION_ID, &nostromo_session_id);
        cmd_builder.env(ENV_MCP_SOCKET, mcp_socket);

        let child = pair.slave.spawn_command(cmd_builder)?;
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 1000)));
        let parser_clone = Arc::clone(&parser);

        let mut kitty_tracker = crate::pty::kitty::KittyFlagsTracker::new();
        let kitty_flags = kitty_tracker.flags();

        let reader_task = tokio::task::spawn_blocking(move || {
            let mut buf = [0u8; 4096];
            let mut filter = crate::pty::altscreen::AltScreenFilter::new();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        debug!("PTY reader EOF");
                        break;
                    }
                    Ok(n) => {
                        let chunk = &buf[..n];
                        let flags_before = kitty_tracker.flags().load(Ordering::Relaxed);
                        // Track kitty flag escapes (does not mutate chunk).
                        kitty_tracker.feed(chunk);
                        let flags_after = kitty_tracker.flags().load(Ordering::Relaxed);
                        if flags_after != flags_before {
                            debug!(view_id, flags_before, flags_after, "kitty flags changed");
                        }
                        let filtered = filter.process(chunk);
                        parser_clone.lock().unwrap().process(&filtered);
                        let _ = event_tx.send(AppEvent::AgentUpdate { view_id });
                    }
                    Err(e) => {
                        // EAGAIN / connection reset at EOF — normal on macOS
                        use std::io::ErrorKind;
                        if matches!(
                            e.kind(),
                            ErrorKind::WouldBlock
                                | ErrorKind::Interrupted
                                | ErrorKind::ConnectionReset
                        ) {
                            break;
                        }
                        warn!("PTY read error: {e}");
                        break;
                    }
                }
            }
        });

        // Register the PTY identity with MCP state (async — spawn a task).
        if let Some(ref state) = mcp_state {
            let state = state.clone();
            let pty_id_reg = nostromo_pty_id.clone();
            let session_id_reg = nostromo_session_id.clone();
            tokio::spawn(async move {
                state
                    .register_pty(
                        pty_id_reg,
                        crate::mcp::state::PtyIdentity {
                            view_id,
                            session_id: session_id_reg,
                            spawned_at: std::time::SystemTime::now(),
                        },
                    )
                    .await;
            });
        }

        Ok(Self {
            master: pair.master,
            writer,
            child,
            parser,
            size: (cols, rows),
            _reader_task: reader_task,
            spawn_ids: PtySpawnIds {
                nostromo_pty_id,
                nostromo_session_id,
            },
            mcp_state,
            kitty_flags,
        })
    }

    /// Resize the PTY and update the vt100 parser dimensions.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        if (cols, rows) == self.size {
            return;
        }
        self.size = (cols, rows);
        if let Err(e) = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        }) {
            warn!("PTY resize error: {e}");
        }
        self.parser.lock().unwrap().screen_mut().set_size(rows, cols);
    }

    /// Forward a crossterm key event to the PTY child.
    pub fn send_key(&mut self, key: &KeyEvent) {
        let flags = self.kitty_flags.load(Ordering::Relaxed);
        if let Some(bytes) = crate::pty::keys::key_to_bytes_for(key, flags) {
            tracing::trace!(?key, flags, ?bytes, "send_key");
            use std::io::ErrorKind;
            if let Err(e) = self.writer.write_all(&bytes) {
                if !matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) {
                    warn!("PTY write error: {e}");
                }
            }
        }
    }

    /// Current PTY size `(cols, rows)`.
    pub fn size(&self) -> (u16, u16) {
        self.size
    }
}

impl Drop for PtyHost {
    fn drop(&mut self) {
        self.child.kill().ok();

        // Deregister from MCP state.  Spawning a tokio task from Drop is safe
        // when the runtime is still running (which it always is during normal
        // shutdown of a view — the TUI exits after the event loop finishes).
        if let Some(state) = self.mcp_state.take() {
            let pty_id = self.spawn_ids.nostromo_pty_id.clone();
            tokio::spawn(async move {
                state.deregister_pty(&pty_id).await;
            });
        }
    }
}

// Needed because the reader task JoinHandle is Send but we also need PtyHost: Send.
// All fields are Send; the trait objects carry the Send bound already.
// SAFETY: explicit Send is safe here — all contained types are Send.
unsafe impl Send for PtyHost {}

// Read import used in spawn_blocking closure.
use std::io::Read;
