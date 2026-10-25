//! Multi-account Fred: per-account sources, one merged mailbox and calendar,
//! and the detail router.
//!
//! `nostromd` calls [`spawn`] only when `[[fred_accounts]]` is configured;
//! without it the original single-Graph code path runs untouched.
//!
//! The merge functions are pure ([`merge_mailboxes`], [`merge_calendars`]) so
//! the state rules can be tested without a daemon. Their invariant, from the
//! rate-limit contract: a merged snapshot is never `Fresh` or `Empty` while any
//! account is degraded or unauthenticated.
//!
//! Privacy: logs carry counts, labels and states only.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::{Config, FredAccount, FredAccounts, FredProvider},
    data::{
        dirty_file,
        fred_calendar::{next_and_sweater, CalendarEvent, CalendarSnapshot},
        fred_calendar_native::FredCalendarNativeSource,
        fred_detail::GraphFredDetail,
        fred_mailbox::{AccountStatus, MailboxItem, MailboxSnapshot},
        fred_mailbox_native::{shared_graph_client, FredMailboxNativeSource, FredTiming},
        google_calendar::GoogleCalendarSource,
        google_client::{GoogleClient, GoogleOAuthClient, GoogleOptions},
        google_detail::GoogleFredDetail,
        google_mailbox::GoogleMailboxSource,
        graph_client::DeviceFlowPrompt,
        work::model::{SourceState, WorkDetail, WorkError},
        work::service::{install_fred_detail_service, FredDetailService},
    },
};

type MailboxRx = watch::Receiver<Option<MailboxSnapshot>>;
type CalendarRx = watch::Receiver<Option<CalendarSnapshot>>;

/// Resolves with `(source index, still alive)` when that source changes.
type ChangeFuture<'a> = Pin<Box<dyn Future<Output = (usize, bool)> + Send + 'a>>;

/// Most merged inbox rows.
const MAX_MERGED_ITEMS: usize = 100;

// ── Spawning ──────────────────────────────────────────────────────────────────

/// Start every configured account and the two merge tasks. Returns the merged
/// mailbox and calendar receivers (empty until the first account reports).
pub fn spawn(config: &Config) -> (MailboxRx, CalendarRx) {
    let (mail_tx, mail_rx) = watch::channel(None);
    let (cal_tx, cal_rx) = watch::channel(None);
    let config = config.clone();
    tokio::spawn(async move { start(config, mail_tx, cal_tx).await });
    (mail_rx, cal_rx)
}

