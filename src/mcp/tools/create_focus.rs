//! `nostromo.create_focus` and the core it shares with the Mac's Send to agent
//! path (`WorkSend`).
//!
//! [`create_focus_core`] creates a persistent daemon-hosted focus running a
//! named agent persona (seeding its first turn with `initial_context`,
//! registering it and broadcasting `FocusCreated`), or queues a Mother job
//! instead. When the request names a source work item it is keyed on that item,
//! not on the title: a live focus or Mother job already sent for the item is
//! returned as `Existing` and nothing is created, unless `allow_duplicate`.
//! The MCP handler [`create_focus`] is a thin adapter over the core.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::Utc;
use serde_json::{json, Value};

use crate::data::work::model::SentMarker;
use crate::data::work::sent;
use crate::ipc::protocol::{FocusMeta, PaneTree, ServerMsg};
use crate::mcp::state::{DaemonMcpBackend, McpSharedState};
use crate::mother::AddJobRequest;

/// The work item a focus or job was started from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceItemRef {
    /// `todo:<id>` | `doc:<repo>:<path>` | `jira:<KEY>` | `sentry:<id>`.
    pub id: String,
    pub title: String,
}

/// Where the work goes.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum Destination {
    /// A new focus running `agent` (the default).
    #[default]
    Focus,
    /// An unattended Mother job. `max_cost` defaults to [`DEFAULT_MOTHER_MAX_COST`].
    MotherJob { max_cost: Option<f64> },
}

/// Mother job budget (USD) when the caller gives none.
pub const DEFAULT_MOTHER_MAX_COST: f64 = 10.0;

#[derive(Debug, Clone, Default)]
pub struct CreateFocusRequest {
    pub agent: String,
    pub title: String,
    /// User-facing label (Jira key, doc title…). Defaults to the title for
    /// markers and the outcome; `FocusMeta.label` stays `None` when absent.
    pub label: Option<String>,
    /// Org section; inferred from the repo's GitHub remote when absent.
    pub org: Option<String>,
    /// Absolute, existing directory.
    pub working_directory: Option<PathBuf>,
    pub initial_context: Option<String>,
    pub source_item: Option<SourceItemRef>,
    /// Create even though a live focus/job exists for `source_item`.
    pub allow_duplicate: bool,
    pub destination: Destination,
    /// `client_id` whose windows should select the new focus.
    pub select_for_client: Option<String>,
    /// MCP pty id of the calling session (its focus tag), so a focus spawned
    /// by a sensitive (Teri/Fred) or network-driven session inherits that.
    pub caller: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutcomeKind {
    Created,
    Existing,
    Queued,
}

impl OutcomeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            OutcomeKind::Created => "created",
            OutcomeKind::Existing => "existing",
            OutcomeKind::Queued => "queued",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateFocusOutcome {
    pub kind: OutcomeKind,
    /// The focus tag (`Created`, or `Existing` for a focus).
    pub focus_tag: Option<String>,
    /// The Mother job id (`Queued`, or `Existing` for a job).
    pub job_id: Option<String>,
    /// The label shown in "sent to <label>": the request's label, else its title.
    pub label: String,
}

/// A refusal, with a stable snake_case `code()` for MCP and `WorkSend`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CreateFocusError {
    InvalidArgs(String),
    InvalidWorkingDirectory(String),
    /// A Mother job needs a working directory.
    ProjectRequired,
    /// A Mother job needs a git repo; carries the directory.
    NotAGitRepo(String),
    SpawnFailed(String),
    /// `mother add` failed, or its brief could not be written.
    MotherFailed(String),
}

impl CreateFocusError {
    pub fn code(&self) -> &'static str {
        match self {
            CreateFocusError::InvalidArgs(_) => "invalid_args",
            CreateFocusError::InvalidWorkingDirectory(_) => "invalid_working_directory",
            CreateFocusError::ProjectRequired => "project_required",
            CreateFocusError::NotAGitRepo(_) => "not_a_git_repo",
            CreateFocusError::SpawnFailed(_) => "spawn_failed",
            CreateFocusError::MotherFailed(_) => "mother_failed",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            CreateFocusError::InvalidArgs(d)
            | CreateFocusError::InvalidWorkingDirectory(d)
            | CreateFocusError::NotAGitRepo(d)
            | CreateFocusError::SpawnFailed(d)
            | CreateFocusError::MotherFailed(d) => d.clone(),
            CreateFocusError::ProjectRequired => {
                "a Mother job needs a working_directory that is a git repo".to_owned()
            }
        }
    }
}

