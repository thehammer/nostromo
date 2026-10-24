//! Output fan-out for one terminal: to the attached operator connections
//! only, never on the broadcast channel.
//!
//! **Coalescer.** A chunk read from the PTY is sent at once if nothing was
//! sent for this terminal in the last [`COALESCE`] (leading edge), or if input
//! was written since the last send (so a keystroke's echo is never held back
//! by the window); otherwise it is batched and sent when that window ends, or
//! as soon as [`MAX_BATCH`] bytes are waiting.
//!
//! **Lag.** Each connection's terminal stream is a bounded channel. A send
//! that finds it full marks the attachment lagged: it gets no further output
//! until a fresh `TerminalReplay` fits, so a slow client sees a correct screen
//! again instead of a stream with holes.
//!
//! **Lock order.** The session's screen lock, then this fan-out's lock. The
//! reader hook runs under the screen lock and calls [`Fanout::on_output`];
//! [`Fanout::attach`] is called from inside `TerminalSession::with_replay`.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use base64::Engine as _;
use tokio::sync::mpsc;

use super::session::TerminalSession;
use super::{LatencyProbe, StreamBatch};
use crate::ipc::protocol::ServerMsg;

/// The coalescing window.
pub const COALESCE: Duration = Duration::from_millis(8);
/// Send a batch at once when this many bytes are waiting.
pub const MAX_BATCH: usize = 64 * 1024;
/// Raw bytes per frame (base64 grows it by a third; `MAX_FRAME_LEN` is 4 MiB).
const FRAME_BYTES: usize = 1024 * 1024;
/// How often a lagged attachment's replay is retried.
const LAG_RETRY: Duration = Duration::from_millis(20);

struct Attachment {
    stream: mpsc::Sender<StreamBatch>,
    lagged: bool,
}

#[derive(Default)]
struct State {
    attached: HashMap<String, Attachment>,
    pending: Vec<u8>,
    last_sent: Option<Instant>,
    input_at: Option<Instant>,
    closed: bool,
}

pub(crate) struct Fanout {
    terminal_id: String,
    state: Mutex<State>,
    cv: Condvar,
    probe: Arc<Mutex<Option<LatencyProbe>>>,
}

impl Fanout {
    /// A fan-out for a live session, with its flusher thread.
    pub(crate) fn start(
        terminal_id: &str,
        session: &Arc<TerminalSession>,
        probe: Arc<Mutex<Option<LatencyProbe>>>,
    ) -> Arc<Self> {
        let fanout = Self::idle(terminal_id, probe);
        let (weak_session, for_flusher) = (Arc::downgrade(session), Arc::clone(&fanout));
        let spawned = std::thread::Builder::new()
            .name("terminal-flush".into())
            .spawn(move || for_flusher.flush_loop(weak_session));
        if let Err(e) = spawned {
            tracing::warn!("terminal flusher thread: {e}");
        }
        let for_hook = Arc::clone(&fanout);
        session.add_reader_hook(Box::new(move |chunk| for_hook.on_output(chunk)));
        fanout
    }

