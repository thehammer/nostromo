//! Mother job notices: tell the focus that queued a job when the job moves.
//!
//! The [`NoticeEngine`] watches the job feed ([`detect`]), batches changes per
//! focus ([`batch`]), and hands the originating focus's session one structured
//! message ([`element`]) through `SessionManager::inject_notice`: an idle
//! session is woken, a busy one gets it behind its turn, a stopped one gets it
//! after its next turn (nothing is started to deliver). It holds deliveries for
//! the hourly cap and the loop guard ([`limits`]), honours the global, focus
//! and job switches, survives a restart without announcing a state twice
//! ([`store`]), audits ids, tags, enums and counts only, and publishes its
//! state for the app (`MotherNoticeState`) and each job's notice record
//! (`MotherJob.nostromo.notice`).
//!
//! Only jobs whose origin the daemon verified (`OriginKind::Focus`) are ever
//! notified, and only their own focus.
//!
//! `pr_state` supplies the "PR merged" signal: relay events and a low-rate
//! `gh` poll, both ending in [`NoticeEngine::pr_event`].
//!
//! This file holds the wire types, the clock and session ports, and the
//! [`NoticeEngine`] API: it takes the lock, calls into the private state
//! machine (`state`) and runs the effects it returns. `wiring` connects the
//! engine to the daemon ([`attach`], [`spawn_feed_watcher`],
//! [`spawn_publisher`]).
//!
//! # Lock order
//!
//! The engine has one `Mutex<State>` and it is a **leaf**: every method
//! computes under it, releases it, and only then calls the session port
//! (`inject_notice`, which takes the session manager's lock), the audit log or
//! the change channel. Nothing else is ever acquired while it is held. So the
//! session manager may call into the engine while holding its own lock
//! ([`NoticeEngine::on_registry`] does), and the origin book may too (the
//! notice-born hook), but the engine never calls them back from under its
//! lock. The port lock (`RwLock<Option<port>>`) is also a leaf: the port is
//! cloned out of it before use. So is the file lock (`written`): the store is
//! snapshotted under the engine lock, and written to disk only after it is
//! released. A call that changes the store writes it on its caller's thread, so
//! a slow disk delays that caller, and any other call that wants to write; but
//! `on_registry` (which the session manager calls under its own lock) never
//! writes: it marks the store dirty and the next call that finishes (the tick)
//! writes it. Snapshots carry a sequence number, so a write that lost the race
//! to a newer one is skipped.
//!
//! Turn events reach the engine from the session readers through a channel to
//! one worker thread ([`attach`]), never on the reader itself, because a
//! delivery takes the session manager's lock.
//!
//! Nothing here logs or audits a title, a reason, a question, a PR URL, a
//! focus name or a session id (SR8).

pub mod batch;
pub mod detect;
pub mod element;
pub mod limits;
pub mod pr_state;
mod state;
pub mod store;
mod wiring;

use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};

use serde::{Deserialize, Serialize};
use tokio::sync::watch;

use self::batch::HoldReason;
use self::detect::JobEvent;
use self::limits::{DayCount, DAY_MS};
use self::state::{Effect, State};
use self::store::Store;
use super::audit::{MotherAudit, MotherAuditEvent};
use super::origin::NotifyLevel;
use super::MotherJob;
use crate::ipc::protocol::ServerMsg;
use crate::ipc::session_manager::{NoticeDelivery, TurnEvent, MOTHER_NOTICE_KEY_PREFIX};

pub use self::wiring::{
    attach, spawn_feed_watcher, spawn_publisher, ManagerPort, PUBLISH_DEBOUNCE, TICK_EVERY,
};

/// Jobs absent from the feed this long are forgotten.
pub const JOB_ABSENT_MAX_MS: i64 = 7 * DAY_MS;
/// A focus's mode is forgotten when the focus has not been seen this long.
pub const FOCUS_UNSEEN_MAX_MS: i64 = 90 * DAY_MS;
/// History entries kept per job.
pub const HISTORY_MAX: usize = 10;

// ── wire types ───────────────────────────────────────────────────────────────

