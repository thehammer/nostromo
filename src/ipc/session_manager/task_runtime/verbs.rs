//! What a local client can ask about one background task: stop it, read its
//! output. Plus the probe that finds out, once per CLI process, whether the
//! CLI can stop tasks at all.
//!
//! Both verbs only ever run for a local peer (network peers are refused
//! before they get here, see `peer.rs`). A client never names a file: the
//! daemon resolves and validates the path itself (`OutputFileValidator`).
//!
//! The output text is output-derived, so it only ever leaves in
//! `SessionTaskOutputResult`, a `LocalOnly` frame.

use std::path::Path;
use std::sync::atomic::Ordering;

use serde_json::json;

use super::super::control::{control_within, says_unsupported};
use super::super::{lock_recover, Shared};
use super::TaskRuntime;
use crate::ipc::protocol::{
    TaskOutputOutcome, TaskOutputSource, TaskStopOutcome, TASK_OUTPUT_MAX_BYTES,
};
use crate::ipc::task_output::{is_valid_task_id, sanitize, OutputFileError, OutputFileValidator, RangeRead};
use crate::ipc::tasks::{PreviewTarget, TaskLabel};

/// The id of the `stop_task` the probe sends. No task has it: a CLI that can
/// stop tasks answers "no such task", one that cannot says it does not know
/// the request.
pub const CAPABILITY_PROBE_TASK_ID: &str = "__nostromo_capability_probe__";

/// The smallest read honoured: a window under four bytes could not hold one
/// UTF-8 scalar, so a reader asking for it would never advance.
const MIN_READ_BYTES: usize = 4;

/// How a stop request ended, and what the audit line needs to say about it.
#[derive(Debug, Clone, PartialEq)]
pub struct StopReport {
    pub outcome: TaskStopOutcome,
    /// The CLI's reason (a refusal), or why nothing was sent.
    pub message: Option<String>,
    /// The task, when the registry holds it.
    pub label: Option<TaskLabel>,
    /// Who the session is, for the audit line (empty when there is none).
    pub agent_name: String,
    pub session_id: Option<String>,
}

impl StopReport {
    /// A stop for a session that does not exist or a task that has ended:
    /// nothing was sent.
    pub fn not_running(message: &str) -> Self {
        Self {
            outcome: TaskStopOutcome::NotRunning,
            message: Some(message.to_owned()),
            label: None,
            agent_name: String::new(),
            session_id: None,
        }
    }
}

/// The answer to an output read.
#[derive(Debug, Clone, PartialEq)]
pub struct OutputReply {
    pub outcome: TaskOutputOutcome,
    pub text: String,
    pub start_offset: u64,
    pub end_offset: u64,
    pub total_bytes: u64,
    pub source: Option<TaskOutputSource>,
    pub message: Option<String>,
}

impl OutputReply {
    /// A read that produced no text.
    pub fn without_text(outcome: TaskOutputOutcome, message: &str) -> Self {
        Self {
            outcome,
            text: String::new(),
            start_offset: 0,
            end_offset: 0,
            total_bytes: 0,
            source: None,
            message: Some(message.to_owned()),
        }
    }
}

// ── stop ────────────────────────────────────────────────────────────────────

