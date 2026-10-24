//! A session whose Claude login expired: watching for the credential to change,
//! and telling the Mac which sessions are waiting.
//!
//! The session manager holds a failed message and pauses the session's queue
//! (`session_manager/login.rs`); this module is the rest:
//!
//! * [`CredentialWatch`]: "did the Claude credential change?", answered by a
//!   *stamp*, never by the secret. Production ([`KeychainItemDate`]) asks the
//!   macOS `security` tool for the attributes of the Keychain item and keeps only
//!   its modification date; every other byte of its output is dropped at once.
//! * [`LoginCoordinator`]: tells every client the whole picture
//!   (`ServerMsg::ClaudeLoginState`, REPLACE semantics) whenever it changes, and
//!   polls the watch every [`POLL_INTERVAL`] **only while a hold exists**.
//!
//! No log line, message or file written here carries message text, error text, a
//! stamp or `security` output.

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, Notify};
use tracing::warn;

use super::protocol::{ClaudeLoginWatch, ServerMsg};
use super::session_manager::SessionManager;

/// Most messages queued behind a held one. Send number 21 is refused with
/// `waiting_for_sign_in: queue full`.
pub const LOGIN_QUEUE_CAP: usize = 20;

/// A held message older than this is sent again only by a human, so it cannot
/// surprise anyone hours later.
pub const AUTO_RESEND_TTL: Duration = Duration::from_secs(60 * 60);

/// Most times the daemon sends one held message again without being asked.
pub const MAX_AUTO_RESENDS: u8 = 3;

/// How often the credential is looked at while a hold exists.
pub const POLL_INTERVAL: Duration = Duration::from_secs(5);

// ── the credential watch ───────────────────────────────────────────────────────

/// What a [`CredentialWatch`] saw. Two stamps are equal exactly when the
/// credential did not change; the stamp says nothing else.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialStamp {
    Stamp(String),
    /// It could not be looked at (no such tool, no such item, a timeout).
    Unavailable,
}

/// Looks at the Claude credential without ever reading it.
pub trait CredentialWatch: Send + Sync {
    /// The credential's current stamp. May block (production runs a process), so
    /// callers on an async task run it on a blocking thread.
    fn stamp(&self) -> CredentialStamp;
}

/// The only program the production watch runs.
pub const SECURITY_PROGRAM: &str = "/usr/bin/security";

/// Its exact arguments: the attributes of the generic-password item Claude Code
/// stores its login in. Never `-g`, `-w` or `-a`, and never a dump: those are what
/// would print the secret (or the account), and a test pins it.
pub const SECURITY_ARGS: &[&str] = &["find-generic-password", "-s", "Claude Code-credentials"];

/// How long the probe may take before the watch calls itself unavailable.
const SECURITY_TIMEOUT: Duration = Duration::from_secs(5);

/// The attributes listing is a few hundred bytes; read no more than this.
const SECURITY_OUTPUT_LIMIT: u64 = 64 * 1024;

/// The production watch: the modification date of the Keychain item.
pub struct KeychainItemDate;

impl CredentialWatch for KeychainItemDate {
    fn stamp(&self) -> CredentialStamp {
        match run_security() {
            Some(stamp) => CredentialStamp::Stamp(stamp),
            None => CredentialStamp::Unavailable,
        }
    }
}

/// Run the probe and keep only the item's modification date. Stderr goes to
/// null; the stdout buffer is dropped as soon as it has been parsed.
fn run_security() -> Option<String> {
    let mut child = Command::new(SECURITY_PROGRAM)
        .args(SECURITY_ARGS)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    // Read on a thread of its own so a probe that hangs with its output pipe
    // open cannot hold this one past the timeout.
    let reader = std::thread::spawn(move || {
        let mut buf = String::new();
        let _ = stdout.take(SECURITY_OUTPUT_LIMIT).read_to_string(&mut buf);
        buf
    });
    let deadline = Instant::now() + SECURITY_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let output = reader.join().ok()?;
    if !status.success() {
        return None;
    }
    parse_mdat(&output)
}

