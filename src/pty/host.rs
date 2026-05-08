//! `PtyHost` — owns the master PTY, child process, vt100 parser, and reader task.

use std::io::Write as _;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
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
                            ErrorKind::WouldBlock | ErrorKind::Interrupted | ErrorKind::ConnectionReset
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
        let bytes: Vec<u8> = match key.code {
            KeyCode::Char(c) => {
                if key.modifiers.contains(KeyModifiers::CONTROL) {
                    let byte = (c as u8) & 0x1f;
                    vec![byte]
                } else {
                    let mut buf = [0u8; 4];
                    c.encode_utf8(&mut buf).as_bytes().to_vec()
                }
            }
            KeyCode::Enter => b"\r".to_vec(),
            KeyCode::Backspace => b"\x7f".to_vec(),
            KeyCode::Tab => b"\t".to_vec(),
            KeyCode::Esc => b"\x1b".to_vec(),
            KeyCode::Up => b"\x1b[A".to_vec(),
            KeyCode::Down => b"\x1b[B".to_vec(),
            KeyCode::Right => b"\x1b[C".to_vec(),
            KeyCode::Left => b"\x1b[D".to_vec(),
            KeyCode::Home => b"\x1b[H".to_vec(),
            KeyCode::End => b"\x1b[F".to_vec(),
            KeyCode::PageUp => b"\x1b[5~".to_vec(),
            KeyCode::PageDown => b"\x1b[6~".to_vec(),
            KeyCode::Delete => b"\x1b[3~".to_vec(),
            KeyCode::Insert => b"\x1b[2~".to_vec(),
            KeyCode::F(n) => {
                // F1-F4 use SS3, F5+ use CSI
                match n {
                    1 => b"\x1bOP".to_vec(),
                    2 => b"\x1bOQ".to_vec(),
                    3 => b"\x1bOR".to_vec(),
                    4 => b"\x1bOS".to_vec(),
                    5 => b"\x1b[15~".to_vec(),
                    6 => b"\x1b[17~".to_vec(),
                    7 => b"\x1b[18~".to_vec(),
                    8 => b"\x1b[19~".to_vec(),
                    9 => b"\x1b[20~".to_vec(),
                    10 => b"\x1b[21~".to_vec(),
                    11 => b"\x1b[23~".to_vec(),
                    12 => b"\x1b[24~".to_vec(),
                    _ => return,
                }
            }
            _ => return,
        };

        use std::io::ErrorKind;
        if let Err(e) = self.writer.write_all(&bytes) {
            if !matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) {
                warn!("PTY write error: {e}");
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
