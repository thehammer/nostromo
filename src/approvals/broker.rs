//! The approval broker (design contract §6): the daemon's one place that hears
//! a session's permission requests, logs them, and **always answers them**.
//!
//! A request the guard lets through is **held** for a human only when all of
//! these are true: a verified Mac app that renders approvals is connected
//! ([`Presenter::can_present`]), and the session carries the guard hook
//! ([`SessionInfo::guarded`], the ordering rule: no Approve before the guard).
//! Otherwise it ends at once as `no_app` / `approval_unavailable`: a clear deny
//! plus a `request` and an `outcome` entry in the audit log. (The Mac app does
//! not claim to render approvals yet, so on a real machine nothing is held.)
//!
//! A held request is broadcast ([`ServerMsg::ApprovalRequest`]) and waits for
//! one of: an answer ([`ApprovalBroker::answer`], first wins), the 15-minute
//! deadline ([`APPROVAL_TIMEOUT`]), the app going away for longer than
//! [`PRESENTER_GRACE`], its session stopping, or the CLI withdrawing it.
//!
//! # Invariants
//!
//! - **Never auto-approve (T-INV-3).** Exactly one path writes
//!   `"behavior":"allow"`: [`ApprovalBroker::answer`] with `allow_once`, which the
//!   server calls only for the verified app's connection. Every other ending
//!   (timeout, error, restart, no app, a closed channel, a failed write) writes a
//!   deny or nothing.
//! - **Exactly one ending per request.** A request lives in `pending` until one
//!   path removes it (the answer path, the guard, the timeout, a cancel, the
//!   session going away, shutdown, the watchdog). Whoever removes it owns the
//!   response and the `outcome` entry; everyone else finds nothing and does
//!   nothing.
//! - **Never write to a session that is gone.** The sink is looked up by the
//!   session's generation and must report itself live; otherwise the ending is
//!   recorded as `cancelled` and nothing is written.
//! - **The reader never waits on the broker.** [`ApprovalBroker::submit`] takes a
//!   short lock and sends to a channel. A worker thread does the parsing, the
//!   guard (which may run `tmux`/`ps`), the audit writes and the stdin writes.
//! - **Lock order.** The state lock is held for map operations only, never across
//!   I/O, and never while calling into a sink (the session's stdin lock is a
//!   leaf lock). The broker never takes the session manager's lock.
//! - **A stuck worker cannot strand a request.** A request is registered when it
//!   is submitted, and a timer task (on the tokio runtime the daemon always has,
//!   captured at [`ApprovalBroker::register_session`]; not the worker) force-denies it if it is
//!   still unresolved [`ARRIVAL_WATCHDOG`] after arriving (for a held request:
//!   [`WATCHDOG_GRACE`] after its deadline), logging `watchdog: true`.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use tokio::sync::broadcast;
use tokio::task::AbortHandle;
use tracing::{debug, error, info, warn};

use super::audit::{sanitize_string, AuditFilter, AuditLog, Entry, Event};
use super::display::ApprovalDisplay;
use super::guard::{self, GuardVerdict, HookPayload, PaneProbe, SystemPaneProbe};
use super::request::{FileSettings, PermissionRequest, SettingsSource};
use super::wire::{
    clean_note, AgentWire, AnswerRefusal, ApprovalDecision, ApprovalFlags, ApprovalOption,
    ApprovalRequestWire, DecisionKind, RefusalChannel, SubagentWire,
};
use super::ApprovalsPaths;
use crate::data::work::is_invisible;
use crate::ipc::protocol::ServerMsg;

// ── the words an agent is told (contract §6.2, verbatim) ──────────────────────

/// The contract's words for a request nobody could be asked about because the app is
/// closed (no verified Nostromo app is connected).
pub const NO_APP_MESSAGE: &str =
    "Nostromo can't ask anyone right now (the app is closed), so this was denied. Tell the user what you wanted to run.";
/// What an agent is told when the app is open but cannot show the request: its
/// approval screen isn't there (the app does not render approvals yet, or the
/// session cannot be asked about safely). (An `AskUserQuestion` or `ExitPlanMode`
/// request, if one reaches `can_use_tool`, gets these words too.)
pub const APPROVAL_UNAVAILABLE_MESSAGE: &str = "Nostromo's approval screen isn't available yet, so this was denied. Tell the user what you wanted to run and give them the exact command; do not retry it.";
/// The error answer to a `control_request` of any subtype but `can_use_tool`: the
/// host does not handle it.
pub const UNSUPPORTED_REQUEST_ERROR: &str = "Nostromo does not handle this kind of request.";
/// A held request nobody answered in time.
pub const TIMED_OUT_MESSAGE: &str = "No one answered the approval request in Nostromo within 15 minutes, so it was denied. Don't retry it unless the user asks; tell them what you wanted to run.";
/// The daemon is shutting down.
pub const RESTART_MESSAGE: &str =
    "Nostromo restarted before anyone answered; this was not approved.";
/// The request could not be read (not in the contract's table: there is no
/// other honest thing to say about a frame we cannot parse).
pub const INVALID_REQUEST_MESSAGE: &str =
    "Nostromo couldn't read this permission request, so it was denied. Tell the user what you wanted to run.";

/// How long a held request waits for a human (user default U1).
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// The same constant under its earlier name.
pub const REQUEST_TIMEOUT: Duration = APPROVAL_TIMEOUT;
/// How long the last approval-rendering app may be gone (a reconnect) before
/// every held request is denied `no_app`.
pub const PRESENTER_GRACE: Duration = Duration::from_secs(3);
/// What the agent is told when the user denies a request.
pub const DENIED_MESSAGE: &str = "The user denied this in Nostromo.";
/// How many ended held requests are remembered, so a late answer can be told what happened.
const RECENT_ENDED: usize = 256;
/// A request that has not been resolved this long after its deadline is force-denied.
pub const WATCHDOG_GRACE: Duration = Duration::from_secs(5);
/// A request that has not been resolved or held this long after arriving is force-denied.
pub const ARRIVAL_WATCHDOG: Duration = Duration::from_secs(1);

/// The file (beside the audit files) that remembers which focuses had a
/// request pending when the daemon crashed.
pub const RESTART_NOTES_FILE: &str = "restart-notes.json";

/// The one line an agent is told after a crash (contract §6.2).
pub fn restart_note_text(tool: &str) -> String {
    format!(
        "A permission request for {tool} was pending when Nostromo restarted. It was not approved."
    )
}

// ── outcomes ──────────────────────────────────────────────────────────────────

/// How a request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Nobody could be asked: the app is closed (contract §6.2; later slices).
    NoApp,
    /// Nobody could be asked: there is no approval screen yet (this slice).
    NotAvailable,
    /// The deny could not be written to the session.
    DenyWriteFailed,
    TimedOut,
    AllowedOnce,
    Denied,
    DeniedAndStopped,
    Restart,
    RestartCrash,
    Withdrawn,
    Cancelled,
    GuardBlocked,
    InvalidRequest,
}

impl Outcome {
    /// The name in the audit log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NoApp => "no_app",
            Self::NotAvailable => "approval_unavailable",
            Self::DenyWriteFailed => "deny_write_failed",
            Self::TimedOut => "timed_out",
            Self::AllowedOnce => "allowed_once",
            Self::Denied => "denied",
            Self::DeniedAndStopped => "denied_and_stopped",
            Self::Restart => "restart",
            Self::RestartCrash => "restart_crash",
            Self::Withdrawn => "withdrawn",
            Self::Cancelled => "cancelled",
            Self::GuardBlocked => "guard_blocked",
            Self::InvalidRequest => "invalid_request",
        }
    }
}

