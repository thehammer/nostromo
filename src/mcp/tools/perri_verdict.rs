//! `perri.record_verdict({ repo, pr, head_sha, verdict, note? })`: Perri says
//! what it thinks of one commit of a pull request.
//!
//! It **only records** (in the daemon's verdict store, see
//! `data::authored_prs::verdicts`). It never merges and never talks to GitHub:
//! the Overview's Merge button reads the record, and the merge itself has its
//! own guarded verb.
//!
//! Who may call it: any session of the operator's own focuses. A session a
//! network peer is steering is refused at dispatch (the tool is withheld from
//! it, like the Teri, Fred, Mother and Huey tools), so a record never comes
//! from a network peer. No free-form fields: an unknown argument is refused.
//!
//! Errors: `invalid_args` (with a fixed `detail`), `unidentified_caller` (no
//! focus to attribute the record to), `not_supported` (no daemon, or the
//! authored-PR list is off).

use serde_json::{json, Value};

use crate::data::authored_prs::snapshot::valid_repo;
use crate::data::authored_prs::verdicts::{is_full_sha, Verdict, MAX_NOTE};
use crate::mcp::state::McpSharedState;

const ARGS: [&str; 5] = ["repo", "pr", "head_sha", "verdict", "note"];

fn invalid(detail: &str) -> Value {
    json!({ "error": "invalid_args", "detail": detail })
}

/// Handle `perri.record_verdict`.
pub async fn record_verdict(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(obj) = args.as_object() else {
        return invalid("arguments must be an object");
    };
    if obj.keys().any(|k| !ARGS.contains(&k.as_str())) {
        return invalid("unknown argument");
    }
    let repo = match obj.get("repo").and_then(Value::as_str) {
        Some(r) if valid_repo(r) => r,
        _ => return invalid("repo must be owner/name"),
    };
    let number = match obj.get("pr").and_then(Value::as_u64) {
        Some(n) if n > 0 => n,
        _ => return invalid("pr must be a positive integer"),
    };
    let head_sha = match obj.get("head_sha").and_then(Value::as_str) {
        Some(s) if is_full_sha(s) => s,
        _ => return invalid("head_sha must be 40 lowercase hex digits"),
    };
    let verdict = match obj
        .get("verdict")
        .and_then(Value::as_str)
        .and_then(Verdict::parse)
    {
        Some(v) => v,
        None => return invalid("verdict must be approved, changes_requested or comment"),
    };
    let note = match obj.get("note") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.chars().count() <= MAX_NOTE => Some(s.as_str()),
        Some(Value::String(_)) => return invalid("note is too long"),
        Some(_) => return invalid("note must be a string"),
    };

    let Some(tag) = pty_id.filter(|t| !t.is_empty()) else {
        return json!({
            "error": "unidentified_caller",
            "detail": "a verdict is recorded for the calling focus; no focus could be identified"
        });
    };
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "requires nostromd" });
    };
    let actions = daemon.session_mgr.lock().unwrap().authored_pr_actions();
    let Some(actions) = actions else {
        return json!({ "error": "not_supported", "detail": "the authored-PR list is off" });
    };

    let agent = crate::mcp::tool_policy::resolve_agent_name(state, pty_id)
        .await
        .filter(|a| !a.is_empty());
    let by = match agent {
        Some(a) => format!("{a}:{tag}"),
        None => tag.to_owned(),
    };
    match actions.record_verdict(repo, number, head_sha, verdict, Some(&by), note) {
        Ok(matches) => json!({
            "ok": true,
            "recorded": {
                "repo": repo.to_ascii_lowercase(),
                "pr": number,
                "head_sha": head_sha,
                "verdict": verdict.as_str(),
            },
            "matches_current_head": match matches {
                Some(m) => json!(m),
                None => json!("unknown"),
            },
        }),
        Err(_) => invalid("not a valid record"),
    }
}
