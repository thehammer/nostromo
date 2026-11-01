//! One daemon-owned PTY: the child process, its replay ring and screen model.
//!
//! Separate from any other PTY code on purpose: a terminal is reachable only
//! through `TerminalManager`, never through the retired `pty_*` verbs.
//!
//! Threads per session: a **reader** (feeds the ring and the `vt100` parser
//! under one lock, then the reader hooks; it polls so a closed terminal can
//! stop it even while a stray background job still holds the tty), a
//! **writer** (drains a bounded input queue into the PTY, so a child that stops
//! reading its input never blocks the caller), and a **waiter** (waits for the
//! child to exit, reaps it, then reports the real exit code once the reader
//! has drained).
//!
//! **Signals.** Nothing is ever sent to a reaped child's pid or group: the
//! kernel may have given that pid to a stranger. `signal_lock` is held across
//! "still unreaped?" + the signal, and across the waiter's reap, so a signal
//! cannot land between the kernel freeing the pid and `reaped` being set. The
//! reaped flag is checked first, then the non-reaping `waitid` probe.

use std::io::{Read, Write};
use std::os::fd::RawFd;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use tracing::{debug, warn};

use crate::ipc::orphans::{child_unreaped, Target};
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
/// How long the reader waits for output before it checks whether it was told
/// to stop.
const READER_POLL: Duration = Duration::from_millis(200);
/// Writes queued for the child before `write` reports it busy.
const INPUT_QUEUE: usize = 256;
/// The most bytes one `write` may carry; a larger one is refused outright.
pub const MAX_INPUT_FRAME_BYTES: usize = 256 * 1024;
/// The most input bytes queued for a child that is not reading (a write
/// that would pass this reports it busy). Bounds a stuck terminal's memory
/// at about this plus the one frame the writer thread holds.
pub const MAX_INPUT_QUEUED_BYTES: usize = 1024 * 1024;
/// The largest size a terminal may be given.
pub const MAX_COLS: u16 = 1000;
pub const MAX_ROWS: u16 = 500;

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

/// Like [`ReaderHook`], but also given the screen model as the chunk left it.
/// Returns `false` to be removed. Used by agent follow, which needs to know
/// when a full-screen program is showing and what is on the screen.
pub type ScreenHook = Box<dyn FnMut(&[u8], &vt100::Screen) -> bool + Send>;

/// Called once with the exit code (`None` if it could not be read).
pub type ExitHook = Box<dyn FnOnce(Option<i32>) + Send>;

/// Why `write` did not queue its bytes. Nothing was queued.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputError {
    /// One write over [`MAX_INPUT_FRAME_BYTES`].
    TooLarge,
    /// The child is not reading: [`INPUT_QUEUE`] writes or
    /// [`MAX_INPUT_QUEUED_BYTES`] bytes are already waiting.
    Busy,
    /// The terminal is gone.
    Gone,
}

/// How a session reaches its child. A seam so tests can simulate a reused pid
/// (a probe that says "still ours" after the reap, a recorder in place of
/// `kill(2)`); production always uses [`SignalOps::real`].
#[derive(Clone)]
pub struct SignalOps {
    /// Is `pid` still an unreaped child of ours? Never reaps.
    unreaped: fn(u32) -> bool,
    /// Deliver `sig` to the process or group.
    send: Arc<dyn Fn(Target, i32) + Send + Sync>,
}

impl SignalOps {
    pub fn real() -> Self {
        Self {
            unreaped: child_unreaped,
            send: Arc::new(|target, sig| target.signal(sig)),
        }
    }

    /// Custom probe and delivery (tests).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn with(
        unreaped: fn(u32) -> bool,
        send: impl Fn(Target, i32) + Send + Sync + 'static,
    ) -> Self {
        Self {
            unreaped,
            send: Arc::new(send),
        }
    }
}

struct Screen {
    ring: ScrollbackBuf,
    parser: vt100::Parser,
    hooks: Vec<ReaderHook>,
    screen_hooks: Vec<ScreenHook>,
}