/// How one request ends: what the log says, and what (if anything) the agent is told.
#[derive(Debug, Clone)]
struct Ending {
    outcome: Outcome,
    /// The deny message to write; `None` writes nothing (unless `allow`).
    message: Option<String>,
    rule: Option<Value>,
    watchdog: bool,
    /// Write `{"behavior":"allow","updatedInput":<this>}` instead of a deny. Set
    /// only by [`Ending::allow_once`], which only [`ApprovalBroker::answer`] calls.
    allow: Option<Value>,
    /// The deny also interrupts the agent (`deny_and_stop`).
    interrupt: bool,
    /// The window that answered.
    by_window: Option<String>,
}

impl Ending {
    fn deny(outcome: Outcome, message: &str) -> Self {
        Self {
            outcome,
            message: Some(message.to_owned()),
            rule: None,
            watchdog: false,
            allow: None,
            interrupt: false,
            by_window: None,
        }
    }

    fn silent(outcome: Outcome) -> Self {
        Self {
            outcome,
            message: None,
            rule: None,
            watchdog: false,
            allow: None,
            interrupt: false,
            by_window: None,
        }
    }

    /// The one ending that approves: the human allowed this call once. The input
    /// goes back to the CLI unchanged.
    fn allow_once(input: Value, by_window: &str) -> Self {
        Self {
            allow: Some(input),
            by_window: Some(by_window.to_owned()),
            ..Self::silent(Outcome::AllowedOnce)
        }
    }

    /// The human denied it (and, for `stop`, interrupted the agent).
    fn denied(note: Option<&str>, stop: bool, by_window: &str) -> Self {
        let mut message = DENIED_MESSAGE.to_owned();
        if let Some(note) = note {
            message.push_str("\n\nUser's note: ");
            message.push_str(note);
        }
        Self {
            interrupt: stop,
            by_window: Some(by_window.to_owned()),
            ..Self::deny(
                if stop { Outcome::DeniedAndStopped } else { Outcome::Denied },
                &message,
            )
        }
    }

    /// Nobody can be asked. `app_connected`: a verified app is there but cannot
    /// show the request, so the agent is not told the app is closed.
    fn cannot_ask(guarded: bool, app_connected: bool) -> Self {
        if app_connected && guarded {
            Self::unavailable()
        } else if app_connected {
            Self::deny(Outcome::NoApp, APPROVAL_UNAVAILABLE_MESSAGE)
        } else {
            Self::deny(Outcome::NoApp, NO_APP_MESSAGE)
        }
    }

    /// The body of the `control_response`.
    fn response(&self) -> Option<Value> {
        if let Some(input) = &self.allow {
            return Some(json!({ "behavior": "allow", "updatedInput": input }));
        }
        let mut body = deny_response(self.message.as_deref()?);
        if self.interrupt {
            body["interrupt"] = json!(true);
        }
        Some(body)
    }

    fn unavailable() -> Self {
        Self::deny(Outcome::NotAvailable, APPROVAL_UNAVAILABLE_MESSAGE)
    }

    fn watchdog() -> Self {
        Self {
            watchdog: true,
            ..Self::unavailable()
        }
    }

    /// This ending, but the deny could not be written: the log says so and keeps
    /// what the outcome would have been.
    fn write_failed(self) -> Self {
        let mut rule = match self.rule {
            Some(Value::Object(map)) => map,
            _ => serde_json::Map::new(),
        };
        rule.insert("intended_outcome".into(), json!(self.outcome.as_str()));
        Self {
            outcome: Outcome::DenyWriteFailed,
            rule: Some(Value::Object(rule)),
            ..self
        }
    }

    fn guard(message: &str, rule: &str, detail: &str) -> Self {
        Self {
            rule: Some(json!({ "guard_rule": rule, "detail": detail })),
            ..Self::deny(Outcome::GuardBlocked, message)
        }
    }
}

/// The body of a deny answer.
pub fn deny_response(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

// ── what the broker talks to ──────────────────────────────────────────────────

/// A session's stdin, as the broker writes answers to it.
pub trait SessionSink: Send + Sync {
    /// Is the process still there to read an answer? (False once it has exited.)
    fn live(&self) -> bool;
    /// Write the `control_response` for the CLI's request `cli_request_id` with
    /// `response` as its body.
    fn respond(&self, cli_request_id: &str, response: &Value) -> io::Result<()>;
}

/// Who can put a request in front of a human. In production: a verified Mac app
/// that renders approvals is connected ([`ApprovalPresenters`]).
pub trait Presenter: Send + Sync {
    fn can_present(&self, tag: &str) -> bool;

    /// Is a verified Mac app connected at all (whether or not it renders
    /// approvals)? It decides which words an agent is told when nobody can be
    /// asked. A presenter that doesn't say is taken to have an app.
    fn app_connected(&self) -> bool {
        true
    }
}

/// Nobody can be asked.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoPresenter;

impl Presenter for NoPresenter {
    fn can_present(&self, _tag: &str) -> bool {
        false
    }
}

/// The connections the daemon has verified as the Mac app (a shared handle:
/// clones see the same sets). A connection is an *app* once verified, and a
/// *presenter* when it also subscribed with `renders_approvals`. Keyed by the
/// server's per-connection id.
#[derive(Clone, Default)]
pub struct ApprovalPresenters {
    sets: Arc<Mutex<PresenterSets>>,
}

#[derive(Default)]
struct PresenterSets {
    apps: HashSet<String>,
    presenters: HashSet<String>,
}

impl ApprovalPresenters {
    fn add_app(&self, conn: &str) {
        lock(&self.sets).apps.insert(conn.to_owned());
    }

    fn add_presenter(&self, conn: &str) {
        let mut sets = lock(&self.sets);
        sets.apps.insert(conn.to_owned());
        sets.presenters.insert(conn.to_owned());
    }

    /// Forget `conn`. True if it was a presenter.
    fn remove(&self, conn: &str) -> bool {
        let mut sets = lock(&self.sets);
        sets.apps.remove(conn);
        sets.presenters.remove(conn)
    }

    /// Is a verified app that renders approvals connected?
    pub fn has_presenter(&self) -> bool {
        !lock(&self.sets).presenters.is_empty()
    }

    /// Is a verified app connected, rendering approvals or not?
    pub fn has_app(&self) -> bool {
        !lock(&self.sets).apps.is_empty()
    }
}

impl Presenter for ApprovalPresenters {
    fn can_present(&self, _tag: &str) -> bool {
        self.has_presenter()
    }

    fn app_connected(&self) -> bool {
        self.has_app()
    }
}

/// Makes the probe the guard looks at tmux panes and processes with. A fresh
/// one per request: the system probe reads the process table once.
pub type ProbeFactory = Arc<dyn Fn() -> Box<dyn PaneProbe> + Send + Sync>;

/// What the broker is built from; tests replace any part.
#[derive(Clone)]
pub struct BrokerParts {
    pub presenter: Arc<dyn Presenter>,
    /// The connection sets the server keeps current ([`ApprovalBroker::presenter_connected`]).
    /// With [`BrokerParts::system`] they are what `presenter` reads.
    pub presenters: ApprovalPresenters,
    pub probe: ProbeFactory,
    pub settings: Arc<dyn SettingsSource>,
    /// How long a held request waits ([`REQUEST_TIMEOUT`]).
    pub timeout: Duration,
}

impl BrokerParts {
    /// The production parts: the connected Mac app is who to ask, the real tmux/ps
    /// probe, the real settings files.
    pub fn system() -> Self {
        let presenters = ApprovalPresenters::default();
        Self {
            presenter: Arc::new(presenters.clone()),
            presenters,
            probe: Arc::new(|| Box::new(SystemPaneProbe::new())),
            settings: Arc::new(FileSettings::new()),
            timeout: REQUEST_TIMEOUT,
        }
    }
}

/// A session the broker can answer.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub tag: String,
    pub agent: String,
    pub session_id: Option<String>,
    pub cwd: Option<PathBuf>,
    /// The session's arguments carry the guard hook
    /// ([`crate::ipc::SessionManager::session_has_guard`]). A request from a
    /// session without it is never held: no Approve before the guard.
    pub guarded: bool,
}

