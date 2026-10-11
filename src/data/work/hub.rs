//! The work hub: one place that holds the latest state of every work source,
//! merges the sent ledger into the items, tells connected clients about
//! changes, and answers the `WorkService` requests.
//!
//! Each source publishes a [`SourceUpdate`] on a `watch` channel. The hub
//! follows every channel, keeps the latest status and groups, and a publisher
//! task broadcasts `WorkSourceStatus` / `WorkSnapshot` frames **only for what
//! changed** (a hash of the serialized group), coalescing bursts into one
//! round every [`COALESCE`]. The server's retained-message cache replays the
//! frames to a client that connects later.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use tokio::sync::{broadcast, watch, Notify};
use tracing::warn;

use crate::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use crate::ipc::protocol::ServerMsg;
use crate::ipc::SessionManager;

use super::model::{
    SendOutcome, SendPreview, SentMarker, SourceState, SourceStatus, WorkDetail, WorkError,
    WorkItem, WorkSource,
};
use super::query::{self, WorkFilter};
use super::service::{SendRequest, WorkService};
use super::{credentials, picks, repo_docs, send, sent, jira, sentry, todos};

/// What one source publishes: its status and its items, one entry per group
/// (`None` for sources that are a single flat list, the repo for repo docs).
pub type SourceUpdate = (SourceStatus, Vec<(Option<String>, Vec<WorkItem>)>);

/// A manual refresh within this long of the previous one only re-announces
/// what the hub already has (design contract §9).
pub const REFRESH_DEBOUNCE: Duration = Duration::from_secs(15);

/// Changes closer together than this are sent as one round of frames.
pub const COALESCE: Duration = Duration::from_millis(250);

/// How often the hub re-checks whether a sent marker's focus is still alive
/// (a closed focus must stop showing "sent to <label>" promptly).
const SENT_LIVENESS_TICK: Duration = Duration::from_secs(5);

/// A `WorkSnapshot` frame must stay under this (`MAX_FRAME_LEN` is 4 MiB).
const MAX_SNAPSHOT_BYTES: usize = 3 * 1024 * 1024;

/// The handles the later slices (picks, send to agent) need from the daemon.
#[derive(Clone)]
pub struct HubContext {
    pub broadcast_tx: broadcast::Sender<ServerMsg>,
    /// `None` in tests that do not host sessions.
    pub session_mgr: Option<Arc<Mutex<SessionManager>>>,
}

/// Everything the hub is built from.
pub struct HubDeps {
    pub broadcast_tx: broadcast::Sender<ServerMsg>,
    pub todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>,
    pub session_mgr: Option<Arc<Mutex<SessionManager>>>,
    /// Changes when the server's retained-frame cache lagged: the hub then
    /// sends everything again.
    pub republish_rx: Option<watch::Receiver<u64>>,
    /// Where the Jira site for todo links comes from.
    pub jira_site: credentials::JiraSite,
    /// Poked when a manual refresh of the todos source passes the debounce.
    pub todos_refresh: Option<Arc<Notify>>,
}

impl HubDeps {
    pub fn new(
        broadcast_tx: broadcast::Sender<ServerMsg>,
        todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>,
    ) -> Self {
        Self {
            broadcast_tx,
            todos_rx,
            session_mgr: None,
            republish_rx: None,
            jira_site: credentials::JiraSite::default(),
            todos_refresh: None,
        }
    }
}

const SOURCE_ORDER: [WorkSource; 4] =
    [WorkSource::Todos, WorkSource::RepoDocs, WorkSource::Jira, WorkSource::Sentry];

pub struct WorkHub {
    ctx: HubContext,
    state: Mutex<State>,
    /// Pokes the publisher task.
    dirty: Notify,
    /// Per source: fires when a manual refresh passed the debounce.
    refresh: HashMap<WorkSource, Arc<Notify>>,
    /// Source of the Jira host for todo links (reads a file: use off the async threads).
    jira_site: Arc<credentials::JiraSite>,
}

struct State {
    slots: BTreeMap<WorkSource, Slot>,
    /// Latest todos snapshot, kept for item detail.
    todos: Option<TeriTodosSnapshot>,
    /// Todos from the last healthy read: shown (as stale) when a read fails.
    last_good_todos: Vec<TeriTodo>,
    /// When that healthy read happened: what a stale banner reports as its age.
    last_good_at: Option<DateTime<Utc>>,
}

