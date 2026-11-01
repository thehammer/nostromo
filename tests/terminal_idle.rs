//! Terminal pane slice 2e: a remote (ECS) shell that nobody types into closes.
//!
//! The rule, from the operator's side:
//!
//! * With no keystrokes for 13 minutes the pane warns: its `terminal_state`
//!   carries `idle_closes_at` (the last keystroke plus 15 minutes) and the
//!   audit trail gets `idle_warning`.
//! * At 15 minutes without keystrokes the shell closes: `idle_closed`, then
//!   `closed {reason: "idle_timeout"}`, and a `terminal_closed` with that
//!   reason goes to the app.
//! * Only the operator app's keystrokes (`terminal_input`) and its Keep open
//!   button (`terminal_keep_alive`) start the clock again. Output from the
//!   shell, a resize, an attach, and anything from another local process or a
//!   network peer do not. After a warning, either one clears `idle_closes_at`
//!   (a `terminal_state` without it) and audits `idle_kept_open` with `via`.
//! * Local terminals are exempt.
//! * The audit trail records all of it by code and never what was typed.
//!
//! The real waits are 13 and 15 minutes, so each test runs the daemon on a
//! paused tokio clock, frozen once the shell is up. Nothing here awaits real
//! IO while the clock is frozen in a way that lets the runtime go idle (an idle
//! runtime on a paused clock jumps to the next timer): the test advances the
//! clock itself, one second at a time, and polls the daemon with yields and
//! short real sleeps. So "nothing earlier" and "at 13:00" are asserted against
//! the virtual clock, to within the daemon's one-second idle tick.
//!
//! Hermetic: the shell is `/bin/cat` behind the fake launcher (or, for the
//! output test, `tests/fixtures/fake-aws` in `spam` mode behind the real
//! launcher); nothing touches AWS, the network, `~/.claude`, `~/.nostromo` or
//! `~/.mother`. A watchdog ends the run if a test wedges.

mod remote_shell_support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chrono::{DateTime, Utc};
use nostromo::ipc::protocol::{
    ClientMsg, ServerMsg, TerminalClosedInfo, TerminalInfo, TerminalKind, TerminalStatus,
};
use nostromo::terminal::ecs::aws::AwsCliSource;
use nostromo::terminal::ecs::AwsEcsLauncher;
use nostromo::terminal::TerminalManager;
use remote_shell_support::*;
use serde_json::Value;
use tempfile::TempDir;

const MINUTE: Duration = Duration::from_secs(60);
const SECOND: Duration = Duration::from_secs(1);
/// Warn after this long without keystrokes, close after [`CLOSE`].
const WARN: Duration = Duration::from_secs(13 * 60);
const CLOSE: Duration = Duration::from_secs(15 * 60);
/// The daemon looks once a second, and a step of ours is a second.
const SLACK: Duration = Duration::from_secs(2);
const CANARY: &str = "CANARY-d41a7c";

// ── the shell ────────────────────────────────────────────────────────────────

/// Open the usual remote shell through the request flow (the app answers
/// Connect); its terminal id.
async fn open_remote(s: &mut Scene) -> String {
    let (call, confirm) = s.ask(args()).await;
    s.app.answer(&confirm.request_id, "connect").await;
    let res = s.mcp.finish(call).await;
    assert_eq!(res["ok"], true, "{res}");
    res["terminal_id"]
        .as_str()
        .expect("terminal_id")
        .to_string()
}

/// Open a local shell for the app in a fresh canonical temp dir.
async fn open_local(s: &mut Scene) -> (TempDir, String) {
    let dir = TempDir::new().expect("tempdir");
    let cwd: PathBuf = std::fs::canonicalize(dir.path()).expect("canonicalize");
    let from = s.app.mark();
    s.app
        .send(&ClientMsg::TerminalOpenLocal {
            tag: TAG.into(),
            relative_to: None,
            position: None,
            cwd: Some(cwd.to_string_lossy().into_owned()),
            client_request_id: "local-1".into(),
        })
        .await;
    let (_, state) = s
        .app
        .wait_since(from, "the local terminal's state", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.opened_by_request.as_deref() == Some("local-1"))
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert_eq!(terminal.kind, TerminalKind::Local);
    (dir, terminal.terminal_id)
}

async fn attach(app: &mut Unix, terminal_id: &str) {
    let from = app.mark();
    app.send(&ClientMsg::TerminalAttach {
        terminal_id: terminal_id.into(),
    })
    .await;
    wait_frame(
        app,
        from,
        "the terminal_replay",
        |m| matches!(m, ServerMsg::TerminalReplay { terminal_id: id, .. } if id == terminal_id),
    )
    .await;
}

// ── talking to the daemon on a frozen clock ──────────────────────────────────

/// Read what has arrived for `c` without ever letting the runtime go idle.
async fn drain(c: &mut Unix) {
    while c.pump(Duration::ZERO).await {}
}

/// Wait (in real time, on a frozen clock) for a frame at or after log index
/// `from` that `pred` accepts.
async fn wait_frame<S>(
    c: &mut Client<S>,
    from: usize,
    what: &str,
    pred: impl Fn(&ServerMsg) -> bool,
) -> (usize, ServerMsg)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut i = from;
    loop {
        while c.pump(Duration::ZERO).await {}
        while i < c.log.len() {
            if pred(&c.log[i]) {
                return (i, c.log[i].clone());
            }
            i += 1;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}; frames seen: [{}]",
            c.summary()
        );
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

