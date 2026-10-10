//! Fred mailbox native data source — uses Microsoft Graph `$delta` directly.
//!
//! Replaces the bash `fred-mailbox-pane --json` poller with a native Rust client
//! that calls Graph every 5 s using delta tokens for low-latency incremental
//! updates.  The public snapshot type (`MailboxSnapshot`) is identical to the
//! bash source's; downstream view code is unchanged.
//!
//! Auth flow: on first run (or after token expiry) `ensure_authed` returns a
//! `DeviceFlowPrompt` that is embedded in the snapshot so the Fred view can
//! render the sign-in prompt inline.
//!
//! Truthfulness: `unread_count` is the Inbox folder's `unreadItemCount` (what
//! Outlook shows), never the number of unread items in the fetched window, and
//! every snapshot carries a `state` so a failed fetch can never read as
//! "0 unread".

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        dirty_file,
        fred_calendar::CalendarSnapshot,
        fred_mailbox::{MailboxItem, MailboxSnapshot},
        graph_client::{failure_reason, GraphClient},
        work::model::SourceState,
    },
};

// ── Timing ────────────────────────────────────────────────────────────────────

/// Poll cadence of the Fred Graph sources. `Default` is production; tests
/// shorten it.
#[derive(Debug, Clone)]
pub struct FredTiming {
    /// Mailbox delta poll (also woken early by the dirty file).
    pub mailbox_poll: Duration,
    /// Calendar poll (also woken early by the dirty file).
    pub calendar_poll: Duration,
    /// How long a fetched Inbox `unreadItemCount` is trusted. A delta that
    /// changed read state forces an immediate re-fetch regardless.
    pub unread_count_ttl: Duration,
    /// The zone that defines "today" for the calendar. `None` = the Mac's
    /// local zone; tests pin one.
    pub day_offset: Option<chrono::FixedOffset>,
}

impl Default for FredTiming {
    fn default() -> Self {
        Self {
            mailbox_poll: Duration::from_secs(5),
            calendar_poll: Duration::from_secs(30),
            unread_count_ttl: Duration::from_secs(30),
            day_offset: None,
        }
    }
}

/// Most items a snapshot carries (unread first, then newest). The count in
/// `unread_count` is the folder's, not this window's.
const MAX_SNAPSHOT_ITEMS: usize = 100;

// ── Graph message shape ───────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphMessage {
    id: String,
    subject: Option<String>,
    is_read: Option<bool>,
    received_date_time: Option<DateTime<Utc>>,
    web_link: Option<String>,
    from: Option<GraphEmailAddress>,
    #[serde(rename = "@removed")]
    removed: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct GraphEmailAddress {
    #[serde(rename = "emailAddress")]
    email_address: GraphEmail,
}