struct Slot {
    status: SourceStatus,
    groups: BTreeMap<Option<String>, Vec<WorkItem>>,
    published_status: Option<SourceStatus>,
    published_groups: HashMap<Option<String>, u64>,
    last_refresh: Option<Instant>,
}

impl Slot {
    fn new(source: WorkSource) -> Self {
        Self {
            status: loading_status(source),
            groups: BTreeMap::new(),
            published_status: None,
            published_groups: HashMap::new(),
            last_refresh: None,
        }
    }

    /// Forget what clients were told so the next round sends everything.
    fn forget_published(&mut self) {
        self.published_status = None;
        self.published_groups.clear();
    }
}

fn loading_status(source: WorkSource) -> SourceStatus {
    SourceStatus {
        source,
        state: SourceState::Loading,
        updated_at: None,
        reason: None,
        retry_at: None,
        count: 0,
        group_errors: Vec::new(),
    }
}

/// Whether two statuses differ in a way worth a frame (a newer `updated_at`
/// alone is not).
fn same_signature(a: &SourceStatus, b: &SourceStatus) -> bool {
    a.state == b.state
        && a.reason == b.reason
        && a.retry_at == b.retry_at
        && a.count == b.count
        && a.group_errors == b.group_errors
}

impl WorkHub {
    /// Build the hub, start following every source and start publishing.
    /// Must be called inside a tokio runtime.
    pub fn spawn(deps: HubDeps) -> Arc<Self> {
        let HubDeps { broadcast_tx, todos_rx, session_mgr, republish_rx, jira_site, todos_refresh } = deps;
        let mut refresh: HashMap<WorkSource, Arc<Notify>> =
            [WorkSource::RepoDocs, WorkSource::Jira, WorkSource::Sentry]
                .into_iter()
                .map(|s| (s, Arc::new(Notify::new())))
                .collect();
        if let Some(notify) = todos_refresh {
            refresh.insert(WorkSource::Todos, notify);
        }
        let hub = Arc::new(Self {
            ctx: HubContext { broadcast_tx, session_mgr },
            state: Mutex::new(State {
                slots: SOURCE_ORDER.iter().map(|s| (*s, Slot::new(*s))).collect(),
                todos: None,
                last_good_todos: Vec::new(),
                last_good_at: None,
            }),
            dirty: Notify::new(),
            refresh,
            jira_site: Arc::new(jira_site),
        });

        let sources = [
            (WorkSource::RepoDocs, repo_docs::spawn(hub.refresh[&WorkSource::RepoDocs].clone())),
            (WorkSource::Jira, jira::spawn(hub.refresh[&WorkSource::Jira].clone())),
            (WorkSource::Sentry, sentry::spawn(hub.refresh[&WorkSource::Sentry].clone())),
        ];
        for (source, rx) in sources {
            // Apply the initial value now so `status()` is right on return.
            hub.apply_update(source, rx.borrow().clone());
            tokio::spawn(follow_source(Arc::clone(&hub), source, rx));
        }

        let mut todos_rx = todos_rx;
        hub.apply_todos(todos_rx.borrow_and_update().clone());
        tokio::spawn(follow_todos(Arc::clone(&hub), todos_rx));

        tokio::spawn(publisher(Arc::clone(&hub)));
        tokio::spawn(follow_sent(Arc::clone(&hub)));
        if let Some(rx) = republish_rx {
            tokio::spawn(follow_republish(Arc::clone(&hub), rx));
        }
        hub
    }

    /// Daemon handles for the picks / send slices.
    pub fn context(&self) -> &HubContext {
        &self.ctx
    }

    /// Items matching `filter`: sources in the order todos, repo docs, Jira,
    /// Sentry, each in its default order (§5).
    pub fn items(&self, filter: &WorkFilter) -> Vec<WorkItem> {
        let state = self.state.lock().unwrap();
        let mut out = Vec::new();
        for source in SOURCE_ORDER {
            let all: Vec<WorkItem> = state.slots[&source]
                .groups
                .values()
                .flat_map(|items| items.iter().cloned())
                .collect();
            let matching = query::filter(&all, filter);
            out.extend(query::default_order(&matching, source));
        }
        out
    }