impl std::fmt::Display for CreateFocusError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code(), self.detail())
    }
}

impl std::error::Error for CreateFocusError {}

/// Serializes creation so "is there already one for this item?" and "record the
/// new one" cannot interleave between two callers (an agent and the Mac sheet
/// sending the same item at once must not both create).
static CREATE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// How long a `git` probe (remote, toplevel, default branch) may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(5);

/// Create a focus or Mother job for `req`; see the module docs.
pub async fn create_focus_core(
    daemon: &DaemonMcpBackend,
    req: CreateFocusRequest,
) -> Result<CreateFocusOutcome, CreateFocusError> {
    validate(&req)?;
    let label = non_blank(req.label.as_deref()).unwrap_or(&req.title).to_owned();

    let _serialized = CREATE_LOCK.lock().await;

    if let Some(item) = req.source_item.as_ref().filter(|_| !req.allow_duplicate) {
        if let Some(existing) = live_marker(daemon, &item.id).await {
            return Ok(existing);
        }
    }

    match req.destination {
        Destination::Focus => create_focus_session(daemon, req, label).await,
        Destination::MotherJob { max_cost } => queue_mother_job(req, max_cost, label).await,
    }
}

fn validate(req: &CreateFocusRequest) -> Result<(), CreateFocusError> {
    if req.agent.is_empty() {
        return Err(CreateFocusError::InvalidArgs("missing agent".into()));
    }
    if req.title.is_empty() {
        return Err(CreateFocusError::InvalidArgs("missing title".into()));
    }
    if let Some(cwd) = &req.working_directory {
        if !cwd.is_absolute() || !cwd.is_dir() {
            return Err(CreateFocusError::InvalidWorkingDirectory(cwd.to_string_lossy().into_owned()));
        }
    }
    if let Destination::MotherJob { max_cost: Some(cost) } = &req.destination {
        if !cost.is_finite() || *cost <= 0.0 {
            return Err(CreateFocusError::InvalidArgs("max_cost must be a positive number".into()));
        }
    }
    Ok(())
}

/// The newest live marker for `item_id`, as an `Existing` outcome.
async fn live_marker(daemon: &DaemonMcpBackend, item_id: &str) -> Option<CreateFocusOutcome> {
    let markers = sent::ledger().markers(item_id);
    // Asked of Mother only if a job marker needs it. Unknown (the list failed)
    // counts as live: better to return the existing job than to start a second
    // unattended one (`allow_duplicate` overrides).
    let mut job_ids: Option<Option<HashSet<String>>> = None;
    for marker in markers.into_iter().rev() {
        let live = match marker.kind.as_str() {
            "focus" => daemon.session_mgr.lock().unwrap().has_live_session(&marker.target_id),
            "mother_job" => {
                if job_ids.is_none() {
                    job_ids = Some(sent::mother_job_ids().await);
                }
                job_ids.as_ref().and_then(Option::as_ref).is_none_or(|ids| ids.contains(&marker.target_id))
            }
            _ => false,
        };
        if live {
            let is_focus = marker.kind == "focus";
            return Some(CreateFocusOutcome {
                kind: OutcomeKind::Existing,
                focus_tag: is_focus.then(|| marker.target_id.clone()),
                job_id: (!is_focus).then_some(marker.target_id),
                label: marker.label,
            });
        }
    }
    None
}

