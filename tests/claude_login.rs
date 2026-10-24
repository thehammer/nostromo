//! An expired Claude login, end to end through real `SessionManager` sessions (CL1).
//!
//! The session is the hermetic fake `claude` of `tests/support/fake_claude_perm.py` in its
//! auth mode (`FAKE_CLAUDE_AUTH_FILE`: `expired` makes every turn fail the way Claude Code
//! 2.1.301 does), started through a `/bin/sh` wrapper so the manager launches it exactly as it
//! launches `claude`. The credential watch is a fake: nothing here ever runs the system's
//! keychain tool or touches the Keychain.
//!
//! What this pins, from outside the daemon:
//! - a failed turn whose message the daemon wrote is held, the session is paused (later
//!   messages queue in order, nothing else is written) and a content-free
//!   `ClaudeLoginState` says so;
//! - the held message is written again exactly once, automatically when the credential
//!   stamp changes or on a manual retry, and the queue then drains in order;
//! - nothing is ever sent twice (racing triggers, an old `hold_id`, a restart);
//! - what is not resendable (the turn did real work), too old, or beyond the attempt cap is
//!   only ever resent by hand;
//! - the poller runs only while a hold exists, and a stopped or given-up session holds nothing;
//! - Stop on a session waiting for a sign-in discards the hold and the queue behind it;
//! - the credential probe never runs on a session's stdout reader;
//! - a resend that was written is never written again on its own after a crash or restart;
//! - no message text, error text or stamp reaches a log line, a broadcast frame or a file.
//!
//! Environment variables are process-wide and tests run on parallel threads, so every test
//! takes `ENV_LOCK` for its whole duration and builds its own paused-clock runtime. The
//! daemon's session reader is a blocking thread, so the paused clock does not advance by
//! itself while a session lives: the 5 s poller is driven with `tokio::time::advance`, and
//! every wait polls in real time with a bound.
//!
//! Not covered here: "a turn that was not started by a message the daemon wrote is not
//! resendable". The fake only answers messages written to its stdin (the daemon wrote them
//! all), so the case cannot be produced without a new cue in the fake.

use std::fmt::Write as _;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use nostromo::ipc::claude_login::{
    parse_mdat, CredentialStamp, CredentialWatch, LoginCoordinator, AUTO_RESEND_TTL, LOGIN_QUEUE_CAP,
    MAX_AUTO_RESENDS, POLL_INTERVAL, SECURITY_ARGS, SECURITY_PROGRAM,
};
use nostromo::ipc::protocol::{ClaudeLoginPhase, ClaudeLoginSession, ClaudeLoginWatch, ServerMsg};
use nostromo::ipc::session_manager::{
    InterruptOutcome, ResendOutcome, ResendTrigger, SessionManager, CLAUDE_BIN_ENV,
};
use nostromo::ipc::stream_json::SessionState;
use serde_json::Value;
use tokio::sync::broadcast;
use tracing_subscriber::layer::{Context, SubscriberExt};

const FAKE_CLI: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/support/fake_claude_perm.py");
const AUTH_PHRASE: &str = "OAuth session expired";

// ── log capture (every event, every field; global because the reader is a blocking thread) ──

struct LogLine {
    level: tracing::Level,
    text: String,
}

static LOGS: Mutex<Vec<LogLine>> = Mutex::new(Vec::new());

struct Capture;

struct Fields(String);

impl tracing::field::Visit for Fields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        let _ = write!(self.0, "{}={:?} ", field.name(), value);
    }
}

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for Capture {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let mut fields = Fields(String::new());
        event.record(&mut fields);
        let line = LogLine {
            level: *event.metadata().level(),
            text: format!("{} {}", event.metadata().target(), fields.0),
        };
        LOGS.lock().unwrap_or_else(|e| e.into_inner()).push(line);
    }
}

fn install_log_capture() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        let _ = tracing::subscriber::set_global_default(tracing_subscriber::registry().with(Capture));
    });
}

fn clear_logs() {
    LOGS.lock().unwrap_or_else(|e| e.into_inner()).clear();
}

/// Captured lines (level, text) whose text contains every needle.
fn logs_with(needles: &[&str]) -> Vec<(tracing::Level, String)> {
    LOGS.lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .filter(|l| needles.iter().all(|n| l.text.contains(n)))
        .map(|l| (l.level, l.text.clone()))
        .collect()
}

fn all_logs() -> Vec<String> {
    LOGS.lock().unwrap_or_else(|e| e.into_inner()).iter().map(|l| l.text.clone()).collect()
}

// ── the credential watch double ──────────────────────────────────────────────────

struct FakeWatch {
    stamp: Mutex<CredentialStamp>,
    calls: AtomicUsize,
    /// Real time every look takes (a slow keychain probe); zero by default.
    delay_ms: AtomicU64,
}

impl FakeWatch {
    fn new(stamp: CredentialStamp) -> Self {
        Self { stamp: Mutex::new(stamp), calls: AtomicUsize::new(0), delay_ms: AtomicU64::new(0) }
    }

    /// Make every look at the credential take `delay` of real time (`std::thread::sleep`).
    fn set_delay(&self, delay: Duration) {
        self.delay_ms.store(delay.as_millis() as u64, Ordering::SeqCst);
    }

    fn set(&self, stamp: CredentialStamp) {
        *self.stamp.lock().unwrap() = stamp;
    }

    fn set_stamp(&self, s: &str) {
        self.set(CredentialStamp::Stamp(s.to_string()));
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl CredentialWatch for FakeWatch {
    fn stamp(&self) -> CredentialStamp {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let stamp = self.stamp.lock().unwrap().clone();
        let delay = self.delay_ms.load(Ordering::SeqCst);
        if delay > 0 {
            std::thread::sleep(Duration::from_millis(delay));
        }
        stamp
    }
}

// ── what the daemon says ─────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Pic {
    needs_login: bool,
    claude_bin: Option<String>,
    watch: ClaudeLoginWatch,
    sessions: Vec<ClaudeLoginSession>,
}

fn pic_of(msg: &ServerMsg) -> Pic {
    match msg {
        ServerMsg::ClaudeLoginState { needs_login, claude_bin, watch, sessions } => Pic {
            needs_login: *needs_login,
            claude_bin: claude_bin.clone(),
            watch: *watch,
            sessions: sessions.clone(),
        },
        other => panic!("not a claude_login_state: {}", serde_json::to_string(other).unwrap_or_default()),
    }
}

impl Pic {
    fn entry(&self, tag: &str) -> Option<&ClaudeLoginSession> {
        self.sessions.iter().find(|s| s.tag == tag)
    }

    fn held(&self, tag: &str) -> ClaudeLoginSession {
        self.entry(tag).unwrap_or_else(|| panic!("no entry for {tag}: {self:?}")).clone()
    }
}

// ── the world a test runs in ─────────────────────────────────────────────────────

/// Kills every fake the manager started when the world goes away, a failed assertion included.
struct KillOnDrop(Arc<Mutex<SessionManager>>);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).kill_all_on_shutdown();
    }
}

struct World {
    mgr: Arc<Mutex<SessionManager>>,
    _kill: KillOnDrop,
    _coordinator: Arc<LoginCoordinator>,
    watch: Arc<FakeWatch>,
    rx: Mutex<broadcast::Receiver<ServerMsg>>,
    frames: Mutex<Vec<ServerMsg>>,
    tmp: tempfile::TempDir,
    auth_file: PathBuf,
    spawns: usize,
}

