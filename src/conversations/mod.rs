//! A private, Mac-only history of the conversations Nostromo focuses started.
//!
//! Distinct from `mother::origin::SessionHistory` (an authority record for
//! Mother job origins, ids only). This one holds what the Resume tab lists:
//! title, label, agent, project, branch, model, PR numbers, one first-prompt
//! line (never for a sensitive conversation or one the sensitive-text guard
//! flags) and what is needed to find and resume the conversation.
//!
//! Nothing here is logged (ids and fixed words only), sent to a network or
//! non-operator peer, or reachable by an MCP tool.

pub mod backfill;
pub mod first_prompt;
pub mod list;
pub mod store;
pub mod transcript;

pub use first_prompt::{FirstPrompt, Reason};
pub use store::{ConversationEntry, ConversationHistory};

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The longest title a user may give a conversation (the same as a focus label).
pub const MAX_TITLE_CHARS: usize = 60;

/// A user's title as stored: trimmed, cut at [`MAX_TITLE_CHARS`] and trimmed
/// again; `None` when nothing is left (which clears the title).
pub fn normalized_title(raw: Option<&str>) -> Option<String> {
    let capped: String = raw?.trim().chars().take(MAX_TITLE_CHARS).collect();
    let capped = capped.trim();
    (!capped.is_empty()).then(|| capped.to_owned())
}