    /// A fan-out with no process behind it (an ended terminal from a previous
    /// daemon): attach still answers with a replay.
    pub(crate) fn idle(terminal_id: &str, probe: Arc<Mutex<Option<LatencyProbe>>>) -> Arc<Self> {
        Arc::new(Self {
            terminal_id: terminal_id.to_string(),
            state: Mutex::new(State::default()),
            cv: Condvar::new(),
            probe,
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Note that input was just written (for the latency probe).
    pub(crate) fn input_received(&self) {
        let mut st = self.lock();
        if st.input_at.is_none() {
            st.input_at = Some(Instant::now());
        }
    }

    /// A chunk from the PTY (reader thread, under the screen lock).
    fn on_output(&self, chunk: &[u8]) {
        let mut st = self.lock();
        // Closed: the terminal is gone (or ended) as far as clients know.
        if st.closed || st.attached.is_empty() {
            st.input_at = None;
            return;
        }
        let quiet = st.last_sent.is_none_or(|t| t.elapsed() >= COALESCE);
        if st.pending.is_empty() && quiet {
            self.send(&mut st, chunk);
            return;
        }
        st.pending.extend_from_slice(chunk);
        // Input since the last send: this is (likely) its echo, so it goes
        // now, with whatever was waiting, however recent the last send.
        if st.pending.len() >= MAX_BATCH || st.input_at.is_some() {
            self.flush(&mut st);
        } else {
            self.cv.notify_all();
        }
    }

    fn flush(&self, st: &mut State) {
        if st.pending.is_empty() {
            return;
        }
        let bytes = std::mem::take(&mut st.pending);
        self.send(st, &bytes);
    }

    /// Send `bytes` to every attachment that is keeping up.
    fn send(&self, st: &mut State, bytes: &[u8]) {
        let batch = output_frames(&self.terminal_id, bytes);
        st.attached.retain(|_, a| {
            if a.lagged {
                return true;
            }
            match a.stream.try_send(batch.clone()) {
                Ok(()) => true,
                Err(mpsc::error::TrySendError::Full(_)) => {
                    a.lagged = true;
                    true
                }
                Err(mpsc::error::TrySendError::Closed(_)) => false,
            }
        });
        st.last_sent = Some(Instant::now());
        if let Some(at) = st.input_at.take() {
            let probe = self.probe.lock().unwrap_or_else(|e| e.into_inner()).clone();
            if let Some(probe) = probe {
                probe(at.elapsed());
            }
        }
        if st.attached.values().any(|a| a.lagged) {
            self.cv.notify_all();
        }
    }

    /// Attach `conn_key` (or re-attach it, replacing its stream): flush what
    /// is waiting to the others, then queue `replay` (the ring and repaint,
    /// read under the same screen lock) for it.
    pub(crate) fn attach(
        &self,
        conn_key: &str,
        stream: mpsc::Sender<StreamBatch>,
        replay: Vec<u8>,
        size: (u16, u16),
    ) {
        let mut st = self.lock();
        self.flush(&mut st);
        let mut attachment = Attachment {
            stream,
            lagged: false,
        };
        if !offer_replay(&self.terminal_id, &mut attachment, &replay, size) {
            return;
        }
        st.attached.insert(conn_key.to_string(), attachment);
        if st.attached.values().any(|a| a.lagged) {
            self.cv.notify_all();
        }
    }

    pub(crate) fn detach(&self, conn_key: &str) {
        self.lock().attached.remove(conn_key);
    }

    pub(crate) fn is_attached(&self, conn_key: &str) -> bool {
        self.lock().attached.contains_key(conn_key)
    }

    /// Send what is waiting, then nothing more: stop streaming and the
    /// flusher. (A later `attach` still gets a replay.)
    pub(crate) fn close(&self) {
        let mut st = self.lock();
        self.flush(&mut st);
        st.closed = true;
        st.attached.clear();
        self.cv.notify_all();
    }

    fn flush_loop(self: Arc<Self>, session: Weak<TerminalSession>) {
        let mut st = self.lock();
        loop {
            if st.closed {
                return;
            }
            if !st.pending.is_empty() {
                let due = st.last_sent.map_or_else(Instant::now, |t| t + COALESCE);
                let now = Instant::now();
                if now >= due {
                    self.flush(&mut st);
                } else {
                    st = self
                        .cv
                        .wait_timeout(st, due - now)
                        .unwrap_or_else(|e| e.into_inner())
                        .0;
                }
                continue;
            }
            if st.attached.values().any(|a| a.lagged) {
                st = self
                    .cv
                    .wait_timeout(st, LAG_RETRY)
                    .unwrap_or_else(|e| e.into_inner())
                    .0;
                if st.closed || !st.pending.is_empty() {
                    continue;
                }
                // Build a replay (a copy of the whole ring) only for a stream
                // that has room for it now.
                let room = st
                    .attached
                    .values()
                    .any(|a| a.lagged && a.stream.capacity() > 0);
                if !room {
                    continue;
                }
                // Lock order: the screen first, so release ours.
                drop(st);
                let Some(session) = session.upgrade() else {
                    return;
                };
                session.with_replay(|replay, size| self.retry_lagged(&replay, size));
                st = self.lock();
                continue;
            }
            st = self.cv.wait(st).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// Offer each lagged attachment a fresh replay (under the screen lock).
    fn retry_lagged(&self, replay: &[u8], size: (u16, u16)) {
        let mut st = self.lock();
        // What is waiting is already in `replay`: the others get it first.
        self.flush(&mut st);
        let terminal_id = self.terminal_id.clone();
        st.attached.retain(|_, a| {
            if !a.lagged || a.stream.capacity() == 0 {
                return true;
            }
            a.lagged = false;
            offer_replay(&terminal_id, a, replay, size)
        });
    }
}

/// Queue a replay on `a`'s stream. `false`: the stream is gone. A full stream
/// leaves `a` lagged (retried later).
fn offer_replay(terminal_id: &str, a: &mut Attachment, replay: &[u8], size: (u16, u16)) -> bool {
    match a.stream.try_send(replay_frames(terminal_id, replay, size)) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            a.lagged = true;
            true
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
    }
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn output_frames(terminal_id: &str, bytes: &[u8]) -> StreamBatch {
    bytes
        .chunks(FRAME_BYTES)
        .map(|chunk| ServerMsg::TerminalOutput {
            terminal_id: terminal_id.to_string(),
            bytes: b64(chunk),
        })
        .collect()
}

/// A `TerminalReplay` with the first frame's worth, then `TerminalOutput`
/// for the rest: one batch, so it is queued whole or not at all.
fn replay_frames(terminal_id: &str, bytes: &[u8], (cols, rows): (u16, u16)) -> StreamBatch {
    let (first, rest) = bytes.split_at(bytes.len().min(FRAME_BYTES));
    let mut batch = vec![ServerMsg::TerminalReplay {
        terminal_id: terminal_id.to_string(),
        cols,
        rows,
        bytes: b64(first),
    }];
    batch.extend(output_frames(terminal_id, rest));
    batch
}