/// The value of the `"mdat"<timedate>=` line of `security find-generic-password`
/// output (`"20261018200418Z\000"` becomes `20261018200418Z`). Every other line,
/// the `"acct"` and `"svce"` attributes included, is ignored.
pub fn parse_mdat(stdout: &str) -> Option<String> {
    const KEY: &str = "\"mdat\"<timedate>=";
    let line = stdout.lines().map(str::trim).find(|l| l.starts_with(KEY))?;
    let after = &line[KEY.len()..];
    let quoted = &after[after.find('"')? + 1..];
    let value = &quoted[..quoted.find('"')?];
    let value = value.trim_end_matches("\\000");
    (!value.is_empty()).then(|| value.to_owned())
}

// ── the coordinator ────────────────────────────────────────────────────────────

/// Publishes `ClaudeLoginState` and polls the credential while a hold exists.
///
/// The session manager owns the holds; the coordinator reads them through the
/// manager (a `Weak`, so neither keeps the other alive). A reader thread that
/// changes a hold only calls [`LoginCoordinator::changed`], which never blocks and
/// never takes the manager's lock: the picture is built, and sent, on a task.
pub struct LoginCoordinator {
    watch: Arc<dyn CredentialWatch>,
    tx: Mutex<Option<broadcast::Sender<ServerMsg>>>,
    attached: Mutex<Option<Attached>>,
    /// Wakes the publisher task.
    dirty: Arc<Notify>,
    /// The last frame sent, as JSON: an identical one is not sent again.
    last_sent: Mutex<Option<String>>,
    polling: AtomicBool,
    /// Whether the last look at the credential worked.
    watch_works: AtomicBool,
    warned_unavailable: AtomicBool,
}

struct Attached {
    manager: Weak<Mutex<SessionManager>>,
    runtime: tokio::runtime::Handle,
}

impl LoginCoordinator {
    pub fn new(watch: Arc<dyn CredentialWatch>) -> Arc<Self> {
        Arc::new(Self {
            watch,
            tx: Mutex::new(None),
            attached: Mutex::new(None),
            dirty: Arc::new(Notify::new()),
            last_sent: Mutex::new(None),
            polling: AtomicBool::new(false),
            watch_works: AtomicBool::new(true),
            warned_unavailable: AtomicBool::new(false),
        })
    }

