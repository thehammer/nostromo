//! Stream-json turn model + parser — the Rust port of the turn model that used
//! to live in the Swift `ChatModels.swift`.
//!
//! `claude --input-format stream-json --output-format stream-json --verbose`
//! emits one JSON object per line (NDJSON). This module parses those lines into
//! a structured [`Turn`] / [`TurnBlock`] model and assembles them into a
//! [`SessionTranscript`] that the daemon broadcasts to attached clients.
//!
//! ## Turn boundary
//!
//! A turn **completes on the `result` event** — NOT on EOF / process exit (a
//! single persistent process services many turns; verified empirically against
//! `claude` 2.1.158). A new user prompt arriving while a turn is still open
//! also flushes the open turn (defensive; this is how stored-session JSONL,
//! which has no `result` lines, delimits turns).
//!
//! ## Block taxonomy (parity with the Swift render model)
//!
//! `text`, `tool_use` (→ `ToolCall` or the `AskQuestion` card), and
//! `tool_result` content blocks are rendered. `thinking` blocks are dropped —
//! exactly as the Swift parser did — so the GUI renders identically to before
//! the daemon owned parsing.
//!
//! ## Retention
//!
//! [`SessionTranscript`] is a **cache**, not the record of truth — the stored
//! session JSONL under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` is
//! authoritative, and the daemon already re-reads it on resume
//! ([`load_scrollback`]). Retention is bounded two ways, enforced after every
//! ingest:
//!
//! - **Turn count** ≤ [`RETAINED_TURNS`] (4× [`SCROLLBACK_TURNS`], the number
//!   of turns actually served on attach/resume — headroom beyond that window
//!   costs memory for no benefit).
//! - **Payload bytes** ≤ [`RETAINED_BYTES`] (32 MiB) — a turn-count cap alone
//!   does not bound memory, since `ToolResult` content and `ToolCall`
//!   `input_full` are retained verbatim and a single agentic turn can carry
//!   hundreds of large tool results.
//!
//! Newest data always wins: trimming drops the oldest complete turns first: if
//! a single retained turn is, on its own, over the byte budget (the
//! in-flight turn is never evicted as a whole to make room), its own oldest
//! blocks are shed instead, newest block last. The one accepted degradation:
//! a single turn whose own text has no blocks to shed (e.g. one oversized user
//! prompt) is retained over budget rather than dropped — being over a soft
//! budget is survivable, dropping human input or spinning forever is not.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::notes::{LedgerNote, NoteKind};

/// How many turns a fresh attach or resume is served. Do not change this
/// value or its two call sites as part of retention work — it is a separate,
/// already-tested concern (see `.claude/prds/bounded-transcript-memory.md`).
pub const SCROLLBACK_TURNS: usize = 30;

/// Hard cap on retained turns — 4× the served window. The in-memory
/// transcript is a cache; the on-disk JSONL is authoritative and is re-read
/// on resume, so anything past the served window is pure headroom.
pub const RETAINED_TURNS: usize = 4 * SCROLLBACK_TURNS;

/// Hard cap on retained payload bytes per session. A turn cap alone does not
/// bound memory: `TurnBlock::ToolResult.content` and
/// `TurnBlock::ToolCall.input_full` are retained verbatim, and one agentic
/// turn can carry hundreds of ≥256 KB tool results.
pub const RETAINED_BYTES: usize = 32 * 1024 * 1024; // 32 MiB

/// Fixed per-block accounting overhead. Without it, a block whose only
/// content is empty strings (e.g. a degenerate `ResultSummary`) would cost
/// nothing against the byte budget no matter how many are retained.
const BLOCK_OVERHEAD: usize = 64;

/// Fixed per-turn accounting overhead, on top of its blocks' own accounting.
const TURN_OVERHEAD: usize = 128;

// ── turn model ──────────────────────────────────────────────────────────────

/// One render block within a turn.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TurnBlock {
    Text {
        text: String,
        /// The Agent/Task call this prose came from, when a subagent said it
        /// (`"?"` when the event is marked as a subagent's but names no
        /// parent). `None` for the main agent's own prose.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent_tool_use_id: Option<String>,
    },
    ToolCall {
        tool_name: String,
        /// One-liner for the collapsed row.
        input_summary: String,
        /// Pretty JSON for possible expansion.
        input_full: String,
        /// The CLI's `tool_use.id`: a durable identity for the call.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool_use_id: Option<String>,
        /// `input.file_path` / `input.notebook_path` of a file tool
        /// (Read, Write, Edit, MultiEdit, NotebookEdit), kept whole so a
        /// client can count distinct files.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        /// When the call was made: the source line's timestamp, else (live
        /// only) the daemon's receive time, else unknown.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ts: Option<chrono::DateTime<chrono::Utc>>,
        /// See [`TurnBlock::Text::parent_tool_use_id`].
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent_tool_use_id: Option<String>,
    },
    ToolResult {
        /// Empty for a quiet success: kept on the wire so a client can tell
        /// a finished call from a running one.
        content: String,
        is_error: bool,
        /// The `tool_use_id` of the call this answers.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool_use_id: Option<String>,
        /// When the result arrived (same rule as [`TurnBlock::ToolCall::ts`]).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ts: Option<chrono::DateTime<chrono::Utc>>,
        /// See [`TurnBlock::Text::parent_tool_use_id`].
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent_tool_use_id: Option<String>,
    },
    ResultSummary {
        duration_ms: u64,
        cost_usd: f64,
        is_error: bool,
        /// The operator pressed Stop: the CLI reports an interrupted turn as an
        /// error result (`error_during_execution`), which is not a failure the
        /// operator should be alarmed by — clients render it as "Interrupted".
        #[serde(default)]
        interrupted: bool,
    },
    ErrorMessage {
        message: String,
    },
    /// Structured question extracted from an `AskUserQuestion` tool_use block
    /// (or a `CONFIRM:` line). Rendered natively as an option card.
    AskQuestion {
        question: String,
        header: String,
        options: Vec<AskOption>,
        multi_select: bool,
    },
    /// A daemon-authored transcript marker ("Model changed to Opus (from
    /// Sonnet) by you."). Not a message: it is never sent to the agent and
    /// never starts a turn. Rendered inline as a system marker, and restored
    /// from the session's notes ledger when a transcript is rebuilt.
    /// (`note_kind`, not `kind`: `kind` is this enum's own tag.)
    Note {
        note_kind: NoteKind,
        text: String,
        ts: chrono::DateTime<chrono::Utc>,
    },
}

impl TurnBlock {
    /// A main-agent prose block.
    pub fn text(text: impl Into<String>) -> Self {
        TurnBlock::Text {
            text: text.into(),
            parent_tool_use_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AskOption {
    pub label: String,
    pub description: String,
    /// True when this is Perri's (or the agent's) recommended choice. Only
    /// ever set from the `CONFIRM:` compact JSON's `"r"` key today — the GUI
    /// renders it as a "(recommended)" suffix on the option label.
    #[serde(default)]
    pub recommended: bool,
}

/// One complete user→assistant exchange.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Turn {
    /// Stable id assigned by the daemon (monotonic per transcript).
    pub id: String,
    pub user_input: String,
    /// ISO-8601 timestamp from the stream, if present.
    pub timestamp: Option<String>,
    pub blocks: Vec<TurnBlock>,
    pub is_complete: bool,
}

/// Summary fired by a `result` event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultSummary {
    pub duration_ms: u64,
    pub cost_usd: f64,
    pub is_error: bool,
    /// See [`TurnBlock::ResultSummary::interrupted`].
    #[serde(default)]
    pub interrupted: bool,
}

/// Live session lifecycle state, broadcast as `SessionState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Idle,
    MidTurn,
    AwaitingPermission,
    Crashed,
}

/// Incremental update to a transcript, broadcast to attached clients.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "delta", rename_all = "snake_case")]
pub enum TurnDelta {
    /// A new user prompt started a turn.
    TurnStarted { turn: Turn },
    /// A block was appended to an in-flight turn.
    BlockAppended { turn_id: String, block: TurnBlock },
    /// A `result` event completed a turn.
    TurnCompleted {
        turn_id: String,
        summary: ResultSummary,
        /// Total context-window tokens at turn completion (input + cache_read + cache_creation).
        /// None when the stream didn't include usage data for this turn.
        context_tokens: Option<u64>,
    },
    /// The in-flight turn was aborted (e.g. the child crashed).
    TurnErrored {
        turn_id: String,
        message: String,
        /// The turn was never a real one (a phantom prompt dropped when the
        /// next prompt arrived), not a turn that ended: its owner must not
        /// treat it as a turn end. Local only; never on the wire.
        #[serde(skip)]
        discarded: bool,
    },
    /// A [`TurnBlock::Note`] was added after the turn `turn_id` (the latest
    /// turn when the note was made). `turn_id: None` means the session has no
    /// turn yet: the note is shown on its own, and it also leads the blocks of
    /// the next `TurnStarted` turn (clients replace the standalone copy then).
    Note {
        turn_id: Option<String>,
        block: TurnBlock,
    },
}

// ── line parsing ──────────────────────────────────────────────────────────────

/// One parsed stream-json line, before turn assembly.
#[derive(Debug, Clone, PartialEq)]
pub enum ParsedLine {
    /// `session_id` observed (carried on `system`/`init` and most events).
    SessionId(String),
    /// A user message with plain-string (or text-array) content — a human
    /// prompt that opens a new turn.
    UserPrompt {
        text: String,
        is_replay: bool,
        timestamp: Option<String>,
    },
    /// Blocks to append to the current in-flight turn — assistant content
    /// blocks, or `tool_result` blocks carried on a `user` event.
    /// `context_tokens` is the total context-window usage extracted from the
    /// assistant message's `usage` field (input + cache_read + cache_creation).
    Blocks {
        blocks: Vec<TurnBlock>,
        context_tokens: Option<u64>,
        /// `message.model` of an assistant event: the model that answered.
        model: Option<String>,
        /// The line's own `timestamp`, if it carries one (stored JSONL lines
        /// and live `user` lines do; live `assistant` lines do not).
        timestamp: Option<String>,
        /// The Agent/Task call a subagent's line belongs to (`"?"` for a
        /// sidechain line that names none); `None` for the main agent.
        parent_tool_use_id: Option<String>,
    },
    /// Turn boundary.
    Result(ResultSummary),
    /// The model a `system`/`init` event reports (re-emitted at the start of
    /// every turn), with the event's session id.
    Model {
        model: String,
        source: ModelReportSource,
        session_id: Option<String>,
    },
    /// The CLI substituted a fallback model (`system` / `model_fallback`).
    ModelFallback {
        original: Option<String>,
        fallback: Option<String>,
        content: Option<String>,
    },
    /// The answer to a control request the daemon sent.
    ControlResponse {
        request_id: String,
        ok: bool,
        error: Option<String>,
        error_code: Option<String>,
        /// The response payload (`response.response`), or `Null`.
        body: Value,
    },
}

/// Where a reported model came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelReportSource {
    Init,
    Assistant,
}

/// `parent_tool_use_id` for subagent traffic that doesn't say which call it
/// belongs to (an `isSidechain: true` event with no parent id).
pub const UNKNOWN_PARENT: &str = "?";

/// Parse one NDJSON line from the stream-json output. Returns `None` for lines
/// we render nothing from (`rate_limit_event`, hook chatter, blank lines, …).
pub fn parse_line(line: &str) -> Option<ParsedLine> {
    let v: Value = serde_json::from_str(line.trim()).ok()?;
    let obj = v.as_object()?;

    match obj.get("type")?.as_str()? {
        "system" => parse_system_event(obj),

        "control_response" => parse_control_response(obj),

        "assistant" => {
            let msg = obj.get("message")?;
            // A subagent's messages arrive on the parent's stdout too, carrying
            // the subagent's model: that is not what the session runs on.
            let parent_tool_use_id = subagent_parent(obj);
            let from_subagent = parent_tool_use_id.is_some();
            let model = msg
                .get("model")
                .and_then(|m| m.as_str())
                .filter(|m| !m.is_empty() && !from_subagent && *m != "<synthetic>")
                .map(str::to_string);
            let Some(content) = msg.get("content").and_then(|c| c.as_array()) else {
                return model.map(|model| ParsedLine::Blocks {
                    blocks: vec![],
                    context_tokens: None,
                    model: Some(model),
                    timestamp: None,
                    parent_tool_use_id: None,
                });
            };
            let blocks: Vec<TurnBlock> = content
                .iter()
                .filter_map(parse_content_block)
                .flat_map(expand_confirm)
                .collect();
            // Extract total context-window usage: input + cache_read + cache_creation.
            // These three sum to the number of tokens currently occupying the context window.
            let context_tokens = msg.get("usage").and_then(|u| {
                let input = u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                let cached = u
                    .get("cache_read_input_tokens")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(0);
                let creating = u
                    .get("cache_creation_input_tokens")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(0);
                let total = input + cached + creating;
                if total > 0 {
                    Some(total)
                } else {
                    None
                }
            });
            if blocks.is_empty() && context_tokens.is_none() && model.is_none() {
                None
            } else {
                Some(ParsedLine::Blocks {
                    blocks,
                    context_tokens,
                    model,
                    timestamp: line_timestamp(obj),
                    parent_tool_use_id,
                })
            }
        }

        "user" => parse_user_event(obj),

        "result" => Some(ParsedLine::Result(ResultSummary {
            duration_ms: obj.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
            cost_usd: obj
                .get("total_cost_usd")
                .and_then(|x| x.as_f64())
                .unwrap_or(0.0),
            is_error: obj
                .get("is_error")
                .and_then(|x| x.as_bool())
                .unwrap_or(false),
            // Only the daemon knows an interrupt was requested; the transcript
            // sets this when it consumes the result (see
            // `SessionTranscript::mark_interrupt_requested`).
            interrupted: false,
        })),

        // rate_limit_event and any other type render nothing.
        _ => None,
    }
}