async fn create_focus_session(
    daemon: &DaemonMcpBackend,
    req: CreateFocusRequest,
    label: String,
) -> Result<CreateFocusOutcome, CreateFocusError> {
    let CreateFocusRequest {
        agent,
        title,
        label: meta_label,
        org,
        working_directory: cwd,
        initial_context,
        source_item,
        select_for_client,
        caller,
        ..
    } = req;

    // Without a source item the tag is the only identity: a live focus under
    // it is "the same one". With one, a live tag belongs to something else (the
    // same item was handled above), so take the next free suffix.
    let base = derive_tag(&agent, &title);
    let tag = {
        let mgr = daemon.session_mgr.lock().unwrap();
        if !mgr.has_live_session(&base) {
            base
        } else if source_item.is_none() {
            return Ok(CreateFocusOutcome {
                kind: OutcomeKind::Existing,
                focus_tag: Some(base),
                job_id: None,
                label,
            });
        } else {
            first_free_tag(&base, |t| mgr.has_live_session(t))
        }
    };

    let org = resolve_org(org, cwd.as_deref()).await;
    register_sensitivity(daemon, &tag, caller.as_deref(), initial_context.is_some());

    // Spawn the session (no remote control; daemon-hosted stream-json child).
    let spawn = daemon.session_mgr.lock().unwrap().spawn_session(
        tag.clone(),
        agent.clone(),
        title.clone(),
        cwd.clone(),
        None,
        false,
    );
    spawn.map_err(|e| CreateFocusError::SpawnFailed(e.to_string()))?;

    // Note: `spawn_session` already calls `reg.init_focus(&tag)` via the
    // SessionManager's pane registry reference: no explicit init needed here.

    // Seed the first turn with the initial context (best-effort).
    if let Some(ctx) = initial_context {
        let mut mgr = daemon.session_mgr.lock().unwrap();
        if let Err(e) = mgr.send_user_message(&tag, &ctx, &[]) {
            tracing::warn!(tag = %tag, "create_focus: failed to seed initial_context: {e}");
        }
    }

    let meta = FocusMeta {
        tag: tag.clone(),
        display_name: title,
        agent_name: agent,
        project_name: cwd.as_deref().and_then(project_name_from),
        org,
        is_built_in: false,
        session_summary: None,
        label: meta_label.filter(|l| !l.trim().is_empty()),
        project_path: cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
        select_for_client,
    };
    announce_focus(daemon, meta);

    record_sent(source_item.as_ref(), "focus", &tag, &label);
    Ok(CreateFocusOutcome { kind: OutcomeKind::Created, focus_tag: Some(tag), job_id: None, label })
}

/// The request's org, else the one inferred from the working directory's GitHub remote.
async fn resolve_org(org: Option<String>, cwd: Option<&Path>) -> Option<String> {
    if let Some(org) = non_blank(org.as_deref()) {
        return Some(org.to_owned());
    }
    let url = git_output(cwd?, &["remote", "get-url", "origin"]).await?;
    org_from_remote_url(&url)
}

/// Mark the new focus's tag sensitive / network-driven before its session exists,
/// so nothing it says can be sent to a network peer first.
///
/// Seeded context is, in practice, text from a work item (a Jira description, a
/// mail body, a todo), so it makes the focus sensitive. So does being created BY
/// a Teri/Fred session (its title can be a mail subject), context or not; for a
/// daemon-hosted session the calling pty id is the focus tag. A focus spawned by
/// a session a network peer is steering is steered by that peer too: it must not
/// be a way back to the withheld tools.
fn register_sensitivity(daemon: &DaemonMcpBackend, tag: &str, caller: Option<&str>, has_context: bool) {
    let sensitive = daemon.session_mgr.lock().unwrap().sensitive_tags();
    if has_context || caller.is_some_and(|c| sensitive.tag_is_sensitive(c)) {
        sensitive.mark_tag(tag);
    }
    if caller.is_some_and(|c| sensitive.is_network_driven(c)) {
        sensitive.mark_network_driven(tag);
    }
}

/// Register the focus and tell every client about it and its initial layout.
fn announce_focus(daemon: &DaemonMcpBackend, meta: FocusMeta) {
    let tag = meta.tag.clone();
    daemon.session_mgr.lock().unwrap().add_or_update_focus(meta.clone());
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusCreated { meta });
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
        tag,
        tree: PaneTree::repl_leaf(),
        focused_pane: None,
    });
}

