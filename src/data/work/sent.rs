//! The sent ledger (`~/.nostromo/teri/sent.json`): which work items were sent
//! to an agent focus or a Mother job.
//!
//! It maps `item_id -> [SentMarker]`. The hub merges the *live* markers into
//! `WorkItem.sent`, and `create_focus_core` consults it for item-keyed
//! duplicate protection. A marker is live while its focus has a live session
//! or its Mother job has not been archived; the ledger itself does not know
//! either, so every reader passes the liveness test in (`is_live`).
//!
//! ## After a daemon restart
//!
//! A restarted daemon has no sessions and an empty focus registry until the Mac
//! reconnects and pushes its own. [`SessionManager::registry_known`] needs TWO
//! agreeing non-empty pushes before the daemon will call a focus closed (one
//! push could be a client that has not loaded yet; an empty push resets it).
//! Until then a marker with no session entry counts as live everywhere
//! ([`focus_marker_may_be_live`]: the "sent" chip, the send sheet's notice and
//! the `existing` answer), so after a restart with only one non-empty push a
//! resend is conservative: it returns `existing` for a focus the user already
//! closed until a second agreeing push arrives, or `allow_duplicate` is set. A
//! Mother job marker is judged by Mother's job list instead (unknown, e.g.
//! Mother unreachable, counts as live).
//!
//! The app and the daemon ship together: the Mac's `work_send` /
//! `work_send_preview` frames are not understood by a daemon that predates
//! them, which drops the frame (a "bad ClientMsg" warning in its log) without
//! an answer, so an older daemon shows up in the app as "The daemon did not
//! answer in time". Run `make install-daemon` with `make mac-install`.
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
use crate::ipc::SessionManager;

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
    /// Set when an unreadable file could not be moved aside: the ledger works
    /// in memory but never writes, so the file's contents are not destroyed.
    write_blocked: Option<String>,
}

impl SentLedger {
    /// Open the ledger at `path`, loading what is there. A missing file is an
    /// empty ledger. Anything else that cannot be read (corrupt JSON, a
    /// permission error) is moved aside to `<file>.corrupt-<n>` first, so the
    /// next write cannot destroy it, and the ledger starts empty.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let (markers, write_blocked) = load(&path);
        Self {
            path,
            markers: Mutex::new(markers),
            changes: watch::channel(0).0,
            write_blocked,
        }
    }

    /// The file this ledger mirrors.
    pub fn path(&self) -> &Path {
        &self.path
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
        if marker.kind == FOCUS_KIND {
            if let Some(nonce) = marker.nonce.clone() {
                supersede(&mut markers, &marker.target_id, &nonce);
            }
        }
        markers.entry(item_id.to_owned()).or_default().push(marker);
        let result = self.persist(&markers);
        drop(markers);
        self.changes.send_modify(|n| *n += 1);
        result
    }

    /// A new focus (`nonce`) now runs under `tag`: forget the focus markers of
    /// whatever ran under it before. For a focus that was created without a
    /// source item, so `record` never sees it.
    pub fn supersede_focus(&self, tag: &str, nonce: &str) {
        let mut markers = self.markers.lock().unwrap();
        if supersede(&mut markers, tag, nonce) {
            if let Err(e) = self.persist(&markers) {
                warn!("sent ledger: could not write {}: {e}", self.path.display());
            }
            drop(markers);
            self.changes.send_modify(|n| *n += 1);
        }
    }

    fn persist(&self, markers: &BTreeMap<String, Vec<SentMarker>>) -> std::io::Result<()> {
        match &self.write_blocked {
            Some(why) => Err(std::io::Error::other(format!(
                "not writing {}: the previous file could not be moved aside ({why})",
                self.path.display()
            ))),
            None => persist(&self.path, markers),
        }
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
            if let Err(e) = self.persist(&markers) {
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

/// Marker kind of a focus.
const FOCUS_KIND: &str = "focus";

/// Drop every focus marker for `tag` whose nonce is not `nonce`; true if any went.
fn supersede(markers: &mut BTreeMap<String, Vec<SentMarker>>, tag: &str, nonce: &str) -> bool {
    let before: usize = markers.values().map(Vec::len).sum();
    markers.retain(|_, list| {
        list.retain(|m| !(m.kind == FOCUS_KIND && m.target_id == tag && m.nonce.as_deref() != Some(nonce)));
        !list.is_empty()
    });
    markers.values().map(Vec::len).sum::<usize>() != before
}

type Loaded = (BTreeMap<String, Vec<SentMarker>>, Option<String>);

/// The ledger at `path`, plus why writing must stay off (see `write_blocked`).
fn load(path: &Path) -> Loaded {
    match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(markers) => (markers, None),
            Err(e) => quarantine(path, &format!("unparseable: {e}")),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), None),
        Err(e) => quarantine(path, &format!("unreadable: {e}")),
    }
}

/// Move `path` aside to `<file>.corrupt-<n>` (first unused n) and start empty.
fn quarantine(path: &Path, why: &str) -> Loaded {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    for n in 1..=1000 {
        let dest = path.with_file_name(format!("{name}.corrupt-{n}"));
        if dest.symlink_metadata().is_ok() {
            continue;
        }
        return match std::fs::rename(path, &dest) {
            Ok(()) => {
                sync_dir(path);
                warn!("sent ledger: {} was {why}; moved to {}", path.display(), dest.display());
                (BTreeMap::new(), None)
            }
            Err(e) => {
                warn!("sent ledger: {} was {why} and could not be moved aside: {e}", path.display());
                (BTreeMap::new(), Some(format!("{why}; rename failed: {e}")))
            }
        };
    }
    warn!("sent ledger: {} was {why} and every .corrupt-<n> name is taken", path.display());
    (BTreeMap::new(), Some(format!("{why}; no free .corrupt-<n> name")))
}

