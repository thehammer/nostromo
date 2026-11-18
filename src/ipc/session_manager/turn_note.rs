//! The tracker note a session's next written message carries.
//!
//! The session manager asks a [`TurnNoteProvider`] (the daemon registers the
//! tracker registry) what the agent has not yet been told, for the one session
//! the daemon spawned for the tag (`SessionCtx::session_id`, never a
//! client-supplied id). The answer rides in the same `<nostromo-note>` block as
//! the model-switch note. The provider is told to `commit` when the frame binds
//! to its turn (turn start); a note that was built but never bound (write
//! failed, session died) is dropped, so the same changes go with the next message.

use std::sync::Arc;

use super::SessionManager;

/// One prepared note. Dropping it without [`TurnNote::commit`] means it was not
/// delivered and nothing is recorded as seen.
pub trait TurnNote: Send {
    /// The text to put in the `<nostromo-note>` block.
    fn text(&self) -> &str;
    /// The frame carrying [`TurnNote::text`] bound to its turn: the agent has now
    /// seen exactly what the text shows.
    fn commit(self: Box<Self>);
}

/// Prepares notes for the next message written to a session.
pub trait TurnNoteProvider: Send + Sync {
    /// The note for session `session_id` of focus `tag`, or `None` when it has
    /// nothing to be told. Takes no session-manager lock.
    fn prepare(&self, tag: &str, session_id: &str) -> Option<Box<dyn TurnNote>>;
}

/// Where the manager keeps its provider for every session's writer.
pub(super) type TurnNoteCell = Arc<std::sync::RwLock<Option<Arc<dyn TurnNoteProvider>>>>;

impl SessionManager {
    /// Register the provider of tracker notes (see [`TurnNoteProvider`]). One
    /// provider serves every session, those already running included.
    pub fn set_turn_note_provider(&mut self, provider: Arc<dyn TurnNoteProvider>) {
        *self.turn_note.write().unwrap_or_else(|e| e.into_inner()) = Some(provider);
    }
}