async fn queue_mother_job(
    req: CreateFocusRequest,
    max_cost: Option<f64>,
    label: String,
) -> Result<CreateFocusOutcome, CreateFocusError> {
    let cwd = req.working_directory.as_deref().ok_or(CreateFocusError::ProjectRequired)?;
    let repo = git_output(cwd, &["rev-parse", "--show-toplevel"])
        .await
        .map(PathBuf::from)
        .ok_or_else(|| CreateFocusError::NotAGitRepo(cwd.to_string_lossy().into_owned()))?;
    let repo_name = repo
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_owned)
        .ok_or_else(|| CreateFocusError::NotAGitRepo(repo.to_string_lossy().into_owned()))?;
    let base = git_output(&repo, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        .await
        .unwrap_or_else(|| "origin/main".to_owned());

    let slug_source = req.source_item.as_ref().map_or(req.title.as_str(), |i| i.id.as_str());
    let slug: String = slugify(slug_source).chars().take(MAX_SLUG_LEN).collect();
    let slug = match slug.trim_end_matches('-') {
        "" => "item".to_owned(),
        s => s.to_owned(),
    };
    let branch = format!("teri/{slug}");
    let brief = brief_markdown(&label, &req, &repo_name, &branch);
    let plan_file = write_brief(&slug, &brief)
        .map_err(|e| CreateFocusError::MotherFailed(format!("could not write the brief: {e}")))?;

    let job = AddJobRequest {
        plan_file: plan_file.clone(),
        repo: repo_name,
        repo_path: Some(repo.to_string_lossy().into_owned()),
        branch,
        base: Some(base),
        max_cost: Some(max_cost.unwrap_or(DEFAULT_MOTHER_MAX_COST)),
        label: Some("teri-send".to_owned()),
        depends_on: Vec::new(),
    };
    let job_id = match crate::mother::add_job(job).await {
        Ok(id) => id,
        Err(e) => {
            // The brief holds work-item text: do not leave it behind for a job that never existed.
            let _ = std::fs::remove_file(&plan_file);
            return Err(CreateFocusError::MotherFailed(e.to_string()));
        }
    };

    record_sent(req.source_item.as_ref(), "mother_job", &job_id, &label);
    Ok(CreateFocusOutcome { kind: OutcomeKind::Queued, focus_tag: None, job_id: Some(job_id), label })
}

/// Remember that `item` was sent (no item, nothing to key it on).
fn record_sent(item: Option<&SourceItemRef>, kind: &str, target_id: &str, label: &str) {
    let Some(item) = item else { return };
    let marker = SentMarker {
        kind: kind.to_owned(),
        target_id: target_id.to_owned(),
        label: label.to_owned(),
        created_at: Utc::now(),
    };
    if let Err(e) = sent::ledger().record(&item.id, marker) {
        tracing::warn!("create_focus: could not save the sent ledger: {e}");
    }
}

/// The brief Mother's worker sees. Mother reads the FIRST ```yaml block that
/// mentions `suggested_config`, so ours goes before the seeded context: a repo
/// doc that is itself a plan must not be able to supply the job's config.
fn brief_markdown(label: &str, req: &CreateFocusRequest, repo_name: &str, branch: &str) -> String {
    let source = match &req.source_item {
        Some(item) => format!("{} (\"{}\")", item.id, item.title),
        None => format!("\"{}\"", req.title),
    };
    let context = req.initial_context.as_deref().map_or("(no context was supplied)", str::trim);
    let mut config = String::from("suggested_config:\n");
    for (agent, why) in BRIEF_AGENT_RATIONALES {
        config.push_str(&format!(
            "  {agent}:\n    model: sonnet\n    effort: medium\n    rationale: \"{why}\"\n"
        ));
    }
    format!(
        "# {label}\n\n\
         ```yaml\n{config}```\n\n\
         ## Context\n\n\
         This job was started from a work item sent by Teri: {source}.\n\n\
         {context}\n\n\
         ## Target\n\n\
         - Repo: {repo_name}\n\
         - Branch: `{branch}`\n\n\
         ## Approach\n\n\
         Investigate first. If the work is not clearly scoped by the context above, \
         call `mother await` with a proposed approach instead of guessing.\n\n\
         ## Acceptance criteria\n\n\
         - The pull request references the source item ({source}) by id or link.\n\n\
         ## Out of scope\n\n\
         - No changes outside the item's scope.\n"
    )
}

