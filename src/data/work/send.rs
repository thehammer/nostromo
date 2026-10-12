//! Send a work item to a new focus or a Mother job (design contract §7).
//!
//! [`preview`] computes the defaults the Mac's confirmation sheet shows;
//! [`send`] turns the confirmed sheet into a `CreateFocusRequest` and hands it
//! to `create_focus_core`'s engine, so the Mac sheet and the MCP tool share
//! one set of rules (item-keyed duplicate protection, tag collisions, org
//! inference, the sent ledger, the Mother brief).
//!
//! Two kinds of text reach the agent and they are never mixed. The user's own
//! words (the sheet's editable `instruction`) are the directive. The item's
//! text (title, fields, markdown, links, the pick's reason) is third-party: the
//! daemon rebuilds it from the hub item by id at send time and `create_focus`
//! fences it; the client only ever sees it read-only in the preview and cannot
//! send any of it back.
//!
//! Nothing here is reachable from a network peer: the server refuses
//! `WorkSendPreviewRequest`/`WorkSend` over TCP before they get this far.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::hub::WorkHub;
use super::model::{SendOutcome, SendPreview, WorkDetail, WorkError, WorkItem, WorkSource};
use super::service::{SendRequest, WorkService};
use super::untrusted::one_line;
use crate::mcp::tools::create_focus::{
    create_focus_on, CreateFocusRequest, Destination, FocusHost, OutcomeKind, SourceItemRef,
};

/// Longest label the preview derives from a title (sidebar width).
const MAX_LABEL_CHARS: usize = 32;

/// What the sheet's instruction starts as, and what an empty one becomes.
pub const DEFAULT_INSTRUCTION: &str = "Propose an approach before changing anything.";

/// How long the answer to a send is remembered for its request id: long enough
/// for a client that timed out to retry, short enough to forget.
const RECENT_SEND_WINDOW: Duration = Duration::from_secs(600);

/// Answers to recent sends, by (item, request id). A retry of a send the daemon
/// already handled (or is still handling) gets that answer instead of a second
/// focus or job: the Mac reuses the request id when it retries after a timeout.
/// Errors are not remembered, so a retry of a failed send runs again.
#[derive(Default)]
pub(crate) struct RecentSends {
    cells: Mutex<HashMap<String, RecentSend>>,
}

/// When a send was first seen, and the answer once there is one.
type RecentSend = (Instant, Arc<tokio::sync::OnceCell<SendOutcome>>);

impl RecentSends {
    async fn run<F>(&self, key: String, send: F) -> Result<SendOutcome, WorkError>
    where
        F: std::future::Future<Output = Result<SendOutcome, WorkError>>,
    {
        let cell = {
            let mut cells = self.cells.lock().unwrap();
            cells.retain(|_, (at, _)| at.elapsed() < RECENT_SEND_WINDOW);
            Arc::clone(&cells.entry(key).or_insert_with(|| (Instant::now(), Arc::default())).1)
        };
        cell.get_or_try_init(|| send).await.cloned()
    }
}

/// Defaults for sending `item_id`: agent, project, label, the default
/// instruction and (read-only) what the agent will also be given, plus the
/// markers that make a resend a duplicate, judged as `send` will judge them.
pub async fn preview(hub: &WorkHub, item_id: &str) -> Result<SendPreview, WorkError> {
    let item = hub.item(item_id).ok_or_else(unknown_item)?;
    let detail = hub.detail(item_id).await?;
    let working_directory = suggested_directory(hub, &item).await;
    Ok(SendPreview {
        item_id: item.id.clone(),
        agent: suggested_agent(&item).to_owned(),
        working_directory: working_directory.map(|p| p.to_string_lossy().into_owned()),
        label: suggested_label(&item),
        instruction: DEFAULT_INSTRUCTION.to_owned(),
        context: shared_material(hub, &item, &detail),
        existing: hub.live_markers_for_send(&item.id),
    })
}

/// Create the focus or queue the Mother job the sheet asked for.
pub async fn send(hub: &WorkHub, request: SendRequest) -> Result<SendOutcome, WorkError> {
    if request.request_id.is_empty() {
        return send_once(hub, request).await;
    }
    let key = format!("{}\0{}", request.item_id, request.request_id);
    hub.recent_sends().run(key, send_once(hub, request)).await
}

async fn send_once(hub: &WorkHub, request: SendRequest) -> Result<SendOutcome, WorkError> {
    let destination = match request.destination.as_str() {
        "focus" => Destination::Focus,
        "mother_job" => Destination::MotherJob { max_cost: None },
        other => {
            return Err(WorkError::new(
                "invalid_args",
                format!("destination must be \"focus\" or \"mother_job\", not \"{}\"", one_line(other, 40)),
            ))
        }
    };
    let item = hub.item(&request.item_id).ok_or_else(unknown_item)?;
    let ctx = hub.context();
    let session_mgr = ctx.session_mgr.clone().ok_or_else(WorkError::not_available)?;
    let host = FocusHost { session_mgr, broadcast_tx: ctx.broadcast_tx.clone() };

    let label = match request.label.trim() {
        "" => suggested_label(&item),
        label => label.to_owned(),
    };
    let working_directory = request
        .working_directory
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(PathBuf::from);
    // The item's text is rebuilt here, from the hub, never taken from the
    // client: whatever the client sends is only ever the user's instruction.
    let detail = hub.detail(&item.id).await?;
    let initial_context = Some(shared_material(hub, &item, &detail));
    let instruction = match request.instruction.trim() {
        "" => DEFAULT_INSTRUCTION.to_owned(),
        _ => request.instruction,
    };

    let core_request = CreateFocusRequest {
        agent: request.agent,
        title: label.clone(),
        label: Some(label),
        org: None,
        working_directory,
        initial_context,
        instruction: Some(instruction),
        source_item: Some(SourceItemRef { id: item.id.clone(), title: item.title.clone() }),
        allow_duplicate: request.allow_duplicate,
        destination,
        select_for_client: request.client_id,
        caller: None,
    };
    let outcome = create_focus_on(host, core_request)
        .await
        .map_err(|e| WorkError::new(e.code(), e.detail()))?;
    let kind = match outcome.kind {
        OutcomeKind::Created => "created",
        OutcomeKind::Existing => "existing",
        OutcomeKind::Queued => "mother_job",
    };
    Ok(SendOutcome { kind: kind.to_owned(), focus_tag: outcome.focus_tag, job_id: outcome.job_id })
}