/// The line's top-level `timestamp`, if it has one.
fn line_timestamp(obj: &serde_json::Map<String, Value>) -> Option<String> {
    obj.get("timestamp")
        .and_then(|x| x.as_str())
        .map(str::to_string)
}

/// Which subagent call an event belongs to: its top-level
/// `parent_tool_use_id` when non-null, else [`UNKNOWN_PARENT`] when the event
/// is marked `isSidechain: true` without one, else `None` (the main agent).
fn subagent_parent(obj: &serde_json::Map<String, Value>) -> Option<String> {
    let named = obj
        .get("parent_tool_use_id")
        .and_then(|p| p.as_str())
        .filter(|p| !p.is_empty());
    if let Some(parent) = named {
        return Some(parent.to_string());
    }
    let sidechain = obj.get("isSidechain").and_then(|x| x.as_bool()) == Some(true);
    sidechain.then(|| UNKNOWN_PARENT.to_string())
}

/// `system` events: the init event (session id, and the model the turn runs
/// on), a model fallback, or anything else that carries a session id.
fn parse_system_event(obj: &serde_json::Map<String, Value>) -> Option<ParsedLine> {
    let str_field = |k: &str| obj.get(k).and_then(|x| x.as_str()).map(str::to_string);
    let session_id = str_field("session_id");
    match obj.get("subtype").and_then(|x| x.as_str()) {
        Some("init") => match str_field("model").filter(|m| !m.is_empty()) {
            Some(model) => Some(ParsedLine::Model {
                model,
                source: ModelReportSource::Init,
                session_id,
            }),
            None => session_id.map(ParsedLine::SessionId),
        },
        Some("model_fallback") | Some("model_refusal_fallback") | Some("model_consent_fallback") => {
            Some(ParsedLine::ModelFallback {
                original: str_field("original_model"),
                fallback: str_field("fallback_model"),
                content: str_field("content"),
            })
        }
        _ => session_id.map(ParsedLine::SessionId),
    }
}

/// `{"type":"control_response","response":{"subtype":"success"|"error",
/// "request_id":…, "error":…, "error_code":…, "response":{…}}}`.
fn parse_control_response(obj: &serde_json::Map<String, Value>) -> Option<ParsedLine> {
    let response = obj.get("response")?;
    let str_field = |k: &str| response.get(k).and_then(|x| x.as_str()).map(str::to_string);
    Some(ParsedLine::ControlResponse {
        request_id: str_field("request_id")?,
        ok: response.get("subtype").and_then(|x| x.as_str()) == Some("success"),
        error: str_field("error"),
        error_code: str_field("error_code"),
        body: response.get("response").cloned().unwrap_or(Value::Null),
    })
}