/// fsync the directory holding `path` so a rename in it survives a crash (best effort).
fn sync_dir(path: &Path) {
    let dir = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    if let Ok(dir) = std::fs::File::open(dir) {
        let _ = dir.sync_all();
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
        std::fs::rename(&tmp, path)?;
        sync_dir(path);
        Ok(())
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
    open_private(options, path)
}

/// Create a file with mode 0600 that must not exist yet (`AlreadyExists` otherwise).
pub fn private_file_new(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    open_private(options, path)
}

fn open_private(mut options: std::fs::OpenOptions, path: &Path) -> std::io::Result<std::fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// How long the send path waits for `mother list` before treating the answer as unknown.
const MOTHER_LIST_TIMEOUT: Duration = Duration::from_secs(10);

/// How long the send sheet's preview waits for it. Shorter than the Mac's own
/// request timeout (10 s), so a hung Mother yields the preview with its job
/// markers kept ("unknown counts as live") and not a client-side timeout.
pub const MOTHER_PREVIEW_TIMEOUT: Duration = Duration::from_millis(2_500);

/// The ids of Mother's current jobs. `None` means unknown (the list failed or
/// timed out): callers treat unknown as "still there", never as "no jobs".
pub async fn mother_job_ids() -> Option<HashSet<String>> {
    mother_job_ids_within(MOTHER_LIST_TIMEOUT).await
}

/// [`mother_job_ids`] with its own bound.
pub async fn mother_job_ids_within(limit: Duration) -> Option<HashSet<String>> {
    match tokio::time::timeout(limit, crate::mother::list_jobs()).await {
        Ok(Ok(jobs)) => Some(jobs.into_iter().map(|j| j.id).collect()),
        Ok(Err(e)) => {
            warn!("sent ledger: could not list Mother jobs: {e}");
            None
        }
        Err(_) => {
            warn!("sent ledger: `mother list` timed out");
            None
        }
    }
}

/// May `marker`'s focus still be there? Used for the sent chips and for
/// duplicate protection alike, so the chip and the "already sent" answer agree.
/// It is not if a later focus took the tag (nonce mismatch), nor if its session
/// was stopped. A daemon that has not yet had a registry pushed (a restart,
/// before the Mac reconnects) cannot tell a closed focus from one it has not
/// heard of, so a marker with no session entry here counts as live until
/// [`SessionManager::registry_known`]; afterwards only a registered tag does.
pub fn focus_marker_may_be_live(mgr: &SessionManager, marker: &SentMarker) -> bool {
    let tag = &marker.target_id;
    focus_marker_matches(mgr, marker)
        && (mgr.has_live_session(tag) || (!mgr.has_session_entry(tag) && mgr.focus_may_exist(tag)))
}

/// Does the focus under `marker`'s tag still carry the marker's nonce? Unknown
/// (no nonce on either side, e.g. after a restart) counts as a match.
pub fn focus_marker_matches(mgr: &SessionManager, marker: &SentMarker) -> bool {
    match (marker.nonce.as_deref(), mgr.focus_nonce(&marker.target_id)) {
        (Some(mine), Some(current)) => mine == current,
        _ => true,
    }
}

static LEDGER: RwLock<Option<Arc<SentLedger>>> = RwLock::new(None);

/// The process-wide ledger, opened at [`default_path`] on first use.
pub fn ledger() -> Arc<SentLedger> {
    if let Some(ledger) = LEDGER.read().unwrap().as_ref() {
        return Arc::clone(ledger);
    }
    let mut slot = LEDGER.write().unwrap();
    if slot.is_none() && reaches_real_teri_dir_from_a_test(teri_dir_overridden()) {
        // Release the lock first: a panic holding it would poison the ledger for every later test.
        drop(slot);
        panic!(
            "a test opened the real sent ledger ({}): install_ledger a temp one and set NOSTROMO_TERI_DIR",
            default_path().display()
        );
    }
    Arc::clone(slot.get_or_insert_with(|| Arc::new(SentLedger::new(default_path()))))
}

/// Panic in a debug test binary if `what` is about to write under the real
/// `~/.nostromo/teri` because `NOSTROMO_TERI_DIR` is not set. For the writers
/// other than the ledger (which has its own check in [`ledger`]).
pub(crate) fn forbid_real_teri_dir_in_tests(what: &str) {
    if reaches_real_teri_dir_from_a_test(teri_dir_overridden()) {
        panic!("a test would write {what} under the real teri dir ({}): set NOSTROMO_TERI_DIR", teri_dir().display());
    }
}

/// Is this a debug test binary about to use the real teri dir (no override)?
fn reaches_real_teri_dir_from_a_test(overridden: bool) -> bool {
    cfg!(debug_assertions) && is_test_binary() && !overridden
}

fn teri_dir_overridden() -> bool {
    std::env::var_os("NOSTROMO_TERI_DIR").is_some_and(|d| !d.is_empty())
}

/// Is this process a cargo test binary (they live in `target/<profile>/deps`)?
/// Only used to catch a test reaching the real `~/.nostromo/teri`.
fn is_test_binary() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().and_then(Path::file_name).map(|n| n == "deps"))
        .unwrap_or(false)
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
            nonce: None,
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
    fn a_debug_test_binary_without_the_teri_dir_override_would_reach_the_real_dir() {
        assert!(reaches_real_teri_dir_from_a_test(false), "this unit test binary is a debug test binary");
        assert!(!reaches_real_teri_dir_from_a_test(true), "an override makes it safe");
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