/// `MotherJob.nostromo.notice.status`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeStatus {
    /// Delivered: written to an idle session, or the queued message written.
    Told,
    /// Waiting (see the reason).
    Held,
    /// Thrown away by a switch, or expired.
    Dropped,
    /// Its focus is closed.
    NotSent,
    /// Nothing to say (yet), or never notifiable.
    #[default]
    None,
}

/// `MotherJob.nostromo.notice.reason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeReason {
    Batching,
    Busy,
    Cap,
    LoopGuard,
    SessionNotRunning,
    Quiet,
    FocusOff,
    GlobalOff,
    FocusClosed,
    NotNotifiable,
}

impl From<HoldReason> for NoticeReason {
    fn from(r: HoldReason) -> Self {
        match r {
            HoldReason::Quiet => Self::Quiet,
            HoldReason::SessionNotRunning => Self::SessionNotRunning,
            HoldReason::Busy => Self::Busy,
            HoldReason::Cap => Self::Cap,
            HoldReason::LoopGuard => Self::LoopGuard,
        }
    }
}

/// One entry of a job's notice history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoticeHistoryEntry {
    pub states: Vec<JobEvent>,
    pub status: NoticeStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<NoticeReason>,
    pub wake: bool,
    pub at_ms: i64,
}

/// `MotherJob.nostromo.notice` (plan index §W).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoticeView {
    pub status: NoticeStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<NoticeReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_state: Option<JobEvent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at_ms: Option<i64>,
    /// The newest [`HISTORY_MAX`] deliveries, holds and drops, newest last.
    /// Absent on the wire while empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history: Vec<NoticeHistoryEntry>,
}

/// `MotherNoticeState.focuses[].held`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeldSummary {
    pub count: usize,
    pub reason: NoticeReason,
}

/// `MotherNoticeState.focuses[]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusNoticeState {
    pub tag: String,
    pub mode: NotifyLevel,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held: Option<HeldSummary>,
    pub chain_held: bool,
    #[serde(default)]
    pub wakes_by_day: Vec<DayCount>,
}

/// `MotherNoticeSettingsSet.scope`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeScope {
    Focus,
    Global,
}

/// Why a settings change was refused (a fixed word, sent back to the app).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsError {
    /// `scope: focus` without a valid `tag` and `mode`.
    FocusNeedsTagAndMode,
    /// `scope: global` without `enabled`.
    GlobalNeedsEnabled,
}

impl SettingsError {
    pub fn code(self) -> &'static str {
        match self {
            Self::FocusNeedsTagAndMode => "invalid_settings: focus scope needs tag and mode",
            Self::GlobalNeedsEnabled => "invalid_settings: global scope needs enabled",
        }
    }
}

// ── clock and session port ───────────────────────────────────────────────────

/// Milliseconds since the epoch. Every window, cap and expiry runs on it.
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> i64;
}

/// The wall clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        chrono::Utc::now().timestamp_millis()
    }
}

/// A clock tests move by hand. Clones share the time.
#[derive(Clone, Debug, Default)]
pub struct ManualClock(Arc<AtomicI64>);

impl ManualClock {
    pub fn new(ms: i64) -> Self {
        Self(Arc::new(AtomicI64::new(ms)))
    }

    pub fn set(&self, ms: i64) {
        self.0.store(ms, Ordering::SeqCst);
    }

