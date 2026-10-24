//! One daemon-owned PTY: the child process, its replay ring and screen model.
//!
//! Separate from any other PTY code on purpose: a terminal is reachable only
//! through `TerminalManager`, never through the retired `pty_*` verbs.
//!
//! Threads per session: a blocking **reader** (feeds the ring and the
//! `vt100` parser under one lock, then the reader hooks), and a **waiter**
//! (`child.wait()`, then the real exit code once the reader has drained).

use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use tracing::{debug, warn};

use crate::ipc::scrollback::ScrollbackBuf;

/// The replay ring keeps at least this many lines (it evicts whole read
/// chunks, so the cap leaves room for one chunk of `READ_CHUNK` newlines).
pub const RING_MAX_NEWLINES: usize = 16_000;
/// …and at most this many bytes.
pub const RING_MAX_BYTES: usize = 4 * 1024 * 1024;
/// Rows of scrollback the screen model keeps.
pub const PARSER_SCROLLBACK_ROWS: usize = 10_000;
/// Bytes per blocking read of the PTY master.
const READ_CHUNK: usize = 4096;
/// How long `kill` waits after SIGHUP before SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(2);
/// How long the waiter lets the reader drain after the child exited.
const DRAIN_WAIT: Duration = Duration::from_secs(1);

/// Variables a shell inside a terminal must not inherit: they would let a
/// `claude` (or anything else) started there impersonate the focus, reach
/// the MCP bridge, or bypass the approvals guard.
pub const SCRUBBED_ENV: &[&str] = &[
    "NOSTROMO_PTY_ID",
    "NOSTROMO_VIEW_ID",
    "NOSTROMO_FOCUS_TAG",
    "NOSTROMO_SESSION_ID",
    "NOSTROMO_MCP_SOCKET",
    "NOSTROMO_PTY",
    "NOSTROMO_GUARD_BIN",
    "NOSTROMO_APPROVALS_DIR",
    "CLAUDECODE",
];

/// Called with each chunk read from the PTY, under the screen lock (so in
/// order, and never concurrently with a replay snapshot). Must be quick and
/// must not call back into the session.
pub type ReaderHook = Box<dyn FnMut(&[u8]) + Send>;

/// Called once with the exit code (`None` if it could not be read).
pub type ExitHook = Box<dyn FnOnce(Option<i32>) + Send>;

struct Screen {
    ring: ScrollbackBuf,
    parser: vt100::Parser,
    hooks: Vec<ReaderHook>,
}

#[derive(Default)]
struct ExitState {
    /// `Some(code)` once the child has exited and output has drained.
    exited: Option<Option<i32>>,
    hooks: Vec<ExitHook>,
}

/// A running (or ended) PTY child.
pub struct TerminalSession {
    screen: Mutex<Screen>,
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    pid: Option<u32>,
    exit: Mutex<ExitState>,
    exit_cv: Condvar,
    reader_done: Mutex<bool>,
    reader_cv: Condvar,
}

impl TerminalSession {
    /// The user's login shell (argv0 `-<shell>`) in `cwd`.
    pub fn spawn_local(cwd: &Path, cols: u16, rows: u16) -> Result<Arc<Self>> {
        Self::spawn(CommandBuilder::new_default_prog(), cwd, &[], cols, rows)
    }

    /// `argv` (no shell) in `cwd`, with `env` on top of the scrubbed daemon
    /// environment. Used by tests, and by remote shells (2b).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn spawn_argv(
        argv: &[String],
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Self>> {
        let (program, args) = argv.split_first().context("empty argv")?;
        let mut cmd = CommandBuilder::new(program);
        cmd.args(args);
        Self::spawn(cmd, cwd, env, cols, rows)
    }

    fn spawn(
        mut cmd: CommandBuilder,
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Self>> {
        for key in SCRUBBED_ENV {
            cmd.env_remove(key);
        }
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Nostromo");
        if cmd.get_env("LANG").is_none() {
            cmd.env("LANG", "en_US.UTF-8");
        }
        for (k, v) in env {
            cmd.env(k, v);
        }
        cmd.cwd(cwd);

        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty")?;
        let mut child = pair.slave.spawn_command(cmd).context("spawn")?;
        // Only the child holds the slave from here, so the reader sees EOF
        // once the child (and anything it left holding the tty) is gone.
        drop(pair.slave);
        let reader = pair.master.try_clone_reader().context("pty reader")?;
        let writer = pair.master.take_writer().context("pty writer")?;
        let pid = child.process_id();

        let session = Arc::new(Self {
            screen: Mutex::new(Screen {
                ring: ScrollbackBuf::with_limits(RING_MAX_BYTES, RING_MAX_NEWLINES),
                parser: vt100::Parser::new(rows, cols, PARSER_SCROLLBACK_ROWS),
                hooks: Vec::new(),
            }),
            writer: Mutex::new(writer),
            master: Mutex::new(pair.master),
            killer: Mutex::new(child.clone_killer()),
            pid,
            exit: Mutex::new(ExitState::default()),
            exit_cv: Condvar::new(),
            reader_done: Mutex::new(false),
            reader_cv: Condvar::new(),
        });

        let for_reader = Arc::clone(&session);
        std::thread::Builder::new()
            .name("terminal-reader".into())
            .spawn(move || for_reader.read_loop(reader))
            .context("reader thread")?;

        let for_waiter = Arc::clone(&session);
        std::thread::Builder::new()
            .name("terminal-waiter".into())
            .spawn(move || {
                let code = match child.wait() {
                    Ok(status) => i32::try_from(status.exit_code()).ok(),
                    Err(e) => {
                        warn!("terminal child wait failed: {e}");
                        None
                    }
                };
                for_waiter.wait_reader_drained(DRAIN_WAIT);
                for_waiter.finish(code);
            })
            .context("waiter thread")?;

        Ok(session)
    }

    fn read_loop(&self, mut reader: Box<dyn Read + Send>) {
        let mut buf = vec![0u8; READ_CHUNK];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = &buf[..n];
                    let mut screen = self.screen.lock().unwrap_or_else(|e| e.into_inner());
                    screen.ring.push(chunk.to_vec());
                    screen.parser.process(chunk);
                    for hook in screen.hooks.iter_mut() {
                        hook(chunk);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                // EIO once the slave side is closed: the normal end.
                Err(e) => {
                    debug!("terminal reader ended: {e}");
                    break;
                }
            }
        }
        *self.reader_done.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.reader_cv.notify_all();
    }