#[derive(Debug, Deserialize)]
struct GraphEmail {
    name: Option<String>,
    address: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphMailFolder {
    unread_item_count: Option<i64>,
}

const MAILBOX_DELTA_PATH: &str =
    "/me/mailFolders/inbox/messages/delta?$top=25&$select=id,webLink,from,subject,receivedDateTime,isRead";

/// The Inbox folder itself: the only place Outlook's unread count lives.
const INBOX_FOLDER_PATH: &str = "/me/mailFolders/inbox?$select=unreadItemCount";

// ── Source ────────────────────────────────────────────────────────────────────

pub struct FredMailboxNativeSource {
    config: Config,
    timing: FredTiming,
}

/// The Inbox unread count and when it was last read from Graph.
#[derive(Default)]
struct UnreadCount {
    value: Option<usize>,
    fetched_at: Option<Instant>,
    /// Read state changed since the last successful fetch.
    dirty: bool,
}

impl UnreadCount {
    fn needs_fetch(&self, ttl: Duration) -> bool {
        self.dirty
            || self.value.is_none()
            || self.fetched_at.is_none_or(|t| t.elapsed() >= ttl)
    }
}

impl FredMailboxNativeSource {
    /// Production entry point: builds (or reuses) the process-wide Graph
    /// client from `config`, then polls.
    pub fn spawn(config: Config) -> watch::Receiver<Option<MailboxSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("mailbox.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let graph = match shared_graph_client(&config).await {
                Ok(g) => g,
                Err(unavailable) => {
                    let snapshot = MailboxSnapshot::from(unavailable);
                    warn!("mailbox graph client unavailable: {:?}", snapshot.error);
                    let _ = tx.send(Some(snapshot));
                    return;
                }
            };
            let source = FredMailboxNativeSource { config, timing: FredTiming::default() };
            source.run(graph, tx, &mut dirty_rx).await;
        });

        rx
    }

    /// Poll with an explicit (usually shared) Graph client and timing.
    pub fn spawn_with(
        graph: GraphClient,
        config: Config,
        timing: FredTiming,
    ) -> watch::Receiver<Option<MailboxSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("mailbox.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let source = FredMailboxNativeSource { config, timing };
            source.run(graph, tx, &mut dirty_rx).await;
        });

        rx
    }

    async fn run(
        &self,
        graph: GraphClient,
        tx: watch::Sender<Option<MailboxSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        let delta_file = self.delta_cache_dir().join("mailbox.delta");

        // Always start with a fresh full sync — the in-memory store is empty on
        // every launch, so reusing a stale delta token would return 0 items.
        let _ = std::fs::remove_file(&delta_file);

        // In-memory message store: id -> item.
        let mut store: HashMap<String, GraphMessage> = HashMap::new();
        let mut unread = UnreadCount::default();

        loop {
            let previous = tx.borrow().clone();
            let next = self
                .refresh(&graph, &delta_file, &mut store, &mut unread, previous.as_ref())
                .await;
            let _ = tx.send(Some(next));

            // Poll every few seconds, or immediately on dirty signal.
            tokio::select! {
                _ = tokio::time::sleep(self.timing.mailbox_poll) => {}
                _ = dirty_rx.recv() => {
                    debug!("mailbox dirty signal received");
                }
            }
        }
    }

    /// One poll cycle. Always yields the snapshot to publish: fresh data, the
    /// sign-in prompt, or the previous data marked stale / an error.
    async fn refresh(
        &self,
        graph: &GraphClient,
        delta_file: &std::path::Path,
        store: &mut HashMap<String, GraphMessage>,
        unread: &mut UnreadCount,
        previous: Option<&MailboxSnapshot>,
    ) -> MailboxSnapshot {
        match graph.ensure_authed().await {
            Ok(Some(prompt)) => return MailboxSnapshot::unauthenticated(prompt),
            Ok(None) => {}
            Err(e) => {
                warn!("graph ensure_authed error: {e:#}");
                return MailboxSnapshot::failed(previous, failure_reason("Mail sign-in failed", &e));
            }
        }

        match graph
            .delta::<GraphMessage>(MAILBOX_DELTA_PATH, delta_file)
            .await
        {
            Ok((msgs, _dl)) => {
                debug!(count = msgs.len(), "mailbox delta received");
                if apply_delta(store, msgs) {
                    unread.dirty = true;
                }
            }
            Err(e) => {
                warn!("mailbox delta failed: {e:#}");
                return MailboxSnapshot::failed(previous, failure_reason("Mail fetch failed", &e));
            }
        }

        if unread.needs_fetch(self.timing.unread_count_ttl) {
            match graph.get_json::<GraphMailFolder>(INBOX_FOLDER_PATH).await {
                Ok(folder) => {
                    unread.value = Some(folder.unread_item_count.unwrap_or(0).max(0) as usize);
                    unread.fetched_at = Some(Instant::now());
                    unread.dirty = false;
                }
                Err(e) => {
                    warn!("inbox unread count failed: {e:#}");
                    return MailboxSnapshot::failed(
                        previous,
                        failure_reason("Mail unread count failed", &e),
                    );
                }
            }
        }

        build_snapshot(store, unread.value.unwrap_or(0), &self.config)
    }

    fn delta_cache_dir(&self) -> PathBuf {
        self.config
            .graph_token_cache_path()
            .parent()
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir().join(".cache").join("nostromo"))
    }
}

/// The Graph client both Fred sources share, or the snapshot explaining why
/// there is none (`not_configured` when no Azure app id is set).
pub(crate) async fn shared_graph_client(config: &Config) -> Result<GraphClient, UnavailableGraph> {
    let client_id = config.graph_client_id.clone().unwrap_or_default();
    if client_id.trim().is_empty() {
        return Err(UnavailableGraph::NotConfigured);
    }
    let tenant = config
        .graph_tenant
        .clone()
        .unwrap_or_else(|| "common".to_owned());
    let cache_path = config.graph_token_cache_path();
    if let Some(parent) = cache_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    GraphClient::shared(client_id, tenant, cache_path)
        .await
        .map_err(|e| UnavailableGraph::Failed(format!("{e:#}")))
}

