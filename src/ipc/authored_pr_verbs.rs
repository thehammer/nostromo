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
use crate::data::authored_prs::is_tellable_focus;
use crate::data::authored_prs::snapshot::{AuthoredPr, MAX_NAME};
use crate::data::authored_prs::wire::{AuthoredPrResult, Done, PreviewOk, PreviewTarget, StartOk};
use crate::data::work::untrusted::one_line;
use crate::ipc::protocol::FocusMeta;
use crate::ipc::SessionManager;
use crate::mcp::tools::create_focus::{
    create_focus_on, CreateFocusRequest, FocusHost, OutcomeKind,
};

type Mgr = Arc<Mutex<SessionManager>>;

/// An open focus the hand-off may write to. Never a built-in (Fred, Teri, Huey, Mother, Perri) or a focus
/// running a sensitive agent: those hold mail, calendar or notes, and a PR notice has no business there.
fn open_focus(mgr: &Mgr, tag: &str) -> Option<FocusMeta> {
    mgr.lock()
        .unwrap()
        .focus_registry()
        .into_iter()
        .find(|f| f.tag == tag)
        .filter(|f| is_tellable_focus(f.is_built_in, &f.agent_name))
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
    // A fresh preview is a fresh chance to send.
    actions.rearm_sends(&composed.row.repo, composed.row.number);
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

/// Send the message to the open focus `tag`, behind a running turn. It is
/// recorded as told only once the session has really been given it: a message
/// queued behind a running turn that the user then stops never arrives, and
/// must leave the pill up. Each preview is good for one send: a replay answers
/// `already_sent` and delivers nothing.
pub fn notify(
    actions: &Arc<AuthoredPrActions>,
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
    if !actions.claim_send(&composed.row.repo, composed.row.number, tag, digest) {
        return AuthoredPrResult::err("already_sent");
    }
    let delivered = {
        let (actions, row, tag) = (Arc::clone(actions), composed.row.clone(), tag.to_owned());
        move || actions.record_told(&row, &tag)
    };
    // The manager lock is held across `ensure_session` (which may start the
    // session's process) and the send, as it is for every spawn, restart and
    // send in the daemon: `spawn_session` needs `&mut SessionManager`, so it
    // cannot run with the lock released. Nothing here waits on the turn: the
    // message is written to a pipe or queued, and a restart's wait for an
    // in-flight write is capped at `WRITE_WAIT_LIMIT` (5 s), as for the user's
    // own restart. The slow part, the CLI starting, is the child's, not ours.
    let sent = {
        let mut g = mgr.lock().unwrap();
        g.ensure_session(tag).is_ok()
            && g.send_user_message_then(tag, &composed.text, delivered)
                .is_ok()
    };
    if !sent {
        actions.release_send(&composed.row.repo, composed.row.number, tag, digest);
        return AuthoredPrResult::err("not_running");
    }
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
    if !actions.claim_send(&composed.row.repo, composed.row.number, "new", digest) {
        return AuthoredPrResult::err("already_sent");
    }
    // No instruction: the create path would wrap it in its own framing, and the
    // first message must be byte-identical to the preview, so it goes in as
    // `first_message`, which is sent as it is.
    let outcome = match create_focus_on(
        host.clone(),
        CreateFocusRequest {
            agent: agent.to_owned(),
            title: format!("PR {}#{}", composed.row.repo, composed.row.number),
            working_directory: Some(dir),
            select_for_client: Some(client_id.to_owned()),
            queued_by_app: true,
            // Delivered as the first message, unframed, before the focus is announced: a send that fails
            // leaves no focus behind.
            first_message: Some(composed.text.clone()),
            // The title names the PR, and a tag is logged: give the focus a tag that does not.
            tag_override: Some(format!(
                "{}-pr-{}",
                agent.to_ascii_lowercase(),
                &uuid::Uuid::new_v4().simple().to_string()[..8]
            )),
            ..Default::default()
        },
    )
    .await
    {
        Ok(o) => o,
        Err(_) => {
            actions.release_send(&composed.row.repo, composed.row.number, "new", digest);
            return AuthoredPrResult::err("start_failed");
        }
    };
    let Some(tag) = outcome
        .focus_tag
        .filter(|_| outcome.kind == OutcomeKind::Created)
    else {
        actions.release_send(&composed.row.repo, composed.row.number, "new", digest);
        return AuthoredPrResult::err("already_open");
    };
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
