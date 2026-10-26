//! Daemon-written messages: output from a terminal the focus follows, and
//! follow notices ([`SessionManager::inject`]).
//!
//! They go through the same queue and write path as a user's message, so an
//! idle agent is woken by one and a busy agent gets it when its turn ends.
//! While a turn runs, injected messages queued back to back are combined into
//! one (one turn for all of them, not one per delivery); a user's message is
//! never combined with anything, and nothing is combined across one, so the
//! order the agent sees is the order things happened.

use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;

use anyhow::{anyhow, Result};

use super::{
    lock_recover, write_user_message, PendingMessage, SessionEvent, SessionManager, SessionState,
    LOGIN_QUEUE_CAP,
};
use crate::ipc::stream_json::TERMINAL_OUTPUT_TAG;

/// The most bytes one combined injected message may carry. Past it, the
/// oldest deliveries after the first part are left out (see [`Injected`]).
pub const INJECT_MERGE_CAP: usize = 48 * 1024;

/// Called with a focus tag whenever its session is stopped (by the user, by a
/// restart, by a new session, by crash recovery) or the crash-loop guard gives
/// up on it. Runs under the session manager's lock: it must not take it.
pub type SessionEndHook = Arc<dyn Fn(&str) + Send + Sync>;

/// Who wrote a queued message.
#[derive(Clone, Debug, Default)]
pub(super) enum PendingOrigin {
    /// The user (or a client acting for them). Never combined.
    #[default]
    User,
    /// The daemon, for followed terminals. Combined with the injected
    /// message queued right after it.
    Injected(Injected),
}

/// One queued injected message, as the parts it was combined from.
#[derive(Clone, Debug, Default)]
pub(super) struct Injected {
    parts: Vec<Part>,
    /// Per key, how many of its deliveries were left out to stay under
    /// [`INJECT_MERGE_CAP`].
    elided: BTreeMap<String, usize>,
}

#[derive(Clone, Debug)]
struct Part {
    key: String,
    text: String,
}

impl Part {
    /// A delivery may be left out to save room; a notice never is.
    fn is_delivery(&self) -> bool {
        self.text
            .trim_start()
            .starts_with(&format!("<{TERMINAL_OUTPUT_TAG}"))
    }
}

impl Injected {
    fn new(key: String, text: String) -> Self {
        Self {
            parts: vec![Part { key, text }],
            elided: BTreeMap::new(),
        }
    }

    /// Add `text` at the end, then leave out the oldest deliveries after the
    /// first part until the whole fits [`INJECT_MERGE_CAP`] (the first part,
    /// the newest part and every notice stay).
    fn push(&mut self, key: String, text: String) {
        self.parts.push(Part { key, text });
        while self.render().len() > INJECT_MERGE_CAP {
            let last = self.parts.len() - 1;
            let Some(i) = (1..last).find(|&i| self.parts[i].is_delivery()) else {
                break;
            };
            let gone = self.parts.remove(i);
            *self.elided.entry(gone.key).or_default() += 1;
        }
    }

    /// Drop every part (and left-out count) of `key`. `false` when nothing is
    /// left.
    fn drop_key(&mut self, key: &str) -> bool {
        self.parts.retain(|p| p.key != key);
        self.elided.remove(key);
        !self.parts.is_empty()
    }

    /// The message text: the parts, a blank line between each, with one line
    /// saying how many deliveries were left out after the first part.
    pub(super) fn render(&self) -> String {
        let elided: usize = self.elided.values().sum();
        let mut out = String::new();
        for (i, part) in self.parts.iter().enumerate() {
            if i > 0 {
                out.push_str("\n\n");
            }
            out.push_str(&part.text);
            if i == 0 && elided > 0 {
                out.push_str(&format!("\n\n[… {elided} earlier deliveries omitted …]"));
            }
        }
        out
    }
}

impl PendingMessage {
    /// A message the user sent.
    pub(super) fn user(text: &str, images: &[String]) -> Self {
        Self {
            text: text.to_string(),
            images: images.to_vec(),
            origin: PendingOrigin::User,
        }
    }

