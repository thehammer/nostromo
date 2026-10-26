//! Huey: a built-in agent that writes one short morning report about the
//! user's own work. H1 is the switch, the skeleton and the per-machine state
//! root; nothing here reads, fetches or writes until setup is confirmed, and
//! nothing can confirm setup yet.

pub mod budget;
pub mod checks;
pub mod config;
pub mod context;
pub mod curate;
pub mod interests;
pub mod items;
pub mod paths;
pub mod render;
pub mod run;
pub mod schedule;
pub mod setup;
pub mod sources;
pub mod store;
pub mod validate;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{Local, NaiveDate};
use tokio::sync::watch;
use tracing::info;

use crate::tracker::clock::{Clock, SystemClock};

pub use config::HueyConfig;
pub use paths::HueyPaths;
pub use setup::SetupState;

/// Bumped on every state change, so bound panes can repaint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HueyView {
    pub version: u64,
}

/// Cheap clone handed to MCP and IPC.
#[derive(Debug, Clone)]
pub struct HueyHandle {
    paths: Arc<HueyPaths>,
    config: Arc<HueyConfig>,
}

impl HueyHandle {
    pub fn paths(&self) -> &HueyPaths {
        &self.paths
    }

    pub fn config(&self) -> &HueyConfig {
        &self.config
    }

    /// Read from disk each time; a machine with no `setup.json` is not set up.
    pub fn setup_state(&self) -> SetupState {
        setup::load(&self.paths).state
    }
}

/// What starting Huey produced.
pub struct HueySources {
    pub handle: HueyHandle,
    pub view_rx: watch::Receiver<HueyView>,
}

pub struct HueyDeps {
    /// The daemon's per-machine state root (`socket_path.parent()`).
    pub state_root: PathBuf,
    pub config: HueyConfig,
    pub clock: Arc<dyn Clock>,
    /// How often the scheduler looks at the clock.
    pub tick: Duration,
}

impl HueyDeps {
    pub fn production(state_root: PathBuf, config: HueyConfig) -> Self {
        Self {
            state_root,
            config,
            clock: Arc::new(SystemClock),
            tick: Duration::from_secs(60),
        }
    }
}

pub struct HueyEngine;

impl HueyEngine {
    /// Build the handle and start the scheduler task. Creates nothing on disk.
    pub fn spawn(deps: HueyDeps) -> HueySources {
        let handle = HueyHandle {
            paths: Arc::new(HueyPaths::new(&deps.state_root)),
            config: Arc::new(deps.config),
        };
        let (view_tx, view_rx) = watch::channel(HueyView::default());
        tokio::spawn(run_scheduler(
            handle.clone(),
            view_tx,
            deps.clock,
            deps.tick,
        ));
        HueySources { handle, view_rx }
    }
}

/// H1: only notes, once per day, that Huey is not set up. It reads at most
/// `setup.json`, makes no network call and writes nothing.
async fn run_scheduler(
    handle: HueyHandle,
    view_tx: watch::Sender<HueyView>,
    clock: Arc<dyn Clock>,
    tick: Duration,
) {
    // Owning the sender keeps the view channel open for the task's lifetime.
    let _view_tx = view_tx;
    let mut noted: Option<NaiveDate> = None;
    loop {
        let today = clock.now().with_timezone(&Local).date_naive();
        if handle.setup_state() == SetupState::NotSetUp && noted != Some(today) {
            info!("huey: not set up");
            noted = Some(today);
        }
        tokio::time::sleep(tick).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::clock::FakeClock;
    use chrono::TimeZone;

    #[tokio::test(start_paused = true)]
    async fn an_unset_up_engine_writes_nothing_past_its_run_time() {
        let root = tempfile::tempdir().unwrap();
        let clock = Arc::new(FakeClock::new(
            chrono::Utc.with_ymd_and_hms(2026, 10, 25, 3, 0, 0).unwrap(),
        ));
        let src = HueyEngine::spawn(HueyDeps {
            state_root: root.path().to_path_buf(),
            config: HueyConfig::default(),
            clock: clock.clone(),
            tick: Duration::from_secs(60),
        });
        clock.advance(chrono::Duration::hours(12));
        tokio::time::sleep(Duration::from_secs(3600)).await;
        assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