/// What [`ApprovalBroker::answer`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnswerResult {
    /// This answer ended the request; `outcome` is how it ended (`allowed_once`,
    /// `denied`, …, or `cancelled` / `deny_write_failed` if the session was gone).
    Applied { outcome: String },
    /// The request had already ended.
    AlreadyResolved { outcome: String },
    /// No held request has this id.
    UnknownRequest,
}

impl AnswerResult {
    /// The refusal frame's fields, or `None` if the answer was applied.
    pub fn refusal(&self) -> Option<(AnswerRefusal, Option<&str>)> {
        match self {
            Self::Applied { .. } => None,
            Self::AlreadyResolved { outcome } => Some((AnswerRefusal::AlreadyResolved, Some(outcome))),
            Self::UnknownRequest => Some((AnswerRefusal::UnknownRequest, None)),
        }
    }
}

/// What the session's reader tells the broker.
#[derive(Debug)]
pub enum Incoming {
    /// A `can_use_tool` request; `value` is the CLI's `request` object.
    Request {
        tag: String,
        generation: u64,
        cli_request_id: String,
        value: Value,
    },
    /// The CLI withdrew a request.
    Cancel { tag: String, cli_request_id: String },
    /// The session's process is gone.
    Gone {
        tag: String,
        generation: u64,
        reason: String,
    },
}

// ── the broker ────────────────────────────────────────────────────────────────

/// A handle to the daemon's broker. Clones share everything.
#[derive(Clone)]
pub struct ApprovalBroker {
    inner: Arc<Inner>,
}

struct Inner {
    audit: AuditLog,
    parts: BrokerParts,
    state: Mutex<State>,
    tx: Mutex<Option<Sender<Job>>>,
    /// The runtime the timer tasks run on (captured when one is known).
    runtime: Mutex<Option<tokio::runtime::Handle>>,
    /// Where approval frames are broadcast (the daemon's frame channel), once known.
    events: Mutex<Option<broadcast::Sender<ServerMsg>>>,
    /// Bumped whenever a presenter connects or the last one leaves: a grace timer
    /// acts only if nothing changed since it was armed.
    grace_epoch: AtomicU64,
    weak: Weak<Inner>,
}

#[derive(Default)]
struct State {
    sessions: HashMap<String, Registered>,
    pending: HashMap<String, Pending>,
    next_generation: u64,
    /// The daemon is shutting down: whatever arrives now is denied `restart`.
    closing: bool,
    /// tag → tool name of the request that was pending at a crash.
    notes: BTreeMap<String, String>,
    /// How the most recent held requests ended (`request_id → outcome`), so a
    /// late answer is told what happened. Oldest first in `ended_order`.
    ended: HashMap<String, String>,
    ended_order: VecDeque<String>,
}

impl State {
    /// Held requests of `tag` still pending.
    fn held_count(&self, tag: &str) -> u32 {
        self.pending.values().filter(|p| p.held && p.ident.tag == tag).count() as u32
    }

    fn remember_ended(&mut self, request_id: &str, outcome: &str) {
        if self.ended.insert(request_id.to_owned(), outcome.to_owned()).is_none() {
            self.ended_order.push_back(request_id.to_owned());
            while self.ended_order.len() > RECENT_ENDED {
                if let Some(old) = self.ended_order.pop_front() {
                    self.ended.remove(&old);
                }
            }
        }
    }
}

impl State {
    /// The registration of `tag`'s process `generation`, if that process is still the one registered.
    fn session(&self, tag: &str, generation: u64) -> Option<&Registered> {
        self.sessions
            .get(tag)
            .filter(|r| r.generation == generation)
    }

    /// Who a request from `tag`'s process `generation` belongs to.
    fn ident(&self, request_id: &str, tag: &str, generation: u64, value: &Value) -> Ident {
        let session = self.session(tag, generation).map(|r| &r.info);
        Ident {
            request_id: request_id.to_owned(),
            tag: tag.to_owned(),
            session_id: session.and_then(|s| s.session_id.clone()),
            tool_use_id: value
                .get("tool_use_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
            agent: session.map(|s| s.agent.clone()),
            subagent: value
                .get("agent_id")
                .and_then(Value::as_str)
                .map(|id| json!({ "agent_id": id })),
            logged: Arc::new(AtomicBool::new(false)),
        }
    }
}

struct Registered {
    generation: u64,
    info: SessionInfo,
    sink: Arc<dyn SessionSink>,
}

/// A request that has not ended.
struct Pending {
    ident: Ident,
    generation: u64,
    cli_request_id: String,
    arrived: Instant,
    /// Held for a human (a deadline timer is running).
    held: bool,
    /// Aborted when the request ends.
    timers: Timers,
    /// What the CLI sent and when, so an ending that gets there before the worker
    /// can still write the `request` entry (see [`Ident::logged`]).
    raw: Value,
    arrived_at: DateTime<Utc>,
    cwd: Option<PathBuf>,
    /// The tool input as parsed: what an `allow_once` sends back unchanged.
    input: Option<Value>,
    /// What the Mac app was shown (set when the request is held).
    wire: Option<ApprovalRequestWire>,
}

/// Who a request belongs to, for the audit entries.
#[derive(Clone)]
struct Ident {
    request_id: String,
    tag: String,
    session_id: Option<String>,
    tool_use_id: Option<String>,
    agent: Option<String>,
    subagent: Option<Value>,
    /// The `request` entry has been written (by the worker, or by an ending that
    /// came first). Whoever flips it writes the entry, so there is exactly one,
    /// and it precedes the outcome in the file.
    logged: Arc<AtomicBool>,
}

#[derive(Default)]
struct Timers(Vec<AbortHandle>);

impl Drop for Timers {
    fn drop(&mut self) {
        for t in &self.0 {
            t.abort();
        }
    }
}

enum Job {
    Request {
        request_id: String,
        arrived_at: DateTime<Utc>,
        ident: Ident,
        generation: u64,
        value: Value,
    },
    Cancel {
        tag: String,
        cli_request_id: String,
    },
    Gone {
        tag: String,
        generation: u64,
        reason: String,
    },
    Stop,
}

#[derive(Clone, Copy)]
enum Timer {
    /// Not held after [`ARRIVAL_WATCHDOG`]: force-deny.
    Arrival,
    /// A held request reached its deadline: `timed_out`.
    Deadline,
    /// Still not ended [`WATCHDOG_GRACE`] after the deadline: force-deny.
    Final,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl ApprovalBroker {
    /// A broker over the store at `paths`, with the production parts.
    pub fn open(paths: &ApprovalsPaths) -> io::Result<Self> {
        Ok(Self::new(
            AuditLog::open(paths.dir())?,
            BrokerParts::system(),
        ))
    }

    /// A broker over `audit` with the given parts. Spawns its worker thread.
    pub fn new(audit: AuditLog, parts: BrokerParts) -> Self {
        let (tx, rx) = mpsc::channel();
        let notes = read_notes(audit.dir());
        let inner = Arc::new_cyclic(|weak| Inner {
            audit,
            parts,
            state: Mutex::new(State {
                notes,
                ..State::default()
            }),
            tx: Mutex::new(Some(tx)),
            runtime: Mutex::new(tokio::runtime::Handle::try_current().ok()),
            events: Mutex::new(None),
            grace_epoch: AtomicU64::new(0),
            weak: weak.clone(),
        });
        let worker = Arc::downgrade(&inner);
        std::thread::Builder::new()
            .name("approval-broker".into())
            .spawn(move || run_worker(worker, rx))
            .expect("spawn the approval broker thread");
        Self { inner }
    }

    /// The audit store this broker writes.
    pub fn audit(&self) -> &AuditLog {
        &self.inner.audit
    }

    /// A session's process is up and can be answered. Returns its generation:
    /// the number every later call about this process carries, so a request from
    /// an old process can never be answered on a new one.
    pub fn register_session(&self, info: SessionInfo, sink: Arc<dyn SessionSink>) -> u64 {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            *lock(&self.inner.runtime) = Some(handle);
        }
        let mut st = lock(&self.inner.state);
        st.next_generation += 1;
        let generation = st.next_generation;
        st.sessions.insert(
            info.tag.clone(),
            Registered {
                generation,
                info,
                sink,
            },
        );
        generation
    }