fn parse_user_event(obj: &serde_json::Map<String, Value>) -> Option<ParsedLine> {
    let parent_tool_use_id = subagent_parent(obj);
    let content = obj.get("message")?.get("content")?;

    // Sub-agent prompts are emitted on the parent process's stdout as `user`
    // events tagged `isSidechain: true`. They are NOT human input — dropping
    // them here prevents a spurious cornflower user bubble / new turn. The
    // sub-agent's prompt is still visible via the parent's `Agent` tool_use
    // block (rendered expandable in the GUI). The one exception: a sidechain
    // event made only of `tool_result` blocks carries a subagent call's
    // result, not a prompt, and is kept (tagged with its parent).
    if obj.get("isSidechain").and_then(|x| x.as_bool()) == Some(true)
        && !is_only_tool_results(content)
    {
        return None;
    }

    // Plain-string content → a human prompt (new turn), unless it's a
    // harness-injected notification (see is_harness_notification below).
    if let Some(s) = content.as_str() {
        if s.trim().is_empty() || is_harness_notification(s) {
            return None;
        }
        return Some(ParsedLine::UserPrompt {
            text: strip_nostromo_note(s).to_string(),
            is_replay: obj
                .get("isReplay")
                .and_then(|x| x.as_bool())
                .unwrap_or(false),
            timestamp: obj
                .get("timestamp")
                .and_then(|x| x.as_str())
                .map(str::to_string),
        });
    }

    // Array content → either tool_result blocks (append to current turn) or a
    // text-array human prompt.
    let arr = content.as_array()?;

    if is_only_tool_results(content) {
        let blocks: Vec<TurnBlock> = arr.iter().filter_map(parse_content_block).collect();
        return if blocks.is_empty() {
            None
        } else {
            Some(ParsedLine::Blocks {
                blocks,
                context_tokens: None,
                model: None,
                timestamp: line_timestamp(obj),
                parent_tool_use_id,
            })
        };
    }

    // Text-array → new human turn.
    let text = arr
        .iter()
        .filter_map(|b| {
            if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                b.get("text").and_then(|t| t.as_str())
            } else {
                None
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    if text.is_empty() || is_harness_notification(&text) {
        return None;
    }
    Some(ParsedLine::UserPrompt {
        text: strip_nostromo_note(&text).to_string(),
        is_replay: obj
            .get("isReplay")
            .and_then(|x| x.as_bool())
            .unwrap_or(false),
        timestamp: obj
            .get("timestamp")
            .and_then(|x| x.as_str())
            .map(str::to_string),
    })
}

/// `content` is a non-empty array made only of `tool_result` blocks.
fn is_only_tool_results(content: &Value) -> bool {
    content.as_array().is_some_and(|arr| {
        !arr.is_empty()
            && arr
                .iter()
                .all(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result"))
    })
}

/// Wrapper tags Claude Code's own harness injects as plain "user" events for
/// out-of-band signals — a completed background task (`<task-notification>`),
/// ambient context (`<system-reminder>`) — arriving on the wire in the exact
/// same shape as real human input. These are not something a human typed;
/// rendering one as a chat bubble reads as garbled human input (see the
/// isSidechain drop above for the same problem with sub-agent prompts).
/// Checked as a prefix after trimming leading whitespace/newlines, since the
/// harness sometimes leads with blank lines before the tag.
///
/// A model switch (`set_model`) makes the CLI write three user entries of its
/// own, replayed live and stored in the session JSONL (contract F1): the
/// `<local-command-caveat>` meta entry, the `<command-name>/model</command-name>`
/// entry and the `<local-command-stdout>Set model to …` entry. The daemon
/// records the switch as a note instead, so these are dropped too. Matched by
/// their tags alone, not their wording: a CLI release that rewords the message
/// must not turn it into a prompt. (Should the tags change too,
/// `SessionTranscript::discard_orphan_prompt` is the net.)
fn is_harness_notification(text: &str) -> bool {
    let trimmed = text.trim_start();
    trimmed.starts_with("<task-notification>")
        || trimmed.starts_with("<system-reminder>")
        || trimmed.starts_with("<local-command-")
        || trimmed.starts_with("<command-name>")
        || trimmed.starts_with("<command-message>")
        || trimmed.starts_with("<command-args>")
}

/// Opening tag of the one-line note the daemon may put in front of a user
/// message it writes, for the agent's eyes only (e.g. the outcome of the
/// agent's own model request).
pub const NOSTROMO_NOTE_OPEN: &str = "<nostromo-note>";
/// Closing tag, followed by a blank line before the user's own text.
pub const NOSTROMO_NOTE_CLOSE: &str = "</nostromo-note>\n\n";

/// The user's own text of a prompt: a leading
/// `<nostromo-note>…</nostromo-note>\n\n` is the daemon's, not the user's,
/// and is never displayed.
pub fn strip_nostromo_note(text: &str) -> &str {
    text.strip_prefix(NOSTROMO_NOTE_OPEN)
        .and_then(|rest| rest.find(NOSTROMO_NOTE_CLOSE).map(|end| &rest[end + NOSTROMO_NOTE_CLOSE.len()..]))
        .unwrap_or(text)
}

fn parse_content_block(b: &Value) -> Option<TurnBlock> {
    match b.get("type")?.as_str()? {
        "text" => {
            let t = b.get("text")?.as_str()?.trim().to_string();
            if t.is_empty() {
                None
            } else {
                Some(TurnBlock::Text {
                    text: t,
                    parent_tool_use_id: None,
                })
            }
        }

        "tool_use" => {
            let name = b.get("name").and_then(|x| x.as_str()).unwrap_or("Tool");
            let input = b
                .get("input")
                .cloned()
                .unwrap_or(Value::Object(Default::default()));

            // AskUserQuestion → a structured card instead of a generic tool row.
            if name == "AskUserQuestion" {
                if let Some(card) = parse_ask_question(&input) {
                    return Some(card);
                }
            }

            Some(TurnBlock::ToolCall {
                tool_name: name.to_string(),
                input_summary: summarize(name, &input),
                input_full: pretty_json(&input),
                tool_use_id: str_field(b, "id"),
                target: target_of(name, &input),
                ts: None,
                parent_tool_use_id: None,
            })
        }

        "tool_result" => {
            let is_error = b.get("is_error").and_then(|x| x.as_bool()).unwrap_or(false);
            let text = extract_tool_result_text(b);
            // Suppress the "Answer questions?" error AskUserQuestion always
            // returns in non-interactive mode — the card handles the UX.
            if is_error && text.trim() == "Answer questions?" {
                return None;
            }
            // An empty successful result is kept (`content: ""`): it is the
            // only sign that a quiet call (`mkdir`, `git add`) finished.
            // Clients fold it into its call rather than render it.
            Some(TurnBlock::ToolResult {
                content: text,
                is_error,
                tool_use_id: str_field(b, "tool_use_id"),
                ts: None,
                parent_tool_use_id: None,
            })
        }

        // thinking and any other block type are dropped (parity with Swift).
        _ => None,
    }
}

fn str_field(b: &Value, key: &str) -> Option<String> {
    b.get(key)
        .and_then(|x| x.as_str())
        .filter(|x| !x.is_empty())
        .map(str::to_string)
}

/// The file a file tool works on: `input.file_path`, else `input.notebook_path`.
fn target_of(name: &str, input: &Value) -> Option<String> {
    if !matches!(name, "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit") {
        return None;
    }
    str_field(input, "file_path").or_else(|| str_field(input, "notebook_path"))
}

fn extract_tool_result_text(b: &Value) -> String {
    match b.get("content") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|x| x.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

// ── AskUserQuestion / CONFIRM: parsing ──────────────────────────────────────

/// Extract an `AskQuestion` block from an `AskUserQuestion` tool input.
fn parse_ask_question(input: &Value) -> Option<TurnBlock> {
    let questions = input.get("questions")?.as_array()?;
    let first = questions.first()?;
    let question = first.get("question")?.as_str()?.to_string();
    if question.is_empty() {
        return None;
    }
    let header = first
        .get("header")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let multi_select = first
        .get("multiSelect")
        .and_then(|x| x.as_bool())
        .unwrap_or(false);
    let options = first
        .get("options")
        .and_then(|x| x.as_array())
        .map(|raw| {
            raw.iter()
                .filter_map(|opt| {
                    let label = opt.get("label").and_then(|x| x.as_str())?;
                    if label.is_empty() {
                        return None;
                    }
                    Some(AskOption {
                        label: label.to_string(),
                        description: opt
                            .get("description")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string(),
                        recommended: false,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    Some(TurnBlock::AskQuestion {
        question,
        header,
        options,
        multi_select,
    })
}

/// If a text block contains one or more `CONFIRM:{json}` lines (emitted by the
/// submit-review skill in place of the unsupported `AskUserQuestion` tool),
/// split it into: leading text • askQuestion card • trailing text.
fn expand_confirm(block: TurnBlock) -> Vec<TurnBlock> {
    let TurnBlock::Text { ref text, .. } = block else {
        return vec![block];
    };

    let mut result: Vec<TurnBlock> = Vec::new();
    let mut pending: Vec<&str> = Vec::new();
    let mut did_split = false;

    for line in text.split('\n') {
        // Tolerate agents wrapping the directive in markdown code formatting —
        // `CONFIRM:{…}` or ```CONFIRM:{…}``` — by stripping surrounding backticks
        // before matching; otherwise it renders as a raw code span, not a dialog.
        let trimmed = line.trim().trim_matches('`').trim();
        if let Some(json_str) = trimmed.strip_prefix("CONFIRM:") {
            let json_str = json_str.trim().trim_end_matches('`').trim();
            let pre = pending.join("\n").trim().to_string();
            if !pre.is_empty() {
                result.push(TurnBlock::Text {
                    text: pre,
                    parent_tool_use_id: None,
                });
            }
            pending.clear();

            if let Ok(json) = serde_json::from_str::<Value>(json_str) {
                if let Some(card) = parse_confirm_json(&json) {
                    result.push(card);
                    did_split = true;
                }
            }
            // Malformed JSON → the line is silently dropped.
        } else {
            pending.push(line);
        }
    }

    let tail = pending.join("\n").trim().to_string();
    if !tail.is_empty() {
        result.push(TurnBlock::Text {
            text: tail,
            parent_tool_use_id: None,
        });
    }

    if did_split {
        result
    } else {
        vec![block]
    }
}

/// Parse the compact JSON the submit-review skill emits on a `CONFIRM:` line.
/// Keys: `q` (question), `h` (header), `opts` (array of `{l, d, r}` — `r` is
/// an optional bool marking Perri's recommended option).
fn parse_confirm_json(json: &Value) -> Option<TurnBlock> {
    let question = json
        .get("q")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let header = json
        .get("h")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let options: Vec<AskOption> = json
        .get("opts")
        .and_then(|x| x.as_array())
        .map(|raw| {
            raw.iter()
                .filter_map(|opt| {
                    let label = opt.get("l").and_then(|x| x.as_str())?;
                    if label.is_empty() {
                        return None;
                    }
                    Some(AskOption {
                        label: label.to_string(),
                        description: opt
                            .get("d")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string(),
                        recommended: opt.get("r").and_then(|x| x.as_bool()).unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    if question.is_empty() && options.is_empty() {
        return None;
    }
    Some(TurnBlock::AskQuestion {
        question,
        header,
        options,
        multi_select: false,
    })
}

// ── input summarisation ───────────────────────────────────────────────────────

fn summarize(name: &str, input: &Value) -> String {
    let s = |k: &str| input.get(k).and_then(|x| x.as_str()).unwrap_or("");
    match name {
        "Read" | "Write" | "Edit" | "MultiEdit" => short_name(s("file_path")),
        "Bash" => s("command").chars().take(80).collect(),
        "Grep" => format!("pattern: {}", s("pattern")),
        "Glob" => s("pattern").to_string(),
        "WebFetch" => s("url").to_string(),
        "Agent" => {
            let d = s("description");
            if d.is_empty() {
                "subagent".to_string()
            } else {
                d.chars().take(60).collect()
            }
        }
        "TodoWrite" => "update todos".to_string(),
        _ => input
            .as_object()
            .and_then(|m| m.values().find_map(|v| v.as_str()))
            .map(|v| v.chars().take(80).collect())
            .unwrap_or_default(),
    }
}

fn short_name(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

fn pretty_json(v: &Value) -> String {
    // serde_json has no `preserve_order` feature enabled in this crate, so its
    // Map is a BTreeMap and keys serialise sorted — matching the Swift
    // `sortedKeys` behaviour.
    serde_json::to_string_pretty(v).unwrap_or_else(|_| "{}".to_string())
}

// ── transcript accumulator ────────────────────────────────────────────────────

/// Owns the canonical turn list for one session and turns parsed lines into
/// broadcastable [`TurnDelta`]s. The daemon holds one per live session.
#[derive(Debug, Default)]
pub struct SessionTranscript {
    session_id: Option<String>,
    turns: Vec<Turn>,
    next_seq: u64,
    /// Most recent context-window token count from an assistant message's usage field.
    last_context_tokens: Option<u64>,
    /// Running total of retained payload bytes — see the module-level
    /// `## Retention` docs. Kept incrementally in sync with `turns` at every
    /// mutation site; never recomputed from scratch on the hot path.
    retained_bytes: usize,
    /// The very first user prompt this transcript ever ingested. Set once and
    /// never cleared by trimming, so the session summary (derived from it)
    /// doesn't change or disappear once old turns fall out of `turns`.
    first_user_input: Option<String>,
    /// The operator asked to interrupt the in-flight turn; the next `result`
    /// is rendered as "Interrupted" and clears this.
    interrupt_pending: bool,
    /// How many user prompts this transcript has ingested in all, trimming
    /// notwithstanding: the absolute prompt number of the newest turn. Notes
    /// are positioned by it (`LedgerNote::after_prompt`).
    prompt_count: u64,
    /// Notes made before the first turn existed. They lead the blocks of the
    /// next turn to start.
    orphan_notes: Vec<TurnBlock>,
    /// The lines being ingested are arriving now, from the running CLI, as
    /// opposed to a replay of a stored session. Only a live transcript may
    /// stamp a call or result that has no timestamp of its own with the
    /// daemon's receive time; a replay never invents times.
    live: bool,
}

impl SessionTranscript {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mark the transcript live (see the `live` field). Set it once any
    /// scrollback has been loaded and the CLI's own output is what's ingested.
    pub fn set_live(&mut self, live: bool) {
        self.live = live;
    }

    pub fn is_live(&self) -> bool {
        self.live
    }

    /// Record that the operator pressed Stop, so the `result` that ends the
    /// interrupted turn is flagged [`ResultSummary::interrupted`] — exactly
    /// once. The CLI reports an interrupt as `error_during_execution`
    /// (`is_error: true`); without this the transcript would show a red failure
    /// for something the operator did on purpose.
    pub fn mark_interrupt_requested(&mut self) {
        self.interrupt_pending = true;
    }

    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    pub fn snapshot(&self) -> Vec<Turn> {
        self.turns.clone()
    }

    /// Current retained payload byte total — see the module-level
    /// `## Retention` docs. Always ≤ [`RETAINED_BYTES`], except for the one
    /// documented escape hatch: a single turn with no blocks left to shed.
    pub fn byte_len(&self) -> usize {
        self.retained_bytes
    }

    /// Number of turns currently retained. Always ≤ [`RETAINED_TURNS`].
    pub fn turn_count(&self) -> usize {
        self.turns.len()
    }

    /// The very first user prompt this transcript ever ingested, surviving
    /// trimming (see the `first_user_input` field doc).
    pub fn first_user_input(&self) -> Option<&str> {
        self.first_user_input.as_deref()
    }

    /// The last `max_turns` turns, newest last — same order as `snapshot()`.
    /// Returns everything if `max_turns` exceeds the retained count, and an
    /// empty vec for `max_turns == 0`. Clones only the requested tail, unlike
    /// `snapshot()` + a manual `split_off`.
    pub fn recent_turns(&self, max_turns: usize) -> Vec<Turn> {
        let len = self.turns.len();
        self.turns[len.saturating_sub(max_turns)..].to_vec()
    }

    /// `true` while the most recent turn is still open.
    pub fn is_mid_turn(&self) -> bool {
        self.turns.last().map(|t| !t.is_complete).unwrap_or(false)
    }

    fn alloc_id(&mut self) -> String {
        let id = format!("t{}", self.next_seq);
        self.next_seq += 1;
        id
    }

    /// Total user prompts ingested (see the `prompt_count` field).
    pub fn prompt_count(&self) -> u64 {
        self.prompt_count
    }

    /// Add a note after the latest turn (or, with no turn yet, ahead of the
    /// next one) and return the delta announcing it.
    pub fn add_note(&mut self, block: TurnBlock) -> TurnDelta {
        let delta = match self.turns.last_mut() {
            Some(turn) => {
                self.retained_bytes += block_bytes(&block);
                turn.blocks.push(block.clone());
                TurnDelta::Note { turn_id: Some(turn.id.clone()), block }
            }
            None => {
                self.orphan_notes.push(block.clone());
                TurnDelta::Note { turn_id: None, block }
            }
        };
        self.enforce_limits();
        delta
    }

    /// Put ledger notes back in place after a rebuild from the session JSONL:
    /// each after the turn of prompt number `after_prompt`. Notes older than
    /// the retained turns are dropped; notes past the newest turn follow it.
    pub fn merge_ledger_notes(&mut self, notes: &[LedgerNote]) {
        let retained = self.turns.len() as u64;
        let first_retained = self.prompt_count.saturating_sub(retained) + 1;
        let mut leading = 0usize;
        for note in notes {
            let block = TurnBlock::Note {
                note_kind: note.kind,
                text: note.text.clone(),
                ts: note.ts,
            };
            if note.after_prompt == 0 {
                match self.turns.first_mut() {
                    Some(first) if first_retained == 1 => {
                        self.retained_bytes += block_bytes(&block);
                        first.blocks.insert(leading, block);
                        leading += 1;
                    }
                    Some(_) => {}
                    None => self.orphan_notes.push(block),
                }
                continue;
            }
            if note.after_prompt < first_retained {
                continue;
            }
            let index = ((note.after_prompt - first_retained) as usize).min(self.turns.len().saturating_sub(1));
            match self.turns.get_mut(index) {
                Some(turn) => {
                    self.retained_bytes += block_bytes(&block);
                    turn.blocks.push(block);
                }
                None => self.orphan_notes.push(block),
            }
        }
        self.enforce_limits();
    }

    /// Ingest one stream-json line, mutate the transcript, and return the
    /// deltas to broadcast (may be empty).
    pub fn ingest_line(&mut self, line: &str) -> Vec<TurnDelta> {
        match parse_line(line) {
            Some(parsed) => self.ingest_parsed(parsed),
            None => vec![],
        }
    }

    /// [`Self::ingest_line`] for an already-parsed line. Model reports and
    /// control responses only contribute their session id here.
    pub fn ingest_parsed(&mut self, parsed: ParsedLine) -> Vec<TurnDelta> {
        match parsed {
            ParsedLine::SessionId(sid)
            | ParsedLine::Model {
                session_id: Some(sid),
                ..
            } => {
                if self.session_id.is_none() {
                    self.session_id = Some(sid);
                }
                vec![]
            }

            ParsedLine::Model { session_id: None, .. }
            | ParsedLine::ModelFallback { .. }
            | ParsedLine::ControlResponse { .. } => vec![],

            ParsedLine::UserPrompt {
                text, timestamp, ..
            } => {
                let mut deltas: Vec<TurnDelta> = self.discard_orphan_prompt().into_iter().collect();
                // Flush any still-open turn (defensive; stored JSONL has no
                // `result` lines and delimits turns by the next user prompt).
                if let Some(last) = self.turns.last_mut() {
                    last.is_complete = true;
                }
                if self.first_user_input.is_none() {
                    self.first_user_input = Some(text.clone());
                }
                self.prompt_count += 1;
                let id = self.alloc_id();
                let turn = Turn {
                    id,
                    user_input: text,
                    timestamp,
                    blocks: std::mem::take(&mut self.orphan_notes),
                    is_complete: false,
                };
                self.retained_bytes += turn_bytes(&turn);
                self.turns.push(turn.clone());
                deltas.push(TurnDelta::TurnStarted { turn });
                self.enforce_limits();
                deltas
            }

            ParsedLine::Blocks {
                blocks,
                context_tokens,
                timestamp,
                parent_tool_use_id,
                ..
            } => {
                if let Some(ct) = context_tokens {
                    self.last_context_tokens = Some(ct);
                }
                let ts = timestamp
                    .as_deref()
                    .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                    .map(|t| t.with_timezone(&chrono::Utc))
                    .or_else(|| self.live.then(chrono::Utc::now));
                let mut deltas = Vec::with_capacity(blocks.len());
                if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    for mut b in blocks {
                        stamp_block(&mut b, ts, parent_tool_use_id.as_deref());
                        self.retained_bytes += block_bytes(&b);
                        turn.blocks.push(b.clone());
                        deltas.push(TurnDelta::BlockAppended {
                            turn_id: turn_id.clone(),
                            block: b,
                        });
                    }
                }
                self.enforce_limits();
                deltas
            }

            ParsedLine::Result(summary) => {
                let summary = ResultSummary {
                    interrupted: std::mem::take(&mut self.interrupt_pending),
                    ..summary
                };
                let deltas = if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    let block = TurnBlock::ResultSummary {
                        duration_ms: summary.duration_ms,
                        cost_usd: summary.cost_usd,
                        is_error: summary.is_error,
                        interrupted: summary.interrupted,
                    };
                    self.retained_bytes += block_bytes(&block);
                    turn.blocks.push(block);
                    turn.is_complete = true;
                    let context_tokens = self.last_context_tokens;
                    vec![TurnDelta::TurnCompleted {
                        turn_id,
                        summary,
                        context_tokens,
                    }]
                } else {
                    vec![]
                };
                self.enforce_limits();
                deltas
            }
        }
    }

    /// The newest turn is a phantom if its "prompt" is a tag-wrapped system
    /// message (`<…>…</…>`), nothing answered it and it is still open when the
    /// next prompt arrives: the CLI's replay of a local command whose tags
    /// `is_harness_notification` does not know (yet). Such a turn never gets a
    /// result, and counting it would shift every ledger note's position
    /// (`prompt_count`). Drop it, keep its notes for the next turn, and return
    /// the delta that closes it for a client that already saw it start.
    fn discard_orphan_prompt(&mut self) -> Option<TurnDelta> {
        let last = self.turns.last()?;
        let wrapped = {
            let t = last.user_input.trim();
            t.starts_with('<') && t.ends_with('>')
        };
        let answered = last.blocks.iter().any(|b| !matches!(b, TurnBlock::Note { .. }));
        if last.is_complete || !wrapped || answered {
            return None;
        }
        let turn = self.turns.pop()?;
        self.prompt_count = self.prompt_count.saturating_sub(1);
        self.retained_bytes = self.retained_bytes.saturating_sub(turn_bytes(&turn));
        if self.turns.is_empty() {
            self.first_user_input = None;
        }
        // Notes made while it was the newest turn lead the next one.
        let mut notes = turn.blocks;
        notes.append(&mut self.orphan_notes);
        self.orphan_notes = notes;
        Some(TurnDelta::TurnErrored {
            turn_id: turn.id,
            message: "Not a message: a system entry the CLI replayed.".to_owned(),
            discarded: true,
        })
    }

    /// Mark the in-flight turn as errored (used on unexpected child exit).
    /// Returns the delta if there was an open turn to abort.
    pub fn mark_current_errored(&mut self, message: &str) -> Option<TurnDelta> {
        let turn = self.turns.last_mut()?;
        if turn.is_complete {
            return None;
        }
        let block = TurnBlock::ErrorMessage {
            message: message.to_string(),
        };
        self.retained_bytes += block_bytes(&block);
        turn.blocks.push(block);
        turn.is_complete = true;
        let delta = Some(TurnDelta::TurnErrored {
            turn_id: turn.id.clone(),
            message: message.to_string(),
            discarded: false,
        });
        self.enforce_limits();
        delta
    }

    /// Complete any trailing open turn without a delta (used after replaying a
    /// stored-session transcript that has no final `result` line).
    pub fn flush(&mut self) {
        if let Some(last) = self.turns.last_mut() {
            last.is_complete = true;
        }
    }

    /// Keep only the last `max_turns` turns (scrollback trimming).
    pub fn truncate_to_last(&mut self, max_turns: usize) {
        while self.turns.len() > max_turns {
            self.drop_oldest_turn();
        }
    }

    /// Enforce both retention bounds, in order: turn count, then byte budget
    /// by dropping whole (completed-first) turns, then — last resort — the
    /// oldest blocks of a single turn that's over budget on its own. Every
    /// loop removes exactly one element per iteration and stops when there is
    /// nothing left to remove, so this always terminates: it runs on the
    /// session's blocking stdout reader thread while holding the transcript
    /// mutex, and a non-terminating trim would hang every attached client.
    fn enforce_limits(&mut self) {
        while self.turns.len() > RETAINED_TURNS {
            self.drop_oldest_turn();
        }
        // Never drop the last turn here — `ingest_line` appends to
        // `turns.last_mut()`, so evicting it as a whole would silently
        // discard the live turn's output.
        while self.retained_bytes > RETAINED_BYTES && self.turns.len() > 1 {
            self.drop_oldest_turn();
        }
        if self.retained_bytes > RETAINED_BYTES {
            self.shed_oldest_blocks_of_last_turn();
        }
    }

    /// Drop the oldest retained turn and subtract its bytes from the running
    /// total. No-op on an empty transcript.
    fn drop_oldest_turn(&mut self) {
        if let Some(t) = self.turns.first() {
            self.retained_bytes = self.retained_bytes.saturating_sub(turn_bytes(t));
        }
        if !self.turns.is_empty() {
            self.turns.remove(0);
        }
    }

    /// Last resort when a single retained turn is, on its own, over budget:
    /// shed its own oldest blocks (never its newest) until back within budget
    /// or no blocks are left. May leave the transcript over budget afterward
    /// (e.g. a single oversized user prompt with no blocks at all) — a
    /// soft-budget overage is survivable, spinning on the reader thread is
    /// not.
    fn shed_oldest_blocks_of_last_turn(&mut self) {
        let over = self.retained_bytes - RETAINED_BYTES;
        let Some(turn) = self.turns.last_mut() else {
            return;
        };
        let mut shed = 0usize;
        let mut count = 0usize;
        for b in turn.blocks.iter() {
            if shed >= over {
                break;
            }
            shed += block_bytes(b);
            count += 1;
        }
        if count > 0 {
            let freed: usize = turn.blocks.drain(0..count).map(|b| block_bytes(&b)).sum();
            self.retained_bytes = self.retained_bytes.saturating_sub(freed);
        }
    }
}

/// Fill in what only the line knows: when a call or result happened, and
/// which subagent call the block came from.
fn stamp_block(
    block: &mut TurnBlock,
    at: Option<chrono::DateTime<chrono::Utc>>,
    parent: Option<&str>,
) {
    let tag_parent = |slot: &mut Option<String>| {
        if slot.is_none() {
            *slot = parent.map(str::to_string);
        }
    };
    match block {
        TurnBlock::Text {
            parent_tool_use_id, ..
        } => tag_parent(parent_tool_use_id),
        TurnBlock::ToolCall {
            ts,
            parent_tool_use_id,
            ..
        }
        | TurnBlock::ToolResult {
            ts,
            parent_tool_use_id,
            ..
        } => {
            if ts.is_none() {
                *ts = at;
            }
            tag_parent(parent_tool_use_id);
        }
        _ => {}
    }
}

/// Accounting weight of one block: fixed overhead plus its own String
/// payloads. Matches on every [`TurnBlock`] variant with no wildcard arm, so
/// adding a variant to the wire type is a compile error here rather than a
/// silently unmetered payload.
fn block_bytes(b: &TurnBlock) -> usize {
    let payload = match b {
        TurnBlock::Text {
            text,
            parent_tool_use_id,
        } => text.len() + opt_len(parent_tool_use_id),
        TurnBlock::ToolCall {
            tool_name,
            input_summary,
            input_full,
            tool_use_id,
            target,
            ts,
            parent_tool_use_id,
        } => {
            tool_name.len()
                + input_summary.len()
                + input_full.len()
                + opt_len(tool_use_id)
                + opt_len(target)
                + ts_bytes(ts)
                + opt_len(parent_tool_use_id)
        }
        TurnBlock::ToolResult {
            content,
            tool_use_id,
            ts,
            parent_tool_use_id,
            ..
        } => content.len() + opt_len(tool_use_id) + ts_bytes(ts) + opt_len(parent_tool_use_id),
        TurnBlock::ResultSummary { .. } => 0,
        TurnBlock::ErrorMessage { message } => message.len(),
        TurnBlock::Note { text, .. } => text.len(),
        TurnBlock::AskQuestion {
            question,
            header,
            options,
            ..
        } => {
            question.len()
                + header.len()
                + options
                    .iter()
                    .map(|o| o.label.len() + o.description.len())
                    .sum::<usize>()
        }
    };
    BLOCK_OVERHEAD + payload
}

fn opt_len(s: &Option<String>) -> usize {
    s.as_deref().map_or(0, str::len)
}

fn ts_bytes(ts: &Option<chrono::DateTime<chrono::Utc>>) -> usize {
    ts.map_or(0, |_| std::mem::size_of::<chrono::DateTime<chrono::Utc>>())
}

/// Accounting weight of one turn: fixed overhead, its own String fields, and
/// every block it currently holds.
fn turn_bytes(t: &Turn) -> usize {
    TURN_OVERHEAD
        + t.id.len()
        + t.user_input.len()
        + t.timestamp.as_deref().map(str::len).unwrap_or(0)
        + t.blocks.iter().map(block_bytes).sum::<usize>()
}

/// Build a [`SessionTranscript`] from the lines of a stored-session JSONL.
pub fn transcript_from_jsonl(content: &str, max_turns: usize) -> SessionTranscript {
    let mut t = SessionTranscript::new();
    for line in content.split('\n') {
        if line.trim().is_empty() {
            continue;
        }
        let _ = t.ingest_line(line);
    }
    t.flush();
    t.truncate_to_last(max_turns);
    // Rebase to the oldest SURVIVING turn, matching what `derive_summary`
    // reads via `turns.first()` today — preserves today's resume-summary
    // behavior exactly, even though the true first prompt of the whole
    // session may have been trimmed away by `truncate_to_last` above.
    t.first_user_input = t.turns.first().map(|turn| turn.user_input.clone());
    t
}

/// Locate the stored JSONL for `session_id` under `~/.claude/projects/*/` and
/// build a transcript from it. Returns an empty transcript if not found.
///
/// Sessions are stored at `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`;
/// the encoded directory isn't known at load time, so every immediate
/// subdirectory is searched (mirrors the Swift `loadScrollback`).
pub fn load_scrollback(session_id: &str, max_turns: usize) -> SessionTranscript {
    let Some(home) = dirs_next::home_dir() else {
        return SessionTranscript::new();
    };
    let projects = home.join(".claude").join("projects");
    let Ok(entries) = std::fs::read_dir(&projects) else {
        return SessionTranscript::new();
    };
    for entry in entries.flatten() {
        if !entry.path().is_dir() {
            continue;
        }
        let candidate = entry.path().join(format!("{session_id}.jsonl"));
        if candidate.is_file() {
            if let Ok(content) = std::fs::read_to_string(&candidate) {
                return transcript_from_jsonl(&content, max_turns);
            }
        }
    }
    SessionTranscript::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIMPLE: &str = include_str!("testdata/stream_simple.jsonl");
    const TOOL_SUCCESS: &str = include_str!("testdata/stream_tool_success.jsonl");
    const REPLAY_BLOCKED: &str = include_str!("testdata/stream_replay_blocked.jsonl");
    const MULTI_TURN: &str = include_str!("testdata/stream_multi_turn.jsonl");
    const SCROLLBACK: &str = include_str!("testdata/scrollback_session.jsonl");

    fn ingest_all(t: &mut SessionTranscript, content: &str) -> Vec<TurnDelta> {
        let mut deltas = vec![];
        for line in content.split('\n') {
            if line.trim().is_empty() {
                continue;
            }
            deltas.extend(t.ingest_line(line));
        }
        deltas
    }

    // ── line parsing ────────────────────────────────────────────────────────

    #[test]
    fn parses_session_id_from_init() {
        let line = r#"{"type":"system","subtype":"init","session_id":"abc-123","cwd":"/tmp"}"#;
        assert_eq!(
            parse_line(line),
            Some(ParsedLine::SessionId("abc-123".to_string()))
        );
    }

    #[test]
    fn parses_assistant_text_block() {
        let line = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks, .. }) => {
                assert_eq!(
                    blocks,
                    vec![TurnBlock::text("hello")]
                );
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn drops_thinking_blocks_for_render_parity() {
        let line = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks, .. }) => {
                assert_eq!(
                    blocks,
                    vec![TurnBlock::text("answer")]
                );
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn parses_tool_use_into_tool_call_with_summary() {
        let line = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"echo hi"}}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks, .. }) => match &blocks[0] {
                TurnBlock::ToolCall {
                    tool_name,
                    input_summary,
                    ..
                } => {
                    assert_eq!(tool_name, "Bash");
                    assert_eq!(input_summary, "echo hi");
                }
                other => panic!("expected ToolCall, got {other:?}"),
            },
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn read_tool_summary_is_basename_only() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/c/deep.rs"}}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => match &b[0] {
                TurnBlock::ToolCall { input_summary, .. } => assert_eq!(input_summary, "deep.rs"),
                other => panic!("{other:?}"),
            },
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn parses_user_string_as_prompt_with_replay_flag() {
        let line = r#"{"type":"user","message":{"role":"user","content":"hi there"},"isReplay":true,"timestamp":"2026-05-30T22:00:00.000Z"}"#;
        assert_eq!(
            parse_line(line),
            Some(ParsedLine::UserPrompt {
                text: "hi there".into(),
                is_replay: true,
                timestamp: Some("2026-05-30T22:00:00.000Z".into()),
            })
        );
    }

    #[test]
    fn sidechain_user_event_is_dropped() {
        // A sub-agent's prompt is emitted on the parent's stdout as a `user`
        // event with isSidechain:true — it must NOT open a turn.
        let line = r#"{"type":"user","message":{"role":"user","content":"You are a sub-agent. Do X."},"isSidechain":true}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn task_notification_user_event_is_dropped() {
        // A completed background task delivers a <task-notification> block as
        // a plain "user" event, same wire shape as real human input — must
        // not open a spurious turn/chat bubble.
        let line = r#"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>abc123</task-id>\n<status>completed</status>\n</task-notification>"}}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn system_reminder_user_event_is_dropped() {
        let line = r#"{"type":"user","message":{"role":"user","content":"<system-reminder>Ambient context.</system-reminder>"}}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn task_notification_in_text_array_is_dropped() {
        // Same drop must apply when the notification arrives as a
        // text-array content shape rather than a plain string.
        let line = r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<task-notification><status>completed</status></task-notification>"}]}}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn leading_whitespace_before_notification_tag_still_drops() {
        let line = r#"{"type":"user","message":{"role":"user","content":"\n\n<task-notification>...</task-notification>"}}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn non_sidechain_user_event_still_parses() {
        // Regression guard: a normal prompt (no isSidechain, or false) still parses.
        let line =
            r#"{"type":"user","message":{"role":"user","content":"hi"},"isSidechain":false}"#;
        assert!(matches!(
            parse_line(line),
            Some(ParsedLine::UserPrompt { .. })
        ));
    }

    #[test]
    fn parses_user_tool_result_array_as_blocks() {
        let line = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok","is_error":false,"tool_use_id":"t1"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => assert_eq!(
                b,
                vec![TurnBlock::ToolResult {
                    content: "ok".into(),
                    is_error: false,
                    tool_use_id: Some("t1".into()),
                    ts: None,
                    parent_tool_use_id: None,
                }]
            ),
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn parses_result_event() {
        let line = r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"total_cost_usd":0.05}"#;
        assert_eq!(
            parse_line(line),
            Some(ParsedLine::Result(ResultSummary {
                duration_ms: 1234,
                cost_usd: 0.05,
                is_error: false,
                interrupted: false,
            }))
        );
    }

    #[test]
    fn a_result_after_an_interrupt_request_is_marked_interrupted_exactly_once() {
        // The CLI ends an interrupted turn with an error result
        // (`error_during_execution`). The operator did that on purpose, so it
        // must be flagged, and ONLY that result: the next turn is a normal one.
        let mut t = SessionTranscript::new();
        t.mark_interrupt_requested();
        ingest_all(&mut t, SIMPLE);
        ingest_all(&mut t, SIMPLE);

        let results: Vec<bool> = t
            .snapshot()
            .iter()
            .flat_map(|turn| turn.blocks.iter())
            .filter_map(|b| match b {
                TurnBlock::ResultSummary { interrupted, .. } => Some(*interrupted),
                _ => None,
            })
            .collect();
        assert_eq!(results, vec![true, false], "first result interrupted, the next not");
    }

    #[test]
    fn a_result_without_an_interrupt_request_is_not_interrupted() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SIMPLE);
        assert!(t.snapshot().iter().flat_map(|turn| turn.blocks.iter()).all(|b| !matches!(
            b,
            TurnBlock::ResultSummary { interrupted: true, .. }
        )));
    }

    #[test]
    fn the_completion_delta_carries_the_interrupted_flag_too() {
        let mut t = SessionTranscript::new();
        t.mark_interrupt_requested();
        let mut saw = None;
        for line in SIMPLE.lines() {
            for d in t.ingest_line(line) {
                if let TurnDelta::TurnCompleted { summary, .. } = d {
                    saw = Some(summary.interrupted);
                }
            }
        }
        assert_eq!(saw, Some(true), "live clients get the flag on TurnCompleted, not only on replay");
    }

    #[test]
    fn rate_limit_event_is_ignored() {
        let line = r#"{"type":"rate_limit_event","rate_limit_info":{}}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn malformed_line_is_ignored() {
        assert_eq!(parse_line("not json"), None);
        assert_eq!(parse_line(""), None);
    }

    #[test]
    fn ask_user_question_becomes_card() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one","header":"H","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => match &b[0] {
                TurnBlock::AskQuestion {
                    question,
                    options,
                    multi_select,
                    ..
                } => {
                    assert_eq!(question, "Pick one");
                    assert_eq!(options.len(), 2);
                    assert!(!multi_select);
                }
                other => panic!("expected AskQuestion, got {other:?}"),
            },
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn confirm_line_splits_text_into_card() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"before\nCONFIRM:{\"q\":\"OK?\",\"h\":\"Review\",\"opts\":[{\"l\":\"Yes\",\"d\":\"do it\"}]}\nafter"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => {
                assert_eq!(b.len(), 3);
                assert_eq!(
                    b[0],
                    TurnBlock::text("before")
                );
                assert!(matches!(b[1], TurnBlock::AskQuestion { .. }));
                assert_eq!(
                    b[2],
                    TurnBlock::text("after")
                );
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn confirm_option_recommended_flag_is_parsed() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"CONFIRM:{\"q\":\"Submit?\",\"h\":\"PR\",\"opts\":[{\"l\":\"Approve\",\"d\":\"Post approval\",\"r\":true},{\"l\":\"Skip\",\"d\":\"Do nothing\"}]}"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => match &b[0] {
                TurnBlock::AskQuestion { options, .. } => {
                    assert_eq!(options.len(), 2);
                    assert!(options[0].recommended);
                    assert!(!options[1].recommended);
                }
                other => panic!("expected AskQuestion, got {other:?}"),
            },
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn confirm_line_wrapped_in_backticks_still_splits() {
        // Agents sometimes emit the directive as markdown code: `CONFIRM:{…}`.
        // It must still render as a card, not raw text.
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"before\n`CONFIRM:{\"q\":\"OK?\",\"h\":\"Review\",\"opts\":[{\"l\":\"Yes\",\"d\":\"do it\"}]}`\nafter"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks: b, .. }) => {
                assert_eq!(b.len(), 3);
                assert_eq!(
                    b[0],
                    TurnBlock::text("before")
                );
                assert!(matches!(b[1], TurnBlock::AskQuestion { .. }));
                assert_eq!(
                    b[2],
                    TurnBlock::text("after")
                );
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn suppresses_answer_questions_noise() {
        let line = r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"Answer questions?","is_error":true,"tool_use_id":"t1"}]}}"#;
        // The only block is suppressed, so the whole line renders nothing.
        assert_eq!(parse_line(line), None);
    }

    // ── transcript assembly ───────────────────────────────────────────────────

    #[test]
    fn simple_fixture_yields_one_completed_turn() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SIMPLE);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 1);
        assert!(turns[0].is_complete, "turn must complete on result");
        // text block + result summary
        assert!(turns[0]
            .blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::Text { .. })));
        assert!(turns[0]
            .blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ResultSummary { .. })));
        // The replayed user message opens the turn.
        assert_eq!(turns[0].user_input, "say hi in exactly two words");
        assert!(t.session_id().is_some(), "session id captured from init");
    }

    #[test]
    fn tool_success_fixture_has_toolcall_and_result_blocks() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, TOOL_SUCCESS);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 1);
        let blocks = &turns[0].blocks;
        assert!(blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ToolCall { .. })));
        assert!(blocks.iter().any(|b| matches!(
            b,
            TurnBlock::ToolResult {
                is_error: false,
                ..
            }
        )));
        assert!(turns[0].is_complete);
    }

    #[test]
    fn replay_fixture_creates_turn_from_replayed_user_message() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, REPLAY_BLOCKED);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 1, "the isReplay user message opens the turn");
        assert!(turns[0]
            .user_input
            .starts_with("Write a file named hello.txt"));
        // The blocked write surfaces an errored tool_result.
        assert!(turns[0]
            .blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ToolResult { is_error: true, .. })));
        assert!(turns[0].is_complete);
    }

    #[test]
    fn turn_completes_on_result_not_eof() {
        // Feed everything EXCEPT the final result line; the turn must stay open.
        let mut t = SessionTranscript::new();
        let no_result: String = SIMPLE
            .split('\n')
            .filter(|l| !l.contains(r#""type":"result""#))
            .collect::<Vec<_>>()
            .join("\n");
        ingest_all(&mut t, &no_result);
        assert!(
            t.is_mid_turn(),
            "without a result event the turn must remain in-flight (boundary = result, not EOF)"
        );
    }

    #[test]
    fn multi_turn_one_process_preserves_order() {
        let mut t = SessionTranscript::new();
        let deltas = ingest_all(&mut t, MULTI_TURN);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 2, "two result events → two turns");
        assert_eq!(turns[0].user_input, "first question");
        assert_eq!(turns[1].user_input, "second question");
        assert!(turns[0].is_complete && turns[1].is_complete);
        assert_ne!(turns[0].id, turns[1].id, "turn ids must be unique");

        // Delta ordering: two TurnStarted and two TurnCompleted, started[0]
        // before completed[0] before started[1].
        let kinds: Vec<&str> = deltas
            .iter()
            .map(|d| match d {
                TurnDelta::TurnStarted { .. } => "start",
                TurnDelta::BlockAppended { .. } => "block",
                TurnDelta::TurnCompleted { .. } => "complete",
                TurnDelta::TurnErrored { .. } => "error",
                TurnDelta::Note { .. } => "note",
            })
            .collect();
        let first_complete = kinds.iter().position(|k| *k == "complete").unwrap();
        let second_start = kinds.iter().rposition(|k| *k == "start").unwrap();
        assert!(
            first_complete < second_start,
            "first turn completes before second starts: {kinds:?}"
        );
    }

    #[test]
    fn scrollback_without_result_lines_splits_turns_on_user_prompt() {
        let t = transcript_from_jsonl(SCROLLBACK, 30);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 2, "two user prompts → two turns");
        assert_eq!(turns[0].user_input, "what is 2+2");
        assert_eq!(turns[1].user_input, "list the file");
        assert!(
            turns.iter().all(|t| t.is_complete),
            "flush completes the trailing turn even without a result line"
        );
        // Second turn carries the tool call + result.
        assert!(turns[1]
            .blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ToolCall { .. })));
    }

    #[test]
    fn truncate_keeps_last_n_turns() {
        let mut t = transcript_from_jsonl(SCROLLBACK, 1);
        t.truncate_to_last(1);
        assert_eq!(t.snapshot().len(), 1);
        assert_eq!(t.snapshot()[0].user_input, "list the file");
    }

    // ── crash recovery ────────────────────────────────────────────────────────

    #[test]
    fn mark_current_errored_aborts_open_turn() {
        let mut t = SessionTranscript::new();
        let _ =
            t.ingest_line(r#"{"type":"user","message":{"content":"do a thing"},"isReplay":true}"#);
        assert!(t.is_mid_turn());
        let delta = t.mark_current_errored("child crashed");
        assert!(matches!(delta, Some(TurnDelta::TurnErrored { .. })));
        let turns = t.snapshot();
        assert!(turns[0].is_complete);
        assert!(turns[0]
            .blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ErrorMessage { .. })));
    }

    #[test]
    fn mark_current_errored_noop_when_no_open_turn() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SIMPLE); // completes its turn
        assert!(t.mark_current_errored("x").is_none());
    }

    // ── serde round-trips (Swift interop guard) ───────────────────────────────

    #[test]
    fn turn_block_variants_round_trip() {
        let blocks = vec![
            TurnBlock::text("hi"),
            TurnBlock::ToolCall {
                tool_name: "Bash".into(),
                input_summary: "ls".into(),
                input_full: "{}".into(),
                tool_use_id: None,
                target: None,
                ts: None,
                parent_tool_use_id: None,
            },
            TurnBlock::ToolResult {
                content: "out".into(),
                is_error: false,
                tool_use_id: None,
                ts: None,
                parent_tool_use_id: None,
            },
            TurnBlock::ResultSummary {
                duration_ms: 10,
                cost_usd: 0.1,
                is_error: false,
                interrupted: false,
            },
            TurnBlock::ErrorMessage {
                message: "boom".into(),
            },
            TurnBlock::AskQuestion {
                question: "q".into(),
                header: "h".into(),
                options: vec![AskOption {
                    label: "A".into(),
                    description: "d".into(),
                    recommended: true,
                }],
                multi_select: true,
            },
        ];
        for b in blocks {
            let json = serde_json::to_string(&b).unwrap();
            let back: TurnBlock = serde_json::from_str(&json).unwrap();
            assert_eq!(b, back, "round trip for {json}");
        }
    }

    #[test]
    fn turn_block_uses_kind_tag() {
        let json = serde_json::to_value(TurnBlock::text("x")).unwrap();
        assert_eq!(json.get("kind").unwrap(), "text");
        assert_eq!(json.get("text").unwrap(), "x");
    }

    #[test]
    fn turn_delta_round_trips() {
        let deltas = vec![
            TurnDelta::TurnStarted {
                turn: Turn {
                    id: "t0".into(),
                    user_input: "hi".into(),
                    timestamp: None,
                    blocks: vec![],
                    is_complete: false,
                },
            },
            TurnDelta::BlockAppended {
                turn_id: "t0".into(),
                block: TurnBlock::text("a"),
            },
            TurnDelta::TurnCompleted {
                turn_id: "t0".into(),
                summary: ResultSummary {
                    duration_ms: 1,
                    cost_usd: 0.0,
                    is_error: false,
                    interrupted: false,
                },
                context_tokens: None,
            },
            TurnDelta::TurnErrored {
                turn_id: "t0".into(),
                message: "x".into(),
                discarded: false,
            },
        ];
        for d in deltas {
            let json = serde_json::to_string(&d).unwrap();
            let back: TurnDelta = serde_json::from_str(&json).unwrap();
            assert_eq!(d, back);
        }
    }

    #[test]
    fn session_state_round_trips() {
        for s in [
            SessionState::Idle,
            SessionState::MidTurn,
            SessionState::AwaitingPermission,
            SessionState::Crashed,
        ] {
            let json = serde_json::to_string(&s).unwrap();
            let back: SessionState = serde_json::from_str(&json).unwrap();
            assert_eq!(s, back);
        }
        assert_eq!(
            serde_json::to_string(&SessionState::MidTurn).unwrap(),
            "\"mid_turn\""
        );
    }

    // ── retention bounds ──────────────────────────────────────────────────────

    fn user_line(i: usize) -> String {
        format!(
            r#"{{"type":"user","message":{{"role":"user","content":"prompt {i}"}},"isReplay":true}}"#
        )
    }

    fn user_prompt_line(text: &str) -> String {
        format!(
            r#"{{"type":"user","message":{{"role":"user","content":"{text}"}},"isReplay":true}}"#
        )
    }

    fn tool_result_line(bytes: usize) -> String {
        let content = "x".repeat(bytes);
        format!(
            r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{content}","is_error":false,"tool_use_id":"t"}}]}}}}"#
        )
    }

    /// Like `tool_result_line`, but the content starts with a distinguishing
    /// `marker` so a test can tell WHICH specific block survived trimming.
    /// Plain `tool_result_line` output is byte-for-byte identical across
    /// calls, which makes "is the first one gone / is the last one present"
    /// unanswerable without a marker.
    fn tool_result_line_marked(marker: &str, bytes: usize) -> String {
        let mut content = marker.to_string();
        if bytes > content.len() {
            content.push_str(&"x".repeat(bytes - content.len()));
        }
        format!(
            r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{content}","is_error":false,"tool_use_id":"t"}}]}}}}"#
        )
    }

    /// A fat `tool_use` block — its `input_full` (pretty-printed JSON) also
    /// counts toward retained bytes, same as a tool_result's content.
    fn tool_use_line(bytes: usize) -> String {
        let payload = "y".repeat(bytes);
        format!(
            r#"{{"type":"assistant","message":{{"role":"assistant","content":[{{"type":"tool_use","name":"Bash","id":"tu","input":{{"command":"{payload}"}}}}]}}}}"#
        )
    }

    fn result_line() -> &'static str {
        r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#
    }

    /// Independent recount of retained byte volume, used as a drift guard
    /// against `byte_len()`'s own running total. The per-turn/per-block
    /// payload summing below is written independently of `turn_bytes`/
    /// `block_bytes` — only the two fixed overhead constants are shared,
    /// since they're production-side *parameters*, not summing logic. A
    /// mismatch here means the running total has drifted from what's
    /// actually retained, which is the real bug this recount exists to
    /// catch.
    fn recount_bytes(t: &SessionTranscript) -> usize {
        t.snapshot()
            .iter()
            .map(|turn| {
                let mut n = TURN_OVERHEAD
                    + turn.id.len()
                    + turn.user_input.len()
                    + turn.timestamp.clone().unwrap_or_default().len();
                for b in &turn.blocks {
                    n += BLOCK_OVERHEAD;
                    n += match b {
                        TurnBlock::Text {
                            text,
                            parent_tool_use_id,
                        } => text.len() + parent_tool_use_id.as_deref().map_or(0, str::len),
                        TurnBlock::ToolCall {
                            tool_name,
                            input_summary,
                            input_full,
                            tool_use_id,
                            target,
                            ts,
                            parent_tool_use_id,
                        } => {
                            tool_name.len()
                                + input_summary.len()
                                + input_full.len()
                                + tool_use_id.as_deref().map_or(0, str::len)
                                + target.as_deref().map_or(0, str::len)
                                + ts.map_or(0, |_| 12)
                                + parent_tool_use_id.as_deref().map_or(0, str::len)
                        }
                        TurnBlock::ToolResult {
                            content,
                            tool_use_id,
                            ts,
                            parent_tool_use_id,
                            ..
                        } => {
                            content.len()
                                + tool_use_id.as_deref().map_or(0, str::len)
                                + ts.map_or(0, |_| 12)
                                + parent_tool_use_id.as_deref().map_or(0, str::len)
                        }
                        TurnBlock::ResultSummary { .. } => 0,
                        TurnBlock::ErrorMessage { message } => message.len(),
                        TurnBlock::Note { text, .. } => text.len(),
                        TurnBlock::AskQuestion {
                            question,
                            header,
                            options,
                            ..
                        } => {
                            question.len()
                                + header.len()
                                + options
                                    .iter()
                                    .map(|o| o.label.len() + o.description.len())
                                    .sum::<usize>()
                        }
                    };
                }
                n
            })
            .sum()
    }

    #[test]
    fn ingest_past_retained_turns_keeps_only_the_newest() {
        let mut t = SessionTranscript::new();
        let total = 5 * RETAINED_TURNS;
        for i in 0..total {
            t.ingest_line(&user_line(i));
            t.ingest_line(result_line());
        }

        assert_eq!(
            t.turn_count(),
            RETAINED_TURNS,
            "turn count must be capped at RETAINED_TURNS after heavy ingest"
        );

        let turns = t.snapshot();
        let newest = turns.last().expect("transcript must not be empty");
        assert_eq!(
            newest.user_input,
            format!("prompt {}", total - 1),
            "the newest turn ingested must survive"
        );
        assert!(
            turns.iter().all(|turn| turn.user_input != "prompt 0"),
            "the very first turn must have been evicted by retention trimming"
        );

        // Turn ids stay unique and strictly increasing across trims — the
        // monotonic counter must never reset or reuse an id.
        let ids: Vec<u64> = turns
            .iter()
            .map(|turn| turn.id.trim_start_matches('t').parse::<u64>().unwrap())
            .collect();
        let mut sorted_ids = ids.clone();
        sorted_ids.sort_unstable();
        assert_eq!(
            ids, sorted_ids,
            "surviving turn ids must remain in strictly increasing order"
        );
        let mut deduped_ids = ids.clone();
        deduped_ids.dedup();
        assert_eq!(
            deduped_ids.len(),
            ids.len(),
            "surviving turn ids must be unique — the id counter must not be reset by trimming"
        );
    }

    #[test]
    fn retained_bytes_accounting_matches_a_full_recount() {
        let mut t = SessionTranscript::new();
        // Mixed workload: plenty of small turns, a couple carrying big
        // tool-result blocks, one carrying a fat tool_use, and one completed
        // via mark_current_errored instead of a result line — enough total
        // volume to cross BOTH RETAINED_TURNS and RETAINED_BYTES.
        let total = RETAINED_TURNS + 20;
        for i in 0..total {
            t.ingest_line(&user_line(i));
            if i == 5 {
                t.ingest_line(&tool_result_line(100 * 1024));
            }
            if i == 6 {
                t.ingest_line(&tool_result_line(250 * 1024));
                t.ingest_line(&tool_use_line(50 * 1024));
            }
            if i == 7 {
                // Completed via the crash path instead of a `result` line.
                t.mark_current_errored("simulated crash");
                continue;
            }
            t.ingest_line(result_line());
        }

        assert_eq!(
            t.byte_len(),
            recount_bytes(&t),
            "byte_len() must match an independent recount of retained turn content \
             (drift guard, not an exact-formula check — see comment on recount_bytes)"
        );
    }

    #[test]
    fn byte_budget_drops_whole_turns_before_touching_the_live_one() {
        let mut t = SessionTranscript::new();
        let one_mib = 1024 * 1024;
        // Enough completed 1 MiB turns to blow well past RETAINED_BYTES.
        let completed_turns = (RETAINED_BYTES / one_mib) + 10;
        for i in 0..completed_turns {
            t.ingest_line(&user_line(i));
            t.ingest_line(&tool_result_line(one_mib));
            t.ingest_line(result_line());
        }

        // One more turn, left in-flight, carrying a couple of small blocks.
        t.ingest_line(&user_line(completed_turns));
        t.ingest_line(&tool_result_line(1024));
        t.ingest_line(&tool_result_line(2048));

        assert!(
            t.byte_len() <= RETAINED_BYTES,
            "byte_len {} must respect RETAINED_BYTES {} after heavy ingest",
            t.byte_len(),
            RETAINED_BYTES
        );
        assert!(
            t.turn_count() < RETAINED_TURNS,
            "the byte budget must bite before the turn-count cap, given how large each turn is"
        );

        let snap = t.snapshot();
        let live = snap.last().expect("transcript must not be empty");
        assert!(
            !live.is_complete,
            "the freshly ingested turn must still be in-flight"
        );
        let has_len = |n: usize| {
            live.blocks
                .iter()
                .any(|b| matches!(b, TurnBlock::ToolResult { content, .. } if content.len() == n))
        };
        assert!(
            has_len(1024) && has_len(2048),
            "both blocks appended to the live in-flight turn must survive trimming untouched: {:?}",
            live.blocks
        );
    }

    #[test]
    fn single_oversized_turn_sheds_its_oldest_blocks() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_line(0));

        let one_mib = 1024 * 1024;
        let block_count = (RETAINED_BYTES / one_mib) + 10;
        for i in 0..block_count {
            t.ingest_line(&tool_result_line_marked(&format!("block{i}"), one_mib));
        }

        assert_eq!(
            t.turn_count(),
            1,
            "a single in-flight turn must never be dropped as a whole turn"
        );
        assert!(
            t.byte_len() <= RETAINED_BYTES,
            "byte_len {} must be capped at RETAINED_BYTES {} even for one oversized turn",
            t.byte_len(),
            RETAINED_BYTES
        );

        let snap = t.snapshot();
        let blocks = &snap[0].blocks;
        let has_marker = |marker: &str| {
            blocks.iter().any(
                |b| matches!(b, TurnBlock::ToolResult { content, .. } if content.starts_with(marker)),
            )
        };
        assert!(
            has_marker(&format!("block{}", block_count - 1)),
            "the LAST block ingested must still be present after shedding"
        );
        assert!(
            !has_marker("block0"),
            "the FIRST block ingested must have been shed to make room — newest data wins"
        );
    }

    #[test]
    fn a_single_giant_user_prompt_terminates_without_spinning() {
        let mut t = SessionTranscript::new();
        // The prompt text alone exceeds RETAINED_BYTES, with no blocks at all
        // — nothing left to shed, so it's retained as-is (documented escape
        // hatch). The test itself completing within the normal test timeout
        // IS the proof that enforcement doesn't spin/hang on this case.
        let giant = "x".repeat(RETAINED_BYTES + 1);
        t.ingest_line(&user_prompt_line(&giant));

        assert_eq!(
            t.turn_count(),
            1,
            "the oversized prompt turn must be retained since there's nothing left to shed"
        );

        // The transcript must keep working afterward.
        t.ingest_line(&user_line(999));
        t.ingest_line(result_line());
        assert!(
            t.turn_count() >= 1,
            "transcript must still be operable after housing an oversized turn"
        );
        let snap = t.snapshot();
        assert_eq!(
            snap.last().unwrap().user_input,
            "prompt 999",
            "a normal turn ingested after the giant one must complete normally"
        );
    }

    #[test]
    fn trimming_never_drops_the_in_flight_turn() {
        let mut t = SessionTranscript::new();
        let one_mib = 1024 * 1024;
        // Drive well past BOTH RETAINED_TURNS and RETAINED_BYTES with
        // completed turns — a trim must fire on at least one of these ingests.
        let completed_turns = 2 * RETAINED_TURNS;
        for i in 0..completed_turns {
            t.ingest_line(&user_line(i));
            t.ingest_line(&tool_result_line(one_mib));
            t.ingest_line(result_line());
        }

        // Drive one fresh turn through start → block → complete, capturing
        // the deltas each ingest_line call returns.
        let started = t.ingest_line(&user_line(completed_turns));
        let blocked = t.ingest_line(&tool_result_line(1024));
        let completed = t.ingest_line(result_line());

        let started_id = match started.as_slice() {
            [TurnDelta::TurnStarted { turn }] => turn.id.clone(),
            other => panic!("expected a single TurnStarted delta, got {other:?}"),
        };
        let blocked_id = match blocked.as_slice() {
            [TurnDelta::BlockAppended { turn_id, .. }] => turn_id.clone(),
            other => panic!("expected a single BlockAppended delta, got {other:?}"),
        };
        let completed_id = match completed.as_slice() {
            [TurnDelta::TurnCompleted { turn_id, .. }] => turn_id.clone(),
            other => panic!("expected a single TurnCompleted delta, got {other:?}"),
        };
        assert_eq!(
            started_id, blocked_id,
            "the block must land on the turn that was just started"
        );
        assert_eq!(
            blocked_id, completed_id,
            "the completion must land on the same turn that was started and blocked"
        );

        let snap = t.snapshot();
        let last = snap.last().expect("transcript must not be empty");
        assert!(
            last.is_complete,
            "the freshly driven turn must have completed"
        );
        assert_eq!(
            last.id, started_id,
            "the in-flight turn must never be evicted mid-turn by a trim triggered by earlier ingests"
        );
        assert!(
            last.blocks.iter().any(
                |b| matches!(b, TurnBlock::ToolResult { content, .. } if content.len() == 1024)
            ),
            "the block appended to the live turn must survive: {:?}",
            last.blocks
        );
    }

    #[test]
    fn first_user_input_survives_trimming() {
        let mut t = SessionTranscript::new();
        let total = RETAINED_TURNS + 50;
        for i in 0..total {
            t.ingest_line(&user_line(i));
            t.ingest_line(result_line());
        }

        assert_eq!(
            t.first_user_input(),
            Some("prompt 0"),
            "first_user_input must survive trimming even though the first turn is long gone"
        );
        assert_ne!(
            t.snapshot()[0].user_input,
            "prompt 0",
            "sanity check: the oldest surviving turn really has been trimmed away"
        );
    }

    #[test]
    fn transcript_from_jsonl_rebases_first_user_input_to_the_oldest_retained_turn() {
        // Same fixture + max_turns as `truncate_keeps_last_n_turns`, which
        // proves the surviving turn's user_input is "list the file".
        // first_user_input() must rebase to match — preserving today's
        // resume-summary behavior (which reads turns.first()) exactly, NOT
        // the true first prompt of the whole session if that was trimmed away.
        let t = transcript_from_jsonl(SCROLLBACK, 1);
        assert_eq!(
            t.first_user_input(),
            Some("list the file"),
            "first_user_input must rebase to the oldest SURVIVING turn after load-time truncation"
        );
    }

    #[test]
    fn truncate_to_last_updates_byte_accounting() {
        let mut t = SessionTranscript::new();
        for i in 0..10 {
            t.ingest_line(&user_line(i));
            if i % 3 == 0 {
                t.ingest_line(&tool_result_line(50_000));
            } else {
                t.ingest_line(&tool_result_line(500));
            }
            t.ingest_line(result_line());
        }

        t.truncate_to_last(4);

        assert_eq!(t.snapshot().len(), 4);
        assert_eq!(
            t.byte_len(),
            recount_bytes(&t),
            "byte_len() must be updated to reflect only the surviving turns after truncate_to_last"
        );
    }

    #[test]
    fn recent_turns_returns_the_newest_and_never_more_than_asked() {
        let mut t = SessionTranscript::new();
        for i in 0..5 {
            t.ingest_line(&user_line(i));
            t.ingest_line(result_line());
        }
        let snap = t.snapshot();

        let last_two = t.recent_turns(2);
        assert_eq!(last_two.len(), 2);
        assert_eq!(
            last_two,
            snap[snap.len() - 2..],
            "recent_turns(2) must be the last two turns, newest last, same order as snapshot()"
        );

        assert_eq!(
            t.recent_turns(0).len(),
            0,
            "recent_turns(0) must return an empty vec"
        );

        let all = t.recent_turns(100);
        assert_eq!(
            all.len(),
            5,
            "asking for more turns than exist must return everything, not panic"
        );
        assert_eq!(all, snap);
    }

    // ── replay frames the CLI writes for its own commands ─────────────────────

    fn user_event(content: serde_json::Value) -> String {
        serde_json::json!({"type": "user", "isReplay": true, "message": {"role": "user", "content": content}}).to_string()
    }

    fn assistant_event(text: &str) -> String {
        serde_json::json!({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}).to_string()
    }

    const PHANTOM: &str = "<new-wrapper>whatever</new-wrapper>";

    #[test]
    fn the_clis_own_command_replays_make_no_turn_whatever_wording_they_carry() {
        for text in [
            "<local-command-stdout>Switched the model → sonnet</local-command-stdout>",
            "<local-command-stdout>Set model to `sonnet (claude-sonnet-5-5)`</local-command-stdout>",
            "<local-command-stdout>Effort set to high</local-command-stdout>",
            "<local-command-stderr>Error: no such model</local-command-stderr>",
            "<local-command-caveat>Caveat: the messages below were generated by the user.</local-command-caveat>",
            "<local-command-some-future-kind>anything at all</local-command-some-future-kind>",
            "\n\n  <local-command-stdout>after leading blank space</local-command-stdout>",
            "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>",
            "<command-name>/effort</command-name>",
            "<command-message>effort</command-message>",
            "<command-args>high</command-args>",
        ] {
            assert_eq!(parse_line(&user_event(serde_json::json!(text))), None, "string content: {text:?}");
            assert_eq!(
                parse_line(&user_event(serde_json::json!([{"type": "text", "text": text}]))),
                None,
                "text-array content: {text:?}"
            );
        }
    }

    #[test]
    fn a_real_prompt_that_only_mentions_such_a_tag_is_still_a_prompt() {
        for text in [
            "why does <local-command-stdout> show up in my transcript?",
            "what does <command-name> mean here",
            "ok, now run /model and tell me about <command-args>",
        ] {
            assert!(
                matches!(parse_line(&user_event(serde_json::json!(text))), Some(ParsedLine::UserPrompt { .. })),
                "{text:?} is something the user typed"
            );
        }
    }

    #[test]
    fn a_wrapped_prompt_that_was_never_answered_is_dropped_once_the_next_prompt_arrives() {
        let mut t = SessionTranscript::new();
        let started = t.ingest_line(&user_event(serde_json::json!(PHANTOM)));
        let phantom_id = match &started[..] {
            [TurnDelta::TurnStarted { turn }] => turn.id.clone(),
            other => panic!("a prompt opens a turn: {other:?}"),
        };

        let replaced = t.ingest_line(&user_event(serde_json::json!("hi")));
        t.ingest_line(&assistant_event("hello"));
        t.ingest_line(result_line());

        let turns = t.snapshot();
        assert_eq!(turns.len(), 1, "only the real prompt is a turn: {turns:?}");
        assert_eq!(turns[0].user_input, "hi");
        assert!(turns[0].is_complete);
        assert_eq!(t.prompt_count(), 1, "the phantom never counted as a prompt");
        assert!(
            replaced.iter().any(|d| matches!(d, TurnDelta::TurnErrored { turn_id, .. } if *turn_id == phantom_id)),
            "a client that already saw the phantom's TurnStarted is told to close it: {replaced:?}"
        );
        assert!(
            replaced.iter().any(|d| matches!(d, TurnDelta::TurnStarted { turn } if turn.user_input == "hi")),
            "{replaced:?}"
        );
    }

    /// The `TurnErrored` deltas among `deltas`, as `(turn_id, discarded)`.
    fn errored(deltas: &[TurnDelta]) -> Vec<(String, bool)> {
        deltas
            .iter()
            .filter_map(|d| match d {
                TurnDelta::TurnErrored { turn_id, discarded, .. } => Some((turn_id.clone(), *discarded)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_delta_that_drops_a_phantom_says_it_was_discarded_so_it_is_not_mistaken_for_a_turn_end() {
        let mut t = SessionTranscript::new();
        let started = t.ingest_line(&user_event(serde_json::json!(PHANTOM)));
        let phantom_id = match &started[..] {
            [TurnDelta::TurnStarted { turn }] => turn.id.clone(),
            other => panic!("a prompt opens a turn: {other:?}"),
        };

        let replaced = t.ingest_line(&user_event(serde_json::json!("hi")));

        assert_eq!(
            errored(&replaced),
            [(phantom_id, true)],
            "the phantom is closed for the clients that saw it start, and marked as never having been a turn"
        );
    }

    #[test]
    fn a_turn_aborted_by_a_crash_is_an_ended_turn_not_a_discard() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_event(serde_json::json!("do a thing")));

        let delta = t.mark_current_errored("child crashed").expect("there was an open turn");

        assert_eq!(errored(&[delta]).iter().map(|(_, discarded)| *discarded).collect::<Vec<_>>(), [false]);
    }

    #[test]
    fn whether_an_errored_turn_was_discarded_is_not_on_the_wire() {
        let ended = TurnDelta::TurnErrored { turn_id: "t0".into(), message: "x".into(), discarded: false };
        let dropped = TurnDelta::TurnErrored { turn_id: "t1".into(), message: "y".into(), discarded: true };

        for delta in [&ended, &dropped] {
            let json = serde_json::to_value(delta).unwrap();
            assert_eq!(json["delta"], "turn_errored");
            assert!(json.get("discarded").is_none(), "no new key for the clients to trip over: {json}");
            assert_eq!(
                json.as_object().unwrap().keys().cloned().collect::<std::collections::BTreeSet<_>>(),
                ["delta", "message", "turn_id"].map(String::from).into_iter().collect(),
                "the same keys as before the flag existed"
            );
        }
        let back: TurnDelta = serde_json::from_value(serde_json::to_value(&ended).unwrap()).unwrap();
        assert_eq!(back, ended, "an ordinary errored turn still round-trips");
    }

    #[test]
    fn a_note_made_while_a_phantom_was_the_last_turn_leads_the_real_turn() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_event(serde_json::json!(PHANTOM)));
        t.add_note(TurnBlock::Note {
            note_kind: NoteKind::ModelChanged,
            text: "Model changed to Opus (from Sonnet) by you.".into(),
            ts: chrono::Utc::now(),
        });

        t.ingest_line(&user_event(serde_json::json!("hi")));

        let turns = t.snapshot();
        assert_eq!(turns.len(), 1);
        assert!(
            matches!(turns[0].blocks.first(), Some(TurnBlock::Note { text, .. }) if text.starts_with("Model changed")),
            "the note did not vanish with the phantom: {:?}",
            turns[0].blocks
        );
        assert_eq!(turns[0].user_input, "hi");
    }

    #[test]
    fn a_real_unanswered_prompt_is_never_dropped() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_event(serde_json::json!("hello")));
        t.ingest_line(&user_event(serde_json::json!("hello? anyone?")));

        let turns = t.snapshot();
        assert_eq!(turns.iter().map(|t| t.user_input.as_str()).collect::<Vec<_>>(), ["hello", "hello? anyone?"]);
        assert_eq!(t.prompt_count(), 2);
    }

    #[test]
    fn a_wrapped_prompt_that_got_an_answer_is_a_real_turn() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_event(serde_json::json!("<tag>pasted xml</tag>")));
        t.ingest_line(&assistant_event("I see the tag"));
        t.ingest_line(&user_event(serde_json::json!("next")));

        assert_eq!(t.turn_count(), 2);
        assert_eq!(t.prompt_count(), 2);
    }

    #[test]
    fn a_wrapped_prompt_is_kept_until_something_follows_it() {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_event(serde_json::json!(PHANTOM)));

        assert_eq!(t.turn_count(), 1, "it may still be answered");
        assert_eq!(t.prompt_count(), 1);
    }

    #[test]
    fn a_stored_session_drops_the_same_phantom() {
        let jsonl = [
            user_event(serde_json::json!(PHANTOM)),
            user_event(serde_json::json!("hi")),
            assistant_event("hello"),
        ]
        .join("\n");

        let t = transcript_from_jsonl(&jsonl, 100);

        assert_eq!(t.turn_count(), 1);
        assert_eq!(t.prompt_count(), 1);
        assert_eq!(t.snapshot()[0].user_input, "hi");
    }

    // ── TF1: wire enrichment (ids, times, targets, subagent tags) ───────────────

    const SUBAGENT: &str = include_str!("testdata/stream_subagent.jsonl");
    const THINKING_BETWEEN_CALLS: &str =
        include_str!("testdata/stream_thinking_between_calls.jsonl");

    fn utc(s: &str) -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339(s)
            .expect("test timestamp")
            .with_timezone(&chrono::Utc)
    }

    /// The blocks of the transcript's only turn, minus the end-of-turn summary.
    fn only_turn_blocks(t: &SessionTranscript) -> Vec<TurnBlock> {
        let turns = t.snapshot();
        assert_eq!(turns.len(), 1, "expected exactly one turn");
        turns[0]
            .blocks
            .iter()
            .filter(|b| !matches!(b, TurnBlock::ResultSummary { .. }))
            .cloned()
            .collect()
    }

    fn call_parts(b: &TurnBlock) -> (&str, Option<&str>, Option<&str>, Option<&str>) {
        match b {
            TurnBlock::ToolCall {
                tool_name,
                tool_use_id,
                target,
                parent_tool_use_id,
                ..
            } => (
                tool_name,
                tool_use_id.as_deref(),
                target.as_deref(),
                parent_tool_use_id.as_deref(),
            ),
            other => panic!("expected ToolCall, got {other:?}"),
        }
    }

    fn result_parts(b: &TurnBlock) -> (&str, Option<&str>, Option<&str>) {
        match b {
            TurnBlock::ToolResult {
                content,
                tool_use_id,
                parent_tool_use_id,
                ..
            } => (content, tool_use_id.as_deref(), parent_tool_use_id.as_deref()),
            other => panic!("expected ToolResult, got {other:?}"),
        }
    }

    fn parent_of(b: &TurnBlock) -> Option<&str> {
        match b {
            TurnBlock::Text {
                parent_tool_use_id, ..
            }
            | TurnBlock::ToolCall {
                parent_tool_use_id, ..
            }
            | TurnBlock::ToolResult {
                parent_tool_use_id, ..
            } => parent_tool_use_id.as_deref(),
            other => panic!("block carries no parent: {other:?}"),
        }
    }

    fn ts_of(b: &TurnBlock) -> Option<chrono::DateTime<chrono::Utc>> {
        match b {
            TurnBlock::ToolCall { ts, .. } | TurnBlock::ToolResult { ts, .. } => *ts,
            other => panic!("block carries no ts: {other:?}"),
        }
    }

    fn first_call(blocks: &[TurnBlock]) -> &TurnBlock {
        blocks
            .iter()
            .find(|b| matches!(b, TurnBlock::ToolCall { .. }))
            .expect("a tool call")
    }

    fn first_result(blocks: &[TurnBlock]) -> &TurnBlock {
        blocks
            .iter()
            .find(|b| matches!(b, TurnBlock::ToolResult { .. }))
            .expect("a tool result")
    }

    /// A turn opened by a prompt, ready for further lines.
    fn transcript_with_open_turn() -> SessionTranscript {
        let mut t = SessionTranscript::new();
        t.ingest_line(&user_line(0));
        t
    }

    #[test]
    fn a_call_and_its_result_share_the_cli_tool_use_id() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, TOOL_SUCCESS);
        let blocks = only_turn_blocks(&t);

        let (name, call_id, _, _) = call_parts(first_call(&blocks));
        let (_, result_id, _) = result_parts(first_result(&blocks));

        assert_eq!(name, "Bash");
        assert_eq!(call_id, Some("toolu_011LGjEjhLiT5jVof1o2zFHU"));
        assert_eq!(result_id, Some("toolu_011LGjEjhLiT5jVof1o2zFHU"));
    }

    #[test]
    fn a_result_takes_the_timestamp_of_the_line_that_carried_it() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, TOOL_SUCCESS);
        let blocks = only_turn_blocks(&t);

        assert_eq!(
            ts_of(first_result(&blocks)),
            Some(utc("2026-05-30T22:38:55.755Z"))
        );
    }

    #[test]
    fn a_call_from_a_line_without_a_timestamp_has_no_time_unless_the_transcript_is_live() {
        // Live `assistant` lines carry no timestamp.
        let mut replay = SessionTranscript::new();
        assert!(!replay.is_live(), "a new transcript is not live");
        ingest_all(&mut replay, TOOL_SUCCESS);
        assert_eq!(ts_of(first_call(&only_turn_blocks(&replay))), None);

        let mut live = SessionTranscript::new();
        live.set_live(true);
        assert!(live.is_live());
        let before = chrono::Utc::now();
        ingest_all(&mut live, TOOL_SUCCESS);
        let after = chrono::Utc::now();
        let blocks = only_turn_blocks(&live);

        let call_ts = ts_of(first_call(&blocks)).expect("a live call is stamped with receive time");
        assert!(
            before <= call_ts && call_ts <= after,
            "{call_ts} not within {before}..{after}"
        );
        // A line that has its own timestamp keeps it, live or not.
        assert_eq!(
            ts_of(first_result(&blocks)),
            Some(utc("2026-05-30T22:38:55.755Z"))
        );
    }

    #[test]
    fn a_replayed_session_gets_times_from_its_lines_and_never_invents_one() {
        let t = transcript_from_jsonl(SCROLLBACK, 30);
        assert!(!t.is_live(), "a stored session is a replay");

        let turns = t.snapshot();
        let blocks = &turns[1].blocks;
        assert_eq!(
            ts_of(first_call(blocks)),
            Some(utc("2026-05-30T20:01:01Z"))
        );
        assert_eq!(
            ts_of(first_result(blocks)),
            Some(utc("2026-05-30T20:01:02Z"))
        );

        // Every time on the wire is one that is present in the source lines.
        let source: Vec<chrono::DateTime<chrono::Utc>> = SCROLLBACK
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get("timestamp")?.as_str().map(utc))
            .collect();
        let mut stamped = 0;
        for turn in &turns {
            for b in &turn.blocks {
                if let TurnBlock::ToolCall { ts, .. } | TurnBlock::ToolResult { ts, .. } = b {
                    stamped += 1;
                    let ts = ts.expect("every line in this session has a timestamp");
                    assert!(source.contains(&ts), "{ts} is not a source-line time");
                }
            }
        }
        assert_eq!(stamped, 2, "the call and its result");
    }

    #[test]
    fn a_replayed_line_without_a_timestamp_stays_untimed() {
        let jsonl = [
            r#"{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-05-30T20:00:00.000Z"}"#,
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"toolu_x","input":{"command":"ls"}}]}}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"a","is_error":false,"tool_use_id":"toolu_x"}]}}"#,
        ]
        .join("\n");

        let t = transcript_from_jsonl(&jsonl, 30);
        let blocks = only_turn_blocks(&t);

        assert_eq!(ts_of(first_call(&blocks)), None);
        assert_eq!(ts_of(first_result(&blocks)), None);
        assert!(!t.is_live());
    }

    #[test]
    fn an_empty_successful_result_is_kept_with_its_id() {
        let line = r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"","is_error":false,"tool_use_id":"toolu_quiet"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks, .. }) => {
                assert_eq!(blocks.len(), 1);
                match &blocks[0] {
                    TurnBlock::ToolResult {
                        content,
                        is_error,
                        tool_use_id,
                        ..
                    } => {
                        assert_eq!(content, "");
                        assert!(!is_error);
                        assert_eq!(tool_use_id.as_deref(), Some("toolu_quiet"));
                    }
                    other => panic!("expected ToolResult, got {other:?}"),
                }
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn an_empty_successful_result_reaches_the_transcript() {
        let mut t = transcript_with_open_turn();
        t.ingest_line(r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"","is_error":false,"tool_use_id":"toolu_quiet"}]}}"#);

        let blocks = &t.snapshot()[0].blocks;
        let (content, id, _) = result_parts(first_result(blocks));
        assert_eq!(content, "");
        assert_eq!(id, Some("toolu_quiet"));
    }

    #[test]
    fn the_answer_questions_error_is_still_suppressed_next_to_a_kept_empty_result() {
        let line = r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"Answer questions?","is_error":true,"tool_use_id":"toolu_ask"},{"type":"tool_result","content":"","is_error":false,"tool_use_id":"toolu_quiet"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks { blocks, .. }) => {
                assert_eq!(blocks.len(), 1, "only the quiet success survives");
                assert_eq!(result_parts(&blocks[0]).1, Some("toolu_quiet"));
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    // ── subagent traffic ─────────────────────────────────────────────────────────

    #[test]
    fn subagent_traffic_is_tagged_with_its_agent_call_and_the_main_agents_is_not() {
        // stream_subagent.jsonl is SYNTHETIC (hand-written to the shape the CLI
        // is believed to emit; JSONL has no comments, so it is flagged here).
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SUBAGENT);
        let blocks = only_turn_blocks(&t);
        const AGENT: Option<&str> = Some("toolu_agent1");

        assert_eq!(blocks.len(), 10, "{blocks:#?}");

        // Main agent: prose, the Agent call.
        assert!(matches!(&blocks[0], TurnBlock::Text { text, .. } if text == "Delegating the survey."));
        assert_eq!(parent_of(&blocks[0]), None);
        assert_eq!(call_parts(&blocks[1]), ("Agent", AGENT, None, None));

        // Subagent: text, Read call, its result.
        assert!(matches!(&blocks[2], TurnBlock::Text { text, .. } if text == "Reading the config."));
        assert_eq!(parent_of(&blocks[2]), AGENT);
        assert_eq!(
            call_parts(&blocks[3]),
            ("Read", Some("toolu_sub_read"), Some("/repo/src/config.rs"), AGENT)
        );
        assert_eq!(
            result_parts(&blocks[4]),
            ("fn config() {}", Some("toolu_sub_read"), AGENT)
        );

        // Subagent: text, Bash call, its quiet (empty) result.
        assert!(matches!(&blocks[5], TurnBlock::Text { text, .. } if text == "Staging the notes."));
        assert_eq!(parent_of(&blocks[5]), AGENT);
        assert_eq!(
            call_parts(&blocks[6]),
            ("Bash", Some("toolu_sub_bash"), None, AGENT)
        );
        assert_eq!(result_parts(&blocks[7]), ("", Some("toolu_sub_bash"), AGENT));

        // The Agent call's own result and the main agent's closing prose.
        assert_eq!(
            result_parts(&blocks[8]),
            ("The config is one small function.", Some("toolu_agent1"), None)
        );
        assert!(matches!(&blocks[9], TurnBlock::Text { text, .. } if text.starts_with("The subagent found")));
        assert_eq!(parent_of(&blocks[9]), None);
    }

    #[test]
    fn subagent_results_carry_the_times_of_their_lines() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SUBAGENT);
        let blocks = only_turn_blocks(&t);

        assert_eq!(ts_of(&blocks[4]), Some(utc("2026-06-01T10:00:05Z")));
        assert_eq!(ts_of(&blocks[7]), Some(utc("2026-06-01T10:00:08Z")));
        assert_eq!(ts_of(&blocks[8]), Some(utc("2026-06-01T10:00:09Z")));
    }

    #[test]
    fn a_subagent_prompt_opens_no_turn_and_the_fixture_makes_one_turn() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, SUBAGENT);

        assert_eq!(t.turn_count(), 1);
        assert_eq!(t.prompt_count(), 1);
        assert_eq!(
            t.snapshot()[0].user_input,
            "Survey the config and tell me what you find."
        );
        assert!(t.snapshot()[0].is_complete);
    }

    #[test]
    fn a_sidechain_prompt_alone_opens_no_turn() {
        let mut t = SessionTranscript::new();
        t.ingest_line(r#"{"type":"user","message":{"role":"user","content":"Do X."},"isSidechain":true,"parent_tool_use_id":"toolu_agent1"}"#);

        assert_eq!(t.turn_count(), 0);
        assert_eq!(t.prompt_count(), 0);
    }

    #[test]
    fn a_sidechain_text_array_prompt_is_dropped() {
        let line = r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Do X."}]},"isSidechain":true,"parent_tool_use_id":"toolu_agent1"}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn a_sidechain_user_event_mixing_text_and_tool_results_is_dropped() {
        let line = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"out","is_error":false,"tool_use_id":"toolu_s"},{"type":"text","text":"and a prompt"}]},"isSidechain":true,"parent_tool_use_id":"toolu_agent1"}"#;
        assert_eq!(parse_line(line), None);
    }

    #[test]
    fn a_sidechain_event_with_no_parent_id_is_tagged_with_the_unknown_marker() {
        let mut t = transcript_with_open_turn();
        t.ingest_line(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"sub says"},{"type":"tool_use","id":"toolu_s1","name":"Bash","input":{"command":"ls"}}]},"isSidechain":true}"#);
        t.ingest_line(r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"out","is_error":false,"tool_use_id":"toolu_s1"}]},"isSidechain":true}"#);

        let blocks = &t.snapshot()[0].blocks;
        assert_eq!(blocks.len(), 3);
        for b in blocks {
            assert_eq!(parent_of(b), Some("?"), "{b:?}");
        }
        assert_eq!(UNKNOWN_PARENT, "?");
    }

    #[test]
    fn a_non_sidechain_result_that_names_a_parent_is_tagged() {
        let mut t = transcript_with_open_turn();
        t.ingest_line(r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"out","is_error":false,"tool_use_id":"toolu_s1"}]},"parent_tool_use_id":"toolu_agent1"}"#);

        let blocks = &t.snapshot()[0].blocks;
        assert_eq!(result_parts(&blocks[0]), ("out", Some("toolu_s1"), Some("toolu_agent1")));
    }

    #[test]
    fn a_null_parent_and_no_sidechain_flag_is_the_main_agent() {
        let mut t = transcript_with_open_turn();
        t.ingest_line(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"mine"}]},"parent_tool_use_id":null,"isSidechain":false}"#);

        assert_eq!(parent_of(&t.snapshot()[0].blocks[0]), None);
    }

    // ── thinking between calls ───────────────────────────────────────────────────

    #[test]
    fn two_calls_separated_only_by_thinking_end_up_adjacent() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, THINKING_BETWEEN_CALLS);
        let blocks = only_turn_blocks(&t);

        let call_positions: Vec<usize> = blocks
            .iter()
            .enumerate()
            .filter(|(_, b)| matches!(b, TurnBlock::ToolCall { .. }))
            .map(|(i, _)| i)
            .collect();
        assert_eq!(call_positions.len(), 2);
        assert_eq!(
            call_positions[1],
            call_positions[0] + 1,
            "no block (thinking is dropped) sits between the calls: {blocks:#?}"
        );
        assert_eq!(call_parts(&blocks[call_positions[0]]).1, Some("toolu_first"));
        assert_eq!(call_parts(&blocks[call_positions[1]]).1, Some("toolu_second"));
        assert!(
            blocks.iter().all(|b| !matches!(b, TurnBlock::Note { .. })),
            "thinking must not surface as another kind of block"
        );
    }

    // ── target ───────────────────────────────────────────────────────────────────

    fn call_target(tool: &str, input: &str) -> Option<String> {
        let line = format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"toolu_t","name":"{tool}","input":{input}}}]}}}}"#
        );
        match parse_line(&line) {
            Some(ParsedLine::Blocks { blocks, .. }) => match &blocks[0] {
                TurnBlock::ToolCall { target, .. } => target.clone(),
                other => panic!("expected ToolCall, got {other:?}"),
            },
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn file_tools_report_the_full_path_they_work_on() {
        for tool in ["Read", "Write", "Edit", "MultiEdit"] {
            assert_eq!(
                call_target(tool, r#"{"file_path":"/repo/deep/dir/file.rs"}"#).as_deref(),
                Some("/repo/deep/dir/file.rs"),
                "{tool}"
            );
        }
        assert_eq!(
            call_target("NotebookEdit", r#"{"notebook_path":"/repo/nb/run.ipynb"}"#).as_deref(),
            Some("/repo/nb/run.ipynb")
        );
    }

    #[test]
    fn tools_that_are_not_file_tools_report_no_target() {
        assert_eq!(call_target("Bash", r#"{"command":"ls"}"#), None);
        assert_eq!(call_target("Bash", r#"{"command":"ls","file_path":"/x"}"#), None);
        assert_eq!(call_target("Grep", r#"{"pattern":"x","path":"/repo"}"#), None);
        assert_eq!(call_target("Read", r#"{}"#), None);
    }

    // ── serde: additive, optional fields ─────────────────────────────────────────

    fn fully_tagged_blocks() -> Vec<TurnBlock> {
        let ts = Some(utc("2026-06-01T10:00:05.250Z"));
        vec![
            TurnBlock::Text {
                text: "hi".into(),
                parent_tool_use_id: Some("toolu_agent1".into()),
            },
            TurnBlock::ToolCall {
                tool_name: "Read".into(),
                input_summary: "a.rs".into(),
                input_full: "{}".into(),
                tool_use_id: Some("toolu_c".into()),
                target: Some("/repo/a.rs".into()),
                ts,
                parent_tool_use_id: Some("toolu_agent1".into()),
            },
            TurnBlock::ToolResult {
                content: "out".into(),
                is_error: true,
                tool_use_id: Some("toolu_c".into()),
                ts,
                parent_tool_use_id: Some("?".into()),
            },
        ]
    }

    #[test]
    fn enriched_blocks_round_trip_through_json() {
        for block in fully_tagged_blocks() {
            let json = serde_json::to_string(&block).unwrap();
            let back: TurnBlock = serde_json::from_str(&json).unwrap();
            assert_eq!(back, block, "{json}");
        }
    }

    #[test]
    fn enriched_blocks_use_the_documented_key_names() {
        let blocks = fully_tagged_blocks();
        let call = serde_json::to_value(&blocks[1]).unwrap();
        assert_eq!(call["tool_use_id"], "toolu_c");
        assert_eq!(call["target"], "/repo/a.rs");
        assert_eq!(call["parent_tool_use_id"], "toolu_agent1");
        let ts = call["ts"].as_str().expect("ts is an RFC 3339 string");
        assert_eq!(utc(ts), utc("2026-06-01T10:00:05.250Z"));

        let result = serde_json::to_value(&blocks[2]).unwrap();
        assert_eq!(result["tool_use_id"], "toolu_c");
        assert!(result["ts"].is_string());
        assert_eq!(result["parent_tool_use_id"], "?");

        let text = serde_json::to_value(&blocks[0]).unwrap();
        assert_eq!(text["parent_tool_use_id"], "toolu_agent1");
    }

    #[test]
    fn blocks_from_before_the_enrichment_still_deserialize_with_the_new_fields_unset() {
        let call: TurnBlock = serde_json::from_str(
            r#"{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{}"}"#,
        )
        .unwrap();
        assert_eq!(
            call,
            TurnBlock::ToolCall {
                tool_name: "Bash".into(),
                input_summary: "ls".into(),
                input_full: "{}".into(),
                tool_use_id: None,
                target: None,
                ts: None,
                parent_tool_use_id: None,
            }
        );

        let result: TurnBlock =
            serde_json::from_str(r#"{"kind":"tool_result","content":"x","is_error":false}"#)
                .unwrap();
        assert_eq!(
            result,
            TurnBlock::ToolResult {
                content: "x".into(),
                is_error: false,
                tool_use_id: None,
                ts: None,
                parent_tool_use_id: None,
            }
        );

        let text: TurnBlock = serde_json::from_str(r#"{"kind":"text","text":"x"}"#).unwrap();
        assert_eq!(text, TurnBlock::text("x"));
    }

    #[test]
    fn untagged_blocks_serialize_with_exactly_the_pre_enrichment_keys() {
        fn keys(b: &TurnBlock) -> Vec<String> {
            let mut k: Vec<String> = serde_json::to_value(b)
                .unwrap()
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect();
            k.sort();
            k
        }
        let call = TurnBlock::ToolCall {
            tool_name: "Bash".into(),
            input_summary: "ls".into(),
            input_full: "{}".into(),
            tool_use_id: None,
            target: None,
            ts: None,
            parent_tool_use_id: None,
        };
        let result = TurnBlock::ToolResult {
            content: "x".into(),
            is_error: false,
            tool_use_id: None,
            ts: None,
            parent_tool_use_id: None,
        };

        assert_eq!(keys(&call), ["input_full", "input_summary", "kind", "tool_name"]);
        assert_eq!(keys(&result), ["content", "is_error", "kind"]);
        assert_eq!(keys(&TurnBlock::text("x")), ["kind", "text"]);
    }

    // ── byte accounting of the new fields ────────────────────────────────────────

    fn call_line(extra: &str) -> String {
        format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use",{extra}"name":"Bash","input":{{"command":"same"}}}}]}}}}"#
        )
    }

    fn retained_after(setup: impl FnOnce(&mut SessionTranscript), line: &str) -> usize {
        let mut t = transcript_with_open_turn();
        setup(&mut t);
        let before = t.byte_len();
        t.ingest_line(line);
        t.byte_len() - before
    }

    #[test]
    fn identity_time_and_parentage_all_count_toward_retained_bytes() {
        let plain = retained_after(|_| {}, &call_line(""));
        let with_id = retained_after(|_| {}, &call_line(r#""id":"toolu_0123456789","#));
        assert!(with_id > plain, "tool_use_id must be counted: {with_id} vs {plain}");

        let live = retained_after(|t| t.set_live(true), &call_line(""));
        assert!(live > plain, "a stamped ts must be counted: {live} vs {plain}");

        let sidechain = retained_after(
            |_| {},
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"same"}}]},"parent_tool_use_id":"toolu_agent_long_id"}"#,
        );
        assert!(sidechain > plain, "parent id must be counted: {sidechain} vs {plain}");
    }

    #[test]
    fn a_target_counts_toward_retained_bytes() {
        let call = |target: Option<&str>| TurnBlock::ToolCall {
            tool_name: "Read".into(),
            input_summary: "a.rs".into(),
            input_full: "{}".into(),
            tool_use_id: None,
            target: target.map(str::to_string),
            ts: None,
            parent_tool_use_id: None,
        };
        assert!(block_bytes(&call(Some("/a/long/path/to/a.rs"))) > block_bytes(&call(None)));
    }

    #[test]
    fn retained_bytes_still_match_a_full_recount_with_the_new_fields_present() {
        let mut t = SessionTranscript::new();
        t.set_live(true);
        ingest_all(&mut t, SUBAGENT);
        ingest_all(&mut t, THINKING_BETWEEN_CALLS);
        ingest_all(&mut t, TOOL_SUCCESS);
        // Make sure the interesting fields really are on the wire here.
        let tagged = t.snapshot().iter().flat_map(|turn| turn.blocks.clone()).any(|b| {
            matches!(&b, TurnBlock::ToolCall { target: Some(_), ts: Some(_), parent_tool_use_id: Some(_), tool_use_id: Some(_), .. })
        });
        assert!(tagged);

        assert_eq!(t.byte_len(), recount_bytes(&t));
    }
}
