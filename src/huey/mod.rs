//! Huey: a built-in agent that writes one short morning report about the
//! user's own work.
//!
//! [`HueyEngine`] runs the scheduler; [`HueyHandle`] triggers runs and
//! serves render-ready documents. Nothing here reads, fetches or writes
//! until setup is confirmed (T6), and at most one run executes at a time
//! (T7).

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

use chrono::{DateTime, NaiveDate, Utc};
use tokio::sync::watch;
use tracing::info;

use crate::tracker::clock::{Clock, SystemClock};

pub use config::HueyConfig;
pub use paths::HueyPaths;
pub use render::{HueyDocument, MissingReason};
pub use run::{Curator, FailReason, LiveSource, RunOutcome, Trigger};
pub use setup::SetupState;

use context::ContextEnv;
use run::{NoCurator, NoLive, RunEnv};
use schedule::{Due, LocalTime, Schedule, SystemLocalTime};
use sources::{HttpClient, HttpLimits};
use store::Store;

/// After any run, a regeneration waits this long (T7).
pub const REGENERATE_COOLDOWN_SECS: i64 = 120;

/// Bumped on every state change, so bound panes can repaint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HueyView {
    pub version: u64,
}

/// Why a trigger did not start a run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TriggerRefused {
    #[error("already running")]
    AlreadyRunning,
    #[error("a run just finished; try again in {seconds} s")]
    Cooldown { seconds: i64 },
}

struct Inner {
    env: RunEnv,
    view_tx: watch::Sender<HueyView>,
    /// Held for the whole of a run: one run at a time (T7).
    run_lock: tokio::sync::Mutex<()>,
    last_run_end: std::sync::Mutex<Option<DateTime<Utc>>>,
}

/// Cheap clone handed to MCP and IPC.
#[derive(Clone)]
pub struct HueyHandle {
    paths: Arc<HueyPaths>,
    config: Arc<HueyConfig>,
    inner: Arc<Inner>,
}

impl std::fmt::Debug for HueyHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HueyHandle")
            .field("paths", &self.paths)
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
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

    pub fn store(&self) -> Store {
        Store::new((*self.paths).clone())
    }

    pub fn is_running(&self) -> bool {
        self.inner.run_lock.try_lock().is_err()
    }

    /// The report date of right now: the local date (or tomorrow, once a
    /// start time before midnight has passed).
    pub fn today(&self) -> NaiveDate {
        self.schedule()
            .report_date(self.inner.env.clock.now(), self.local_time())
    }

    fn local_time(&self) -> &dyn LocalTime {
        self.inner.env.local_time.as_ref()
    }

    fn schedule(&self) -> Schedule {
        Schedule::from_config(&self.config)
    }

    fn bump(&self) {
        self.inner.view_tx.send_modify(|v| v.version += 1);
    }

    /// Start a run now, unless one is running or (for a regeneration) one
    /// just finished.
    pub async fn trigger(&self, trigger: Trigger) -> Result<RunOutcome, TriggerRefused> {
        self.trigger_with(trigger, None, self.inner.env.clock.now())
            .await
    }

    async fn trigger_with(
        &self,
        trigger: Trigger,
        late_reason: Option<String>,
        now: DateTime<Utc>,
    ) -> Result<RunOutcome, TriggerRefused> {
        let Ok(_guard) = self.inner.run_lock.try_lock() else {
            return Err(TriggerRefused::AlreadyRunning);
        };
        if trigger == Trigger::Regenerate {
            if let Some(end) = *self.inner.last_run_end.lock().unwrap() {
                let left = REGENERATE_COOLDOWN_SECS - (now - end).num_seconds();
                if left > 0 {
                    return Err(TriggerRefused::Cooldown { seconds: left });
                }
            }
        }
        self.bump();
        let outcome = run::run_as_of(&self.inner.env, trigger, late_reason, now).await;
        *self.inner.last_run_end.lock().unwrap() = Some(self.inner.env.clock.now());
        self.bump();
        Ok(outcome)
    }

    /// Why today's report is not there (AC31). Budget is never a reason.
    pub fn missing_reason(&self, today: NaiveDate) -> MissingReason {
        if self.is_running() {
            return MissingReason::Pending;
        }
        let now = self.inner.env.clock.now();
        let late = chrono::Duration::minutes(schedule::LATE_AFTER_MINUTES);
        let day = self.store().day_runs(today);
        match day.last_failure() {
            Some((_, FailReason::FetchFailed)) => MissingReason::FetchFailed,
            Some((_, FailReason::WriteFailed)) => MissingReason::WriteFailed,
            Some((at, FailReason::ModelFailed)) => {
                let retry_due = chrono::Duration::minutes(schedule::RETRY_AFTER_MINUTES);
                if day.model_failures() >= 2 || now - at > retry_due + late {
                    MissingReason::ModelFailed
                } else {
                    MissingReason::Pending
                }
            }
            Some((_, FailReason::Asleep | FailReason::NotSetUp)) => MissingReason::Asleep,
            None if now > self.schedule().run_at(today, self.local_time()) + late => {
                MissingReason::Asleep
            }
            None => MissingReason::Pending,
        }
    }

    /// What the Report pane shows with no params: today's latest report;
    /// else the latest earlier one, labelled with its date and why today's
    /// is missing; or the not-set-up document. Reads only.
    pub fn current_document(&self) -> HueyDocument {
        if self.setup_state() != SetupState::Confirmed {
            return render::not_set_up_document();
        }
        let today = self.today();
        let store = self.store();
        if let Some(doc) = store
            .latest_version(today)
            .and_then(|v| self.document_for(today, Some(v)))
        {
            return doc;
        }
        let reason = self.missing_reason(today);
        match store
            .latest_before(today)
            .and_then(|d| self.document_for(d, None))
        {
            Some(mut doc) => {
                doc.banner = render::banner_for(doc.date.unwrap_or(today), today, reason);
                doc
            }
            None => render::no_report_document(today, reason),
        }
    }

    /// One report version (`None`: the date's latest). A report from
    /// another day carries an info banner with its date.
    pub fn document_for(&self, date: NaiveDate, version: Option<u32>) -> Option<HueyDocument> {
        let store = self.store();
        let version = match version {
            Some(v) => v,
            None => store.latest_version(date)?,
        };
        let report = store.load_report(date, version)?;
        let today = self.today();
        let banner = (date != today).then(|| render::Banner {
            level: render::BannerLevel::Info,
            text: format!("This is the report from {}.", date.format("%A, %b %-d, %Y")),
        });
        Some(HueyDocument {
            title: render::title(date, version),
            banner,
            markdown: render::render_markdown(&report),
            blocks: render::render_blocks(&report),
            date: Some(date),
            version: Some(version),
        })
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
    /// Where the context is read from.
    pub context: ContextEnv,
    pub http: HttpClient,
    pub curator: Arc<dyn Curator>,
    pub live: Arc<dyn LiveSource>,
    pub local_time: Arc<dyn LocalTime>,
}