const BRIEF_AGENT_RATIONALES: [(&str, &str); 4] = [
    ("cody", "Implements one bounded work item; sonnet at medium effort is the default for an unattended send."),
    ("redd", "Writes the tests for that one item; sonnet at medium effort is enough."),
    ("marty", "Light refactor pass over the same change; sonnet at medium effort is enough."),
    ("perri", "Reviews the resulting diff against the item; sonnet at medium effort is enough."),
];

/// Write the brief to `<teri dir>/mother-briefs/<slug>-<ts>.md` (dir 0700, file 0600).
fn write_brief(slug: &str, brief: &str) -> std::io::Result<PathBuf> {
    use std::io::Write;
    let dir = sent::teri_dir().join("mother-briefs");
    sent::create_private_dir(&dir)?;
    let path = dir.join(format!("{slug}-{}.md", Utc::now().format("%Y%m%dT%H%M%S%3f")));
    sent::private_file(&path)?.write_all(brief.as_bytes())?;
    Ok(path)
}

/// Trimmed stdout of `git -C <dir> <args>`; `None` on failure, timeout or empty output.
async fn git_output(dir: &Path, args: &[&str]) -> Option<String> {
    let mut cmd = tokio::process::Command::new("git");
    cmd.arg("-C").arg(dir).args(args).stdin(std::process::Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    (!text.is_empty()).then_some(text)
}

fn non_blank(s: Option<&str>) -> Option<&str> {
    s.filter(|s| !s.trim().is_empty())
}

/// `base`, or `base-2`, `base-3`, ...: the first one `is_taken` rejects.
pub(crate) fn first_free_tag(base: &str, is_taken: impl Fn(&str) -> bool) -> String {
    if !is_taken(base) {
        return base.to_owned();
    }
    (2u32..)
        .map(|n| format!("{base}-{n}"))
        .find(|candidate| !is_taken(candidate))
        .expect("an unbounded range always yields a free tag")
}

/// Map a git remote URL to a Nostromo org name, exactly as the Mac's
/// `RepoOrg.org(forRemoteURL:)` does (`macOS/Nostromo/Data/RepoOrg.swift`):
/// GitHub hosts only; owner `carefeed` -> "Carefeed", `thehammer` ->
/// "Personal"; anything else -> `None` (the client picks a default).
pub fn org_from_remote_url(url: &str) -> Option<String> {
    let owner = github_owner(url)?;
    match owner.to_lowercase().as_str() {
        "carefeed" => Some("Carefeed".to_owned()),
        "thehammer" => Some("Personal".to_owned()),
        _ => None,
    }
}

/// `OWNER` of `ssh://git@github.com/OWNER/repo`, `https://user:pw@github.com/OWNER/repo`
/// or scp-like `git@github.com:OWNER/repo`; `None` for non-GitHub hosts.
fn github_owner(raw: &str) -> Option<&str> {
    let url = raw.trim();
    if url.is_empty() {
        return None;
    }
    let (host, path) = if let Some((_, rest)) = url.split_once("://") {
        let (authority, path) = rest.split_once('/')?;
        let authority = authority.rsplit_once('@').map_or(authority, |(_, a)| a);
        let host = authority.split_once(':').map_or(authority, |(h, _)| h);
        (host, path)
    } else {
        let (host, path) = url.split_once(':')?;
        (host.rsplit_once('@').map_or(host, |(_, h)| h), path)
    };
    if !is_github_host(&host.to_lowercase()) {
        return None;
    }
    let mut parts = path.split('/').filter(|p| !p.is_empty());
    let owner = parts.next()?;
    parts.next()?;
    Some(owner)
}

/// github.com, www./ssh. variants, and per-identity SSH aliases such as
/// `github.com-work` or `github-personal`.
fn is_github_host(host: &str) -> bool {
    if ["github.com", "www.github.com", "ssh.github.com"].contains(&host) {
        return true;
    }
    ["github.com-", "github-"]
        .iter()
        .filter_map(|prefix| host.strip_prefix(prefix))
        .any(|suffix| !suffix.is_empty() && !suffix.contains('.'))
}

/// Longest slug used in a branch / brief file name.
const MAX_SLUG_LEN: usize = 48;

/// Lowercase ASCII alphanumerics with single dashes between, no leading or trailing dash.
fn slugify(text: &str) -> String {
    let mut slug = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    slug.trim_matches('-').to_owned()
}

/// Derive a stable, filesystem/IPC-safe focus tag from an agent name + title.
/// e.g. ("cody", "CORE-1234") -> "cody-core-1234".
fn derive_tag(agent: &str, title: &str) -> String {
    format!("{}-{}", agent.to_ascii_lowercase(), slugify(title))
}

/// Title-cased last path component, for `FocusMeta::project_name`.
fn project_name_from(cwd: &Path) -> Option<String> {
    cwd.file_name().and_then(|n| n.to_str()).map(|s| s.to_string())
}

/// Handle `nostromo.create_focus`: parse the arguments, run
/// [`create_focus_core`], shape the result.
pub async fn create_focus(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "create_focus requires the daemon-hosted MCP server" });
    };
    let req = match parse_request(args, pty_id) {
        Ok(req) => req,
        Err(e) => return error_json(&e),
    };
    match create_focus_core(daemon, req).await {
        Ok(outcome) => outcome_json(&outcome),
        Err(e) => error_json(&e),
    }
}

