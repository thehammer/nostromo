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

pub mod actions;
pub mod budget;
pub mod classify;
mod engine;
pub mod github;
pub mod links;
pub mod memory;
pub mod notice;
pub mod ownership;
mod safe_read;
pub mod snapshot;
pub mod usage;
pub mod wire;
pub mod working_copy;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use ownership::PrKey;
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::data::github_client::GithubClient;
use crate::data::relay_client::{QueueSignal, RelayStatus};
use crate::mother::MotherJob;

pub use actions::AuthoredPrActions;
pub use budget::Demand;
pub use snapshot::AuthoredPrsSnapshot;

/// Wall-clock time, injectable. Scheduling uses `tokio::time::Instant`, which
/// a test pauses; this supplies the timestamps that appear in the snapshot.
pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

/// The real wall clock. Production uses this one: unlike [`TokioClock`] it keeps
/// up when the Mac sleeps (a monotonic clock stops), so `generated_at`,
/// `checked_at`, `retry_at`, `resumes_at` and the rate-limit reset comparison
/// stay true.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// Wall time anchored at construction and advanced by tokio's clock, so it
/// follows `tokio::time::pause` and `advance` in a test. Tests only: it stops
/// while the Mac sleeps.
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
    told_tx: mpsc::UnboundedSender<PrKey>,
}

pub(crate) struct DemandInputs {
    pub demand_rx: watch::Receiver<Demand>,
    pub refresh_rx: mpsc::UnboundedReceiver<()>,
    pub told_rx: mpsc::UnboundedReceiver<PrKey>,
}

impl DemandBoard {
    pub(crate) fn new() -> (Arc<DemandBoard>, DemandInputs) {
        let (tx, demand_rx) = watch::channel(Demand::Idle);
        let (refresh_tx, refresh_rx) = mpsc::unbounded_channel();
        let (told_tx, told_rx) = mpsc::unbounded_channel();
        (
            Arc::new(DemandBoard {
                levels: Mutex::new(HashMap::new()),
                tx,
                refresh_tx,
                told_tx,
            }),
            DemandInputs {
                demand_rx,
                refresh_rx,
                told_rx,
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

    /// A link or told record for this PR changed: the engine reads it again and
    /// publishes now.
    pub fn pr_changed(&self, key: PrKey) {
        let _ = self.told_tx.send(key);
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
    /// The persona the focus runs (`cody`); empty when unknown.
    pub agent_name: String,
    pub session_id: Option<String>,
    /// The directory the session was spawned in.
    pub spawn_cwd: Option<PathBuf>,
    /// The focus's project path from the registry.
    pub project_path: Option<PathBuf>,
    /// One of the app's built-in focuses (Fred, Teri, Huey, Mother, Perri).
    pub built_in: bool,
}

impl FocusInfo {
    /// May the hand-off write to this focus? See [`is_tellable_focus`].
    pub fn tellable(&self) -> bool {
        is_tellable_focus(self.built_in, &self.agent_name)
    }
}

/// The one rule for which open focuses a PR notice may be sent to, shared by
/// the verbs (which refuse the rest), the pill (never raised for an owner that
/// cannot be told) and, through the shared fixture
/// `tests/fixtures/authored_prs/tellable_focuses.json`, the Mac's picker and
/// Tell button. Conservative on purpose: never a built-in focus and never one
/// running a Fred, Teri or Huey agent, since those hold mail, calendar or
/// personal notes and a PR notice has no business there.
pub fn is_tellable_focus(built_in: bool, agent_name: &str) -> bool {
    !built_in
        && !crate::ipc::peer::is_teri_or_fred_agent(agent_name)
        && !crate::ipc::peer::is_huey_agent(agent_name)
}

/// Lists the open focuses. Built from the session manager in `nostromd`.
pub type FocusProvider = Arc<dyn Fn() -> Vec<FocusInfo> + Send + Sync>;

/// Looks for a GitHub token again (reads files); `None` when there is still none.
pub type TokenResolver = Arc<dyn Fn() -> Option<GithubClient> + Send + Sync>;

/// Everything the engine reads, all injectable: no network, no home directory.
pub struct Deps {
    /// `https://api.github.com` in production; a local mock in a test. A
    /// constructor argument, not Perri's thread-local override.
    pub api_base: String,
    /// `None` when no token could be resolved: the feature then runs in
    /// `token: missing` and makes no request.
    pub github: Option<GithubClient>,
    /// Re-checked (at most every five minutes, only while someone watches) when
    /// `github` is `None`, so a token that appears later is picked up without
    /// a restart.
    pub token_resolver: Option<TokenResolver>,
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
    /// Where links, told records and the focus memory persist; `None` keeps
    /// them in memory only (tests).
    pub state_root: Option<PathBuf>,
}

pub struct AuthoredPrsHandle {
    pub demand: Arc<DemandBoard>,
    pub store: Arc<links::AuthoredPrStore>,
    pub memory: Arc<memory::FocusMemory>,
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
        let (store, memory) = match &deps.state_root {
            Some(root) => (
                Arc::new(links::AuthoredPrStore::open(root)),
                Arc::new(memory::FocusMemory::open(root)),
            ),
            None => (
                Arc::new(links::AuthoredPrStore::in_memory()),
                Arc::new(memory::FocusMemory::in_memory()),
            ),
        };
        let task = tokio::spawn(
            engine::Engine::new(deps, inputs, tx, Arc::clone(&store), Arc::clone(&memory)).run(),
        );
        AuthoredPrsHandle {
            demand,
            store,
            memory,
            snapshot: rx,
            task,
        }
    }
}

#[cfg(test)]
mod tellable_tests {
    use super::is_tellable_focus;

    /// The table the Mac's picker and Tell button are tested against too, so the
    /// two sides cannot drift: what the Mac offers is what the daemon accepts.
    #[test]
    fn the_shared_table_says_which_focuses_a_notice_may_go_to() {
        let table: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../tests/fixtures/authored_prs/tellable_focuses.json"
        ))
        .unwrap();
        assert!(table.len() >= 10);
        for row in table {
            let built_in = row["built_in"].as_bool().unwrap();
            let agent = row["agent"].as_str().unwrap();
            assert_eq!(
                is_tellable_focus(built_in, agent),
                row["tellable"].as_bool().unwrap(),
                "built_in={built_in} agent={agent:?}"
            );
        }
    }
}