    /// Hand a session's frame to the broker without waiting for anything. `Err`
    /// gives the frame back when the broker cannot take it (its worker is gone):
    /// the caller must then answer a request itself.
    #[allow(clippy::result_large_err)] // the rejected frame goes back to the caller
    pub fn submit(&self, incoming: Incoming) -> Result<(), Incoming> {
        match incoming {
            Incoming::Request {
                tag,
                generation,
                cli_request_id,
                value,
            } => {
                let request_id = uuid::Uuid::new_v4().to_string();
                let arrived_at = Utc::now();
                let ident = self.inner.register_request(
                    &request_id,
                    &tag,
                    generation,
                    &cli_request_id,
                    &value,
                    arrived_at,
                );
                let job = Job::Request {
                    request_id: request_id.clone(),
                    arrived_at,
                    ident,
                    generation,
                    value,
                };
                self.inner.send(job).map_err(|job| {
                    // Not taken: forget it (the caller answers), and stop its watchdog.
                    lock(&self.inner.state).pending.remove(&request_id);
                    match job {
                        Job::Request { value, .. } => Incoming::Request {
                            tag,
                            generation,
                            cli_request_id,
                            value,
                        },
                        _ => unreachable!("a request job comes back as a request"),
                    }
                })
            }
            Incoming::Cancel {
                tag,
                cli_request_id,
            } => self
                .inner
                .send(Job::Cancel {
                    tag: tag.clone(),
                    cli_request_id: cli_request_id.clone(),
                })
                .map_err(|_| Incoming::Cancel {
                    tag,
                    cli_request_id,
                }),
            Incoming::Gone {
                tag,
                generation,
                reason,
            } => self
                .inner
                .send(Job::Gone {
                    tag: tag.clone(),
                    generation,
                    reason: reason.clone(),
                })
                .map_err(|_| Incoming::Gone {
                    tag,
                    generation,
                    reason,
                }),
        }
    }

    /// A request the reader had to deny itself because [`Self::submit`] failed:
    /// log it so it is not missing from the record. The `request` entry is written,
    /// then `answer` (the reader's write of the deny), then the `outcome`:
    /// `approval_unavailable`, or `deny_write_failed` if `answer` failed.
    pub fn record_unqueued_denial(
        &self,
        tag: &str,
        generation: u64,
        value: &Value,
        answer: impl FnOnce() -> io::Result<()>,
    ) {
        let request_id = uuid::Uuid::new_v4().to_string();
        let (ident, cwd) = {
            let st = lock(&self.inner.state);
            let cwd = st.session(tag, generation).and_then(|r| r.info.cwd.clone());
            (st.ident(&request_id, tag, generation, value), cwd)
        };
        let parsed = PermissionRequest::from_cli(value);
        self.inner.append(entry(
            request_event(&parsed, value, cwd.as_deref(), &*self.inner.parts.settings),
            &ident,
            Utc::now(),
        ));
        self.inner.answer_and_log(&ident, Ending::unavailable(), answer);
    }

    /// A permission request the reader could not read (nested too deep, too large,
    /// malformed, an id that is not a string) but could identify, and denied itself.
    /// `tool_name` is what the reader could still make out. Logged as `request`, then
    /// `answer`, then `outcome: invalid_request` (or `deny_write_failed`).
    pub fn record_unreadable_denial(
        &self,
        tag: &str,
        generation: u64,
        tool_name: Option<&str>,
        answer: impl FnOnce() -> io::Result<()>,
    ) {
        let request_id = uuid::Uuid::new_v4().to_string();
        let ident = lock(&self.inner.state).ident(&request_id, tag, generation, &Value::Null);
        self.inner.append(entry(
            Event::Request {
                tool_name: tool_name.unwrap_or("unknown").to_owned(),
                input: Value::Null,
                display_text: None,
                reason: Some(json!({
                    "kind": "other",
                    "text": "Unreadable request: too large, nested too deeply or malformed to read",
                })),
                flags: None,
                options: Some(json!([])),
                cli_request: None,
            },
            &ident,
            Utc::now(),
        ));
        self.inner.answer_and_log(
            &ident,
            Ending::deny(Outcome::InvalidRequest, INVALID_REQUEST_MESSAGE),
            answer,
        );
    }

    /// A permission request the reader could not even identify (no request id to
    /// answer under): one `outcome: request_unparseable` entry for the session, with
    /// no request id. Nothing of the line is recorded.
    pub fn record_unparseable(&self, tag: &str, generation: u64) {
        let ident = lock(&self.inner.state).ident("", tag, generation, &Value::Null);
        let mut e = entry(
            Event::Outcome {
                outcome: "request_unparseable".into(),
                rule: None,
                by_window: None,
                latency_ms: None,
                watchdog: false,
            },
            &ident,
            Utc::now(),
        );
        e.request_id = None;
        self.inner.append(e);
    }

    /// The CLI withdrew request `cli_request_id`: `withdrawn`, nothing written.
    pub fn on_cancel(&self, tag: &str, cli_request_id: &str) {
        self.inner.cancel(tag, cli_request_id);
    }

    /// The session's process is gone (stopped, restarted, cleared, exited): every
    /// request of that process still pending ends `cancelled`, with nothing
    /// written, and the sink is forgotten.
    pub fn on_session_gone(&self, tag: &str, generation: u64, reason: &str) {
        self.inner.session_gone(tag, generation, reason);
    }

    /// The daemon is shutting down: deny every pending request `restart` (written
    /// before this returns) and refuse new ones. Returns the `(tag, tool_use_id)`
    /// of each deny that was written, so the caller can wait for the CLI to act on it.
    pub fn deny_all_for_shutdown(&self) -> Vec<(String, String)> {
        let ids: Vec<String> = {
            let mut st = lock(&self.inner.state);
            st.closing = true;
            st.pending.keys().cloned().collect()
        };
        let mut written = Vec::new();
        for id in ids {
            if let Some(done) = self
                .inner
                .finish(&id, Ending::deny(Outcome::Restart, RESTART_MESSAGE))
            {
                if let (true, Some(tool_use_id)) = (done.wrote, done.tool_use_id) {
                    written.push((done.tag, tool_use_id));
                }
            }
        }
        written
    }