/// Ask the CLI to stop `task_id`. The task's status does not change here: it
/// changes when the CLI reports the task ended.
pub(in crate::ipc::session_manager) async fn stop_task(shared: &Shared, task_id: &str) -> StopReport {
    let runtime = &shared.tasks;
    let label = {
        let lookup = runtime.tool_lookup();
        lock_recover(&runtime.hub).begin_stop(task_id, &lookup)
    };
    let report = |outcome, message: Option<String>, label: Option<TaskLabel>| StopReport {
        outcome,
        message,
        label,
        agent_name: shared.ctx.agent_name.clone(),
        session_id: Some(shared.ctx.session_id.clone()).filter(|s| !s.is_empty()),
    };
    let Some(label) = label else {
        return report(TaskStopOutcome::NotRunning, Some("the task is not running".to_owned()), None);
    };

    let reply = control_within(
        shared,
        json!({ "subtype": "stop_task", "task_id": task_id }),
        runtime.control_timeout,
    )
    .await;
    let failure = match reply {
        Ok(_) => {
            runtime.learn_stop_supported(&shared.event_tx, true);
            return report(TaskStopOutcome::Accepted, None, Some(label));
        }
        // The stop may still land: the mark stays for the end it explains.
        Err(f) if f.timed_out => return report(TaskStopOutcome::Timeout, Some(f.reason), Some(label)),
        Err(f) => f,
    };
    // Every other failure means no stop is under way.
    lock_recover(&runtime.hub).cancel_stop(task_id);
    let outcome = if failure.refused && says_unsupported(&failure.reason) {
        runtime.learn_stop_supported(&shared.event_tx, false);
        TaskStopOutcome::Unsupported
    } else if failure.refused {
        runtime.learn_stop_supported(&shared.event_tx, true);
        TaskStopOutcome::Refused
    } else {
        // The session went away: its tasks ended with it.
        TaskStopOutcome::NotRunning
    };
    report(outcome, Some(failure.reason), Some(label))
}

/// Send the capability probe if it is due: once per CLI process, after the
/// first task that could be stopped appears.
pub(in crate::ipc::session_manager) fn ensure_probe(shared: &Shared) {
    let runtime = &shared.tasks;
    if shared.exited.load(Ordering::SeqCst) || runtime.probe_started.load(Ordering::SeqCst) {
        return;
    }
    if !lock_recover(&runtime.hub).registry().has_stoppable_task() {
        return;
    }
    if runtime.probe_started.swap(true, Ordering::SeqCst) {
        return;
    }
    let shared = shared.clone();
    let handle = shared.runtime.clone();
    handle.spawn(async move { probe(&shared).await });
}

async fn probe(shared: &Shared) {
    let runtime = &shared.tasks;
    let reply = control_within(
        shared,
        json!({ "subtype": "stop_task", "task_id": CAPABILITY_PROBE_TASK_ID }),
        runtime.control_timeout,
    )
    .await;
    match reply {
        // Expected: "No task found with ID". Either way the CLI knows the request.
        Ok(_) => runtime.learn_stop_supported(&shared.event_tx, true),
        Err(f) if f.refused => {
            runtime.learn_stop_supported(&shared.event_tx, !says_unsupported(&f.reason));
        }
        // No answer: stays unknown; Stop is offered and a real refusal explains.
        Err(_) => {}
    }
}

// ── output ──────────────────────────────────────────────────────────────────

/// Read `task_id`'s output: from its file when one validates, else the CLI's
/// own last 8 KiB, else nothing. See `SessionTaskOutput` for the wire rules.
pub(in crate::ipc::session_manager) async fn read_output(
    shared: &Shared,
    task_id: &str,
    offset: Option<u64>,
    max_bytes: u32,
) -> OutputReply {
    let runtime = &shared.tasks;
    let max = (max_bytes.min(TASK_OUTPUT_MAX_BYTES) as usize).max(MIN_READ_BYTES);
    let target = if is_valid_task_id(task_id) {
        let lookup = runtime.tool_lookup();
        lock_recover(&runtime.hub).registry().output_target(task_id, &lookup)
    } else {
        None
    };
    let Some((kind, target)) = target else {
        return OutputReply::without_text(TaskOutputOutcome::Error, "the session has no such task");
    };
    if !kind.has_output() {
        return OutputReply::without_text(TaskOutputOutcome::Unavailable, "this kind of task has no output");
    }

    let finished = target.terminal;
    let file = runtime
        .first_readable(&target, move |validator, path, id| {
            validator.read_range_of(path, id, offset, max, finished)
        })
        .await;
    if let Some(range) = file {
        return file_reply(range);
    }

    if let Some(reply) = cli_tail_reply(shared, &target, max).await {
        return reply;
    }
    OutputReply::without_text(TaskOutputOutcome::Unavailable, "the output is no longer available")
}