    fn injected(key: String, text: &str) -> Self {
        let injected = Injected::new(key, text.to_string());
        Self {
            text: injected.render(),
            images: Vec::new(),
            origin: PendingOrigin::Injected(injected),
        }
    }
}

impl SessionManager {
    /// Write `text` into `tag`'s conversation as if it were a user message,
    /// for the daemon's own purposes (terminal follow). An idle session gets it
    /// now and starts a turn; otherwise it is queued, and combined with an
    /// injected message queued right before it (a blank line between; see
    /// [`INJECT_MERGE_CAP`]). `coalesce_key` names what the text is about (a
    /// terminal), so [`drop_injected`](Self::drop_injected) can take it back
    /// before it is written.
    ///
    /// Unlike [`send_user_message`](Self::send_user_message), the text never
    /// carries the approvals restart note and never marks the session
    /// sensitive.
    pub fn inject(&mut self, tag: &str, text: &str, coalesce_key: String) -> Result<()> {
        let session = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
        if !session.alive() {
            anyhow::bail!("session {tag} is not alive");
        }
        let shared = &session.shared;
        // The same decision as `send_user_message`, under the same locks; the
        // text is queued (or combined) under `state` so a turn ending meanwhile
        // cannot miss it.
        let queued = {
            let mut state = lock_recover(&shared.state);
            let applying = lock_recover(&shared.model).applying.is_some();
            let paused = shared.login.paused();
            if *state == SessionState::Idle && !applying && !paused {
                // Optimistically mid-turn, so the next inject queues.
                *state = SessionState::MidTurn;
                None
            } else {
                Some(enqueue(
                    &mut lock_recover(&shared.pending),
                    paused,
                    coalesce_key.clone(),
                    text,
                ))
            }
        };
        if let Some(result) = queued {
            if result.is_ok() {
                shared.login.notify();
            }
            return result;
        }
        if let Err(e) = write_user_message(shared, &PendingMessage::injected(coalesce_key, text)) {
            // The optimistic MidTurn would otherwise wedge the session.
            *lock_recover(&shared.state) = SessionState::Idle;
            return Err(e);
        }
        shared.broadcast(SessionEvent::State(SessionState::MidTurn));
        Ok(())
    }

    /// Take back everything injected under `coalesce_key` that is still queued
    /// (not yet written) for `tag`: its parts leave their combined messages,
    /// and a message left with nothing is removed. A message already on its
    /// way to the CLI is not touched.
    pub fn drop_injected(&mut self, tag: &str, coalesce_key: &str) {
        let Some(session) = self.sessions.get(tag) else {
            return;
        };
        let _state = lock_recover(&session.shared.state);
        let mut pending = lock_recover(&session.shared.pending);
        pending.retain_mut(|m| match &mut m.origin {
            PendingOrigin::User => true,
            PendingOrigin::Injected(injected) => {
                let keep = injected.drop_key(coalesce_key);
                if keep {
                    m.text = injected.render();
                }
                keep
            }
        });
    }

    /// Be told when a session ends (see [`SessionEndHook`]).
    pub fn set_session_end_hook(&mut self, hook: SessionEndHook) {
        self.session_end_hook = Some(hook);
    }

    /// Tell the [`SessionEndHook`], if any, that `tag`'s session ended.
    pub(super) fn session_ended(&self, tag: &str) {
        if let Some(hook) = &self.session_end_hook {
            hook(tag);
        }
    }
}

/// Queue `text`: onto the last queued message when that one is injected too,
/// else as a message of its own (refused when a sign-in pause has filled the
/// queue).
fn enqueue(
    pending: &mut VecDeque<PendingMessage>,
    paused: bool,
    key: String,
    text: &str,
) -> Result<()> {
    if let Some(PendingMessage {
        text: queued,
        origin: PendingOrigin::Injected(injected),
        ..
    }) = pending.back_mut()
    {
        injected.push(key, text.to_string());
        *queued = injected.render();
        return Ok(());
    }
    if paused && pending.len() >= LOGIN_QUEUE_CAP {
        anyhow::bail!("waiting_for_sign_in: queue full");
    }
    pending.push_back(PendingMessage::injected(key, text));
    Ok(())
}