/// What one fake process leaves behind (all respawns of a session share the directory).
struct Fake {
    dir: PathBuf,
}

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn run<Fut: Future<Output = ()>>(body: impl FnOnce(World) -> Fut) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    install_log_capture();
    clear_logs();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().start_paused(true).build().unwrap();
    rt.block_on(async move {
        let world = World::new();
        body(world).await;
    });
}

impl World {
    fn new() -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::set_var(nostromo::approvals::APPROVALS_DIR_ENV, tmp.path().join("approvals"));
        std::env::set_var(
            nostromo::approvals::guard::GUARD_BIN_ENV,
            env!("CARGO_BIN_EXE_nostromo-guard"),
        );

        let auth_file = tmp.path().join("auth-state");
        std::fs::write(&auth_file, "ok").unwrap();

        let watch = Arc::new(FakeWatch::new(CredentialStamp::Stamp("stamp-0".into())));
        let coordinator = LoginCoordinator::new(watch.clone());
        let (tx, rx) = broadcast::channel(4096);
        coordinator.configure_broadcast(tx);
        let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("daemon-sessions.json"),
        )));
        coordinator.attach(&mgr);
        Self {
            _kill: KillOnDrop(mgr.clone()),
            mgr,
            _coordinator: coordinator,
            watch,
            rx: Mutex::new(rx),
            frames: Mutex::new(Vec::new()),
            tmp,
            auth_file,
            spawns: 0,
        }
    }

    fn set_login(&self, value: &str) {
        std::fs::write(&self.auth_file, value).unwrap();
    }

    /// Start a session of the fake CLI under `tag`. `sticky`: the fake reads the login once at
    /// startup (like a live CLI that cached a bad credential).
    fn spawn(&mut self, tag: &str, sticky: bool) -> Fake {
        self.spawns += 1;
        let dir = self.tmp.path().join(format!("fake-{}", self.spawns));
        std::fs::create_dir_all(&dir).unwrap();
        let wrapper = dir.join("claude");
        let sticky_env = if sticky { "FAKE_CLAUDE_AUTH_STICKY=1" } else { "" };
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{dir}/spawns.log'\n\
                 printf '%s\\n' $$ >> '{dir}/pids.log'\n\
                 FAKE_CLAUDE_LOG_DIR='{dir}' FAKE_CLAUDE_AUTH_FILE='{auth}' {sticky_env} \
                 exec python3 -I '{FAKE_CLI}' \"$@\"\n",
                dir = dir.display(),
                auth = self.auth_file.display(),
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
        let work = self.tmp.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        self.mgr
            .lock()
            .unwrap()
            .spawn_session(tag.into(), "cody".into(), format!("view-{tag}"), Some(work), None, false)
            .expect("the session starts")
            .expect("a session id");
        Fake { dir }
    }

    fn send(&self, tag: &str, text: &str) -> anyhow::Result<()> {
        self.mgr.lock().unwrap().send_user_message(tag, text, &[])
    }

    fn say(&self, tag: &str, text: &str) {
        self.send(tag, text).expect("the message is accepted");
    }

    fn state(&self, tag: &str) -> SessionState {
        self.mgr
            .lock()
            .unwrap()
            .list()
            .into_iter()
            .find(|s| s.tag == tag)
            .map(|s| s.state)
            .expect("a known session")
    }

    fn resend(&self, tag: &str, hold_id: &str, trigger: ResendTrigger) -> ResendOutcome {
        self.mgr.lock().unwrap().resend_held(tag, hold_id, trigger)
    }

    fn discard(&self, tag: &str, hold_id: Option<&str>) -> bool {
        self.mgr.lock().unwrap().discard_held(tag, hold_id)
    }

    fn pic(&self) -> Pic {
        pic_of(&self.mgr.lock().unwrap().login_snapshot())
    }

    /// Does any session of the manager hold a message for a sign-in?
    fn has_hold(&self) -> bool {
        self.mgr.lock().unwrap().has_login_hold()
    }

    fn stop(&self, tag: &str) {
        self.mgr.lock().unwrap().stop(tag);
    }

    fn restart(&self, tag: &str) {
        self.mgr.lock().unwrap().restart(tag).expect("restart");
    }

    fn interrupt(&self, tag: &str) -> InterruptOutcome {
        self.mgr.lock().unwrap().interrupt(tag).expect("interrupt")
    }

    /// Has the manager given up on `tag` (stopped by the user or by the crash-loop guard)?
    fn is_stopped(&self, tag: &str) -> bool {
        self.mgr
            .lock()
            .unwrap()
            .list()
            .into_iter()
            .find(|s| s.tag == tag)
            .is_some_and(|s| s.stop_reason.is_some())
    }

    /// Kill the process most recently started for `fake` the way a crash does (SIGKILL: no exit
    /// code, so the supervisor restarts it at once), then run the supervisor until it has either
    /// started a new process or given up on the session.
    async fn crash_and_recover(&self, tag: &str, fake: &Fake) {
        let before = fake.pids();
        let pid = *before.last().expect("a process was started");
        // SAFETY: `pid` is the fake the manager started (its wrapper `exec`s into it).
        assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0, "the fake is alive to be killed");
        wait_until("the supervisor to restart the session or give up on it", || {
            self.mgr.lock().unwrap().reap_and_recover();
            (fake.pids().len() > before.len() || self.is_stopped(tag)).then_some(())
        })
        .await;
    }

    /// Crash `tag` over and over until the crash-loop guard gives up on it.
    async fn crash_until_the_guard_trips(&self, tag: &str, fake: &Fake) {
        let mut crashes = 0;
        while !self.is_stopped(tag) {
            assert!(crashes < 8, "the crash-loop guard never tripped");
            self.crash_and_recover(tag, fake).await;
            crashes += 1;
        }
        assert!(crashes >= 2, "the guard tripped on crashes, not on the first one: {crashes}");
    }

    /// Nothing looks at the credential any more: the count stays put over several intervals.
    async fn assert_poller_stopped(&self) {
        self.ticks(2).await; // let an in-flight look finish
        settle().await;
        let after = self.watch.calls();
        self.ticks(6).await;
        settle().await;
        assert_eq!(self.watch.calls(), after, "the poller keeps looking at the credential");
    }

    /// Everything broadcast so far.
    fn broadcasts(&self) -> Vec<ServerMsg> {
        let mut rx = self.rx.lock().unwrap();
        let mut frames = self.frames.lock().unwrap();
        loop {
            match rx.try_recv() {
                Ok(m) => frames.push(m),
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
        frames.clone()
    }

    async fn wait_idle(&self, tag: &str) {
        wait_until(&format!("{tag} to go idle"), || (self.state(tag) == SessionState::Idle).then_some(())).await;
    }

    /// The session's entry once it holds a message.
    async fn wait_hold(&self, tag: &str) -> ClaudeLoginSession {
        wait_until(&format!("a hold for {tag}"), || {
            self.pic().entry(tag).filter(|e| e.hold_id.is_some()).cloned()
        })
        .await
    }

    /// A hold for `tag` whose id is not `old`, in `phase`.
    async fn wait_new_hold(&self, tag: &str, old: &str, phase: ClaudeLoginPhase) -> ClaudeLoginSession {
        self.drive_until(&format!("a new hold for {tag}"), || {
            self.pic()
                .entry(tag)
                .filter(|e| e.hold_id.as_deref().is_some_and(|id| id != old) && e.phase == phase)
                .cloned()
        })
        .await
    }

    /// One poll interval of paused time, then enough real time for the poller and the
    /// blocking reader to react.
    async fn tick(&self) {
        tokio::time::advance(POLL_INTERVAL).await;
        for _ in 0..4 {
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    async fn ticks(&self, n: usize) {
        for _ in 0..n {
            self.tick().await;
        }
    }

    /// Like `wait_until`, advancing the poller's clock between looks.
    async fn drive_until<R>(&self, what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
        let start = Instant::now();
        loop {
            if let Some(v) = ready() {
                return v;
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out (real time) waiting for {what}"
            );
            self.tick().await;
        }
    }

    /// Wait until the fake has been sent `n` user messages.
    async fn wait_user_texts(&self, fake: &Fake, n: usize) -> Vec<String> {
        self.drive_until(&format!("{n} user message(s) to reach the fake"), || {
            let texts = fake.user_texts();
            (texts.len() >= n).then_some(texts)
        })
        .await
    }

    /// Everything the daemon ended up writing, once a few more poll intervals have passed.
    async fn settled_user_texts(&self, fake: &Fake) -> Vec<String> {
        self.ticks(6).await;
        settle().await;
        fake.user_texts()
    }
}

impl Fake {
    fn read_lines(&self, file: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join(file))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{file}: {e}: {l}")))
            .collect()
    }

    /// Every user frame the daemon wrote to the fake's stdin, verbatim.
    fn user_frames(&self) -> Vec<Value> {
        self.read_lines("stdin.jsonl").into_iter().filter(|f| f["type"] == "user").collect()
    }

    fn user_texts(&self) -> Vec<String> {
        self.user_frames()
            .iter()
            .map(|f| f["message"]["content"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    /// The pid of every process started, oldest first (the wrapper `exec`s into the fake).
    fn pids(&self) -> Vec<i32> {
        std::fs::read_to_string(self.dir.join("pids.log"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect()
    }

    /// One line per process started (its argv).
    fn spawn_lines(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("spawns.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The argv of the most recent process.
    fn last_argv(&self) -> Vec<String> {
        let text = std::fs::read_to_string(self.dir.join("argv.json")).expect("argv.json");
        serde_json::from_str(&text).expect("argv.json is a list")
    }
}

async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(start.elapsed() < Duration::from_secs(30), "timed out (real time) waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
        tokio::task::yield_now().await;
    }
}

async fn settle() {
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

fn count(texts: &[String], needle: &str) -> usize {
    texts.iter().filter(|t| t.contains(needle)).count()
}

/// Is `id` shaped like a fresh random id (a hyphenated uuid)?
fn looks_like_uuid(id: &str) -> bool {
    id.len() == 36 && id.matches('-').count() == 4
}

// ═════════════════════════════════════════════════════════════════════════════════
// 1. detection: the failure is held, announced, and logged once
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn an_expired_login_holds_the_message_and_announces_the_sign_in_need() {
    run(|mut w| async move {
        let tag = "cody-detect";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-DETECT hello");

        // The broadcast says what is going on.
        let frame = wait_until("a needs_login broadcast", || {
            w.broadcasts()
                .iter()
                .filter(|m| matches!(m, ServerMsg::ClaudeLoginState { .. }))
                .map(pic_of)
                .rfind(|p| p.needs_login)
        })
        .await;
        let entry = frame.held(tag);
        let hold_id = entry.hold_id.clone().expect("a hold id");
        assert!(looks_like_uuid(&hold_id), "{hold_id}");
        assert_eq!(entry.phase, ClaudeLoginPhase::Waiting);
        assert_eq!(entry.queued, 0);
        assert_eq!(entry.auto_resends_left, MAX_AUTO_RESENDS);
        let failed_at = chrono::DateTime::parse_from_rfc3339(&entry.failed_at)
            .unwrap_or_else(|e| panic!("failed_at {:?}: {e}", entry.failed_at));
        assert_eq!(failed_at.offset().local_minus_utc(), 0, "UTC: {}", entry.failed_at);
        assert!(frame.claude_bin.as_deref().is_some_and(|b| b.ends_with("claude")), "{:?}", frame.claude_bin);

        // The session is idle, not mid-turn, and the snapshot agrees with the broadcast.
        w.wait_idle(tag).await;
        let snapshot = w.pic();
        assert!(snapshot.needs_login);
        assert_eq!(snapshot.watch, ClaudeLoginWatch::Keychain);
        assert_eq!(snapshot.held(tag), entry);

        // The failed message was written once and is not written again.
        settle().await;
        assert_eq!(count(&fake.user_texts(), "HELD-DETECT"), 1);
    });
}

#[test]
fn the_daemon_logs_one_warning_per_auth_failure_with_no_content() {
    run(|mut w| async move {
        let tag = "cody-warnlog";
        let _fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-WARNLOG hello");
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        settle().await;

        let warns: Vec<_> = logs_with(&["claude auth failure detected", tag])
            .into_iter()
            .filter(|(level, _)| *level == tracing::Level::WARN)
            .collect();
        assert_eq!(warns.len(), 1, "{warns:?}");
    });
}

#[test]
fn a_healthy_login_never_holds_anything() {
    run(|mut w| async move {
        let tag = "cody-healthy";
        let fake = w.spawn(tag, false);
        w.say(tag, "HEALTHY-ONE");
        w.say(tag, "HEALTHY-TWO");
        w.wait_user_texts(&fake, 2).await;
        w.wait_idle(tag).await;
        let pic = w.pic();
        assert!(!pic.needs_login);
        assert!(pic.sessions.is_empty());
        assert!(logs_with(&["claude auth failure detected"]).is_empty());
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 2-3. paused sessions keep their messages; a credential change resends and drains
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn messages_sent_while_waiting_for_sign_in_are_queued_not_written() {
    run(|mut w| async move {
        let tag = "cody-queue";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-QUEUE");
        let held = w.wait_hold(tag).await;
        w.wait_idle(tag).await;

        for i in 1..=3 {
            w.say(tag, &format!("QUEUED-{i}"));
        }
        settle().await;

        assert_eq!(fake.user_frames().len(), 1, "only the failed message was ever written");
        let entry = w.pic().held(tag);
        assert_eq!(entry.queued, 3);
        assert_eq!(entry.hold_id, held.hold_id, "queueing does not replace the hold");
        assert_eq!(entry.phase, ClaudeLoginPhase::Waiting);
        // Not even a poll interval or three changes that.
        w.ticks(3).await;
        assert_eq!(fake.user_frames().len(), 1);
    });
}

#[test]
fn a_credential_change_resends_the_held_message_once_then_drains_the_queue_in_order() {
    run(|mut w| async move {
        let tag = "cody-resend";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-RESEND");
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        for i in 1..=3 {
            w.say(tag, &format!("QUEUED-{i}"));
        }

        // The user signs in: the credential changes and the CLI can authenticate again.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");

        let texts = w.wait_user_texts(&fake, 5).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        w.wait_idle(tag).await;
        let texts_later = w.settled_user_texts(&fake).await;
        assert_eq!(texts_later, texts, "nothing is written twice");
        assert_eq!(
            texts,
            vec!["HELD-RESEND", "HELD-RESEND", "QUEUED-1", "QUEUED-2", "QUEUED-3"],
            "the original, the held message once more, then the queue in order"
        );

        // The resent frame is byte for byte the one that failed.
        let frames = fake.user_frames();
        assert_eq!(frames[0], frames[1]);

        let pic = w.pic();
        assert!(!pic.needs_login);
        assert!(pic.sessions.is_empty());
        let last = w.broadcasts().iter().rev().find(|m| matches!(m, ServerMsg::ClaudeLoginState { .. })).map(pic_of);
        let last = last.expect("a final broadcast");
        assert!(!last.needs_login && last.sessions.is_empty(), "{last:?}");

        // B8: one line when the held message is resent, with the outcome.
        let resending = logs_with(&["resending held message", tag]);
        assert_eq!(resending.len(), 1, "{resending:?}");
        assert!(!logs_with(&["held message resent: ok"]).is_empty());
    });
}

#[test]
fn an_unchanged_credential_never_resends() {
    run(|mut w| async move {
        let tag = "cody-nochange";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-NOCHANGE");
        w.wait_hold(tag).await;
        w.set_login("ok"); // the CLI could now authenticate, but the watch saw nothing change
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-NOCHANGE"]);
        assert_eq!(w.pic().held(tag).phase, ClaudeLoginPhase::Waiting);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 4. nothing is ever sent twice
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn two_manual_retries_and_a_credential_change_at_once_write_the_message_once() {
    run(|mut w| async move {
        let tag = "cody-race";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-RACE");
        let hold = w.wait_hold(tag).await;
        let id = hold.hold_id.unwrap();
        w.wait_idle(tag).await;

        w.set_login("ok");
        w.watch.set_stamp("stamp-1"); // the poller would resend too
        let first = w.resend(tag, &id, ResendTrigger::Manual);
        let second = w.resend(tag, &id, ResendTrigger::Manual);
        assert_eq!(first, ResendOutcome::Resent);
        assert_ne!(second, ResendOutcome::Resent, "the same hold is resent once");

        w.wait_user_texts(&fake, 2).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-RACE", "HELD-RACE"], "one extra frame, whoever won the race");
    });
}

#[test]
fn a_retry_naming_a_hold_that_has_been_replaced_writes_nothing() {
    run(|mut w| async move {
        let tag = "cody-stale";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-STALE");
        let first_hold = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;

        // The login is still broken: the resend fails again and the message is re-held.
        assert_eq!(w.resend(tag, &first_hold, ResendTrigger::Manual), ResendOutcome::Resent);
        w.wait_user_texts(&fake, 2).await;
        let second = w.wait_new_hold(tag, &first_hold, ClaudeLoginPhase::Waiting).await;
        let second_hold = second.hold_id.clone().unwrap();
        assert_ne!(first_hold, second_hold, "a new hold id after the resend failed");
        w.wait_idle(tag).await;

        // A late duplicate Retry from the card that showed the old hold.
        let outcome = w.resend(tag, &first_hold, ResendTrigger::Manual);
        assert_ne!(outcome, ResendOutcome::Resent);
        assert_ne!(w.resend(tag, "not-a-hold-id", ResendTrigger::Manual), ResendOutcome::Resent);
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-STALE", "HELD-STALE"], "nothing written for a stale id");
        assert_eq!(w.pic().held(tag).hold_id.as_deref(), Some(second_hold.as_str()));
    });
}

#[test]
fn a_stale_discard_changes_nothing() {
    run(|mut w| async move {
        let tag = "cody-staledrop";
        let _fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-STALEDROP");
        let hold = w.wait_hold(tag).await;
        assert!(!w.discard(tag, Some("some-other-hold")));
        assert_eq!(w.pic().held(tag).hold_id, hold.hold_id);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 5. a turn that did real work is not resent on its own
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn a_turn_that_did_real_work_is_held_but_only_a_manual_retry_resends_it() {
    run(|mut w| async move {
        let tag = "cody-midturn";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-MIDTURN AUTH_MIDTURN");
        let entry = w.wait_hold(tag).await;
        assert_eq!(entry.phase, ClaudeLoginPhase::NotResendable);
        assert!(w.pic().needs_login, "still detected and announced");
        let id = entry.hold_id.clone().expect("held, so Resend anyway can name it");
        w.wait_idle(tag).await;

        // The credential changes, and the CLI could authenticate: still nothing is resent.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts.len(), 1, "no automatic resend of a turn that ran a tool: {texts:?}");
        let entry = w.pic().held(tag);
        assert_eq!(entry.phase, ClaudeLoginPhase::NotResendable);
        assert_eq!(entry.hold_id.as_deref(), Some(id.as_str()));

        // Resend anyway.
        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        let texts = w.wait_user_texts(&fake, 2).await;
        assert_eq!(texts[0], texts[1]);
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 6. a CLI that cached the bad credential: one restart, no more
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn a_live_cli_that_cached_the_bad_login_is_restarted_once_and_the_message_resent_after_the_respawn() {
    run(|mut w| async move {
        let tag = "cody-sticky-ok";
        w.set_login("expired"); // read once, at startup, by the sticky fake
        let fake = w.spawn(tag, true);
        w.say(tag, "HELD-STICKY");
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        assert_eq!(fake.spawn_lines().len(), 1);

        // The user signs in. The running process keeps its cached credential; a new one reads
        // the new login.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");

        w.drive_until("the restart", || (fake.spawn_lines().len() >= 2).then_some(())).await;
        let texts = w.wait_user_texts(&fake, 3).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        assert!(
            fake.last_argv().iter().any(|a| a == "--resume"),
            "the second process resumes the session: {:?}",
            fake.last_argv()
        );
        let texts_later = w.settled_user_texts(&fake).await;
        assert_eq!(texts_later, texts);
        assert_eq!(texts, vec!["HELD-STICKY"; 3], "the original, the failed resend, the resend after respawn");
        assert_eq!(fake.spawn_lines().len(), 2, "restarted exactly once");
        let frames = fake.user_frames();
        assert!(frames[0] == frames[1] && frames[1] == frames[2], "verbatim every time");
    });
}

#[test]
fn if_the_respawned_cli_still_cannot_authenticate_the_message_is_held_again_without_a_second_restart() {
    run(|mut w| async move {
        let tag = "cody-sticky-bad";
        w.set_login("expired");
        let fake = w.spawn(tag, true);
        w.say(tag, "HELD-STICKYBAD");
        let first_hold = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;

        // The credential changed, but the CLI (old and new process alike) still fails.
        w.watch.set_stamp("stamp-1");

        w.drive_until("the restart", || (fake.spawn_lines().len() >= 2).then_some(())).await;
        w.wait_user_texts(&fake, 3).await;
        let again = w.wait_new_hold(tag, &first_hold, ClaudeLoginPhase::Waiting).await;
        assert!(again.hold_id.is_some());
        w.wait_idle(tag).await;

        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-STICKYBAD"; 3], "exactly two attempts after the first failure");
        assert_eq!(fake.spawn_lines().len(), 2, "no second restart");
        assert!(w.pic().needs_login);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 7. discard
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn discarding_the_hold_unpauses_and_writes_the_first_queued_message() {
    run(|mut w| async move {
        let tag = "cody-discard";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-DISCARD");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        w.say(tag, "QUEUED-A");
        w.say(tag, "QUEUED-B");
        w.set_login("ok");

        assert!(w.discard(tag, Some(&id)));

        let texts = w.wait_user_texts(&fake, 3).await;
        w.wait_idle(tag).await;
        let texts_later = w.settled_user_texts(&fake).await;
        assert_eq!(texts_later, texts);
        assert_eq!(texts, vec!["HELD-DISCARD", "QUEUED-A", "QUEUED-B"], "the held message is gone, the queue drains");
        let pic = w.pic();
        assert!(!pic.needs_login && pic.sessions.is_empty(), "{pic:?}");

        // B8: one line for the discard.
        assert_eq!(logs_with(&["held message discarded", tag]).len(), 1);
        // A second discard has nothing to drop.
        assert!(!w.discard(tag, Some(&id)));
    });
}

#[test]
fn if_the_message_after_a_discard_fails_too_it_becomes_the_new_hold() {
    run(|mut w| async move {
        let tag = "cody-discard-fail";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-DF");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        w.say(tag, "QUEUED-DF-1");
        w.say(tag, "QUEUED-DF-2");

        assert!(w.discard(tag, Some(&id)));
        w.wait_user_texts(&fake, 2).await;
        let entry = w.wait_new_hold(tag, &id, ClaudeLoginPhase::Waiting).await;
        assert_eq!(entry.queued, 1, "the second queued message is still waiting");
        w.wait_idle(tag).await;
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-DF", "QUEUED-DF-1"], "the discarded message never comes back");
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 8. the paused queue is bounded
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn the_twenty_first_message_to_a_session_waiting_for_sign_in_is_refused_and_not_written() {
    run(|mut w| async move {
        let tag = "cody-cap";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-CAP");
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;

        for i in 1..=LOGIN_QUEUE_CAP {
            w.say(tag, &format!("QUEUED-CAP-{i}"));
        }
        let err = w.send(tag, "OVERFLOW-CAP").expect_err("the queue is full");
        let text = format!("{err:#}");
        assert!(text.contains("waiting_for_sign_in: queue full"), "{text}");
        assert!(!text.contains("OVERFLOW-CAP"), "the refusal carries no message text: {text}");

        settle().await;
        assert_eq!(fake.user_frames().len(), 1, "nothing written");
        assert_eq!(w.pic().held(tag).queued as usize, LOGIN_QUEUE_CAP);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 9. the hold survives a restart
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn the_hold_and_the_pause_survive_a_session_restart() {
    run(|mut w| async move {
        let tag = "cody-restart";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-RESTART");
        let before = w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        w.say(tag, "QUEUED-R1");
        w.say(tag, "QUEUED-R2");

        w.mgr.lock().unwrap().restart(tag).expect("restart");
        settle().await;

        let after = w.pic().held(tag);
        assert_eq!(after.hold_id, before.hold_id, "same hold");
        assert_eq!(after.queued, 2);
        assert_eq!(fake.user_texts(), vec!["HELD-RESTART"], "the new process was sent nothing");
        w.ticks(2).await;
        assert_eq!(fake.user_texts(), vec!["HELD-RESTART"]);

        // And it still resends, into the new process, in order.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.wait_user_texts(&fake, 4).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        let texts_later = w.settled_user_texts(&fake).await;
        assert_eq!(texts_later, texts);
        assert_eq!(texts, vec!["HELD-RESTART", "HELD-RESTART", "QUEUED-R1", "QUEUED-R2"]);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 10. the 60-minute window and the attempt cap bound the automatic resend
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn a_hold_older_than_the_ttl_is_not_resent_automatically_but_a_manual_retry_still_works() {
    run(|mut w| async move {
        let tag = "cody-ttl";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-TTL");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;

        // An hour goes by with the credential unchanged.
        for _ in 0..13 {
            tokio::time::advance(Duration::from_secs(5 * 60)).await;
            tokio::task::yield_now().await;
        }
        assert!(Duration::from_secs(13 * 5 * 60) > AUTO_RESEND_TTL);
        settle().await;

        // Then the user signs in.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-TTL"], "too old to surprise the user");
        assert_eq!(w.pic().held(tag).hold_id.as_deref(), Some(id.as_str()));

        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        w.wait_user_texts(&fake, 2).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
    });
}

#[test]
fn automatic_resends_stop_at_the_cap_and_a_manual_retry_still_works() {
    run(|mut w| async move {
        let tag = "cody-attempts";
        let fake = w.spawn(tag, false);
        w.set_login("expired"); // never recovers on its own
        w.say(tag, "HELD-CAP3");
        let mut hold = w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        assert_eq!(hold.auto_resends_left, MAX_AUTO_RESENDS);

        // Each new credential stamp buys one more attempt (the one after a respawn counts too),
        // until MAX_AUTO_RESENDS attempts have been used.
        let mut written = 1usize;
        let mut stamp = 0;
        while written < 1 + MAX_AUTO_RESENDS as usize {
            stamp += 1;
            assert!(stamp <= 6, "the attempts never reached the cap");
            w.watch.set_stamp(&format!("stamp-cap-{stamp}"));
            let before = written;
            w.drive_until("an automatic attempt", || (fake.user_texts().len() > before).then_some(())).await;
            written = w.settled_user_texts(&fake).await.len();
            w.wait_idle(tag).await;
            hold = w.pic().held(tag);
        }
        assert_eq!(written, 1 + MAX_AUTO_RESENDS as usize, "exactly {MAX_AUTO_RESENDS} automatic attempts");
        assert_eq!(hold.auto_resends_left, 0);

        // Further credential changes resend nothing.
        for i in 0..3 {
            w.watch.set_stamp(&format!("stamp-after-cap-{i}"));
            w.ticks(3).await;
        }
        settle().await;
        assert_eq!(fake.user_texts().len(), written, "capped");
        let entry = w.pic().held(tag);
        assert_eq!(entry.auto_resends_left, 0);
        assert_eq!(entry.phase, ClaudeLoginPhase::Waiting);

        // The human still can.
        w.set_login("ok");
        assert_eq!(w.resend(tag, &entry.hold_id.unwrap(), ResendTrigger::Manual), ResendOutcome::Resent);
        w.wait_user_texts(&fake, written + 1).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
    });
}

#[test]
fn one_credential_stamp_buys_at_most_one_automatic_attempt() {
    run(|mut w| async move {
        let tag = "cody-onestamp";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-ONESTAMP");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;

        w.watch.set_stamp("stamp-1");
        w.wait_new_hold(tag, &id, ClaudeLoginPhase::Waiting).await;
        w.wait_idle(tag).await;
        let after_first = w.settled_user_texts(&fake).await;
        // The watch keeps saying the same stamp, poll after poll.
        w.ticks(8).await;
        settle().await;
        assert_eq!(fake.user_texts(), after_first, "the same stamp is not tried again");
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 11. the poller only runs while something is held
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn the_credential_is_not_looked_at_while_nothing_is_held() {
    run(|mut w| async move {
        let tag = "cody-idlepoll";
        let fake = w.spawn(tag, false);
        w.ticks(4).await;
        assert_eq!(w.watch.calls(), 0, "no session at all");

        w.say(tag, "FINE-ONE");
        w.wait_user_texts(&fake, 1).await;
        w.wait_idle(tag).await;
        w.ticks(4).await;
        assert_eq!(w.watch.calls(), 0, "a session with a working login");
    });
}

#[test]
fn the_credential_is_polled_while_a_hold_exists_and_not_after_it_clears() {
    run(|mut w| async move {
        let tag = "cody-pollcycle";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-POLL");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;

        let at_failure = w.watch.calls();
        w.ticks(4).await;
        assert!(
            w.watch.calls() >= at_failure + 2,
            "the poller looks every interval while a hold exists ({} -> {})",
            at_failure,
            w.watch.calls()
        );

        // The hold clears.
        w.set_login("ok");
        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        w.wait_user_texts(&fake, 2).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        w.wait_idle(tag).await;
        settle().await;
        w.ticks(2).await; // let an in-flight look finish
        settle().await;

        let after_clear = w.watch.calls();
        w.ticks(6).await;
        settle().await;
        assert_eq!(w.watch.calls(), after_clear, "the poller stops when no hold is left");
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 12. a watch that cannot see the credential: manual only
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn with_an_unavailable_watch_nothing_is_resent_by_itself_but_a_manual_retry_works() {
    run(|mut w| async move {
        let tag = "cody-nowatch";
        w.watch.set(CredentialStamp::Unavailable);
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-NOWATCH");
        let id = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        assert_eq!(w.pic().watch, ClaudeLoginWatch::Unavailable);

        w.set_login("ok");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-NOWATCH"], "no timer-based resend");
        assert_eq!(w.pic().held(tag).phase, ClaudeLoginPhase::Waiting);

        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        w.wait_user_texts(&fake, 2).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 13. a session the manager gave up on holds nothing, is not polled and resends nothing
// ═════════════════════════════════════════════════════════════════════════════════

/// A session that waits for a sign-in with one message held.
async fn hold_one(w: &mut World, tag: &str, text: &str) -> Fake {
    let fake = w.spawn(tag, false);
    w.set_login("expired");
    w.say(tag, text);
    w.wait_hold(tag).await;
    w.wait_idle(tag).await;
    fake
}

#[test]
fn stopping_a_session_waiting_for_sign_in_drops_its_hold_and_the_credential_is_no_longer_polled() {
    run(|mut w| async move {
        let tag = "cody-stop-hold";
        let _fake = hold_one(&mut w, tag, "HELD-STOPHOLD").await;
        let at_failure = w.watch.calls();
        w.ticks(4).await;
        assert!(w.watch.calls() >= at_failure + 2, "the poller runs while the hold exists");
        assert!(w.has_hold());

        w.stop(tag);

        assert!(!w.has_hold(), "a stopped session holds no message for a sign-in");
        let pic = w.pic();
        assert!(!pic.needs_login && pic.sessions.is_empty(), "{pic:?}");
        w.assert_poller_stopped().await;
    });
}

#[test]
fn a_message_held_by_a_stopped_session_is_never_sent_when_the_session_is_started_again() {
    run(|mut w| async move {
        let tag = "cody-stop-restart";
        let fake = hold_one(&mut w, tag, "HELD-STOPRESTART").await;

        w.stop(tag);
        w.restart(tag);
        settle().await;
        assert_eq!(fake.user_texts(), vec!["HELD-STOPRESTART"], "the new process was sent nothing");
        assert!(w.pic().sessions.is_empty(), "the started-again session is not waiting for anything");

        // The user signs in later: there is nothing to resend, and nothing is paused.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-STOPRESTART"], "the old message is not written to the new process");
        assert!(!w.has_hold());
        assert!(!w.pic().needs_login);

        // And the session is usable, not paused.
        w.say(tag, "AFTER-STOPRESTART");
        let texts = w.wait_user_texts(&fake, 2).await;
        assert_eq!(texts, vec!["HELD-STOPRESTART", "AFTER-STOPRESTART"]);
    });
}

#[test]
fn a_session_the_crash_loop_guard_gave_up_on_holds_nothing_and_is_not_polled() {
    run(|mut w| async move {
        let tag = "cody-guard-hold";
        let fake = hold_one(&mut w, tag, "HELD-GUARD").await;

        w.crash_until_the_guard_trips(tag, &fake).await;

        assert!(!w.has_hold(), "a session the guard gave up on holds no message for a sign-in");
        let pic = w.pic();
        assert!(!pic.needs_login && pic.sessions.is_empty(), "{pic:?}");
        w.assert_poller_stopped().await;

        // A credential change has nobody to resend to.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-GUARD"], "nothing is written");
    });
}

#[test]
fn a_message_held_by_a_session_the_guard_gave_up_on_is_never_sent_when_it_is_restarted() {
    run(|mut w| async move {
        let tag = "cody-guard-restart";
        let fake = hold_one(&mut w, tag, "HELD-GUARDRESTART").await;
        w.crash_until_the_guard_trips(tag, &fake).await;

        w.restart(tag);
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-GUARDRESTART"], "the old message is not written to the new process");
        assert!(!w.has_hold());
        assert!(w.pic().sessions.is_empty());
    });
}

#[test]
fn the_credential_is_polled_until_the_last_session_holding_a_message_is_gone() {
    run(|mut w| async move {
        let (a, b) = ("cody-two-a", "cody-two-b");
        let _fa = hold_one(&mut w, a, "HELD-TWO-A").await;
        let _fb = hold_one(&mut w, b, "HELD-TWO-B").await;
        assert_eq!(w.pic().sessions.len(), 2);

        w.stop(a);
        assert!(w.has_hold(), "the other session still holds its message");
        let pic = w.pic();
        assert!(pic.entry(a).is_none() && pic.entry(b).is_some(), "{pic:?}");
        let before = w.watch.calls();
        w.ticks(4).await;
        assert!(w.watch.calls() >= before + 2, "still polled while one session waits");

        w.stop(b);
        assert!(!w.has_hold());
        assert!(w.pic().sessions.is_empty());
        w.assert_poller_stopped().await;
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 17. Stop on a session waiting for a sign-in
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn stop_on_an_idle_session_waiting_for_sign_in_discards_the_hold_and_the_queue() {
    run(|mut w| async move {
        let tag = "cody-stopwait";
        let fake = hold_one(&mut w, tag, "HELD-STOPWAIT").await;
        for i in 1..=3 {
            w.say(tag, &format!("QUEUED-STOPWAIT-{i}"));
        }
        assert_eq!(w.pic().held(tag).queued, 3);

        assert_eq!(w.interrupt(tag), InterruptOutcome::DiscardedHold);

        assert!(!w.has_hold());
        let pic = w.pic();
        assert!(!pic.needs_login && pic.sessions.is_empty(), "{pic:?}");
        w.drive_until("the picture to clear on the wire", || {
            let last = w.broadcasts().iter().rev().find(|m| matches!(m, ServerMsg::ClaudeLoginState { .. })).map(pic_of);
            last.filter(|p| !p.needs_login && p.sessions.is_empty()).map(|_| ())
        })
        .await;

        // The user signs in: neither the held message nor the queue comes back.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-STOPWAIT"], "nothing more is written after the sign-in");
        w.wait_idle(tag).await;

        // The session is not paused any more, and the queue is gone: the next message is the next write.
        w.say(tag, "AFTER-STOPWAIT");
        let texts = w.wait_user_texts(&fake, 2).await;
        assert_eq!(texts, vec!["HELD-STOPWAIT", "AFTER-STOPWAIT"]);
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(texts, vec!["HELD-STOPWAIT", "AFTER-STOPWAIT"], "the discarded queue was not written");
    });
}

#[test]
fn stop_on_an_idle_session_that_is_not_waiting_for_anything_still_has_nothing_to_stop() {
    run(|mut w| async move {
        let tag = "cody-stopidle";
        let fake = w.spawn(tag, false);
        w.say(tag, "FINE-STOPIDLE");
        w.wait_user_texts(&fake, 1).await;
        w.wait_idle(tag).await;

        assert_eq!(w.interrupt(tag), InterruptOutcome::NotRunning);
        assert!(w.pic().sessions.is_empty());
    });
}

#[test]
fn stop_while_a_held_message_is_being_resent_stops_that_turn_as_it_always_did() {
    run(|mut w| async move {
        let tag = "cody-stopresend";
        let fake = hold_one(&mut w, tag, "HELD-STOPRESEND HANG_MIDTURN").await;
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        w.wait_user_texts(&fake, 2).await; // the resend; the fake takes it and never finishes the turn
        w.drive_until("the hold to be resending", || {
            w.pic().entry(tag).filter(|e| e.phase == ClaudeLoginPhase::Resending).map(|_| ())
        })
        .await;

        assert_eq!(w.interrupt(tag), InterruptOutcome::Requested);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 18. the credential probe never runs on a session's stdout reader
// ═════════════════════════════════════════════════════════════════════════════════

/// A look at the credential takes this long of real time in the slow-probe test.
const SLOW_PROBE: Duration = Duration::from_secs(3);
/// What a session may take to react, well under `SLOW_PROBE`.
const REACTS_WITHIN: Duration = Duration::from_millis(1500);

#[test]
fn a_slow_credential_probe_does_not_delay_the_hold_the_idle_state_or_the_next_turns() {
    run(|mut w| async move {
        let tag = "cody-slowprobe";
        let fake = w.spawn(tag, false);
        w.watch.set_delay(SLOW_PROBE);
        w.set_login("expired");

        // The failure is held and the session goes idle without waiting for the probe.
        let started = Instant::now();
        w.say(tag, "HELD-SLOWPROBE");
        let first = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        assert!(started.elapsed() < REACTS_WITHIN, "the failure took {:?} to be held", started.elapsed());
        w.say(tag, "QUEUED-SLOWPROBE");

        // A resend that fails again is held again just as fast.
        let started = Instant::now();
        assert_eq!(w.resend(tag, &first, ResendTrigger::Manual), ResendOutcome::Resent);
        let second = wait_until("a new hold", || {
            w.pic()
                .entry(tag)
                .filter(|e| e.hold_id.as_deref().is_some_and(|id| id != first) && e.phase == ClaudeLoginPhase::Waiting)
                .and_then(|e| e.hold_id.clone())
        })
        .await;
        w.wait_idle(tag).await;
        assert!(started.elapsed() < REACTS_WITHIN, "the second failure took {:?} to be held", started.elapsed());

        // The session carries on: the queued message is written and its turn completes, with
        // the probe still running somewhere else.
        w.set_login("ok");
        let started = Instant::now();
        assert!(w.discard(tag, Some(&second)));
        wait_until("the queued message to be written", || (fake.user_texts().len() >= 3).then_some(())).await;
        w.wait_idle(tag).await;
        assert!(started.elapsed() < REACTS_WITHIN, "the next turn took {:?} to complete", started.elapsed());
        assert_eq!(fake.user_texts(), vec!["HELD-SLOWPROBE", "HELD-SLOWPROBE", "QUEUED-SLOWPROBE"]);
        assert!(w.pic().sessions.is_empty());
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 19. a resend that was written is never written again on its own
// ═════════════════════════════════════════════════════════════════════════════════

#[test]
fn a_resend_whose_process_died_mid_turn_is_never_written_again_on_its_own() {
    run(|mut w| async move {
        let tag = "cody-crashresend";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, "HELD-CRASHRESEND DIE_MIDTURN");
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        assert_eq!(w.pic().held(tag).phase, ClaudeLoginPhase::Waiting, "nothing ran: resendable");

        // The user signs in: the daemon resends once, and the process dies in the middle of it.
        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        w.wait_user_texts(&fake, 2).await;
        wait_until("the process to die", || {
            let mgr = w.mgr.lock().unwrap();
            mgr.list().iter().all(|s| s.tag != tag || !s.alive).then_some(())
        })
        .await;

        // The supervisor restarts it, carrying the hold.
        let before = fake.pids().len();
        wait_until("the supervisor to restart the session", || {
            w.mgr.lock().unwrap().reap_and_recover();
            (fake.pids().len() > before).then_some(())
        })
        .await;
        w.wait_idle(tag).await;
        let entry = w.pic().held(tag);
        assert!(entry.hold_id.is_some(), "the message is still held");
        assert_eq!(
            entry.phase,
            ClaudeLoginPhase::NotResendable,
            "it was written once already and may have run: it needs the user's attention"
        );

        // Credential changes (this session's own, then other sessions' refreshes): nothing is written.
        for i in 2..6 {
            w.watch.set_stamp(&format!("stamp-{i}"));
            w.ticks(3).await;
        }
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(
            count(&texts, "HELD-CRASHRESEND"),
            2,
            "the original and the one resend, never a third: {texts:?}"
        );
        assert_eq!(fake.spawn_lines().len(), 2, "no further restarts either");
        let entry = w.pic().held(tag);
        assert_eq!(entry.phase, ClaudeLoginPhase::NotResendable);

        // The human still can.
        let id = entry.hold_id.unwrap();
        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        let texts = w.wait_user_texts(&fake, 3).await;
        assert_eq!(count(&texts, "HELD-CRASHRESEND"), 3);
    });
}

#[test]
fn a_restart_while_the_held_message_is_being_resent_never_writes_it_again_on_its_own() {
    run(|mut w| async move {
        let tag = "cody-restartresend";
        let fake = hold_one(&mut w, tag, "HELD-RESTARTRESEND HANG_MIDTURN").await;
        assert_eq!(w.pic().held(tag).phase, ClaudeLoginPhase::Waiting);

        w.set_login("ok");
        w.watch.set_stamp("stamp-1");
        w.wait_user_texts(&fake, 2).await; // the resend; the fake takes it and never finishes the turn
        w.drive_until("the hold to be resending", || {
            w.pic().entry(tag).filter(|e| e.phase == ClaudeLoginPhase::Resending).map(|_| ())
        })
        .await;

        w.restart(tag);
        settle().await;
        let entry = w.pic().held(tag);
        assert!(entry.hold_id.is_some(), "the message is still held");
        assert_eq!(
            entry.phase,
            ClaudeLoginPhase::NotResendable,
            "it was written once already and may have run: it needs the user's attention"
        );

        for i in 2..6 {
            w.watch.set_stamp(&format!("stamp-{i}"));
            w.ticks(3).await;
        }
        let texts = w.settled_user_texts(&fake).await;
        assert_eq!(
            count(&texts, "HELD-RESTARTRESEND"),
            2,
            "the original and the one resend, never a third: {texts:?}"
        );

        // The human still can.
        w.wait_idle(tag).await;
        let id = w.pic().held(tag).hold_id.unwrap();
        assert_eq!(w.resend(tag, &id, ResendTrigger::Manual), ResendOutcome::Resent);
        let texts = w.wait_user_texts(&fake, 3).await;
        assert_eq!(count(&texts, "HELD-RESTARTRESEND"), 3);
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 14. no content in logs, broadcasts or files
// ═════════════════════════════════════════════════════════════════════════════════

fn files_under(dir: &Path, skip: &dyn Fn(&Path) -> bool, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    for entry in read.flatten() {
        let path = entry.path();
        if skip(&path) {
            continue;
        }
        if path.is_dir() {
            files_under(&path, skip, out);
        } else {
            out.push(path);
        }
    }
}

#[test]
fn no_message_text_error_text_or_stamp_reaches_a_log_a_broadcast_or_a_file() {
    run(|mut w| async move {
        let user_markers = ["USERTEXT-MARKER-5d1e7a", "QUEUEDTEXT-MARKER-92b0c4", "DISCARDTEXT-MARKER-3fa86d"];
        let stamps = ["STAMP-MARKER-c81d2e", "STAMP-MARKER-0be44f"];
        w.watch.set_stamp(stamps[0]);

        let tag = "cody-nocontent";
        let fake = w.spawn(tag, false);
        w.set_login("expired");
        w.say(tag, &format!("{} please look at this", user_markers[0]));
        w.wait_hold(tag).await;
        w.wait_idle(tag).await;
        w.say(tag, &format!("{} and this", user_markers[1]));
        w.ticks(2).await;

        // Resend path: the credential changes, the login works.
        w.set_login("ok");
        w.watch.set_stamp(stamps[1]);
        w.wait_user_texts(&fake, 3).await;
        w.drive_until("the picture to clear", || (!w.pic().needs_login).then_some(())).await;
        w.wait_idle(tag).await;

        // Failure, manual retry that fails, and discard paths too.
        w.set_login("expired");
        w.say(tag, &format!("{} again", user_markers[2]));
        let id2 = w.wait_hold(tag).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        let _ = w.resend(tag, &id2, ResendTrigger::Manual);
        let id3 = w.wait_new_hold(tag, &id2, ClaudeLoginPhase::Waiting).await.hold_id.unwrap();
        w.wait_idle(tag).await;
        assert!(w.discard(tag, Some(&id3)));
        w.ticks(2).await;
        settle().await;

        let mut forbidden: Vec<String> = user_markers.iter().chain(stamps.iter()).map(|s| s.to_string()).collect();
        forbidden.push(AUTH_PHRASE.to_string());

        // Logs: every event, every field, any level.
        let logs = all_logs();
        assert!(!logs.is_empty(), "the capture works: the daemon logged something");
        for line in &logs {
            let lower = line.to_lowercase();
            for needle in &forbidden {
                assert!(!lower.contains(&needle.to_lowercase()), "{needle:?} leaked into a log line: {line}");
            }
        }

        // Broadcast frames.
        let frames = w.broadcasts();
        assert!(frames.iter().any(|m| matches!(m, ServerMsg::ClaudeLoginState { .. })));
        for frame in &frames {
            let json = serde_json::to_string(frame).unwrap();
            for needle in &forbidden {
                assert!(!json.contains(needle.as_str()), "{needle:?} leaked into a broadcast: {json}");
            }
        }
        // And the snapshot.
        let snapshot = serde_json::to_string(&w.mgr.lock().unwrap().login_snapshot()).unwrap();
        for needle in &forbidden {
            assert!(!snapshot.contains(needle.as_str()), "{needle:?} leaked into the snapshot");
        }

        // Files the daemon wrote (not the fake CLI's own logs, the wrappers or the login file).
        let auth_file = w.auth_file.clone();
        let skip = move |p: &Path| {
            p == auth_file
                || p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("fake-"))
        };
        let mut files = Vec::new();
        files_under(w.tmp.path(), &skip, &mut files);
        assert!(!files.is_empty(), "the daemon wrote at least its id store");
        for path in files {
            let Ok(bytes) = std::fs::read(&path) else { continue };
            let text = String::from_utf8_lossy(&bytes);
            for needle in &forbidden {
                assert!(!text.contains(needle.as_str()), "{needle:?} leaked into {}", path.display());
            }
        }
    });
}

// ═════════════════════════════════════════════════════════════════════════════════
// 15-16. the credential probe: the Keychain is only ever looked at, never read
// ═════════════════════════════════════════════════════════════════════════════════

/// The system tool's path, built at run time so that this file does not name it.
fn security_program() -> String {
    format!("{}/{}", "/usr/bin", "security")
}

fn rust_files_under(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_files_under(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_test_names_the_system_security_tool() {
    let needles = [
        security_program(),
        format!("Command::new(\"{}\")", "security"),
        format!("Command::new(\"{}/{}\")", "/usr/bin", "security"),
    ];
    let mut files = Vec::new();
    rust_files_under(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests"), &mut files);
    assert!(files.len() > 20, "found the tests directory");
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        for needle in &needles {
            assert!(!text.contains(needle.as_str()), "{} runs or names the security tool", file.display());
        }
    }
}

#[test]
fn the_probe_runs_the_one_program_with_attribute_only_arguments() {
    assert_eq!(SECURITY_PROGRAM, security_program());
    assert_eq!(SECURITY_ARGS, ["find-generic-password", "-s", "Claude Code-credentials"]);
    for forbidden in ["-g", "-w", "-a"] {
        assert!(!SECURITY_ARGS.contains(&forbidden), "{forbidden} would print the secret or the account");
    }
    for arg in SECURITY_ARGS {
        assert!(!arg.to_lowercase().contains("dump"), "{arg}");
    }
}

/// Synthetic output of the attribute lookup (no secret in it; the creation date is a decoy).
fn security_output() -> String {
    [
        "keychain: \"/Users/someone/Library/Keychains/login.keychain-db\"",
        "version: 512",
        "class: \"genp\"",
        "attributes:",
        "    0x00000007 <blob>=\"Claude Code-credentials\"",
        "    0x00000008 <blob>=<NULL>",
        "    \"acct\"<blob>=\"x\"",
        "    \"cdat\"<timedate>=0x32303235303130313030303030305A00  \"20250101000000Z\\000\"",
        "    \"crtr\"<uint32>=<NULL>",
        "    \"desc\"<blob>=<NULL>",
        "    \"mdat\"<timedate>=0x32303236313031383230303431385A00  \"20261018200418Z\\000\"",
        "    \"svce\"<blob>=\"Claude Code-credentials\"",
        "    \"type\"<uint32>=<NULL>",
    ]
    .join("\n")
        + "\n"
}

#[test]
fn parse_mdat_keeps_only_the_modification_date() {
    assert_eq!(parse_mdat(&security_output()), Some("20261018200418Z".to_string()));
}

#[test]
fn parse_mdat_does_not_depend_on_where_the_line_is() {
    let only = "    \"mdat\"<timedate>=0x00  \"20261018200418Z\\000\"\n";
    assert_eq!(parse_mdat(only), Some("20261018200418Z".to_string()));
    let first = format!("{only}    \"acct\"<blob>=\"x\"\n    \"svce\"<blob>=\"Claude Code-credentials\"\n");
    assert_eq!(parse_mdat(&first), Some("20261018200418Z".to_string()));
}

#[test]
fn parse_mdat_tolerates_crlf_line_ends() {
    let crlf = security_output().replace('\n', "\r\n");
    assert_eq!(parse_mdat(&crlf), Some("20261018200418Z".to_string()));
}

#[test]
fn parse_mdat_gives_nothing_without_a_usable_modification_date() {
    assert_eq!(parse_mdat(""), None);
    assert_eq!(parse_mdat("   \n\n"), None);
    let without = security_output().lines().filter(|l| !l.contains("mdat")).collect::<Vec<_>>().join("\n");
    assert_eq!(parse_mdat(&without), None, "the creation date is not the modification date");
    assert_eq!(parse_mdat("    \"mdat\"<timedate>=<NULL>\n"), None);
    assert_eq!(parse_mdat("    \"mdat\"<timedate>=0x00  \"\"\n"), None);
    assert_eq!(parse_mdat("    \"mdat\"<timedate>=0x00  \"\\000\"\n"), None);
    assert_eq!(parse_mdat("    \"mdat\"<timedate>=garbage\n"), None);
    assert_eq!(parse_mdat("security: SecKeychainSearchCopyNext: The specified item could not be found.\n"), None);
}