fn unknown_item() -> WorkError {
    WorkError::new("unknown_item", "That item is no longer in Teri's list")
}

/// `debbie` investigates errors; everything else goes to `claudia`.
fn suggested_agent(item: &WorkItem) -> &'static str {
    let is_bug_doc = item.source == WorkSource::RepoDocs && item.kind == "bug";
    if item.source == WorkSource::Sentry || is_bug_doc {
        "debbie"
    } else {
        "claudia"
    }
}

/// The Jira key, the Sentry short id, else the title shortened for the sidebar.
fn suggested_label(item: &WorkItem) -> String {
    let short_id = match item.source {
        WorkSource::Jira => item.id.strip_prefix("jira:").map(str::to_owned),
        WorkSource::Sentry => item.linked.first().cloned(),
        _ => None,
    };
    let label = short_id.map(|id| one_line(&id, MAX_LABEL_CHARS)).filter(|l| !l.is_empty());
    label.unwrap_or_else(|| one_line(&item.title, MAX_LABEL_CHARS))
}

/// Repo docs: the item's own repo. Sentry: the repo the project maps to.
/// Jira and todos have none (the Mac fills it from its most-recently-used list).
/// Only a directory that exists is suggested, so Start never fails on a path
/// the user did not choose.
async fn suggested_directory(hub: &WorkHub, item: &WorkItem) -> Option<PathBuf> {
    let repo = match item.source {
        WorkSource::RepoDocs => item.repo.clone(),
        WorkSource::Sentry => sentry_repo(hub, item).await,
        WorkSource::Jira | WorkSource::Todos => None,
    }?;
    // A mapping file or a doc id names a directory under the code root, never a path.
    if repo.is_empty() || repo.starts_with('.') || repo.contains(['/', '\\', '\0']) {
        return None;
    }
    let dir = hub.repo_docs_root().join(repo);
    dir.is_dir().then_some(dir)
}

async fn sentry_repo(hub: &WorkHub, item: &WorkItem) -> Option<String> {
    if let (Some(path), Some(project)) = (hub.sentry_repos_path(), item.project.as_deref()) {
        if let Some(repo) = super::sentry::read_repos(path).await.get(project) {
            return Some(repo.clone());
        }
    }
    item.repo.clone()
}

/// The item's own text, as the agent will be given it (fenced as untrusted
/// data by `create_focus`) and as the sheet shows it read-only: where it came
/// from, the whole item as the detail view shows it, and why Teri picked it.
fn shared_material(hub: &WorkHub, item: &WorkItem, detail: &WorkDetail) -> String {
    let reason = hub.picks().snapshot().items.into_iter().find(|p| p.item_id == item.id).map(|p| p.reason);
    material_for(item, detail, reason.as_deref())
}

fn material_for(item: &WorkItem, detail: &WorkDetail, pick_reason: Option<&str>) -> String {
    let mut origin = vec![format!("Source: {}", item.source.as_str())];
    if let Some(repo) = &item.repo {
        origin.push(format!("Repo: {repo}"));
    }
    if let Some(project) = &item.project {
        origin.push(format!("Project: {project}"));
    }
    if let Some(path) = &item.path {
        origin.push(format!("Path: {path}"));
    } else if let Some(url) = &item.url {
        origin.push(format!("Link: {url}"));
    }

    let mut out = format!("{}\n\nTitle: {}\n", origin.join(" · "), item.title);
    if let Some(reason) = pick_reason.filter(|r| !r.trim().is_empty()) {
        // Written by Teri's picks session from third-party text: data, like the rest.
        out.push_str(&format!("Why Teri picked this: {reason}\n"));
    }
    if item.source == WorkSource::Sentry {
        if let Some(short_id) = item.linked.first() {
            out.push_str(&format!("Short id: {short_id}\n"));
        }
    }
    for (label, value) in &detail.fields {
        out.push_str(&format!("{label}: {value}\n"));
    }
    if !detail.markdown.trim().is_empty() {
        out.push('\n');
        out.push_str(detail.markdown.trim_end());
        out.push('\n');
    }
    let others: Vec<&String> = detail.files.iter().filter(|f| !is_index(f)).collect();
    if !others.is_empty() {
        out.push_str("\nOther files in this folder:\n");
        for file in others {
            out.push_str(&format!("- {file}\n"));
        }
    }
    let links: Vec<String> = detail
        .links
        .iter()
        .filter(|l| !out.contains(&l.url))
        .map(|l| format!("- {}: {}", l.label, l.url))
        .collect();
    if !links.is_empty() {
        out.push_str("\nLinks:\n");
        out.push_str(&links.join("\n"));
        out.push('\n');
    }
    out
}

fn is_index(file: &str) -> bool {
    Path::new(file).file_name().is_some_and(|n| n == "index.md")
}