/// Ping and wait for the Pong: the daemon has handled everything this
/// connection sent before it.
async fn sync<S>(c: &mut Client<S>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let from = c.mark();
    c.send(&ClientMsg::Ping).await;
    wait_frame(c, from, "a Pong", |m| matches!(m, ServerMsg::Pong)).await;
}

async fn type_line(app: &mut Unix, terminal_id: &str, line: &str) {
    app.send(&ClientMsg::TerminalInput {
        terminal_id: terminal_id.into(),
        bytes: B64.encode(format!("{line}\r")),
        auto_reply: false,
        via: None,
    })
    .await;
}

/// What a terminal emulator answers a remote program's `ESC[6n` with: a cursor
/// position report. The app marks it `auto_reply`; it is not a person typing.
const CURSOR_REPORT: &[u8] = b"\x1b[24;80R";

async fn auto_reply<S>(c: &mut Client<S>, terminal_id: &str, bytes: &[u8])
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    c.send(&ClientMsg::TerminalInput {
        terminal_id: terminal_id.into(),
        bytes: B64.encode(bytes),
        auto_reply: true,
        via: None,
    })
    .await;
}

async fn keep_open<S>(c: &mut Client<S>, terminal_id: &str)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    c.send(&ClientMsg::TerminalKeepAlive {
        terminal_id: terminal_id.into(),
    })
    .await;
}

/// The frozen clock: virtual time since it stopped.
struct Vt {
    start: tokio::time::Instant,
}

impl Vt {
    fn now(&self) -> Duration {
        tokio::time::Instant::now() - self.start
    }

    /// Move the clock on by `d` and let the daemon's tasks react.
    async fn step(&self, d: Duration) {
        tokio::time::advance(d).await;
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
    }

    async fn run_to(&self, target: Duration) {
        while self.now() < target {
            self.step(SECOND.min(target - self.now())).await;
        }
    }
}

// ── a running remote shell on a frozen clock ─────────────────────────────────

/// What else a test needs connected before the clock stops.
#[derive(Default, Clone, Copy)]
struct Extras {
    script: bool,
    tcp: bool,
    local: bool,
}

struct Idle {
    s: Scene,
    /// The remote shell.
    id: String,
    /// A local shell, if asked for.
    local_id: Option<String>,
    script: Option<Unix>,
    tcp: Option<Tcp>,
    vt: Vt,
    /// Virtual time of the keystroke that started the idle clock.
    t0: Duration,
    /// The wall clock just before and just after that keystroke.
    wall: (DateTime<Utc>, DateTime<Utc>),
    _local_dir: Option<TempDir>,
    _watchdog: Watchdog,
}

impl Idle {
    /// A remote shell on the fake launcher, the app attached, the clock frozen,
    /// the idle monitor running, and one keystroke typed to start the clock.
    async fn start(extras: Extras) -> Idle {
        let mut s = Scene::start_with(Options::new(&[Peer::App, Peer::Script])).await;
        let id = open_remote(&mut s).await;
        Self::begin(s, id, extras, true).await
    }

    /// `pin`: type a keystroke after the clock stops, so the idle clock starts
    /// at a known instant (otherwise it started when the shell did).
    async fn begin(mut s: Scene, id: String, extras: Extras, pin: bool) -> Idle {
        let watchdog = Watchdog::arm(180);
        attach(&mut s.app, &id).await;
        let (local_dir, local_id) = if extras.local {
            let (dir, local) = open_local(&mut s).await;
            (Some(dir), Some(local))
        } else {
            (None, None)
        };
        let script = if extras.script {
            Some(s.d.script(vec![], &[]).await)
        } else {
            None
        };
        let tcp = if extras.tcp {
            Some(s.d.tcp(vec![], false).await)
        } else {
            None
        };

        // Freeze the clock now that every real wait is over, then run the monitor.
        tokio::time::pause();
        let vt = Vt {
            start: tokio::time::Instant::now(),
        };
        TerminalManager::start_idle_monitor(&s.d.terminals);
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }

        let w0 = Utc::now();
        if pin {
            type_line(&mut s.app, &id, "start").await;
            sync(&mut s.app).await;
        }
        let w1 = Utc::now();
        let t0 = vt.now();
        Idle {
            s,
            id,
            local_id,
            script,
            tcp,
            vt,
            t0,
            wall: (w0, w1),
            _local_dir: local_dir,
            _watchdog: watchdog,
        }
    }

    // ── what the daemon holds ────────────────────────────────────────────────

    fn info(&self) -> Option<TerminalInfo> {
        self.s.d.info(&self.id)
    }

    fn closes_at(&self) -> Option<DateTime<Utc>> {
        self.info().and_then(|i| i.idle_closes_at)
    }

    fn warned(&self) -> bool {
        self.closes_at().is_some()
    }

    fn open(&self) -> bool {
        self.info().is_some()
    }

    /// Advance a second at a time until the shell is warned; the virtual time
    /// at which that was first seen. Fails if it takes past `limit`.
    async fn until_warned(&self, limit: Duration) -> Duration {
        while !self.warned() {
            assert!(
                self.open(),
                "the shell closed at {:?} without a warning",
                self.vt.now()
            );
            assert!(
                self.vt.now() < limit,
                "no idle warning by {limit:?} (now {:?})",
                self.vt.now()
            );
            self.vt.step(SECOND).await;
        }
        self.vt.now()
    }

    /// Advance a second at a time until the shell is gone; the virtual time at
    /// which that was first seen.
    async fn until_closed(&self, limit: Duration) -> Duration {
        while self.open() {
            assert!(
                self.vt.now() < limit,
                "the shell was still open at {:?} (limit {limit:?}); warned: {}",
                self.vt.now(),
                self.warned()
            );
            self.vt.step(SECOND).await;
        }
        self.vt.now()
    }

    // ── the audit trail ──────────────────────────────────────────────────────

    /// This terminal's idle-related audit lines, in order.
    fn idle_audit(&self) -> Vec<Value> {
        self.s
            .d
            .audit()
            .into_iter()
            .filter(|l| l["terminal_id"] == self.id.as_str())
            .filter(|l| {
                matches!(
                    l["event"].as_str(),
                    Some("idle_warning" | "idle_kept_open" | "idle_closed" | "closed")
                )
            })
            .collect()
    }

    fn idle_audit_names(&self) -> Vec<String> {
        self.idle_audit()
            .iter()
            .map(|l| l["event"].as_str().unwrap_or_default().to_string())
            .collect()
    }

    // ── what the app was told ────────────────────────────────────────────────

    /// The `terminal_state` frames for the remote shell since `from`, as
    /// `idle_closes_at`.
    fn app_states_since(&self, from: usize) -> Vec<Option<DateTime<Utc>>> {
        self.s.app.log[from..]
            .iter()
            .filter_map(|m| match m {
                ServerMsg::TerminalState { terminal } if terminal.terminal_id == self.id => {
                    Some(terminal.idle_closes_at)
                }
                _ => None,
            })
            .collect()
    }

    async fn wait_app_state(
        &mut self,
        from: usize,
        what: &str,
        pred: impl Fn(Option<DateTime<Utc>>) -> bool,
    ) -> DateTime<Utc> {
        let id = self.id.clone();
        let (_, m) = wait_frame(&mut self.s.app, from, what, |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == id && pred(terminal.idle_closes_at))
        })
        .await;
        match m {
            ServerMsg::TerminalState { terminal } => {
                terminal.idle_closes_at.unwrap_or(DateTime::<Utc>::MIN_UTC)
            }
            _ => unreachable!(),
        }
    }

    async fn wait_app_closed(&mut self, from: usize) -> TerminalClosedInfo {
        let id = self.id.clone();
        let (_, m) = wait_frame(
            &mut self.s.app,
            from,
            "a terminal_closed",
            |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == id),
        )
        .await;
        match m {
            ServerMsg::TerminalClosed(c) => c,
            _ => unreachable!(),
        }
    }

    /// The app has been sent no `terminal_closed` for the remote shell.
    fn app_closed_frames(&self) -> usize {
        self.s
            .app
            .log
            .iter()
            .filter(|m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == self.id))
            .count()
    }
}

/// `actual` is at `expected` or up to [`SLACK`] after it.
fn assert_at(what: &str, actual: Duration, expected: Duration) {
    assert!(
        actual >= expected,
        "{what}: happened at {actual:?}, before {expected:?}"
    );
    assert!(
        actual <= expected + SLACK,
        "{what}: happened at {actual:?}, well after {expected:?}"
    );
}

fn parse_ts(line: &Value, key: &str) -> DateTime<Utc> {
    let raw = line[key]
        .as_str()
        .unwrap_or_else(|| panic!("no {key} in {line}"));
    DateTime::parse_from_rfc3339(raw)
        .unwrap_or_else(|e| panic!("{key} {raw:?} is not a timestamp: {e}"))
        .with_timezone(&Utc)
}

