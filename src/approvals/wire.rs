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
/// The most questions one `AskUserQuestion` request may carry (the CLI's own schema bound).
pub const MAX_QUESTIONS: usize = 4;
/// The most options one question may carry (the CLI's own schema bound).
pub const MAX_OPTIONS: usize = 4;
/// The longest free-text ("Other") answer, in characters, before it is cleaned.
pub const MAX_OTHER_CHARS: usize = 1000;

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
    /// The rules the human may choose "for this session" (AP4); empty when none is offered.
    #[serde(default)]
    pub session_rule_candidates: Vec<SessionRuleCandidateWire>,
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
    /// Only on an `AskUserQuestion` request whose input can be answered
    /// (`questions::parse_questions`); never part of [`ApprovalOption::ALL`].
    AnswerQuestions,
    /// Only on a request with session-rule candidates (`rules::candidates`); never
    /// part of [`ApprovalOption::ALL`].
    AllowSession,
}

impl ApprovalOption {
    /// Everything this slice offers.
    pub const ALL: [ApprovalOption; 4] = [
        Self::AllowOnce,
        Self::Deny,
        Self::DenyAndStop,
        Self::DenyWithNote,
    ];
}

/// What the human decided.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalDecision {
    pub kind: DecisionKind,
    /// Why, for the agent to read (denials). At most [`MAX_NOTE_CHARS`] once cleaned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// The answers to an `AskUserQuestion` request (`answer_questions` only; ignored by every other kind).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answers: Option<Vec<QuestionAnswer>>,
    /// `allow_session` only: the id of one of the held request's own candidates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate_id: Option<String>,
    /// `allow_session` only: that candidate's rule text, exactly as shown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_text: Option<String>,
}

/// A rule the human may choose for a held request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRuleCandidateWire {
    pub id: String,
    pub rule_text: String,
    pub summary: String,
    pub kind: super::rules::CandidateKind,
    /// The user's ask rule this overrides, for an ask-rule request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub overrides: Option<String>,
}

/// An active session rule, as the chip lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRuleWire {
    pub id: String,
    pub rule_text: String,
    pub summary: String,
    pub kind: super::rules::CandidateKind,
    pub created_at_ms: u64,
    pub uses: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

/// The human's answer to one question of an `AskUserQuestion` request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionAnswer {
    /// The question's text, exactly as the CLI asked it.
    pub question: String,
    /// The option labels chosen.
    #[serde(default)]
    pub selected: Vec<String>,
    /// The free-text ("Other") answer, if that was chosen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionKind {
    AllowOnce,
    Deny,
    DenyAndStop,
    /// The human answered an `AskUserQuestion` request.
    AnswerQuestions,
    /// Allow this call and create the session rule `candidate_id` names.
    AllowSession,
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
    /// An `answer_questions` decision that does not fit the request's questions.
    InvalidAnswer,
    /// An `allow_session` decision that names no candidate of the request, or text that differs.
    InvalidRule,
}

impl AnswerRefusal {
    /// The code as written in the audit log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RequiresSecureConnection => "requires_secure_connection",
            Self::NotOperatorApp => "not_operator_app",
            Self::AlreadyResolved => "already_resolved",
            Self::UnknownRequest => "unknown_request",
            Self::InvalidAnswer => "invalid_answer",
            Self::InvalidRule => "invalid_rule",
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
