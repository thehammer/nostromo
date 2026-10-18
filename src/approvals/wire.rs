//! The approval wire types (design contract §4): what the daemon sends the Mac
//! app about a held permission request, and what the app answers.
//!
//! The frames themselves are [`crate::ipc::protocol::ServerMsg`] /
//! [`crate::ipc::protocol::ClientMsg`] variants; these are their payloads.
//!
//! **Who sees what.** Everything here except [`ApprovalPending`]'s count is
//! `LocalOnly` (see `ipc::peer`): it carries the command, the reason and the
//! working directory, and it never reaches a TCP/LAN peer.
//!
//! Beyond the contract's field list: [`ApprovalRequestWire::tag`]. The snapshot
//! (`approvals_snapshot`) is a bare list of requests, and each one must say which
//! focus it belongs to, so the tag is carried on the request itself (it repeats
//! `approval_request.tag`, which stays for the live frame).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::display::ApprovalDisplay;
use super::request::{McpTool, Reason, ToolKind};

/// The longest note an answer may carry, in characters (after invisible characters are removed).
pub const MAX_NOTE_CHARS: usize = 500;

/// A held permission request, as the card shows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApprovalRequestWire {
    /// A Nostromo UUID: never the CLI's own request id.
    pub request_id: String,
    /// The focus the request belongs to.
    pub tag: String,
    pub tool_use_id: String,
    pub agent: AgentWire,
    pub tool_name: String,
    pub display_name: String,
    pub tool_kind: ToolKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp: Option<McpTool>,
    /// The tool input exactly as the CLI sent it.
    pub input: Value,
    pub display: ApprovalDisplay,
    /// Where the session runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub reason: Reason,
    pub flags: ApprovalFlags,
    /// The agent's own description of the call (sanitized): a claim, not a fact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub options: Vec<ApprovalOption>,
    /// Session-rule candidates (a later slice; empty until then).
    #[serde(default)]
    pub session_rule_candidates: Vec<Value>,
    pub created_at_ms: u64,
    pub deadline_at_ms: u64,
}

/// Who is asking: the session's agent, and the sub-agent if it is one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentWire {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent: Option<SubagentWire>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubagentWire {
    pub agent_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
}

/// The CLI's flags on a request (each false when the CLI sent none).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalFlags {
    pub default_to_no: bool,
    pub suppress_always_allow_rule: bool,
    pub requires_user_interaction: bool,
    pub classifier_approvable: bool,
}

/// What the card offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalOption {
    AllowOnce,
    Deny,
    DenyAndStop,
    DenyWithNote,
}

impl ApprovalOption {
    /// Everything this slice offers.
    pub const ALL: [ApprovalOption; 4] = [Self::AllowOnce, Self::Deny, Self::DenyAndStop, Self::DenyWithNote];
}

/// What the human decided.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalDecision {
    pub kind: DecisionKind,
    /// Why, for the agent to read (denials). At most [`MAX_NOTE_CHARS`] once cleaned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionKind {
    AllowOnce,
    Deny,
    DenyAndStop,
}

/// The verdict `approval_resolved` carries is the audit log's outcome name
/// (`allowed_once`, `denied`, `denied_and_stopped`, `timed_out`, `no_app`,
/// `cancelled`, …). A string, so a later slice's outcome needs no wire change.
pub type OutcomeName = String;

/// Why an answer was not applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnswerRefusal {
    RequiresSecureConnection,
    NotOperatorApp,
    AlreadyResolved,
    UnknownRequest,
}

impl AnswerRefusal {
    /// The code as written in the audit log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RequiresSecureConnection => "requires_secure_connection",
            Self::NotOperatorApp => "not_operator_app",
            Self::AlreadyResolved => "already_resolved",
            Self::UnknownRequest => "unknown_request",
        }
    }
}

/// Which control a refused or suspicious input came through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusalChannel {
    AppControl,
    Accessibility,
    Unknown,
}

impl RefusalChannel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AppControl => "app_control",
            Self::Accessibility => "accessibility",
            Self::Unknown => "unknown",
        }
    }
}

/// Clean a note for the agent: invisible characters removed, line breaks turned
/// into spaces, at most [`MAX_NOTE_CHARS`] characters. `None` when nothing is left.
pub fn clean_note(note: &str) -> Option<String> {
    let cleaned: String = note
        .chars()
        // Line breaks first: `is_invisible` counts them as control characters.
        .map(|c| if matches!(c, '\n' | '\r') { ' ' } else { c })
        .filter(|c| !crate::data::work::is_invisible(*c))
        .take(MAX_NOTE_CHARS)
        .collect();
    (!cleaned.trim().is_empty()).then_some(cleaned)
}