    fn wait_reader_drained(&self, timeout: Duration) {
        let done = self.reader_done.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self
            .reader_cv
            .wait_timeout_while(done, timeout, |done| !*done);
    }

    fn finish(&self, code: Option<i32>) {
        let hooks = {
            let mut exit = self.exit.lock().unwrap_or_else(|e| e.into_inner());
            exit.exited = Some(code);
            std::mem::take(&mut exit.hooks)
        };
        self.exit_cv.notify_all();
        for hook in hooks {
            hook(code);
        }
    }

    /// The child's pid, if the platform reported one.
    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Write bytes to the child's terminal.
    pub fn write(&self, bytes: &[u8]) -> std::io::Result<()> {
        let mut w = self.writer.lock().unwrap_or_else(|e| e.into_inner());
        w.write_all(bytes)?;
        w.flush()
    }

    /// Resize the PTY and the screen model.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        self.master
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("pty resize")?;
        self.screen
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .parser
            .screen_mut()
            .set_size(rows, cols);
        Ok(())
    }

    /// `(cols, rows)` of the screen model.
    pub fn size(&self) -> (u16, u16) {
        let screen = self.screen.lock().unwrap_or_else(|e| e.into_inner());
        let (rows, cols) = screen.parser.screen().size();
        (cols, rows)
    }

    /// SIGHUP the child; SIGKILL it if it is still running after a grace.
    pub fn kill(self: &Arc<Self>) {
        if self.is_exited() {
            return;
        }
        if let Err(e) = self.killer.lock().unwrap_or_else(|e| e.into_inner()).kill() {
            debug!("terminal SIGHUP failed: {e}");
        }
        let (Some(pid), this) = (self.pid, Arc::clone(self)) else {
            return;
        };
        let _ = std::thread::Builder::new()
            .name("terminal-kill".into())
            .spawn(move || {
                if this.wait_exit(KILL_GRACE).is_none() {
                    // SAFETY: plain kill(2) on the pid we spawned and have not reaped.
                    unsafe {
                        libc::kill(pid as libc::pid_t, libc::SIGKILL);
                    }
                }
            });
    }

    /// Has the child exited (and its output drained)?
    pub fn is_exited(&self) -> bool {
        self.exit
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .exited
            .is_some()
    }

    /// Block up to `timeout` for the exit: `None` if still running,
    /// otherwise `Some(exit code)`.
    pub fn wait_exit(&self, timeout: Duration) -> Option<Option<i32>> {
        let exit = self.exit.lock().unwrap_or_else(|e| e.into_inner());
        let (exit, _) = self
            .exit_cv
            .wait_timeout_while(exit, timeout, |e| e.exited.is_none())
            .unwrap_or_else(|e| e.into_inner());
        exit.exited
    }

    /// Run `hook` once with the exit code, on another thread (never the
    /// caller's, which may hold the lock the hook takes).
    pub fn on_exit(&self, hook: ExitHook) {
        let mut exit = self.exit.lock().unwrap_or_else(|e| e.into_inner());
        match exit.exited {
            Some(code) => {
                drop(exit);
                let _ = std::thread::Builder::new()
                    .name("terminal-exit".into())
                    .spawn(move || hook(code));
            }
            None => exit.hooks.push(hook),
        }
    }

    /// Add a hook called with every chunk read from here on.
    pub fn add_reader_hook(&self, hook: ReaderHook) {
        self.screen
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .hooks
            .push(hook);
    }

    /// Run `f` with a consistent view of the screen: no chunk is read (and no
    /// hook runs) while it runs. `f` gets the replay bytes and `(cols, rows)`.
    pub fn with_replay<T>(&self, f: impl FnOnce(Vec<u8>, (u16, u16)) -> T) -> T {
        let screen = self.screen.lock().unwrap_or_else(|e| e.into_inner());
        let (rows, cols) = screen.parser.screen().size();
        let mut bytes = screen.ring.drain();
        bytes.extend(repaint(&screen.parser));
        f(bytes, (cols, rows))
    }

    /// The raw replay ring.
    pub fn ring_bytes(&self) -> Vec<u8> {
        self.screen
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ring
            .drain()
    }

    /// Escape codes that redraw the current screen (alternate screen
    /// included) on a terminal that has been fed the ring.
    pub fn repaint_bytes(&self) -> Vec<u8> {
        repaint(&self.screen.lock().unwrap_or_else(|e| e.into_inner()).parser)
    }

    /// What an attaching client is fed: the ring, then the repaint.
    pub fn replay_bytes(&self) -> Vec<u8> {
        self.with_replay(|bytes, _| bytes)
    }
}

fn repaint(parser: &vt100::Parser) -> Vec<u8> {
    let screen = parser.screen();
    let mut out = Vec::new();
    if screen.alternate_screen() {
        out.extend_from_slice(b"\x1b[?1049h");
    }
    out.extend(screen.state_formatted());
    out
}