/// Why no Graph client could be built.
pub(crate) enum UnavailableGraph {
    NotConfigured,
    Failed(String),
}

const NOT_CONFIGURED_REASON: &str =
    "Microsoft Graph is not set up: add graph_client_id to ~/.config/nostromo/config.toml";

impl From<UnavailableGraph> for MailboxSnapshot {
    fn from(u: UnavailableGraph) -> Self {
        match u {
            UnavailableGraph::NotConfigured => MailboxSnapshot {
                generated_at: Some(Utc::now()),
                state: SourceState::NotConfigured,
                error: Some(NOT_CONFIGURED_REASON.to_owned()),
                ..Default::default()
            },
            UnavailableGraph::Failed(reason) => MailboxSnapshot::failed(
                None,
                format!("Graph client init failed: {reason}"),
            ),
        }
    }
}

impl From<UnavailableGraph> for CalendarSnapshot {
    fn from(u: UnavailableGraph) -> Self {
        match u {
            UnavailableGraph::NotConfigured => Self {
                generated_at: Some(Utc::now()),
                sweater: "sage".to_owned(),
                state: SourceState::NotConfigured,
                error: Some(NOT_CONFIGURED_REASON.to_owned()),
                ..Default::default()
            },
            UnavailableGraph::Failed(reason) => Self::failed(
                None,
                format!("Graph client init failed: {reason}"),
            ),
        }
    }
}

/// Apply one delta batch to the store. Returns true when the read state of any
/// message changed (so the folder's unread count must be re-read).
fn apply_delta(store: &mut HashMap<String, GraphMessage>, msgs: Vec<GraphMessage>) -> bool {
    let mut read_state_changed = false;
    for msg in msgs {
        let was_unread = store.get(&msg.id).map(|m| !m.is_read.unwrap_or(false));
        if msg.removed.is_some() {
            read_state_changed |= was_unread == Some(true);
            store.remove(&msg.id);
        } else {
            let now_unread = !msg.is_read.unwrap_or(false);
            read_state_changed |= was_unread.unwrap_or(false) != now_unread;
            store.insert(msg.id.clone(), msg);
        }
    }
    read_state_changed
}

// ── Snapshot builder ──────────────────────────────────────────────────────────

fn build_snapshot(
    store: &HashMap<String, GraphMessage>,
    unread_count: usize,
    config: &Config,
) -> MailboxSnapshot {
    let vip_set: std::collections::HashSet<String> = config
        .vip_senders
        .iter()
        .map(|s| s.to_lowercase())
        .collect();

    let mut items: Vec<MailboxItem> = store
        .values()
        .map(|msg| {
            let from_name = msg
                .from
                .as_ref()
                .and_then(|f| f.email_address.name.clone())
                .unwrap_or_default();
            let from_addr = msg
                .from
                .as_ref()
                .and_then(|f| f.email_address.address.clone())
                .unwrap_or_default();
            let from = if from_name.is_empty() {
                from_addr.clone()
            } else {
                format!("{from_name} <{from_addr}>")
            };
            let subject = msg.subject.clone().unwrap_or_default();
            let is_read = msg.is_read.unwrap_or(false);
            let is_invite = subject.starts_with("Invitation:");
            let vip = vip_set.contains(&from_addr.to_lowercase());

            MailboxItem {
                id: msg.id.clone(),
                web_link: msg.web_link.clone(),
                from,
                subject,
                received_at: msg.received_date_time,
                vip,
                is_invite,
                is_read,
            }
        })
        .collect();

    // Sort: unread first (`false < true`), then by received_at descending.
    items.sort_by(|a, b| {
        a.is_read
            .cmp(&b.is_read)
            .then_with(|| b.received_at.cmp(&a.received_at))
    });
    items.truncate(MAX_SNAPSHOT_ITEMS);

    let now = Utc::now();
    let state = if items.is_empty() && unread_count == 0 {
        SourceState::Empty
    } else {
        SourceState::Fresh
    };

    MailboxSnapshot {
        generated_at: Some(now),
        unread_count,
        items,
        stale: false,
        error: None,
        auth_prompt: None,
        state,
        updated_at: Some(now),
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
