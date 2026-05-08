//! `PtyHost` — owns the master PTY, child process, vt100 parser, and reader task.

use std::io::Write as _;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use crossterm::event::KeyEvent;
use portable_pty::{CommandBuilder, PtySize};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::event::AppEvent;

/// Owns one embedded PTY session.
pub struct PtyHost {
    master: Box<dyn portable_pty::MasterPty + Send>,
    writer: Box<dyn std::io::Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    pub parser: Arc<Mutex<vt100::Parser>>,
    size: (u16, u16),
    _reader_task: tokio::task::JoinHandle<()>,
}

impl PtyHost {
    /// Spawn `cmd args` inside a new PTY of size `(cols, rows)`.
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

        let child = pair.slave.spawn_command(cmd_builder)?;
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 0)));
        let parser_clone = Arc::clone(&parser);

        let reader_task = tokio::task::spawn_blocking(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        debug!("PTY reader EOF");
                        break;
                    }
                    Ok(n) => {
                        parser_clone.lock().unwrap().process(&buf[..n]);
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

        Ok(Self {
            master: pair.master,
            writer,
            child,
            parser,
            size: (cols, rows),
            _reader_task: reader_task,
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
        self.parser.lock().unwrap().set_size(rows, cols);
    }

    /// Forward a crossterm key event to the PTY child.
    pub fn send_key(&mut self, key: &KeyEvent) {
        if let Some(bytes) = crate::pty::keys::key_to_bytes(key) {
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
    }
}

// Needed because the reader task JoinHandle is Send but we also need PtyHost: Send.
// All fields are Send; the trait objects carry the Send bound already.
// SAFETY: explicit Send is safe here — all contained types are Send.
unsafe impl Send for PtyHost {}

// Read import used in spawn_blocking closure.
use std::io::Read;