// ═════════════════════════════════════════════════════════════════════════════
// Warning and closing
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn an_unattended_remote_shell_warns_at_13_minutes_and_closes_at_15_and_not_before() {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    let (w0, w1) = i.wall;
    let from = i.s.app.mark();

    // Twelve minutes and 58 seconds in: nothing has happened.
    i.vt.run_to(t0 + WARN - SLACK).await;
    assert!(i.open(), "closed early");
    assert!(!i.warned(), "warned early");
    drain(&mut i.s.app).await;
    assert!(
        i.app_states_since(from).is_empty(),
        "no terminal_state before the warning"
    );
    assert!(
        i.idle_audit().is_empty(),
        "nothing audited before the warning: {:?}",
        i.idle_audit()
    );

    // The warning comes at 13:00.
    let warned_at = i.until_warned(t0 + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, t0 + WARN);
    // It says when the shell closes: the last keystroke plus 15 minutes.
    let closes_at = i.closes_at().expect("warned");
    let fifteen = chrono::Duration::from_std(CLOSE).unwrap();
    let slack = chrono::Duration::seconds(1);
    assert!(
        closes_at >= w0 + fifteen - slack && closes_at <= w1 + fifteen + slack,
        "idle_closes_at {closes_at} is not the keystroke ({w0} .. {w1}) plus 15 minutes"
    );
    // It says how long without keystrokes brought the warning, so the banner never hardcodes it.
    assert_eq!(
        i.info().and_then(|t| t.idle_warn_after_secs),
        Some(WARN.as_secs()),
        "idle_warn_after_secs is the warn threshold"
    );
    // The app is told, with the same time; the shell is still running.
    let told = i
        .wait_app_state(from, "the warning terminal_state", |c| c.is_some())
        .await;
    assert_eq!(told, closes_at);
    assert_eq!(
        i.info().map(|t| t.status),
        Some(TerminalStatus::Running),
        "a warned shell keeps running"
    );
    // The warning is audited once, with the same time.
    let audit = i.idle_audit();
    assert_eq!(i.idle_audit_names(), ["idle_warning"], "{audit:?}");
    assert_eq!(audit[0]["kind"], "ecs", "{}", audit[0]);
    assert_eq!(parse_ts(&audit[0], "closes_at"), closes_at);

    // Still open a moment before 15:00: only the one warning, no close.
    i.vt.run_to(t0 + CLOSE - SLACK).await;
    assert!(i.open(), "closed early");
    drain(&mut i.s.app).await;
    assert_eq!(i.app_closed_frames(), 0);
    assert_eq!(
        i.app_states_since(from).len(),
        1,
        "the warning is sent once, not every second"
    );
    assert_eq!(i.idle_audit_names(), ["idle_warning"]);

    // At 15:00 it closes, and the app is told why.
    let closed_at = i.until_closed(t0 + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, t0 + CLOSE);
    let closed = i.wait_app_closed(from).await;
    assert_eq!(closed.reason, "idle_timeout", "{closed:?}");
    assert_eq!(closed.kind, TerminalKind::Ecs);
    assert_eq!(closed.tag, TAG);
    assert_eq!(closed.target, Some(canonical_target()));
    assert!(i.s.d.list().is_empty(), "{:?}", i.s.d.list());
    assert!(
        i.s.d.leaves(TAG).is_empty(),
        "the pane is gone with the shell"
    );
    // idle_closed, then the closed line with the same reason code.
    let audit = i.idle_audit();
    assert_eq!(
        i.idle_audit_names(),
        ["idle_warning", "idle_closed", "closed"],
        "{audit:?}"
    );
    assert_eq!(audit[2]["reason"], "idle_timeout", "{}", audit[2]);
    assert_eq!(audit[2]["kind"], "ecs", "{}", audit[2]);
}

#[tokio::test]
async fn an_unattended_shell_that_was_never_typed_into_still_closes() {
    // No keystroke at all: the clock runs from when the shell began.
    let mut s = Scene::start_with(Options::new(&[Peer::App])).await;
    let before = Instant::now();
    let id = open_remote(&mut s).await;
    let i = Idle::begin(s, id, Extras::default(), false).await;
    let age = before.elapsed();

    let warned_at = i.until_warned(WARN + SLACK).await;
    let closed_at = i.until_closed(CLOSE + SLACK).await;

    // The clock began a moment (real time) before the freeze.
    assert!(
        warned_at + age + SLACK >= WARN && warned_at <= WARN + SLACK,
        "warned at {warned_at:?}"
    );
    assert!(
        closed_at + age + SLACK >= CLOSE && closed_at <= CLOSE + SLACK,
        "closed at {closed_at:?}"
    );
}