/// What a spawn adds to the defaults.
#[derive(Default)]
struct SpawnOptions {
    /// Reader hooks installed before the reader starts.
    hooks: Vec<ReaderHook>,
    /// Sweep the child's process group when it exits on its own.
    sweep_group_on_exit: bool,
    /// Start the child with **only** `env` (no inherited daemon environment).
    clean_env: bool,
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
    input: SyncSender<Vec<u8>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    /// The master's fd, for the reader's poll. Valid while the reader runs:
    /// the reader holds an `Arc` of the session, which owns the master.
    master_fd: Option<RawFd>,
    pid: Option<u32>,
    /// What the shell's own process is called (the program started, and its
    /// name just after spawn), so a later `exec ssh …` (same pid, new program)
    /// is told apart from the shell itself.
    shell_names: Vec<String>,
    ops: SignalOps,
    /// Held while checking `reaped` and signalling, and by the waiter while it
    /// reaps and sets `reaped`: see the module docs.
    signal_lock: Mutex<()>,
    /// Set (under `signal_lock`) as soon as the child was reaped: its pid may
    /// be reused, so nothing is signalled from then on.
    reaped: AtomicBool,
    /// `kill` was called: whatever the shell leaves in its group when it exits
    /// is SIGKILLed before the shell is reaped.
    closing: AtomicBool,
    /// The same sweep happens when the child exits on its own (a remote
    /// shell's helper processes must not outlive their pane).
    sweep_group_on_exit: bool,
    /// Tells the reader to stop (the terminal was closed).
    stop_reader: AtomicBool,
    /// Input bytes queued and not yet written.
    queued_bytes: Arc<AtomicUsize>,
    /// Bytes ever accepted for the child's input by [`Self::write`] (the daemon's
    /// own accounting of input; the zero-bytes proof of command staging reads it).
    input_bytes_accepted: AtomicU64,
    /// Bytes ever written to the PTY master, counted by the one writer thread.
    input_bytes_written: Arc<AtomicU64>,
    exit: Mutex<ExitState>,
    exit_cv: Condvar,
    reader_done: Mutex<bool>,
    reader_cv: Condvar,
}

impl TerminalSession {
    /// The user's login shell (argv0 `-<shell>`) in `cwd`.
    pub fn spawn_local(cwd: &Path, cols: u16, rows: u16, ops: SignalOps) -> Result<Arc<Self>> {
        Self::spawn(
            CommandBuilder::new_default_prog(),
            cwd,
            &[],
            cols,
            rows,
            ops,
            SpawnOptions::default(),
        )
    }

    /// `argv` (no shell) in `cwd`, with `env` on top of the scrubbed daemon
    /// environment. Used by tests.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn spawn_argv(
        argv: &[String],
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Self>> {
        Self::spawn_argv_with(argv, cwd, env, cols, rows, SignalOps::real())
    }

