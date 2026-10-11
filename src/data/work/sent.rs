//! The sent ledger (`~/.nostromo/teri/sent.json`): which work items were sent
//! to an agent focus or a Mother job.
//!
//! It maps `item_id -> [SentMarker]`. The hub merges the *live* markers into
//! `WorkItem.sent`, and `create_focus_core` consults it for item-keyed
//! duplicate protection. A marker is live while its focus has a live session
//! or its Mother job has not been archived; the ledger itself does not know
//! either, so every reader passes the liveness test in (`is_live`).
//!
//! The file is written atomically (temp file + rename) and is not a secret
//! (ids, labels, timestamps), but is still 0600 like the rest of `~/.nostromo/teri`.

use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use tokio::sync::watch;
use tracing::warn;

use super::model::SentMarker;

/// How often the hub drops markers whose focus or job is gone.
pub const PRUNE_INTERVAL: Duration = Duration::from_secs(10 * 60);

/// After a daemon start, sessions are respawned as the Mac reconnects: wait
/// this long before the first prune so a restart does not forget live work.
pub const STARTUP_GRACE: Duration = Duration::from_secs(60);

/// `~/.nostromo/teri` (override with `NOSTROMO_TERI_DIR`, used by tests).
pub fn teri_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("NOSTROMO_TERI_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("teri")
}

/// The ledger file inside [`teri_dir`].
pub fn default_path() -> PathBuf {
    teri_dir().join("sent.json")
}

/// The ledger: `item_id -> markers`, mirrored to one JSON file.
pub struct SentLedger {
    path: PathBuf,
    markers: Mutex<BTreeMap<String, Vec<SentMarker>>>,
    /// Bumped on every change so the hub can re-broadcast affected items.
    changes: watch::Sender<u64>,
}

impl SentLedger {
    /// Open the ledger at `path`, loading what is there. A missing file is an
    /// empty ledger; an unreadable one is too (logged), so a corrupt file
    /// never blocks sending.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let markers = load(&path);
        Self { path, markers: Mutex::new(markers), changes: watch::channel(0).0 }
    }

    /// Record that `item_id` was sent. Persisted before it returns; on a write
    /// error the in-memory ledger still has the marker (this run's duplicate
    /// protection holds) and the error is returned for the caller to log.
    pub fn record(&self, item_id: &str, marker: SentMarker) -> std::io::Result<()> {
        let mut markers = self.markers.lock().unwrap();
        // A closed focus's tag is reused by the next one for the same title: keep
        // one marker per target, not two chips pointing at the same place.
        let list = markers.entry(item_id.to_owned()).or_default();
        list.retain(|m| !(m.kind == marker.kind && m.target_id == marker.target_id));
        list.push(marker);
        let result = persist(&self.path, &markers);
        drop(markers);
        self.changes.send_modify(|n| *n += 1);
        result
    }

    /// Every marker for `item_id`, live or not.
    pub fn markers(&self, item_id: &str) -> Vec<SentMarker> {
        self.markers.lock().unwrap().get(item_id).cloned().unwrap_or_default()
    }

    /// The markers for `item_id` that `is_live` accepts.
    pub fn live_markers(
        &self,
        item_id: &str,
        is_live: &dyn Fn(&SentMarker) -> bool,
    ) -> Vec<SentMarker> {
        self.markers(item_id).into_iter().filter(|m| is_live(m)).collect()
    }

    /// Item ids that have at least one marker.
    pub fn item_ids(&self) -> Vec<String> {
        self.markers.lock().unwrap().keys().cloned().collect()
    }

    /// Drop every marker `is_live` rejects; returns how many went. Persists
    /// and notifies subscribers only when something was dropped.
    pub fn prune(&self, is_live: &dyn Fn(&SentMarker) -> bool) -> usize {
        let mut markers = self.markers.lock().unwrap();
        let before: usize = markers.values().map(Vec::len).sum();
        markers.retain(|_, list| {
            list.retain(|m| is_live(m));
            !list.is_empty()
        });
        let removed = before - markers.values().map(Vec::len).sum::<usize>();
        if removed > 0 {
            if let Err(e) = persist(&self.path, &markers) {
                warn!("sent ledger: could not write {}: {e}", self.path.display());
            }
            drop(markers);
            self.changes.send_modify(|n| *n += 1);
        }
        removed
    }

    /// A receiver that fires whenever markers are added or pruned.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }
}

fn load(path: &Path) -> BTreeMap<String, Vec<SentMarker>> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    match serde_json::from_str(&text) {
        Ok(markers) => markers,
        Err(e) => {
            warn!("sent ledger: ignoring unreadable {}: {e}", path.display());
            BTreeMap::new()
        }
    }
}