#[tokio::test]
async fn only_remote_shells_idle_out_a_local_shell_is_exempt() {
    let mut i = Idle::start(Extras {
        local: true,
        ..Extras::default()
    })
    .await;
    let local = i.local_id.clone().expect("a local shell");
    let t0 = i.t0;
    let from = i.s.app.mark();

    // The remote shell goes at 15:00 ...
    i.until_closed(t0 + CLOSE + SLACK * 2).await;
    // ... and the local one is still there half an hour after its last keystroke.
    i.vt.run_to(t0 + 2 * CLOSE + MINUTE).await;
    drain(&mut i.s.app).await;

    let info = i.s.d.info(&local).expect("the local shell is still open");
    assert_eq!(info.status, TerminalStatus::Running);
    assert_eq!(info.idle_closes_at, None, "a local shell is never warned");
    for m in &i.s.app.log[from..] {
        match m {
            ServerMsg::TerminalState { terminal } if terminal.terminal_id == local => {
                assert_eq!(terminal.idle_closes_at, None, "{terminal:?}");
            }
            ServerMsg::TerminalClosed(c) if c.terminal_id == local => {
                panic!("the local shell was closed: {c:?}")
            }
            _ => {}
        }
    }
    assert!(
        i.s.d
            .audit()
            .iter()
            .filter(|l| l["terminal_id"] == local.as_str())
            .all(|l| !matches!(
                l["event"].as_str(),
                Some("idle_warning" | "idle_kept_open" | "idle_closed" | "closed")
            )),
        "no idle line for a local shell: {:?}",
        i.s.d.audit()
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// What does and does not count as activity
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_shell_that_keeps_printing_still_warns_and_closes_on_schedule() {
    // The shell's own output is not the operator's attention: a runaway
    // process in a forgotten production shell must not keep it open. (The
    // real launcher and the fake `aws` in `spam` mode: one line a millisecond.)
    let work = TempDir::new().expect("tempdir");
    let wrapper = work.path().join("aws");
    write_exec(
        &wrapper,
        &format!(
            "#!/bin/sh\n[ \"$1\" = \"--wrapper-probe\" ] && exit 0\nFAKE_AWS_MODE='spam' exec '{}' \"$@\"\n",
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/fake-aws")
                .display()
        ),
    );
    let mut opts = Options::new(&[Peer::App]);
    opts.fake_launcher = false;
    let mut s = Scene::start_with(opts).await;
    let launcher = AwsEcsLauncher::new(&s.d.terminals, AwsCliSource::only(&wrapper));
    s.d.terminals.lock().unwrap().set_remote_launcher(launcher);
    let before = Instant::now();
    let id = open_remote(&mut s).await;
    let mut i = Idle::begin(s, id, Extras::default(), false).await;
    let age = before.elapsed();
    let from = i.s.app.mark();

    // Minute by minute, output keeps arriving until the warning.
    let mut seen_before = 0usize;
    let mut minute = 1u32;
    while !i.warned() {
        let minute_end = MINUTE * minute;
        while i.vt.now() < minute_end && !i.warned() {
            assert!(i.open(), "the shell closed before it was warned");
            i.vt.step(SECOND).await;
            std::thread::sleep(Duration::from_millis(3));
            drain(&mut i.s.app).await;
        }
        let seen = output_frames(&i.s.app.log, &i.id);
        if !i.warned() {
            assert!(
                seen > seen_before,
                "the shell stopped printing in the minute ending {minute_end:?}"
            );
        }
        seen_before = seen;
        minute += 1;
    }
    let warned_at = i.vt.now();
    assert!(
        warned_at + age + SLACK >= WARN && warned_at <= WARN + SLACK,
        "warned at {warned_at:?} (the clock began {age:?} of real time before the freeze)"
    );

    // Two more minutes of output, and then it closes, mid-stream.
    let printing_at_warning = output_frames(&i.s.app.log, &i.id);
    while i.open() {
        assert!(
            i.vt.now() < CLOSE + SLACK * 2,
            "still open at {:?}",
            i.vt.now()
        );
        i.vt.step(SECOND).await;
        std::thread::sleep(Duration::from_millis(3));
        drain(&mut i.s.app).await;
    }
    let closed_at = i.vt.now();
    assert!(
        output_frames(&i.s.app.log, &i.id) > printing_at_warning,
        "the shell was still printing while it was warned"
    );
    assert!(
        closed_at + age + SLACK >= CLOSE && closed_at <= CLOSE + SLACK,
        "closed at {closed_at:?}"
    );
    assert!(
        closed_at - warned_at + SLACK >= 2 * MINUTE && closed_at - warned_at <= 2 * MINUTE + SLACK,
        "the warning gives the full two minutes: warned {warned_at:?}, closed {closed_at:?}"
    );
    let closed = i.wait_app_closed(from).await;
    assert_eq!(closed.reason, "idle_timeout", "{closed:?}");
}

fn output_frames(log: &[ServerMsg], terminal_id: &str) -> usize {
    log.iter()
        .filter(
            |m| matches!(m, ServerMsg::TerminalOutput { terminal_id: id, .. } if id == terminal_id),
        )
        .count()
}

#[tokio::test]
async fn resizing_and_attaching_do_not_restart_the_idle_clock() {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    i.vt.run_to(t0 + 12 * MINUTE).await;

    // The user looks at the pane (a fresh attach) and resizes the window.
    let id = i.id.clone();
    i.s.app
        .send(&ClientMsg::TerminalResize {
            terminal_id: id.clone(),
            cols: 100,
            rows: 30,
        })
        .await;
    attach(&mut i.s.app, &id).await;
    sync(&mut i.s.app).await;
    assert_eq!(
        i.info().map(|t| (t.cols, t.rows)),
        Some((100, 30)),
        "the resize took effect"
    );

    // The warning still comes 13 minutes after the last keystroke, not the resize.
    assert!(!i.warned());
    let warned_at = i.until_warned(t0 + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, t0 + WARN);
    let closed_at = i.until_closed(t0 + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, t0 + CLOSE);
}

#[tokio::test]
async fn a_keystroke_before_the_warning_quietly_restarts_the_clock() {
    let mut i = Idle::start(Extras::default()).await;
    i.vt.run_to(i.t0 + 10 * MINUTE).await;
    let typed_at = i.vt.now();
    let id = i.id.clone();

    type_line(&mut i.s.app, &id, "ls").await;
    sync(&mut i.s.app).await;

    // Past the original 13 minutes and 15 minutes: nothing.
    i.vt.run_to(typed_at + WARN - SLACK).await;
    assert!(i.open() && !i.warned(), "the keystroke restarted the clock");
    assert!(
        i.idle_audit().is_empty(),
        "no warning, so nothing to keep open: {:?}",
        i.idle_audit()
    );
    // The full 13 and 15 minutes run from the keystroke.
    let warned_at = i.until_warned(typed_at + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, typed_at + WARN);
    let closed_at = i.until_closed(typed_at + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, typed_at + CLOSE);
}

/// A remote program can print `ESC[6n` forever and the app's terminal answers
/// each time. Those answers are written to the shell but are not keystrokes.
#[tokio::test]
async fn auto_replies_do_not_restart_the_clock_before_the_warning() {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    let id = i.id.clone();

    // One reply a minute for the first 12 minutes.
    for minute in 1..=12u32 {
        i.vt.run_to(t0 + MINUTE * minute).await;
        auto_reply(&mut i.s.app, &id, CURSOR_REPORT).await;
        sync(&mut i.s.app).await;
    }
    assert!(i.open() && !i.warned());

    // The warning and the close still come on the keystroke's schedule.
    let warned_at = i.until_warned(t0 + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, t0 + WARN);
    let closed_at = i.until_closed(t0 + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, t0 + CLOSE);
}

#[tokio::test]
async fn auto_replies_do_not_withdraw_the_warning_but_a_keystroke_does() {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    let id = i.id.clone();
    let from = i.s.app.mark();
    i.until_warned(t0 + WARN + SLACK * 2).await;
    i.wait_app_state(from, "the warning", |c| c.is_some()).await;
    let closes_at = i.closes_at();
    let after_warning = i.s.app.mark();

    i.vt.run_to(t0 + CLOSE - 2 * MINUTE).await;
    auto_reply(&mut i.s.app, &id, CURSOR_REPORT).await;
    sync(&mut i.s.app).await;
    assert_eq!(
        i.closes_at(),
        closes_at,
        "a reply must not clear idle_closes_at"
    );
    assert_eq!(i.idle_audit_names(), ["idle_warning"]);
    drain(&mut i.s.app).await;
    assert!(
        i.s.app.log[after_warning..].iter().all(|m| !matches!(
            m,
            ServerMsg::TerminalState { terminal } if terminal.idle_closes_at.is_none()
        )),
        "no terminal_state withdrawing the warning: [{}]",
        i.s.app.summary()
    );

    // A person's keystroke a minute later does.
    i.vt.run_to(t0 + CLOSE - MINUTE).await;
    type_line(&mut i.s.app, &id, "still here").await;
    sync(&mut i.s.app).await;
    assert!(!i.warned(), "a keystroke withdraws the warning");
    assert_eq!(i.idle_audit_names(), ["idle_warning", "idle_kept_open"]);
}

#[tokio::test]
async fn an_auto_reply_still_reaches_the_shell() {
    let mut i = Idle::start(Extras::default()).await;
    let id = i.id.clone();
    let from = i.s.app.mark();
    // `cat` echoes what the pty is given: the reply must have been written.
    auto_reply(&mut i.s.app, &id, b"REPLY-7f3a\r").await;
    sync(&mut i.s.app).await;
    wait_frame(&mut i.s.app, from, "the echoed reply", |m| {
        matches!(m, ServerMsg::TerminalOutput { bytes, .. }
            if B64.decode(bytes).map(|b| String::from_utf8_lossy(&b).contains("REPLY-7f3a")).unwrap_or(false))
    })
    .await;
}

#[tokio::test]
async fn keep_open_before_the_warning_quietly_restarts_the_clock() {
    let mut i = Idle::start(Extras::default()).await;
    i.vt.run_to(i.t0 + 10 * MINUTE).await;
    let pressed_at = i.vt.now();
    let id = i.id.clone();

    keep_open(&mut i.s.app, &id).await;
    sync(&mut i.s.app).await;

    i.vt.run_to(pressed_at + WARN - SLACK).await;
    assert!(i.open() && !i.warned(), "keep open restarted the clock");
    assert!(i.idle_audit().is_empty(), "{:?}", i.idle_audit());
    let warned_at = i.until_warned(pressed_at + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, pressed_at + WARN);
    let closed_at = i.until_closed(pressed_at + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, pressed_at + CLOSE);
}

// ═════════════════════════════════════════════════════════════════════════════
// Keeping a warned shell open
// ═════════════════════════════════════════════════════════════════════════════

/// After a warning, `how` keeps the shell open: the warning is withdrawn, the
/// app told, the keep audited with `via`, and the full 15 minutes start again.
async fn assert_keeps_open_after_warning(how: &str, via: &str) {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    let from = i.s.app.mark();
    i.until_warned(t0 + WARN + SLACK * 2).await;
    i.wait_app_state(from, "the warning", |c| c.is_some()).await;
    let after_warning = i.s.app.mark();
    // Wait out most of the warning window, then act with a minute to go.
    i.vt.run_to(t0 + CLOSE - MINUTE).await;
    let acted_at = i.vt.now();
    let w0 = Utc::now();
    let id = i.id.clone();

    match how {
        "keystroke" => type_line(&mut i.s.app, &id, "still here").await,
        "keep_alive" => keep_open(&mut i.s.app, &id).await,
        other => panic!("unknown way to keep a shell open: {other}"),
    }
    sync(&mut i.s.app).await;

    // The warning is withdrawn, in the daemon and for the app.
    assert!(!i.warned(), "idle_closes_at must clear");
    i.wait_app_state(
        after_warning,
        "a terminal_state without idle_closes_at",
        |c| c.is_none(),
    )
    .await;
    let audit = i.idle_audit();
    assert_eq!(
        i.idle_audit_names(),
        ["idle_warning", "idle_kept_open"],
        "{audit:?}"
    );
    assert_eq!(audit[1]["via"], via, "{}", audit[1]);

    // The original close time passes: still open.
    i.vt.run_to(t0 + CLOSE + 2 * MINUTE).await;
    assert!(i.open(), "closed at the old time after being kept open");
    drain(&mut i.s.app).await;
    assert_eq!(i.app_closed_frames(), 0);

    // The full cycle runs again from the keep: warning at +13, close at +15.
    i.vt.run_to(acted_at + WARN - SLACK).await;
    assert!(
        i.open() && !i.warned(),
        "warned early after being kept open"
    );
    let warned_at = i.until_warned(acted_at + WARN + SLACK * 2).await;
    assert_at("the second warning", warned_at, acted_at + WARN);
    let second = i.closes_at().expect("warned again");
    let fifteen = chrono::Duration::from_std(CLOSE).unwrap();
    assert!(
        second >= w0 + fifteen - chrono::Duration::seconds(1)
            && second <= Utc::now() + fifteen + chrono::Duration::seconds(1),
        "the second idle_closes_at {second} is 15 minutes after the keep, not the first keystroke"
    );
    let closed_at = i.until_closed(acted_at + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, acted_at + CLOSE);
}

#[tokio::test]
async fn typing_after_the_warning_keeps_the_shell_open_for_another_full_15_minutes() {
    assert_keeps_open_after_warning("keystroke", "keystroke").await;
}

#[tokio::test]
async fn the_keep_open_button_keeps_the_shell_open_for_another_full_15_minutes() {
    assert_keeps_open_after_warning("keep_alive", "button").await;
}

// ═════════════════════════════════════════════════════════════════════════════
// Only the operator app can keep a shell open
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn another_local_process_cannot_keep_a_shell_open() {
    let mut i = Idle::start(Extras {
        script: true,
        ..Extras::default()
    })
    .await;
    let t0 = i.t0;
    let warned_at = i.until_warned(t0 + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, t0 + WARN);
    let closes_at = i.closes_at();
    let id = i.id.clone();
    let mut script = i.script.take().expect("a plain local connection");
    let from = script.mark();

    keep_open(&mut script, &id).await;
    type_line_as(&mut script, &id, CANARY).await;
    sync(&mut script).await;

    // Each is refused, naming the terminal.
    let refusals = script.refusals_since(from);
    assert_eq!(
        refusals,
        vec![
            (
                "keep_alive".to_string(),
                Some(id.clone()),
                "terminal_control_forbidden".to_string()
            ),
            (
                "input".to_string(),
                Some(id.clone()),
                "terminal_input_forbidden".to_string()
            ),
        ],
        "[{}]",
        script.summary()
    );
    // Both are audited as refused over the local channel.
    let lines = i.s.d.refused_lines("ipc");
    let ops: Vec<(&str, &str)> = lines
        .iter()
        .map(|l| {
            (
                l["op"].as_str().unwrap_or_default(),
                l["code"].as_str().unwrap_or_default(),
            )
        })
        .collect();
    assert!(
        ops.contains(&("keep_alive", "terminal_control_forbidden")),
        "{lines:?}"
    );
    assert!(
        lines
            .iter()
            .any(|l| l["op"] == "keep_alive" && l["terminal_id"] == id.as_str()),
        "the refusal names the terminal: {lines:?}"
    );
    // The warning stands and the audit trail has no keep.
    assert_eq!(i.closes_at(), closes_at, "the warning must stand");
    assert_eq!(i.idle_audit_names(), ["idle_warning"]);
    // The clock was not restarted: it closes 15 minutes after the app's keystroke.
    let closed_at = i.until_closed(t0 + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, t0 + CLOSE);
    assert!(
        !i.s.d.audit_text().contains(CANARY),
        "what was typed is never audited"
    );
}

async fn type_line_as<S>(c: &mut Client<S>, terminal_id: &str, line: &str)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    c.send(&ClientMsg::TerminalInput {
        terminal_id: terminal_id.into(),
        bytes: B64.encode(format!("{line}\r")),
        auto_reply: false,
        via: None,
    })
    .await;
}

#[tokio::test]
async fn another_local_process_cannot_keep_a_shell_open_with_auto_replies() {
    let mut i = Idle::start(Extras {
        script: true,
        ..Extras::default()
    })
    .await;
    let t0 = i.t0;
    i.vt.run_to(t0 + 10 * MINUTE).await;
    let id = i.id.clone();
    let mut script = i.script.take().expect("a plain local connection");
    let from = script.mark();

    auto_reply(&mut script, &id, CURSOR_REPORT).await;
    sync(&mut script).await;

    assert_eq!(
        script.refusals_since(from),
        vec![(
            "input".to_string(),
            Some(id.clone()),
            "terminal_input_forbidden".to_string()
        )],
        "[{}]",
        script.summary()
    );
    let warned_at = i.until_warned(t0 + WARN + SLACK * 2).await;
    assert_at("the warning", warned_at, t0 + WARN);
}

#[tokio::test]
async fn a_network_peer_cannot_send_auto_replies() {
    let mut i = Idle::start(Extras {
        tcp: true,
        ..Extras::default()
    })
    .await;
    let id = i.id.clone();
    let mut tcp = i.tcp.take().expect("a tcp connection");
    let from = tcp.mark();

    auto_reply(&mut tcp, &id, CURSOR_REPORT).await;
    sync(&mut tcp).await;

    let errors = tcp.errors_since(from);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].starts_with("requires_secure_connection"),
        "{errors:?}"
    );
    let lines = i.s.d.refused_lines("tcp");
    assert!(lines.iter().any(|l| l["op"] == "input"), "{lines:?}");
}

