//! The background-task registry of one session.
//!
//! The Claude Code CLI reports its background work (shell commands, monitors,
//! subagents, workflows) as `system` events: `task_started`, `task_progress`,
//! `task_updated`, `task_notification` and `background_tasks_changed`. This
//! module parses them ([`parse_task_event`] → [`TaskEvent`]) and keeps what
//! the activity panel shows: [`TaskRegistry`] holds one [`TaskEntry`] per task
//! and builds the wire snapshots ([`TaskMeta`]); [`TaskHub`] adds the 250 ms
//! coalescing of what is published.
//!
//! Everything here is pure: time comes in as `now_ms` arguments and the
//! originating tool of a task is looked up through a caller-supplied closure,
//! so the rules are testable without a clock, a transcript or a process. The
//! daemon wiring lives in `session_manager::task_runtime`.
//!
//! Design: `.claude/plans/background-activity-panel-design-contract.md` §1.1,
//! §2.1–2.3.
//!
//! **Where text may go.** [`TaskMeta`] is a closed struct sent to network
//! peers for non-sensitive focuses, so it carries no output-derived or
//! conversation-derived free text beyond the task's own description. A
//! preview line, the agent's summaries and its prompt live in
//! [`TaskDetailMsg`], which is `LocalOnly` (see `peer.rs`).

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use super::protocol::{TaskDetailMsg, TaskEndReason, TaskKind, TaskMeta, TaskStatus};
use super::task_output::{sanitize, truncate_chars};

/// How long a background task may be missing from the CLI's live set before
/// it is declared gone.
pub const VANISH_GRACE_MS: u64 = 3_000;

/// Ended tasks kept per session, besides every task still running.
pub const RETAINED_ENDED_TASKS: usize = 40;

/// Snapshots and details are published at most once per this many ms.
pub const COALESCE_MS: u64 = 250;

/// Longest description carried in a snapshot.
const MAX_DESCRIPTION_CHARS: usize = 1_000;
/// Longest progress or completion summary carried in a detail.
const MAX_SUMMARY_CHARS: usize = 2_000;
/// Longest agent prompt carried in a detail.
const MAX_PROMPT_CHARS: usize = 16_000;

// ── parsed events ───────────────────────────────────────────────────────────

/// One of the five background-task events, with the session id the line carried.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskEvent {
    pub session_id: Option<String>,
    pub kind: TaskEventKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TaskEventKind {
    Started(TaskStarted),
    Progress(TaskProgress),
    Updated(TaskUpdated),
    Notification(TaskNotification),
    /// `background_tasks_changed`: the full live background set (REPLACE).
    LevelChanged(Vec<LevelTask>),
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TaskStarted {
    pub task_id: String,
    pub run_id: Option<String>,
    pub tool_use_id: Option<String>,
    pub description: String,
    pub subagent_type: Option<String>,
    pub task_type: Option<String>,
    pub workflow_name: Option<String>,
    pub parent_task_id: Option<String>,
    pub is_backgrounded: Option<bool>,
    pub prompt: Option<String>,
    pub skip_transcript: bool,
    pub ambient: bool,
}

/// The `usage` object of a progress or notification event. Absent fields stay
/// absent: a missing token count is never reported as 0.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TaskUsage {
    pub total_tokens: Option<u64>,
    pub tool_uses: Option<u64>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TaskProgress {
    pub task_id: String,
    pub run_id: Option<String>,
    pub tool_use_id: Option<String>,
    pub description: Option<String>,
    pub subagent_type: Option<String>,
    pub usage: Option<TaskUsage>,
    pub last_tool_name: Option<String>,
    pub summary: Option<String>,
}

/// The CLI's own task statuses, before mapping to [`TaskStatus`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawTaskStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Killed,
    Paused,
}

impl RawTaskStatus {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "pending" => Self::Pending,
            "running" => Self::Running,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            "killed" => Self::Killed,
            "paused" => Self::Paused,
            _ => return None,
        })
    }

    fn status(self) -> TaskStatus {
        match self {
            Self::Pending => TaskStatus::Pending,
            Self::Running => TaskStatus::Running,
            Self::Paused => TaskStatus::Paused,
            Self::Completed => TaskStatus::Completed,
            Self::Failed => TaskStatus::Failed,
            Self::Killed => TaskStatus::Stopped,
        }
    }
}

