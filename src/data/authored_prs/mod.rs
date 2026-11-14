//! The author's side of GitHub: every open PR the token's user wrote, kept
//! current inside a GitHub budget the feature measures, with the focus that
//! owns each one worked out, published on the local-only `authored_prs` topic.
//!
//! Carefeed's PRs arrive live from the github relay; every other repo is
//! polled, at a cadence set by who is looking (see [`budget`]). With nobody
//! looking the feature makes **no request at all**, and a Mac that never sends
//! the demand verb counts as nobody. See `docs/authored-prs.md`.
//!
//! Privacy: this module logs counts, durations, error classes and posture
//! changes only; never a title, branch, check name, login, repo, PR number,
//! URL or token. The in-memory head branch and SHA never leave the process.

pub mod budget;
pub mod classify;
mod engine;
pub mod github;
pub mod ownership;
pub mod snapshot;
pub mod usage;
pub mod working_copy;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::data::github_client::GithubClient;
use crate::data::relay_client::{QueueSignal, RelayStatus};
use crate::mother::MotherJob;

pub use budget::Demand;
pub use snapshot::AuthoredPrsSnapshot;

/// Wall-clock time, injectable. Scheduling uses `tokio::time::Instant`, which
/// a test pauses; this supplies the timestamps that appear in the snapshot.
pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

/// Wall time anchored at construction and advanced by tokio's clock, so it
/// follows `tokio::time::pause` and `advance` in a test and is real time otherwise.
pub struct TokioClock {
    wall: DateTime<Utc>,
    mono: Instant,
}

impl TokioClock {
    pub fn new(start: DateTime<Utc>) -> Self {
        TokioClock {
            wall: start,
            mono: Instant::now(),
        }
    }
}

impl Clock for TokioClock {
    fn now(&self) -> DateTime<Utc> {
        let elapsed = Instant::now().saturating_duration_since(self.mono);
        self.wall + chrono::Duration::from_std(elapsed).unwrap_or_default()
    }
}

/// Who is looking: the highest level any live operator connection has asked
/// for. A connection that never said anything is not in the map, so with no
/// entry the demand is `idle`.
pub struct DemandBoard {
    levels: Mutex<HashMap<String, Demand>>,
    tx: watch::Sender<Demand>,
    refresh_tx: mpsc::UnboundedSender<()>,
}

pub(crate) struct DemandInputs {
    pub demand_rx: watch::Receiver<Demand>,
    pub refresh_rx: mpsc::UnboundedReceiver<()>,
}

impl DemandBoard {
    pub(crate) fn new() -> (Arc<DemandBoard>, DemandInputs) {
        let (tx, demand_rx) = watch::channel(Demand::Idle);
        let (refresh_tx, refresh_rx) = mpsc::unbounded_channel();
        (
            Arc::new(DemandBoard {
                levels: Mutex::new(HashMap::new()),
                tx,
                refresh_tx,
            }),
            DemandInputs {
                demand_rx,
                refresh_rx,
            },
        )
    }

    fn publish(&self, levels: &HashMap<String, Demand>) {
        let top = levels.values().copied().max().unwrap_or(Demand::Idle);
        self.tx.send_if_modified(|cur| {
            let changed = *cur != top;
            *cur = top;
            changed
        });
    }

    /// Connection `conn` now asks for `level` (`"visible"`, `"hidden"`,
    /// `"idle"`; anything else counts as hidden).
    pub fn set(&self, conn: &str, level: &str) {
        let mut levels = self.levels.lock().unwrap_or_else(|e| e.into_inner());
        levels.insert(conn.to_owned(), Demand::from_wire(level));
        self.publish(&levels);
    }

    /// Connection `conn` closed: its level is gone.
    pub fn remove(&self, conn: &str) {
        let mut levels = self.levels.lock().unwrap_or_else(|e| e.into_inner());
        if levels.remove(conn).is_some() {
            self.publish(&levels);
        }
    }

    /// Ask for a full reconcile now (the engine may refuse, and says so in the snapshot).
    pub fn refresh(&self) {
        let _ = self.refresh_tx.send(());
    }

    pub fn current(&self) -> Demand {
        *self.tx.borrow()
    }
}

/// What the engine needs to know about one open focus.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FocusInfo {
    pub tag: String,
    pub name: String,
    pub session_id: Option<String>,
    /// The directory the session was spawned in.
    pub spawn_cwd: Option<PathBuf>,
    /// The focus's project path from the registry.
    pub project_path: Option<PathBuf>,
}

/// Lists the open focuses. Built from the session manager in `nostromd`.
pub type FocusProvider = Arc<dyn Fn() -> Vec<FocusInfo> + Send + Sync>;

/// Everything the engine reads, all injectable: no network, no home directory.
pub struct Deps {
    /// `https://api.github.com` in production; a local mock in a test. A
    /// constructor argument, not Perri's thread-local override.
    pub api_base: String,
    /// `None` when no token could be resolved: the feature then runs in
    /// `token: missing` and makes no request.
    pub github: Option<GithubClient>,
    pub relay_status: Arc<RelayStatus>,
    /// `relay_url` and `relay_token` are both configured.
    pub relay_configured: bool,
    /// This feature's channel on the `RelayHub`, registered before the relay spawns.
    pub relay_rx: Option<mpsc::UnboundedReceiver<QueueSignal>>,
    pub jobs_rx: watch::Receiver<Vec<MotherJob>>,
    pub focuses: FocusProvider,
    /// `~/.claude/projects` in production.
    pub projects_root: PathBuf,
    pub clock: Arc<dyn Clock>,
}

pub struct AuthoredPrsHandle {
    pub demand: Arc<DemandBoard>,
    /// The latest snapshot; `None` until the engine publishes its first.
    pub snapshot: watch::Receiver<Option<AuthoredPrsSnapshot>>,
    pub task: tokio::task::JoinHandle<()>,
}

pub struct AuthoredPrsSource;

impl AuthoredPrsSource {
    /// Start the engine task. Publishes on change only, debounced 250 ms.
    pub fn spawn(deps: Deps) -> AuthoredPrsHandle {
        let (demand, inputs) = DemandBoard::new();
        let (tx, rx) = watch::channel(None);
        let task = tokio::spawn(engine::Engine::new(deps, inputs, tx).run());
        AuthoredPrsHandle {
            demand,
            snapshot: rx,
            task,
        }
    }
}
