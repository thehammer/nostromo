//! The hand-off verbs of the author's PR list: preview a message, send it to a
//! focus, start a session with it, link a PR to a focus.
//!
//! The caller (the server) has already checked that the peer is the verified
//! operator app. Every message is **recomposed here from current facts**; the
//! client only echoes a digest of what it showed, and nothing is sent when it
//! no longer matches. Answers carry codes only. Nothing in this module logs.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::data::authored_prs::actions::AuthoredPrActions;
use crate::data::authored_prs::snapshot::{AuthoredPr, MAX_NAME};
use crate::data::authored_prs::wire::{AuthoredPrResult, Done, PreviewOk, PreviewTarget, StartOk};
use crate::data::work::untrusted::one_line;
use crate::ipc::protocol::FocusMeta;
use crate::ipc::SessionManager;
use crate::mcp::tools::create_focus::{
    create_focus_on, CreateFocusRequest, FocusHost, OutcomeKind,
};

type Mgr = Arc<Mutex<SessionManager>>;

fn open_focus(mgr: &Mgr, tag: &str) -> Option<FocusMeta> {
    mgr.lock()
        .unwrap()
        .focus_registry()
        .into_iter()
        .find(|f| f.tag == tag)
}

fn names_tag(row: &AuthoredPr, tag: &str) -> bool {
    row.owner.tag.as_deref() == Some(tag)
        || row.owner.candidates.iter().any(|c| c.tag == tag)
        || row.told.as_ref().is_some_and(|t| t.tag == tag)
}

/// The message for `repo#number`, for an open focus or a new session.
pub fn preview(
    actions: &AuthoredPrActions,
    mgr: &Mgr,
    repo: &str,
    number: u64,
    target: &PreviewTarget,
) -> AuthoredPrResult<PreviewOk> {
    let composed = match actions.compose_for(repo, number) {
        Ok(c) => c,
        Err(code) => return AuthoredPrResult::err(code),
    };
    let last_told = AuthoredPrActions::last_told(&composed.row);
    let mut ok = PreviewOk {
        text: composed.text,
        digest: composed.digest,
        target_name: String::new(),
        last_told,
        suggested_folder: None,
        suggested_agent: None,
    };
    match target {
        PreviewTarget::Focus { tag } => match open_focus(mgr, tag) {
            Some(f) => ok.target_name = one_line(&f.display_name, MAX_NAME),
            None if names_tag(&composed.row, tag) => return AuthoredPrResult::err("owner_closed"),
            None => return AuthoredPrResult::err("unknown_focus"),
        },
        PreviewTarget::NewSession { new_session: true } => {
            let (history, open_projects): (_, Vec<PathBuf>) = {
                let g = mgr.lock().unwrap();
                (
                    g.session_history(),
                    g.focus_registry()
                        .into_iter()
                        .filter_map(|f| f.project_path.map(PathBuf::from))
                        .collect(),
                )
            };
            ok.suggested_folder = actions.suggest_folder(&composed.row, &history, &open_projects);
            ok.suggested_agent = actions.suggest_agent(&composed.row);
        }
        PreviewTarget::NewSession { new_session: false } => {
            return AuthoredPrResult::err("unknown_focus")
        }
    }
    AuthoredPrResult::Ok(ok)
}

/// Send the message to the open focus `tag`, behind a running turn, and record
/// that it was told. Nothing is recorded unless the message was written or queued.
pub fn notify(
    actions: &AuthoredPrActions,
    mgr: &Mgr,
    repo: &str,
    number: u64,
    tag: &str,
    digest: &str,
) -> AuthoredPrResult<Done> {
    if open_focus(mgr, tag).is_none() {
        return AuthoredPrResult::err("owner_closed");
    }
    let composed = match actions.compose_for(repo, number) {
        Ok(c) => c,
        Err(code) => return AuthoredPrResult::err(code),
    };
    if composed.digest != digest {
        return AuthoredPrResult::err("changed");
    }
    {
        let mut g = mgr.lock().unwrap();
        if g.ensure_session(tag).is_err() || g.send_user_message(tag, &composed.text, &[]).is_err()
        {
            return AuthoredPrResult::err("not_running");
        }
    }
    actions.record_told(&composed.row, tag);
    AuthoredPrResult::Ok(Done {})
}

