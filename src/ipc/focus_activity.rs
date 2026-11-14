//! Per-session activity counters for the sidebar's "something happened since you
//! looked" marks.
//!
//! The daemon counts REAL events, and the Mac compares the counters with the
//! values it saw the last time the operator looked at the focus. Three counters
//! only ever go up within an epoch:
//!
//! * `agent_turns`: completed agent turns on the live stream;
//! * `agent_messages`: assistant text messages on the main thread;
//! * `agent_problems`: [`ProblemKind`] events.
//!
//! They count **live events since the session's tracker was created**. A
//! transcript rebuilt from disk (a resume, `load_scrollback`) never touches them:
//! only [`ActivityTally`], which `run_reader` feeds from the CLI's own stdout,
//! does. They are an operator-UI signal and are never put on the MCP surface.
//!
//! **Nothing here logs or keeps message text.** Only counts and a [`ProblemKind`]
//! are stored.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::auth_failure::AuthSignal;
use super::stream_json::{ParsedLine, TurnBlock, TurnDelta};

/// What kind of problem a session had. Every `agent_problems` increment names
/// exactly one of these, and the newest is sent as `last_problem`.
///
/// This is the exhaustive list: [`ProblemKind::ALL`]. `Unknown` is never
/// produced; it only lets an older build decode a kind a newer daemon added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProblemKind {
    /// The CLI process exited without being asked to (counted once per crash,
    /// when the supervisor first sees it, whether or not it then restarts).
    Crashed,
    /// The operator stopped the session (`session_control` stop). A restart,
    /// "new session" and the supervisor's own recovery are not this.
    Stopped,
    /// The crash-loop guard gave up on the session after too many crashes
    /// (`StopReason::CrashLoopGuard`).
    CrashLoopGuard,
    /// A turn ended in an error result and nothing more specific is known.
    /// An interrupt the operator asked for is not an error.
    TurnError,
    /// A turn ended on an API error: a synthetic error message from the CLI
    /// (`isApiErrorMessage`) or an error result that says `API Error`.
    ApiError,
    /// A turn ended on a usage or rate limit.
    RateLimited,
    /// A turn failed because Claude could not sign in: its message is held for
    /// the sign-in (CL1). Counted once per failed turn, a resend included.
    LoginHold,
    /// A message to the session was refused (the process is down, or the queue
    /// behind a sign-in hold is full) or could not be written to its stdin.
    SendRefused,
    /// A turn completed without a single assistant text message: a silent
    /// finish (tool calls only, or nothing). Counted only when the turn had no
    /// error, so a turn is at most one problem.
    NoText,
    /// A kind this build does not know (a newer daemon's). Never produced.
    #[serde(other)]
    Unknown,
}

impl ProblemKind {
    /// Every kind this build produces.
    pub const ALL: [ProblemKind; 9] = [
        ProblemKind::Crashed,
        ProblemKind::Stopped,
        ProblemKind::CrashLoopGuard,
        ProblemKind::TurnError,
        ProblemKind::ApiError,
        ProblemKind::RateLimited,
        ProblemKind::LoginHold,
        ProblemKind::SendRefused,
        ProblemKind::NoText,
    ];
}

/// One reading of a session's counters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivitySnapshot {
    pub epoch: String,
    pub agent_turns: u64,
    pub agent_messages: u64,
    pub agent_problems: u64,
    pub last_problem: Option<ProblemKind>,
}

struct Counters {
    /// The Claude session id the counters belong to.
    session_id: String,
    epoch: String,
    turns: u64,
    messages: u64,
    problems: u64,
    last_problem: Option<ProblemKind>,
}

impl Counters {
    fn fresh(session_id: &str) -> Self {
        Self {
            session_id: session_id.to_owned(),
            epoch: Uuid::new_v4().to_string(),
            turns: 0,
            messages: 0,
            problems: 0,
            last_problem: None,
        }
    }
}

/// One focus's counters and epoch. Shared between the manager, the session's
/// reader thread and every respawn of the focus's process, so a restart neither
/// resets the counters nor counts as an event.
///
/// **Epoch design.** The epoch is a random id made when the tracker is created,
/// so a daemon restart (counters are not persisted) always starts a new one, and
/// it is made again, with the counters back at zero, when the focus's Claude
/// session id changes ([`FocusActivity::bind_session`]: a fresh conversation, a
/// stale id replaced). Within an epoch the counters never decrease.
pub struct FocusActivity {
    inner: Mutex<Counters>,
}