    /// At daemon start: every `request` entry without an `outcome` was pending
    /// when the daemon died. Each gets `outcome: restart_crash`, and its focus is
    /// remembered so the agent's next message carries a note
    /// ([`Self::take_restart_note`]). Returns how many were reconciled.
    pub fn startup_reconcile(&self, now: DateTime<Utc>) -> io::Result<usize> {
        let since = now - chrono::Duration::days(super::audit::RETENTION_DAYS + 1);
        let range = since..now + chrono::Duration::days(1);
        // Two passes over the files, each line by line: the log can hold 90 days of
        // entries with full inputs, and only the ids and a few fields are kept.
        let mut ended = std::collections::HashSet::new();
        self.inner.audit.for_each(
            range.clone(),
            &AuditFilter {
                tag: None,
                event: Some("outcome".into()),
            },
            |e| {
                ended.extend(e.request_id);
            },
        )?;
        // Only what the `restart_crash` outcome needs is kept of each unresolved request.
        let mut unresolved: Vec<(Entry, String)> = Vec::new();
        self.inner.audit.for_each(
            range,
            &AuditFilter {
                tag: None,
                event: Some("request".into()),
            },
            |e| {
                let Event::Request { tool_name, .. } = &e.event else {
                    return;
                };
                let Some(request_id) = e.request_id.as_deref().filter(|id| !ended.contains(*id)) else {
                    return;
                };
                let mut outcome = Entry::new(
                    Event::Outcome {
                        outcome: Outcome::RestartCrash.as_str().into(),
                        rule: None,
                        by_window: None,
                        latency_ms: None,
                        watchdog: false,
                    },
                    now,
                );
                outcome.request_id = Some(request_id.to_owned());
                outcome.tag = e.tag.clone();
                outcome.session_id = e.session_id.clone();
                outcome.tool_use_id = e.tool_use_id.clone();
                outcome.agent = e.agent.clone();
                outcome.subagent = e.subagent.clone();
                unresolved.push((outcome, tool_name.clone()));
            },
        )?;
        let mut count = 0;
        let mut notes = Vec::new();
        for (outcome, tool_name) in unresolved {
            if let Err(e) = self.inner.audit.append(&outcome) {
                // Left unresolved: the next start tries again.
                warn!(request_id = ?outcome.request_id, "could not write restart_crash: {e}");
                continue;
            }
            count += 1;
            if let Some(tag) = outcome.tag {
                notes.push((tag, tool_name));
            }
        }
        if !notes.is_empty() {
            let all = {
                let mut st = lock(&self.inner.state);
                for (tag, tool) in notes {
                    st.notes.entry(tag).or_insert(tool);
                }
                st.notes.clone()
            };
            write_notes(self.inner.audit.dir(), &all)?;
        }
        Ok(count)
    }

    /// The note for `tag`, once: the line an agent is told after a crash left
    /// one of its requests pending. `None` if there is none (or it was taken).
    pub fn take_restart_note(&self, tag: &str) -> Option<String> {
        let note = self.peek_restart_note(tag)?;
        self.discard_restart_note(tag);
        Some(note)
    }

    /// [`Self::take_restart_note`] without forgetting it: for a caller that
    /// discards it only once the agent has been told.
    pub fn peek_restart_note(&self, tag: &str) -> Option<String> {
        lock(&self.inner.state)
            .notes
            .get(tag)
            .map(|tool| restart_note_text(tool))
    }

    /// Forget the note for `tag` (the agent has been told).
    pub fn discard_restart_note(&self, tag: &str) {
        let remaining = {
            let mut st = lock(&self.inner.state);
            st.notes.remove(tag).is_some().then(|| st.notes.clone())
        };
        if let Some(Err(e)) = remaining.map(|notes| write_notes(self.inner.audit.dir(), &notes)) {
            warn!(tag, "could not update {RESTART_NOTES_FILE}: {e}");
        }
    }

    /// Delete audit files past retention ([`AuditLog::sweep`]).
    pub fn sweep(&self, now: DateTime<Utc>) -> io::Result<usize> {
        self.inner.audit.sweep(now)
    }

    // ── the app side ─────────────────────────────────────────────────────────

    /// Where the approval frames are broadcast: the daemon's frame channel. The
    /// server connects it when it binds; nothing is broadcast before then.
    pub fn configure_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        *lock(&self.inner.events) = Some(tx);
    }

    /// The connection sets the server keeps current.
    pub fn presenters(&self) -> &ApprovalPresenters {
        &self.inner.parts.presenters
    }

    /// Is a verified Mac app that renders approvals connected?
    pub fn has_approval_presenter(&self) -> bool {
        self.inner.parts.presenters.has_presenter()
    }

    /// Connection `conn` was verified as the Mac app (it may not render approvals).
    pub fn app_connected(&self, conn: &str) {
        self.inner.parts.presenters.add_app(conn);
    }

    /// Connection `conn` (a verified app) renders approvals: held requests can
    /// now be shown. Returns the requests already held, for the connection's
    /// `approvals_snapshot`. Any grace period running for a departed presenter ends.
    pub fn presenter_connected(&self, conn: &str) -> Vec<ApprovalRequestWire> {
        self.inner.parts.presenters.add_presenter(conn);
        self.inner.grace_epoch.fetch_add(1, Ordering::SeqCst);
        self.snapshot()
    }

    /// Connection `conn` is gone. If it was the last presenter, held requests
    /// get [`PRESENTER_GRACE`] for one to reconnect, then are denied `no_app`.
    pub fn app_disconnected(&self, conn: &str) {
        if self.inner.parts.presenters.remove(conn) && !self.has_approval_presenter() {
            self.presenter_lost();
        }
    }

    /// The last presenter left: start the grace period. ([`Self::app_disconnected`]
    /// does this; it is public for a [`Presenter`] that is not [`ApprovalPresenters`].)
    pub fn presenter_lost(&self) {
        self.inner.arm_presenter_grace();
    }

    /// Every request held for a human, oldest first.
    pub fn snapshot(&self) -> Vec<ApprovalRequestWire> {
        let mut wires: Vec<ApprovalRequestWire> = lock(&self.inner.state)
            .pending
            .values()
            .filter(|p| p.held)
            .filter_map(|p| p.wire.clone())
            .collect();
        wires.sort_by_key(|w| w.created_at_ms);
        wires
    }

    /// The human's answer to held request `request_id`, from window `window_id`
    /// of connection `conn_key` (the server has already checked the connection is
    /// the verified app). The first answer ends the request and is the only one
    /// ever written; every later one is told what happened.
    pub fn answer(
        &self,
        request_id: &str,
        decision: &ApprovalDecision,
        window_id: &str,
        conn_key: &str,
    ) -> AnswerResult {
        let input = {
            let st = lock(&self.inner.state);
            match st.pending.get(request_id) {
                Some(p) if p.held => p.input.clone(),
                Some(_) => None,
                None => {
                    return match st.ended.get(request_id) {
                        Some(outcome) => AnswerResult::AlreadyResolved { outcome: outcome.clone() },
                        None => AnswerResult::UnknownRequest,
                    }
                }
            }
        };
        let Some(input) = input else {
            return AnswerResult::UnknownRequest;
        };
        let note = decision.note.as_deref().and_then(clean_note);
        let ending = match decision.kind {
            DecisionKind::AllowOnce => Ending::allow_once(input, window_id),
            DecisionKind::Deny => Ending::denied(note.as_deref(), false, window_id),
            DecisionKind::DenyAndStop => Ending::denied(note.as_deref(), true, window_id),
        };
        match self.inner.finish(request_id, ending) {
            Some(done) => {
                debug!(conn_key, request_id, outcome = done.outcome.as_str(), "approval answered");
                AnswerResult::Applied { outcome: done.outcome.as_str().to_owned() }
            }
            // Another answer (or the timeout, or the app quitting) got there between
            // the look above and the removal.
            None => match lock(&self.inner.state).ended.get(request_id) {
                Some(outcome) => AnswerResult::AlreadyResolved { outcome: outcome.clone() },
                None => AnswerResult::UnknownRequest,
            },
        }
    }

