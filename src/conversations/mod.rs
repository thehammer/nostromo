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
