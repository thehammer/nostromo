//! What the daemon watches in an ECS terminal's output: the marker that says
//! the session began, the marker that says the remote side ended it, and the
//! last few KiB, kept only to classify why the process ended.
//!
//! [`RemoteWatch::observe`] runs in the terminal's reader hook, under the
//! screen lock, so it never touches the manager: it updates its own small state
//! and queues a [`ConnectEvent`] for the launcher that is waiting. The text it
//! holds is bounded ([`MAX_TAIL_BYTES`]), never audited, and dropped as soon
//! as it has been classified (T-2b-2).

use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use super::classify::{
    classify_close, classify_connect_failure, CONNECTED_MARKER, MAX_TAIL_BYTES, REMOTE_EXIT_MARKER,
};
use crate::terminal::launcher::ConnectFailure;

/// What the launcher waiting on a connecting terminal is told.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectEvent {
    /// The session-manager plugin said the session began.
    Connected,
    /// The terminal is gone before the session began (it exited, was closed,
    /// or the daemon is stopping). No pane remains.
    Failed(ConnectFailure),
}

#[derive(Default)]
struct State {
    /// The last [`MAX_TAIL_BYTES`] of output.
    tail: Vec<u8>,
    connected: bool,
    remote_exit: bool,
}

/// One ECS terminal's output watch.
pub struct RemoteWatch {
    /// The SSO session a login remedy names.
    sso_session: String,
    state: Mutex<State>,
    events: mpsc::UnboundedSender<ConnectEvent>,
}

impl RemoteWatch {
    /// A watch, and the receiver the launcher waits on.
    pub fn new(sso_session: &str) -> (Arc<Self>, mpsc::UnboundedReceiver<ConnectEvent>) {
        let (events, rx) = mpsc::unbounded_channel();
        let watch = Arc::new(Self {
            sso_session: sso_session.to_string(),
            state: Mutex::new(State::default()),
            events,
        });
        (watch, rx)
    }

    /// One chunk of the process's output. Quick, and never takes another lock.
    pub fn observe(&self, chunk: &[u8]) {
        let mut state = self.lock();
        let before = state.tail.len();
        state.tail.extend_from_slice(chunk);
        // Only what a marker could newly appear in: the new bytes, and the
        // few before them that a marker may straddle. (Scanned before the
        // tail is trimmed, so a chunk larger than the tail is still seen whole.)
        let longest = CONNECTED_MARKER.len().max(REMOTE_EXIT_MARKER.len());
        let from = before.saturating_sub(longest - 1);
        if !state.connected && contains(&state.tail[from..], CONNECTED_MARKER) {
            state.connected = true;
            let _ = self.events.send(ConnectEvent::Connected);
        }
        if !state.remote_exit && contains(&state.tail[from..], REMOTE_EXIT_MARKER) {
            state.remote_exit = true;
        }
        let excess = state.tail.len().saturating_sub(MAX_TAIL_BYTES);
        state.tail.drain(..excess);
    }

    /// Tell the waiting launcher the terminal is gone.
    pub fn fail(&self, failure: ConnectFailure) {
        let _ = self.events.send(ConnectEvent::Failed(failure));
    }

    /// Did the session begin?
    pub fn connected(&self) -> bool {
        self.lock().connected
    }

    /// Why a process that exited before the session began could not connect.
    /// Takes (and so drops) the captured text.
    pub fn take_connect_failure(&self) -> ConnectFailure {
        let tail = self.take_tail();
        classify_connect_failure(&tail, &self.sso_session)
    }

    /// Why a session that was running ended. Takes (and so drops) the
    /// captured text.
    pub fn take_close_reason(&self) -> &'static str {
        let tail = self.take_tail();
        classify_close(&tail, self.lock().remote_exit)
    }

    fn take_tail(&self) -> String {
        let bytes = std::mem::take(&mut self.lock().tail);
        String::from_utf8_lossy(&bytes).into_owned()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn contains(haystack: &[u8], needle: &str) -> bool {
    let needle = needle.as_bytes();
    haystack.windows(needle.len()).any(|w| w == needle)
}