    /// Record in the audit log that an answer (or a report of a refused input) was
    /// not accepted. `peer` is `{trust, pid?, exe?}`.
    pub fn record_refusal(
        &self,
        request_id: Option<&str>,
        code: &str,
        peer: Value,
        channel: Option<RefusalChannel>,
        control: Option<&str>,
    ) {
        let mut e = Entry::new(
            Event::Refusal {
                refusal_code: code.to_owned(),
                peer: Some(peer),
                channel: channel.map(|c| c.as_str().to_owned()),
                control: control.map(sanitize_string),
            },
            Utc::now(),
        );
        e.request_id = request_id.map(sanitize_string);
        self.inner.append(e);
    }

    /// Stop the worker thread, as if it had died: later [`Self::submit`] calls
    /// fail. For tests of the fail-safe.
    #[doc(hidden)]
    pub fn stop_worker_for_test(&self) {
        let _ = self.inner.send(Job::Stop);
        lock(&self.inner.tx).take();
    }
}

impl Inner {
    // `Err` hands the unsent job back; it is large, and this is not a hot path.
    #[allow(clippy::result_large_err)]
    fn send(&self, job: Job) -> Result<(), Job> {
        match lock(&self.tx).as_ref() {
            Some(tx) => tx.send(job).map_err(|e| e.0),
            None => Err(job),
        }
    }

    /// Record a request the moment it arrives, so a watchdog covers it even if
    /// the worker never gets to it.
    fn register_request(
        &self,
        request_id: &str,
        tag: &str,
        generation: u64,
        cli_request_id: &str,
        value: &Value,
        arrived_at: DateTime<Utc>,
    ) -> Ident {
        let mut st = lock(&self.state);
        let ident = st.ident(request_id, tag, generation, value);
        let cwd = st.session(tag, generation).and_then(|r| r.info.cwd.clone());
        let mut timers = Timers::default();
        timers
            .0
            .extend(self.arm(request_id, ARRIVAL_WATCHDOG, Timer::Arrival));
        st.pending.insert(
            request_id.to_owned(),
            Pending {
                ident: ident.clone(),
                generation,
                cli_request_id: cli_request_id.to_owned(),
                arrived: Instant::now(),
                held: false,
                timers,
                raw: value.clone(),
                arrived_at,
                cwd,
                input: None,
                wire: None,
            },
        );
        ident
    }

    /// Start a timer task that, after `after`, ends or checks request `request_id`.
    /// The work runs on the blocking pool: it writes to disk and to a pipe.
    fn arm(&self, request_id: &str, after: Duration, timer: Timer) -> Option<AbortHandle> {
        let runtime = lock(&self.runtime).clone()?;
        let weak = self.weak.clone();
        let request_id = request_id.to_owned();
        let task = runtime.spawn(async move {
            tokio::time::sleep(after).await;
            let Some(inner) = weak.upgrade() else { return };
            let _ = tokio::task::spawn_blocking(move || inner.on_timer(&request_id, timer)).await;
        });
        Some(task.abort_handle())
    }

    fn on_timer(&self, request_id: &str, timer: Timer) {
        let held = lock(&self.state).pending.get(request_id).map(|p| p.held);
        let Some(held) = held else { return };
        match timer {
            Timer::Arrival if held => {}
            Timer::Arrival | Timer::Final => {
                warn!(
                    request_id,
                    "approval watchdog: request still unresolved, denying it"
                );
                self.finish(request_id, Ending::watchdog());
            }
            Timer::Deadline => {
                self.finish(
                    request_id,
                    Ending::deny(Outcome::TimedOut, TIMED_OUT_MESSAGE),
                );
            }
        }
    }

    /// End a request: answer it (if the ending says to, and the session can still
    /// hear), then log the outcome. `None` if it had already ended.
    fn finish(&self, request_id: &str, ending: Ending) -> Option<Finished> {
        let (pending, sink, held_after) = {
            let mut st = lock(&self.state);
            let pending = st.pending.remove(request_id)?;
            // In the same critical section as the removal, so a second answer
            // that arrives while this one is being written is told what won.
            if pending.held {
                st.remember_ended(request_id, ending.outcome.as_str());
            }
            let held_after = st.held_count(&pending.ident.tag);
            let sink = st
                .session(&pending.ident.tag, pending.generation)
                .map(|r| Arc::clone(&r.sink));
            (pending, sink, held_after)
        };
        let mut ending = ending;
        let mut outcome = ending.outcome;
        let mut wrote = false;
        if let Some(body) = ending.response() {
            match sink.filter(|s| s.live()) {
                Some(sink) => match sink.respond(&pending.cli_request_id, &body) {
                    Ok(()) => wrote = true,
                    Err(e) => {
                        warn!(tag = %pending.ident.tag, "could not write the answer: {e}");
                        ending = ending.write_failed();
                        outcome = ending.outcome;
                    }
                },
                // The process is gone: say so, and write nothing.
                None => outcome = Outcome::Cancelled,
            }
        }
        if pending.held && outcome != ending.outcome {
            lock(&self.state).remember_ended(request_id, outcome.as_str());
        }
        // The worker may not have got to this request (it is stuck, or still queued):
        // the record must not hold an outcome without its request.
        self.log_request_once(
            &pending.ident,
            pending.arrived_at,
            &pending.raw,
            pending.cwd.as_deref(),
        );
        let latency_ms = pending.arrived.elapsed().as_millis() as u64;
        let entry_id = self.log_outcome(&pending.ident, outcome, &ending, latency_ms);
        if pending.held {
            self.broadcast(ServerMsg::ApprovalResolved {
                tag: pending.ident.tag.clone(),
                request_id: request_id.to_owned(),
                outcome: outcome.as_str().to_owned(),
                by_window: ending.by_window.clone(),
                at_ms: now_ms(),
            });
            self.broadcast(ServerMsg::ApprovalPending {
                tag: pending.ident.tag.clone(),
                count: held_after,
            });
        }
        Some(Finished {
            tag: pending.ident.tag.clone(),
            tool_use_id: pending.ident.tool_use_id.clone(),
            wrote,
            outcome,
            entry_id,
        })
    }

    /// Broadcast an approval frame, if the daemon's channel is known (nobody
    /// listening is not an error).
    fn broadcast(&self, msg: ServerMsg) {
        if let Some(tx) = lock(&self.events).as_ref() {
            let _ = tx.send(msg);
        }
    }

    /// Write the `request` entry unless it has been written.
    fn log_request_once(
        &self,
        ident: &Ident,
        arrived_at: DateTime<Utc>,
        raw: &Value,
        cwd: Option<&Path>,
    ) {
        if ident.logged.swap(true, Ordering::SeqCst) {
            return;
        }
        let parsed = PermissionRequest::from_cli(raw);
        self.append(entry(
            request_event(&parsed, raw, cwd, &*self.parts.settings),
            ident,
            arrived_at,
        ));
    }

    /// Run `answer` (the caller's write of the deny for `ending`), then log the outcome:
    /// `ending`'s, or `deny_write_failed` if the write failed.
    fn answer_and_log(&self, ident: &Ident, ending: Ending, answer: impl FnOnce() -> io::Result<()>) {
        let ending = match answer() {
            Ok(()) => ending,
            Err(e) => {
                warn!(tag = %ident.tag, "could not write the deny: {e}");
                ending.write_failed()
            }
        };
        self.log_outcome(ident, ending.outcome, &ending, 0);
    }