impl HueyDeps {
    /// Defaults around `context`: the system clock and local time, a 60 s
    /// tick, default HTTP limits with no GitHub token, no model and no live
    /// inputs.
    pub fn new(state_root: PathBuf, config: HueyConfig, context: ContextEnv) -> Self {
        Self {
            state_root,
            config,
            clock: Arc::new(SystemClock),
            tick: Duration::from_secs(60),
            context,
            http: HttpClient::new(HttpLimits::default(), None),
            curator: Arc::new(NoCurator),
            live: Arc::new(NoLive),
            local_time: Arc::new(SystemLocalTime),
        }
    }

    pub fn production(
        state_root: PathBuf,
        config: HueyConfig,
        code_root: PathBuf,
        live: Arc<dyn LiveSource>,
    ) -> Self {
        let context = ContextEnv::production(code_root, state_root.clone());
        Self {
            http: HttpClient::production(),
            live,
            ..Self::new(state_root, config, context)
        }
    }
}

pub struct HueyEngine;

impl HueyEngine {
    /// Build the handle and start the scheduler task. Creates nothing on disk.
    pub fn spawn(deps: HueyDeps) -> HueySources {
        let paths = HueyPaths::new(&deps.state_root);
        let (view_tx, view_rx) = watch::channel(HueyView::default());
        let handle = HueyHandle {
            paths: Arc::new(paths.clone()),
            config: Arc::new(deps.config.clone()),
            inner: Arc::new(Inner {
                env: RunEnv {
                    paths,
                    config: deps.config,
                    context: deps.context,
                    http: deps.http,
                    curator: deps.curator,
                    live: deps.live,
                    clock: deps.clock,
                    local_time: deps.local_time,
                },
                view_tx,
                run_lock: tokio::sync::Mutex::new(()),
                last_run_end: std::sync::Mutex::new(None),
            }),
        };
        tokio::spawn(run_scheduler(handle.clone(), deps.tick));
        HueySources { handle, view_rx }
    }
}

/// Every tick: if setup is confirmed and today's run is due, run it. An
/// engine that is not set up reads at most `setup.json`, makes no network
/// call and writes nothing.
async fn run_scheduler(handle: HueyHandle, tick: Duration) {
    let mut noted: Option<NaiveDate> = None;
    loop {
        let now = handle.inner.env.clock.now();
        let today = handle.schedule().report_date(now, handle.local_time());
        if handle.setup_state() != SetupState::Confirmed {
            if noted != Some(today) {
                info!("huey: not set up");
                noted = Some(today);
            }
        } else if !recently_ran(&handle, now) {
            let day = handle.store().day_runs(today);
            if let Due::Run {
                trigger,
                late_reason,
            } = schedule::is_due(&handle.schedule(), now, handle.local_time(), &day)
            {
                let _ = handle.trigger_with(trigger, late_reason, now).await;
            }
        }
        tokio::time::sleep(tick).await;
    }
}

/// A run ended less than the retry interval ago. Guards against a run log
/// that cannot be written turning every tick into a run.
fn recently_ran(handle: &HueyHandle, now: DateTime<Utc>) -> bool {
    handle
        .inner
        .last_run_end
        .lock()
        .unwrap()
        .is_some_and(|end| now - end < chrono::Duration::minutes(schedule::RETRY_AFTER_MINUTES))
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
        let context = ContextEnv::for_home(
            root.path(),
            root.path().join("code"),
            root.path().to_path_buf(),
            "test".into(),
        );
        let src = HueyEngine::spawn(HueyDeps {
            clock: clock.clone(),
            ..HueyDeps::new(root.path().to_path_buf(), HueyConfig::default(), context)
        });
        clock.advance(chrono::Duration::hours(12));
        tokio::time::sleep(Duration::from_secs(3600)).await;
        assert_eq!(src.handle.setup_state(), SetupState::NotSetUp);
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