    /// [`Self::spawn_argv`] with its signals going through `ops`.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn spawn_argv_with(
        argv: &[String],
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
        ops: SignalOps,
    ) -> Result<Arc<Self>> {
        let cmd = argv_command(argv)?;
        Self::spawn(cmd, cwd, env, cols, rows, ops, SpawnOptions::default())
    }

    /// [`Self::spawn_argv`] with `hook` installed before the reader starts, so
    /// it sees the process's very first byte (a remote shell's connect marker
    /// can arrive before a later `add_reader_hook` would).
    pub(crate) fn spawn_argv_observed(
        argv: &[String],
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
        hook: ReaderHook,
    ) -> Result<Arc<Self>> {
        let cmd = argv_command(argv)?;
        let options = SpawnOptions {
            hooks: vec![hook],
            sweep_group_on_exit: true,
            clean_env: true,
        };
        Self::spawn(cmd, cwd, env, cols, rows, SignalOps::real(), options)
    }

    fn spawn(
        mut cmd: CommandBuilder,
        cwd: &Path,
        env: &[(String, String)],
        cols: u16,
        rows: u16,
        ops: SignalOps,
        options: SpawnOptions,
    ) -> Result<Arc<Self>> {
        if options.clean_env {
            // A remote shell's helper gets exactly what the caller lists, not
            // the daemon's environment minus a denylist.
            cmd.env_clear();
        } else {
            for key in SCRUBBED_ENV {
                cmd.env_remove(key);
            }
            cmd.env("TERM", "xterm-256color");
            cmd.env("COLORTERM", "truecolor");
            cmd.env("TERM_PROGRAM", "Nostromo");
            if cmd.get_env("LANG").is_none() {
                cmd.env("LANG", "en_US.UTF-8");
            }
        }
        for (k, v) in env {
            cmd.env(k, v);
        }
        cmd.cwd(cwd);

        let started_as = cmd
            .get_argv()
            .first()
            .and_then(|a| Path::new(a).file_name())
            .map(|n| n.to_string_lossy().trim_start_matches('-').to_string());
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
        let master_fd = pair.master.as_raw_fd();
        let (input, queued) = sync_channel(INPUT_QUEUE);
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        let input_bytes_written = Arc::new(AtomicU64::new(0));

        let session = Arc::new(Self {
            screen: Mutex::new(Screen {
                ring: ScrollbackBuf::with_limits(RING_MAX_BYTES, RING_MAX_NEWLINES),
                parser: vt100::Parser::new(rows, cols, PARSER_SCROLLBACK_ROWS),
                hooks: options.hooks,
                screen_hooks: Vec::new(),
            }),
            input,
            master: Mutex::new(pair.master),
            master_fd,
            pid,
            shell_names: started_as
                .into_iter()
                .chain(pid.and_then(process_name))
                .collect(),
            ops,
            signal_lock: Mutex::new(()),
            reaped: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            sweep_group_on_exit: options.sweep_group_on_exit,
            stop_reader: AtomicBool::new(false),
            queued_bytes: Arc::clone(&queued_bytes),
            input_bytes_accepted: AtomicU64::new(0),
            input_bytes_written: Arc::clone(&input_bytes_written),
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

        std::thread::Builder::new()
            .name("terminal-writer".into())
            .spawn(move || write_loop(writer, queued, queued_bytes, input_bytes_written))
            .context("writer thread")?;

        let for_waiter = Arc::clone(&session);
        std::thread::Builder::new()
            .name("terminal-waiter".into())
            .spawn(move || {
                // Learn of the exit without reaping, so the reap below can
                // happen under `signal_lock`.
                if let Some(pid) = pid {
                    wait_until_exited(pid);
                }
                let waited = {
                    let _guard = for_waiter
                        .signal_lock
                        .lock()
                        .unwrap_or_else(|e| e.into_inner());
                    if for_waiter.closing.load(Ordering::SeqCst) || for_waiter.sweep_group_on_exit {
                        // Closed: nothing the shell left in its group outlives it.
                        // The shell is a zombie, not reaped, so its pid and group
                        // are still ours.
                        for_waiter.signal_locked(libc::SIGKILL);
                    }
                    let waited = child.wait();
                    for_waiter.reaped.store(true, Ordering::SeqCst);
                    waited
                };
                let code = match waited {
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
            if self.stop_reader.load(Ordering::SeqCst) {
                break;
            }
            if let Some(fd) = self.master_fd {
                if !readable(fd, READER_POLL) {
                    continue;
                }
            }
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = &buf[..n];
                    let mut guard = self.screen.lock().unwrap_or_else(|e| e.into_inner());
                    let screen = &mut *guard;
                    screen.ring.push(chunk.to_vec());
                    screen.parser.process(chunk);
                    for hook in screen.hooks.iter_mut() {
                        hook(chunk);
                    }
                    let parser = &screen.parser;
                    screen
                        .screen_hooks
                        .retain_mut(|hook| hook(chunk, parser.screen()));
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

    /// What has the terminal in the foreground: the shell itself (at its
    /// prompt, or running a builtin), or another program (`ssh`, `sleep`, an
    /// `exec`ed replacement). `Unknown` when the platform cannot say. Like
    /// tmux: `tcgetpgrp` on the pty master against the shell's pid.
    ///
    /// Not a prompt detector: a builtin waiting for input (`read`) is still the
    /// shell. Cheap (a syscall and a name lookup), safe to call from a timer.
    pub fn foreground(&self) -> Foreground {
        let (Some(fd), Some(pid)) = (self.master_fd, self.pid) else {
            return Foreground::Unknown;
        };
        if self.is_exited() {
            return Foreground::Unknown;
        }
        // SAFETY: `fd` is the pty master this session owns (kept open for the
        // session's life); tcgetpgrp only reads.
        let group = unsafe { libc::tcgetpgrp(fd) };
        if group <= 0 {
            return Foreground::Unknown;
        }
        let group = group as u32;
        if group != pid {
            return match process_name(group) {
                Some(name) => Foreground::Program(sanitize_program_name(&name)),
                None => Foreground::Unknown,
            };
        }
        // The kernel truncates names (Linux: 15 bytes), so a prefix matches.
        let is_shell = |now: &str| {
            self.shell_names
                .iter()
                .any(|n| n.starts_with(now) || now.starts_with(n.as_str()))
        };
        match process_name(pid) {
            None => Foreground::Unknown,
            Some(now) if !self.shell_names.is_empty() && !is_shell(&now) => {
                Foreground::Program(sanitize_program_name(&now))
            }
            Some(_) => Foreground::Shell,
        }
    }

    /// Queue bytes for the child's terminal. Never blocks: [`InputError::TooLarge`]
    /// for a write over [`MAX_INPUT_FRAME_BYTES`], [`InputError::Busy`] when the
    /// queue is full by count or by [`MAX_INPUT_QUEUED_BYTES`] (the child is not
    /// reading its input), [`InputError::Gone`] once the terminal is gone.
    pub fn write(&self, bytes: &[u8]) -> Result<(), InputError> {
        if bytes.len() > MAX_INPUT_FRAME_BYTES {
            return Err(InputError::TooLarge);
        }
        let queued = self.queued_bytes.fetch_add(bytes.len(), Ordering::SeqCst) + bytes.len();
        if queued > MAX_INPUT_QUEUED_BYTES {
            self.queued_bytes.fetch_sub(bytes.len(), Ordering::SeqCst);
            return Err(InputError::Busy);
        }
        match self.input.try_send(bytes.to_vec()) {
            Ok(()) => {
                self.input_bytes_accepted
                    .fetch_add(bytes.len() as u64, Ordering::SeqCst);
                Ok(())
            }
            Err(e) => {
                self.queued_bytes.fetch_sub(bytes.len(), Ordering::SeqCst);
                Err(match e {
                    TrySendError::Full(_) => InputError::Busy,
                    TrySendError::Disconnected(_) => InputError::Gone,
                })
            }
        }
    }

    /// Bytes ever accepted for the child's input.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn input_bytes_accepted(&self) -> u64 {
        self.input_bytes_accepted.load(Ordering::SeqCst)
    }

    /// Bytes ever written to the PTY master: every write goes through the one
    /// writer thread, which counts them. Zero for a terminal nobody typed into.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn input_bytes_written(&self) -> u64 {
        self.input_bytes_written.load(Ordering::SeqCst)
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

    /// Close the terminal: SIGHUP the shell and its process group, SIGKILL
    /// them if the shell is still running after a grace (and, once the shell
    /// exits, whatever it left in its group), then stop the reader so the
    /// ring, the screen model and the PTY go with the pane. Nothing is
    /// signalled once the child has been reaped.
    pub fn kill(self: &Arc<Self>) {
        self.hang_up();
        let this = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("terminal-kill".into())
            .spawn(move || {
                if this.wait_exit(KILL_GRACE).is_none() {
                    this.signal(libc::SIGKILL);
                    let _ = this.wait_exit(KILL_GRACE);
                }
                this.stop_reader.store(true, Ordering::SeqCst);
            });
        if spawned.is_err() {
            self.stop_reader.store(true, Ordering::SeqCst);
        }
    }

    /// Mark the session closing and send SIGHUP (unless the child was reaped).
    fn hang_up(&self) {
        let _guard = self.signal_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.closing.store(true, Ordering::SeqCst);
        self.signal_locked(libc::SIGHUP);
    }

    /// Signal the child's group and the child, unless it was reaped.
    fn signal(&self, sig: i32) {
        let _guard = self.signal_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.signal_locked(sig);
    }

    /// `signal` for a caller holding `signal_lock`. The reaped flag is read
    /// first; only an unreaped child is then probed (a reaped pid may name a
    /// stranger that the probe would also call "ours").
    fn signal_locked(&self, sig: i32) {
        let Some(pid) = self.pid else {
            return;
        };
        if self.reaped.load(Ordering::SeqCst) || !(self.ops.unreaped)(pid) {
            return;
        }
        // The shell is the session leader (portable-pty `setsid`s the child),
        // so its pid is also its group's id.
        (self.ops.send)(Target::Group(pid), sig);
        (self.ops.send)(Target::Pid(pid), sig);
    }

    /// Has the child been reaped (its pid is no longer ours)?
    #[cfg(test)]
    pub(crate) fn is_reaped(&self) -> bool {
        self.reaped.load(Ordering::SeqCst)
    }

    /// Has the reader thread finished (EOF, or told to stop)?
    #[cfg(test)]
    pub(crate) fn reader_finished(&self) -> bool {
        *self.reader_done.lock().unwrap_or_else(|e| e.into_inner())
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

    /// Look at the current screen with `start`, and add the [`ScreenHook`] it
    /// returns, in one step: the hook gets exactly the chunks read after
    /// `start` looked.
    pub fn add_screen_hook<T>(&self, start: impl FnOnce(&vt100::Screen) -> (T, ScreenHook)) -> T {
        let mut screen = self.screen.lock().unwrap_or_else(|e| e.into_inner());
        let (value, hook) = start(screen.parser.screen());
        screen.screen_hooks.push(hook);
        value
    }

    /// Run `f` on the current screen model (no chunk is read meanwhile).
    pub fn with_screen<T>(&self, f: impl FnOnce(&vt100::Screen) -> T) -> T {
        f(self
            .screen
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .parser
            .screen())
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

/// Feed queued input to the PTY until the session (the sender) is gone or
/// the terminal stops taking writes.
/// `argv` as a command: element 0 is the program, the rest are its arguments.
/// No shell.
fn argv_command(argv: &[String]) -> Result<CommandBuilder> {
    let (program, args) = argv.split_first().context("empty argv")?;
    let mut cmd = CommandBuilder::new(program);
    cmd.args(args);
    Ok(cmd)
}

fn write_loop(
    mut writer: Box<dyn Write + Send>,
    queued: Receiver<Vec<u8>>,
    queued_bytes: Arc<AtomicUsize>,
    input_bytes_written: Arc<AtomicU64>,
) {
    for bytes in queued {
        let result = writer.write_all(&bytes).and_then(|()| writer.flush());
        if result.is_ok() {
            input_bytes_written.fetch_add(bytes.len() as u64, Ordering::SeqCst);
        }
        queued_bytes.fetch_sub(bytes.len(), Ordering::SeqCst);
        if let Err(e) = result {
            debug!("terminal writer ended: {e}");
            return;
        }
    }
}

/// Block until `pid` (our child) has exited, without reaping it.
fn wait_until_exited(pid: u32) {
    loop {
        // SAFETY: `waitid` fills a zeroed `siginfo_t` we own; `WNOWAIT` leaves
        // the child's state untouched, so it can still be waited for.
        let rc = unsafe {
            let mut info: libc::siginfo_t = std::mem::zeroed();
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        // Done, or not waitable at all (the caller's `wait` then decides).
        if rc == 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return;
        }
    }
}

/// Is there something to read on `fd` (data, hangup or an error: `read` then
/// says which), after waiting up to `timeout`? `false` on timeout.
fn readable(fd: RawFd, timeout: Duration) -> bool {
    let mut p = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
    // SAFETY: one valid `pollfd` that we own.
    let rc = unsafe { libc::poll(&mut p, 1, ms) };
    match rc {
        0 => false,
        n if n < 0 => std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted,
        _ => true,
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

/// What [`TerminalSession::foreground`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Foreground {
    Shell,
    /// Another program (its sanitised name).
    Program(String),
    Unknown,
}

/// The longest program name kept, in Unicode scalars.
const MAX_PROGRAM_NAME_CHARS: usize = 24;

/// `name` as printable text of at most [`MAX_PROGRAM_NAME_CHARS`] scalars.
fn sanitize_program_name(name: &str) -> String {
    let clean: String = name
        .chars()
        .filter(|c| !c.is_control() && !crate::data::work::is_invisible(*c))
        .take(MAX_PROGRAM_NAME_CHARS)
        .collect();
    if clean.is_empty() {
        "unknown program".to_string()
    } else {
        clean
    }
}

/// The name of process `pid` (macOS: `proc_name`).
#[cfg(target_os = "macos")]
fn process_name(pid: u32) -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its length; proc_name writes at most that.
    let n = unsafe {
        libc::proc_name(
            pid as libc::c_int,
            buf.as_mut_ptr() as *mut libc::c_void,
            buf.len() as u32,
        )
    };
    if n <= 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

/// The name of process `pid` (Linux: `/proc/<pid>/comm`).
#[cfg(target_os = "linux")]
fn process_name(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .ok()
        .map(|s| s.trim_end().to_string())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn process_name(_pid: u32) -> Option<String> {
    None
}