/// `task_updated.patch`: merge semantics, every field optional.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TaskPatch {
    pub status: Option<RawTaskStatus>,
    pub description: Option<String>,
    /// Epoch milliseconds.
    pub end_time: Option<u64>,
    pub is_backgrounded: Option<bool>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TaskUpdated {
    pub task_id: String,
    pub run_id: Option<String>,
    pub patch: TaskPatch,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TaskNotification {
    pub task_id: String,
    pub run_id: Option<String>,
    pub tool_use_id: Option<String>,
    pub status: TaskStatus,
    /// `worker_restart` and friends.
    pub reason: Option<String>,
    /// A path. Stays in the daemon: never on the wire.
    pub output_file: Option<String>,
    pub summary: Option<String>,
    pub usage: Option<TaskUsage>,
    pub skip_transcript: bool,
    pub ambient: bool,
}

/// One entry of `background_tasks_changed.tasks`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LevelTask {
    pub task_id: String,
    pub run_id: Option<String>,
    pub task_type: Option<String>,
    pub subagent_type: Option<String>,
    pub description: String,
    pub parent_task_id: Option<String>,
    pub ambient: bool,
}

/// Parse a `system` event of one of the five task subtypes. `None` for any
/// other subtype and for a malformed task event (no usable task id, a `tasks`
/// field that is not an array, an unknown notification status, …): the caller
/// then treats the line like any other `system` line.
pub fn parse_task_event(subtype: &str, obj: &Map<String, Value>) -> Option<TaskEvent> {
    let kind = match subtype {
        "task_started" => TaskEventKind::Started(parse_started(obj)?),
        "task_progress" => TaskEventKind::Progress(parse_progress(obj)?),
        "task_updated" => TaskEventKind::Updated(parse_updated(obj)?),
        "task_notification" => TaskEventKind::Notification(parse_notification(obj)?),
        "background_tasks_changed" => TaskEventKind::LevelChanged(parse_level(obj)?),
        _ => return None,
    };
    Some(TaskEvent {
        session_id: str_of(obj, "session_id"),
        kind,
    })
}