    pub fn status(&self, source: WorkSource) -> SourceStatus {
        self.state.lock().unwrap().slots[&source].status.clone()
    }

    /// Every source's status, in source order.
    pub fn statuses(&self) -> Vec<SourceStatus> {
        let state = self.state.lock().unwrap();
        SOURCE_ORDER.iter().map(|s| state.slots[s].status.clone()).collect()
    }

    // ── updates ───────────────────────────────────────────────────────────────

    fn apply_update(&self, source: WorkSource, (status, groups): SourceUpdate) {
        let groups: BTreeMap<Option<String>, Vec<WorkItem>> = groups
            .into_iter()
            .filter(|(_, items)| !items.is_empty())
            .map(|(group, items)| (group, prepare_group(source, items, &|m| self.marker_is_live(m))))
            .collect();
        {
            let mut state = self.state.lock().unwrap();
            let slot = state.slots.get_mut(&source).expect("every source has a slot");
            slot.status = status;
            slot.groups = groups;
        }
        self.dirty.notify_one();
    }

    fn apply_todos(&self, snap: Option<TeriTodosSnapshot>) {
        let Some(mut snap) = snap else {
            self.apply_update(WorkSource::Todos, (loading_status(WorkSource::Todos), Vec::new()));
            return;
        };
        {
            let mut state = self.state.lock().unwrap();
            let healthy = snap.error.is_none() && !snap.stale && !snap.not_configured;
            if healthy {
                state.last_good_todos = snap.items.clone();
                state.last_good_at = snap.generated_at;
            } else if snap.error.is_some() && snap.items.is_empty() && !state.last_good_todos.is_empty()
            {
                // A failed read keeps showing the last good list, marked stale.
                snap.items = state.last_good_todos.clone();
                snap.stale = true;
                // The banner says how old the LIST is, not when the failed read ran.
                snap.generated_at = state.last_good_at.or(snap.generated_at);
            }
            state.todos = Some(snap.clone());
        }
        let (status, items) = todos::adapt(&snap);
        self.apply_update(WorkSource::Todos, (status, vec![(None, items)]));
    }

    /// Is the focus or job a sent marker points at still there? A focus is live
    /// while its session is; a Mother job is live until the periodic prune finds
    /// it archived (the hub cannot ask Mother on the hot path).
    fn marker_is_live(&self, marker: &SentMarker) -> bool {
        match marker.kind.as_str() {
            "focus" => self
                .ctx
                .session_mgr
                .as_ref()
                .is_some_and(|mgr| mgr.lock().unwrap().has_live_session(&marker.target_id)),
            _ => true,
        }
    }

    /// Re-attach live sent markers to every held item and, if any item's
    /// markers changed, let the publisher re-broadcast it.
    fn refresh_sent(&self) {
        let ledger = sent::ledger();
        let ids: Vec<String> = {
            let state = self.state.lock().unwrap();
            state
                .slots
                .values()
                .flat_map(|slot| slot.groups.values().flatten())
                .filter(|item| !item.sent.is_empty() || !ledger.markers(&item.id).is_empty())
                .map(|item| item.id.clone())
                .collect()
        };
        // Probe outside the state lock: it takes the session manager's lock.
        let live: HashMap<String, Vec<SentMarker>> = ids
            .into_iter()
            .map(|id| {
                let markers = ledger.live_markers(&id, &|m| self.marker_is_live(m));
                (id, markers)
            })
            .collect();
        let mut changed = false;
        {
            let mut state = self.state.lock().unwrap();
            for slot in state.slots.values_mut() {
                for item in slot.groups.values_mut().flatten() {
                    if let Some(markers) = live.get(&item.id) {
                        if item.sent != *markers {
                            item.sent = markers.clone();
                            changed = true;
                        }
                    }
                }
            }
        }
        if changed {
            self.dirty.notify_one();
        }
    }

