//! `~/.nostromo/daemon-terminals.json`: which terminal panes exist, so a
//! restarted daemon can tell the app what became of them.
//!
//! Nothing about a terminal's bytes is stored: only its identity, place and
//! kind. At daemon start [`reconcile`] turns the records into what survives a
//! daemon stop: a **local** terminal's shell is gone but its pane stays,
//! `ended` with `ended_reason = "daemon_stopped"` (Restart works); a **remote**
//! (`ecs`) terminal's pane is removed and reported closed `daemon_stopped`.
//!
//! The pane tree and this file are written one after the other, so a crash
//! can leave them disagreeing; [`reconcile`] settles that against the tree: a
//! record whose leaf is gone is closed (`pane_missing`), and a terminal-shaped
//! leaf no record claims is removed.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::ipc::pane_registry::PaneRegistry;
use crate::ipc::protocol::{
    TerminalClosedInfo, TerminalInfo, TerminalKind, TerminalRequester, TerminalStatus,
    TerminalTarget,
};

/// Why a terminal ended or closed when the daemon stopped under it.
pub const DAEMON_STOPPED: &str = "daemon_stopped";
/// Why a terminal was closed at start: its record survived but its pane did not.
pub const PANE_MISSING: &str = "pane_missing";

/// The size an ended terminal reports until someone resizes it.
pub const DEFAULT_COLS: u16 = 80;
pub const DEFAULT_ROWS: u16 = 24;

/// One persisted terminal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalRecord {
    pub terminal_id: String,
    pub tag: String,
    pub pane_id: String,
    pub kind: TerminalKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TerminalTarget>,
    #[serde(default = "user_requester")]
    pub requested_by: TerminalRequester,
}

fn user_requester() -> TerminalRequester {
    TerminalRequester {
        kind: "user".into(),
        tag: None,
    }
}

#[derive(Default, Serialize, Deserialize)]
struct StoreFile {
    #[serde(default)]
    terminals: Vec<TerminalRecord>,
}

/// The store file, or nothing (tests).
#[derive(Debug, Clone)]
pub struct TerminalStore {
    path: Option<PathBuf>,
}

impl TerminalStore {
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self {
            path: Some(path.into()),
        }
    }

    pub fn in_memory() -> Self {
        Self { path: None }
    }

    /// `~/.nostromo/daemon-terminals.json`.
    pub fn default_path() -> PathBuf {
        dirs_next::home_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join(".nostromo")
            .join("daemon-terminals.json")
    }

    /// The persisted records; none if the file is missing or unreadable.
    pub fn load(&self) -> Vec<TerminalRecord> {
        let Some(path) = &self.path else {
            return Vec::new();
        };
        match std::fs::read(path) {
            Ok(bytes) => match serde_json::from_slice::<StoreFile>(&bytes) {
                Ok(file) => file.terminals,
                Err(e) => {
                    warn!(path = %path.display(), "unreadable terminal store, ignored: {e}");
                    Vec::new()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => {
                warn!(path = %path.display(), "cannot read terminal store: {e}");
                Vec::new()
            }
        }
    }

    /// Replace the persisted records (atomically, mode `0600`).
    pub fn save(&self, records: &[TerminalRecord]) {
        let Some(path) = &self.path else {
            return;
        };
        let file = StoreFile {
            terminals: records.to_vec(),
        };
        if let Err(e) = write_atomic(path, &file) {
            warn!(path = %path.display(), "cannot write terminal store: {e}");
        }
    }
}

fn write_atomic(path: &Path, file: &StoreFile) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let bytes = serde_json::to_vec_pretty(file).map_err(std::io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(&bytes)?;
    f.sync_data()?;
    std::fs::rename(&tmp, path)
}

/// What [`reconcile`] made of the persisted records.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Reconciled {
    /// Local terminals: their panes stay, `ended / daemon_stopped`.
    pub ended: Vec<TerminalInfo>,
    /// Remote terminals: their panes are gone, closed `daemon_stopped`; and,
    /// whatever their kind, terminals whose pane was already gone (`pane_missing`).
    pub closed: Vec<TerminalClosedInfo>,
}

