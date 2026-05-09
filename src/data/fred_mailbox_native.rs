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

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tracing::{debug, warn};

use crate::{
    config::Config,
    data::{dirty_file, fred_mailbox::MailboxSnapshot, graph_client::GraphClient},
};

// Rebuild alias so we can refer to the item type easily.
use crate::data::fred_mailbox::MailboxItem;

// ── Graph message shape ───────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphMessage {
    id: String,
    subject: Option<String>,
    is_read: Option<bool>,
    received_date_time: Option<DateTime<Utc>>,
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

const MAILBOX_DELTA_PATH: &str =
    "/me/mailFolders/inbox/messages/delta?$top=25&$select=from,subject,receivedDateTime,isRead";

// ── Source ────────────────────────────────────────────────────────────────────

pub struct FredMailboxNativeSource {
    config: Config,
}

impl FredMailboxNativeSource {
    pub fn spawn(config: Config) -> watch::Receiver<Option<MailboxSnapshot>> {
        let (tx, rx) = watch::channel(None);
        let (dirty_tx, mut dirty_rx) = mpsc::unbounded_channel::<()>();

        let dirty_path = config.fred_state_dir().join("mailbox.dirty");
        dirty_file::spawn_watcher(dirty_path, dirty_tx);

        tokio::spawn(async move {
            let source = FredMailboxNativeSource { config };
            source.run(tx, &mut dirty_rx).await;
        });

        rx
    }

    async fn run(
        &self,
        tx: watch::Sender<Option<MailboxSnapshot>>,
        dirty_rx: &mut mpsc::UnboundedReceiver<()>,
    ) {
        let graph = match self.build_graph_client().await {
            Ok(g) => g,
            Err(e) => {
                warn!("failed to build graph client: {e:#}");
                let _ = tx.send(Some(MailboxSnapshot {
                    error: Some(format!("Graph client init failed: {e:#}")),
                    stale: true,
                    ..Default::default()
                }));
                return;
            }
        };

        let delta_file = self.delta_cache_dir().join("mailbox.delta");
        // In-memory message store: id -> item.
        let mut store: HashMap<String, GraphMessage> = HashMap::new();

        loop {
            // Ensure we're authenticated before fetching.
            let auth_prompt = match graph.ensure_authed().await {
                Ok(p) => p,
                Err(e) => {
                    warn!("graph ensure_authed error: {e:#}");
                    None
                }
            };

            if auth_prompt.is_some() {
                // Emit a snapshot with the auth prompt so the view can render it.
                let current = tx.borrow().clone().unwrap_or_default();
                let _ = tx.send(Some(MailboxSnapshot {
                    auth_prompt,
                    ..current
                }));
            } else {
                // Fetch delta.
                match graph
                    .delta::<GraphMessage>(MAILBOX_DELTA_PATH, &delta_file)
                    .await
                {
                    Ok((msgs, _dl)) => {
                        debug!(count = msgs.len(), "mailbox delta received");
                        for msg in msgs {
                            if msg.removed.is_some() {
                                store.remove(&msg.id);
                            } else {
                                store.insert(msg.id.clone(), msg);
                            }
                        }
                        let snap = build_snapshot(&store, &self.config);
                        let _ = tx.send(Some(snap));
                    }
                    Err(e) => {
                        warn!("mailbox delta failed: {e:#}");
                        let mut snap = tx.borrow().clone().unwrap_or_default();
                        snap.stale = true;
                        snap.error = Some(e.to_string());
                        let _ = tx.send(Some(snap));
                    }
                }
            }

            // Poll every 5 s, or immediately on dirty signal.
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {}
                _ = dirty_rx.recv() => {
                    debug!("mailbox dirty signal received");
                }
            }
        }
    }

    async fn build_graph_client(&self) -> Result<GraphClient> {
        let client_id = self.config.graph_client_id.clone().ok_or_else(|| {
            anyhow::anyhow!(
                "graph_client_id not configured. \
                     Add to ~/.config/nostromo/config.toml:\n  \
                     graph_client_id = \"<your-azure-app-id>\"\n\n\
                     Or use --bash-fallback flag to use legacy bash sources."
            )
        })?;

        if client_id.trim().is_empty() {
            return Err(anyhow::anyhow!(
                "graph_client_id is empty. \
                 Set a valid Azure AD application ID in ~/.config/nostromo/config.toml:\n  \
                 graph_client_id = \"<your-azure-app-id>\"\n\n\
                 Or use --bash-fallback flag to use legacy bash sources."
            ));
        }

        let tenant = self
            .config
            .graph_tenant
            .clone()
            .unwrap_or_else(|| "common".to_owned());
        let cache_path = self.config.graph_token_cache_path();

        if let Some(parent) = cache_path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }

        GraphClient::new(client_id, tenant, cache_path).await
    }

    fn delta_cache_dir(&self) -> PathBuf {
        home_dir().join(".cache").join("nostromo")
    }
}

// ── Snapshot builder ──────────────────────────────────────────────────────────

fn build_snapshot(store: &HashMap<String, GraphMessage>, config: &Config) -> MailboxSnapshot {
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
                from,
                subject,
                received_at: msg.received_date_time,
                vip,
                is_invite,
                is_read,
            }
        })
        .collect();

    // Sort: unread first, then by received_at descending.
    items.sort_by(|a, b| {
        b.is_read
            .cmp(&a.is_read)
            .then_with(|| b.received_at.cmp(&a.received_at))
    });

    let unread_count = items.iter().filter(|m| !m.is_read).count();

    MailboxSnapshot {
        generated_at: Some(Utc::now()),
        unread_count,
        items,
        stale: false,
        error: None,
        auth_prompt: None,
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
