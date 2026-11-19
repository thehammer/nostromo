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
//! The caller must be a **registered** focus (its tag is in the focus registry);
//! the record says which (`by` is `<agent>:<tag>`). The tag is self-declared: a
//! local process on the user's account can still claim a registered one, so the
//! record shows who, it does not prove who. The merge's real gates are the
//! user's click, GitHub's CLEAN state and branch protection.
//!
//! An `approved` is only recorded for the head the daemon holds for the PR (one
//! refresh is asked for when it differs); `changes_requested` and `comment` can
//! only block, so they are recorded for any head, flagged `for_current_head`.
//!
//! Errors: `invalid_args` (with a fixed `detail`), `unidentified_caller` (the
//! caller is no registered focus), `pr_unknown`, `head_not_current` (an
//! `approved` for a commit the daemon does not hold as the PR's head),
//! `not_supported` (no daemon, or the authored-PR list is off).

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

    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "requires nostromd" });
    };
    // The caller is a registered focus: a tag that matches none (a stray local
    // process claiming a name) records nothing. Self-declared, so this is a
    // record of who, not a proof of who (see the module docs).
    let focus = pty_id.filter(|t| !t.is_empty()).and_then(|tag| {
        let mgr = daemon.session_mgr.lock().unwrap();
        mgr.focus_registry().into_iter().find(|f| f.tag == tag)
    });
    let Some(focus) = focus else {
        return json!({
            "error": "unidentified_caller",
            "detail": "a verdict is recorded for a registered focus; the caller is none"
        });
    };
    let actions = daemon.session_mgr.lock().unwrap().authored_pr_actions();
    let Some(actions) = actions else {
        return json!({ "error": "not_supported", "detail": "the authored-PR list is off" });
    };

    let by = if focus.agent_name.is_empty() {
        focus.tag.clone()
    } else {
        format!("{}:{}", focus.agent_name, focus.tag)
    };
    match actions
        .record_verdict(repo, number, head_sha, verdict, Some(&by), note)
        .await
    {
        Ok(for_current_head) => json!({
            "ok": true,
            "recorded": {
                "repo": repo.to_ascii_lowercase(),
                "pr": number,
                "head_sha": head_sha,
                "verdict": verdict.as_str(),
            },
            "for_current_head": for_current_head,
        }),
        Err(code @ ("pr_unknown" | "head_not_current")) => json!({
            "error": code,
            "detail": match code {
                "pr_unknown" => "the PR is not in the daemon's list of open PRs",
                _ => "the daemon does not hold that commit as the PR's head; \
                      an approval is only recorded for the current head",
            },
        }),
        Err(_) => invalid("not a valid record"),
    }
}