fn error_json(e: &CreateFocusError) -> Value {
    json!({ "error": e.code(), "detail": e.detail() })
}

/// `{ focus_id?, job_id?, kind, label }`; `focus_id` is kept for callers that predate `kind`.
fn outcome_json(outcome: &CreateFocusOutcome) -> Value {
    let mut out = json!({ "kind": outcome.kind.as_str(), "label": outcome.label });
    if let Some(tag) = &outcome.focus_tag {
        out["focus_id"] = json!(tag);
    }
    if let Some(job) = &outcome.job_id {
        out["job_id"] = json!(job);
    }
    out
}

fn parse_request(args: &Value, pty_id: Option<&str>) -> Result<CreateFocusRequest, CreateFocusError> {
    let invalid = |detail: &str| CreateFocusError::InvalidArgs(detail.to_owned());
    // Absent or null is `None`; anything else must be a string.
    let string = |key: &str| -> Result<Option<String>, CreateFocusError> {
        match args.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.clone())),
            Some(_) => Err(CreateFocusError::InvalidArgs(format!("{key} must be a string"))),
        }
    };
    let agent = string("agent")?.filter(|s| !s.is_empty()).ok_or_else(|| invalid("missing agent"))?;
    let title = string("title")?.filter(|s| !s.is_empty()).ok_or_else(|| invalid("missing title"))?;
    let working_directory = string("working_directory")?.filter(|s| !s.is_empty()).map(PathBuf::from);

    let source_item_title = string("source_item_title")?.filter(|t| !t.is_empty());
    let source_item = string("source_item_id")?.filter(|s| !s.is_empty()).map(|id| SourceItemRef {
        title: source_item_title.unwrap_or_else(|| title.clone()),
        id,
    });
    let allow_duplicate = match args.get("allow_duplicate") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(invalid("allow_duplicate must be a boolean")),
    };
    let destination = match string("destination")?.as_deref() {
        None | Some("focus") => Destination::Focus,
        Some("mother_job") => Destination::MotherJob {
            max_cost: match args.get("max_cost") {
                None | Some(Value::Null) => None,
                Some(v) => Some(v.as_f64().ok_or_else(|| invalid("max_cost must be a number"))?),
            },
        },
        Some(other) => {
            return Err(CreateFocusError::InvalidArgs(format!(
                "destination must be \"focus\" or \"mother_job\", got \"{other}\""
            )))
        }
    };

    Ok(CreateFocusRequest {
        agent,
        title,
        label: string("label")?,
        org: string("org")?,
        working_directory,
        initial_context: string("initial_context")?,
        source_item,
        allow_duplicate,
        destination,
        select_for_client: None,
        caller: pty_id.map(str::to_owned),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_tag_slugifies_title() {
        assert_eq!(derive_tag("cody", "CORE-1234"), "cody-core-1234");
        assert_eq!(derive_tag("Fred", "My  Cool  Task!!"), "fred-my-cool-task");
        assert_eq!(derive_tag("cody", "  leading "), "cody-leading");
    }

    // The table mirrors macOS/NostromoTests/RepoOrgTests.swift so the daemon
    // and the Mac agree on which org a remote belongs to.

    #[test]
    fn carefeed_remote_forms_are_carefeed() {
        for url in [
            "git@github.com:carefeed/portal.git",
            "git@github.com:carefeed/portal",
            "ssh://git@github.com/carefeed/portal.git",
            "ssh://git@github.com/carefeed/portal",
            "https://github.com/carefeed/portal.git",
            "https://github.com/carefeed/portal",
            "https://user:token@github.com/carefeed/portal.git",
            "https://x-access-token@github.com/carefeed/portal",
            "git@github.com:CareFeed/portal.git",
            "  https://github.com/CAREFEED/portal\n",
        ] {
            assert_eq!(org_from_remote_url(url).as_deref(), Some("Carefeed"), "{url:?}");
        }
    }

    #[test]
    fn personal_remote_forms_are_personal() {
        for url in [
            "git@github.com:thehammer/nostromo.git",
            "https://github.com/thehammer/nostromo",
            "ssh://git@github.com/TheHammer/nostromo.git",
        ] {
            assert_eq!(org_from_remote_url(url).as_deref(), Some("Personal"), "{url:?}");
        }
    }

    #[test]
    fn unknown_owners_hosts_and_garbage_have_no_org() {
        for url in [
            "git@github.com:someoneelse/repo.git",
            "https://github.com/someoneelse/repo",
            "git@gitlab.com:carefeed/portal.git",
            "https://bitbucket.org/thehammer/repo.git",
            "https://notgithub.com/carefeed/portal",
            "",
            "   ",
            "garbage",
            "github.com",
            "/Users/me/local/repo",
            "https://github.com/carefeed",
            "https://github.com/carefeed/",
            "git@github.com:carefeed",
            "git@notgithub.com:carefeed/x",
            "git@github.com.evil.example:carefeed/x",
            "https://github.com.evil.example/carefeed/x",
            "git@github.com-:carefeed/x",
            "git@github.com-a.evil.example:carefeed/x",
            "git@github-:carefeed/x",
            "git@githubx:carefeed/x",
        ] {
            assert_eq!(org_from_remote_url(url), None, "{url:?}");
        }
    }

    #[test]
    fn host_variants_and_ssh_aliases_resolve_like_the_mac() {
        for (url, expected) in [
            ("https://www.github.com/carefeed/x", "Carefeed"),
            ("ssh://git@ssh.github.com:443/thehammer/x.git", "Personal"),
            ("git@github.com-personal:thehammer/x", "Personal"),
            ("git@github.com-work:carefeed/x", "Carefeed"),
            ("git@github-work:carefeed/x", "Carefeed"),
            ("git@github-personal:thehammer/x.git", "Personal"),
            ("ssh://git@github.com-work/carefeed/x", "Carefeed"),
        ] {
            assert_eq!(org_from_remote_url(url).as_deref(), Some(expected), "{url:?}");
        }
    }

    #[test]
    fn first_free_tag_returns_the_base_when_it_is_free() {
        assert_eq!(first_free_tag("cody-x", |_| false), "cody-x");
    }

    #[test]
    fn first_free_tag_suffixes_from_two_until_one_is_free() {
        let taken = |t: &str| ["cody-x", "cody-x-2"].contains(&t);
        assert_eq!(first_free_tag("cody-x", taken), "cody-x-3");
        assert_eq!(first_free_tag("cody-x", |t| t == "cody-x"), "cody-x-2");
    }

    #[test]
    fn first_free_tag_skips_a_long_run_of_taken_suffixes() {
        let taken = |t: &str| t == "a" || (2..=40).any(|n| t == format!("a-{n}"));
        assert_eq!(first_free_tag("a", taken), "a-41");
    }
}