/// Create one focus in `folder`, give it the message as its first operator
/// message, link the PR to it and record that it was told.
#[allow(clippy::too_many_arguments)]
pub async fn start_session(
    actions: &AuthoredPrActions,
    host: FocusHost,
    client_id: &str,
    request_id: &str,
    repo: &str,
    number: u64,
    folder: &str,
    agent: &str,
    digest: &str,
) -> AuthoredPrResult<StartOk> {
    let _one_at_a_time = actions.start_gate.lock().await;
    if let Some(earlier) = actions.remembered_start(request_id) {
        return earlier;
    }
    let result = start_once(
        actions, host, client_id, repo, number, folder, agent, digest,
    )
    .await;
    actions.remember_start(request_id, &result);
    result
}

#[allow(clippy::too_many_arguments)]
async fn start_once(
    actions: &AuthoredPrActions,
    host: FocusHost,
    client_id: &str,
    repo: &str,
    number: u64,
    folder: &str,
    agent: &str,
    digest: &str,
) -> AuthoredPrResult<StartOk> {
    let composed = match actions.compose_for(repo, number) {
        Ok(c) => c,
        Err(code) => return AuthoredPrResult::err(code),
    };
    if composed.digest != digest {
        return AuthoredPrResult::err("changed");
    }
    let dir = PathBuf::from(folder);
    if !dir.is_absolute() || !dir.is_dir() {
        return AuthoredPrResult::err("bad_folder");
    }
    if !actions.agent_is_known(agent) {
        return AuthoredPrResult::err("unknown_agent");
    }
    // No instruction: the create path would wrap it in its own framing, and the
    // first message must be byte-identical to the preview. The message goes in
    // below, through the same send as a notify.
    let outcome = match create_focus_on(
        host.clone(),
        CreateFocusRequest {
            agent: agent.to_owned(),
            title: format!("PR {}#{}", composed.row.repo, composed.row.number),
            // The title names the PR, and a tag is logged: give the focus a tag that does not.
            tag_override: Some(format!(
                "{}-pr-{}",
                agent.to_ascii_lowercase(),
                &uuid::Uuid::new_v4().simple().to_string()[..8]
            )),
            working_directory: Some(dir),
            select_for_client: Some(client_id.to_owned()),
            queued_by_app: true,
            ..Default::default()
        },
    )
    .await
    {
        Ok(o) => o,
        Err(_) => return AuthoredPrResult::err("start_failed"),
    };
    let Some(tag) = outcome
        .focus_tag
        .filter(|_| outcome.kind == OutcomeKind::Created)
    else {
        return AuthoredPrResult::err("already_open");
    };
    {
        let mut g = host.session_mgr.lock().unwrap();
        if g.send_user_message(&tag, &composed.text, &[]).is_err() {
            g.stop(&tag);
            return AuthoredPrResult::err("not_running");
        }
    }
    actions.set_link(&composed.row.repo, composed.row.number, Some(&tag));
    actions.record_told(&composed.row, &tag);
    AuthoredPrResult::Ok(StartOk { tag })
}

/// Link the PR to the open focus `tag`, or unlink it.
pub fn link(
    actions: &AuthoredPrActions,
    mgr: &Mgr,
    repo: &str,
    number: u64,
    tag: Option<&str>,
) -> AuthoredPrResult<Done> {
    if let Some(tag) = tag {
        if open_focus(mgr, tag).is_none() {
            return AuthoredPrResult::err("unknown_focus");
        }
    }
    if !actions.set_link(repo, number, tag) {
        return AuthoredPrResult::err("unknown_pr");
    }
    AuthoredPrResult::Ok(Done {})
}