#[tokio::test]
async fn a_network_peer_cannot_keep_a_shell_open() {
    let mut i = Idle::start(Extras {
        tcp: true,
        ..Extras::default()
    })
    .await;
    let t0 = i.t0;
    i.until_warned(t0 + WARN + SLACK * 2).await;
    let id = i.id.clone();
    let mut tcp = i.tcp.take().expect("a tcp connection");
    let from = tcp.mark();

    keep_open(&mut tcp, &id).await;
    type_line_as(&mut tcp, &id, CANARY).await;
    sync(&mut tcp).await;

    // Refused as every terminal frame is over TCP, and told nothing else.
    let errors = tcp.errors_since(from);
    assert_eq!(errors.len(), 2, "{errors:?}");
    assert!(
        errors
            .iter()
            .all(|e| e.starts_with("requires_secure_connection")),
        "{errors:?}"
    );
    assert!(
        tcp.refusals_since(from).is_empty(),
        "no terminal_refused over tcp"
    );
    let lines = i.s.d.refused_lines("tcp");
    assert!(
        lines.iter().any(|l| l["op"] == "keep_alive"),
        "audited as a refused keep_alive over tcp: {lines:?}"
    );
    assert!(i.warned(), "the warning must stand");
    assert_eq!(i.idle_audit_names(), ["idle_warning"]);
    let closed_at = i.until_closed(t0 + CLOSE + SLACK * 2).await;
    assert_at("the close", closed_at, t0 + CLOSE);
}

