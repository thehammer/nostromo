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
//! cloned out of it before use.
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
pub mod store;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::watch;

use self::batch::{Hold, HoldReason, InFlight, Pending};
use self::detect::{JobEvent, Seen};
use self::element::NoticeItem;
use self::limits::{DayCount, DAY_MS, HOUR_MS};
use self::store::{FocusRecord, JobRecord, Snapshot, Store};
use super::audit::{MotherAudit, MotherAuditEvent};
use super::origin::{NotifyLevel, OriginKind};
use super::{JobsFeed, MotherJob};
use crate::ipc::protocol::ServerMsg;
use crate::ipc::session_manager::{
    NoticeDelivery, SessionManager, TurnAuthor, TurnEvent, MOTHER_NOTICE_KEY_PREFIX,
};

/// Jobs absent from the feed this long are forgotten.
pub const JOB_ABSENT_MAX_MS: i64 = 7 * DAY_MS;
/// A focus's mode is forgotten when the focus has not been seen this long.
pub const FOCUS_UNSEEN_MAX_MS: i64 = 90 * DAY_MS;
/// History entries kept per job.
pub const HISTORY_MAX: usize = 10;
/// How often the worker thread looks at the timers.
pub const TICK_EVERY: Duration = Duration::from_secs(1);
/// State changes are published at most this often.
pub const PUBLISH_DEBOUNCE: Duration = Duration::from_millis(250);

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

/// The session manager as a [`SessionPort`]. Holds it weakly: the engine
/// never keeps the manager alive.
pub struct ManagerPort(std::sync::Weak<Mutex<SessionManager>>);

impl ManagerPort {
    pub fn new(sessions: &Arc<Mutex<SessionManager>>) -> Self {
        Self(Arc::downgrade(sessions))
    }
}

impl SessionPort for ManagerPort {
    fn deliver(
        &self,
        tag: &str,
        key: &str,
        merged: &str,
        fresh: &str,
    ) -> anyhow::Result<NoticeDelivery> {
        let sessions = self
            .0
            .upgrade()
            .ok_or_else(|| anyhow::anyhow!("session manager gone"))?;
        let mut mgr = sessions.lock().unwrap_or_else(|e| e.into_inner());
        mgr.inject_notice(tag, key, merged, fresh)
    }

    fn withdraw(&self, tag: &str) {
        if let Some(sessions) = self.0.upgrade() {
            sessions
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .drop_injected_prefix(tag, MOTHER_NOTICE_KEY_PREFIX);
        }
    }
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

/// What triggered a delivery attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Trigger {
    /// A batch window closed.
    Window,
    /// A turn started or ended (Quiet, session not running, busy).
    AfterTurn,
    /// The hour rolled under a cap hold.
    CapRolled,
    /// The user started a turn: releases every hold, cap and loop guard too.
    UserTurn,
    /// A notice turn started: Quiet / session-not-running items queue behind
    /// it, but only when the delivery cannot become a turn past the cap or the
    /// loop guard whatever this turn does.
    DuringNoticeTurn,
}

/// Something to do once the engine's lock is released.
#[derive(Debug)]
enum Effect {
    Deliver {
        tag: String,
        gen: u64,
        merged: String,
        fresh: String,
    },
    Withdraw {
        tag: String,
    },
}

/// The effective level of a change: the lowest of the global switch, the
/// focus's mode and the job's own `notify`. `Err` names why it is off.
fn effective(
    global: bool,
    mode: Option<NotifyLevel>,
    job: Option<NotifyLevel>,
) -> Result<NotifyLevel, NoticeReason> {
    if !global {
        return Err(NoticeReason::GlobalOff);
    }
    let rank = |l: NotifyLevel| match l {
        NotifyLevel::Off => 0,
        NotifyLevel::Quiet => 1,
        NotifyLevel::Wake => 2,
    };
    let focus = mode.unwrap_or(NotifyLevel::Wake);
    let job = job.unwrap_or(NotifyLevel::Wake);
    let level = if rank(job) < rank(focus) { job } else { focus };
    if level == NotifyLevel::Off {
        Err(NoticeReason::FocusOff)
    } else {
        Ok(level)
    }
}

struct State {
    store: Store,
    /// The store existed (or the engine has looked at the feed once).
    bootstrapped: bool,
    /// The first look after loading compares each job with what was last
    /// accounted for (R9).
    restart_check: bool,
    /// Tags the registry has reported departed (and not seen again).
    closed: HashSet<String>,
    /// Focuses in a notice turn now, and whether it queued a notice-born job.
    notice_turns: HashMap<String, bool>,
    /// The store needs writing.
    dirty: bool,
    /// Something the app or the feed shows changed.
    changed: bool,
    audits: Vec<MotherAuditEvent>,
}

/// The notice engine. See the module docs.
pub struct NoticeEngine {
    state: Mutex<State>,
    clock: Arc<dyn Clock>,
    audit: MotherAudit,
    store_path: Option<PathBuf>,
    port: RwLock<Option<Arc<dyn SessionPort>>>,
    changes: watch::Sender<u64>,
}