    pub fn advance(&self, ms: i64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// Where notices go: the session manager in the daemon, a recorder in tests.
pub trait SessionPort: Send + Sync {
    /// See `SessionManager::inject_notice`. An error means the focus has no
    /// live session.
    fn deliver(
        &self,
        tag: &str,
        key: &str,
        merged: &str,
        fresh: &str,
    ) -> anyhow::Result<NoticeDelivery>;
    /// Take back a queued, unwritten notice for `tag`.
    fn withdraw(&self, tag: &str);
}

/// The coalesce key of generation `gen` of `tag`'s notices.
pub fn notice_key(tag: &str, gen: u64) -> String {
    format!("{MOTHER_NOTICE_KEY_PREFIX}{tag}#{gen}")
}

/// The generation in a notice key.
fn gen_of(key: &str) -> Option<u64> {
    key.strip_prefix(MOTHER_NOTICE_KEY_PREFIX)?
        .rsplit_once('#')?
        .1
        .parse()
        .ok()
}

// ── the engine ───────────────────────────────────────────────────────────────

/// How the engine is built.
pub struct NoticeConfig {
    /// `None`: nothing is written (the engine starts as if it had run before).
    pub store_path: Option<PathBuf>,
    pub audit: MotherAudit,
    pub clock: Arc<dyn Clock>,
}

/// The notice engine. See the module docs.
pub struct NoticeEngine {
    state: Mutex<State>,
    clock: Arc<dyn Clock>,
    audit: MotherAudit,
    store_path: Option<PathBuf>,
    /// The sequence number of the newest snapshot written to `store_path`;
    /// held while writing. Taken only with the engine lock released.
    written: Mutex<u64>,
    port: RwLock<Option<Arc<dyn SessionPort>>>,
    changes: watch::Sender<u64>,
    /// Runs just before the store is written (tests hold the write here).
    #[cfg(test)]
    before_write: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl NoticeEngine {
    /// An engine with the store at `config.store_path` (loaded now).
    pub fn new(config: NoticeConfig) -> Arc<Self> {
        let (store, existed) = match &config.store_path {
            Some(path) => store::load(path),
            None => (Store::default(), true),
        };
        let now = config.clock.now_ms();
        Arc::new(Self {
            state: Mutex::new(State::new(store, existed, now)),
            clock: config.clock,
            audit: config.audit,
            store_path: config.store_path,
            written: Mutex::new(0),
            port: RwLock::new(None),
            changes: watch::channel(0).0,
            #[cfg(test)]
            before_write: Mutex::new(None),
        })
    }

    /// Where deliveries go from now on.
    pub fn set_port(&self, port: Arc<dyn SessionPort>) {
        *self.port.write().unwrap_or_else(|e| e.into_inner()) = Some(port);
    }

    /// Bumped whenever something the app or the feed shows changed.
    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    fn now(&self) -> i64 {
        self.clock.now_ms()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn port(&self) -> Option<Arc<dyn SessionPort>> {
        self.port.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    // ── inputs ──────────────────────────────────────────────────────────────

    /// A new job list from the feed (annotated with origins).
    pub fn on_jobs(&self, jobs: &[MotherJob]) {
        let now = self.now();
        let mut st = self.lock();
        st.on_jobs(jobs, now);
        self.finish(st, Vec::new());
    }

    /// A job's PR was merged (`true`) or closed without merging (`false`).
    /// Fed by MF2b; announced at most once per job and outcome.
    pub fn pr_event(&self, job_id: &str, merged: bool) {
        let now = self.now();
        let mut st = self.lock();
        st.pr_event(job_id, merged, now);
        self.finish(st, Vec::new());
    }

    /// The jobs whose PRs are worth asking about: a verified origin, an open
    /// focus, a level that is not Off, no PR outcome announced yet, still in
    /// the feed, and running or finished less than 14 days ago. `None` until
    /// the engine has seen the feed once; empty while the global switch is off.
    pub fn pr_candidates(&self) -> Option<Vec<pr_state::PrCandidate>> {
        let now = self.now();
        self.lock().pr_candidates(now)
    }

    /// A turn event from `tag`'s session.
    pub fn on_turn(&self, tag: &str, event: &TurnEvent) {
        let now = self.now();
        let mut st = self.lock();
        let effects = st.on_turn(tag, event, now);
        self.finish(st, effects);
    }

    /// The focus registry was pushed: `present` are its tags, `departed` the
    /// tags now gone for good. Called under the session manager's lock, so it
    /// only records: nothing is delivered, audited or written here (the next
    /// tick does).
    pub fn on_registry(&self, present: &[String], departed: &[String]) {
        let now = self.now();
        let mut st = self.lock();
        st.on_registry(present, departed, now);
        let changed = st.take_changed();
        drop(st);
        if changed {
            self.changes.send_modify(|v| *v = v.wrapping_add(1));
        }
    }

    /// `job_id` was just stamped (or first evaluated) as queued by `tag`. When
    /// `tag` is in a notice turn, the job is notice-born (loop guard).
    pub fn note_job_origin(&self, _job_id: &str, tag: &str) {
        self.lock().note_job_origin(tag, None);
    }

    /// Look at the timers: windows that closed, cap holds whose hour rolled,
    /// holds older than 24 h, jobs long gone.
    pub fn tick(&self) {
        let now = self.now();
        let mut st = self.lock();
        let effects = st.tick(now);
        self.finish(st, effects);
    }

    /// Apply the app's `MotherNoticeSettingsSet`.
    pub fn apply_settings(
        &self,
        scope: NoticeScope,
        tag: Option<&str>,
        mode: Option<NotifyLevel>,
        enabled: Option<bool>,
    ) -> Result<(), SettingsError> {
        let now = self.now();
        let mut st = self.lock();
        let effects = st.apply_settings(scope, tag, mode, enabled, now)?;
        self.finish(st, effects);
        Ok(())
    }

    /// A settings change was refused because the peer is not the operator
    /// app (`trust` is a fixed word: `local_other`, `network`).
    pub fn audit_settings_refused(&self, trust: &'static str) {
        self.audit
            .record(&MotherAuditEvent::MotherNoticeSettingsRefused { peer: trust });
    }

    // ── outputs ─────────────────────────────────────────────────────────────

    /// Set `nostromo.notice` on every annotated job the engine knows.
    pub fn annotate(&self, jobs: &mut [MotherJob]) {
        let st = self.lock();
        for job in jobs.iter_mut() {
            let (Some(ann), Some(rec)) = (job.nostromo.as_mut(), st.store.jobs.get(&job.id)) else {
                continue;
            };
            ann.notice = Some(rec.notice.clone());
        }
    }

    /// One job's notice record.
    pub fn notice_of(&self, job_id: &str) -> Option<NoticeView> {
        self.lock().store.jobs.get(job_id).map(|r| r.notice.clone())
    }

    /// The `MotherNoticeState` frame.
    pub fn state_msg(&self) -> ServerMsg {
        let now = self.now();
        let st = self.lock();
        ServerMsg::MotherNoticeState {
            enabled: st.store.enabled,
            focuses: st.focus_states(now),
        }
    }

    /// The focus states alone (tests and diagnostics).
    pub fn focus_state(&self, tag: &str) -> Option<FocusNoticeState> {
        let now = self.now();
        self.lock()
            .focus_states(now)
            .into_iter()
            .find(|f| f.tag == tag)
    }

    /// Is the global switch on?
    pub fn enabled(&self) -> bool {
        self.lock().store.enabled
    }

    // ── effects ─────────────────────────────────────────────────────────────

    #[cfg(test)]
    fn run_before_write_hook(&self) {
        let hook = self.before_write.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook();
        }
    }

    #[cfg(not(test))]
    fn run_before_write_hook(&self) {}

    /// Snapshot the store if it needs writing, release the lock, then write
    /// it, audit, publish and run `effects` (each delivery's outcome is
    /// applied under the lock again).
    fn finish(&self, mut st: MutexGuard<'_, State>, effects: Vec<Effect>) {
        let snapshot = (st.take_dirty() && self.store_path.is_some()).then(|| {
            st.saves += 1;
            (st.saves, st.store.clone())
        });
        let audits = st.take_audits();
        let changed = st.take_changed();
        drop(st);
        if let (Some((seq, store)), Some(path)) = (snapshot, &self.store_path) {
            self.run_before_write_hook();
            let mut written = self.written.lock().unwrap_or_else(|e| e.into_inner());
            if seq > *written {
                store::save(path, &store);
                *written = seq;
            }
        }
        for event in &audits {
            self.audit.record(event);
        }
        if changed {
            self.changes.send_modify(|v| *v = v.wrapping_add(1));
        }
        for effect in effects {
            match effect {
                Effect::Withdraw { tag } => {
                    if let Some(port) = self.port() {
                        port.withdraw(&tag);
                    }
                }
                Effect::Deliver {
                    tag,
                    gen,
                    merged,
                    fresh,
                } => {
                    let result = match self.port() {
                        Some(port) => port.deliver(&tag, &notice_key(&tag, gen), &merged, &fresh),
                        None => Err(anyhow::anyhow!("no session port")),
                    };
                    if result.is_err() {
                        tracing::debug!(tag = %tag, gen, "mother notice not delivered: no live session");
                    }
                    let now = self.now();
                    let mut st = self.lock();
                    st.delivered(&tag, gen, result.ok(), now);
                    self.finish(st, Vec::new());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