/// A non-empty string field.
fn str_of(obj: &Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// A string field, possibly empty (a description may be).
fn text_of(obj: &Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn flag_of(obj: &Map<String, Value>, key: &str) -> Option<bool> {
    obj.get(key).and_then(Value::as_bool)
}

fn task_id_of(obj: &Map<String, Value>) -> Option<String> {
    str_of(obj, "task_id")
}

fn parse_usage(obj: &Map<String, Value>) -> Option<TaskUsage> {
    let usage = obj.get("usage")?.as_object()?;
    let count = |k: &str| usage.get(k).and_then(Value::as_u64);
    Some(TaskUsage {
        total_tokens: count("total_tokens"),
        tool_uses: count("tool_uses"),
        duration_ms: count("duration_ms"),
    })
}

fn parse_started(obj: &Map<String, Value>) -> Option<TaskStarted> {
    Some(TaskStarted {
        task_id: task_id_of(obj)?,
        run_id: str_of(obj, "run_id"),
        tool_use_id: str_of(obj, "tool_use_id"),
        description: text_of(obj, "description").unwrap_or_default(),
        subagent_type: str_of(obj, "subagent_type"),
        task_type: str_of(obj, "task_type"),
        workflow_name: str_of(obj, "workflow_name"),
        parent_task_id: str_of(obj, "parent_task_id"),
        is_backgrounded: flag_of(obj, "is_backgrounded"),
        prompt: str_of(obj, "prompt"),
        skip_transcript: flag_of(obj, "skip_transcript").unwrap_or(false),
        ambient: flag_of(obj, "ambient").unwrap_or(false),
    })
}

fn parse_progress(obj: &Map<String, Value>) -> Option<TaskProgress> {
    Some(TaskProgress {
        task_id: task_id_of(obj)?,
        run_id: str_of(obj, "run_id"),
        tool_use_id: str_of(obj, "tool_use_id"),
        description: text_of(obj, "description"),
        subagent_type: str_of(obj, "subagent_type"),
        usage: parse_usage(obj),
        last_tool_name: str_of(obj, "last_tool_name"),
        summary: str_of(obj, "summary"),
    })
}

fn parse_updated(obj: &Map<String, Value>) -> Option<TaskUpdated> {
    let patch = obj.get("patch")?.as_object()?;
    Some(TaskUpdated {
        task_id: task_id_of(obj)?,
        run_id: str_of(obj, "run_id"),
        patch: TaskPatch {
            status: patch
                .get("status")
                .and_then(Value::as_str)
                .and_then(RawTaskStatus::parse),
            description: text_of(patch, "description"),
            end_time: patch.get("end_time").and_then(Value::as_u64),
            is_backgrounded: flag_of(patch, "is_backgrounded"),
        },
    })
}

fn parse_notification(obj: &Map<String, Value>) -> Option<TaskNotification> {
    let status = match obj.get("status").and_then(Value::as_str)? {
        "completed" => TaskStatus::Completed,
        "failed" => TaskStatus::Failed,
        "stopped" | "killed" => TaskStatus::Stopped,
        _ => return None,
    };
    Some(TaskNotification {
        task_id: task_id_of(obj)?,
        run_id: str_of(obj, "run_id"),
        tool_use_id: str_of(obj, "tool_use_id"),
        status,
        reason: str_of(obj, "reason"),
        output_file: str_of(obj, "output_file"),
        summary: str_of(obj, "summary"),
        usage: parse_usage(obj),
        skip_transcript: flag_of(obj, "skip_transcript").unwrap_or(false),
        ambient: flag_of(obj, "ambient").unwrap_or(false),
    })
}

fn parse_level(obj: &Map<String, Value>) -> Option<Vec<LevelTask>> {
    let tasks = obj.get("tasks")?.as_array()?;
    Some(
        tasks
            .iter()
            .filter_map(Value::as_object)
            .filter_map(|t| {
                Some(LevelTask {
                    task_id: task_id_of(t)?,
                    run_id: str_of(t, "run_id"),
                    task_type: str_of(t, "task_type"),
                    subagent_type: str_of(t, "subagent_type"),
                    description: text_of(t, "description").unwrap_or_default(),
                    parent_task_id: str_of(t, "parent_task_id"),
                    ambient: flag_of(t, "ambient").unwrap_or(false),
                })
            })
            .collect(),
    )
}

// ── kind resolution ─────────────────────────────────────────────────────────

/// What a task is, from the CLI's `task_type` and the tool that started it.
///
/// `local_bash` is both a background `Bash` and the `Monitor` tool, and the
/// CLI does not say which on the wire: the originating call's tool name
/// decides (`Monitor` → monitor, anything else, or unknown yet → shell).
pub fn resolve_kind(task_type: &str, tool_name: Option<&str>) -> TaskKind {
    match task_type {
        "local_bash" => {
            if tool_name == Some("Monitor") {
                TaskKind::Monitor
            } else {
                TaskKind::Shell
            }
        }
        "monitor_mcp" | "monitor_ws" => TaskKind::Monitor,
        "local_agent" => TaskKind::Agent,
        "local_workflow" => TaskKind::Workflow,
        _ => TaskKind::Other,
    }
}

/// `true` when the event or entry is housekeeping, not activity.
fn housekeeping_of(ambient: bool, skip_transcript: bool) -> bool {
    ambient || skip_transcript
}

// ── the registry ────────────────────────────────────────────────────────────

/// Looks up the name of the tool call a `tool_use_id` belongs to.
pub type ToolNameLookup<'a> = &'a dyn Fn(&str) -> Option<String>;

/// A registry entry; see the module docs. Never leaves the daemon as-is:
/// [`TaskMeta`] and [`TaskDetailMsg`] are its wire forms.
#[derive(Debug, Clone)]
struct TaskEntry {
    id: String,
    /// Arrival order of the task's first event.
    seq: u64,
    run_id: Option<String>,
    task_type: String,
    tool_use_id: Option<String>,
    /// The originating tool's name, once a lookup found it.
    tool_name: Option<String>,
    description: String,
    subagent_type: Option<String>,
    workflow_name: Option<String>,
    parent_task_id: Option<String>,
    is_backgrounded: Option<bool>,
    /// Listed in a `background_tasks_changed` level at some point.
    seen_in_level: bool,
    housekeeping: bool,
    status: TaskStatus,
    end_reason: Option<TaskEndReason>,
    started_at_ms: u64,
    ended_at_ms: Option<u64>,
    reported_duration_ms: Option<u64>,
    total_tokens: Option<u64>,
    tool_uses: Option<u64>,
    last_tool_name: Option<String>,
    /// From a `task_notification`. A path: never on the wire.
    output_file: Option<String>,
    /// Missing from the live level since; ends `vanished` at this time.
    vanish_at: Option<u64>,
    detail: TaskDetailMsg,
}

impl TaskEntry {
    fn new(id: &str, seq: u64, now: u64) -> Self {
        Self {
            id: id.to_owned(),
            seq,
            run_id: None,
            task_type: String::new(),
            tool_use_id: None,
            tool_name: None,
            description: String::new(),
            subagent_type: None,
            workflow_name: None,
            parent_task_id: None,
            is_backgrounded: None,
            seen_in_level: false,
            housekeeping: false,
            status: TaskStatus::Running,
            end_reason: None,
            started_at_ms: now,
            ended_at_ms: None,
            reported_duration_ms: None,
            total_tokens: None,
            tool_uses: None,
            last_tool_name: None,
            output_file: None,
            vanish_at: None,
            detail: TaskDetailMsg {
                task_id: id.to_owned(),
                ..Default::default()
            },
        }
    }

    fn in_background(&self) -> bool {
        self.seen_in_level || self.is_backgrounded == Some(true)
    }

    /// Remember the originating tool's name once a lookup finds it.
    fn resolve_tool_name(&mut self, lookup: ToolNameLookup<'_>) {
        self.tool_name = self.effective_tool_name(lookup);
    }

    /// The originating tool's name: the remembered one, else a fresh lookup
    /// (the call may have been seen only after the task was).
    fn effective_tool_name(&self, lookup: ToolNameLookup<'_>) -> Option<String> {
        self.tool_name
            .clone()
            .or_else(|| self.tool_use_id.as_deref().and_then(lookup))
    }

    fn kind(&self, lookup: ToolNameLookup<'_>) -> TaskKind {
        resolve_kind(&self.task_type, self.effective_tool_name(lookup).as_deref())
    }

    fn meta(&self, lookup: ToolNameLookup<'_>) -> TaskMeta {
        let tool_name = self.effective_tool_name(lookup);
        let kind = resolve_kind(&self.task_type, tool_name.as_deref());
        let duration_ms = self.reported_duration_ms.or_else(|| {
            self.ended_at_ms
                .map(|ended| ended.saturating_sub(self.started_at_ms))
        });
        TaskMeta {
            id: self.id.clone(),
            run_id: self.run_id.clone(),
            task_type: self.task_type.clone(),
            kind,
            tool_name,
            description: self.description.clone(),
            subagent_type: self.subagent_type.clone(),
            workflow_name: self.workflow_name.clone(),
            tool_use_id: self.tool_use_id.clone(),
            parent_task_id: self.parent_task_id.clone(),
            is_backgrounded: self.is_backgrounded,
            housekeeping: self.housekeeping,
            status: self.status,
            end_reason: self.end_reason,
            started_at_ms: Some(self.started_at_ms),
            ended_at_ms: self.ended_at_ms,
            duration_ms,
            total_tokens: self.total_tokens,
            tool_uses: self.tool_uses,
            last_tool_name: self.last_tool_name.clone(),
            has_output: kind.has_output(),
        }
    }

    /// Enter a terminal state; the first terminal state of a run wins.
    fn finish(&mut self, status: TaskStatus, ended_at: u64, end_reason: Option<TaskEndReason>) {
        if self.status.is_terminal() {
            return;
        }
        self.status = status;
        self.ended_at_ms = Some(ended_at);
        self.vanish_at = None;
        if status == TaskStatus::Stopped {
            self.end_reason = end_reason.or(self.end_reason);
        }
    }

    fn absorb_usage(&mut self, usage: Option<TaskUsage>) {
        if let Some(u) = usage {
            if u.total_tokens.is_some() {
                self.total_tokens = u.total_tokens;
            }
            if u.tool_uses.is_some() {
                self.tool_uses = u.tool_uses;
            }
            if u.duration_ms.is_some() {
                self.reported_duration_ms = u.duration_ms;
            }
        }
    }

    /// Start a new run: everything about the previous one is forgotten.
    fn reset_for_run(&mut self, run_id: Option<String>, now: u64) {
        let (id, seq) = (self.id.clone(), self.seq);
        *self = TaskEntry::new(&id, seq, now);
        self.run_id = run_id;
    }
}

/// What changed since the last [`TaskRegistry::take_dirty`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Dirty {
    /// The snapshot differs from the last one taken.
    pub snapshot: bool,
    /// Tasks whose detail text changed (or that are new with a detail).
    pub details: Vec<String>,
}

impl Dirty {
    pub fn is_clean(&self) -> bool {
        !self.snapshot && self.details.is_empty()
    }
}

/// A task the preview poller may read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewTarget {
    pub task_id: String,
    pub terminal: bool,
    /// The output path the CLI reported for the task, if it did.
    pub output_file: Option<String>,
    /// The tool call that started the task.
    pub tool_use_id: Option<String>,
    /// The preview already published, if any.
    pub preview: Option<String>,
}