/// Settle the records a previous daemon left. Local records keep their leaf
/// (registered as a terminal leaf); remote records lose theirs. With a pane
/// registry the records are also checked against the pane tree, both ways: a
/// record with no leaf is closed `pane_missing`, and a terminal-shaped leaf
/// with no record is removed from the tree.
pub fn reconcile(records: Vec<TerminalRecord>, mut panes: Option<&mut PaneRegistry>) -> Reconciled {
    let mut out = Reconciled::default();
    if let Some(panes) = panes.as_deref_mut() {
        remove_unclaimed_leaves(panes, &records);
    }
    for r in records {
        let leaf_gone = panes
            .as_deref()
            .is_some_and(|p| !p.pane_ids(&r.tag).contains(&r.pane_id));
        if leaf_gone {
            warn!(pane_id = %r.pane_id, "terminal record without a pane; closing it");
            out.closed.push(TerminalClosedInfo {
                terminal_id: r.terminal_id,
                tag: r.tag,
                pane_id: r.pane_id,
                label: r.label,
                kind: r.kind,
                reason: PANE_MISSING.into(),
                exit_code: None,
                target: r.target,
            });
            continue;
        }
        match r.kind {
            TerminalKind::Local => {
                if let Some(panes) = panes.as_deref_mut() {
                    panes.register_terminal_leaf(&r.tag, &r.pane_id);
                }
                out.ended.push(TerminalInfo {
                    terminal_id: r.terminal_id,
                    tag: r.tag,
                    pane_id: r.pane_id,
                    kind: r.kind,
                    label: r.label,
                    cwd: r.cwd,
                    target: r.target,
                    status: TerminalStatus::Ended,
                    exit_code: None,
                    ended_reason: Some(DAEMON_STOPPED.into()),
                    cols: DEFAULT_COLS,
                    rows: DEFAULT_ROWS,
                    requested_by: r.requested_by,
                    opened_by_request: None,
                    follower: None,
                    idle_closes_at: None,
                });
            }
            TerminalKind::Ecs => {
                if let Some(panes) = panes.as_deref_mut() {
                    panes.unregister_terminal_leaf(&r.tag, &r.pane_id);
                    panes.remove_terminal_leaf(&r.tag, &r.pane_id);
                }
                out.closed.push(TerminalClosedInfo {
                    terminal_id: r.terminal_id,
                    tag: r.tag,
                    pane_id: r.pane_id,
                    label: r.label,
                    kind: r.kind,
                    reason: DAEMON_STOPPED.into(),
                    exit_code: None,
                    target: r.target,
                });
            }
        }
    }
    out
}

/// Remove every leaf shaped like a terminal's (`terminal-<8 hex>`) that no
/// record names: the daemon crashed after placing it and before saving.
fn remove_unclaimed_leaves(panes: &mut PaneRegistry, records: &[TerminalRecord]) {
    let tags: Vec<String> = panes
        .all_layouts()
        .into_iter()
        .map(|(tag, _, _)| tag)
        .collect();
    for tag in tags {
        for pane_id in panes.pane_ids(&tag) {
            let claimed = records.iter().any(|r| r.tag == tag && r.pane_id == pane_id);
            if !claimed && is_terminal_pane_id(&pane_id) {
                warn!(%pane_id, "terminal pane without a record; removing it");
                panes.unregister_terminal_leaf(&tag, &pane_id);
                panes.remove_terminal_leaf(&tag, &pane_id);
            }
        }
    }
}

/// `terminal-` followed by 8 hex digits: the ids `TerminalManager` mints.
fn is_terminal_pane_id(id: &str) -> bool {
    id.strip_prefix(super::PANE_PREFIX)
        .is_some_and(|hex| hex.len() == 8 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}
