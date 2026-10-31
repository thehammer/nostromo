//! MCP tool handlers for Mother job-control mutations.
//!
//! ## Tools
//! - `mother.enqueue_job({ plan_path, repo, branch, notify?, ... })`
//! - `mother.cancel_job({ id })`
//! - `mother.archive_job({ id })`
//! - `mother.resume_job({ id, answer })`

use std::future::Future;
use std::path::PathBuf;

use serde_json::{json, Value};

use crate::ipc::protocol::ServerMsg;
use crate::mcp::state::McpSharedState;
use crate::mother::origin::{self, NotifyLevel, OriginCaller, Via};
use crate::mother::{self, AddJobRequest, MotherCliError};

// ── handlers ─────────────────────────────────────────────────────────────────

/// Arguments an agent might send to name a different origin. All are ignored:
/// the daemon records the caller's own focus (R1), and the result says so.
const IGNORED_ORIGIN_ARGS: [&str; 5] = [
    "origin",
    "origin_focus",
    "origin_focus_name",
    "origin_session",
    "focus",
];

/// Handle `mother.enqueue_job({ plan_path, repo, branch, repo_path?, base?,
/// max_cost?, label?, depends_on?, notify? })`.
///
/// The daemon records the calling focus (`pty_id` is the focus tag) as the
/// job's origin: it passes the focus's session to `mother add`, the focus tag
/// and name too when `mother add` takes them, and writes the origin book. A
/// caller that is not a focus the daemon knows stamps nothing.
pub async fn enqueue_job(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let mut req = match parse_add_request(args) {
        Ok(r) => r,
        Err(detail) => return json!({ "error": "invalid_args", "detail": detail }),
    };
    let notify = match parse_notify(args) {
        Ok(n) => n,
        Err(detail) => return json!({ "error": "invalid_args", "detail": detail }),
    };

    let Some(daemon) = state.daemon.as_ref() else {
        return json!({ "error": "not_supported", "detail": "requires nostromd" });
    };
    if !req.plan_file.is_file() {
        return json!({ "error": "plan_not_found", "detail": req.plan_file.display().to_string() });
    }

    let caller = pty_id.and_then(|tag| daemon.session_mgr.lock().unwrap().origin_caller(tag));
    if let Some(caller) = &caller {
        apply_origin(&mut req, caller).await;
    }
    let book = state.mother_feed.as_ref().and_then(|f| f.origins());
    // Mother lists the job before it is stamped: until then it is undecided,
    // not unverified.
    let in_flight = caller.as_ref().and(book).map(|b| b.begin_enqueue());
    match mother::add_job(req).await {
        Ok(id) => {
            if let (Some(caller), Some(book)) = (&caller, book) {
                book.stamp(&id, caller.stamp(Via::Mcp, notify));
            }
            drop(in_flight);
            rebroadcast_jobs(state).await;
            let mut result = json!({ "id": id });
            if let Some(caller) = &caller {
                result["origin"] = json!({ "kind": "focus", "focus_tag": caller.tag });
            }
            if IGNORED_ORIGIN_ARGS.iter().any(|k| args.get(*k).is_some()) {
                result["origin_overridden"] = json!(true);
            }
            result
        }
        Err(e) => cli_error_value(&e),
    }
}

/// Put the calling focus's origin on a `mother add` request: its session
/// always (that flag exists in every `mother`), its tag and name only when
/// this `mother` takes them (an older one dies on an unknown flag) and the
/// focus is not sensitive.
///
/// A sensitive focus hands over its session id alone. Its tag can be a slug of
/// a work item's title, so it stays out of argv and Mother's record too; the
/// daemon still vouches for the job, because the session id alone names the one
/// focus whose history holds it (`SessionHistory::tag_of`), and it stamps the
/// tag and name into its own book.
pub(crate) async fn apply_origin(req: &mut AddJobRequest, caller: &OriginCaller) {
    let (session, name) = caller.flag_values();
    req.origin_session = session;
    if !caller.sensitive && !caller.tag.starts_with('-') && origin::supports_origin_focus().await {
        req.origin_focus = Some(caller.tag.clone());
        req.origin_focus_name = name;
    }
}

/// The optional `notify` argument: `wake`, `quiet` or `off`.
fn parse_notify(args: &Value) -> Result<Option<NotifyLevel>, String> {
    match args.get("notify") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_str()
            .and_then(NotifyLevel::parse)
            .map(Some)
            .ok_or_else(|| "notify must be one of wake, quiet, off".to_owned()),
    }
}

