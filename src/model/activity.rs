//! Audit lines for model changes, appended to `~/.claude/activity.jsonl` in
//! that file's existing shape (see `agent_bus::ActivityEvent`) plus the
//! model-specific fields.

use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::{SecondsFormat, Utc};
use serde::Serialize;

use super::ModelTarget;
use crate::ipc::protocol::TaskKind;

/// Same override the activity hook honours (`nostromo_activity_hook`).
pub const ACTIVITY_PATH_ENV: &str = "NOSTROMO_ACTIVITY_PATH";

/// `$NOSTROMO_ACTIVITY_PATH`, else `~/.claude/activity.jsonl`.
pub fn activity_path() -> PathBuf {
    std::env::var(ACTIVITY_PATH_ENV)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs_next::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".claude")
                .join("activity.jsonl")
        })
}

/// `model_switch` or `model_default`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelActivityKind {
    ModelSwitch,
    ModelDefault,
}

/// How a request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Applied,
    Failed,
    Denied,
    Expired,
    Refused,
}

/// One activity line.
#[derive(Debug, Clone, Serialize)]
pub struct ModelActivity {
    /// The agent of the focus (the `agent` field of every activity line).
    pub agent: String,
    pub kind: ModelActivityKind,
    pub summary: String,
    pub session_id: Option<String>,
    pub agent_type: Option<String>,
    pub focus_tag: Option<String>,
    pub from: Option<ModelTarget>,
    pub to: Option<ModelTarget>,
    /// `user`, `script`, `agent:<name>` or `network`.
    pub actor: String,
    pub outcome: Outcome,
    /// The agent's stated reason, or why the request failed or was refused.
    pub reason: Option<String>,
    /// Bishop's posture at the time, or `None` when unknown.
    pub posture: Option<String>,
}

/// What a background-task audit line is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskActivityKind {
    /// A request to stop a background task.
    TaskStop,
    /// A request to read a task's output, as far as a network peer's refused
    /// one is concerned (a local read is not audited).
    TaskOutput,
}

/// One audit line about a background task: a stop the user asked for, or a
/// request a network peer made and was refused.
#[derive(Debug, Clone, Serialize)]
pub struct TaskActivity {
    /// The agent of the focus (the `agent` field of every activity line).
    pub agent: String,
    pub kind: TaskActivityKind,
    pub summary: String,
    pub session_id: Option<String>,
    pub agent_type: Option<String>,
    /// The focus; the opaque id for a sensitive one.
    pub focus_tag: Option<String>,
    /// `user` for a local request, `network` for a refused one.
    pub actor: String,
    pub task_kind: Option<TaskKind>,
    pub description: Option<String>,
    pub outcome: Outcome,
    /// Why the request was refused or failed.
    pub reason: Option<String>,
}

#[derive(Serialize)]
struct Line<'a, T: Serialize> {
    ts: String,
    #[serde(flatten)]
    activity: &'a T,
}

/// Bishop's current posture label, if a posture file is readable.
pub fn current_posture() -> Option<String> {
    crate::data::rate_limits::PostureSnapshot::load().map(|p| p.posture.label().to_owned())
}

/// Append `activity` to the log at `path`. Best effort: a failure is logged,
/// never surfaced (the switch itself already happened or failed).
pub fn append(path: &Path, activity: &ModelActivity) {
    append_line(path, activity);
}

/// Append a background-task `activity` line to the log at `path`. Best effort,
/// like [`append`].
pub fn append_task(path: &Path, activity: &TaskActivity) {
    append_line(path, activity);
}

fn append_line<T: Serialize>(path: &Path, activity: &T) {
    let line = Line {
        ts: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        activity,
    };
    let result = (|| -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut text = serde_json::to_string(&line)?;
        text.push('\n');
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        f.write_all(text.as_bytes())?;
        Ok(())
    })();
    if let Err(e) = result {
        tracing::warn!(path = %path.display(), "could not append activity: {e:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stop_line(outcome: Outcome, reason: Option<&str>) -> TaskActivity {
        TaskActivity {
            agent: "cody".into(),
            kind: TaskActivityKind::TaskStop,
            summary: "Stop of build watcher: applied.".into(),
            session_id: Some("sess-1".into()),
            agent_type: Some("cody".into()),
            focus_tag: Some("cody-core-1".into()),
            actor: "user".into(),
            task_kind: Some(TaskKind::Shell),
            description: Some("build watcher".into()),
            outcome,
            reason: reason.map(str::to_owned),
        }
    }

    fn lines_of(path: &Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("not a JSON line ({e}): {l}")))
            .collect()
    }

    #[test]
    fn a_stop_is_appended_as_one_json_line_with_who_what_and_how_it_ended() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("nested").join("activity.jsonl");

        append_task(&log, &stop_line(Outcome::Applied, None));

        let lines = lines_of(&log);
        assert_eq!(lines.len(), 1);
        let line = &lines[0];
        assert!(line["ts"].as_str().is_some_and(|t| t.ends_with('Z')), "a UTC timestamp: {line}");
        assert_eq!(line["kind"], "task_stop");
        assert_eq!(line["actor"], "user");
        assert_eq!(line["agent"], "cody");
        assert_eq!(line["focus_tag"], "cody-core-1");
        assert_eq!(line["task_kind"], "shell");
        assert_eq!(line["description"], "build watcher");
        assert_eq!(line["outcome"], "applied");
        assert_eq!(line["session_id"], "sess-1");
    }

    #[test]
    fn a_refused_network_read_names_its_kind_actor_and_reason() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("activity.jsonl");
        let mut refusal = stop_line(Outcome::Refused, Some("requires_secure_connection"));
        refusal.kind = TaskActivityKind::TaskOutput;
        refusal.actor = "network".into();
        refusal.task_kind = None;
        refusal.description = None;

        append_task(&log, &refusal);

        let line = &lines_of(&log)[0];
        assert_eq!(line["kind"], "task_output");
        assert_eq!(line["actor"], "network");
        assert_eq!(line["outcome"], "refused");
        assert_eq!(line["reason"], "requires_secure_connection");
        assert!(line["description"].is_null() && line["task_kind"].is_null(), "{line}");
    }

    #[test]
    fn every_outcome_is_written_by_its_snake_case_name() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("activity.jsonl");
        for outcome in [Outcome::Applied, Outcome::Failed, Outcome::Denied, Outcome::Expired, Outcome::Refused] {
            append_task(&log, &stop_line(outcome, None));
        }
        let names: Vec<String> =
            lines_of(&log).iter().map(|l| l["outcome"].as_str().unwrap().to_owned()).collect();
        assert_eq!(names, ["applied", "failed", "denied", "expired", "refused"]);
    }

    #[test]
    fn task_lines_append_after_model_lines_without_disturbing_them() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("activity.jsonl");
        append_task(&log, &stop_line(Outcome::Applied, None));
        append(
            &log,
            &ModelActivity {
                agent: "cody".into(),
                kind: ModelActivityKind::ModelSwitch,
                summary: "switch".into(),
                session_id: None,
                agent_type: None,
                focus_tag: Some("cody-core-1".into()),
                from: None,
                to: None,
                actor: "user".into(),
                outcome: Outcome::Applied,
                reason: None,
                posture: None,
            },
        );
        append_task(&log, &stop_line(Outcome::Failed, Some("timeout")));

        let kinds: Vec<String> = lines_of(&log).iter().map(|l| l["kind"].as_str().unwrap().to_owned()).collect();
        assert_eq!(kinds, ["task_stop", "model_switch", "task_stop"]);
    }
}