// ═════════════════════════════════════════════════════════════════════════════
// The audit trail (criterion 26)
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_audit_trail_tells_the_idle_story_in_order_and_never_holds_what_was_typed() {
    let mut i = Idle::start(Extras::default()).await;
    let t0 = i.t0;
    let id = i.id.clone();
    // Something sensitive typed (and echoed back by the shell) on the way.
    type_line(&mut i.s.app, &id, &format!("echo {CANARY}")).await;
    sync(&mut i.s.app).await;
    let typed_at = i.vt.now();
    assert!(typed_at >= t0);

    // Warned, kept open with the button, idle again, warned, closed.
    i.until_warned(typed_at + WARN + SLACK * 2).await;
    keep_open(&mut i.s.app, &id).await;
    sync(&mut i.s.app).await;
    assert!(!i.warned());
    let kept_at = i.vt.now();
    i.until_warned(kept_at + WARN + SLACK * 2).await;
    i.until_closed(kept_at + CLOSE + SLACK * 2).await;

    let audit = i.idle_audit();
    assert_eq!(
        i.idle_audit_names(),
        [
            "idle_warning",
            "idle_kept_open",
            "idle_warning",
            "idle_closed",
            "closed"
        ],
        "{audit:#?}"
    );
    assert_eq!(audit[1]["via"], "button", "{}", audit[1]);
    assert_eq!(audit[4]["reason"], "idle_timeout", "{}", audit[4]);
    // Each line says which shell it is about.
    for line in &audit {
        assert_eq!(line["tag"], TAG, "{line}");
        assert_eq!(line["pane_id"], audit[0]["pane_id"], "{line}");
    }
    // The second warning's time is later than the first's.
    assert!(
        parse_ts(&audit[2], "closes_at") > parse_ts(&audit[0], "closes_at"),
        "{audit:#?}"
    );
    // Codes and times only: never what was typed or what the shell echoed.
    assert!(
        !i.s.d.audit_text().contains(CANARY),
        "the audit trail holds typed text:\n{}",
        i.s.d.audit_text()
    );
}

// ── the real launcher's shell wrapper ────────────────────────────────────────

/// Write an executable script and make sure the kernel will run it: a script
/// written while another thread forks can be "text file busy" for a moment, so
/// run it once (it answers `--wrapper-probe` first) until it starts.
fn write_exec(path: &Path, body: &str) {
    std::fs::write(path, body).expect("write the wrapper");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    for _ in 0..200 {
        match std::process::Command::new(path)
            .arg("--wrapper-probe")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
        {
            Ok(status) => {
                assert!(status.success(), "the wrapper's probe failed: {status}");
                return;
            }
            Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => {
                std::thread::sleep(Duration::from_millis(20))
            }
            Err(e) => panic!("cannot run the wrapper {}: {e}", path.display()),
        }
    }
    panic!("the wrapper stayed busy");
}
