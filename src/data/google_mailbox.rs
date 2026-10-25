//! Fred mailbox source for one Gmail account.
//!
//! A full sync (profile, inbox list, metadata per message) on launch and after
//! Gmail forgets our history point, then `users.history.list` for incremental
//! updates: the analogue of Graph delta links.
//!
//! Truthfulness: `unread_count` is the INBOX label's `threadsUnread` (what
//! Gmail shows for the inbox in conversation view), never the number of unread
//! rows we hold. It counts threads, so it can be lower than the number of
//! unread rows shown. A response without it is a failure, never zero, and a
//! history page without `historyId` is a failure, never "no changes".
//!
//! Privacy: logs carry counts, labels and states only.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{
        fred_mailbox::{MailboxItem, MailboxSnapshot},
        fred_mailbox_native::{FredTiming, UnreadCount},
        google_client::{
            encode_segment, failure_reason, with_query, GoogleClient, GoogleHttpError,
        },
        http_backoff::ThrottleBackoff,
        work::model::SourceState,
    },
};

const MAX_SNAPSHOT_ITEMS: usize = 100;
/// Most messages kept in memory between cycles (newest first).
const MAX_STORE: usize = 200;
/// Most metadata fetches per cycle; the rest carry over to the next.
const MAX_FETCH_PER_CYCLE: usize = 25;
/// Most `history.list` pages followed in one cycle; more is an error.
const MAX_HISTORY_PAGES: usize = 20;
const INBOX: &str = "INBOX";
const UNREAD: &str = "UNREAD";

// ── Gmail shapes ──────────────────────────────────────────────────────────────

#[derive(Clone)]
struct GmailMsg {
    thread_id: String,
    from: String,
    subject: String,
    internal_date: Option<DateTime<Utc>>,
    unread: bool,
}

