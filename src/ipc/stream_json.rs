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

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    TurnCompleted { turn_id: String, summary: ResultSummary },
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
    Blocks(Vec<TurnBlock>),
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
            let content = obj.get("message")?.get("content")?.as_array()?;
            let blocks: Vec<TurnBlock> = content
                .iter()
                .filter_map(parse_content_block)
                .flat_map(expand_confirm)
                .collect();
            if blocks.is_empty() {
                None
            } else {
                Some(ParsedLine::Blocks(blocks))
            }
        }

        "user" => parse_user_event(obj),

        "result" => Some(ParsedLine::Result(ResultSummary {
            duration_ms: obj.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
            cost_usd: obj
                .get("total_cost_usd")
                .and_then(|x| x.as_f64())
                .unwrap_or(0.0),
            is_error: obj.get("is_error").and_then(|x| x.as_bool()).unwrap_or(false),
        })),

        // rate_limit_event and any other type render nothing.
        _ => None,
    }
}

fn parse_user_event(obj: &serde_json::Map<String, Value>) -> Option<ParsedLine> {
    let content = obj.get("message")?.get("content")?;

    // Plain-string content → a human prompt (new turn).
    if let Some(s) = content.as_str() {
        let s = s.to_string();
        if s.trim().is_empty() {
            return None;
        }
        return Some(ParsedLine::UserPrompt {
            text: s,
            is_replay: obj.get("isReplay").and_then(|x| x.as_bool()).unwrap_or(false),
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
            Some(ParsedLine::Blocks(blocks))
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

    if text.is_empty() {
        return None;
    }
    Some(ParsedLine::UserPrompt {
        text,
        is_replay: obj.get("isReplay").and_then(|x| x.as_bool()).unwrap_or(false),
        timestamp: obj
            .get("timestamp")
            .and_then(|x| x.as_str())
            .map(str::to_string),
    })
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
            let input = b.get("input").cloned().unwrap_or(Value::Object(Default::default()));

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
            Some(TurnBlock::ToolResult { content: text, is_error })
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
        let trimmed = line.trim();
        if let Some(json_str) = trimmed.strip_prefix("CONFIRM:") {
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
/// Keys: `q` (question), `h` (header), `opts` (array of `{l, d}`).
fn parse_confirm_json(json: &Value) -> Option<TurnBlock> {
    let question = json.get("q").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let header = json.get("h").and_then(|x| x.as_str()).unwrap_or("").to_string();
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
                        description: opt.get("d").and_then(|x| x.as_str()).unwrap_or("").to_string(),
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

            ParsedLine::UserPrompt { text, timestamp, .. } => {
                // Flush any still-open turn (defensive; stored JSONL has no
                // `result` lines and delimits turns by the next user prompt).
                if let Some(last) = self.turns.last_mut() {
                    last.is_complete = true;
                }
                let id = self.alloc_id();
                let turn = Turn {
                    id,
                    user_input: text,
                    timestamp,
                    blocks: vec![],
                    is_complete: false,
                };
                self.turns.push(turn.clone());
                vec![TurnDelta::TurnStarted { turn }]
            }

            ParsedLine::Blocks(blocks) => {
                let mut deltas = Vec::with_capacity(blocks.len());
                if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    for b in blocks {
                        turn.blocks.push(b.clone());
                        deltas.push(TurnDelta::BlockAppended {
                            turn_id: turn_id.clone(),
                            block: b,
                        });
                    }
                }
                deltas
            }

            ParsedLine::Result(summary) => {
                if let Some(turn) = self.turns.last_mut() {
                    let turn_id = turn.id.clone();
                    turn.blocks.push(TurnBlock::ResultSummary {
                        duration_ms: summary.duration_ms,
                        cost_usd: summary.cost_usd,
                        is_error: summary.is_error,
                    });
                    turn.is_complete = true;
                    vec![TurnDelta::TurnCompleted { turn_id, summary }]
                } else {
                    vec![]
                }
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
        turn.blocks.push(TurnBlock::ErrorMessage {
            message: message.to_string(),
        });
        turn.is_complete = true;
        Some(TurnDelta::TurnErrored {
            turn_id: turn.id.clone(),
            message: message.to_string(),
        })
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
        if self.turns.len() > max_turns {
            let drop = self.turns.len() - max_turns;
            self.turns.drain(0..drop);
        }
    }
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
            Some(ParsedLine::Blocks(blocks)) => {
                assert_eq!(blocks, vec![TurnBlock::Text { text: "hello".into() }]);
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn drops_thinking_blocks_for_render_parity() {
        let line = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks(blocks)) => {
                assert_eq!(blocks, vec![TurnBlock::Text { text: "answer".into() }]);
            }
            other => panic!("expected Blocks, got {other:?}"),
        }
    }

    #[test]
    fn parses_tool_use_into_tool_call_with_summary() {
        let line = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"echo hi"}}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks(blocks)) => match &blocks[0] {
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
            Some(ParsedLine::Blocks(b)) => match &b[0] {
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
    fn parses_user_tool_result_array_as_blocks() {
        let line = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok","is_error":false,"tool_use_id":"t1"}]}}"#;
        match parse_line(line) {
            Some(ParsedLine::Blocks(b)) => assert_eq!(
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
            Some(ParsedLine::Blocks(b)) => match &b[0] {
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
            Some(ParsedLine::Blocks(b)) => {
                assert_eq!(b.len(), 3);
                assert_eq!(b[0], TurnBlock::Text { text: "before".into() });
                assert!(matches!(b[1], TurnBlock::AskQuestion { .. }));
                assert_eq!(b[2], TurnBlock::Text { text: "after".into() });
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
        assert!(blocks.iter().any(|b| matches!(b, TurnBlock::ToolCall { .. })));
        assert!(blocks
            .iter()
            .any(|b| matches!(b, TurnBlock::ToolResult { is_error: false, .. })));
        assert!(turns[0].is_complete);
    }

    #[test]
    fn replay_fixture_creates_turn_from_replayed_user_message() {
        let mut t = SessionTranscript::new();
        ingest_all(&mut t, REPLAY_BLOCKED);
        let turns = t.snapshot();
        assert_eq!(turns.len(), 1, "the isReplay user message opens the turn");
        assert!(turns[0].user_input.starts_with("Write a file named hello.txt"));
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
        let _ = t.ingest_line(
            r#"{"type":"user","message":{"content":"do a thing"},"isReplay":true}"#,
        );
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
            TurnBlock::ErrorMessage { message: "boom".into() },
            TurnBlock::AskQuestion {
                question: "q".into(),
                header: "h".into(),
                options: vec![AskOption {
                    label: "A".into(),
                    description: "d".into(),
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
}