    /// Where `ClaudeLoginState` frames are sent (the server's broadcast channel).
    pub fn configure_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        *self.tx.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
    }

    /// Wire the manager and the coordinator to each other and start the
    /// publisher. Call inside the tokio runtime, before sessions are spawned.
    pub fn attach(self: &Arc<Self>, manager: &Arc<Mutex<SessionManager>>) {
        *self.attached.lock().unwrap_or_else(|e| e.into_inner()) = Some(Attached {
            manager: Arc::downgrade(manager),
            runtime: tokio::runtime::Handle::current(),
        });
        manager.lock().unwrap_or_else(|e| e.into_inner()).configure_login(Arc::clone(self));
        let weak = Arc::downgrade(self);
        let dirty = Arc::clone(&self.dirty);
        tokio::spawn(async move {
            loop {
                dirty.notified().await;
                let Some(coordinator) = weak.upgrade() else { return };
                coordinator.publish();
            }
        });
    }

    /// A hold (or a queue behind one) changed. Cheap and non-blocking: callable
    /// from a reader thread, or with the manager's lock held.
    pub fn changed(&self) {
        self.dirty.notify_one();
    }

    /// Send the current picture again even if it is the one last sent: a human's
    /// action changed nothing, and whoever acted learns where things stand.
    pub fn rebroadcast(&self) {
        *self.last_sent.lock().unwrap_or_else(|e| e.into_inner()) = None;
        self.changed();
    }

    /// The credential's stamp now. Blocks while the watch runs.
    pub fn stamp_now(&self) -> CredentialStamp {
        let stamp = self.watch.stamp();
        self.observe(&stamp);
        stamp
    }

    /// Remember whether the watch could see the credential this time. Said once
    /// (in the log) when it cannot, and told to clients whenever it flips.
    fn observe(&self, stamp: &CredentialStamp) {
        let works = matches!(stamp, CredentialStamp::Stamp(_));
        let was_working = self.watch_works.swap(works, Ordering::SeqCst);
        if !works && !self.warned_unavailable.swap(true, Ordering::SeqCst) {
            warn!("credential watch unavailable");
        }
        if works != was_working {
            self.changed();
        }
    }

    /// What the frame's `watch` says.
    pub fn watch_state(&self) -> ClaudeLoginWatch {
        if self.watch_works.load(Ordering::SeqCst) {
            ClaudeLoginWatch::Keychain
        } else {
            ClaudeLoginWatch::Unavailable
        }
    }

    fn manager(&self) -> Option<Arc<Mutex<SessionManager>>> {
        self.attached.lock().unwrap_or_else(|e| e.into_inner()).as_ref()?.manager.upgrade()
    }

    /// Build the picture and send it unless it is the one already sent. Starts
    /// the poller when someone is waiting.
    fn publish(self: &Arc<Self>) {
        let Some(manager) = self.manager() else { return };
        let snapshot = manager.lock().unwrap_or_else(|e| e.into_inner()).login_snapshot();
        let waiting = matches!(&snapshot, ServerMsg::ClaudeLoginState { needs_login: true, .. });
        let json = serde_json::to_string(&snapshot).unwrap_or_default();
        if let Some(tx) = self.tx.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let mut last = self.last_sent.lock().unwrap_or_else(|e| e.into_inner());
            if last.as_deref() != Some(json.as_str()) {
                *last = Some(json);
                let _ = tx.send(snapshot);
            }
        }
        if waiting {
            self.ensure_poller();
        }
    }

    /// Start the poller unless it runs. It stops itself when no hold is left.
    fn ensure_poller(self: &Arc<Self>) {
        if self.polling.swap(true, Ordering::SeqCst) {
            return;
        }
        let runtime = {
            let attached = self.attached.lock().unwrap_or_else(|e| e.into_inner());
            match attached.as_ref() {
                Some(a) => a.runtime.clone(),
                None => {
                    self.polling.store(false, Ordering::SeqCst);
                    return;
                }
            }
        };
        let weak = Arc::downgrade(self);
        runtime.spawn(async move {
            loop {
                tokio::time::sleep(POLL_INTERVAL).await;
                let Some(coordinator) = weak.upgrade() else { return };
                if coordinator.poll_once().await {
                    continue;
                }
                // Nothing is held. Say so, then look once more: a hold made in
                // the gap must not be left without a poller.
                coordinator.polling.store(false, Ordering::SeqCst);
                if coordinator.any_hold() && !coordinator.polling.swap(true, Ordering::SeqCst) {
                    continue;
                }
                return;
            }
        });
    }

    fn any_hold(&self) -> bool {
        match self.manager() {
            Some(manager) => manager.lock().unwrap_or_else(|e| e.into_inner()).has_login_hold(),
            None => false,
        }
    }

    /// One look at the credential. False when nothing is held (the credential
    /// is then not looked at).
    async fn poll_once(&self) -> bool {
        if !self.any_hold() {
            return false;
        }
        let watch = Arc::clone(&self.watch);
        let stamp = tokio::task::spawn_blocking(move || watch.stamp())
            .await
            .unwrap_or(CredentialStamp::Unavailable);
        self.observe(&stamp);
        if let (CredentialStamp::Stamp(current), Some(manager)) = (stamp, self.manager()) {
            manager.lock().unwrap_or_else(|e| e.into_inner()).on_credential_stamp(&current);
        }
        true
    }
}