/// Write the ledger next to `path` and rename it into place.
fn persist(path: &Path, markers: &BTreeMap<String, Vec<SentMarker>>) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    create_private_dir(dir)?;
    let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(markers).map_err(std::io::Error::other)?;
    let write = || -> std::io::Result<()> {
        let mut file = private_file(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    let result = write();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Create `dir` (and parents) with mode 0700 for the leaf.
pub fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Create (truncating) a file with mode 0600.
pub fn private_file(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// The ids of Mother's current jobs. `None` means unknown (the list failed):
/// callers treat unknown as "still there", never as "no jobs".
pub async fn mother_job_ids() -> Option<HashSet<String>> {
    match crate::mother::list_jobs().await {
        Ok(jobs) => Some(jobs.into_iter().map(|j| j.id).collect()),
        Err(e) => {
            warn!("sent ledger: could not list Mother jobs: {e}");
            None
        }
    }
}

static LEDGER: RwLock<Option<Arc<SentLedger>>> = RwLock::new(None);

/// The process-wide ledger, opened at [`default_path`] on first use.
pub fn ledger() -> Arc<SentLedger> {
    if let Some(ledger) = LEDGER.read().unwrap().as_ref() {
        return Arc::clone(ledger);
    }
    let mut slot = LEDGER.write().unwrap();
    Arc::clone(slot.get_or_insert_with(|| Arc::new(SentLedger::new(default_path()))))
}

/// Replace the process-wide ledger (tests point it at a temp dir).
pub fn install_ledger(ledger: Arc<SentLedger>) {
    *LEDGER.write().unwrap() = Some(ledger);
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn marker(kind: &str, target: &str) -> SentMarker {
        SentMarker {
            kind: kind.into(),
            target_id: target.into(),
            label: format!("label {target}"),
            created_at: Utc::now(),
        }
    }

    #[test]
    fn a_recorded_marker_survives_reopening_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("teri").join("sent.json");
        let ledger = SentLedger::new(&path);
        ledger.record("doc:nostromo:ideas/x.md", marker("focus", "claudia-x")).unwrap();

        let reopened = SentLedger::new(&path);
        let got = reopened.markers("doc:nostromo:ideas/x.md");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].target_id, "claudia-x");
        assert!(reopened.markers("doc:nostromo:other").is_empty());
    }

    #[test]
    fn recording_the_same_target_again_replaces_its_marker() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = SentLedger::new(dir.path().join("sent.json"));
        ledger.record("jira:A-1", marker("focus", "cody-a-1")).unwrap();
        ledger.record("jira:A-1", marker("focus", "cody-a-1")).unwrap();
        ledger.record("jira:A-1", marker("mother_job", "cody-a-1")).unwrap();
        assert_eq!(ledger.markers("jira:A-1").len(), 2, "same kind+target collapses; other kinds do not");
    }

    #[test]
    fn live_markers_only_returns_what_the_probe_accepts() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = SentLedger::new(dir.path().join("sent.json"));
        ledger.record("jira:A-1", marker("focus", "dead")).unwrap();
        ledger.record("jira:A-1", marker("mother_job", "alive")).unwrap();

        let live = ledger.live_markers("jira:A-1", &|m| m.target_id == "alive");
        assert_eq!(live.len(), 1);
        assert_eq!(live[0].target_id, "alive");
        assert_eq!(ledger.markers("jira:A-1").len(), 2, "filtering never deletes");
    }

    #[test]
    fn prune_drops_dead_markers_persists_and_notifies() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.json");
        let ledger = SentLedger::new(&path);
        ledger.record("jira:A-1", marker("focus", "dead")).unwrap();
        ledger.record("jira:A-2", marker("focus", "alive")).unwrap();
        let mut rx = ledger.subscribe();
        rx.borrow_and_update();

        assert_eq!(ledger.prune(&|m| m.target_id == "alive"), 1);

        assert!(rx.has_changed().unwrap(), "pruning must tell the hub");
        let reopened = SentLedger::new(&path);
        assert!(reopened.markers("jira:A-1").is_empty());
        assert_eq!(reopened.item_ids(), vec!["jira:A-2".to_string()]);
    }

    #[test]
    fn prune_with_nothing_dead_does_not_notify() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = SentLedger::new(dir.path().join("sent.json"));
        ledger.record("jira:A-1", marker("focus", "alive")).unwrap();
        let mut rx = ledger.subscribe();
        rx.borrow_and_update();
        assert_eq!(ledger.prune(&|_| true), 0);
        assert!(!rx.has_changed().unwrap());
    }

    #[test]
    fn a_corrupt_file_is_an_empty_ledger_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sent.json");
        std::fs::write(&path, "{not json").unwrap();
        let ledger = SentLedger::new(&path);
        assert!(ledger.item_ids().is_empty());
        ledger.record("jira:A-1", marker("focus", "t")).unwrap();
        assert_eq!(SentLedger::new(&path).markers("jira:A-1").len(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn the_file_and_directory_are_private_and_no_temp_file_is_left() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let teri = dir.path().join("teri");
        let path = teri.join("sent.json");
        SentLedger::new(&path).record("jira:A-1", marker("focus", "t")).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&teri), 0o700);
        assert_eq!(mode(&path), 0o600);
        let names: Vec<_> = std::fs::read_dir(&teri)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["sent.json".to_string()]);
    }
}
