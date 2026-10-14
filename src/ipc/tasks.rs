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

    /// Start a new run: what the previous run did is forgotten (state, times,
    /// usage, text, output file). What the task *is* stays, so a newer run
    /// announced by a notification alone still has its label and kind.
    fn reset_for_run(&mut self, run_id: Option<String>, now: u64) {
        let mut fresh = TaskEntry::new(&self.id, self.seq, now);
        fresh.run_id = run_id;
        fresh.task_type = std::mem::take(&mut self.task_type);
        fresh.tool_use_id = self.tool_use_id.take();
        fresh.tool_name = self.tool_name.take();
        fresh.description = std::mem::take(&mut self.description);
        fresh.subagent_type = self.subagent_type.take();
        fresh.workflow_name = self.workflow_name.take();
        fresh.parent_task_id = self.parent_task_id.take();
        fresh.is_backgrounded = self.is_backgrounded;
        fresh.housekeeping = self.housekeeping;
        *self = fresh;
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
    /// Not activity (an ambient watcher): its output is not worth reading.
    pub housekeeping: bool,
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
            // A detail is published when it has text, or when it lost the
            // text a client holds (a new run); a task with nothing to say
            // announces no detail at all.
            let publish_detail = self.entries.get(&id).is_some_and(|e| {
                let had_text = before_detail.as_ref().is_some_and(|d| !detail_is_empty(d));
                before_detail.as_ref() != Some(&e.detail)
                    && (had_text || !detail_is_empty(&e.detail))
            });
            if publish_detail {
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

    fn entries_in_order(&self) -> Vec<&TaskEntry> {
        let mut entries: Vec<&TaskEntry> = self.entries.values().collect();
        entries.sort_by_key(|e| e.seq);
        entries
    }

    /// Every task, in arrival order, as the wire shows it.
    pub fn snapshot(&self, tool_name: ToolNameLookup<'_>) -> Vec<TaskMeta> {
        self.entries_in_order()
            .into_iter()
            .map(|e| e.meta(tool_name))
            .collect()
    }

    /// The details of every retained task that has any text.
    pub fn details(&self) -> Vec<TaskDetailMsg> {
        self.entries_in_order()
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
        self.entries_in_order()
            .into_iter()
            .filter(|e| e.kind(tool_name).has_output())
            .map(|e| PreviewTarget {
                task_id: e.id.clone(),
                terminal: e.status.is_terminal(),
                housekeeping: e.housekeeping,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;

    // ── builders: events as the CLI sends them ──────────────────────────────

    /// `{"task_id": id, ...extra}` as the object a `system` line carries.
    fn body(id: &str, extra: Value) -> Map<String, Value> {
        let mut obj = Map::new();
        obj.insert("task_id".into(), json!(id));
        if let Value::Object(extra) = extra {
            obj.extend(extra);
        }
        obj
    }

    fn parsed(subtype: &str, obj: Map<String, Value>) -> TaskEvent {
        parse_task_event(subtype, &obj).unwrap_or_else(|| panic!("{subtype} did not parse: {obj:?}"))
    }

    fn started(id: &str, extra: Value) -> TaskEvent {
        let mut obj = body(id, extra);
        obj.entry("description").or_insert(json!("a task"));
        parsed("task_started", obj)
    }

    fn progress(id: &str, extra: Value) -> TaskEvent {
        parsed("task_progress", body(id, extra))
    }

    fn updated(id: &str, patch: Value) -> TaskEvent {
        parsed("task_updated", body(id, json!({ "patch": patch })))
    }

    fn updated_run(id: &str, run: &str, patch: Value) -> TaskEvent {
        parsed("task_updated", body(id, json!({ "run_id": run, "patch": patch })))
    }

    fn notified(id: &str, status: &str, extra: Value) -> TaskEvent {
        let mut obj = body(id, extra);
        obj.insert("status".into(), json!(status));
        parsed("task_notification", obj)
    }

    fn level(tasks: Value) -> TaskEvent {
        let mut obj = Map::new();
        obj.insert("tasks".into(), tasks);
        parsed("background_tasks_changed", obj)
    }

    fn in_level(ids: &[&str]) -> TaskEvent {
        level(Value::Array(
            ids.iter()
                .map(|id| json!({ "task_id": id, "task_type": "local_bash", "description": "d" }))
                .collect(),
        ))
    }

    fn no_tools(_: &str) -> Option<String> {
        None
    }

    /// A tool-name index the test can fill in as it goes.
    #[derive(Default)]
    struct Tools(RefCell<std::collections::HashMap<String, String>>);

    impl Tools {
        fn learn(&self, id: &str, name: &str) {
            self.0.borrow_mut().insert(id.to_owned(), name.to_owned());
        }

        fn lookup(&self) -> impl Fn(&str) -> Option<String> + '_ {
            move |id| self.0.borrow().get(id).cloned()
        }
    }

    fn snap(reg: &TaskRegistry) -> Vec<TaskMeta> {
        reg.snapshot(&no_tools)
    }

    fn one(reg: &TaskRegistry, id: &str) -> TaskMeta {
        snap(reg)
            .into_iter()
            .find(|t| t.id == id)
            .unwrap_or_else(|| panic!("no task {id} in {:?}", snap(reg)))
    }

    fn registry_with(events: &[(&TaskEvent, u64)]) -> TaskRegistry {
        let mut reg = TaskRegistry::new();
        for (event, now) in events {
            reg.apply(event, *now, &no_tools);
        }
        reg
    }

    // ── kind resolution ─────────────────────────────────────────────────────

    #[test]
    fn a_tasks_kind_comes_from_its_type_and_the_tool_that_started_it() {
        let tools = Tools::default();
        tools.learn("toolu_mon", "Monitor");
        tools.learn("toolu_bash", "Bash");
        tools.learn("toolu_agent", "Agent");
        let lookup = tools.lookup();

        // (task_type, originating tool call, kind, has output)
        let table: &[(Option<&str>, Option<&str>, TaskKind, bool)] = &[
            (Some("local_bash"), Some("toolu_mon"), TaskKind::Monitor, true),
            (Some("local_bash"), Some("toolu_bash"), TaskKind::Shell, true),
            (Some("local_bash"), None, TaskKind::Shell, true),
            (Some("local_bash"), Some("toolu_not_seen"), TaskKind::Shell, true),
            (Some("monitor_mcp"), None, TaskKind::Monitor, true),
            (Some("monitor_mcp"), Some("toolu_bash"), TaskKind::Monitor, true),
            (Some("monitor_ws"), None, TaskKind::Monitor, true),
            (Some("local_agent"), Some("toolu_agent"), TaskKind::Agent, false),
            (Some("local_agent"), None, TaskKind::Agent, false),
            (Some("local_workflow"), None, TaskKind::Workflow, false),
            (Some("remote_agent"), None, TaskKind::Other, false),
            (Some("mcp_task"), None, TaskKind::Other, false),
            (Some("in_process_teammate"), None, TaskKind::Other, false),
            (Some("quantum_task"), None, TaskKind::Other, false),
            (None, None, TaskKind::Other, false),
        ];
        for (task_type, tool_use_id, kind, has_output) in table {
            let mut extra = json!({});
            if let Some(t) = task_type {
                extra["task_type"] = json!(t);
            }
            if let Some(u) = tool_use_id {
                extra["tool_use_id"] = json!(u);
            }
            let mut reg = TaskRegistry::new();
            reg.apply(&started("t1", extra), 1_000, &lookup);

            let meta = &reg.snapshot(&lookup)[0];

            assert_eq!(meta.kind, *kind, "{task_type:?} via {tool_use_id:?}");
            assert_eq!(meta.has_output, *has_output, "{task_type:?} via {tool_use_id:?}");
            assert_eq!(meta.task_type, task_type.unwrap_or(""), "the raw type is kept as the CLI sent it");
        }
    }

    #[test]
    fn a_monitor_call_and_a_bash_call_are_told_apart_by_the_tool_name_in_the_snapshot() {
        let tools = Tools::default();
        tools.learn("toolu_mon", "Monitor");
        tools.learn("toolu_bash", "Bash");
        let lookup = tools.lookup();
        let mut reg = TaskRegistry::new();
        reg.apply(&started("m", json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"})), 1, &lookup);
        reg.apply(&started("b", json!({"task_type": "local_bash", "tool_use_id": "toolu_bash"})), 2, &lookup);

        let snapshot = reg.snapshot(&lookup);

        assert_eq!((snapshot[0].kind, snapshot[0].tool_name.as_deref()), (TaskKind::Monitor, Some("Monitor")));
        assert_eq!((snapshot[1].kind, snapshot[1].tool_name.as_deref()), (TaskKind::Shell, Some("Bash")));
    }

    #[test]
    fn a_task_started_before_its_tool_call_is_known_is_a_shell_and_becomes_a_monitor_on_the_next_snapshot() {
        let tools = Tools::default();
        let lookup = tools.lookup();
        let mut reg = TaskRegistry::new();
        reg.apply(
            &started("t1", json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"})),
            1_000,
            &lookup,
        );
        assert_eq!(reg.snapshot(&lookup)[0].kind, TaskKind::Shell, "the call has not been seen yet");

        tools.learn("toolu_mon", "Monitor");

        let after = &reg.snapshot(&lookup)[0];
        assert_eq!(after.kind, TaskKind::Monitor);
        assert_eq!(after.tool_name.as_deref(), Some("Monitor"));
        assert!(after.has_output);
    }

    #[test]
    fn a_resolved_kind_survives_the_tool_call_leaving_the_transcript() {
        let tools = Tools::default();
        tools.learn("toolu_mon", "Monitor");
        let mut reg = TaskRegistry::new();
        reg.apply(
            &started("t1", json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"})),
            1_000,
            &tools.lookup(),
        );

        // The retained turns moved on: the index forgot the call.
        tools.0.borrow_mut().clear();
        reg.apply(&progress("t1", json!({"description": "still watching"})), 2_000, &tools.lookup());

        assert_eq!(reg.snapshot(&tools.lookup())[0].kind, TaskKind::Monitor);
    }

    #[test]
    fn a_level_that_creates_a_task_before_its_start_event_gives_it_its_type() {
        let mut reg = TaskRegistry::new();
        reg.apply(&in_level(&["t1"]), 1_000, &no_tools);
        assert_eq!(one(&reg, "t1").task_type, "local_bash");
        assert_eq!(one(&reg, "t1").status, TaskStatus::Running);

        reg.apply(&started("t1", json!({"description": "Run it", "tool_use_id": "toolu_x"})), 1_100, &no_tools);

        assert_eq!(reg.len(), 1, "one task, not two");
        let t = one(&reg, "t1");
        assert_eq!((t.description.as_str(), t.task_type.as_str()), ("Run it", "local_bash"));
        assert_eq!(t.started_at_ms, Some(1_000), "the first event it saw");
    }

    // ── housekeeping ────────────────────────────────────────────────────────

    #[test]
    fn ambient_or_skip_transcript_makes_a_task_housekeeping() {
        let table = [
            (json!({}), false),
            (json!({"ambient": false, "skip_transcript": false}), false),
            (json!({"ambient": true}), true),
            (json!({"skip_transcript": true}), true),
            (json!({"ambient": true, "skip_transcript": true}), true),
            (json!({"ambient": false, "skip_transcript": true}), true),
        ];
        for (extra, expected) in table {
            let mut extra = extra;
            extra["task_type"] = json!("local_bash");
            let reg = registry_with(&[(&started("t1", extra.clone()), 1)]);
            assert_eq!(one(&reg, "t1").housekeeping, expected, "{extra}");
        }
    }

    #[test]
    fn a_notification_or_level_that_calls_the_task_ambient_makes_it_housekeeping() {
        let reg = registry_with(&[
            (&started("n", json!({})), 1),
            (&notified("n", "completed", json!({"ambient": true})), 2),
            (&started("s", json!({})), 3),
            (&notified("s", "completed", json!({"skip_transcript": true})), 4),
            (&started("l", json!({})), 5),
            (&level(json!([{"task_id": "l", "task_type": "monitor_ws", "description": "d", "ambient": true}])), 6),
        ]);
        assert!(one(&reg, "n").housekeeping);
        assert!(one(&reg, "s").housekeeping);
        assert!(one(&reg, "l").housekeeping);
    }

    #[test]
    fn an_ordinary_monitor_is_not_housekeeping() {
        let tools = Tools::default();
        tools.learn("toolu_mon", "Monitor");
        let mut reg = TaskRegistry::new();
        reg.apply(
            &started("m", json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"})),
            1,
            &tools.lookup(),
        );
        assert!(!reg.snapshot(&tools.lookup())[0].housekeeping);
    }

    // ── status and end reasons ──────────────────────────────────────────────

    #[test]
    fn the_clis_task_statuses_map_onto_the_wire_statuses() {
        let table = [
            ("pending", TaskStatus::Pending),
            ("running", TaskStatus::Running),
            ("paused", TaskStatus::Paused),
            ("completed", TaskStatus::Completed),
            ("failed", TaskStatus::Failed),
            ("killed", TaskStatus::Stopped),
        ];
        for (raw, expected) in table {
            let reg = registry_with(&[
                (&started("t1", json!({})), 1_000),
                (&updated("t1", json!({ "status": raw })), 2_000),
            ]);
            assert_eq!(one(&reg, "t1").status, expected, "patch status {raw}");
        }
    }

    #[test]
    fn a_new_task_is_running_until_told_otherwise() {
        let reg = registry_with(&[(&started("t1", json!({})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!(t.status, TaskStatus::Running);
        assert_eq!((t.ended_at_ms, t.end_reason, t.duration_ms), (None, None, None));
    }

    #[test]
    fn a_notification_status_maps_onto_the_wire_status() {
        for (raw, expected) in [
            ("completed", TaskStatus::Completed),
            ("failed", TaskStatus::Failed),
            ("stopped", TaskStatus::Stopped),
        ] {
            let reg = registry_with(&[
                (&started("t1", json!({})), 1_000),
                (&notified("t1", raw, json!({})), 2_000),
            ]);
            assert_eq!(one(&reg, "t1").status, expected, "{raw}");
            assert_eq!(one(&reg, "t1").end_reason, None, "no reason given, none invented: {raw}");
        }
    }

    #[test]
    fn a_worker_restart_notification_ends_the_task_stopped_with_the_restart_reason() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&notified("t1", "stopped", json!({"reason": "worker_restart"})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.end_reason), (TaskStatus::Stopped, Some(TaskEndReason::Restart)));
    }

    #[test]
    fn a_restart_notification_after_a_killed_patch_still_says_why() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&updated("t1", json!({"status": "killed"})), 2_000),
            (&notified("t1", "stopped", json!({"reason": "worker_restart"})), 2_100),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.end_reason), (TaskStatus::Stopped, Some(TaskEndReason::Restart)));
    }

    #[test]
    fn any_other_reason_gives_no_end_reason() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&notified("t1", "stopped", json!({"reason": "something_new"})), 2_000),
        ]);
        assert_eq!(one(&reg, "t1").end_reason, None);
    }

    #[test]
    fn an_ended_task_stays_ended_within_its_run() {
        let reg = registry_with(&[
            (&started("t1", json!({"run_id": "run-001"})), 1_000),
            (&notified("t1", "completed", json!({"run_id": "run-001"})), 2_000),
            (&updated_run("t1", "run-001", json!({"status": "running"})), 3_000),
            (&progress("t1", json!({"run_id": "run-001", "usage": {"total_tokens": 9}})), 3_100),
        ]);
        let t = one(&reg, "t1");
        assert_eq!(t.status, TaskStatus::Completed);
        assert_eq!(t.ended_at_ms, Some(2_000));
    }

    #[test]
    fn an_unrecognised_patch_status_changes_nothing() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&updated("t1", json!({"status": "weird", "end_time": "yesterday"})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.ended_at_ms), (TaskStatus::Running, None));
    }

    #[test]
    fn a_patch_merges_description_and_backgrounded_without_ending_the_task() {
        let reg = registry_with(&[
            (&started("t1", json!({"description": "before", "is_backgrounded": false})), 1_000),
            (&updated("t1", json!({"description": "after", "is_backgrounded": true})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!(t.description, "after");
        assert_eq!(t.is_backgrounded, Some(true));
        assert_eq!(t.status, TaskStatus::Running);
    }

    #[test]
    fn tasks_are_listed_in_the_order_they_first_appeared() {
        let reg = registry_with(&[
            (&started("c", json!({})), 1),
            (&started("a", json!({})), 2),
            (&started("b", json!({})), 3),
            (&progress("c", json!({"description": "again"})), 4),
        ]);
        let ids: Vec<String> = snap(&reg).into_iter().map(|t| t.id).collect();
        assert_eq!(ids, ["c", "a", "b"]);
    }

    #[test]
    fn started_carries_the_descriptive_fields_into_the_snapshot() {
        let reg = registry_with(&[(
            &started(
                "t1",
                json!({
                    "task_type": "local_workflow", "workflow_name": "release-checks",
                    "subagent_type": "Explore", "parent_task_id": "p1", "tool_use_id": "toolu_1",
                    "description": "Release checks", "is_backgrounded": true, "run_id": "run-001",
                }),
            ),
            1_000,
        )]);
        let t = one(&reg, "t1");
        assert_eq!(t.description, "Release checks");
        assert_eq!(t.workflow_name.as_deref(), Some("release-checks"));
        assert_eq!(t.subagent_type.as_deref(), Some("Explore"));
        assert_eq!(t.parent_task_id.as_deref(), Some("p1"));
        assert_eq!(t.tool_use_id.as_deref(), Some("toolu_1"));
        assert_eq!(t.is_backgrounded, Some(true));
        assert_eq!(t.run_id.as_deref(), Some("run-001"));
    }

    #[test]
    fn progress_updates_the_live_description_and_the_last_tool() {
        let reg = registry_with(&[
            (&started("t1", json!({"task_type": "local_agent", "description": "Survey"})), 1_000),
            (&progress("t1", json!({"description": "Reading files", "last_tool_name": "Read"})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!(t.description, "Reading files");
        assert_eq!(t.last_tool_name.as_deref(), Some("Read"));
    }

    // ── run ids ─────────────────────────────────────────────────────────────

    #[test]
    fn a_frame_from_an_older_run_changes_nothing_and_marks_nothing_dirty() {
        let mut reg = registry_with(&[(
            &started("t1", json!({"run_id": "run-002", "description": "current run"})),
            1_000,
        )]);
        reg.take_dirty();
        let before = snap(&reg);
        let details_before = reg.details();

        let late = [
            progress("t1", json!({"run_id": "run-001", "description": "stale", "usage": {"total_tokens": 99}, "summary": "stale summary"})),
            updated_run("t1", "run-001", json!({"status": "completed", "end_time": 1_500, "description": "stale"})),
            notified("t1", "failed", json!({"run_id": "run-001", "summary": "stale", "ambient": true})),
            started("t1", json!({"run_id": "run-001", "description": "stale start", "prompt": "stale prompt"})),
            level(json!([{"task_id": "t1", "run_id": "run-001", "task_type": "monitor_ws", "description": "stale", "ambient": true}])),
        ];
        for (i, event) in late.iter().enumerate() {
            reg.apply(event, 2_000 + i as u64, &no_tools);
            assert_eq!(snap(&reg), before, "late frame {i} changed the snapshot");
            assert_eq!(reg.details(), details_before, "late frame {i} changed a detail");
            assert!(!reg.is_dirty(), "late frame {i} marked the registry dirty");
            assert!(reg.take_dirty().is_clean(), "late frame {i}");
        }
    }

    #[test]
    fn a_late_frame_for_a_task_not_yet_known_is_just_the_first_news_of_it() {
        let reg = registry_with(&[(&progress("t1", json!({"run_id": "run-001", "description": "hello"})), 1_000)]);
        assert_eq!(one(&reg, "t1").run_id.as_deref(), Some("run-001"));
    }

    #[test]
    fn a_frame_without_a_run_id_applies_to_the_run_held() {
        let reg = registry_with(&[
            (&started("t1", json!({"run_id": "run-003"})), 1_000),
            (&notified("t1", "completed", json!({})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.run_id.as_deref()), (TaskStatus::Completed, Some("run-003")));
    }

    #[test]
    fn a_run_id_arriving_after_a_task_without_one_is_adopted() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&progress("t1", json!({"run_id": "run-001", "description": "later"})), 1_500),
        ]);
        let t = one(&reg, "t1");
        assert_eq!(t.run_id.as_deref(), Some("run-001"));
        assert_eq!(t.description, "later");
        assert_eq!(t.started_at_ms, Some(1_000), "the same run, not a restart");
    }

    #[test]
    fn a_newer_run_of_the_same_task_makes_it_running_again_with_a_fresh_start_time() {
        let reg = registry_with(&[
            (&started("t1", json!({"run_id": "run-001", "task_type": "local_agent", "description": "first"})), 1_000),
            (&notified("t1", "completed", json!({"run_id": "run-001", "usage": {"total_tokens": 10, "tool_uses": 2, "duration_ms": 500}})), 2_000),
            (&started("t1", json!({"run_id": "run-002", "task_type": "local_agent", "description": "resumed"})), 9_000),
        ]);

        let t = one(&reg, "t1");

        assert_eq!(reg.len(), 1, "same task id, one entry");
        assert_eq!(t.status, TaskStatus::Running);
        assert_eq!(t.run_id.as_deref(), Some("run-002"));
        assert_eq!(t.started_at_ms, Some(9_000));
        assert_eq!((t.ended_at_ms, t.duration_ms, t.end_reason), (None, None, None));
        assert_eq!((t.total_tokens, t.tool_uses), (None, None), "the earlier run's counts are not this run's");
        assert_eq!(t.description, "resumed");
    }

    #[test]
    fn the_resumed_run_can_end_again_and_then_ignores_the_first_runs_late_frames() {
        let reg = registry_with(&[
            (&started("t1", json!({"run_id": "run-001"})), 1_000),
            (&notified("t1", "completed", json!({"run_id": "run-001"})), 2_000),
            (&started("t1", json!({"run_id": "run-002"})), 9_000),
            (&notified("t1", "failed", json!({"run_id": "run-002"})), 9_500),
            (&notified("t1", "completed", json!({"run_id": "run-001"})), 9_600),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.ended_at_ms, t.duration_ms), (TaskStatus::Failed, Some(9_500), Some(500)));
    }

    #[test]
    fn a_newer_run_keeps_the_tasks_place_in_the_list() {
        let reg = registry_with(&[
            (&started("a", json!({"run_id": "run-001"})), 1),
            (&started("b", json!({})), 2),
            (&started("a", json!({"run_id": "run-002"})), 3),
        ]);
        let ids: Vec<String> = snap(&reg).into_iter().map(|t| t.id).collect();
        assert_eq!(ids, ["a", "b"]);
    }

    // ── vanishing ───────────────────────────────────────────────────────────

    /// A backgrounded shell started at 10_000 and listed at 10_100.
    fn backgrounded_and_listed() -> TaskRegistry {
        registry_with(&[
            (&started("t1", json!({"task_type": "local_bash", "is_backgrounded": true})), 10_000),
            (&in_level(&["t1"]), 10_100),
        ])
    }

    #[test]
    fn a_background_task_missing_from_the_level_ends_vanished_exactly_when_the_grace_runs_out() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&level(json!([])), 20_000, &no_tools);
        assert_eq!(reg.next_deadline(), Some(20_000 + 3_000));

        assert!(!reg.tick(20_000 + 2_999), "one millisecond early");
        assert_eq!(one(&reg, "t1").status, TaskStatus::Running);

        assert!(reg.tick(20_000 + 3_000), "on the dot");
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.end_reason), (TaskStatus::Stopped, Some(TaskEndReason::Vanished)));
        assert_eq!(t.ended_at_ms, Some(23_000));
        assert_eq!(reg.next_deadline(), None);
        assert!(!reg.tick(99_000), "nothing left to end");
    }

    #[test]
    fn the_grace_period_is_three_seconds() {
        assert_eq!(VANISH_GRACE_MS, 3_000);
    }

    #[test]
    fn a_level_that_still_lists_the_task_never_ends_it() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&in_level(&["t1", "other"]), 20_000, &no_tools);
        assert_eq!(reg.next_deadline(), None);
        assert!(!reg.tick(1_000_000));
        assert_eq!(one(&reg, "t1").status, TaskStatus::Running);
    }

    #[test]
    fn a_terminal_update_inside_the_grace_means_the_task_is_not_declared_vanished() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&level(json!([])), 20_000, &no_tools);

        reg.apply(&updated("t1", json!({"status": "completed"})), 21_000, &no_tools);

        assert!(!reg.tick(23_000));
        let t = one(&reg, "t1");
        assert_eq!((t.status, t.end_reason, t.ended_at_ms), (TaskStatus::Completed, None, Some(21_000)));
        assert_eq!(reg.next_deadline(), None);
    }

    #[test]
    fn a_notification_inside_the_grace_means_the_task_is_not_declared_vanished() {
        for status in ["completed", "failed", "stopped"] {
            let mut reg = backgrounded_and_listed();
            reg.apply(&level(json!([])), 20_000, &no_tools);

            reg.apply(&notified("t1", status, json!({})), 22_999, &no_tools);
            reg.tick(23_000);

            assert_eq!(one(&reg, "t1").end_reason, None, "{status}");
            assert_ne!(one(&reg, "t1").status, TaskStatus::Running, "{status}");
            assert_eq!(one(&reg, "t1").ended_at_ms, Some(22_999), "{status}");
        }
    }

    #[test]
    fn a_task_that_reappears_in_a_later_level_is_spared_and_gets_a_fresh_grace_next_time() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&level(json!([])), 20_000, &no_tools);
        reg.apply(&in_level(&["t1"]), 21_000, &no_tools);

        assert!(!reg.tick(23_000));
        assert_eq!(one(&reg, "t1").status, TaskStatus::Running);
        assert_eq!(reg.next_deadline(), None);

        reg.apply(&level(json!([])), 30_000, &no_tools);
        assert!(!reg.tick(32_999));
        assert!(reg.tick(33_000));
        assert_eq!(one(&reg, "t1").end_reason, Some(TaskEndReason::Vanished));
    }

    #[test]
    fn missing_from_two_levels_in_a_row_does_not_extend_the_grace() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&level(json!([])), 20_000, &no_tools);
        reg.apply(&in_level(&["other"]), 21_500, &no_tools);

        assert_eq!(reg.next_deadline(), Some(23_000));
        assert!(reg.tick(23_000));
    }

    #[test]
    fn a_foreground_task_never_in_a_level_is_not_subject_to_vanishing() {
        for backgrounded in [json!(false), Value::Null] {
            let mut extra = json!({"task_type": "local_bash"});
            if !backgrounded.is_null() {
                extra["is_backgrounded"] = backgrounded.clone();
            }
            let mut reg = registry_with(&[(&started("fg", extra), 10_000)]);

            reg.apply(&level(json!([])), 20_000, &no_tools);
            reg.apply(&in_level(&["someone-else"]), 21_000, &no_tools);

            assert_eq!(reg.next_deadline(), None, "is_backgrounded {backgrounded}");
            assert!(!reg.tick(10_000_000));
            assert_eq!(one(&reg, "fg").status, TaskStatus::Running);
        }
    }

    #[test]
    fn a_task_seen_in_a_level_counts_as_backgrounded_even_without_the_flag() {
        let mut reg = registry_with(&[
            (&started("t1", json!({"task_type": "local_bash"})), 10_000),
            (&in_level(&["t1"]), 10_500),
        ]);
        reg.apply(&level(json!([])), 20_000, &no_tools);
        assert!(reg.tick(23_000));
        assert_eq!(one(&reg, "t1").end_reason, Some(TaskEndReason::Vanished));
    }

    #[test]
    fn a_task_backgrounded_by_a_later_patch_becomes_subject_to_vanishing() {
        let mut reg = registry_with(&[
            (&started("t1", json!({"task_type": "local_bash", "is_backgrounded": false})), 10_000),
            (&updated("t1", json!({"is_backgrounded": true})), 12_000),
        ]);
        reg.apply(&level(json!([])), 20_000, &no_tools);
        assert!(reg.tick(23_000));
        assert_eq!(one(&reg, "t1").end_reason, Some(TaskEndReason::Vanished));
    }

    #[test]
    fn a_paused_or_pending_background_task_vanishes_too() {
        for raw in ["paused", "pending"] {
            let mut reg = backgrounded_and_listed();
            reg.apply(&updated("t1", json!({"status": raw})), 11_000, &no_tools);
            reg.apply(&level(json!([])), 20_000, &no_tools);
            assert!(reg.tick(23_000), "{raw}");
            assert_eq!(one(&reg, "t1").end_reason, Some(TaskEndReason::Vanished), "{raw}");
        }
    }

    #[test]
    fn a_level_never_brings_an_ended_task_back() {
        let mut reg = backgrounded_and_listed();
        reg.apply(&notified("t1", "completed", json!({})), 15_000, &no_tools);

        reg.apply(&in_level(&["t1"]), 16_000, &no_tools);

        assert_eq!(one(&reg, "t1").status, TaskStatus::Completed);
        reg.apply(&level(json!([])), 17_000, &no_tools);
        assert!(!reg.tick(1_000_000));
        assert_eq!(one(&reg, "t1").end_reason, None);
    }

    #[test]
    fn only_the_missing_task_vanishes() {
        let mut reg = registry_with(&[
            (&started("keep", json!({"task_type": "local_bash", "is_backgrounded": true})), 10_000),
            (&started("gone", json!({"task_type": "local_bash", "is_backgrounded": true})), 10_000),
            (&in_level(&["keep", "gone"]), 10_100),
        ]);
        reg.apply(&in_level(&["keep"]), 20_000, &no_tools);
        reg.tick(23_000);
        assert_eq!(one(&reg, "keep").status, TaskStatus::Running);
        assert_eq!(one(&reg, "gone").status, TaskStatus::Stopped);
    }

    // ── the CLI process ends ────────────────────────────────────────────────

    #[test]
    fn when_the_session_ends_every_unfinished_task_is_stopped_with_that_reason() {
        let mut reg = registry_with(&[
            (&started("run", json!({"task_type": "local_bash"})), 1_000),
            (&started("pend", json!({})), 1_000),
            (&updated("pend", json!({"status": "pending"})), 1_100),
            (&started("paus", json!({})), 1_000),
            (&updated("paus", json!({"status": "paused"})), 1_100),
            (&started("vanishing", json!({"task_type": "local_bash", "is_backgrounded": true})), 1_000),
            (&level(json!([])), 1_200),
            (&started("done", json!({})), 1_000),
            (&notified("done", "completed", json!({})), 1_500),
            (&started("restarted", json!({})), 1_000),
            (&notified("restarted", "stopped", json!({"reason": "worker_restart"})), 1_600),
        ]);
        reg.take_dirty();

        reg.end_session(5_000);

        for id in ["run", "pend", "paus", "vanishing"] {
            let t = one(&reg, id);
            assert_eq!(
                (t.status, t.end_reason, t.ended_at_ms),
                (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded), Some(5_000)),
                "{id}"
            );
        }
        let done = one(&reg, "done");
        assert_eq!((done.status, done.end_reason, done.ended_at_ms), (TaskStatus::Completed, None, Some(1_500)));
        let restarted = one(&reg, "restarted");
        assert_eq!((restarted.end_reason, restarted.ended_at_ms), (Some(TaskEndReason::Restart), Some(1_600)));
        assert!(reg.take_dirty().snapshot, "clients must be told");
        assert_eq!(reg.next_deadline(), None);
    }

    #[test]
    fn ending_a_session_with_nothing_unfinished_changes_nothing() {
        let mut reg = registry_with(&[
            (&started("done", json!({})), 1_000),
            (&notified("done", "completed", json!({})), 1_500),
        ]);
        reg.take_dirty();
        reg.end_session(5_000);
        assert!(!reg.is_dirty());
        let mut empty = TaskRegistry::new();
        empty.end_session(5_000);
        assert!(!empty.is_dirty());
    }

    #[test]
    fn ending_a_session_twice_is_idempotent() {
        let mut reg = registry_with(&[(&started("run", json!({})), 1_000)]);
        reg.end_session(5_000);
        reg.take_dirty();
        let once = snap(&reg);
        reg.end_session(9_000);
        assert_eq!(snap(&reg), once);
        assert!(!reg.is_dirty());
    }

    // ── retention ───────────────────────────────────────────────────────────

    #[test]
    fn the_forty_most_recent_ended_tasks_are_kept_and_the_rest_are_dropped_with_their_details() {
        let mut reg = TaskRegistry::new();
        for i in 0..45u64 {
            let id = format!("e{i:02}");
            // Half of them housekeeping: retention does not care about kind.
            let ambient = i % 2 == 0;
            reg.apply(&started(&id, json!({"prompt": format!("prompt {i}"), "ambient": ambient})), 1_000 + i, &no_tools);
            reg.apply(&notified(&id, "completed", json!({})), 2_000 + i * 10, &no_tools);
        }
        for i in 0..3u64 {
            reg.apply(&started(&format!("r{i}"), json!({"prompt": "running prompt"})), 5_000 + i, &no_tools);
        }

        let ids: Vec<String> = snap(&reg).into_iter().map(|t| t.id).collect();

        assert_eq!(ids.len(), 43, "3 running + 40 ended: {ids:?}");
        for dropped in 0..5 {
            assert!(!ids.contains(&format!("e{dropped:02}")), "e{dropped:02} is among the 5 oldest ended");
            assert_eq!(reg.detail(&format!("e{dropped:02}")), None);
        }
        for kept in 5..45 {
            assert!(ids.contains(&format!("e{kept:02}")), "e{kept:02}");
            assert!(reg.detail(&format!("e{kept:02}")).is_some());
        }
        assert_eq!(reg.details().len(), 43, "details follow their tasks");
        assert!(reg.take_dirty().details.iter().all(|id| ids.contains(id)), "no detail is announced for a dropped task");
    }

    #[test]
    fn every_running_task_is_kept_however_many_there_are() {
        let mut reg = TaskRegistry::new();
        for i in 0..60u64 {
            reg.apply(&started(&format!("run{i:02}"), json!({})), 1 + i, &no_tools);
        }
        for i in 0..45u64 {
            let id = format!("end{i:02}");
            reg.apply(&started(&id, json!({})), 10_000 + i, &no_tools);
            reg.apply(&notified(&id, "failed", json!({})), 20_000 + i, &no_tools);
        }

        let snapshot = snap(&reg);

        let running = snapshot.iter().filter(|t| t.status == TaskStatus::Running).count();
        let ended = snapshot.iter().filter(|t| t.status.is_terminal()).count();
        assert_eq!((running, ended), (60, 40));
    }

    #[test]
    fn ended_tasks_are_ranked_by_when_they_ended_not_when_they_started() {
        let mut reg = TaskRegistry::new();
        // The long-running one starts first but ends last.
        reg.apply(&started("long", json!({})), 1, &no_tools);
        for i in 0..40u64 {
            let id = format!("quick{i:02}");
            reg.apply(&started(&id, json!({})), 100 + i, &no_tools);
            reg.apply(&notified(&id, "completed", json!({})), 200 + i, &no_tools);
        }
        reg.apply(&notified("long", "completed", json!({})), 9_000, &no_tools);

        let ids: Vec<String> = snap(&reg).into_iter().map(|t| t.id).collect();

        assert!(ids.contains(&"long".to_owned()));
        assert!(!ids.contains(&"quick00".to_owned()), "the oldest-ended makes room");
        assert_eq!(ids.len(), 40);
    }

    // ── usage ───────────────────────────────────────────────────────────────

    #[test]
    fn without_usage_the_counts_are_unknown_not_zero() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&progress("t1", json!({"description": "no usage here"})), 1_500),
            (&notified("t1", "completed", json!({})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (None, None));
        let wire = serde_json::to_value(&t).unwrap();
        assert!(wire.get("total_tokens").is_none() && wire.get("tool_uses").is_none(), "{wire}");
    }

    #[test]
    fn an_empty_usage_object_is_still_unknown() {
        let reg = registry_with(&[(&progress("t1", json!({"usage": {}})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses, t.duration_ms), (None, None, None));
    }

    #[test]
    fn usage_with_only_some_fields_sets_only_those() {
        let reg = registry_with(&[(&progress("t1", json!({"usage": {"total_tokens": 50}})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (Some(50), None));

        let reg = registry_with(&[(&progress("t1", json!({"usage": {"tool_uses": 4}})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (None, Some(4)));
    }

    #[test]
    fn a_reported_zero_is_a_zero() {
        let reg = registry_with(&[(&progress("t1", json!({"usage": {"total_tokens": 0, "tool_uses": 0}})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (Some(0), Some(0)));
    }

    #[test]
    fn later_usage_updates_the_fields_it_names_and_keeps_the_others() {
        let reg = registry_with(&[
            (&progress("t1", json!({"usage": {"total_tokens": 100, "tool_uses": 2}})), 1_000),
            (&progress("t1", json!({"usage": {"total_tokens": 250}})), 2_000),
            (&progress("t1", json!({"description": "no usage this time"})), 3_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (Some(250), Some(2)));
    }

    #[test]
    fn a_notifications_usage_counts_too() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&notified("t1", "completed", json!({"usage": {"total_tokens": 7, "tool_uses": 1}})), 2_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (Some(7), Some(1)));
    }

    #[test]
    fn malformed_usage_is_ignored() {
        let reg = registry_with(&[(&progress("t1", json!({"usage": "lots"})), 1_000)]);
        let t = one(&reg, "t1");
        assert_eq!((t.total_tokens, t.tool_uses), (None, None));
    }

    // ── times ───────────────────────────────────────────────────────────────

    #[test]
    fn the_start_time_is_when_the_daemon_first_heard_of_the_task() {
        let reg = registry_with(&[
            (&progress("t1", json!({"description": "early news"})), 500),
            (&started("t1", json!({})), 1_000),
            (&progress("t1", json!({"description": "more"})), 2_000),
        ]);
        assert_eq!(one(&reg, "t1").started_at_ms, Some(500));
    }

    #[test]
    fn a_patch_end_time_wins_over_the_time_the_event_arrived() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&updated("t1", json!({"status": "completed", "end_time": 5_000})), 9_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(5_000), Some(4_000)));
    }

    #[test]
    fn without_an_end_time_the_end_is_when_the_terminal_event_arrived() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&updated("t1", json!({"status": "failed"})), 6_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(6_000), Some(5_000)));

        let reg = registry_with(&[
            (&started("t2", json!({})), 1_000),
            (&notified("t2", "completed", json!({})), 4_000),
        ]);
        let t = one(&reg, "t2");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(4_000), Some(3_000)));
    }

    #[test]
    fn a_reported_duration_wins_over_end_minus_start() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&notified("t1", "completed", json!({"usage": {"duration_ms": 1_234}})), 4_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(4_000), Some(1_234)));
    }

    #[test]
    fn a_reported_duration_beats_a_patch_end_time_too() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 1_000),
            (&progress("t1", json!({"usage": {"duration_ms": 777}})), 2_000),
            (&updated("t1", json!({"status": "completed", "end_time": 9_000})), 9_500),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(9_000), Some(777)));
    }

    #[test]
    fn a_running_task_has_no_duration_unless_the_cli_reported_one() {
        let reg = registry_with(&[(&started("t1", json!({})), 1_000), (&progress("t1", json!({"description": "x"})), 5_000)]);
        assert_eq!(one(&reg, "t1").duration_ms, None);
        let reg = registry_with(&[(&started("t1", json!({})), 1_000), (&progress("t1", json!({"usage": {"duration_ms": 300}})), 5_000)]);
        assert_eq!(one(&reg, "t1").duration_ms, Some(300));
    }

    #[test]
    fn an_end_time_before_the_start_does_not_underflow() {
        let reg = registry_with(&[
            (&started("t1", json!({})), 10_000),
            (&updated("t1", json!({"status": "completed", "end_time": 500})), 11_000),
        ]);
        let t = one(&reg, "t1");
        assert_eq!((t.ended_at_ms, t.duration_ms), (Some(500), Some(0)));
    }

    // ── what is private to the daemon ───────────────────────────────────────

    #[test]
    fn preview_summaries_and_prompt_land_in_the_detail_and_never_in_the_snapshot() {
        let mut reg = registry_with(&[
            (
                &started(
                    "agt",
                    json!({"task_type": "local_agent", "description": "Survey", "prompt": "SECRET-OUTPUT-1 read the config"}),
                ),
                1_000,
            ),
            (&progress("agt", json!({"summary": "SECRET-OUTPUT-2 reading", "usage": {"total_tokens": 5}})), 2_000),
            (
                &notified(
                    "agt",
                    "completed",
                    json!({
                        "summary": "SECRET-OUTPUT-3 finished",
                        "output_file": "/private/tmp/claude-501/-repo/s/tasks/SECRET-OUTPUT-4.output",
                    }),
                ),
                3_000,
            ),
        ]);
        reg.set_preview("agt", Some("SECRET-OUTPUT-5 last line".into()));

        let detail = reg.detail("agt").expect("a detail");

        assert_eq!(detail.task_id, "agt");
        assert_eq!(detail.prompt.as_deref(), Some("SECRET-OUTPUT-1 read the config"));
        assert_eq!(detail.progress_summary.as_deref(), Some("SECRET-OUTPUT-2 reading"));
        assert_eq!(detail.completion_summary.as_deref(), Some("SECRET-OUTPUT-3 finished"));
        assert_eq!(detail.preview.as_deref(), Some("SECRET-OUTPUT-5 last line"));
        let wire = serde_json::to_string(&snap(&reg)).unwrap();
        assert!(!wire.contains("SECRET-OUTPUT"), "free text leaked into the metadata frame: {wire}");
        assert!(!wire.contains("/private/tmp") && !wire.contains("output_file") && !wire.contains(".output"), "{wire}");
    }

    #[test]
    fn an_output_path_never_appears_in_a_task_meta() {
        let reg = registry_with(&[
            (&started("t1", json!({"task_type": "local_bash"})), 1_000),
            (
                &notified("t1", "completed", json!({"output_file": "/private/tmp/claude-501/-repo/s/tasks/t1.output"})),
                2_000,
            ),
        ]);
        let wire = serde_json::to_string(&one(&reg, "t1")).unwrap();
        assert!(!wire.contains("/private/tmp") && !wire.contains("tasks/t1") && !wire.contains("output_file"), "{wire}");
    }

    #[test]
    fn only_tasks_with_text_have_a_detail() {
        let reg = registry_with(&[
            (&started("plain", json!({})), 1),
            (&started("agent", json!({"prompt": "do it"})), 2),
        ]);
        let ids: Vec<String> = reg.details().into_iter().map(|d| d.task_id).collect();
        assert_eq!(ids, ["agent"]);
    }

    #[test]
    fn a_new_detail_is_announced_once_and_a_snapshot_only_change_announces_no_detail() {
        let mut reg = registry_with(&[(&started("t1", json!({"prompt": "hello"})), 1_000)]);
        let dirty = reg.take_dirty();
        assert!(dirty.snapshot);
        assert_eq!(dirty.details, ["t1"]);

        reg.apply(&progress("t1", json!({"usage": {"total_tokens": 3}})), 2_000, &no_tools);
        let dirty = reg.take_dirty();
        assert!(dirty.snapshot);
        assert!(dirty.details.is_empty(), "the prompt did not change");
    }

    #[test]
    fn setting_the_same_preview_twice_changes_nothing_the_second_time() {
        let mut reg = registry_with(&[(&started("t1", json!({})), 1_000)]);
        reg.take_dirty();
        assert!(reg.set_preview("t1", Some("line".into())));
        assert_eq!(reg.take_dirty().details, ["t1"]);
        assert!(!reg.set_preview("t1", Some("line".into())));
        assert!(!reg.is_dirty());
        assert!(!reg.set_preview("no-such-task", Some("x".into())));
    }

    #[test]
    fn descriptions_and_texts_arrive_clean() {
        let hostile = format!("\u{1b}[31mred\u{1b}[0m\u{1b}]0;title\u{7} {}", "x".repeat(10_000));
        let reg = registry_with(&[(
            &started("t1", json!({"description": hostile, "prompt": hostile})),
            1_000,
        )]);
        let t = one(&reg, "t1");
        assert!(t.description.starts_with("red x"), "{:?}", &t.description[..20]);
        assert!(!t.description.contains('\u{1b}'));
        assert!(t.description.chars().count() < 10_000, "a 10 KB description is cut");
        let detail = reg.detail("t1").unwrap();
        assert!(!detail.prompt.unwrap().contains('\u{1b}'));
    }

    // ── preview targets ─────────────────────────────────────────────────────

    #[test]
    fn only_shell_and_monitor_tasks_are_previewable() {
        let reg = registry_with(&[
            (&started("sh", json!({"task_type": "local_bash"})), 1),
            (&started("mon", json!({"task_type": "monitor_mcp"})), 2),
            (&started("ag", json!({"task_type": "local_agent"})), 3),
            (&started("wf", json!({"task_type": "local_workflow"})), 4),
            (&started("ot", json!({"task_type": "quantum_task"})), 5),
        ]);
        let ids: Vec<String> = reg.preview_targets(&no_tools).into_iter().map(|t| t.task_id).collect();
        assert_eq!(ids, ["sh", "mon"]);
        assert!(reg.has_running_output_task(&no_tools));
    }

    #[test]
    fn running_output_tasks_stop_counting_once_they_end() {
        let mut reg = registry_with(&[
            (&started("sh", json!({"task_type": "local_bash"})), 1),
            (&started("ag", json!({"task_type": "local_agent"})), 2),
        ]);
        assert!(reg.has_running_output_task(&no_tools));
        reg.apply(&notified("sh", "completed", json!({})), 3, &no_tools);
        assert!(!reg.has_running_output_task(&no_tools), "an agent is not previewed");
        assert!(reg.preview_targets(&no_tools)[0].terminal);
    }

    #[test]
    fn a_notifications_output_path_is_offered_to_the_poller_only() {
        let reg = registry_with(&[
            (&started("sh", json!({"task_type": "local_bash"})), 1),
            (&notified("sh", "completed", json!({"output_file": "/x/y/sh.output"})), 2),
        ]);
        assert_eq!(reg.preview_targets(&no_tools)[0].output_file.as_deref(), Some("/x/y/sh.output"));
    }

    // ── coalescing ──────────────────────────────────────────────────────────

    /// Fire every wakeup the hub asks for up to `until`, as an ideal timer would.
    fn run_timer(hub: &mut TaskHub, until: u64, out: &mut Vec<(u64, TaskOutput)>) {
        for _ in 0..10_000 {
            let Some(at) = hub.next_wakeup() else { return };
            if at > until {
                return;
            }
            out.extend(hub.on_tick(at, &no_tools).into_iter().map(|o| (at, o)));
        }
        panic!("the hub keeps asking to be woken without making progress");
    }

    /// The one snapshot in a publication (its details, if any, are ignored).
    fn snapshot_in(out: &[TaskOutput]) -> Vec<TaskMeta> {
        let found: Vec<&Vec<TaskMeta>> = out
            .iter()
            .filter_map(|o| match o {
                TaskOutput::Snapshot(s) => Some(s),
                TaskOutput::Detail(_) => None,
            })
            .collect();
        assert_eq!(found.len(), 1, "expected exactly one snapshot in {out:?}");
        found[0].clone()
    }

    fn snapshots(out: &[(u64, TaskOutput)]) -> Vec<(u64, Vec<TaskMeta>)> {
        out.iter()
            .filter_map(|(at, o)| match o {
                TaskOutput::Snapshot(tasks) => Some((*at, tasks.clone())),
                TaskOutput::Detail(_) => None,
            })
            .collect()
    }

    #[test]
    fn a_hundred_progress_events_in_a_second_make_at_most_five_snapshots_and_the_last_is_current() {
        let mut hub = TaskHub::new();
        let mut out = Vec::new();
        for i in 0..100u64 {
            let now = i * 10;
            run_timer(&mut hub, now, &mut out);
            let event = progress("agt", json!({"usage": {"total_tokens": i + 1}}));
            out.extend(hub.on_event(&event, now, &no_tools).into_iter().map(|o| (now, o)));
        }
        run_timer(&mut hub, u64::MAX, &mut out);

        let published = snapshots(&out);

        assert!(!published.is_empty());
        assert!(published.len() <= 5, "{} snapshots: at {:?}", published.len(), published.iter().map(|p| p.0).collect::<Vec<_>>());
        assert_eq!(published[0].0, 0, "the first change goes out at once");
        for pair in published.windows(2) {
            assert!(pair[1].0 - pair[0].0 >= COALESCE_MS, "{} then {}", pair[0].0, pair[1].0);
        }
        let last = &published.last().unwrap().1;
        assert_eq!(last[0].total_tokens, Some(100), "the last snapshot reflects the last event");
        assert_eq!(hub.next_wakeup(), None, "nothing is left unpublished");
    }

    #[test]
    fn the_first_change_after_a_quiet_spell_is_published_in_the_same_call() {
        let mut hub = TaskHub::new();
        let first = hub.on_event(&progress("t1", json!({"description": "one"})), 1_000, &no_tools);
        assert_eq!(snapshot_in(&first).len(), 1);

        // Exactly the window later.
        let second = hub.on_event(&progress("t1", json!({"description": "two"})), 1_000 + COALESCE_MS, &no_tools);
        assert!(matches!(second.as_slice(), [TaskOutput::Snapshot(s)] if s[0].description == "two"), "{second:?}");

        // A long quiet.
        let third = hub.on_event(&progress("t1", json!({"description": "three"})), 60_000, &no_tools);
        assert!(matches!(third.as_slice(), [TaskOutput::Snapshot(s)] if s[0].description == "three"), "{third:?}");
    }

    #[test]
    fn a_change_inside_the_window_waits_for_the_window_to_end() {
        let mut hub = TaskHub::new();
        hub.on_event(&progress("t1", json!({"description": "one"})), 1_000, &no_tools);

        let early = hub.on_event(&progress("t1", json!({"description": "two"})), 1_249, &no_tools);

        assert!(early.is_empty());
        assert_eq!(hub.next_wakeup(), Some(1_250));
        assert!(hub.on_tick(1_249, &no_tools).is_empty(), "not yet");
        let due = hub.on_tick(1_250, &no_tools);
        assert!(matches!(due.as_slice(), [TaskOutput::Snapshot(s)] if s[0].description == "two"), "{due:?}");
        assert_eq!(hub.next_wakeup(), None);
    }

    #[test]
    fn an_event_that_changes_nothing_publishes_nothing_and_asks_for_no_wakeup() {
        let mut hub = TaskHub::new();
        let event = progress("t1", json!({"description": "same", "usage": {"total_tokens": 5}, "last_tool_name": "Read"}));
        snapshot_in(&hub.on_event(&event, 1_000, &no_tools));

        // Well past the window, and inside it.
        assert!(hub.on_event(&event, 1_100, &no_tools).is_empty());
        assert!(hub.on_event(&event, 9_000, &no_tools).is_empty());
        assert_eq!(hub.next_wakeup(), None);
    }

    #[test]
    fn a_stale_run_event_publishes_nothing() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({"run_id": "run-002"})), 1_000, &no_tools);
        let late = progress("t1", json!({"run_id": "run-001", "description": "late"}));
        assert!(hub.on_event(&late, 9_000, &no_tools).is_empty());
        assert_eq!(hub.next_wakeup(), None);
    }

    #[test]
    fn a_new_task_with_no_text_announces_no_detail() {
        let mut reg = registry_with(&[(&started("t1", json!({})), 1_000)]);
        let dirty = reg.take_dirty();
        assert!(dirty.snapshot);
        assert!(dirty.details.is_empty(), "there is nothing to say about it yet: {:?}", dirty.details);
    }

    #[test]
    fn a_plain_new_task_publishes_a_snapshot_and_no_empty_detail() {
        let mut hub = TaskHub::new();
        let out = hub.on_event(&started("t1", json!({"task_type": "local_bash"})), 1_000, &no_tools);
        assert!(matches!(out.as_slice(), [TaskOutput::Snapshot(_)]), "{out:?}");
    }

    #[test]
    fn a_publication_is_the_snapshot_then_the_details_that_changed() {
        let mut hub = TaskHub::new();
        let out = hub.on_event(&started("t1", json!({"prompt": "hello"})), 1_000, &no_tools);
        assert!(matches!(out.as_slice(), [TaskOutput::Snapshot(_), TaskOutput::Detail(d)] if d.prompt.as_deref() == Some("hello")), "{out:?}");
    }

    #[test]
    fn a_new_preview_publishes_a_detail_only_and_the_same_preview_nothing() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({"task_type": "local_bash"})), 1_000, &no_tools);

        let out = hub.set_preview("t1", Some("building 3/9".into()), 5_000, &no_tools);
        assert!(
            matches!(out.as_slice(), [TaskOutput::Detail(d)] if d.task_id == "t1" && d.preview.as_deref() == Some("building 3/9")),
            "{out:?}"
        );
        assert!(hub.set_preview("t1", Some("building 3/9".into()), 9_000, &no_tools).is_empty());
        assert_eq!(hub.next_wakeup(), None);
    }

    #[test]
    fn a_vanished_task_is_published_when_its_grace_ends() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({"task_type": "local_bash", "is_backgrounded": true})), 10_000, &no_tools);
        hub.on_event(&in_level(&["t1"]), 10_500, &no_tools);
        assert!(hub.on_event(&level(json!([])), 20_000, &no_tools).is_empty(), "nothing visible changed yet");
        assert_eq!(hub.next_wakeup(), Some(23_000), "the timer must wake for the deadline");

        assert!(hub.on_tick(22_999, &no_tools).is_empty());
        let out = hub.on_tick(23_000, &no_tools);

        let [TaskOutput::Snapshot(tasks)] = out.as_slice() else { panic!("{out:?}") };
        assert_eq!((tasks[0].status, tasks[0].end_reason), (TaskStatus::Stopped, Some(TaskEndReason::Vanished)));
    }

    #[test]
    fn the_end_of_a_session_is_published_at_once_even_inside_the_window() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({})), 1_000, &no_tools);

        let out = hub.end_session(1_010, &no_tools);

        let [TaskOutput::Snapshot(tasks)] = out.as_slice() else { panic!("{out:?}") };
        assert_eq!((tasks[0].status, tasks[0].end_reason), (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded)));
    }

    #[test]
    fn the_end_of_a_session_also_flushes_a_change_still_waiting_in_the_window() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({})), 1_000, &no_tools);
        hub.on_event(&started("t2", json!({})), 1_050, &no_tools); // deferred

        let out = hub.end_session(1_060, &no_tools);

        let tasks = snapshot_in(&out);
        assert_eq!(tasks.len(), 2, "the deferred task is in the final snapshot");
        assert!(tasks.iter().all(|t| t.status == TaskStatus::Stopped));
        assert_eq!(hub.next_wakeup(), None);
    }

    #[test]
    fn ending_a_session_with_no_unfinished_task_publishes_nothing() {
        let mut hub = TaskHub::new();
        assert!(hub.end_session(1_000, &no_tools).is_empty());
        hub.on_event(&started("t1", json!({})), 2_000, &no_tools);
        hub.on_event(&notified("t1", "completed", json!({})), 3_000, &no_tools);
        assert!(hub.end_session(4_000, &no_tools).is_empty());
    }

    #[test]
    fn the_current_state_is_available_without_disturbing_the_schedule() {
        let mut hub = TaskHub::new();
        hub.on_event(&started("t1", json!({"prompt": "p"})), 1_000, &no_tools);
        hub.on_event(&progress("t1", json!({"usage": {"total_tokens": 9}})), 1_100, &no_tools); // deferred
        let wake = hub.next_wakeup();

        let (tasks, details) = hub.current(&no_tools);

        assert_eq!(tasks[0].total_tokens, Some(9), "current includes the unpublished change");
        assert_eq!(details.len(), 1);
        assert_eq!(hub.next_wakeup(), wake);
        let due = hub.on_tick(1_250, &no_tools);
        assert!(matches!(due.as_slice(), [TaskOutput::Snapshot(s)] if *s == tasks), "{due:?}");
    }

    // ── parsing ─────────────────────────────────────────────────────────────

    #[test]
    fn a_task_event_remembers_the_session_it_came_from() {
        let e = started("t1", json!({"session_id": "sess-1"}));
        assert_eq!(e.session_id.as_deref(), Some("sess-1"));
        assert_eq!(started("t1", json!({})).session_id, None);
    }

    #[test]
    fn unknown_subtypes_and_malformed_events_do_not_parse() {
        let o = |v: Value| v.as_object().unwrap().clone();
        assert!(parse_task_event("task_frobnicated", &o(json!({"task_id": "t"}))).is_none());
        assert!(parse_task_event("init", &o(json!({"task_id": "t"}))).is_none());
        assert!(parse_task_event("task_started", &o(json!({"description": "no id"}))).is_none());
        assert!(parse_task_event("task_progress", &o(json!({"task_id": ""}))).is_none());
        assert!(parse_task_event("task_updated", &o(json!({"task_id": "t", "patch": "done"}))).is_none());
        assert!(parse_task_event("task_updated", &o(json!({"task_id": "t"}))).is_none());
        assert!(parse_task_event("task_notification", &o(json!({"task_id": "t", "status": "exploded"}))).is_none());
        assert!(parse_task_event("task_notification", &o(json!({"task_id": "t"}))).is_none());
        assert!(parse_task_event("background_tasks_changed", &o(json!({"tasks": "t"}))).is_none());
        assert!(parse_task_event("background_tasks_changed", &o(json!({}))).is_none(), "a level without `tasks` is not an empty level");
    }

    #[test]
    fn a_level_skips_entries_it_cannot_use_and_keeps_the_rest() {
        let e = level(json!([42, null, {"description": "no id"}, {"task_id": "ok1", "task_type": "local_bash", "description": "survivor"}]));
        let TaskEventKind::LevelChanged(tasks) = e.kind else { panic!() };
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task_id, "ok1");
    }

    #[test]
    fn a_hostile_event_stream_never_panics_the_registry() {
        let mut reg = TaskRegistry::new();
        let events = [
            progress("t1", json!({"usage": {"total_tokens": u64::MAX, "tool_uses": u64::MAX, "duration_ms": u64::MAX}})),
            updated("t1", json!({"status": "completed", "end_time": 0})),
            updated("t1", json!({"end_time": u64::MAX})),
            notified("t1", "stopped", json!({"usage": {"duration_ms": u64::MAX}})),
            started("t2", json!({"description": "\u{1b}[", "task_type": "\u{1b}]0;x"})),
            level(json!([{"task_id": "t2"}, {"task_id": "t2"}])),
            level(json!([])),
        ];
        for (i, e) in events.iter().enumerate() {
            reg.apply(e, 1_760_000_000_000 + i as u64, &no_tools);
        }
        reg.tick(u64::MAX);
        reg.end_session(u64::MAX);
        let _ = reg.snapshot(&no_tools);
    }
}