async fn start(
    config: Config,
    mail_tx: watch::Sender<Option<MailboxSnapshot>>,
    cal_tx: watch::Sender<Option<CalendarSnapshot>>,
) {
    let (resolved, warnings) = config.resolve_fred_accounts();
    for w in &warnings {
        warn!("{w}");
    }
    let accounts = match resolved {
        FredAccounts::Configured(a) if !a.is_empty() => a,
        _ => {
            let reason = "No usable Fred accounts in config.toml (see the daemon log)";
            let _ = mail_tx.send(Some(not_configured_mailbox(reason)));
            let _ = cal_tx.send(Some(not_configured_calendar(reason)));
            return;
        }
    };

    let oauth = if accounts.iter().any(|a| a.provider == FredProvider::Google) {
        let path = config.google_oauth_client_path();
        match GoogleOAuthClient::load(&path) {
            Ok(c) => Ok(c),
            Err(e) => {
                // Why it is invalid goes to the log; the file's contents never do.
                warn!("google oauth client file unusable: {e:#}");
                Err(format!(
                    "Google OAuth client file missing or invalid: {}",
                    path.display()
                ))
            }
        }
    } else {
        Err(String::new())
    };

    // One watcher per sentinel, fanned out: the watcher deletes the file, so
    // two watchers on one path would race.
    let mut mail_dirty: Vec<mpsc::UnboundedSender<()>> = Vec::new();
    let mut cal_dirty: Vec<mpsc::UnboundedSender<()>> = Vec::new();

    let mut mail_parts: Vec<MailboxRx> = Vec::new();
    let mut cal_parts: Vec<CalendarRx> = Vec::new();
    let mut detail: HashMap<String, Arc<dyn FredDetailService>> = HashMap::new();

    for account in &accounts {
        let (mtx, mrx) = mpsc::unbounded_channel();
        let (ctx, crx) = mpsc::unbounded_channel();
        match account.provider {
            FredProvider::Google => match &oauth {
                Ok(oauth) => {
                    let client =
                        GoogleClient::shared(account, oauth.clone(), GoogleOptions::default());
                    match client {
                        Ok(client) => {
                            mail_dirty.push(mtx);
                            cal_dirty.push(ctx);
                            mail_parts.push(GoogleMailboxSource::spawn_with_dirty(
                                client.clone(),
                                account.label.clone(),
                                config.clone(),
                                FredTiming::default(),
                                mrx,
                            ));
                            cal_parts.push(GoogleCalendarSource::spawn_with_dirty(
                                client.clone(),
                                account.label.clone(),
                                FredTiming::default(),
                                crx,
                            ));
                            detail.insert(
                                account.label.clone(),
                                Arc::new(GoogleFredDetail::new(client)),
                            );
                        }
                        Err(e) => {
                            warn!("google client for '{}' failed: {e:#}", account.label);
                            let reason = "Google client could not start (see the daemon log)";
                            mail_parts.push(fixed(not_configured_mailbox(reason)));
                            cal_parts.push(fixed(not_configured_calendar(reason)));
                        }
                    }
                }
                Err(reason) => {
                    mail_parts.push(fixed(not_configured_mailbox(reason)));
                    cal_parts.push(fixed(not_configured_calendar(reason)));
                }
            },
            FredProvider::Microsoft => match shared_graph_client(&config).await {
                Ok(graph) => {
                    mail_dirty.push(mtx);
                    cal_dirty.push(ctx);
                    mail_parts.push(FredMailboxNativeSource::spawn_with_dirty(
                        graph.clone(),
                        config.clone(),
                        FredTiming::default(),
                        mrx,
                    ));
                    cal_parts.push(FredCalendarNativeSource::spawn_with_dirty(
                        graph.clone(),
                        config.clone(),
                        FredTiming::default(),
                        crx,
                    ));
                    detail.insert(account.label.clone(), Arc::new(GraphFredDetail::new(graph)));
                }
                Err(unavailable) => {
                    let (m, c) = (
                        MailboxSnapshot::from(unavailable.clone()),
                        CalendarSnapshot::from(unavailable),
                    );
                    warn!("microsoft account '{}' unavailable", account.label);
                    mail_parts.push(fixed(m));
                    cal_parts.push(fixed(c));
                }
            },
        }
    }

    fan_out(config.fred_state_dir().join("mailbox.dirty"), mail_dirty);
    fan_out(config.fred_state_dir().join("calendar.dirty"), cal_dirty);

    install_fred_detail_service(Arc::new(FredDetailRouter::new(detail)));

    let accounts = Arc::new(accounts);
    tokio::spawn(merge_task(
        accounts.clone(),
        mail_parts,
        mail_tx,
        merge_mailboxes,
    ));
    tokio::spawn(merge_task(accounts, cal_parts, cal_tx, merge_calendars));
}

fn fixed<T: Clone + Send + Sync + 'static>(value: T) -> watch::Receiver<Option<T>> {
    watch::channel(Some(value)).1
}

fn fan_out(path: std::path::PathBuf, mut targets: Vec<mpsc::UnboundedSender<()>>) {
    if targets.is_empty() {
        return;
    }
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();
    dirty_file::spawn_watcher(path, tx);
    tokio::spawn(async move {
        while rx.recv().await.is_some() {
            targets.retain(|t| t.send(()).is_ok());
            if targets.is_empty() {
                break;
            }
        }
    });
}

/// Recompute the merged snapshot whenever any account's snapshot changes.
async fn merge_task<S, F>(
    accounts: Arc<Vec<FredAccount>>,
    mut parts: Vec<watch::Receiver<Option<S>>>,
    out: watch::Sender<Option<S>>,
    merge: F,
) where
    S: Clone + Send + Sync + 'static,
    F: Fn(DateTime<Utc>, &[(&FredAccount, Option<&S>)]) -> S + Send + 'static,
{
    let mut closed = vec![false; parts.len()];
    let mut first = true;
    loop {
        let snapshots: Vec<Option<S>> = parts.iter().map(|r| r.borrow().clone()).collect();
        // Nothing has reported yet: stay empty, like a legacy source.
        if !(first && snapshots.iter().all(Option::is_none)) {
            let view: Vec<(&FredAccount, Option<&S>)> = accounts
                .iter()
                .zip(snapshots.iter())
                .map(|(a, s)| (a, s.as_ref()))
                .collect();
            if out.send(Some(merge(Utc::now(), &view))).is_err() {
                return;
            }
        }
        first = false;

        // A source whose task ended (or a fixed receiver) keeps its last
        // value but is no longer waited on, or `changed()` would spin.
        let waits: Vec<ChangeFuture<'_>> = parts
            .iter_mut()
            .enumerate()
            .filter(|(i, _)| !closed[*i])
            .map(|(i, r)| {
                Box::pin(async move { (i, r.changed().await.is_ok()) }) as ChangeFuture<'_>
            })
            .collect();
        if waits.is_empty() {
            return;
        }
        let ((index, alive), _, _) = futures::future::select_all(waits).await;
        if !alive {
            debug!("fred account source {index} stopped");
            closed[index] = true;
        }
    }
}

