//! Terminal pane slice 2e: the controlled-restart guard's question to the
//! daemon. `nostromd remote-shells [--json]` connects to the running daemon's
//! socket as an ordinary client and reports which remote (ECS) shells are
//! open, so `make install` and friends can refuse to end them by surprise:
//!
//! * exit 3 with a line per open shell (project, environment, service, age),
//! * exit 0 when no remote shell is open (a local shell does not count),
//! * exit 2 when no daemon is running (no socket, or connection refused),
//! * exit 4 when a daemon is there but gives no usable answer.
//!
//! The same answer is available on the wire as `terminal_remote_summary_request`
//! -> `terminal_remote_summary`: any local process may ask, the reply carries
//! labels, targets and open times only (never what a shell printed or was
//! typed), and a network peer is refused.
//!
//! Hermetic: the daemon is the in-process test harness (temp socket, temp
//! audit file, the fake remote launcher). The binary under test is run with
//! `NOSTROMOD_SOCKET` and `HOME` pointing into temp dirs, so it can never see a
//! real daemon, `~/.nostromo` or `~/.mother`.

mod remote_shell_support;

use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, TerminalStatus};
use remote_shell_support::*;
use serde_json::Value;
use tempfile::TempDir;

/// What `nostromd remote-shells` did.
struct Ran {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl std::fmt::Debug for Ran {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "exit {:?}; stdout {:?}; stderr {:?}",
            self.code, self.stdout, self.stderr
        )
    }
}