    /// Write the `outcome` entry; returns its id.
    fn log_outcome(&self, ident: &Ident, outcome: Outcome, ending: &Ending, latency_ms: u64) -> String {
        let event = Event::Outcome {
            outcome: outcome.as_str().into(),
            rule: ending.rule.clone(),
            by_window: ending.by_window.clone(),
            latency_ms: Some(latency_ms),
            watchdog: ending.watchdog,
        };
        let entry = entry(event, ident, Utc::now());
        let id = entry.id.clone();
        self.append(entry);
        id
    }

    /// Append an audit entry. A failure is logged, never a reason to skip the answer.
    fn append(&self, entry: Entry) {
        if let Err(e) = self.audit.append(&entry) {
            error!(
                event = entry.event.kind(),
                "approval audit write failed: {e}"
            );
        }
    }

    fn cancel(&self, tag: &str, cli_request_id: &str) {
        let id = {
            let st = lock(&self.state);
            st.pending
                .iter()
                .find(|(_, p)| p.ident.tag == tag && p.cli_request_id == cli_request_id)
                .map(|(id, _)| id.clone())
        };
        if let Some(id) = id {
            self.finish(&id, Ending::silent(Outcome::Withdrawn));
        }
    }

    fn session_gone(&self, tag: &str, generation: u64, reason: &str) {
        let ids: Vec<String> = {
            let mut st = lock(&self.state);
            if st.session(tag, generation).is_some() {
                st.sessions.remove(tag);
            }
            st.pending
                .iter()
                .filter(|(_, p)| p.ident.tag == tag && p.generation == generation)
                .map(|(id, _)| id.clone())
                .collect()
        };
        debug!(
            tag,
            generation,
            reason,
            pending = ids.len(),
            "approval session gone"
        );
        for id in ids {
            self.finish(&id, Ending::silent(Outcome::Cancelled));
        }
    }

    fn handle(&self, job: Job) {
        match job {
            Job::Request {
                request_id,
                arrived_at,
                ident,
                generation,
                value,
            } => self.process(&request_id, arrived_at, &ident, generation, &value),
            Job::Cancel {
                tag,
                cli_request_id,
            } => self.cancel(&tag, &cli_request_id),
            Job::Gone {
                tag,
                generation,
                reason,
            } => self.session_gone(&tag, generation, &reason),
            Job::Stop => {}
        }
    }

    /// Parse, log, guard, then hold or deny one request.
    fn process(
        &self,
        request_id: &str,
        arrived_at: DateTime<Utc>,
        ident: &Ident,
        generation: u64,
        value: &Value,
    ) {
        let epoch_at_check = self.grace_epoch.load(Ordering::SeqCst);
        let session = {
            let st = lock(&self.state);
            st.session(&ident.tag, generation).map(|r| r.info.clone())
        };
        let cwd = session.as_ref().and_then(|s| s.cwd.clone());
        let session_gone = session.is_none();
        self.log_request_once(ident, arrived_at, value, cwd.as_deref());
        if !lock(&self.state).pending.contains_key(request_id) {
            return; // it ended while it waited for the worker
        }
        let parsed = PermissionRequest::from_cli(value);
        if session_gone {
            // The process that asked is not the one registered (or none is): there
            // is nobody to answer, and nobody to ask about a process that is gone.
            self.finish(request_id, Ending::silent(Outcome::Cancelled));
            return;
        }
        let req = match parsed {
            Ok(req) => req,
            Err(e) => {
                warn!(tag = %ident.tag, "unreadable permission request: {e}");
                self.finish(
                    request_id,
                    Ending::deny(Outcome::InvalidRequest, INVALID_REQUEST_MESSAGE),
                );
                return;
            }
        };
        if lock(&self.state).closing {
            self.finish(request_id, Ending::deny(Outcome::Restart, RESTART_MESSAGE));
            return;
        }
        // The guard first: no rule, mode or answer is consulted before it.
        let payload = HookPayload {
            tool_name: req.tool_name.clone(),
            tool_input: req.input.clone(),
            session_id: ident.session_id.clone(),
            tool_use_id: Some(req.tool_use_id.clone()),
            permission_mode: None,
            cwd: cwd.as_ref().map(|c| c.to_string_lossy().into_owned()),
            hook_event_name: None,
        };
        let probe = (self.parts.probe)();
        let blocked = match guard::evaluate(&payload, &*probe) {
            Ok(GuardVerdict::Block { rule_id, detail }) => {
                Some(Ending::guard(guard::GUARD_MESSAGE, rule_id, &detail))
            }
            Ok(GuardVerdict::Allow) => None,
            // The guard could not decide: fail closed, like the hook does.
            Err(e) => Some(Ending::guard(
                guard::FAIL_CLOSED_MESSAGE,
                "guard_error",
                &e.to_string(),
            )),
        };
        if let Some(ending) = blocked {
            if let Some(done) = self.finish(request_id, ending) {
                self.broadcast(ServerMsg::ApprovalGuardBlocked {
                    tag: ident.tag.clone(),
                    tool_use_id: req.tool_use_id.clone(),
                    entry_id: done.entry_id,
                    at_ms: now_ms(),
                    summary: guard_summary(&req),
                });
            }
            return;
        }
        // The ordering rule, in code: a request is held for a human only if the
        // session carries the guard hook *and* someone who can answer is there.
        let guarded = session.as_ref().is_some_and(|s| s.guarded);
        if guarded && self.parts.presenter.can_present(&ident.tag) {
            let wire = approval_wire(
                request_id,
                &ident.tag,
                session.as_ref().map(|s| s.agent.as_str()).unwrap_or_default(),
                &req,
                cwd.as_deref(),
                &*self.parts.settings,
                self.parts.timeout,
            );
            self.hold(request_id, wire, req.input.clone(), epoch_at_check);
        } else {
            self.finish(
                request_id,
                Ending::cannot_ask(guarded, self.parts.presenter.app_connected()),
            );
        }
    }

    /// Keep the request until its deadline (or until something else ends it), and
    /// show it to the presenters. `epoch_at_check`: the presenter epoch when the
    /// presenter was asked; a change since means one came or went in between.
    fn hold(&self, request_id: &str, wire: ApprovalRequestWire, input: Value, epoch_at_check: u64) {
        let tag = wire.tag.clone();
        let mut st = lock(&self.state);
        let Some(p) = st.pending.get_mut(request_id) else {
            return;
        };
        p.held = true;
        p.input = Some(input);
        p.wire = Some(wire.clone());
        // The arrival watchdog is replaced by the deadline and its watchdog. (Both
        // need the tokio runtime the daemon always has; see the module docs.)
        p.timers = Timers::default();
        p.timers
            .0
            .extend(self.arm(request_id, self.parts.timeout, Timer::Deadline));
        p.timers.0.extend(self.arm(
            request_id,
            self.parts.timeout + WATCHDOG_GRACE,
            Timer::Final,
        ));
        let count = st.held_count(&tag);
        drop(st);
        self.broadcast(ServerMsg::ApprovalRequest { tag: tag.clone(), request: wire });
        self.broadcast(ServerMsg::ApprovalPending { tag, count });
        if self.grace_epoch.load(Ordering::SeqCst) != epoch_at_check {
            // The presenter set changed while this request was being prepared:
            // have it checked again, so a request held just after the last
            // presenter left is not stranded.
            self.arm_presenter_grace();
        }
    }