fn not_configured_mailbox(reason: &str) -> MailboxSnapshot {
    MailboxSnapshot {
        generated_at: Some(Utc::now()),
        state: SourceState::NotConfigured,
        error: Some(reason.to_owned()),
        ..Default::default()
    }
}

fn not_configured_calendar(reason: &str) -> CalendarSnapshot {
    CalendarSnapshot {
        generated_at: Some(Utc::now()),
        sweater: "sage".to_owned(),
        state: SourceState::NotConfigured,
        error: Some(reason.to_owned()),
        ..Default::default()
    }
}

// ── Merge ─────────────────────────────────────────────────────────────────────

/// What the merge needs from one account's snapshot.
struct PartView<'a> {
    account: &'a FredAccount,
    state: SourceState,
    error: Option<&'a str>,
    retry_at: Option<DateTime<Utc>>,
    updated_at: Option<DateTime<Utc>>,
    prompt: Option<&'a DeviceFlowPrompt>,
    /// The snapshot exists and has had a successful fetch.
    has_data: bool,
}

/// The state, error, prompt, retry and per-account rules shared by both merges.
struct Combined {
    state: SourceState,
    error: Option<String>,
    auth_prompt: Option<DeviceFlowPrompt>,
    retry_at: Option<DateTime<Utc>>,
    updated_at: Option<DateTime<Utc>>,
    accounts: Vec<AccountStatus>,
}

fn provider_name(p: FredProvider) -> &'static str {
    match p {
        FredProvider::Google => "google",
        FredProvider::Microsoft => "microsoft",
    }
}

fn is_degraded(state: SourceState) -> bool {
    matches!(
        state,
        SourceState::Stale
            | SourceState::Error
            | SourceState::RateLimited
            | SourceState::NotConfigured
    )
}