impl NoticeEngine {
    /// An engine with the store at `config.store_path` (loaded now).
    pub fn new(config: NoticeConfig) -> Arc<Self> {
        let (mut store, existed) = match &config.store_path {
            Some(path) => store::load(path),
            None => (Store::default(), true),
        };
        let now = config.clock.now_ms();
        // Messages in flight died with the previous daemon's queue: they wait
        // for the session's next turn.
        for focus in store.focuses.values_mut() {
            let lost: Vec<InFlight> = std::mem::take(&mut focus.bucket.inflight);
            let lost: Vec<Pending> = lost
                .into_iter()
                .filter(|f| !f.told)
                .map(|f| Pending {
                    item: f.item,
                    due: f.due,
                    updated_ms: f.at_ms,
                })
                .collect();
            if !lost.is_empty() {
                focus.bucket.restore(lost);
                focus
                    .bucket
                    .hold_at_least(HoldReason::SessionNotRunning, now);
            }
        }
        Arc::new(Self {
            state: Mutex::new(State {
                store,
                bootstrapped: existed,
                restart_check: existed,
                closed: HashSet::new(),
                notice_turns: HashMap::new(),
                dirty: false,
                changed: false,
                audits: Vec::new(),
            }),
            clock: config.clock,
            audit: config.audit,
            store_path: config.store_path,
            port: RwLock::new(None),
            changes: watch::channel(0).0,
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
        let changed = std::mem::take(&mut st.changed);
        drop(st);
        if changed {
            self.changes.send_modify(|v| *v = v.wrapping_add(1));
        }
    }

    /// `job_id` was just stamped (or first evaluated) as queued by `tag`. When
    /// `tag` is in a notice turn, the job is notice-born (loop guard).
    pub fn note_job_origin(&self, _job_id: &str, tag: &str) {
        if let Some(born) = self.lock().notice_turns.get_mut(tag) {
            *born = true;
        }
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

    /// Write the store if needed, release the lock, then audit, publish and
    /// run `effects` (each delivery's outcome is applied under the lock again).
    fn finish(&self, mut st: MutexGuard<'_, State>, effects: Vec<Effect>) {
        if std::mem::take(&mut st.dirty) {
            if let Some(path) = &self.store_path {
                store::save(path, &st.store);
            }
        }
        let audits = std::mem::take(&mut st.audits);
        let changed = std::mem::take(&mut st.changed);
        drop(st);
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

// ── the state machine ────────────────────────────────────────────────────────

impl State {
    fn focus(&mut self, tag: &str) -> &mut FocusRecord {
        self.store.focuses.entry(tag.to_owned()).or_default()
    }

    /// Record a status change for `job_id`. `history` adds an entry.
    #[allow(clippy::too_many_arguments)]
    fn record(
        &mut self,
        job_id: &str,
        status: NoticeStatus,
        reason: Option<NoticeReason>,
        states: &[JobEvent],
        wake: bool,
        history: bool,
        now: i64,
    ) {
        let Some(rec) = self.store.jobs.get_mut(job_id) else {
            return;
        };
        let view = &mut rec.notice;
        let same = view.status == status && view.reason == reason;
        if same && !history {
            return;
        }
        view.status = status;
        view.reason = reason;
        if let Some(last) = states.last() {
            view.last_state = Some(*last);
        }
        view.at_ms = Some(now);
        if history {
            view.history.push(NoticeHistoryEntry {
                states: states.to_vec(),
                status,
                reason,
                wake,
                at_ms: now,
            });
            let excess = view.history.len().saturating_sub(HISTORY_MAX);
            view.history.drain(..excess);
        }
        if matches!(
            status,
            NoticeStatus::Told | NoticeStatus::Dropped | NoticeStatus::NotSent
        ) {
            if let Some(last) = states.last() {
                rec.last_notified = Some(last.as_str().to_owned());
            }
        }
        self.dirty = true;
        self.changed = true;
    }

    /// Mark each due item of `tag`'s bucket held for `reason` (history only
    /// when its reason changes).
    fn record_held(&mut self, tag: &str, reason: NoticeReason, now: i64) {
        let items: Vec<(String, Vec<JobEvent>)> = self
            .store
            .focuses
            .get(tag)
            .map(|f| {
                f.bucket
                    .items
                    .iter()
                    .filter(|p| p.due)
                    .map(|p| (p.item.job_id.clone(), p.item.states.clone()))
                    .collect()
            })
            .unwrap_or_default();
        for (id, states) in items {
            let changed = self.store.jobs.get(&id).is_some_and(|r| {
                r.notice.status != NoticeStatus::Held || r.notice.reason != Some(reason)
            });
            if changed {
                self.record(
                    &id,
                    NoticeStatus::Held,
                    Some(reason),
                    &states,
                    false,
                    true,
                    now,
                );
            }
        }
    }

    /// Hold `tag`'s due delivery for `reason` (audited when the reason is new).
    fn hold(&mut self, tag: &str, reason: HoldReason, now: i64) {
        let bucket = &mut self.focus(tag).bucket;
        let before = bucket.hold.map(|h| h.reason);
        bucket.hold_with(reason, now);
        if before != Some(reason) {
            self.audits.push(MotherAuditEvent::JobNoticeHeld {
                focus: tag.to_owned(),
                reason: reason.into(),
            });
            self.changed = true;
            self.dirty = true;
        }
        self.record_held(tag, reason.into(), now);
    }

    /// Drop everything waiting for `tag` with `status`/`reason`.
    fn drop_all(
        &mut self,
        tag: &str,
        status: NoticeStatus,
        reason: NoticeReason,
        audit: Option<&'static str>,
        now: i64,
    ) -> bool {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return false;
        };
        let gone = focus.bucket.clear();
        if gone.is_empty() {
            return false;
        }
        for item in &gone {
            self.record(
                &item.job_id,
                status,
                Some(reason),
                &item.states,
                false,
                true,
                now,
            );
        }
        if let Some(word) = audit {
            self.audits.push(MotherAuditEvent::JobNoticeDropped {
                focus: tag.to_owned(),
                reason: word,
            });
        }
        self.dirty = true;
        self.changed = true;
        true
    }

    fn on_jobs(&mut self, jobs: &[MotherJob], now: i64) {
        if !self.bootstrapped {
            // First run ever: what is there now was never news to anyone.
            for job in jobs {
                let mut rec = record_for(job, now);
                rec.last_notified = Some(job.state.clone());
                if rec.focus.is_none() {
                    rec.notice.reason = Some(NoticeReason::NotNotifiable);
                }
                self.store.jobs.insert(job.id.clone(), rec);
            }
            self.bootstrapped = true;
            self.restart_check = false;
            self.dirty = true;
            self.changed = true;
            return;
        }
        let restart = std::mem::take(&mut self.restart_check);
        for job in jobs {
            let fresh = record_for(job, now);
            let prev = self.store.jobs.get(&job.id).cloned();
            let mut events = detect::changes(
                prev.as_ref().map(|p| Seen {
                    state: &p.state,
                    has_pr: p.has_pr,
                }),
                job,
            );
            if restart && events.is_empty() {
                if let Some(p) = &prev {
                    if p.last_notified.as_deref() != Some(job.state.as_str()) {
                        events.extend(JobEvent::from_state(&job.state));
                    }
                }
            }
            // Keep what the record learned; keep its notice and accounting.
            match self.store.jobs.get_mut(&job.id) {
                Some(rec) => {
                    let moved = rec.state != fresh.state
                        || rec.has_pr != fresh.has_pr
                        || rec.focus != fresh.focus
                        || rec.notify != fresh.notify
                        || rec.snapshot != fresh.snapshot
                        || now - rec.last_seen_ms > HOUR_MS;
                    rec.state = fresh.state;
                    rec.has_pr = fresh.has_pr;
                    rec.focus = fresh.focus;
                    rec.notify = fresh.notify;
                    rec.snapshot = fresh.snapshot;
                    rec.last_seen_ms = now;
                    self.dirty |= moved;
                }
                None => {
                    self.dirty = true;
                    self.changed = true;
                    self.store.jobs.insert(job.id.clone(), fresh);
                }
            }
            let Some(rec) = self.store.jobs.get_mut(&job.id) else {
                continue;
            };
            let Some(tag) = rec.focus.clone() else {
                // Never notified: unverified, the user's own, or unknown.
                rec.last_notified = Some(job.state.clone());
                if rec.notice.status != NoticeStatus::None
                    || rec.notice.reason != Some(NoticeReason::NotNotifiable)
                {
                    rec.notice.status = NoticeStatus::None;
                    rec.notice.reason = Some(NoticeReason::NotNotifiable);
                    self.dirty = true;
                    self.changed = true;
                }
                continue;
            };
            if rec.notice.reason == Some(NoticeReason::NotNotifiable) {
                // An origin upgraded to verified since.
                rec.notice.reason = None;
                self.changed = true;
            }
            let notify = rec.notify;
            // The origin book says the focus is closed (it saw a registry push
            // without it): after a daemon restart no departure is reported for
            // a focus closed meanwhile, so this is how the engine learns it.
            let closed = job
                .nostromo
                .as_ref()
                .is_some_and(|a| a.origin.closed == Some(true));
            if closed && self.closed.insert(tag.clone()) {
                self.drop_all(
                    &tag,
                    NoticeStatus::NotSent,
                    NoticeReason::FocusClosed,
                    Some("focus_closed"),
                    now,
                );
            }
            if prev.is_none() {
                if let Some(born) = self.notice_turns.get_mut(&tag) {
                    *born = true;
                }
            }
            for event in events {
                let snapshot = item_for(job, event);
                self.route(&job.id, &tag, notify, snapshot, event, now);
            }
        }
        // Forget jobs gone from the feed for a week.
        let before = self.store.jobs.len();
        self.store
            .jobs
            .retain(|_, r| now - r.last_seen_ms <= JOB_ABSENT_MAX_MS);
        if self.store.jobs.len() != before {
            self.dirty = true;
        }
    }

    fn pr_event(&mut self, job_id: &str, merged: bool, now: i64) {
        let Some(rec) = self.store.jobs.get_mut(job_id) else {
            return;
        };
        if rec.pr_final == Some(merged) {
            return;
        }
        rec.pr_final = Some(merged);
        self.dirty = true;
        let Some(tag) = rec.focus.clone() else {
            return;
        };
        let event = if merged {
            JobEvent::PrMerged
        } else {
            JobEvent::PrClosed
        };
        let snapshot = NoticeItem {
            job_id: job_id.to_owned(),
            title: rec.snapshot.title.clone(),
            states: Vec::new(),
            pr_url: rec.snapshot.pr_url.clone(),
            cost_usd: rec.snapshot.cost_usd,
            reason: None,
        };
        let notify = rec.notify;
        self.route(job_id, &tag, notify, snapshot, event, now);
    }

    /// Send one change of a verified job of `tag` where it belongs.
    fn route(
        &mut self,
        job_id: &str,
        tag: &str,
        notify: Option<NotifyLevel>,
        snapshot: NoticeItem,
        event: JobEvent,
        now: i64,
    ) {
        if self.closed.contains(tag) {
            self.record(
                job_id,
                NoticeStatus::NotSent,
                Some(NoticeReason::FocusClosed),
                &[event],
                false,
                true,
                now,
            );
            return;
        }
        let global = self.store.enabled;
        let focus = self.focus(tag);
        focus.last_seen_ms = now;
        let mode = focus.mode;
        let level = match effective(global, mode, notify) {
            Ok(level) => level,
            Err(reason) => {
                self.record(
                    job_id,
                    NoticeStatus::Dropped,
                    Some(reason),
                    &[event],
                    false,
                    true,
                    now,
                );
                if event.is_waking() {
                    self.audits.push(MotherAuditEvent::JobNoticeDropped {
                        focus: tag.to_owned(),
                        reason: if reason == NoticeReason::GlobalOff {
                            "global_off"
                        } else {
                            "focus_off"
                        },
                    });
                }
                return;
            }
        };
        let due = event.is_waking();
        let bucket = &mut self.focus(tag).bucket;
        if !bucket.add(snapshot, event, due, now) {
            // Already waiting with this state (a restart's re-check): it keeps
            // its window or hold, and no window opens for it again.
            return;
        }
        let states = bucket
            .items
            .iter()
            .find(|p| p.item.job_id == job_id)
            .map(|p| p.item.states.clone())
            .unwrap_or_default();
        // (reason, add a history entry)
        let held: Option<(NoticeReason, bool)> = match level {
            NotifyLevel::Wake => {
                if due || bucket.window.is_some() {
                    bucket.touch_window(now);
                }
                due.then(|| {
                    let reason = match bucket.hold.map(|h| h.reason) {
                        Some(r @ (HoldReason::Cap | HoldReason::LoopGuard)) => r.into(),
                        _ => NoticeReason::Batching,
                    };
                    (reason, false)
                })
            }
            NotifyLevel::Quiet => {
                // It joins an open window (moving its end) but never opens one.
                if bucket.window.is_some() {
                    bucket.touch_window(now);
                }
                due.then(|| {
                    bucket.hold_at_least(HoldReason::Quiet, now);
                    let reason = bucket
                        .hold
                        .map(|h| h.reason.into())
                        .unwrap_or(NoticeReason::Quiet);
                    (reason, true)
                })
            }
            NotifyLevel::Off => None,
        };
        self.dirty = true;
        self.changed = true;
        if let Some((reason, history)) = held {
            self.record(
                job_id,
                NoticeStatus::Held,
                Some(reason),
                &states,
                false,
                history,
                now,
            );
        }
    }

    /// Try to deliver what is due for `tag`.
    fn attempt(&mut self, tag: &str, trigger: Trigger, now: i64) -> Option<Effect> {
        let (has_due, chain_held, capped) = {
            let focus = self.store.focuses.get(tag)?;
            (
                focus.bucket.has_due(),
                focus.limits.chain_held(),
                focus.limits.capped(now),
            )
        };
        if !has_due {
            return None;
        }
        if self.closed.contains(tag) {
            self.drop_all(
                tag,
                NoticeStatus::NotSent,
                NoticeReason::FocusClosed,
                None,
                now,
            );
            return None;
        }
        if trigger == Trigger::DuringNoticeTurn {
            // Queued behind the notice turn now running, this delivery is the
            // next notice turn: send it only if that one stays within the cap
            // (this turn already counted) and the loop guard even if this turn
            // queues a job. Otherwise it waits for a later turn's start.
            let chain = self.store.focuses.get(tag).map_or(0, |f| f.limits.chain);
            if chain + 1 >= limits::CHAIN_LIMIT || capped {
                return None;
            }
        } else {
            if trigger != Trigger::UserTurn {
                if chain_held {
                    self.hold(tag, HoldReason::LoopGuard, now);
                    return None;
                }
                if capped {
                    self.hold(tag, HoldReason::Cap, now);
                    return None;
                }
            }
            if self.notice_turns.contains_key(tag) {
                self.hold(tag, HoldReason::Busy, now);
                return None;
            }
        }
        let bucket = &mut self.focus(tag).bucket;
        bucket.gen += 1;
        let gen = bucket.gen;
        let items = bucket.take_items();
        let fresh_items: Vec<NoticeItem> = items.iter().map(|p| p.item.clone()).collect();
        // One element per job: a job whose notice still waits in the session's
        // queue gains the new states in place of a second element.
        for p in items {
            match bucket
                .inflight
                .iter_mut()
                .find(|f| !f.told && f.item.job_id == p.item.job_id)
            {
                Some(f) => {
                    for s in &p.item.states {
                        if f.item.states.last() != Some(s) {
                            f.item.states.push(*s);
                        }
                    }
                    f.item.title = p.item.title;
                    f.item.pr_url = p.item.pr_url;
                    f.item.cost_usd = p.item.cost_usd;
                    f.item.reason = p.item.reason;
                    f.due |= p.due;
                    f.gen = gen;
                    f.at_ms = now;
                }
                None => bucket.inflight.push(InFlight {
                    gen,
                    item: p.item,
                    due: p.due,
                    at_ms: now,
                    told: false,
                }),
            }
        }
        let merged_items: Vec<NoticeItem> =
            bucket.untold_inflight().map(|f| f.item.clone()).collect();
        let merged = element::render_message(&merged_items);
        let fresh = element::render_message(&fresh_items);
        bucket.hold = None;
        bucket.window = None;
        for item in &fresh_items {
            self.record(
                &item.job_id,
                NoticeStatus::Held,
                Some(NoticeReason::Busy),
                &item.states,
                false,
                false,
                now,
            );
        }
        self.dirty = true;
        self.changed = true;
        Some(Effect::Deliver {
            tag: tag.to_owned(),
            gen,
            merged,
            fresh,
        })
    }

    /// The outcome of handing generation `gen` to `tag`'s session (`None`: no
    /// live session).
    fn delivered(&mut self, tag: &str, gen: u64, outcome: Option<NoticeDelivery>, now: i64) {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return;
        };
        match outcome {
            Some(NoticeDelivery::Woke) => {
                let told: Vec<NoticeItem> = focus
                    .bucket
                    .inflight
                    .iter_mut()
                    .filter(|f| f.gen == gen && !f.told)
                    .map(|f| {
                        f.told = true;
                        f.item.clone()
                    })
                    .collect();
                self.told(tag, &told, true, now);
            }
            Some(NoticeDelivery::Queued) => {}
            Some(NoticeDelivery::Replaced) => {
                for f in focus.bucket.inflight.iter_mut().filter(|f| !f.told) {
                    f.gen = gen;
                }
            }
            None => {
                let (back, keep): (Vec<InFlight>, Vec<InFlight>) =
                    std::mem::take(&mut focus.bucket.inflight)
                        .into_iter()
                        .partition(|f| f.gen == gen && !f.told);
                focus.bucket.inflight = keep;
                focus.bucket.restore(
                    back.into_iter()
                        .map(|f| Pending {
                            item: f.item,
                            due: f.due,
                            updated_ms: f.at_ms,
                        })
                        .collect(),
                );
                self.hold(tag, HoldReason::SessionNotRunning, now);
            }
        }
        self.dirty = true;
        self.changed = true;
    }

    /// `items` reached `tag`'s agent.
    fn told(&mut self, tag: &str, items: &[NoticeItem], wake: bool, now: i64) {
        if items.is_empty() {
            return;
        }
        for item in items {
            self.record(
                &item.job_id,
                NoticeStatus::Told,
                None,
                &item.states,
                wake,
                true,
                now,
            );
        }
        self.audits.push(MotherAuditEvent::JobNoticeDelivered {
            job_ids: items.iter().map(|i| i.job_id.clone()).collect(),
            focus: tag.to_owned(),
            wake,
            combined: items.len(),
        });
    }

    fn on_turn(&mut self, tag: &str, event: &TurnEvent, now: i64) -> Vec<Effect> {
        let mut effects = Vec::new();
        match event {
            TurnEvent::Started { author } if author.is_notice() => {
                let TurnAuthor::Injected { key, .. } = author else {
                    return effects;
                };
                let gen = gen_of(key).unwrap_or(0);
                self.notice_turns.insert(tag.to_owned(), false);
                let focus = self.focus(tag);
                focus.limits.note_notice_turn(now);
                let inflight = std::mem::take(&mut focus.bucket.inflight);
                let mut told = Vec::new();
                let mut lost = Vec::new();
                let mut keep = Vec::new();
                for f in inflight {
                    if f.gen == gen {
                        if !f.told {
                            told.push(f.item);
                        }
                    } else if f.gen < gen {
                        if !f.told {
                            lost.push(Pending {
                                item: f.item,
                                due: f.due,
                                updated_ms: f.at_ms,
                            });
                        }
                    } else {
                        keep.push(f);
                    }
                }
                focus.bucket.inflight = keep;
                let lost_any = !lost.is_empty();
                focus.bucket.restore(lost);
                let after_turn = matches!(
                    focus.bucket.hold.map(|h| h.reason),
                    Some(HoldReason::Quiet | HoldReason::SessionNotRunning)
                );
                self.told(tag, &told, false, now);
                if lost_any {
                    // Lost from a cleared queue: they go when this turn ends.
                    self.hold(tag, HoldReason::Busy, now);
                } else if after_turn {
                    // Quiet and not-running holds go behind any turn that
                    // starts, this one included, when that is safe.
                    effects.extend(self.attempt(tag, Trigger::DuringNoticeTurn, now));
                }
                self.dirty = true;
                self.changed = true;
            }
            TurnEvent::Started { author } => {
                // A turn of any other author: a notice turn before it is over.
                self.end_notice_turn(tag);
                let user = matches!(author, TurnAuthor::User);
                let Some(focus) = self.store.focuses.get_mut(tag) else {
                    return effects;
                };
                if user && focus.limits.chain > 0 {
                    focus.limits.user_turn();
                    self.dirty = true;
                    self.changed = true;
                }
                // A notice handed to the session and not yet started is either
                // still queued behind this turn or was lost (the queue was
                // cleared): messages are written in order, so one queued
                // before this turn's would have started already. Take it back
                // and hand it again, so it is neither lost nor told twice.
                let requeued = take_back_inflight(&mut focus.bucket);
                if requeued {
                    effects.push(Effect::Withdraw {
                        tag: tag.to_owned(),
                    });
                }
                let hold = focus.bucket.hold.map(|h| h.reason);
                let release = requeued
                    || match hold {
                        None => false,
                        Some(_) if user => true,
                        Some(r) => matches!(r, HoldReason::Quiet | HoldReason::SessionNotRunning),
                    };
                if release {
                    let trigger = if user {
                        Trigger::UserTurn
                    } else {
                        Trigger::AfterTurn
                    };
                    effects.extend(self.attempt(tag, trigger, now));
                }
            }
            TurnEvent::Discarded => {
                // The notice turn that "started" was a phantom: the real turn's
                // Started follows. Undo its count; its items stay told.
                if self.notice_turns.remove(tag).is_some() {
                    let limits = &mut self.focus(tag).limits;
                    limits.wakes.pop();
                    self.dirty = true;
                    self.changed = true;
                }
            }
            TurnEvent::Completed | TurnEvent::Exited => {
                let was_notice = self.end_notice_turn(tag);
                // Only what was due to wake and waited for this notice turn
                // goes now (the session is idle, so it wakes). Quiet and
                // not-running holds never wake: they wait for a turn to start.
                if was_notice && matches!(event, TurnEvent::Completed) {
                    let hold = self
                        .store
                        .focuses
                        .get(tag)
                        .and_then(|f| f.bucket.hold.map(|h| h.reason));
                    if hold == Some(HoldReason::Busy) {
                        effects.extend(self.attempt(tag, Trigger::AfterTurn, now));
                    }
                }
            }
        }
        effects
    }

    /// End `tag`'s notice turn, if it is in one: grow or end the chain.
    fn end_notice_turn(&mut self, tag: &str) -> bool {
        let Some(born) = self.notice_turns.remove(tag) else {
            return false;
        };
        let limits = &mut self.focus(tag).limits;
        let before = limits.chain;
        limits.notice_turn_ended(born);
        if limits.chain != before {
            self.dirty = true;
            self.changed = true;
        }
        true
    }

    fn on_registry(&mut self, present: &[String], departed: &[String], now: i64) {
        for tag in present {
            self.closed.remove(tag);
            if let Some(focus) = self.store.focuses.get_mut(tag) {
                if now - focus.last_seen_ms > HOUR_MS {
                    focus.last_seen_ms = now;
                    self.dirty = true;
                }
            }
        }
        for tag in departed {
            self.closed.insert(tag.clone());
            self.notice_turns.remove(tag);
            self.drop_all(
                tag,
                NoticeStatus::NotSent,
                NoticeReason::FocusClosed,
                Some("focus_closed"),
                now,
            );
        }
        // Modes of focuses unseen for 90 days go; departed ones keep theirs
        // until then (a recreated focus gets its tag back).
        let before = self.store.focuses.len();
        self.store
            .focuses
            .retain(|_, f| !(now - f.last_seen_ms > FOCUS_UNSEEN_MAX_MS && f.bucket.is_empty()));
        if self.store.focuses.len() != before {
            self.dirty = true;
            self.changed = true;
        }
    }

    fn tick(&mut self, now: i64) -> Vec<Effect> {
        let mut effects = Vec::new();
        let tags: Vec<String> = self.store.focuses.keys().cloned().collect();
        for tag in tags {
            self.expire(&tag, now);
            let Some(focus) = self.store.focuses.get_mut(&tag) else {
                continue;
            };
            if focus.bucket.window.is_some_and(|w| now >= w.closes_at()) {
                focus.bucket.window = None;
                effects.extend(self.attempt(&tag, Trigger::Window, now));
                continue;
            }
            let rolled = focus.bucket.hold.map(|h| h.reason) == Some(HoldReason::Cap)
                && !focus.limits.capped(now);
            if rolled {
                if focus.mode == Some(NotifyLevel::Quiet) {
                    // A Quiet focus is never woken: back to "after a turn".
                    self.hold(&tag, HoldReason::Quiet, now);
                } else {
                    effects.extend(self.attempt(&tag, Trigger::CapRolled, now));
                }
            }
        }
        let before = self.store.jobs.len();
        self.store
            .jobs
            .retain(|_, r| now - r.last_seen_ms <= JOB_ABSENT_MAX_MS);
        if self.store.jobs.len() != before {
            self.dirty = true;
        }
        effects
    }

    /// Drop `tag`'s items (waiting or in flight) older than 24 h.
    fn expire(&mut self, tag: &str, now: i64) {
        let Some(focus) = self.store.focuses.get_mut(tag) else {
            return;
        };
        let old = |t: i64| now - t > batch::HOLD_MAX_MS;
        let mut gone: Vec<NoticeItem> = Vec::new();
        let (expired, kept): (Vec<Pending>, Vec<Pending>) = std::mem::take(&mut focus.bucket.items)
            .into_iter()
            .partition(|p| old(p.updated_ms));
        focus.bucket.items = kept;
        gone.extend(expired.into_iter().map(|p| p.item));
        let (expired, kept): (Vec<InFlight>, Vec<InFlight>) =
            std::mem::take(&mut focus.bucket.inflight)
                .into_iter()
                .partition(|f| old(f.at_ms) || (f.told && now - f.at_ms > HOUR_MS));
        focus.bucket.inflight = kept;
        gone.extend(expired.into_iter().filter(|f| !f.told).map(|f| f.item));
        if !focus.bucket.has_due() && focus.bucket.window.is_none() {
            focus.bucket.hold = None;
        }
        if gone.is_empty() {
            return;
        }
        for item in &gone {
            self.record(
                &item.job_id,
                NoticeStatus::Dropped,
                None,
                &item.states,
                false,
                true,
                now,
            );
        }
        self.audits.push(MotherAuditEvent::JobNoticeDropped {
            focus: tag.to_owned(),
            reason: "expired",
        });
        self.dirty = true;
        self.changed = true;
    }

    fn apply_settings(
        &mut self,
        scope: NoticeScope,
        tag: Option<&str>,
        mode: Option<NotifyLevel>,
        enabled: Option<bool>,
        now: i64,
    ) -> Result<Vec<Effect>, SettingsError> {
        let mut effects = Vec::new();
        match scope {
            NoticeScope::Focus => {
                let (Some(tag), Some(mode)) = (tag.filter(|t| is_tag_like(t)), mode) else {
                    return Err(SettingsError::FocusNeedsTagAndMode);
                };
                let focus = self.focus(tag);
                focus.mode = (mode != NotifyLevel::Wake).then_some(mode);
                focus.last_seen_ms = now;
                match mode {
                    NotifyLevel::Off => {
                        self.drop_all(
                            tag,
                            NoticeStatus::Dropped,
                            NoticeReason::FocusOff,
                            Some("focus_off"),
                            now,
                        );
                        effects.push(Effect::Withdraw {
                            tag: tag.to_owned(),
                        });
                    }
                    NotifyLevel::Quiet => {
                        let bucket = &mut self.focus(tag).bucket;
                        if bucket.window.take().is_some() && bucket.has_due() {
                            self.hold(tag, HoldReason::Quiet, now);
                        }
                    }
                    // Quiet to Wake does not wake for what is held: it goes
                    // after the next turn, as it would have.
                    NotifyLevel::Wake => {}
                }
                self.audits
                    .push(MotherAuditEvent::MotherNoticeSettingsChanged {
                        scope,
                        focus: Some(tag.to_owned()),
                        mode: Some(mode),
                        enabled: None,
                    });
            }
            NoticeScope::Global => {
                let Some(enabled) = enabled else {
                    return Err(SettingsError::GlobalNeedsEnabled);
                };
                self.store.enabled = enabled;
                if !enabled {
                    let tags: Vec<String> = self.store.focuses.keys().cloned().collect();
                    for tag in tags {
                        if self.drop_all(
                            &tag,
                            NoticeStatus::Dropped,
                            NoticeReason::GlobalOff,
                            Some("global_off"),
                            now,
                        ) {
                            effects.push(Effect::Withdraw { tag });
                        }
                    }
                }
                self.audits
                    .push(MotherAuditEvent::MotherNoticeSettingsChanged {
                        scope,
                        focus: None,
                        mode: None,
                        enabled: Some(enabled),
                    });
            }
        }
        self.dirty = true;
        self.changed = true;
        Ok(effects)
    }

    fn focus_states(&self, now: i64) -> Vec<FocusNoticeState> {
        self.store
            .focuses
            .iter()
            .filter(|(_, f)| !f.is_trivial())
            .map(|(tag, f)| {
                let b = &f.bucket;
                let waiting =
                    b.items.iter().filter(|p| p.due).count() + b.untold_inflight().count();
                let reason = match (b.hold, b.window, b.untold_inflight().next()) {
                    (Some(Hold { reason, .. }), _, _) => Some(reason.into()),
                    (None, Some(_), _) => Some(NoticeReason::Batching),
                    (None, None, Some(_)) => Some(NoticeReason::Busy),
                    _ => None,
                };
                FocusNoticeState {
                    tag: tag.clone(),
                    mode: f.mode.unwrap_or(NotifyLevel::Wake),
                    held: reason.filter(|_| waiting > 0).map(|reason| HeldSummary {
                        count: waiting,
                        reason,
                    }),
                    chain_held: f.limits.chain_held(),
                    wakes_by_day: f.limits.wakes_by_day(now),
                }
            })
            .collect()
    }
}

/// Move every untold item in flight back to the waiting items. Returns
/// whether there was any.
fn take_back_inflight(bucket: &mut batch::Bucket) -> bool {
    let (untold, told): (Vec<InFlight>, Vec<InFlight>) = std::mem::take(&mut bucket.inflight)
        .into_iter()
        .partition(|f| !f.told);
    bucket.inflight = told;
    if untold.is_empty() {
        return false;
    }
    bucket.restore(
        untold
            .into_iter()
            .map(|f| Pending {
                item: f.item,
                due: f.due,
                updated_ms: f.at_ms,
            })
            .collect(),
    );
    true
}

/// A job's record as the feed shows it now (accounting fields empty).
fn record_for(job: &MotherJob, now: i64) -> JobRecord {
    let focus = job
        .nostromo
        .as_ref()
        .filter(|a| a.origin.kind == OriginKind::Focus)
        .and_then(|a| a.origin.focus_tag.clone());
    JobRecord {
        state: job.state.clone(),
        has_pr: job.pr_url.is_some(),
        last_seen_ms: now,
        last_notified: None,
        focus,
        notify: job.nostromo.as_ref().and_then(|a| a.notify),
        snapshot: Snapshot {
            title: element::clean_title(&job.title),
            pr_url: job.pr_url.as_deref().and_then(element::clean_pr),
            cost_usd: job.actual_cost_usd,
        },
        pr_final: None,
        notice: NoticeView::default(),
    }
}

/// What a notice says about `job` for `event` (states filled in by the batch).
fn item_for(job: &MotherJob, event: JobEvent) -> NoticeItem {
    NoticeItem {
        job_id: job.id.clone(),
        title: element::clean_title(&job.title),
        states: Vec::new(),
        pr_url: job.pr_url.as_deref().and_then(element::clean_pr),
        cost_usd: job.actual_cost_usd,
        reason: element::reason_for(job, event),
    }
}

/// A focus tag as the settings frame may name it.
fn is_tag_like(s: &str) -> bool {
    !s.is_empty()
        && s.chars().count() <= 80
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
}

// ── wiring ───────────────────────────────────────────────────────────────────

/// Connect `engine` to the session manager: deliveries go through it, its
/// focus registry pushes reach the engine, and every session's turn events
/// are handed to one worker thread (which also runs the timers every
/// [`TICK_EVERY`]). The thread ends when the manager drops its hook.
pub fn attach(engine: &Arc<NoticeEngine>, sessions: &Arc<Mutex<SessionManager>>) {
    engine.set_port(Arc::new(ManagerPort::new(sessions)));
    let (tx, rx) = std::sync::mpsc::channel::<(String, TurnEvent)>();
    {
        let mut mgr = sessions.lock().unwrap_or_else(|e| e.into_inner());
        mgr.configure_notice_engine(Arc::clone(engine));
        mgr.set_turn_hook(Arc::new(move |tag: &str, event: &TurnEvent| {
            let _ = tx.send((tag.to_owned(), event.clone()));
        }));
    }
    let weak = Arc::downgrade(engine);
    let spawned = std::thread::Builder::new()
        .name("mother-notices".into())
        .spawn(move || {
            let mut last_tick = std::time::Instant::now();
            loop {
                let next = rx.recv_timeout(TICK_EVERY);
                let Some(engine) = weak.upgrade() else {
                    break;
                };
                match next {
                    Ok((tag, event)) => engine.on_turn(&tag, &event),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
                if last_tick.elapsed() >= TICK_EVERY {
                    engine.tick();
                    last_tick = std::time::Instant::now();
                }
            }
        });
    if spawned.is_err() {
        tracing::warn!("mother notice worker could not start: notices are off");
    }
}

/// Feed every published job list to `engine`, in order.
pub fn spawn_feed_watcher(
    engine: Arc<NoticeEngine>,
    feed: &JobsFeed,
) -> tokio::task::JoinHandle<()> {
    let mut rx = feed.jobs_rx();
    tokio::spawn(async move {
        while rx.changed().await.is_ok() {
            let jobs = rx.borrow_and_update().clone();
            let engine = Arc::clone(&engine);
            let _ = tokio::task::spawn_blocking(move || engine.on_jobs(&jobs)).await;
        }
    })
}

/// Publish the engine's changes (debounced [`PUBLISH_DEBOUNCE`]): the
/// `MotherNoticeState` frame, and the job list re-annotated through the feed
/// (so MCP readers see the same notice records) as a `MotherJobs` frame.
///
/// `republish` (the IPC server's "retained frames were lost" signal) resends
/// the state frame, so a client subscribing later still gets it.
pub fn spawn_publisher(
    engine: Arc<NoticeEngine>,
    feed: JobsFeed,
    tx: tokio::sync::broadcast::Sender<ServerMsg>,
    republish: Option<watch::Receiver<u64>>,
) -> tokio::task::JoinHandle<()> {
    let mut changes = engine.changes();
    let mut listening = republish.is_some();
    let (_keep, idle) = watch::channel(0u64);
    let mut republish = republish.unwrap_or(idle);
    tokio::spawn(async move {
        let _ = tx.send(engine.state_msg());
        loop {
            tokio::select! {
                changed = changes.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    tokio::time::sleep(PUBLISH_DEBOUNCE).await;
                    changes.borrow_and_update();
                    let _ = tx.send(engine.state_msg());
                    if let Some(jobs) = feed.republish_annotations() {
                        let _ = tx.send(ServerMsg::MotherJobs { jobs });
                    }
                }
                lost = republish.changed(), if listening => {
                    if lost.is_err() {
                        listening = false;
                        continue;
                    }
                    let _ = tx.send(engine.state_msg());
                }
            }
        }
    })
}

#[cfg(test)]
mod tests;