    /// Start a grace period: if nobody has connected by its end, every held
    /// request that nobody can be asked about is denied.
    fn arm_presenter_grace(&self) {
        let epoch = self.grace_epoch.fetch_add(1, Ordering::SeqCst) + 1;
        let Some(runtime) = lock(&self.runtime).clone() else { return };
        let weak = self.weak.clone();
        runtime.spawn(async move {
            tokio::time::sleep(PRESENTER_GRACE).await;
            let Some(inner) = weak.upgrade() else { return };
            let _ = tokio::task::spawn_blocking(move || inner.on_presenter_grace(epoch)).await;
        });
    }

    fn on_presenter_grace(&self, epoch: u64) {
        if self.grace_epoch.load(Ordering::SeqCst) != epoch {
            return; // someone connected (or left again): a newer grace period decides
        }
        let held: Vec<(String, String)> = lock(&self.state)
            .pending
            .iter()
            .filter(|(_, p)| p.held)
            .map(|(id, p)| (id.clone(), p.ident.tag.clone()))
            .collect();
        for (id, tag) in held {
            if !self.parts.presenter.can_present(&tag) {
                self.finish(&id, Ending::cannot_ask(true, self.parts.presenter.app_connected()));
            }
        }
    }
}

/// What [`Inner::finish`] did.
struct Finished {
    tag: String,
    tool_use_id: Option<String>,
    /// An answer (deny, or the human's allow) was written to the session.
    wrote: bool,
    /// How it ended, as logged.
    outcome: Outcome,
    /// The id of the `outcome` entry.
    entry_id: String,
}

fn now_ms() -> u64 {
    Utc::now().timestamp_millis().max(0) as u64
}

/// What the Mac app is shown of a held request.
fn approval_wire(
    request_id: &str,
    tag: &str,
    agent: &str,
    req: &PermissionRequest,
    cwd: Option<&Path>,
    settings: &dyn SettingsSource,
    timeout: Duration,
) -> ApprovalRequestWire {
    let created_at_ms = now_ms();
    ApprovalRequestWire {
        request_id: request_id.to_owned(),
        tag: tag.to_owned(),
        tool_use_id: req.tool_use_id.clone(),
        agent: AgentWire {
            name: agent.to_owned(),
            subagent: req
                .agent_id
                .as_ref()
                .map(|id| SubagentWire { agent_id: id.clone(), agent_type: None }),
        },
        tool_name: req.tool_name.clone(),
        display_name: req.display_name.clone().unwrap_or_else(|| req.tool_name.clone()),
        tool_kind: req.tool_kind,
        mcp: req.mcp.clone(),
        input: req.input.clone(),
        display: ApprovalDisplay::build(req.tool_kind, &req.input),
        cwd: cwd.map(|c| c.to_string_lossy().into_owned()),
        reason: req.reason(cwd, settings),
        flags: ApprovalFlags {
            default_to_no: req.default_to_no.unwrap_or(false),
            suppress_always_allow_rule: req.suppress_always_allow_rule.unwrap_or(false),
            requires_user_interaction: req.requires_user_interaction.unwrap_or(false),
            classifier_approvable: req.classifier_approvable.unwrap_or(false),
        },
        description: req.description.clone(),
        options: ApprovalOption::ALL.to_vec(),
        session_rule_candidates: Vec::new(),
        created_at_ms,
        deadline_at_ms: created_at_ms + timeout.as_millis() as u64,
    }
}

/// The guard bar's one line: the tool name, and for Bash the first command word.
/// Never more (the full command stays in the audit log).
fn guard_summary(req: &PermissionRequest) -> String {
    let first_word = (req.tool_kind == super::request::ToolKind::Bash)
        .then(|| req.input.get("command").and_then(Value::as_str))
        .flatten()
        .and_then(|c| c.split_whitespace().next())
        .map(|w| w.chars().filter(|c| !is_invisible(*c)).take(64).collect::<String>())
        .filter(|w| !w.is_empty());
    let name: String = req.tool_name.chars().filter(|c| !is_invisible(*c)).take(64).collect();
    match first_word {
        Some(w) => format!("{name} {w}"),
        None => name,
    }
}

fn entry(event: Event, ident: &Ident, ts: DateTime<Utc>) -> Entry {
    let mut e = Entry::new(event, ts);
    e.request_id = Some(ident.request_id.clone());
    e.tag = Some(ident.tag.clone());
    e.session_id = ident.session_id.clone();
    e.tool_use_id = ident.tool_use_id.clone();
    e.agent = ident.agent.clone();
    e.subagent = ident.subagent.clone();
    e
}

/// The `request` audit event: the typed view, plus the request exactly as received.
fn request_event(
    parsed: &Result<PermissionRequest, super::request::RequestError>,
    raw: &Value,
    cwd: Option<&Path>,
    settings: &dyn SettingsSource,
) -> Event {
    match parsed {
        Ok(req) => {
            let display = ApprovalDisplay::build(req.tool_kind, &req.input);
            Event::Request {
                tool_name: req.tool_name.clone(),
                input: req.input.clone(),
                display_text: Some(sanitize_string(&display.shown_text())),
                reason: serde_json::to_value(req.reason(cwd, settings)).ok(),
                flags: Some(json!({
                    "default_to_no": req.default_to_no.unwrap_or(false),
                    "suppress_always_allow_rule": req.suppress_always_allow_rule.unwrap_or(false),
                    "requires_user_interaction": req.requires_user_interaction.unwrap_or(false),
                    "classifier_approvable": req.classifier_approvable.unwrap_or(false),
                })),
                options: Some(json!([])),
                cli_request: Some(without_input(raw)),
            }
        }
        Err(e) => Event::Request {
            tool_name: raw
                .get("tool_name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned(),
            input: raw.get("input").cloned().unwrap_or(Value::Null),
            display_text: None,
            reason: Some(json!({ "kind": "other", "text": format!("Unreadable request: {e}") })),
            flags: None,
            options: Some(json!([])),
            cli_request: Some(without_input(raw)),
        },
    }
}

/// The CLI's request as the log keeps it in `cli_request`: every field but `input`,
/// which the entry records in full in its own `input`.
fn without_input(raw: &Value) -> Value {
    match raw.as_object() {
        Some(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| k.as_str() != "input")
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        ),
        None => raw.clone(),
    }
}

fn run_worker(inner: Weak<Inner>, rx: Receiver<Job>) {
    while let Ok(job) = rx.recv() {
        if matches!(job, Job::Stop) {
            break;
        }
        let Some(inner) = inner.upgrade() else { break };
        let request_id = match &job {
            Job::Request { request_id, .. } => Some(request_id.clone()),
            _ => None,
        };
        if std::panic::catch_unwind(AssertUnwindSafe(|| inner.handle(job))).is_err() {
            error!("approval broker: handling a request panicked; denying it");
            if let Some(id) = request_id {
                inner.finish(&id, Ending::unavailable());
            }
        }
    }
    info!("approval broker worker stopped");
}

// ── restart notes ─────────────────────────────────────────────────────────────

fn read_notes(dir: &Path) -> BTreeMap<String, String> {
    std::fs::read_to_string(dir.join(RESTART_NOTES_FILE))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write_notes(dir: &Path, notes: &BTreeMap<String, String>) -> io::Result<()> {
    use std::io::Write;
    let path = dir.join(RESTART_NOTES_FILE);
    if notes.is_empty() {
        return match std::fs::remove_file(&path) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
    }
    let tmp = dir.join(format!("{RESTART_NOTES_FILE}.tmp"));
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)?;
    file.write_all(
        serde_json::to_string(notes)
            .map_err(io::Error::other)?
            .as_bytes(),
    )?;
    file.sync_data()?;
    std::fs::rename(tmp, path)
}