/// `from` and `subject` are other people's words: never printed.
impl std::fmt::Debug for GmailMsg {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GmailMsg")
            .field("thread_id", &"<redacted>")
            .field("from", &"<redacted>")
            .field("subject", &"<redacted>")
            .field("internal_date", &self.internal_date)
            .field("unread", &self.unread)
            .finish()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Profile {
    email_address: String,
    #[serde(default, deserialize_with = "flexible_u64")]
    history_id: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageList {
    #[serde(default)]
    messages: Vec<MessageStub>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageStub {
    id: String,
    #[serde(default)]
    label_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawMessage {
    id: String,
    thread_id: Option<String>,
    #[serde(default)]
    label_ids: Vec<String>,
    internal_date: Option<String>,
    payload: Option<RawPayload>,
}

#[derive(Deserialize)]
struct RawPayload {
    #[serde(default)]
    headers: Vec<RawHeader>,
}

#[derive(Deserialize)]
struct RawHeader {
    name: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryPage {
    #[serde(default)]
    history: Vec<HistoryRecord>,
    next_page_token: Option<String>,
    #[serde(default, deserialize_with = "flexible_u64")]
    history_id: Option<u64>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct HistoryRecord {
    #[serde(default)]
    messages_added: Vec<HistoryMessage>,
    #[serde(default)]
    messages_deleted: Vec<HistoryMessage>,
    #[serde(default)]
    labels_added: Vec<HistoryLabelChange>,
    #[serde(default)]
    labels_removed: Vec<HistoryLabelChange>,
}

#[derive(Deserialize)]
struct HistoryMessage {
    message: MessageStub,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryLabelChange {
    message: MessageStub,
    #[serde(default)]
    label_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LabelInfo {
    threads_unread: Option<i64>,
}

/// Gmail sends history ids as strings; accept numbers too.
fn flexible_u64<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Option<u64>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Flex {
        Num(u64),
        Text(String),
    }
    match Option::<Flex>::deserialize(d)? {
        None => Ok(None),
        Some(Flex::Num(n)) => Ok(Some(n)),
        Some(Flex::Text(s)) => s.parse().map(Some).map_err(serde::de::Error::custom),
    }
}

// ── Per-account state ─────────────────────────────────────────────────────────

#[derive(Default)]
struct SyncState {
    store: HashMap<String, GmailMsg>,
    history_id: Option<u64>,
    email: Option<String>,
    /// Message ids whose metadata is still to be fetched.
    queue: VecDeque<String>,
    unread: UnreadCount,
    backoff: ThrottleBackoff,
}

// ── Source ────────────────────────────────────────────────────────────────────

pub struct GoogleMailboxSource {
    label: String,
    config: Config,
    timing: FredTiming,
}

impl GoogleMailboxSource {
    /// Poll one Gmail account. Wakes early on `dirty_rx`.
    pub fn spawn_with_dirty(
        client: GoogleClient,
        label: String,
        config: Config,
        timing: FredTiming,
        mut dirty_rx: mpsc::UnboundedReceiver<()>,
    ) -> watch::Receiver<Option<MailboxSnapshot>> {
        let (tx, rx) = watch::channel(None);
        tokio::spawn(async move {
            let source = GoogleMailboxSource {
                label,
                config,
                timing,
            };
            source.run(client, tx, &mut dirty_rx).await;
        });
        rx
    }

    async fn run(
        &self,
        client: GoogleClient,
        tx: watch::Sender<Option<MailboxSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        // Every launch starts with a full sync: there is no on-disk history point.
        let mut state = SyncState::default();
        loop {
            let previous = tx.borrow().clone();
            let (next, throttled_for) = self.refresh(&client, &mut state, previous.as_ref()).await;
            let _ = tx.send(Some(next));

            if let Some(quiet) = throttled_for {
                // Google is throttling us: stay silent for the whole wait, dirty
                // signals included, and forget the ones that piled up meanwhile.
                tokio::time::sleep(quiet).await;
                while dirty_rx.try_recv().is_ok() {}
                continue;
            }

            tokio::select! {
                _ = tokio::time::sleep(self.timing.mailbox_poll) => {}
                _ = dirty_rx.recv() => {
                    debug!("google mailbox '{}' dirty signal received", self.label);
                }
            }
        }
    }

    /// One poll cycle. Always yields the snapshot to publish; the second value
    /// is how long to stay silent when Google throttled us.
    async fn refresh(
        &self,
        client: &GoogleClient,
        st: &mut SyncState,
        previous: Option<&MailboxSnapshot>,
    ) -> (MailboxSnapshot, Option<Duration>) {
        let poll = self.timing.mailbox_poll;
        let label = self.label.as_str();
        let failure = |backoff: &mut ThrottleBackoff, what: &str, e: &anyhow::Error| {
            let reason = failure_reason(what, e);
            warn!("google mailbox '{label}': {reason}");
            match backoff.throttled(e) {
                Some(wait) => {
                    let wait = wait.max(poll);
                    let retry_at =
                        Utc::now() + chrono::Duration::from_std(wait).unwrap_or_default();
                    (
                        MailboxSnapshot::rate_limited(previous, reason, retry_at),
                        Some(wait),
                    )
                }
                None => (
                    MailboxSnapshot::failed(previous, reason),
                    backoff.persistent(poll),
                ),
            }
        };

        match client.ensure_authed().await {
            Ok(Some(prompt)) => {
                let reason = format!("Sign in to Google ({label}) to see your mail");
                return (MailboxSnapshot::unauthenticated_with(prompt, reason), None);
            }
            Ok(None) => {}
            Err(e) => return failure(&mut st.backoff, "Mail sign-in failed", &e),
        }

        if let Err(e) = self.sync(client, st).await {
            return failure(&mut st.backoff, "Mail fetch failed", &e);
        }

        if st.unread.needs_fetch(self.timing.unread_count_ttl) {
            match fetch_unread_count(client).await {
                Ok(n) => {
                    st.unread.value = Some(n);
                    st.unread.fetched_at = Some(Instant::now());
                    st.unread.dirty = false;
                }
                Err(e) => return failure(&mut st.backoff, "Mail unread count failed", &e),
            }
        }

        st.backoff.succeeded();
        prune(&mut st.store);
        debug!(
            "google mailbox '{label}' refreshed ({} messages held)",
            st.store.len()
        );
        let unread = st.unread.value.unwrap_or(0);
        (
            build_snapshot(&st.store, st.email.as_deref(), unread, &self.config),
            None,
        )
    }

    /// Bring the store up to date: full sync, or history since the last point
    /// (falling back to a full sync when Gmail no longer has that point).
    async fn sync(&self, client: &GoogleClient, st: &mut SyncState) -> Result<()> {
        if st.history_id.is_none() {
            return full_sync(client, st).await;
        }
        match incremental_sync(client, st).await {
            Err(e) if is_not_found(&e) => {
                debug!(
                    "google mailbox '{}' history point expired; resyncing",
                    self.label
                );
                st.history_id = None;
                full_sync(client, st).await
            }
            other => other,
        }
    }
}

fn is_not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<GoogleHttpError>()
        .is_some_and(|h| h.status == reqwest::StatusCode::NOT_FOUND)
}

// ── Sync steps ────────────────────────────────────────────────────────────────

async fn full_sync(client: &GoogleClient, st: &mut SyncState) -> Result<()> {
    // The history id comes before the list, so nothing that arrives while we
    // list is missed.
    let profile: Profile = client
        .get_json(&client.gmail_url("/users/me/profile"))
        .await?;
    let history_id = profile.history_id.context("profile has no historyId")?;

    let list_url = client.gmail_url(&with_query(
        "/users/me/messages",
        &[
            ("labelIds", INBOX),
            ("maxResults", &MAX_FETCH_PER_CYCLE.to_string()),
        ],
    ));
    let list: MessageList = client.get_json(&list_url).await?;

    let mut store = HashMap::new();
    for stub in list.messages {
        if let Some((id, msg)) = fetch_message(client, &stub.id).await? {
            store.insert(id, msg);
        }
    }

    st.store = store;
    st.queue.clear();
    st.history_id = Some(history_id);
    st.email = Some(profile.email_address);
    st.unread.dirty = true;
    Ok(())
}

async fn incremental_sync(client: &GoogleClient, st: &mut SyncState) -> Result<()> {
    let start = st.history_id.context("no history point")?.to_string();
    let mut records: Vec<HistoryRecord> = Vec::new();
    let mut page_token: Option<String> = None;
    let latest;
    let mut pages = 0usize;
    loop {
        pages += 1;
        if pages > MAX_HISTORY_PAGES {
            anyhow::bail!("history list exceeded {MAX_HISTORY_PAGES} pages");
        }
        let mut params: Vec<(&str, &str)> = vec![
            ("startHistoryId", &start),
            ("historyTypes", "messageAdded"),
            ("historyTypes", "messageDeleted"),
            ("historyTypes", "labelAdded"),
            ("historyTypes", "labelRemoved"),
            ("maxResults", "500"),
        ];
        if let Some(t) = &page_token {
            params.push(("pageToken", t));
        }
        let page: HistoryPage = client
            .get_json(&client.gmail_url(&with_query("/users/me/history", &params)))
            .await?;
        // A page without `historyId` is an error, never "no changes".
        let page_id = page.history_id.context("history page has no historyId")?;
        records.extend(page.history);
        match page.next_page_token {
            Some(t) if page_token.as_deref() == Some(t.as_str()) => {
                anyhow::bail!("history list repeated a page token")
            }
            Some(t) => page_token = Some(t),
            None => {
                latest = page_id;
                break;
            }
        }
    }

    apply_history(st, records);

    let mut fetched = 0;
    while fetched < MAX_FETCH_PER_CYCLE {
        let Some(id) = st.queue.pop_front() else {
            break;
        };
        fetched += 1;
        match fetch_message(client, &id).await {
            // A message that vanished was deleted; drop it.
            Ok(None) => {}
            Ok(Some((id, msg))) => {
                let was_unread = st.store.get(&id).map(|m| m.unread);
                if was_unread != Some(msg.unread) {
                    st.unread.dirty = true;
                }
                st.store.insert(id, msg);
            }
            Err(e) => {
                st.queue.push_front(id);
                return Err(e);
            }
        }
    }

    st.history_id = Some(latest);
    Ok(())
}

/// Apply history records, in order, to the store and the fetch queue.
fn apply_history(st: &mut SyncState, records: Vec<HistoryRecord>) {
    fn has(labels: &[String], wanted: &str) -> bool {
        labels.iter().any(|l| l == wanted)
    }
    for record in records {
        for added in record.messages_added {
            if has(&added.message.label_ids, INBOX) {
                enqueue(st, added.message.id);
            }
        }
        for deleted in record.messages_deleted {
            remove(st, &deleted.message.id);
        }
        for change in record.labels_added {
            let id = change.message.id;
            if has(&change.label_ids, INBOX) {
                enqueue(st, id.clone());
            }
            if has(&change.label_ids, UNREAD) {
                if let Some(msg) = st.store.get_mut(&id) {
                    msg.unread = true;
                    st.unread.dirty = true;
                }
            }
        }
        for change in record.labels_removed {
            let id = change.message.id;
            if has(&change.label_ids, INBOX) {
                remove(st, &id);
            }
            if has(&change.label_ids, UNREAD) {
                if let Some(msg) = st.store.get_mut(&id) {
                    msg.unread = false;
                    st.unread.dirty = true;
                }
            }
        }
    }
}

fn enqueue(st: &mut SyncState, id: String) {
    if !st.queue.contains(&id) {
        st.queue.push_back(id);
    }
}

fn remove(st: &mut SyncState, id: &str) {
    st.queue.retain(|q| q != id);
    if st.store.remove(id).is_some() {
        st.unread.dirty = true;
    }
}

/// The metadata of one message. `Ok(None)` when it no longer exists or is not
/// in the inbox any more.
async fn fetch_message(client: &GoogleClient, id: &str) -> Result<Option<(String, GmailMsg)>> {
    let url = client.gmail_url(&with_query(
        &format!("/users/me/messages/{}", encode_segment(id)),
        &[
            ("format", "metadata"),
            ("metadataHeaders", "From"),
            ("metadataHeaders", "Subject"),
        ],
    ));
    let raw: RawMessage = match client.get_json(&url).await {
        Ok(raw) => raw,
        Err(e) if is_not_found(&e) => return Ok(None),
        Err(e) => return Err(e),
    };
    if !raw.label_ids.iter().any(|l| l == INBOX) {
        return Ok(None);
    }
    let header = |name: &str| {
        raw.payload
            .as_ref()
            .and_then(|p| p.headers.iter().find(|h| h.name.eq_ignore_ascii_case(name)))
            .map(|h| h.value.clone())
            .unwrap_or_default()
    };
    let internal_date = raw
        .internal_date
        .as_deref()
        .and_then(|d| d.parse::<i64>().ok())
        .and_then(DateTime::from_timestamp_millis);
    let msg = GmailMsg {
        thread_id: raw.thread_id.clone().unwrap_or_else(|| raw.id.clone()),
        from: header("From"),
        subject: header("Subject"),
        internal_date,
        unread: raw.label_ids.iter().any(|l| l == UNREAD),
    };
    Ok(Some((raw.id, msg)))
}

/// The INBOX label's `threadsUnread`. A response without it is a failure.
async fn fetch_unread_count(client: &GoogleClient) -> Result<usize> {
    let info: LabelInfo = client
        .get_json(&client.gmail_url("/users/me/labels/INBOX"))
        .await?;
    let n = info
        .threads_unread
        .context("inbox label response has no threadsUnread")?;
    Ok(n.max(0) as usize)
}

/// Keep only the newest `MAX_STORE` messages.
fn prune(store: &mut HashMap<String, GmailMsg>) {
    if store.len() <= MAX_STORE {
        return;
    }
    let mut by_age: Vec<(Option<DateTime<Utc>>, String)> = store
        .iter()
        .map(|(id, m)| (m.internal_date, id.clone()))
        .collect();
    by_age.sort_by_key(|(date, _)| std::cmp::Reverse(*date));
    let keep: HashSet<String> = by_age
        .into_iter()
        .take(MAX_STORE)
        .map(|(_, id)| id)
        .collect();
    store.retain(|id, _| keep.contains(id));
}

// ── Snapshot builder ──────────────────────────────────────────────────────────

fn build_snapshot(
    store: &HashMap<String, GmailMsg>,
    email: Option<&str>,
    unread_count: usize,
    config: &Config,
) -> MailboxSnapshot {
    let vip_set: HashSet<String> = config
        .vip_senders
        .iter()
        .map(|s| s.to_lowercase())
        .collect();

    let mut items: Vec<MailboxItem> = store
        .iter()
        .map(|(id, msg)| MailboxItem {
            id: id.clone(),
            from: msg.from.clone(),
            subject: msg.subject.clone(),
            received_at: msg.internal_date,
            vip: vip_set.contains(&sender_address(&msg.from).to_lowercase()),
            is_invite: msg.subject.starts_with("Invitation:"),
            is_read: !msg.unread,
            web_link: Some(web_link(email, &msg.thread_id)),
            account: None,
        })
        .collect();

    // Unread first (`false < true`), then newest first.
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
        retry_at: None,
        accounts: Vec::new(),
    }
}

/// The address in `Name <addr>`, or the whole value.
fn sender_address(from: &str) -> &str {
    match (from.rfind('<'), from.rfind('>')) {
        (Some(open), Some(close)) if open < close => from[open + 1..close].trim(),
        _ => from.trim(),
    }
}

/// `https://mail.google.com/mail/?authuser=<email>#all/<thread id>`.
pub(crate) fn web_link(email: Option<&str>, thread_id: &str) -> String {
    let mut url = url::Url::parse("https://mail.google.com/mail/").expect("static URL");
    if let Some(email) = email {
        url.query_pairs_mut().append_pair("authuser", email);
    }
    url.set_fragment(Some(&format!("all/{thread_id}")));
    url.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sender_address_takes_the_angle_part_or_the_whole_value() {
        assert_eq!(sender_address("Ann <ann@x.com>"), "ann@x.com");
        assert_eq!(sender_address("ann@x.com"), "ann@x.com");
    }

    #[test]
    fn web_link_carries_authuser_and_thread() {
        let link = web_link(Some("a@gmail.com"), "t1");
        assert_eq!(
            link,
            "https://mail.google.com/mail/?authuser=a%40gmail.com#all/t1"
        );
    }

    #[test]
    fn history_ids_parse_from_strings_and_numbers() {
        let p: HistoryPage = serde_json::from_str(r#"{"historyId":"42"}"#).unwrap();
        assert_eq!(p.history_id, Some(42));
        let p: HistoryPage = serde_json::from_str(r#"{"historyId":43}"#).unwrap();
        assert_eq!(p.history_id, Some(43));
        let p: HistoryPage = serde_json::from_str("{}").unwrap();
        assert_eq!(p.history_id, None);
    }
}