/// Run the built `nostromd` with `args`, pointed at `socket` and nothing real.
async fn nostromd(socket: &Path, args: &[&str]) -> Ran {
    let home = TempDir::new().expect("a private HOME");
    let out = tokio::time::timeout(
        Duration::from_secs(60),
        tokio::process::Command::new(env!("CARGO_BIN_EXE_nostromd"))
            .args(args)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", home.path())
            .env("NOSTROMOD_SOCKET", socket)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .expect("nostromd remote-shells did not finish")
    .expect("run nostromd");
    Ran {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

/// Open the usual remote shell (admin-portal, production, scheduler) through
/// the request flow; its terminal id.
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
    assert_eq!(terminal.kind, nostromo::ipc::protocol::TerminalKind::Local);
    (dir, terminal.terminal_id)
}

fn json_of(ran: &Ran) -> Value {
    serde_json::from_str(ran.stdout.trim())
        .unwrap_or_else(|e| panic!("--json printed something that is not JSON ({e}): {ran:?}"))
}

// ═════════════════════════════════════════════════════════════════════════════
// `nostromd remote-shells`
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn an_open_remote_shell_exits_3_and_is_named_with_its_age() {
    let mut s = Scene::start().await;
    open_remote(&mut s).await;

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(3), "{ran:?}");
    let lines: Vec<&str> = ran.stdout.lines().collect();
    assert_eq!(lines.len(), 1, "one line per open shell: {ran:?}");
    let words: Vec<&str> = lines[0].split_whitespace().collect();
    assert_eq!(
        &words[..3],
        ["admin-portal", "production", "scheduler"],
        "project, environment, service: {ran:?}"
    );
    assert!(
        lines[0].contains("open"),
        "the line says how long it has been open: {ran:?}"
    );
    let age = lines[0]
        .split("open ")
        .nth(1)
        .and_then(|rest| rest.split(')').next())
        .unwrap_or_default();
    assert!(
        age.chars().next().is_some_and(|c| c.is_ascii_digit()) && age.ends_with(['s', 'm']),
        "a shell opened a moment ago has an age in seconds or minutes, got {age:?}: {ran:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn each_open_remote_shell_gets_its_own_line() {
    let mut s = Scene::start().await;
    open_remote(&mut s).await;
    open_remote(&mut s).await;

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(3), "{ran:?}");
    assert_eq!(ran.stdout.lines().count(), 2, "{ran:?}");
    for line in ran.stdout.lines() {
        assert!(
            line.starts_with("admin-portal production scheduler"),
            "{ran:?}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn json_output_carries_project_environment_service_and_age() {
    let mut s = Scene::start().await;
    let terminal_id = open_remote(&mut s).await;
    let info = s.d.info(&terminal_id).expect("the terminal exists");

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells", "--json"]).await;

    assert_eq!(ran.code, Some(3), "--json keeps the exit code: {ran:?}");
    let v = json_of(&ran);
    let shells = v["shells"].as_array().unwrap_or_else(|| panic!("{ran:?}"));
    assert_eq!(shells.len(), 1, "{ran:?}");
    let shell = &shells[0];
    assert_eq!(shell["project"], "admin-portal", "{ran:?}");
    assert_eq!(shell["environment"], "production", "{ran:?}");
    assert_eq!(shell["service"], "scheduler", "{ran:?}");
    assert_eq!(shell["label"], info.label.as_str(), "{ran:?}");
    let age = shell["age_secs"]
        .as_i64()
        .unwrap_or_else(|| panic!("age_secs is a number: {ran:?}"));
    assert!(
        (0..120).contains(&age),
        "a shell opened a moment ago: {ran:?}"
    );
    let opened_at = shell["opened_at"]
        .as_str()
        .expect("opened_at is a timestamp");
    let opened = chrono::DateTime::parse_from_rfc3339(opened_at)
        .unwrap_or_else(|e| panic!("opened_at {opened_at:?} is not RFC 3339: {e}"));
    let ago = chrono::Utc::now().signed_duration_since(opened);
    assert!(
        ago.num_seconds().abs() < 120,
        "opened_at is when it opened: {opened_at}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn no_open_remote_shell_exits_0_and_says_nothing() {
    let s = Scene::start().await;

    let text = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;
    let json = nostromd(&s.d.ipc_sock, &["remote-shells", "--json"]).await;

    assert_eq!(text.code, Some(0), "{text:?}");
    assert_eq!(text.stdout.trim(), "", "{text:?}");
    assert_eq!(json.code, Some(0), "{json:?}");
    assert_eq!(
        json_of(&json)["shells"].as_array().map(Vec::len),
        Some(0),
        "{json:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_shell_alone_does_not_count_as_a_remote_shell() {
    let mut s = Scene::start().await;
    let (_dir, local_id) = open_local(&mut s).await;
    assert_eq!(
        s.d.info(&local_id).map(|i| i.status),
        Some(TerminalStatus::Running)
    );

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(0), "{ran:?}");
    assert_eq!(ran.stdout.trim(), "", "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_shell_is_not_listed_beside_a_remote_one() {
    let mut s = Scene::start().await;
    let (_dir, _local_id) = open_local(&mut s).await;
    open_remote(&mut s).await;

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(3), "{ran:?}");
    assert_eq!(
        ran.stdout.lines().count(),
        1,
        "only the remote shell: {ran:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shell_that_has_closed_no_longer_counts() {
    let mut s = Scene::start().await;
    let terminal_id = open_remote(&mut s).await;
    let from = s.app.mark();
    s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: terminal_id.clone(),
        })
        .await;
    s.app
        .wait_since(
            from,
            "the close",
            |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == terminal_id),
        )
        .await;

    let ran = nostromd(&s.d.ipc_sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(0), "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn with_no_daemon_at_the_socket_it_exits_2() {
    let dir = TempDir::new().expect("tempdir");

    let missing = nostromd(&dir.path().join("nobody-home.sock"), &["remote-shells"]).await;
    let json = nostromd(
        &dir.path().join("nobody-home.sock"),
        &["remote-shells", "--json"],
    )
    .await;

    assert_eq!(missing.code, Some(2), "{missing:?}");
    assert_eq!(missing.stdout.trim(), "", "{missing:?}");
    assert_eq!(json.code, Some(2), "{json:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stale_socket_file_with_no_daemon_behind_it_exits_2() {
    let dir = TempDir::new().expect("tempdir");
    let sock = dir.path().join("stale.sock");
    drop(std::os::unix::net::UnixListener::bind(&sock).expect("bind"));
    assert!(sock.exists(), "the stale socket file is left behind");

    let ran = nostromd(&sock, &["remote-shells"]).await;

    assert_eq!(ran.code, Some(2), "{ran:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// The wire question behind it
// ═════════════════════════════════════════════════════════════════════════════

const CANARY: &str = "CANARY-5c1e9b";

fn b64(s: &str) -> String {
    B64.encode(s)
}

/// The summary frame the daemon sent `c`, as JSON.
fn summary_frames(log: &[ServerMsg]) -> Vec<Value> {
    log.iter()
        .filter(|m| matches!(m, ServerMsg::TerminalRemoteSummary { .. }))
        .map(|m| serde_json::to_value(m).expect("serialize"))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn any_local_process_is_told_the_open_shells_as_metadata_only() {
    let mut s = Scene::start_with(Options::new(&[Peer::App, Peer::Script])).await;
    let terminal_id = open_remote(&mut s).await;
    // Something typed and something printed: neither may reach the summary.
    s.app
        .send(&ClientMsg::TerminalAttach {
            terminal_id: terminal_id.clone(),
        })
        .await;
    s.app
        .send(&ClientMsg::TerminalInput {
            terminal_id: terminal_id.clone(),
            bytes: b64(&format!("{CANARY}\r")),
            auto_reply: false,
            via: None,
        })
        .await;
    s.app
        .wait_since(0, "the shell to print the canary", |m| match m {
            ServerMsg::TerminalReplay { bytes, .. } | ServerMsg::TerminalOutput { bytes, .. } => {
                B64.decode(bytes)
                    .map(|b| String::from_utf8_lossy(&b).contains(CANARY))
                    .unwrap_or(false)
            }
            _ => false,
        })
        .await;
    let mut plain = s.d.script(vec![], &[]).await;
    let from = plain.mark();

    plain.send(&ClientMsg::TerminalRemoteSummaryRequest).await;
    plain
        .wait_since(from, "a terminal_remote_summary", |m| {
            matches!(m, ServerMsg::TerminalRemoteSummary { .. })
        })
        .await;

    let frames = summary_frames(&plain.log[from..]);
    assert_eq!(frames.len(), 1, "[{}]", plain.summary());
    let shells = frames[0]["shells"].as_array().expect("shells is a list");
    assert_eq!(shells.len(), 1, "{}", frames[0]);
    let shell = shells[0].as_object().expect("a shell is an object");
    let mut keys: Vec<&str> = shell.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        ["label", "opened_at", "target"],
        "labels, targets and open times only: {}",
        frames[0]
    );
    assert_eq!(shell["target"]["project"], "admin-portal");
    assert_eq!(shell["target"]["environment"], "production");
    assert_eq!(shell["target"]["service"], "scheduler");
    assert!(
        !frames[0].to_string().contains(CANARY),
        "no typed or printed text in the summary: {}",
        frames[0]
    );
    // It was an answer to one asker, not news for everyone.
    s.app.sync().await;
    assert!(
        summary_frames(&s.app.log).is_empty(),
        "the app was sent a summary it never asked for: [{}]",
        s.app.summary()
    );
    // And asking changed nothing.
    assert_eq!(s.d.list().len(), 1);
    assert_eq!(
        s.d.info(&terminal_id).map(|i| i.status),
        Some(TerminalStatus::Running)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_summary_is_empty_when_no_remote_shell_is_open() {
    let s = Scene::start_with(Options::new(&[Peer::App, Peer::Script])).await;
    let mut plain = s.d.script(vec![], &[]).await;
    let from = plain.mark();

    plain.send(&ClientMsg::TerminalRemoteSummaryRequest).await;
    plain
        .wait_since(from, "a terminal_remote_summary", |m| {
            matches!(m, ServerMsg::TerminalRemoteSummary { .. })
        })
        .await;

    let frames = summary_frames(&plain.log[from..]);
    assert_eq!(frames[0]["shells"].as_array().map(Vec::len), Some(0));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_network_peer_cannot_ask_which_remote_shells_are_open() {
    let mut s = Scene::start().await;
    open_remote(&mut s).await;
    let mut tcp = s.d.tcp(vec![], false).await;
    let from = tcp.mark();

    tcp.send(&ClientMsg::TerminalRemoteSummaryRequest).await;
    tcp.sync().await;

    assert!(
        tcp.errors_since(from)
            .iter()
            .any(|e| e.starts_with("requires_secure_connection")),
        "refused as every other terminal frame is over TCP: [{}]",
        tcp.summary()
    );
    assert!(
        summary_frames(&tcp.log[from..]).is_empty(),
        "a network peer learns nothing about open shells: [{}]",
        tcp.summary()
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Connected but no usable answer: exit 4, never 2 (which means "no daemon")
// ═════════════════════════════════════════════════════════════════════════════

/// How a fake daemon misbehaves once a client connects.
#[derive(Clone, Copy)]
enum Fake {
    /// Accepts and never answers.
    Silent,
    /// Answers the hello with bytes that are not a frame body.
    Garbage,
    /// Welcomes, then refuses the summary request like an old daemon would.
    UnknownFrame,
    /// Answers the hello with something other than a welcome.
    NotWelcome,
}

async fn put(w: &mut (impl tokio::io::AsyncWrite + Unpin), body: &[u8]) {
    nostromo::ipc::codec::write_frame(w, body)
        .await
        .expect("write");
}

/// Serve `fake` on a fresh socket for the test's lifetime; the socket path.
fn fake_daemon(dir: &Path, fake: Fake) -> PathBuf {
    let sock = dir.join("fake.sock");
    let listener = tokio::net::UnixListener::bind(&sock).expect("bind");
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let (mut r, mut w) = tokio::io::split(stream);
                if matches!(fake, Fake::Silent) {
                    let _ = nostromo::ipc::codec::read_frame(&mut r).await;
                    tokio::time::sleep(Duration::from_secs(120)).await;
                    return;
                }
                let _ = nostromo::ipc::codec::read_frame(&mut r).await;
                match fake {
                    Fake::Garbage => put(&mut w, b"\xff not json").await,
                    Fake::NotWelcome => put(&mut w, br#"{"type":"error","message":"nope"}"#).await,
                    _ => {
                        put(
                            &mut w,
                            br#"{"type":"welcome","protocol_version":1,"daemon_pid":1}"#,
                        )
                        .await;
                        let _ = nostromo::ipc::codec::read_frame(&mut r).await; // subscribe
                        let _ = nostromo::ipc::codec::read_frame(&mut r).await; // summary request
                        put(&mut w, br#"{"type":"error","message":"unknown frame"}"#).await;
                        tokio::time::sleep(Duration::from_secs(120)).await;
                    }
                }
            });
        }
    });
    sock
}

async fn exit_code_against(fake: Fake) -> Ran {
    let dir = TempDir::new().expect("tempdir");
    let sock = fake_daemon(dir.path(), fake);
    nostromd(&sock, &["remote-shells"]).await
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_accepts_but_never_answers_exits_4() {
    let ran = exit_code_against(Fake::Silent).await;
    assert_eq!(ran.code, Some(4), "{ran:?}");
    assert!(ran.stderr.contains("no usable answer"), "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_answers_garbage_exits_4() {
    let ran = exit_code_against(Fake::Garbage).await;
    assert_eq!(ran.code, Some(4), "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_that_is_not_a_welcome_exits_4() {
    let ran = exit_code_against(Fake::NotWelcome).await;
    assert_eq!(ran.code, Some(4), "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_does_not_know_the_summary_frame_exits_4() {
    let ran = exit_code_against(Fake::UnknownFrame).await;
    assert_eq!(ran.code, Some(4), "{ran:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn no_socket_and_a_dead_socket_both_still_exit_2() {
    let dir = TempDir::new().expect("tempdir");
    let missing = nostromd(&dir.path().join("none.sock"), &["remote-shells"]).await;
    assert_eq!(missing.code, Some(2), "{missing:?}");

    // A socket file nobody listens on: connection refused.
    let dead = dir.path().join("dead.sock");
    drop(std::os::unix::net::UnixListener::bind(&dead).expect("bind"));
    let refused = nostromd(&dead, &["remote-shells"]).await;
    assert_eq!(refused.code, Some(2), "{refused:?}");
}