    /// Drop ledger markers whose focus is gone (no session and no registry
    /// entry) or whose Mother job no longer exists.
    async fn prune_sent(&self) {
        let ledger = sent::ledger();
        let has_jobs = ledger
            .item_ids()
            .iter()
            .any(|id| ledger.markers(id).iter().any(|m| m.kind == "mother_job"));
        // Unknown (`None`) keeps every job marker.
        let jobs = if has_jobs { sent::mother_job_ids().await } else { None };
        let focus_exists = |tag: &str| {
            self.ctx.session_mgr.as_ref().is_some_and(|mgr| {
                let mgr = mgr.lock().unwrap();
                mgr.has_live_session(tag) || mgr.focus_registry().iter().any(|f| f.tag == tag)
            })
        };
        let removed = ledger.prune(&|m| match m.kind.as_str() {
            "focus" => focus_exists(&m.target_id),
            "mother_job" => jobs.as_ref().is_none_or(|jobs| jobs.contains(&m.target_id)),
            _ => true,
        });
        if removed > 0 {
            self.refresh_sent();
        }
    }

    /// Forget what clients were told so the next round sends everything.
    fn republish(&self) {
        {
            let mut state = self.state.lock().unwrap();
            state.slots.values_mut().for_each(Slot::forget_published);
        }
        self.dirty.notify_one();
    }

    /// Send the frames for whatever changed since the last round.
    fn publish(&self) {
        let mut frames = Vec::new();
        {
            let mut state = self.state.lock().unwrap();
            for (source, slot) in state.slots.iter_mut() {
                let changed = slot
                    .published_status
                    .as_ref()
                    .is_none_or(|published| !same_signature(published, &slot.status));
                if changed {
                    slot.published_status = Some(slot.status.clone());
                    frames.push(ServerMsg::WorkSourceStatus { status: slot.status.clone() });
                }
                for (group, items) in &slot.groups {
                    let items = fit_frame(*source, group.as_deref(), items);
                    let digest = digest_of(&items);
                    if slot.published_groups.get(group) != Some(&digest) {
                        slot.published_groups.insert(group.clone(), digest);
                        frames.push(ServerMsg::WorkSnapshot {
                            source: *source,
                            group: group.clone(),
                            items,
                        });
                    }
                }
                let gone: Vec<Option<String>> = slot
                    .published_groups
                    .keys()
                    .filter(|g| !slot.groups.contains_key(*g))
                    .cloned()
                    .collect();
                for group in gone {
                    slot.published_groups.remove(&group);
                    frames.push(ServerMsg::WorkSnapshot { source: *source, group, items: Vec::new() });
                }
            }
        }
        for frame in frames {
            // No receiver (no client connected) is fine.
            let _ = self.ctx.broadcast_tx.send(frame);
        }
    }
}

/// Order a group's items and attach their live sent markers.
fn prepare_group(
    source: WorkSource,
    items: Vec<WorkItem>,
    is_live: &dyn Fn(&SentMarker) -> bool,
) -> Vec<WorkItem> {
    let ledger = sent::ledger();
    let mut items = query::default_order(&items, source);
    for item in &mut items {
        item.sent = ledger.live_markers(&item.id, is_live);
    }
    items
}

fn digest_of(items: &[WorkItem]) -> u64 {
    let mut hasher = DefaultHasher::new();
    serde_json::to_vec(items).unwrap_or_default().hash(&mut hasher);
    hasher.finish()
}

/// Keep a snapshot under the frame limit: first shorten the search text of the
/// items, then drop it.
fn fit_frame(source: WorkSource, group: Option<&str>, items: &[WorkItem]) -> Vec<WorkItem> {
    let size = |items: &[WorkItem]| serde_json::to_vec(items).map(|b| b.len()).unwrap_or(0);
    if size(items) <= MAX_SNAPSHOT_BYTES {
        return items.to_vec();
    }
    warn!(source = source.as_str(), group, "work snapshot over the frame limit; trimming search text");
    let mut trimmed = items.to_vec();
    for keep in [2048usize, 0] {
        for item in &mut trimmed {
            if item.search_text.len() > keep {
                let mut cut = keep;
                while !item.search_text.is_char_boundary(cut) {
                    cut -= 1;
                }
                item.search_text.truncate(cut);
            }
        }
        if size(&trimmed) <= MAX_SNAPSHOT_BYTES {
            break;
        }
    }
    trimmed
}