fn parse_add_request(args: &Value) -> Result<AddJobRequest, String> {
    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).map(str::to_string);
    let plan_file = str_arg("plan_path").ok_or("missing plan_path")?;
    let repo = str_arg("repo").ok_or("repo is required")?;
    let branch = str_arg("branch").ok_or("branch is required")?;
    let depends_on = args
        .get("depends_on")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let req = AddJobRequest {
        plan_file: PathBuf::from(plan_file),
        repo,
        repo_path: str_arg("repo_path"),
        branch,
        base: str_arg("base"),
        max_cost: args.get("max_cost").and_then(|v| v.as_f64()),
        label: str_arg("label"),
        depends_on,
        ..Default::default()
    };
    req.validate().map_err(|e| e.to_string())?;
    Ok(req)
}

/// The tool error for a failed `mother` CLI call.
///
/// An "open PR" refusal gets its own error code and a pointer at
/// `mother reconcile` (the CLI's own remedy) so an agent can act on it
/// instead of retrying blindly.
fn cli_error_value(e: &anyhow::Error) -> Value {
    if let Some(MotherCliError::OpenPr { detail, .. }) = e.downcast_ref::<MotherCliError>() {
        return json!({
            "error": "mother_job_has_open_pr",
            "detail": detail,
            "hint": "the job's branch already has an open PR; adopt it with `mother reconcile <id>` instead",
        });
    }
    json!({ "error": format!("mother_cli_error: {e}"), "detail": e.to_string() })
}

/// Run a daemon-side job mutation, then re-list jobs, publish them to the
/// daemon's feed (so `mother.list_jobs` / `get_status` / `list_views` see the
/// result immediately) and broadcast them to every client.
async fn daemon_mutation(
    state: &McpSharedState,
    op: impl Future<Output = anyhow::Result<()>>,
) -> Value {
    let result = match op.await {
        Ok(()) => json!({ "ok": true }),
        Err(e) => cli_error_value(&e),
    };
    rebroadcast_jobs(state).await;
    result
}

async fn rebroadcast_jobs(state: &McpSharedState) {
    let Some(daemon) = state.daemon.as_ref() else {
        return;
    };
    let listed = match state.mother_feed.as_ref() {
        Some(feed) => feed.refresh().await,
        None => mother::list_jobs().await,
    };
    match listed {
        Ok(jobs) => {
            let _ = daemon.broadcast_tx.send(ServerMsg::MotherJobs { jobs });
        }
        Err(e) => tracing::warn!("mother job re-poll failed: {e:#}"),
    }
}

/// Handle `mother.cancel_job({ id })`.
pub async fn cancel_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    if state.daemon.is_some() {
        return daemon_mutation(state, mother::cancel(&job_id)).await;
    }

    json!({ "error": "not_supported", "detail": "requires nostromd" })
}

/// Handle `mother.archive_job({ id })`.
pub async fn archive_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    if state.daemon.is_some() {
        return daemon_mutation(state, mother::archive(&job_id)).await;
    }

    json!({ "error": "not_supported", "detail": "requires nostromd" })
}

/// Handle `mother.retry_job({ id })`.
pub async fn retry_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };

    if state.daemon.is_some() {
        return daemon_mutation(state, mother::retry(&job_id)).await;
    }

    json!({ "error": "not_supported", "detail": "requires nostromd" })
}

/// Whether the daemon's latest job list has this job held with an open decision.
fn has_open_decision(state: &McpSharedState, job_id: &str) -> bool {
    let Some(feed) = state.mother_feed.as_ref() else {
        return false;
    };
    let jobs = feed.jobs_rx().borrow().clone();
    jobs.iter()
        .any(|j| j.id == job_id && j.open_decision().is_some())
}

/// Handle `mother.resume_job({ id, answer })`.
pub async fn resume_job(state: &McpSharedState, args: &Value) -> Value {
    let job_id = match args.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing id" }),
    };
    let answer = match args.get("answer").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing answer" }),
    };

    if state.daemon.is_some() {
        // A structured hold is the operator's choice, made in Nostromo's Mother panel. An agent can't
        // answer it here (it can still run `mother resume --option` itself; Mother records that as `cli`).
        // The reply says nothing about the job.
        if has_open_decision(state, &job_id) {
            return json!({
                "error": "needs_operator_choice",
                "detail": "This Mother hold needs the operator's choice in Nostromo's Mother panel.",
            });
        }
        return daemon_mutation(state, mother::resume(&job_id, &answer)).await;
    }

    json!({ "error": "not_supported", "detail": "requires nostromd" })
}
