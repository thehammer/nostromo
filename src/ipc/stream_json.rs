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
    },
    ToolCall {
        tool_name: String,
        /// One-liner for the collapsed row.
        input_summary: String,
        /// Pretty JSON for possible expansion.
        input_full: String,
    },
    ToolResult {
        content: String,
        is_error: bool,
    },
    ResultSummary {
        duration_ms: u64,
        cost_usd: f64,
        is_error: bool,
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
    TurnErrored { turn_id: String, message: String },
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
    },
    /// Turn boundary.
    Result(ResultSummary),
}

/// Parse one NDJSON line from the stream-json output. Returns `None` for lines
/// we render nothing from (`rate_limit_event`, hook chatter, blank lines, …).
pub fn parse_line(line: &str) -> Option<ParsedLine> {
    let v: Value = serde_json::from_str(line.trim()).ok()?;
    let obj = v.as_object()?;

    match obj.get("type")?.as_str()? {
        "system" => obj
            .get("session_id")
            .and_then(|s| s.as_str())
            .map(|s| ParsedLine::SessionId(s.to_string())),

        "assistant" => {
            let msg = obj.get("message")?;
            let content = msg.get("content")?.as_array()?;
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
            if blocks.is_empty() && context_tokens.is_none() {
                None
            } else {
                Some(ParsedLine::Blocks {
                    blocks,
                    context_tokens,
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
        })),

        // rate_limit_event and any other type render nothing.
        _ => None,
    }
}

fn parse_user_event(obj: &serde_json::Map<String, Value>) -> Option<ParsedLine> {
    // Sub-agent prompts are emitted on the parent process's stdout as `user`
    // events tagged `isSidechain: true`. They are NOT human input — dropping
    // them here prevents a spurious cornflower user bubble / new turn. The
    // sub-agent's prompt is still visible via the parent's `Agent` tool_use
    // block (rendered expandable in the GUI).
    if obj.get("isSidechain").and_then(|x| x.as_bool()) == Some(true) {
        return None;
    }

    let content = obj.get("message")?.get("content")?;

    // Plain-string content → a human prompt (new turn), unless it's a
    // harness-injected notification (see is_harness_notification below).
    if let Some(s) = content.as_str() {
        let s = s.to_string();
        if s.trim().is_empty() || is_harness_notification(&s) {
            return None;
        }
        return Some(ParsedLine::UserPrompt {
            text: s,
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
    let all_tool_results = !arr.is_empty()
        && arr
            .iter()
            .all(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result"));

    if all_tool_results {
        let blocks: Vec<TurnBlock> = arr.iter().filter_map(parse_content_block).collect();
        return if blocks.is_empty() {
            None
        } else {
            Some(ParsedLine::Blocks {
                blocks,
                context_tokens: None,
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
        text,
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

/// Wrapper tags Claude Code's own harness injects as plain "user" events for
/// out-of-band signals — a completed background task (`<task-notification>`),
/// ambient context (`<system-reminder>`) — arriving on the wire in the exact
/// same shape as real human input. These are not something a human typed;
/// rendering one as a chat bubble reads as garbled human input (see the
/// isSidechain drop above for the same problem with sub-agent prompts).
/// Checked as a prefix after trimming leading whitespace/newlines, since the
/// harness sometimes leads with blank lines before the tag.
fn is_harness_notification(text: &str) -> bool {
    let trimmed = text.trim_start();
    trimmed.starts_with("<task-notification>") || trimmed.starts_with("<system-reminder>")
}

fn parse_content_block(b: &Value) -> Option<TurnBlock> {
    match b.get("type")?.as_str()? {
        "text" => {
            let t = b.get("text")?.as_str()?.trim().to_string();
            if t.is_empty() {
                None
            } else {
                Some(TurnBlock::Text { text: t })
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
            // Skip empty successful results — they're just ACKs.
            if text.is_empty() && !is_error {
                return None;
            }
            Some(TurnBlock::ToolResult {
                content: text,
                is_error,
            })
        }

        // thinking and any other block type are dropped (parity with Swift).
        _ => None,
    }
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
    let TurnBlock::Text { ref text } = block else {
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
                result.push(TurnBlock::Text { text: pre });
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
        result.push(TurnBlock::Text { text: tail });
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
}

impl SessionTranscript {
    pub fn new() -> Self {
        Self::default()
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

    /// Ingest one stream-json line, mutate the transcript, and return the
    /// deltas to broadcast (may be empty).
    pub fn ingest_line(&mut self, line: &str) -> Vec<TurnDelta> {
        let Some(parsed) = parse_line(line) else {
            return vec![];
        };
        match parsed {
            ParsedLine::SessionId(sid) => {
                if self.session_id.is_none() {
                    self.session_id = Some(sid);
                }
                vec![]
            }

            ParsedLine::UserPrompt {
                text, timestamp, ..
            } => {
                // Flush any still-open turn (defensive; stored JSONL has no
                // `result` lines and delimits turns by the next user prompt).
                if let Some(last) = self.turns.last_mut() {
                    last.is_complete = true;
                }
                if self.first_user_input.is_none() {
                    self.first_user_input = Some(text.clone());
                }
                let id = self.alloc_id();
                let turn = Turn {
                    id,
                    user_input: text,
                    timestamp,
                    blocks: vec![],
                    is_complete: false,
                };
                self.retained_bytes += turn_bytes(&turn);
                self.turns.push(turn.clone());
                let deltas = vec![TurnDelta::TurnStarted { turn }];
                self.enforce_limits();
                deltas
            }

            ParsedLine::Blocks {
                blocks,
                context_tokens,
            } => {
                if let Some(ct) = context_tokens {
                    self.last_context_tokens = Some(ct);
                }
                let mut deltas = Vec::with_capacity(blocks.len());
                if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    for b in blocks {
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
                let deltas = if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    let block = TurnBlock::ResultSummary {
                        duration_ms: summary.duration_ms,
                        cost_usd: summary.cost_usd,
                        is_error: summary.is_error,
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

/// Accounting weight of one block: fixed overhead plus its own String
/// payloads. Matches on every [`TurnBlock`] variant with no wildcard arm, so
/// adding a variant to the wire type is a compile error here rather than a
/// silently unmetered payload.
fn block_bytes(b: &TurnBlock) -> usize {
    let payload = match b {
        TurnBlock::Text { text } => text.len(),
        TurnBlock::ToolCall {
            tool_name,
            input_summary,
            input_full,
        } => tool_name.len() + input_summary.len() + input_full.len(),
        TurnBlock::ToolResult { content, .. } => content.len(),
        TurnBlock::ResultSummary { .. } => 0,
        TurnBlock::ErrorMessage { message } => message.len(),
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
                    vec![TurnBlock::Text {
                        text: "hello".into()
                    }]
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
                    vec![TurnBlock::Text {
                        text: "answer".into()
                    }]
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
                    is_error: false
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
            }))
        );
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
                    TurnBlock::Text {
                        text: "before".into()
                    }
                );
                assert!(matches!(b[1], TurnBlock::AskQuestion { .. }));
                assert_eq!(
                    b[2],
                    TurnBlock::Text {
                        text: "after".into()
                    }
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
                    TurnBlock::Text {
                        text: "before".into()
                    }
                );
                assert!(matches!(b[1], TurnBlock::AskQuestion { .. }));
                assert_eq!(
                    b[2],
                    TurnBlock::Text {
                        text: "after".into()
                    }
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
            TurnBlock::Text { text: "hi".into() },
            TurnBlock::ToolCall {
                tool_name: "Bash".into(),
                input_summary: "ls".into(),
                input_full: "{}".into(),
            },
            TurnBlock::ToolResult {
                content: "out".into(),
                is_error: false,
            },
            TurnBlock::ResultSummary {
                duration_ms: 10,
                cost_usd: 0.1,
                is_error: false,
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
        let json = serde_json::to_value(TurnBlock::Text { text: "x".into() }).unwrap();
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
                block: TurnBlock::Text { text: "a".into() },
            },
            TurnDelta::TurnCompleted {
                turn_id: "t0".into(),
                summary: ResultSummary {
                    duration_ms: 1,
                    cost_usd: 0.0,
                    is_error: false,
                },
                context_tokens: None,
            },
            TurnDelta::TurnErrored {
                turn_id: "t0".into(),
                message: "x".into(),
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
                        TurnBlock::Text { text } => text.len(),
                        TurnBlock::ToolCall {
                            tool_name,
                            input_summary,
                            input_full,
                        } => tool_name.len() + input_summary.len() + input_full.len(),
                        TurnBlock::ToolResult { content, .. } => content.len(),
                        TurnBlock::ResultSummary { .. } => 0,
                        TurnBlock::ErrorMessage { message } => message.len(),
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
}