// ── tasks ─────────────────────────────────────────────────────────────────────

async fn follow_source(hub: Arc<WorkHub>, source: WorkSource, mut rx: watch::Receiver<SourceUpdate>) {
    while rx.changed().await.is_ok() {
        let update = rx.borrow_and_update().clone();
        hub.apply_update(source, update);
    }
}

async fn follow_todos(hub: Arc<WorkHub>, mut rx: watch::Receiver<Option<TeriTodosSnapshot>>) {
    while rx.changed().await.is_ok() {
        let snap = rx.borrow_and_update().clone();
        hub.apply_todos(snap);
    }
}

async fn follow_republish(hub: Arc<WorkHub>, mut rx: watch::Receiver<u64>) {
    while rx.changed().await.is_ok() {
        hub.republish();
    }
}

/// Keeps `WorkItem.sent` true: re-merges when the ledger changes and on a
/// short tick (a focus can die without the ledger hearing of it), and prunes
/// dead markers for good once after the startup grace, then every 10 minutes.
async fn follow_sent(hub: Arc<WorkHub>) {
    let mut changes = sent::ledger().subscribe();
    let mut tick = tokio::time::interval(SENT_LIVENESS_TICK);
    let mut next_prune = Instant::now() + sent::STARTUP_GRACE;
    loop {
        tokio::select! {
            result = changes.changed() => {
                if result.is_err() {
                    return;
                }
            }
            _ = tick.tick() => {}
        }
        hub.refresh_sent();
        if Instant::now() >= next_prune {
            hub.prune_sent().await;
            next_prune = Instant::now() + sent::PRUNE_INTERVAL;
        }
    }
}

async fn publisher(hub: Arc<WorkHub>) {
    loop {
        hub.dirty.notified().await;
        // Let a burst of changes settle, then send one round.
        tokio::time::sleep(COALESCE).await;
        hub.publish();
    }
}

// ── WorkService ───────────────────────────────────────────────────────────────

#[async_trait]
impl WorkService for WorkHub {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let prefix = item_id.split_once(':').map_or("", |(p, _)| p);
        match prefix {
            "todo" => {
                let snap = self.state.lock().unwrap().todos.clone();
                let snap = snap.ok_or_else(|| {
                    WorkError::new("unknown_item", "Todos have not loaded yet")
                })?;
                // Reads a credentials file: keep it off the async threads.
                let jira_site = Arc::clone(&self.jira_site);
                let site = tokio::task::spawn_blocking(move || jira_site.lookup())
                    .await
                    .unwrap_or_default();
                todos::detail(&snap, item_id, site.as_deref())
            }
            "doc" => repo_docs::detail(item_id).await,
            "jira" => jira::detail(item_id).await,
            "sentry" => sentry::detail(item_id).await,
            _ => Err(WorkError::new("unknown_item", "Unknown kind of work item")),
        }
    }

    async fn refresh(&self, source: Option<WorkSource>, _fred: bool) -> Result<(), WorkError> {
        let targets: Vec<WorkSource> = source.map_or_else(|| SOURCE_ORDER.to_vec(), |s| vec![s]);
        let now = Instant::now();
        {
            let mut state = self.state.lock().unwrap();
            for target in &targets {
                let slot = state.slots.get_mut(target).expect("every source has a slot");
                let due = slot.last_refresh.is_none_or(|t| now.duration_since(t) >= REFRESH_DEBOUNCE);
                if due {
                    slot.last_refresh = Some(now);
                    if let Some(notify) = self.refresh.get(target) {
                        notify.notify_one();
                    }
                }
                // Whether or not a fetch started, tell clients what we have.
                slot.forget_published();
            }
        }
        self.dirty.notify_one();
        Ok(())
    }

    async fn refresh_picks(&self, reason: &str) -> Result<(), WorkError> {
        picks::refresh(&self.ctx, reason).await
    }

    async fn send_preview(&self, item_id: &str) -> Result<SendPreview, WorkError> {
        send::preview(&self.ctx, item_id).await
    }

    async fn send(&self, request: SendRequest) -> Result<SendOutcome, WorkError> {
        send::send(&self.ctx, request).await
    }
}