/// `has_content`: the merged view shows at least one item / event / unread.
fn combine(parts: &[PartView<'_>], has_content: bool) -> Combined {
    let any_data = parts.iter().any(|p| p.has_data);
    let state = if parts.iter().all(|p| p.state == SourceState::Loading) {
        SourceState::Loading
    } else if parts
        .iter()
        .any(|p| p.state == SourceState::Unauthenticated)
    {
        SourceState::Unauthenticated
    } else if parts.iter().any(|p| is_degraded(p.state)) {
        if any_data {
            SourceState::Stale
        } else {
            parts
                .iter()
                .map(|p| p.state)
                .fold(SourceState::Loading, |worst, s| {
                    if s.severity() > worst.severity() {
                        s
                    } else {
                        worst
                    }
                })
        }
    } else if parts.iter().any(|p| p.state == SourceState::Loading) {
        // An account that has not reported yet may hold anything: never claim
        // `Fresh` or `Empty` for the merge, even if the others are healthy.
        SourceState::Loading
    } else if has_content {
        SourceState::Fresh
    } else {
        SourceState::Empty
    };

    let errors: Vec<String> = parts
        .iter()
        .filter_map(|p| p.error.map(|e| format!("{}: {e}", p.account.label)))
        .collect();

    let auth_prompt = parts
        .iter()
        .find(|p| p.state == SourceState::Unauthenticated)
        .and_then(|p| {
            let mut prompt = p.prompt?.clone();
            prompt
                .account
                .get_or_insert_with(|| p.account.label.clone());
            prompt
                .provider
                .get_or_insert_with(|| provider_name(p.account.provider).to_owned());
            Some(prompt)
        });

    Combined {
        state,
        error: (!errors.is_empty()).then(|| errors.join("; ")),
        auth_prompt,
        retry_at: parts
            .iter()
            .filter(|p| p.state == SourceState::RateLimited)
            .filter_map(|p| p.retry_at)
            .min(),
        updated_at: parts
            .iter()
            .filter(|p| p.has_data)
            .filter_map(|p| p.updated_at)
            .min(),
        accounts: parts
            .iter()
            .map(|p| AccountStatus {
                account: p.account.label.clone(),
                provider: provider_name(p.account.provider).to_owned(),
                state: p.state,
                error: p.error.map(str::to_owned),
                retry_at: p.retry_at,
                updated_at: p.updated_at,
            })
            .collect(),
    }
}

fn prefixed(label: &str, id: &str) -> String {
    format!("{label}:{id}")
}

/// One merged inbox from every account, in config order. Pure.
pub fn merge_mailboxes(
    now: DateTime<Utc>,
    parts: &[(&FredAccount, Option<&MailboxSnapshot>)],
) -> MailboxSnapshot {
    let views: Vec<PartView<'_>> = parts
        .iter()
        .map(|(account, snap)| PartView {
            account,
            state: snap.map_or(SourceState::Loading, |s| s.state),
            error: snap.and_then(|s| s.error.as_deref()),
            retry_at: snap.and_then(|s| s.retry_at),
            updated_at: snap.and_then(|s| s.updated_at),
            prompt: snap.and_then(|s| s.auth_prompt.as_ref()),
            has_data: snap.is_some_and(|s| s.updated_at.is_some()),
        })
        .collect();

    let mut rows: Vec<(usize, MailboxItem)> = Vec::new();
    let mut unread_count = 0;
    for (index, (account, snap)) in parts.iter().enumerate() {
        let Some(snap) = snap.filter(|s| s.updated_at.is_some()) else {
            continue;
        };
        unread_count += snap.unread_count;
        rows.extend(snap.items.iter().map(|item| {
            let mut item = item.clone();
            item.id = prefixed(&account.label, &item.id);
            item.account = Some(account.label.clone());
            (index, item)
        }));
    }
    rows.sort_by(|(ai, a), (bi, b)| {
        a.is_read
            .cmp(&b.is_read)
            .then_with(|| b.received_at.cmp(&a.received_at))
            .then_with(|| ai.cmp(bi))
            .then_with(|| a.id.cmp(&b.id))
    });
    rows.truncate(MAX_MERGED_ITEMS);
    let items: Vec<MailboxItem> = rows.into_iter().map(|(_, i)| i).collect();

    let c = combine(&views, !items.is_empty() || unread_count > 0);
    MailboxSnapshot {
        generated_at: Some(now),
        unread_count,
        items,
        stale: c.state == SourceState::Stale,
        error: c.error,
        auth_prompt: c.auth_prompt,
        state: c.state,
        updated_at: c.updated_at,
        retry_at: c.retry_at,
        accounts: c.accounts,
    }
}

/// One merged Today list from every account, in config order. Pure.
pub fn merge_calendars(
    now: DateTime<Utc>,
    parts: &[(&FredAccount, Option<&CalendarSnapshot>)],
) -> CalendarSnapshot {
    let views: Vec<PartView<'_>> = parts
        .iter()
        .map(|(account, snap)| PartView {
            account,
            state: snap.map_or(SourceState::Loading, |s| s.state),
            error: snap.and_then(|s| s.error.as_deref()),
            retry_at: snap.and_then(|s| s.retry_at),
            updated_at: snap.and_then(|s| s.updated_at),
            prompt: snap.and_then(|s| s.auth_prompt.as_ref()),
            has_data: snap.is_some_and(|s| s.updated_at.is_some()),
        })
        .collect();

    // A meeting invited to two accounts is kept once, from the earlier account.
    let mut seen: HashSet<(String, Option<DateTime<Utc>>)> = HashSet::new();
    let mut events: Vec<CalendarEvent> = Vec::new();
    for (account, snap) in parts {
        let Some(snap) = snap.filter(|s| s.updated_at.is_some()) else {
            continue;
        };
        let mut mine = Vec::new();
        for event in &snap.events {
            if let Some(key) = &event.dedupe_key {
                if seen.contains(&(key.clone(), event.start)) {
                    continue;
                }
                mine.push((key.clone(), event.start));
            }
            let mut event = event.clone();
            event.id = prefixed(&account.label, &event.id);
            event.account = Some(account.label.clone());
            events.push(event);
        }
        seen.extend(mine);
    }
    events.sort_by_key(|e| (e.start, e.end));
    let (next, sweater) = next_and_sweater(&events, now);

    let c = combine(&views, !events.is_empty());
    CalendarSnapshot {
        stale: c.state == SourceState::Stale,
        events,
        next,
        sweater,
        error: c.error,
        generated_at: Some(now),
        state: c.state,
        updated_at: c.updated_at,
        auth_prompt: c.auth_prompt,
        retry_at: c.retry_at,
        accounts: c.accounts,
    }
}

// ── Detail routing ────────────────────────────────────────────────────────────

/// Routes `mail:<label>:<id>` / `event:<label>:<id>` to that account's service.
pub struct FredDetailRouter {
    services: HashMap<String, Arc<dyn FredDetailService>>,
}

impl FredDetailRouter {
    pub fn new(services: HashMap<String, Arc<dyn FredDetailService>>) -> Self {
        Self { services }
    }
}

#[async_trait]
impl FredDetailService for FredDetailRouter {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        let not_found = || WorkError::new("not_found", "Not a Fred mail or calendar item");
        let (kind, rest) = ["mail:", "event:"]
            .iter()
            .find_map(|k| item_id.strip_prefix(k).map(|r| (*k, r)))
            .ok_or_else(not_found)?;
        let (label, native) = rest.split_once(':').ok_or_else(not_found)?;
        let service = self.services.get(label).ok_or_else(not_found)?;
        let mut detail = service.detail(&format!("{kind}{native}")).await?;
        // The Mac matches responses by the id it asked for.
        detail.item_id = item_id.to_owned();
        Ok(detail)
    }
}
