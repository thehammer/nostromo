//! Global `nostromo.*` meta tools available from any view.
//!
//! ## Tools
//! - `nostromo.get_worktree_info()` — git repo / worktree info for the PTY's cwd
//! - `nostromo.get_rate_limits()` — latest `RateLimits` snapshot
//! - `nostromo.get_budget_posture()` — latest `BudgetPosture` snapshot

use std::time::Duration;

use serde_json::{json, Value};
use tokio::process::Command;

use crate::mcp::state::McpSharedState;

/// Handle `nostromo.get_worktree_info()`.
///
/// Shells out to `git` with a 2-second timeout.  Returns structured JSON on
/// success, or `{"error": "git_timeout"}` / `{"error": "not_a_git_repo"}` on
/// failure.  Never panics.
pub async fn get_worktree_info(cwd: Option<&str>) -> Value {
    let work_dir = cwd.unwrap_or(".");

    let toplevel = match run_git_with_timeout(&["rev-parse", "--show-toplevel"], work_dir).await {
        Ok(out) if !out.is_empty() => out.trim().to_owned(),
        Ok(_) => return json!({ "error": "not_a_git_repo" }),
        Err(e) => return e,
    };

    let branch = match run_git_with_timeout(&["symbolic-ref", "--short", "HEAD"], &toplevel).await {
        Ok(out) => out.trim().to_owned(),
        Err(_) => "(detached HEAD)".to_owned(),
    };

    // Detect if we're in a `git worktree` (not the main worktree).
    // `git worktree list --porcelain` lists all worktrees; the main one has
    // `bare` or is first with no `worktree` prefix — we check if our cwd
    // resolves to a non-main worktree by comparing to the common dir.
    let common_dir = match run_git_with_timeout(&["rev-parse", "--git-common-dir"], &toplevel).await
    {
        Ok(out) => out.trim().to_owned(),
        Err(_) => String::new(),
    };
    let git_dir = match run_git_with_timeout(&["rev-parse", "--git-dir"], &toplevel).await {
        Ok(out) => out.trim().to_owned(),
        Err(_) => String::new(),
    };

    // In a linked worktree, `--git-dir` is inside `.git/worktrees/<name>` but
    // `--git-common-dir` points to the main `.git`.  They differ iff we're in a
    // linked worktree.
    let is_worktree = !common_dir.is_empty()
        && !git_dir.is_empty()
        && common_dir != git_dir
        && common_dir != ".";

    // Parent repo: the toplevel of the main worktree, which is one level up from
    // the common .git dir when it ends with `.git`.
    let parent_repo = if is_worktree {
        let p = std::path::Path::new(&common_dir);
        p.parent()
            .and_then(|p2| p2.to_str())
            .unwrap_or("")
            .to_owned()
    } else {
        toplevel.clone()
    };

    json!({
        "cwd": work_dir,
        "branch": branch,
        "parent_repo": parent_repo,
        "is_worktree": is_worktree,
    })
}

/// Handle `nostromo.get_rate_limits()`.
pub fn get_rate_limits(state: &McpSharedState) -> Value {
    match state.rate_limits_rx.borrow().as_ref() {
        Some(rl) => serde_json::to_value(rl).unwrap_or_else(|e| {
            json!({ "error": "serialization_failed", "detail": e.to_string() })
        }),
        None => Value::Null,
    }
}

/// Handle `nostromo.get_budget_posture()`.
pub fn get_budget_posture(state: &McpSharedState) -> Value {
    match state.budget_posture_rx.borrow().as_ref() {
        Some(p) => serde_json::to_value(p).unwrap_or_else(|e| {
            json!({ "error": "serialization_failed", "detail": e.to_string() })
        }),
        None => Value::Null,
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Run a `git` subcommand in `work_dir` with a 2-second timeout.
///
/// Returns the trimmed stdout on success, or a structured error `Value` on
/// timeout, non-zero exit, or OS error.
async fn run_git_with_timeout(args: &[&str], work_dir: &str) -> Result<String, Value> {
    let fut = Command::new("git")
        .args(args)
        .current_dir(work_dir)
        .output();

    match tokio::time::timeout(Duration::from_secs(2), fut).await {
        Ok(Ok(out)) => {
            if out.status.success() {
                Ok(String::from_utf8_lossy(&out.stdout).into_owned())
            } else {
                Err(json!({ "error": "not_a_git_repo" }))
            }
        }
        Ok(Err(e)) => Err(json!({ "error": "git_exec_failed", "detail": e.to_string() })),
        Err(_) => Err(json!({ "error": "git_timeout" })),
    }
}