impl FocusActivity {
    pub fn new(session_id: &str) -> Self {
        Self {
            inner: Mutex::new(Counters::fresh(session_id)),
        }
    }

    /// The process about to run belongs to Claude session `session_id`. The same
    /// id as before (a restart, a resume) changes nothing; another one means the
    /// old counters describe a conversation that is gone, so a new epoch starts.
    pub fn bind_session(&self, session_id: &str) {
        let mut c = self.lock();
        if c.session_id != session_id {
            *c = Counters::fresh(session_id);
        }
    }

    pub fn snapshot(&self) -> ActivitySnapshot {
        let c = self.lock();
        ActivitySnapshot {
            epoch: c.epoch.clone(),
            agent_turns: c.turns,
            agent_messages: c.messages,
            agent_problems: c.problems,
            last_problem: c.last_problem,
        }
    }

    pub(crate) fn note_turn(&self) {
        let mut c = self.lock();
        c.turns = c.turns.saturating_add(1);
    }

    pub(crate) fn note_message(&self) {
        let mut c = self.lock();
        c.messages = c.messages.saturating_add(1);
    }

    pub(crate) fn note_problem(&self, kind: ProblemKind) {
        let mut c = self.lock();
        c.problems = c.problems.saturating_add(1);
        c.last_problem = Some(kind);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Counters> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The daemon's trackers, one per focus tag, kept for the daemon's lifetime
/// (never persisted).
#[derive(Default)]
pub struct ActivityBook {
    by_tag: Mutex<HashMap<String, Arc<FocusActivity>>>,
}

impl ActivityBook {
    /// The tracker for `tag`, about to run Claude session `session_id`: made on
    /// first use, rebased when the session id differs from the one it had.
    pub fn for_session(&self, tag: &str, session_id: &str) -> Arc<FocusActivity> {
        let mut by_tag = self.by_tag.lock().unwrap_or_else(|e| e.into_inner());
        let tracker = by_tag
            .entry(tag.to_owned())
            .or_insert_with(|| Arc::new(FocusActivity::new(session_id)));
        tracker.bind_session(session_id);
        Arc::clone(tracker)
    }
}

/// Feeds one session reader's stdout into a [`FocusActivity`].
///
/// What counts, precisely (all on the live stream, never on a replay):
///
/// * **Turn**: a `result` that ends a turn the reader saw start (`TurnStarted`),
///   whatever opened it: the user's message, a wake, a notice, a peer message.
///   A `result` with no live turn open (a resume handshake) is nothing. A turn
///   the operator interrupted is neither a turn nor a problem.
/// * **Message**: one per assistant stdout record, on the main thread, that
///   has at least one non-empty text block, while a live turn is open. Not
///   subagent (sidechain) text, not tool calls or thinking, not the CLI's
///   synthetic lines (API errors, interrupt placeholders), and not any user-role
///   line: the user's own messages and injected notices never reach here as
///   blocks. A record that streams several text blocks is one message; two
///   records are two. Partial-message stream events are not parsed at all, so
///   text counts once, when its record completes.
/// * **Problem**: at a turn's end, at most one: sign-in failure, rate limit, API
///   error, other error, else [`ProblemKind::NoText`]. The others are counted by
///   the session manager (`Crashed`, `Stopped`, `CrashLoopGuard`, `SendRefused`).
pub struct ActivityTally {
    sink: Arc<FocusActivity>,
    /// A turn the reader saw start is open.
    open: bool,
    /// Messages counted in the open turn.
    messages: u32,
    /// What the turn's synthetic API error line said, if it had one.
    hint: Option<ProblemKind>,
    /// What the turn's error result said, if it was one.
    result_kind: Option<ProblemKind>,
}

/// A line longer than this is not parsed again for its error text: an error
/// line is short, and a huge one is some other output that quotes the words.
const MAX_ERROR_LINE_BYTES: usize = 256 * 1024;

/// Only this many characters of an error text are matched.
const ERROR_MATCH_CHARS: usize = 512;

impl ActivityTally {
    pub fn new(sink: Arc<FocusActivity>) -> Self {
        Self {
            sink,
            open: false,
            messages: 0,
            hint: None,
            result_kind: None,
        }
    }

    /// One stdout line and what `parse_line` made of it, before the transcript
    /// takes it in. `raw` is only inspected for markers, never kept.
    pub fn on_line(&mut self, raw: &str, parsed: &ParsedLine) {
        match parsed {
            // The main agent's blocks. A user line's blocks (tool results) have
            // no text, and a subagent's carry a parent id.
            ParsedLine::Blocks {
                blocks,
                parent_tool_use_id: None,
                ..
            } if self.open && blocks.iter().any(|b| matches!(b, TurnBlock::Text { .. })) => {
                match synthetic_line(raw) {
                    Some(Synthetic::ApiError(kind)) => {
                        self.hint.get_or_insert(kind);
                    }
                    Some(Synthetic::Other) => {}
                    None => {
                        self.messages = self.messages.saturating_add(1);
                        self.sink.note_message();
                    }
                }
            }
            ParsedLine::Result(summary) if summary.is_error => {
                self.result_kind = error_result_kind(raw);
            }
            _ => {}
        }
    }

    /// One delta the transcript produced for the line. `auth_failed` is the
    /// turn's sign-in verdict at a turn end (`TurnAuthTracker::finish`).
    pub fn on_delta(&mut self, delta: &TurnDelta, auth_failed: Option<AuthSignal>) {
        match delta {
            // A local slash command's record (`/context`) is no agent turn: no
            // model ran, so it is neither counted nor a `NoText` problem. Its
            // `result` then meets no open turn here and is nothing.
            TurnDelta::TurnStarted { turn }
                if turn.origin.as_ref().is_some_and(|o| o.is_local_command()) =>
            {
                self.open = false;
            }
            TurnDelta::TurnStarted { .. } => {
                self.open = true;
                self.messages = 0;
                self.hint = None;
                self.result_kind = None;
            }
            // A phantom dropped, or a turn cut short: no result will come.
            TurnDelta::TurnErrored { .. } => self.open = false,
            TurnDelta::TurnCompleted { summary, .. } => {
                let was_open = std::mem::take(&mut self.open);
                // A result with no live turn behind it (a resume handshake), and
                // a turn the operator stopped, are not the agent's.
                if !was_open || summary.interrupted {
                    return;
                }
                self.sink.note_turn();
                let problem = if auth_failed.is_some() {
                    Some(ProblemKind::LoginHold)
                } else if let Some(hint) = self.hint {
                    Some(hint)
                } else if summary.is_error {
                    Some(self.result_kind.unwrap_or(ProblemKind::TurnError))
                } else if self.messages == 0 {
                    Some(ProblemKind::NoText)
                } else {
                    None
                };
                if let Some(kind) = problem {
                    self.sink.note_problem(kind);
                }
            }
            _ => {}
        }
    }
}

/// What a main-thread assistant line with text is, when it is not the agent's.
enum Synthetic {
    /// The CLI's own error message (`isApiErrorMessage`), by kind.
    ApiError(ProblemKind),
    /// Another line the CLI made up (`<synthetic>`: an interrupt placeholder).
    Other,
}

/// Is `raw` one of the CLI's own assistant lines? Only a line that names itself
/// is parsed again.
fn synthetic_line(raw: &str) -> Option<Synthetic> {
    if raw.len() > MAX_ERROR_LINE_BYTES
        || !(raw.contains("<synthetic>") || raw.contains("isApiErrorMessage"))
    {
        return None;
    }
    let v: Value = serde_json::from_str(raw).ok()?;
    let synthetic = v["message"]["model"].as_str() == Some("<synthetic>");
    let api_error = v["isApiErrorMessage"].as_bool() == Some(true);
    if api_error {
        let kind = match v["error"].as_str() {
            Some("authentication_failed") => ProblemKind::LoginHold,
            Some("rate_limit") => ProblemKind::RateLimited,
            _ => ProblemKind::ApiError,
        };
        return Some(Synthetic::ApiError(kind));
    }
    synthetic.then_some(Synthetic::Other)
}

/// What an error `result` line says went wrong, when it says anything specific.
fn error_result_kind(raw: &str) -> Option<ProblemKind> {
    if raw.len() > MAX_ERROR_LINE_BYTES {
        return None;
    }
    let v: Value = serde_json::from_str(raw).ok()?;
    let head: String = v["result"]
        .as_str()?
        .chars()
        .take(ERROR_MATCH_CHARS)
        .collect::<String>()
        .to_lowercase();
    if ["usage limit", "rate limit", "rate_limit"]
        .iter()
        .any(|p| head.contains(p))
    {
        Some(ProblemKind::RateLimited)
    } else if head.starts_with("api error") {
        Some(ProblemKind::ApiError)
    } else {
        None
    }
}

#[cfg(test)]
mod tests;