fn file_reply(range: RangeRead) -> OutputReply {
    OutputReply {
        outcome: TaskOutputOutcome::Ok,
        text: sanitize(&range.bytes),
        start_offset: range.start,
        end_offset: range.end,
        total_bytes: range.total_bytes,
        source: Some(TaskOutputSource::File),
        message: None,
    }
}

/// The CLI's own tail of the output, as a reply; `None` when it has none.
async fn cli_tail_reply(shared: &Shared, target: &PreviewTarget, max: usize) -> Option<OutputReply> {
    let runtime = &shared.tasks;
    if lock_recover(&runtime.cli_tail).unsupported {
        return None;
    }
    let reply = control_within(
        shared,
        json!({ "subtype": "get_task_output", "task_id": target.task_id }),
        runtime.control_timeout,
    )
    .await;
    runtime.note_cli_tail_answer(&reply.as_ref().map(|_| ()).map_err(|f| f.reason.clone()));
    let body = reply.ok()?.body;
    let output = body.get("output")?.as_str()?;
    let total = body
        .get("total_bytes")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(output.len() as u64)
        .max(output.len() as u64);
    // "An ended task whose file is gone reads as empty": for a finished task
    // that is no output at all, not an output of nothing.
    if output.is_empty() && total == 0 && target.terminal {
        return None;
    }
    let tail = last_bytes(output, max);
    Some(OutputReply {
        outcome: TaskOutputOutcome::Ok,
        text: sanitize(tail.as_bytes()),
        start_offset: total - tail.len() as u64,
        end_offset: total,
        total_bytes: total,
        source: Some(TaskOutputSource::CliTail),
        message: None,
    })
}

/// The last `max` bytes of `s`, starting on a character boundary.
fn last_bytes(s: &str, max: usize) -> &str {
    let mut from = s.len().saturating_sub(max);
    while !s.is_char_boundary(from) {
        from += 1;
    }
    &s[from..]
}

impl TaskRuntime {
    /// The first candidate file for `target` that validates and that `read`
    /// reads. `None`: no file could be read (missing, refused, or unreadable).
    pub(super) async fn first_readable<T: Send + 'static>(
        &self,
        target: &PreviewTarget,
        read: impl Fn(&OutputFileValidator, &Path, &str) -> Result<T, OutputFileError> + Clone + Send + 'static,
    ) -> Option<T> {
        for path in self.candidate_paths(target) {
            let validator = lock_recover(&self.files).validator.clone();
            let id = target.task_id.clone();
            let read_path = path.clone();
            let read = read.clone();
            let result = tokio::task::spawn_blocking(move || read(&validator, &read_path, &id)).await;
            if let Ok(Ok(value)) = result {
                if let Some(dir) = path.parent() {
                    lock_recover(&self.files).known_dir = Some(dir.to_path_buf());
                }
                return Some(value);
            }
        }
        None
    }

    /// What the CLI's answers say about stopping tasks. A `true` never
    /// overrides what is known; a `false` (the CLI said it does not know the
    /// request) always does. A change is published as a new snapshot.
    fn learn_stop_supported(&self, tx: &tokio::sync::broadcast::Sender<super::super::SessionEvent>, supported: bool) {
        {
            let mut known = lock_recover(&self.stop_supported);
            let next = match (*known, supported) {
                (None, value) => Some(value),
                (Some(_), false) => Some(false),
                (Some(current), true) => Some(current),
            };
            if *known == next {
                return;
            }
            *known = next;
        }
        let lookup = self.tool_lookup();
        let mut hub = lock_recover(&self.hub);
        let out = hub.republish(self.clock.now_ms(), &lookup);
        self.publish(tx, out);
        drop(hub);
        self.wake.notify_one();
    }
}