/// The tasks of one session.
#[derive(Debug, Default)]
pub struct TaskRegistry {
    entries: HashMap<String, TaskEntry>,
    next_seq: u64,
    dirty_snapshot: bool,
    dirty_details: HashSet<String>,
}

impl TaskRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one parsed event received at `now` (epoch ms).
    ///
    /// A frame naming an older `run_id` than the one held is late and changes
    /// nothing; a newer run of the same task replaces the earlier one.
    pub fn apply(&mut self, event: &TaskEvent, now: u64, tool_name: ToolNameLookup<'_>) {
        let before_snapshot = self.snapshot(tool_name);
        let touched = event_task_id(&event.kind).map(str::to_owned);
        let before_detail = touched
            .as_ref()
            .and_then(|id| self.entries.get(id))
            .map(|e| e.detail.clone());

        match &event.kind {
            TaskEventKind::Started(e) => self.on_started(e, now),
            TaskEventKind::Progress(e) => self.on_progress(e, now),
            TaskEventKind::Updated(e) => self.on_updated(e, now),
            TaskEventKind::Notification(e) => self.on_notification(e, now),
            TaskEventKind::LevelChanged(level) => self.on_level(level, now),
        }
        if let Some(entry) = touched.as_ref().and_then(|id| self.entries.get_mut(id)) {
            entry.resolve_tool_name(tool_name);
        }
        self.retain();

        if let Some(id) = touched {
            let after = self.entries.get(&id).map(|e| e.detail.clone());
            if after.is_some() && after != before_detail {
                self.dirty_details.insert(id);
            }
        }
        if self.snapshot(tool_name) != before_snapshot {
            self.dirty_snapshot = true;
        }
    }

    /// End the tasks whose grace period ran out by `now`. Returns `true` when
    /// any task ended.
    pub fn tick(&mut self, now: u64) -> bool {
        let mut ended = false;
        for entry in self.entries.values_mut() {
            if entry.status.is_terminal() {
                continue;
            }
            if entry.vanish_at.is_some_and(|at| now >= at) {
                entry.finish(TaskStatus::Stopped, now, Some(TaskEndReason::Vanished));
                ended = true;
            }
        }
        if ended {
            self.retain();
            self.dirty_snapshot = true;
        }
        ended
    }

    /// The earliest time [`Self::tick`] will end a task.
    pub fn next_deadline(&self) -> Option<u64> {
        self.entries
            .values()
            .filter(|e| !e.status.is_terminal())
            .filter_map(|e| e.vanish_at)
            .min()
    }

    /// The CLI process ended: every task still running ended with it.
    pub fn end_session(&mut self, now: u64) {
        let mut ended = false;
        for entry in self.entries.values_mut() {
            if !entry.status.is_terminal() {
                entry.finish(TaskStatus::Stopped, now, Some(TaskEndReason::SessionEnded));
                ended = true;
            }
        }
        if ended {
            self.retain();
            self.dirty_snapshot = true;
        }
    }

    /// Record the latest output line of a task (`None` clears it). Returns
    /// `true` when the stored preview changed.
    pub fn set_preview(&mut self, task_id: &str, preview: Option<String>) -> bool {
        let Some(entry) = self.entries.get_mut(task_id) else {
            return false;
        };
        if entry.detail.preview == preview {
            return false;
        }
        entry.detail.preview = preview;
        self.dirty_details.insert(task_id.to_owned());
        true
    }

    /// Every task, in arrival order, as the wire shows it.
    pub fn snapshot(&self, tool_name: ToolNameLookup<'_>) -> Vec<TaskMeta> {
        let mut entries: Vec<&TaskEntry> = self.entries.values().collect();
        entries.sort_by_key(|e| e.seq);
        entries
            .into_iter()
            .map(|e| e.meta(tool_name))
            .collect()
    }

    /// The details of every retained task that has any text.
    pub fn details(&self) -> Vec<TaskDetailMsg> {
        let mut entries: Vec<&TaskEntry> = self.entries.values().collect();
        entries.sort_by_key(|e| e.seq);
        entries
            .into_iter()
            .map(|e| e.detail.clone())
            .filter(|d| !detail_is_empty(d))
            .collect()
    }

    /// The detail of one task, if it exists.
    pub fn detail(&self, task_id: &str) -> Option<TaskDetailMsg> {
        self.entries.get(task_id).map(|e| e.detail.clone())
    }

    /// Take (and clear) what changed since the last call.
    pub fn take_dirty(&mut self) -> Dirty {
        let mut details: Vec<String> = self
            .dirty_details
            .drain()
            .filter(|id| self.entries.contains_key(id))
            .collect();
        details.sort_by_key(|id| self.entries.get(id).map(|e| e.seq));
        Dirty {
            snapshot: std::mem::take(&mut self.dirty_snapshot),
            details,
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty_snapshot || !self.dirty_details.is_empty()
    }

    /// `true` while a shell or monitor task has not ended: the condition for
    /// polling previews.
    pub fn has_running_output_task(&self, tool_name: ToolNameLookup<'_>) -> bool {
        self.entries
            .values()
            .any(|e| !e.status.is_terminal() && e.kind(tool_name).has_output())
    }

    /// The shell and monitor tasks, running or ended, for the preview poller.
    pub fn preview_targets(&self, tool_name: ToolNameLookup<'_>) -> Vec<PreviewTarget> {
        let mut entries: Vec<&TaskEntry> = self.entries.values().collect();
        entries.sort_by_key(|e| e.seq);
        entries
            .into_iter()
            .filter(|e| e.kind(tool_name).has_output())
            .map(|e| PreviewTarget {
                task_id: e.id.clone(),
                terminal: e.status.is_terminal(),
                output_file: e.output_file.clone(),
                tool_use_id: e.tool_use_id.clone(),
                preview: e.detail.preview.clone(),
            })
            .collect()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    // ── event handlers ──────────────────────────────────────────────────────

    /// The entry a frame of `run_id` applies to: created if new, `None` when
    /// the frame is late (older run than the held one). A newer run resets the
    /// entry first.
    fn entry_for(&mut self, id: &str, run_id: Option<&str>, now: u64) -> Option<&mut TaskEntry> {
        if !self.entries.contains_key(id) {
            let seq = self.next_seq;
            self.next_seq += 1;
            let mut entry = TaskEntry::new(id, seq, now);
            entry.run_id = run_id.map(str::to_owned);
            self.entries.insert(id.to_owned(), entry);
        }
        let entry = self.entries.get_mut(id)?;
        let held = entry.run_id.clone();
        match (held.as_deref(), run_id) {
            (Some(held), Some(frame)) if frame < held => return None,
            (Some(held), Some(frame)) if frame > held => {
                entry.reset_for_run(Some(frame.to_owned()), now);
            }
            (None, Some(frame)) => entry.run_id = Some(frame.to_owned()),
            _ => {}
        }
        Some(entry)
    }

    fn on_started(&mut self, e: &TaskStarted, now: u64) {
        let Some(entry) = self.entry_for(&e.task_id, e.run_id.as_deref(), now) else {
            return;
        };
        if let Some(t) = &e.task_type {
            entry.task_type = t.clone();
        }
        if e.tool_use_id.is_some() {
            entry.tool_use_id = e.tool_use_id.clone();
        }
        entry.description = clean_description(&e.description);
        entry.subagent_type = e.subagent_type.clone().or(entry.subagent_type.take());
        entry.workflow_name = e.workflow_name.clone().or(entry.workflow_name.take());
        entry.parent_task_id = e.parent_task_id.clone().or(entry.parent_task_id.take());
        if e.is_backgrounded.is_some() {
            entry.is_backgrounded = e.is_backgrounded;
        }
        entry.housekeeping |= housekeeping_of(e.ambient, e.skip_transcript);
        if let Some(prompt) = &e.prompt {
            entry.detail.prompt = clean_text(prompt, MAX_PROMPT_CHARS);
        }
    }

    fn on_progress(&mut self, e: &TaskProgress, now: u64) {
        let Some(entry) = self.entry_for(&e.task_id, e.run_id.as_deref(), now) else {
            return;
        };
        if entry.status.is_terminal() {
            return;
        }
        if let Some(d) = &e.description {
            entry.description = clean_description(d);
        }
        if e.tool_use_id.is_some() && entry.tool_use_id.is_none() {
            entry.tool_use_id = e.tool_use_id.clone();
        }
        if e.subagent_type.is_some() {
            entry.subagent_type = e.subagent_type.clone();
        }
        if e.last_tool_name.is_some() {
            entry.last_tool_name = e.last_tool_name.clone();
        }
        entry.absorb_usage(e.usage);
        if let Some(summary) = &e.summary {
            entry.detail.progress_summary = clean_text(summary, MAX_SUMMARY_CHARS);
        }
    }

    fn on_updated(&mut self, e: &TaskUpdated, now: u64) {
        let Some(entry) = self.entry_for(&e.task_id, e.run_id.as_deref(), now) else {
            return;
        };
        let patch = &e.patch;
        if let Some(d) = &patch.description {
            entry.description = clean_description(d);
        }
        if patch.is_backgrounded.is_some() {
            entry.is_backgrounded = patch.is_backgrounded;
        }
        let Some(status) = patch.status.map(RawTaskStatus::status) else {
            return;
        };
        if status.is_terminal() {
            entry.finish(status, patch.end_time.unwrap_or(now), None);
        } else if !entry.status.is_terminal() {
            entry.status = status;
        }
    }

    fn on_notification(&mut self, e: &TaskNotification, now: u64) {
        let Some(entry) = self.entry_for(&e.task_id, e.run_id.as_deref(), now) else {
            return;
        };
        if e.tool_use_id.is_some() && entry.tool_use_id.is_none() {
            entry.tool_use_id = e.tool_use_id.clone();
        }
        entry.housekeeping |= housekeeping_of(e.ambient, e.skip_transcript);
        if e.output_file.is_some() {
            entry.output_file = e.output_file.clone();
        }
        if let Some(summary) = &e.summary {
            entry.detail.completion_summary = clean_text(summary, MAX_SUMMARY_CHARS);
        }
        entry.absorb_usage(e.usage);
        let reason = (e.reason.as_deref() == Some("worker_restart")).then_some(TaskEndReason::Restart);
        entry.finish(e.status, now, reason);
        // A restart notification that follows an earlier `stopped` still
        // says why.
        if reason.is_some() && entry.status == TaskStatus::Stopped && entry.end_reason.is_none() {
            entry.end_reason = reason;
        }
    }

    fn on_level(&mut self, level: &[LevelTask], now: u64) {
        let in_level: HashSet<&str> = level.iter().map(|t| t.task_id.as_str()).collect();
        for t in level {
            let Some(entry) = self.entry_for(&t.task_id, t.run_id.as_deref(), now) else {
                continue;
            };
            entry.seen_in_level = true;
            entry.vanish_at = None;
            if entry.task_type.is_empty() {
                if let Some(task_type) = &t.task_type {
                    entry.task_type = task_type.clone();
                }
            }
            if entry.description.is_empty() {
                entry.description = clean_description(&t.description);
            }
            entry.subagent_type = entry.subagent_type.take().or_else(|| t.subagent_type.clone());
            entry.parent_task_id = entry.parent_task_id.take().or_else(|| t.parent_task_id.clone());
            entry.housekeeping |= t.ambient;
        }
        for entry in self.entries.values_mut() {
            if !entry.status.is_terminal()
                && entry.in_background()
                && !in_level.contains(entry.id.as_str())
                && entry.vanish_at.is_none()
            {
                entry.vanish_at = Some(now + VANISH_GRACE_MS);
            }
        }
    }

    /// Keep every running task and the [`RETAINED_ENDED_TASKS`] most recently
    /// ended; drop the rest with their details.
    fn retain(&mut self) {
        let mut ended: Vec<(u64, u64, String)> = self
            .entries
            .values()
            .filter(|e| e.status.is_terminal())
            .map(|e| (e.ended_at_ms.unwrap_or(e.started_at_ms), e.seq, e.id.clone()))
            .collect();
        if ended.len() <= RETAINED_ENDED_TASKS {
            return;
        }
        ended.sort_by(|a, b| (b.0, b.1).cmp(&(a.0, a.1)));
        for (_, _, id) in ended.into_iter().skip(RETAINED_ENDED_TASKS) {
            self.entries.remove(&id);
            self.dirty_details.remove(&id);
        }
    }
}

fn event_task_id(kind: &TaskEventKind) -> Option<&str> {
    match kind {
        TaskEventKind::Started(e) => Some(&e.task_id),
        TaskEventKind::Progress(e) => Some(&e.task_id),
        TaskEventKind::Updated(e) => Some(&e.task_id),
        TaskEventKind::Notification(e) => Some(&e.task_id),
        TaskEventKind::LevelChanged(_) => None,
    }
}

/// `true` when a detail carries no text.
pub fn detail_is_empty(d: &TaskDetailMsg) -> bool {
    d.preview.is_none()
        && d.progress_summary.is_none()
        && d.completion_summary.is_none()
        && d.prompt.is_none()
}

fn clean_description(s: &str) -> String {
    truncate_chars(&sanitize(s.as_bytes()), MAX_DESCRIPTION_CHARS)
}

/// Free text for a detail: escapes removed, trimmed, capped; `None` if empty.
fn clean_text(s: &str, max_chars: usize) -> Option<String> {
    let clean = sanitize(s.as_bytes());
    let clean = clean.trim();
    (!clean.is_empty()).then(|| truncate_chars(clean, max_chars))
}

// ── coalescing ──────────────────────────────────────────────────────────────

/// What a [`TaskHub`] hands to be published.
#[derive(Debug, Clone, PartialEq)]
pub enum TaskOutput {
    /// The full list of tasks (REPLACE).
    Snapshot(Vec<TaskMeta>),
    Detail(TaskDetailMsg),
}

/// A [`TaskRegistry`] plus the publication schedule: at most one publication
/// per [`COALESCE_MS`], and the first change after a quiet period goes out at
/// once. A change inside the window waits for it to end
/// ([`TaskHub::next_wakeup`] says when).
#[derive(Debug, Default)]
pub struct TaskHub {
    registry: TaskRegistry,
    last_publish_ms: Option<u64>,
}

impl TaskHub {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn registry(&self) -> &TaskRegistry {
        &self.registry
    }

    pub fn on_event(
        &mut self,
        event: &TaskEvent,
        now: u64,
        tool_name: ToolNameLookup<'_>,
    ) -> Vec<TaskOutput> {
        self.registry.apply(event, now, tool_name);
        self.publish_if_due(now, tool_name)
    }

    /// Time has passed: end vanished tasks, publish what is due.
    pub fn on_tick(&mut self, now: u64, tool_name: ToolNameLookup<'_>) -> Vec<TaskOutput> {
        self.registry.tick(now);
        self.publish_if_due(now, tool_name)
    }

    /// A preview line was read for `task_id`.
    pub fn set_preview(
        &mut self,
        task_id: &str,
        preview: Option<String>,
        now: u64,
        tool_name: ToolNameLookup<'_>,
    ) -> Vec<TaskOutput> {
        self.registry.set_preview(task_id, preview);
        self.publish_if_due(now, tool_name)
    }

    /// The CLI process ended: end its tasks and publish at once, window or not.
    pub fn end_session(&mut self, now: u64, tool_name: ToolNameLookup<'_>) -> Vec<TaskOutput> {
        self.registry.end_session(now);
        self.publish(now, tool_name)
    }

    /// The earliest time something is due: a coalesced publication or a
    /// vanish deadline.
    pub fn next_wakeup(&self) -> Option<u64> {
        let publish = self
            .registry
            .is_dirty()
            .then(|| self.last_publish_ms.map_or(0, |t| t + COALESCE_MS));
        match (publish, self.registry.next_deadline()) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// The current snapshot and every detail, for a client that attaches or
    /// whose forwarder lagged. Does not touch the publication schedule.
    pub fn current(&self, tool_name: ToolNameLookup<'_>) -> (Vec<TaskMeta>, Vec<TaskDetailMsg>) {
        (self.registry.snapshot(tool_name), self.registry.details())
    }

    fn publish_if_due(&mut self, now: u64, tool_name: ToolNameLookup<'_>) -> Vec<TaskOutput> {
        let due = self.registry.is_dirty()
            && self
                .last_publish_ms
                .is_none_or(|last| now >= last.saturating_add(COALESCE_MS));
        if due {
            self.publish(now, tool_name)
        } else {
            Vec::new()
        }
    }

    fn publish(&mut self, now: u64, tool_name: ToolNameLookup<'_>) -> Vec<TaskOutput> {
        let dirty = self.registry.take_dirty();
        if dirty.is_clean() {
            return Vec::new();
        }
        self.last_publish_ms = Some(now);
        let mut out = Vec::with_capacity(1 + dirty.details.len());
        if dirty.snapshot {
            out.push(TaskOutput::Snapshot(self.registry.snapshot(tool_name)));
        }
        out.extend(
            dirty
                .details
                .iter()
                .filter_map(|id| self.registry.detail(id))
                .map(TaskOutput::Detail),
        );
        out
    }
}
