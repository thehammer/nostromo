//! Terminal pane slice 2b: Connect opens a real ECS shell (PRD criteria 20, 21,
//! 22, 23 and 26), end to end through 2a's request flow: the agent's MCP call,
//! the verified app answering `connect`, the daemon's real `AwsEcsLauncher`,
//! and a fake `aws` (`tests/fixtures/fake-aws`) standing in for AWS.
//!
//! * C20  Connect starts `aws ecs execute-command` as the terminal's process
//!   (an argv array, one `--command` element), the pane is `connecting` until
//!   the session begins and then `running`, and it is labelled for the target.
//! * C21  the remote side's `exit`, a dropped connection and the user's own
//!   close each end the pane with their own reason; the user can type into it.
//! * C22  an ECS terminal is never restarted, nothing reconnects, and a new
//!   connection is a new request with a new confirm sheet.
//! * C23  every way the connect can fail leaves no pane, no leaf and no
//!   terminal, and says why (`{error:"connect_failed", reason, remedy}`).
//! * C26  the audit trail records the connect and the close by code, and never
//!   what was typed, what the shell printed, or what the AWS CLI said.
//!
//! Hermetic: nothing here contacts AWS or the network, or reads `~/.claude`,
//! `~/.nostromo` or `~/.mother` (the harness points `$HOME` at a private
//! directory and copies the vocabulary fixtures). Each test writes its own
//! `aws` wrapper script into its own temp dir: it sets the fake's mode and log
//! files for that test alone (tests run in parallel in one process, so no
//! process-global environment is touched) and `exec`s the fake. The daemon is
//! told that wrapper is the AWS CLI, with no fallback to a real one.

mod remote_shell_support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nostromo::ipc::protocol::{
    ClientMsg, PaneTree, ServerMsg, TerminalClosedInfo, TerminalInfo, TerminalKind, TerminalStatus,
};
use nostromo::terminal::agent_api::AgentRemoteRequest;
use nostromo::terminal::ecs::aws::AwsCliSource;
use nostromo::terminal::ecs::{AwsEcsLauncher, EcsPaths, EcsVocabulary, TargetPin};
use nostromo::terminal::TerminalAgentApi;
use remote_shell_support::*;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

/// The one task the fake reports.
const ARN: &str =
    "arn:aws:ecs:us-east-2:123456789012:task/fake-cluster/0123456789abcdef0123456789abcdef";
/// What the pane is called: environment, project, service, shell type.
const LABEL: &str = "production · admin-portal · scheduler · shell";
const CANARY: &str = "CANARY-7f3a91";
const PROFILE_REMEDY: &str =
    "Create ~/.claude/ecs-local.json with your AWS profiles (run ecs_setup in a shell)";

fn fake_aws() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-aws")
}

// ── the fake AWS CLI, per test ───────────────────────────────────────────────

/// What the daemon is told the AWS CLI is.
enum Cli {
    /// `tests/fixtures/fake-aws` in this mode (`ok`, `expired`, `hang`, ...).
    Fake(&'static str),
    /// A tiny script that answers the helper calls as the test says.
    Stub(Stub),
    /// A [`Stub`] that also behaves as [`Tuning`] says (slow, failing at the
    /// shell, or unable to be started again).
    Tuned(Stub, Tuning),
    /// A path where there is no executable.
    Missing,
}

/// A scripted `aws`: how `sts` answers, which tasks `list-tasks` returns, and
/// what `describe-tasks` says about them (in that order).
struct Stub {
    /// `Some(stderr)`: `sts get-caller-identity` fails with it.
    sts_stderr: Option<&'static str>,
    listed: Vec<&'static str>,
    /// `(arn, lastStatus, enableExecuteCommand)`.
    described: Vec<(&'static str, &'static str, bool)>,
}

/// What else a scripted `aws` does, beyond answering the helper calls.
#[derive(Default)]
struct Tuning {
    /// Seconds `list-tasks` sleeps before it answers.
    list_sleep: Option<&'static str>,
    /// `execute-command` prints this (no single quotes) and exits 255 instead
    /// of starting a session.
    exec_fails_with: Option<&'static str>,
    /// `describe-tasks` replaces this very script with one the kernel cannot
    /// start, so the `execute-command` that follows cannot be spawned.
    unspawnable_after_checks: bool,
}

const FAKE_TEMPLATE: &str = r#"#!/bin/sh
[ "$1" = "--wrapper-probe" ] && exit 0
case "$*" in *execute-command*) echo $$ >> '@PIDS@' ;; esac
FAKE_AWS_MODE='@MODE@' FAKE_AWS_LOG='@LOG@' FAKE_AWS_ENV_LOG='@ENV_LOG@' exec '@FAKE@' "$@"
"#;

const STUB_TEMPLATE: &str = r#"#!/bin/sh
[ "$1" = "--wrapper-probe" ] && exit 0
echo "$*" >> '@LOG@'
case "$*" in
  *"sts get-caller-identity"*) @STS@ ;;
  *"ecs list-tasks"*) @LIST_PRE@ printf '%s' '@LISTED@' ;;
  *"ecs describe-tasks"*) @DESCRIBE_PRE@ printf '%s' '@DESCRIBED@' ;;
  *"ecs execute-command"*)
    echo $$ >> '@PIDS@'
    @EXEC@ ;;
  *) echo "stub: unsupported: $*" >&2; exit 252 ;;
esac
"#;

fn stub_script(stub: &Stub, log: &Path, pids: &Path) -> String {
    tuned_stub_script(stub, &Tuning::default(), Path::new("/unused"), log, pids)
}

fn tuned_stub_script(
    stub: &Stub,
    tuning: &Tuning,
    wrapper: &Path,
    log: &Path,
    pids: &Path,
) -> String {
    let sts = match stub.sts_stderr {
        None => r#"printf '%s' '{"Account":"1"}'"#.to_string(),
        Some(stderr) => format!("printf '%s\\n' '{stderr}' >&2; exit 255"),
    };
    let listed = stub
        .listed
        .iter()
        .map(|a| format!("\"{a}\""))
        .collect::<Vec<_>>()
        .join(",");
    let described = stub
        .described
        .iter()
        .map(|(arn, status, enabled)| {
            format!(
                "{{\"taskArn\":\"{arn}\",\"lastStatus\":\"{status}\",\"enableExecuteCommand\":{enabled}}}"
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let list_pre = tuning
        .list_sleep
        .map(|secs| format!("sleep {secs};"))
        .unwrap_or_default();
    let describe_pre = if tuning.unspawnable_after_checks {
        let w = wrapper.display();
        format!(
            "printf '#!/nonexistent/interpreter\\n' > '{w}.new'; chmod 755 '{w}.new'; mv '{w}.new' '{w}';"
        )
    } else {
        String::new()
    };
    let exec = match tuning.exec_fails_with {
        Some(text) => format!("printf '%s\\n' '{text}'; exit 255"),
        None => {
            "printf '\\nStarting session with SessionId: stub-1\\n'\n    exec sleep 60".to_string()
        }
    };
    STUB_TEMPLATE
        .replace("@LIST_PRE@", &list_pre)
        .replace("@DESCRIBE_PRE@", &describe_pre)
        .replace("@EXEC@", &exec)
        .replace("@LOG@", &log.display().to_string())
        .replace("@PIDS@", &pids.display().to_string())
        .replace("@STS@", &sts)
        .replace("@LISTED@", &format!("{{\"taskArns\":[{listed}]}}"))
        .replace(
            "@DESCRIBED@",
            &format!("{{\"tasks\":[{described}],\"failures\":[]}}"),
        )
}

/// Write an executable script and make sure the kernel will run it: a script
/// written while another thread of this process forks can be "text file busy"
/// for a moment, so run it once (it answers `--wrapper-probe` before anything
/// else) until it starts.
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

// ── the rig ──────────────────────────────────────────────────────────────────

/// A daemon with the real launcher pointed at a per-test fake `aws`, the
/// verified app, and an agent connection in focus [`TAG`].
struct Rig {
    s: Scene,
    work: TempDir,
    /// The `aws` the launcher is told to use.
    wrapper: PathBuf,
    /// The fake's argv log (JSON lines), or the stub's plain-text log.
    log: PathBuf,
    env_log: PathBuf,
    /// The pid of every `execute-command` process that started.
    pids: PathBuf,
}

/// An answered request: the MCP result and the sheet it came from.
struct Asked {
    res: Value,
    confirm: Confirm,
    /// The app's log position before the request.
    from: usize,
}

/// A shell that connected.
struct Connected {
    terminal_id: String,
    pane_id: String,
    from: usize,
    confirm: Confirm,
}

impl Rig {
    async fn start(mode: &'static str) -> Rig {
        Self::build(Cli::Fake(mode), None).await
    }

    async fn build(cli: Cli, connect_timeout: Option<Duration>) -> Rig {
        let mut opts = Options::new(&[Peer::App]);
        opts.fake_launcher = false;
        let s = Scene::start_with(opts).await;
        let work = TempDir::new().expect("tempdir");
        let bin = work.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let wrapper = bin.join("aws");
        let log = work.path().join("aws.log");
        let env_log = work.path().join("aws-env.log");
        let pids = work.path().join("aws.pids");
        let source = match &cli {
            Cli::Missing => AwsCliSource::only(work.path().join("nowhere").join("aws")),
            Cli::Fake(mode) => {
                let script = FAKE_TEMPLATE
                    .replace("@PIDS@", &pids.display().to_string())
                    .replace("@MODE@", mode)
                    .replace("@LOG@", &log.display().to_string())
                    .replace("@ENV_LOG@", &env_log.display().to_string())
                    .replace("@FAKE@", &fake_aws().display().to_string());
                write_exec(&wrapper, &script);
                AwsCliSource::only(&wrapper)
            }
            Cli::Stub(stub) => {
                write_exec(&wrapper, &stub_script(stub, &log, &pids));
                AwsCliSource::only(&wrapper)
            }
            Cli::Tuned(stub, tuning) => {
                write_exec(
                    &wrapper,
                    &tuned_stub_script(stub, tuning, &wrapper, &log, &pids),
                );
                AwsCliSource::only(&wrapper)
            }
        };
        let launcher = match connect_timeout {
            Some(t) => AwsEcsLauncher::with_connect_timeout(&s.d.terminals, source, t),
            None => AwsEcsLauncher::new(&s.d.terminals, source),
        };
        s.d.terminals.lock().unwrap().set_remote_launcher(launcher);
        Rig {
            s,
            work,
            wrapper,
            log,
            env_log,
            pids,
        }
    }

    // ── requests ─────────────────────────────────────────────────────────────

    /// An agent request, answered Connect.
    async fn request(&mut self, a: Value) -> Asked {
        let from = self.s.app.mark();
        let (call, confirm) = self.s.ask(a).await;
        self.s.app.answer(&confirm.request_id, "connect").await;
        let res = self.s.mcp.finish(call).await;
        Asked { res, confirm, from }
    }

    /// The usual request, answered Connect, and it connects.
    async fn connect_ok(&mut self) -> Connected {
        let asked = self.request(args()).await;
        assert_eq!(asked.res["ok"], true, "{}", asked.res);
        assert_eq!(asked.res["outcome"], "connected", "{}", asked.res);
        Connected {
            terminal_id: asked.res["terminal_id"].as_str().unwrap().to_string(),
            pane_id: asked.res["pane_id"].as_str().unwrap().to_string(),
            from: asked.from,
            confirm: asked.confirm,
        }
    }

    /// A request that fails to connect, for `reason`: nothing remains, the app
    /// and the audit trail say so, and the CLI was never asked to log in.
    async fn failed(&mut self, a: Value, reason: &str) -> Asked {
        let asked = self.request(a).await;
        assert_eq!(asked.res["error"], "connect_failed", "{}", asked.res);
        assert_eq!(asked.res["reason"], reason, "{}", asked.res);
        self.assert_nothing_remains(reason);
        let resolved = self
            .s
            .app
            .wait_resolved(asked.from, &asked.confirm.request_id)
            .await;
        assert_eq!(resolved.outcome, "connect_failed");
        assert_eq!(resolved.reason.as_deref(), Some(reason));
        assert_eq!(
            resolved.remedy.as_deref(),
            asked.res["remedy"].as_str(),
            "the sheet is given the same remedy as the agent"
        );
        self.s
            .d
            .wait_audit("connect_failed", |l| {
                l["event"] == "connect_failed" && l["reason_code"] == reason
            })
            .await;
        self.assert_never_logged_in();
        asked
    }

    fn remedy(asked: &Asked) -> String {
        asked.res["remedy"].as_str().unwrap_or_default().to_string()
    }

    // ── what the daemon holds ────────────────────────────────────────────────

    /// No terminal, no leaf, and the focus's tree is as it began.
    fn assert_nothing_remains(&self, what: &str) {
        let d = &self.s.d;
        assert!(
            d.list().is_empty(),
            "{what}: a terminal remains: {:?}",
            d.list()
        );
        for tag in [TAG, TAG2] {
            assert!(
                d.leaves(tag).is_empty(),
                "{what}: a terminal leaf remains in {tag}"
            );
        }
        assert_eq!(
            d.tree(TAG),
            Some(PaneTree::repl_leaf()),
            "{what}: the pane tree changed"
        );
    }

    /// The statuses the app was told the terminal had, in order.
    fn states(&self, terminal_id: &str) -> Vec<TerminalStatus> {
        self.s
            .app
            .log
            .iter()
            .filter_map(|m| match m {
                ServerMsg::TerminalState { terminal } if terminal.terminal_id == terminal_id => {
                    Some(terminal.status)
                }
                _ => None,
            })
            .collect()
    }

    /// The first connecting ECS terminal the daemon holds, waiting for it.
    async fn wait_connecting(&self) -> TerminalInfo {
        let mut found = None;
        eventually("an ecs terminal that is connecting", || {
            found =
                self.s.d.list().into_iter().find(|t| {
                    t.kind == TerminalKind::Ecs && t.status == TerminalStatus::Connecting
                });
            found.is_some()
        })
        .await;
        found.unwrap()
    }

    // ── the fake's logs ──────────────────────────────────────────────────────

    /// Every invocation's whole argv (the fake's JSON log).
    fn calls(&self) -> Vec<Vec<String>> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("bad log line {l}: {e}")))
            .collect()
    }

    fn exec_calls(&self) -> Vec<Vec<String>> {
        self.calls()
            .into_iter()
            .filter(|c| {
                c.get(1).map(String::as_str) == Some("ecs")
                    && c.get(2).map(String::as_str) == Some("execute-command")
            })
            .collect()
    }

    /// The subcommand of each invocation: `sts get-caller-identity`, ...
    fn subcommands(&self) -> Vec<String> {
        self.calls()
            .iter()
            .map(|c| format!("{} {}", c[1], c[2]))
            .collect()
    }

    /// The stub's log: one line of arguments per invocation.
    fn stub_lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    /// The daemon never ran `aws sso ...` (the fake refuses it, and logs it).
    fn assert_never_logged_in(&self) {
        // The fake logs JSON argv lists; a stub logs its arguments as text.
        for line in std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
        {
            let argv: Vec<String> = serde_json::from_str(line)
                .unwrap_or_else(|_| line.split(' ').map(str::to_string).collect());
            assert!(
                !argv.iter().skip(1).any(|a| a == "sso" || a == "login"),
                "the daemon ran an sso command: {argv:?}"
            );
        }
    }

    fn started_pids(&self) -> Vec<i32> {
        std::fs::read_to_string(&self.pids)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect()
    }

    /// Every `execute-command` process that started has ended.
    async fn assert_aws_processes_gone(&self, what: &str) {
        let pids = self.started_pids();
        assert!(
            !pids.is_empty(),
            "{what}: no execute-command process ever started"
        );
        eventually(&format!("{what}: the aws process to be gone"), || {
            pids.iter().all(|p| !alive(*p))
        })
        .await;
    }

    // ── the app's side of a terminal ─────────────────────────────────────────

    async fn attach(&mut self, terminal_id: &str) {
        let from = self.s.app.mark();
        self.s
            .app
            .send(&ClientMsg::TerminalAttach {
                terminal_id: terminal_id.into(),
            })
            .await;
        self.s
            .app
            .wait_since(from, "the terminal_replay", |m| {
                matches!(m, ServerMsg::TerminalReplay { terminal_id: id, .. } if id == terminal_id)
            })
            .await;
    }

    async fn type_line(&mut self, terminal_id: &str, line: &str) {
        self.s
            .app
            .send(&ClientMsg::TerminalInput {
                terminal_id: terminal_id.into(),
                bytes: B64.encode(format!("{line}\r")),
                auto_reply: false,
            })
            .await;
    }

    /// What the app has been sent of the terminal's bytes so far.
    fn text(&self, terminal_id: &str) -> String {
        let mut bytes = Vec::new();
        for m in &self.s.app.log {
            if let ServerMsg::TerminalReplay {
                terminal_id: id,
                bytes: b,
                ..
            }
            | ServerMsg::TerminalOutput {
                terminal_id: id,
                bytes: b,
            } = m
            {
                if id == terminal_id {
                    bytes.extend(B64.decode(b).expect("terminal bytes are base64"));
                }
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    async fn wait_text(&mut self, terminal_id: &str, needle: &str) {
        let deadline = Instant::now() + WAIT;
        loop {
            if self.text(terminal_id).contains(needle) {
                return;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.s.app.pump(left).await {
                panic!(
                    "timed out waiting for {needle:?} in the terminal; it showed {:?}",
                    self.text(terminal_id)
                );
            }
        }
    }

    /// Attach and wait for the remote prompt: the session is up and reading.
    async fn attach_ready(&mut self, terminal_id: &str) {
        self.attach(terminal_id).await;
        self.wait_text(terminal_id, "remote$ ").await;
    }

    async fn wait_closed(&mut self, from: usize, terminal_id: &str) -> TerminalClosedInfo {
        let (_, m) = self
            .s
            .app
            .wait_since(
                from,
                "a terminal_closed",
                |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == terminal_id),
            )
            .await;
        match m {
            ServerMsg::TerminalClosed(c) => c,
            _ => unreachable!(),
        }
    }

    /// The close of a connected shell is reported with this reason and code,
    /// for this terminal, and what the app is told matches the target.
    fn assert_closed(
        &self,
        closed: &TerminalClosedInfo,
        c: &Connected,
        reason: &str,
        exit_code: Option<i32>,
    ) {
        assert_eq!(closed.reason, reason, "{closed:?}");
        if exit_code.is_some() {
            assert_eq!(closed.exit_code, exit_code, "{closed:?}");
        }
        assert_eq!(closed.kind, TerminalKind::Ecs);
        assert_eq!(closed.label, LABEL);
        assert_eq!(closed.target, Some(canonical_target()));
        assert_eq!(closed.tag, TAG);
        assert_eq!(closed.pane_id, c.pane_id);
        self.assert_nothing_remains("after the shell closed");
        assert!(
            !self.states(&c.terminal_id).contains(&TerminalStatus::Ended),
            "an ecs terminal is never `ended`: {:?}",
            self.states(&c.terminal_id)
        );
    }
}

// ── small utilities ──────────────────────────────────────────────────────────

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

async fn eventually(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    loop {
        if cond() {
            return;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// `flag value` appears (adjacent) in `call`.
fn has_pair(call: &[String], flag: &str, value: &str) -> bool {
    call.windows(2).any(|w| w[0] == flag && w[1] == value)
}

fn rewrite_local(r: &Rig, json_text: &str) {
    std::fs::write(r.s.d.ecs_file("ecs-local.json"), json_text).expect("write ecs-local.json");
}

fn restore_local(r: &Rig) {
    std::fs::copy(
        fixture_dir().join("ecs-local.json"),
        r.s.d.ecs_file("ecs-local.json"),
    )
    .expect("restore ecs-local.json");
}

/// `names` appear in the audit trail's event names, in this order (not
/// necessarily next to each other). `confirm_outcome` carries its outcome.
fn assert_audit_in_order(d: &Daemon, wanted: &[&str]) {
    let names: Vec<String> = d
        .audit()
        .iter()
        .map(|l| {
            let event = l["event"].as_str().unwrap_or_default();
            match l["outcome"].as_str() {
                Some(o) if event == "confirm_outcome" => format!("{event}:{o}"),
                _ => event.to_string(),
            }
        })
        .collect();
    let mut at = 0;
    for want in wanted {
        match names[at..].iter().position(|n| n == want) {
            Some(i) => at += i + 1,
            None => panic!("the audit trail lacks `{want}` in order; events: {names:?}"),
        }
    }
}

/// Nothing in the trail but codes: no keystrokes, output or CLI messages.
fn assert_audit_has_no_content(d: &Daemon, extra: &[&str]) {
    let text = d.audit_text();
    for secret in [
        CANARY,
        "you said",
        "Starting session",
        "Exiting session",
        "remote$",
        ARN,
    ]
    .iter()
    .chain(extra)
    {
        assert!(
            !text.contains(secret),
            "the audit trail contains {secret:?}:\n{text}"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The fake is the only AWS there is
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn the_cli_these_tests_run_is_the_fake_wrapper_and_never_a_real_aws() {
    let fake = fake_aws();
    let meta = std::fs::metadata(&fake).expect("tests/fixtures/fake-aws exists");
    assert!(meta.is_file());
    assert!(
        meta.permissions().mode() & 0o111 != 0,
        "tests/fixtures/fake-aws must be executable"
    );

    let r = Rig::start("ok").await;
    let cli = AwsCliSource::only(&r.wrapper)
        .resolve()
        .expect("the wrapper resolves");
    assert_eq!(cli.exe, r.wrapper);
    assert!(
        cli.exe.starts_with(r.work.path()),
        "the CLI is in the test's own temp dir: {}",
        cli.exe.display()
    );
    let script = std::fs::read_to_string(&r.wrapper).unwrap();
    assert!(
        script.contains(&format!("exec '{}'", fake.display())),
        "the wrapper runs the fake and nothing else:\n{script}"
    );
    assert!(
        script.contains("FAKE_AWS_MODE="),
        "the wrapper sets the fake's mode for this test alone"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// C20: Connect starts the real shell
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn connect_runs_aws_execute_command_as_the_terminals_process_and_the_pane_goes_from_connecting_to_running(
) {
    let mut r = Rig::start("ok").await;
    // No personal profile override: the shared `production` profile is used.
    rewrite_local(&r, r#"{"sso_session":"carefeed"}"#);

    let c = r.connect_ok().await;

    // What the daemon holds: an ecs terminal for the target, running, named.
    let info =
        r.s.d
            .info(&c.terminal_id)
            .expect("the terminal is registered");
    assert_eq!(info.kind, TerminalKind::Ecs);
    assert_eq!(info.status, TerminalStatus::Running);
    assert_eq!(info.label, LABEL);
    assert_eq!(info.target, Some(canonical_target()));
    assert_eq!(info.tag, TAG);
    assert_eq!(info.pane_id, c.pane_id);
    assert_eq!(info.requested_by.kind, "focus");
    assert_eq!(r.s.d.leaves(TAG), vec![c.pane_id.clone()]);

    // What the app was told: connecting first, then running; never ended.
    r.s.app
        .wait_since(c.from, "the running terminal_state", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == c.terminal_id && terminal.status == TerminalStatus::Running)
        })
        .await;
    let states = r.states(&c.terminal_id);
    assert_eq!(
        states.first(),
        Some(&TerminalStatus::Connecting),
        "{states:?}"
    );
    assert_eq!(states.last(), Some(&TerminalStatus::Running), "{states:?}");
    assert!(!states.contains(&TerminalStatus::Ended), "{states:?}");
    let resolved = r.s.app.wait_resolved(c.from, &c.confirm.request_id).await;
    assert_eq!(resolved.outcome, "connected");

    // The checks run before the shell starts: session, tasks, task description.
    assert_eq!(
        r.subcommands(),
        [
            "sts get-caller-identity",
            "ecs list-tasks",
            "ecs describe-tasks",
            "ecs execute-command"
        ]
    );
    let calls = r.calls();
    for call in &calls {
        assert!(has_pair(call, "--profile", "fake-prod-profile"), "{call:?}");
    }
    assert!(
        has_pair(&calls[1], "--region", "us-east-2"),
        "{:?}",
        calls[1]
    );
    assert!(
        has_pair(&calls[1], "--cluster", "fake-prod-ecs"),
        "{:?}",
        calls[1]
    );
    assert!(
        has_pair(&calls[1], "--service-name", "production-fake-ap-scheduler"),
        "{:?}",
        calls[1]
    );
    assert!(
        calls[2].iter().any(|a| a == ARN),
        "describe-tasks names the task"
    );

    // The shell is the exact argv, with the shell command as ONE element.
    let exec = &r.exec_calls()[0];
    let expected: Vec<String> = [
        fake_aws().display().to_string().as_str(),
        "ecs",
        "execute-command",
        "--profile",
        "fake-prod-profile",
        "--region",
        "us-east-2",
        "--cluster",
        "fake-prod-ecs",
        "--task",
        ARN,
        "--container",
        "main",
        "--interactive",
        "--command",
        "/bin/bash",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    assert_eq!(exec, &expected);
    let at = exec.iter().position(|a| a == "--command").unwrap();
    assert_eq!(
        at,
        exec.len() - 2,
        "--command is followed by exactly one element"
    );
    for (i, a) in exec.iter().enumerate() {
        if i == at + 1 {
            continue;
        }
        assert!(
            !["sh", "bash", "-c", "eval", "/bin/sh", "/bin/bash"].contains(&a.as_str()),
            "{a:?} is an argument of its own: {exec:?}"
        );
    }
    r.assert_never_logged_in();

    // The environment each invocation ran with.
    let bin = r.wrapper.parent().unwrap().display().to_string();
    let envs: Vec<Value> = std::fs::read_to_string(&r.env_log)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(envs.len(), 4, "{envs:?}");
    for env in &envs {
        assert_eq!(
            env["PATH"],
            format!("{bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
            "{env}"
        );
        assert_eq!(env["AWS_PAGER"], "", "{env}");
    }
    assert_eq!(
        envs[3]["TERM"], "xterm-256color",
        "the shell's terminal type"
    );

    // When the remote side ends it the pane is gone; it never lingers `ended`.
    r.attach_ready(&c.terminal_id).await;
    r.type_line(&c.terminal_id, "exit").await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;
    r.assert_closed(&closed, &c, "remote_exit", Some(0));
    assert!(r.s.d.info(&c.terminal_id).is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_users_own_aws_profile_for_the_environment_is_the_one_aws_is_given() {
    let mut r = Rig::start("ok").await;
    // The fixture's ecs-local.json names `local-fake-prod-profile`, which wins
    // over the shared `fake-prod-profile`.

    let c = r.connect_ok().await;

    let calls = r.calls();
    assert_eq!(calls.len(), 4);
    for call in &calls {
        assert!(
            has_pair(call, "--profile", "local-fake-prod-profile"),
            "{call:?}"
        );
    }
    r.s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    r.wait_closed(c.from, &c.terminal_id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tinker_shell_runs_its_own_command_as_one_argument() {
    let mut r = Rig::start("ok").await;
    rewrite_local(&r, r#"{"sso_session":"carefeed"}"#);

    let (call, confirm) = r.s.ask(args_with("shell_type", json!("tinker"))).await;
    r.s.app.answer(&confirm.request_id, "connect").await;
    let res = r.s.mcp.finish(call).await;

    assert_eq!(res["ok"], true, "{res}");
    let exec = &r.exec_calls()[0];
    assert_eq!(&exec[exec.len() - 2..], ["--command", "php artisan tinker"]);
    let info = r.s.d.info(res["terminal_id"].as_str().unwrap()).unwrap();
    assert_eq!(info.label, "production · admin-portal · scheduler · tinker");
}

// ═════════════════════════════════════════════════════════════════════════════
// C21: how a session ends
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn the_user_can_type_into_the_remote_shell_and_sees_its_answer() {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;

    r.attach_ready(&c.terminal_id).await;
    r.type_line(&c.terminal_id, "hello there").await;
    r.wait_text(&c.terminal_id, "you said: hello there").await;
    r.type_line(&c.terminal_id, "second line").await;
    r.wait_text(&c.terminal_id, "you said: second line").await;

    let info = r.s.d.info(&c.terminal_id).expect("still open");
    assert_eq!(info.status, TerminalStatus::Running);
}

#[tokio::test(flavor = "multi_thread")]
async fn when_the_remote_side_ends_the_session_the_pane_closes_as_remote_exit_with_the_label_and_target(
) {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;
    r.attach_ready(&c.terminal_id).await;

    r.type_line(&c.terminal_id, "exit").await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;

    r.assert_closed(&closed, &c, "remote_exit", Some(0));
    r.assert_aws_processes_gone("after a remote exit").await;
    let line =
        r.s.d
            .wait_audit("closed", |l| {
                l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str()
            })
            .await;
    assert_eq!(line["reason"], "remote_exit", "{line}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connection_that_drops_after_it_began_closes_the_pane_as_network_with_the_exit_code() {
    let mut r = Rig::start("drop_after_connect").await;
    let c = r.connect_ok().await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;

    r.assert_closed(&closed, &c, "network", Some(255));
    let states = r.states(&c.terminal_id);
    assert_eq!(
        states.first(),
        Some(&TerminalStatus::Connecting),
        "{states:?}"
    );
    assert!(states.contains(&TerminalStatus::Running), "{states:?}");
    let line =
        r.s.d
            .wait_audit("closed", |l| {
                l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str()
            })
            .await;
    assert_eq!(line["reason"], "network", "{line}");
    assert_audit_has_no_content(&r.s.d, &["Cannot perform", "EOF"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_the_pane_ends_the_aws_process_and_reports_user_closed() {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;
    r.attach_ready(&c.terminal_id).await;

    r.s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;

    r.assert_closed(&closed, &c, "user_closed", None);
    r.assert_aws_processes_gone("after the user closed the pane")
        .await;
    let line =
        r.s.d
            .wait_audit("closed", |l| {
                l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str()
            })
            .await;
    assert_eq!(line["reason"], "user_closed", "{line}");
}

// ═════════════════════════════════════════════════════════════════════════════
// C22: no restart, no reconnect
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn restarting_an_ecs_terminal_is_refused_and_changes_nothing() {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;
    r.attach_ready(&c.terminal_id).await;

    let from = r.s.app.mark();
    r.s.app
        .send(&ClientMsg::TerminalRestart {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    r.s.app
        .wait_since(from, "a terminal_refused", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    r.s.app.settle(Duration::from_millis(300)).await;

    let refusals = r.s.app.refusals_since(from);
    assert_eq!(refusals.len(), 1, "{refusals:?}");
    assert_eq!(refusals[0].1.as_deref(), Some(c.terminal_id.as_str()));
    assert_eq!(refusals[0].2, "terminal_control_forbidden");
    assert!(
        !r.s.app.log[from..].iter().any(|m| matches!(
            m,
            ServerMsg::TerminalState { .. } | ServerMsg::TerminalClosed(_)
        )),
        "the terminal is untouched: [{}]",
        r.s.app.summary()
    );
    assert_eq!(r.s.d.list().len(), 1);
    assert_eq!(r.s.d.list()[0].terminal_id, c.terminal_id);
    assert_eq!(r.exec_calls().len(), 1, "no second connection was made");
    // And it still works.
    r.type_line(&c.terminal_id, "still here").await;
    r.wait_text(&c.terminal_id, "you said: still here").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn after_a_close_nothing_reconnects_and_a_new_shell_needs_a_new_request_and_a_new_confirm() {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;
    r.attach_ready(&c.terminal_id).await;
    r.type_line(&c.terminal_id, "exit").await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;
    r.assert_closed(&closed, &c, "remote_exit", Some(0));
    let after_close = r.s.app.mark();

    // Left alone, nothing comes back.
    r.s.app.settle(Duration::from_millis(1500)).await;
    assert_eq!(
        r.exec_calls().len(),
        1,
        "exactly one connection was ever made"
    );
    r.assert_nothing_remains("while idle after the close");
    assert!(
        !r.s.app.log[after_close..]
            .iter()
            .any(|m| matches!(m, ServerMsg::TerminalState { .. })),
        "no terminal appeared: [{}]",
        r.s.app.summary()
    );

    // Restarting what is gone does nothing either.
    r.s.app
        .send(&ClientMsg::TerminalRestart {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    r.s.app.sync().await;
    r.s.app.settle(Duration::from_millis(200)).await;
    assert_eq!(r.s.app.refusals_since(after_close).len(), 1);
    assert_eq!(r.exec_calls().len(), 1);
    r.assert_nothing_remains("after a restart of a closed terminal");

    // The user asks for one himself: a new sheet, and nothing before Connect.
    let from = r.s.app.mark();
    r.s.app
        .open_remote(TAG, ["ap", "prod", "sched", "shell"])
        .await;
    let sheet = r.s.app.wait_confirm(from).await;
    assert_ne!(sheet.request_id, c.confirm.request_id);
    assert_eq!(sheet.requested_by.kind, "user");
    r.s.app.settle(Duration::from_millis(300)).await;
    assert_eq!(r.exec_calls().len(), 1, "nothing starts before Connect");
    r.assert_nothing_remains("while the user's sheet is up");
    r.s.app.answer(&sheet.request_id, "cancel").await;
    assert_eq!(
        r.s.app.wait_resolved(from, &sheet.request_id).await.outcome,
        "cancelled"
    );
    assert_eq!(r.exec_calls().len(), 1, "Cancel connects nothing");

    // An agent's new request is a new sheet, and Connect makes a new terminal.
    let second = r.connect_ok().await;
    assert_ne!(second.confirm.request_id, c.confirm.request_id);
    assert_ne!(second.confirm.request_id, sheet.request_id);
    assert_ne!(second.terminal_id, c.terminal_id);
    assert_eq!(r.exec_calls().len(), 2);
}

// ═════════════════════════════════════════════════════════════════════════════
// C23: every failure leaves nothing behind and says why
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn an_expired_aws_session_is_reported_with_the_login_command_and_the_cli_is_never_asked_to_log_in(
) {
    let mut r = Rig::start("expired").await;

    // The user's ecs-local.json names the SSO session `carefeed`.
    rewrite_local(&r, r#"{"sso_session":"carefeed"}"#);
    let a = r.failed(args(), "sso_expired").await;
    assert!(
        Rig::remedy(&a).contains("aws sso login --sso-session carefeed"),
        "{}",
        a.res
    );

    // It names a different one (the fixture's).
    restore_local(&r);
    let a = r.failed(args(), "sso_expired").await;
    assert!(
        Rig::remedy(&a).contains("aws sso login --sso-session fake-sso-session"),
        "{}",
        a.res
    );

    // It names none: the default session.
    r.s.d.remove_ecs("ecs-local.json");
    let a = r.failed(args(), "sso_expired").await;
    assert!(
        Rig::remedy(&a).contains("aws sso login --sso-session carefeed"),
        "{}",
        a.res
    );

    // Only the session check ran, each time: no task lookup, no shell.
    assert_eq!(r.subcommands(), ["sts get-caller-identity"; 3]);
    assert!(r.exec_calls().is_empty());
    // What the CLI said is not kept.
    assert_audit_has_no_content(&r.s.d, &["ExpiredToken", "security token"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_service_with_no_running_task_is_reported_and_no_shell_is_started() {
    let mut r = Rig::start("no_tasks").await;

    let a = r.failed(args(), "no_running_task").await;

    assert!(!Rig::remedy(&a).is_empty(), "{}", a.res);
    assert_eq!(
        r.subcommands(),
        ["sts get-caller-identity", "ecs list-tasks"]
    );
    assert!(r.exec_calls().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_service_whose_tasks_cannot_be_exec_d_into_is_reported_and_no_shell_is_started() {
    let mut r = Rig::start("exec_disabled").await;

    let a = r.failed(args(), "exec_not_enabled").await;

    assert!(!Rig::remedy(&a).is_empty(), "{}", a.res);
    assert_eq!(
        r.subcommands(),
        [
            "sts get-caller-identity",
            "ecs list-tasks",
            "ecs describe-tasks"
        ]
    );
    assert!(r.exec_calls().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_missing_session_manager_plugin_is_reported_with_the_install_command_and_leaves_no_pane()
{
    let mut r = Rig::start("plugin_missing").await;

    let a = r.failed(args(), "session_manager_plugin_missing").await;

    assert!(
        Rig::remedy(&a).contains("brew install --cask session-manager-plugin"),
        "{}",
        a.res
    );
    assert_eq!(r.exec_calls().len(), 1);
    // The pane had appeared (the process was started) and was closed with the
    // reason, and what the plugin printed is nowhere in the trail.
    let closed =
        r.s.d
            .wait_audit("closed", |l| l["event"] == "closed" && l["kind"] == "ecs")
            .await;
    assert_eq!(
        closed["reason"], "session_manager_plugin_missing",
        "{closed}"
    );
    assert_audit_has_no_content(
        &r.s.d,
        &[
            "SessionManagerPlugin",
            "Documentation",
            "docs.aws.amazon.com",
        ],
    );
    r.assert_aws_processes_gone("after the plugin was found missing")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_that_never_begins_times_out_and_the_aws_process_is_killed_and_the_pane_removed()
{
    let mut r = Rig::build(Cli::Fake("hang"), Some(Duration::from_secs(3))).await;

    let from = r.s.app.mark();
    let started = Instant::now();
    let (call, confirm) = r.s.ask(args()).await;
    r.s.app.answer(&confirm.request_id, "connect").await;

    // Until it begins (or gives up) the pane exists and is connecting.
    let t = r.wait_connecting().await;
    assert_eq!(t.kind, TerminalKind::Ecs);
    assert_eq!(t.label, LABEL);
    assert_eq!(t.target, Some(canonical_target()));
    assert_eq!(t.tag, TAG);
    assert_eq!(r.s.d.leaves(TAG), vec![t.pane_id.clone()]);
    r.s.app
        .wait_since(from, "the connecting terminal_state", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == t.terminal_id && terminal.status == TerminalStatus::Connecting)
        })
        .await;
    // It cannot be restarted while it connects.
    let before = r.s.app.mark();
    r.s.app
        .send(&ClientMsg::TerminalRestart {
            terminal_id: t.terminal_id.clone(),
        })
        .await;
    r.s.app
        .wait_since(before, "a terminal_refused", |m| {
            matches!(m, ServerMsg::TerminalRefused { code, .. } if code == "terminal_control_forbidden")
        })
        .await;
    assert_eq!(
        r.s.d.info(&t.terminal_id).map(|i| i.status),
        Some(TerminalStatus::Connecting)
    );

    let res = r.s.mcp.finish(call).await;

    assert_eq!(res["error"], "connect_failed", "{res}");
    assert_eq!(res["reason"], "connect_timeout", "{res}");
    assert!(
        res["remedy"].as_str().is_some_and(|s| !s.is_empty()),
        "{res}"
    );
    assert!(
        started.elapsed() >= Duration::from_millis(2500),
        "it waited for the session: {:?}",
        started.elapsed()
    );
    r.assert_nothing_remains("after the connect timed out");
    r.assert_aws_processes_gone("after the connect timed out")
        .await;
    assert!(!r.states(&t.terminal_id).contains(&TerminalStatus::Running));
    assert!(!r.states(&t.terminal_id).contains(&TerminalStatus::Ended));
    let resolved = r.s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(
        (resolved.outcome.as_str(), resolved.reason.as_deref()),
        ("connect_failed", Some("connect_timeout"))
    );
    r.s.d
        .wait_audit("connect_failed", |l| {
            l["event"] == "connect_failed" && l["reason_code"] == "connect_timeout"
        })
        .await;
    let closed =
        r.s.d
            .wait_audit("closed", |l| {
                l["event"] == "closed" && l["terminal_id"] == t.terminal_id.as_str()
            })
            .await;
    assert_eq!(closed["reason"], "connect_timeout", "{closed}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_missing_aws_cli_is_reported_with_the_install_command_and_nothing_else_is_tried() {
    let mut r = Rig::build(Cli::Missing, None).await;

    let a = r.failed(args(), "aws_cli_missing").await;

    assert!(Rig::remedy(&a).contains("brew install awscli"), "{}", a.res);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_environment_without_a_profile_is_reported_and_aws_is_never_run() {
    let mut r = Rig::start("ok").await;

    // `canada` has no profile anywhere (the shared file says CONFIGURE_ME).
    let a = r
        .failed(
            args_with("environment", json!("canada")),
            "profile_not_configured",
        )
        .await;
    assert_eq!(Rig::remedy(&a), PROFILE_REMEDY, "{}", a.res);

    // `staging` has one only in the user's own file; without it, none.
    rewrite_local(&r, r#"{"sso_session":"carefeed"}"#);
    let a = r
        .failed(
            args_with("environment", json!("staging")),
            "profile_not_configured",
        )
        .await;
    assert_eq!(Rig::remedy(&a), PROFILE_REMEDY, "{}", a.res);

    assert!(
        r.calls().is_empty(),
        "aws was run with no profile to run it with: {:?}",
        r.calls()
    );
}

// ── when the checks themselves fail or find several tasks ────────────────────

const TASK_A: &str = "arn:aws:ecs:us-east-2:123456789012:task/stub-cluster/aaaa";
const TASK_B: &str = "arn:aws:ecs:us-east-2:123456789012:task/stub-cluster/bbbb";

/// Connect against a stub `aws` and return the task its shell was started on.
async fn task_picked(stub: Stub) -> String {
    let mut r = Rig::build(Cli::Stub(stub), None).await;
    let c = r.connect_ok().await;
    let exec: Vec<String> = r
        .stub_lines()
        .into_iter()
        .filter(|l| l.starts_with("ecs execute-command"))
        .collect();
    assert_eq!(exec.len(), 1, "{exec:?}");
    let argv: Vec<&str> = exec[0].split(' ').collect();
    let at = argv.iter().position(|a| *a == "--task").expect("--task");
    let picked = argv[at + 1].to_string();
    r.s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    r.wait_closed(c.from, &c.terminal_id).await;
    picked
}

#[tokio::test(flavor = "multi_thread")]
async fn the_shell_goes_to_the_first_running_task_that_can_be_exec_d_into() {
    let picked = task_picked(Stub {
        sts_stderr: None,
        listed: vec![TASK_A, TASK_B],
        described: vec![(TASK_A, "RUNNING", false), (TASK_B, "RUNNING", true)],
    })
    .await;
    assert_eq!(picked, TASK_B);
}

#[tokio::test(flavor = "multi_thread")]
async fn of_several_usable_tasks_the_first_listed_is_used_whatever_order_they_are_described_in() {
    let picked = task_picked(Stub {
        sts_stderr: None,
        listed: vec![TASK_A, TASK_B],
        described: vec![(TASK_B, "RUNNING", true), (TASK_A, "RUNNING", true)],
    })
    .await;
    assert_eq!(picked, TASK_A);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_task_that_is_not_running_is_never_chosen() {
    let picked = task_picked(Stub {
        sts_stderr: None,
        listed: vec![TASK_A, TASK_B],
        described: vec![(TASK_A, "STOPPED", true), (TASK_B, "RUNNING", true)],
    })
    .await;
    assert_eq!(picked, TASK_B);
}

#[tokio::test(flavor = "multi_thread")]
async fn when_no_listed_task_is_actually_running_the_service_has_no_running_task() {
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: None,
            listed: vec![TASK_A],
            described: vec![(TASK_A, "STOPPED", true)],
        }),
        None,
    )
    .await;

    r.failed(args(), "no_running_task").await;

    assert!(!r
        .stub_lines()
        .iter()
        .any(|l| l.starts_with("ecs execute-command")));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unrecognised_aws_error_reaches_the_operator_as_its_first_line_and_the_agent_not_at_all()
{
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some("An error occurred (ThrottlingException) when calling the GetCallerIdentity operation: Rate exceeded\nsecond-line-of-noise"),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;

    let a = r.failed(args(), "aws_error").await;

    // The agent: the code and the fixed remedy, and none of what AWS said.
    let text = a.res.to_string();
    assert!(a.res.get("detail").is_none(), "{text}");
    for aws_text in [
        "ThrottlingException",
        "Rate exceeded",
        "GetCallerIdentity",
        "second-line",
    ] {
        assert!(
            !text.contains(aws_text),
            "{aws_text} reached the agent: {text}"
        );
    }
    // The operator's app: the first line, sanitised, on the frame that closes
    // the sheet.
    let resolved = r.s.app.wait_resolved(a.from, &a.confirm.request_id).await;
    let detail = resolved.detail.unwrap_or_default();
    assert!(detail.contains("ThrottlingException"), "{detail}");
    assert!(!detail.contains("second-line-of-noise"), "{detail}");
    assert_eq!(r.stub_lines().len(), 1, "it stopped at the failing check");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_profile_the_cli_does_not_know_is_reported_as_profile_not_configured() {
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some("The config profile (fake-prod-profile) could not be found"),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;

    let a = r.failed(args(), "profile_not_configured").await;

    assert_eq!(Rig::remedy(&a), PROFILE_REMEDY, "{}", a.res);
}

// ── going away while the session starts ──────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn closing_the_pane_while_it_connects_fails_the_request_and_leaves_nothing_behind() {
    let mut r = Rig::build(Cli::Fake("hang"), Some(Duration::from_secs(30))).await;
    let started = Instant::now();
    let (call, confirm) = r.s.ask(args()).await;
    r.s.app.answer(&confirm.request_id, "connect").await;
    let t = r.wait_connecting().await;

    r.s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: t.terminal_id.clone(),
        })
        .await;
    let res = r.s.mcp.finish(call).await;

    assert_eq!(res["error"], "connect_failed", "{res}");
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "the request did not wait out the connect timeout"
    );
    r.assert_nothing_remains("after the user closed a connecting pane");
    r.assert_aws_processes_gone("after the user closed a connecting pane")
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn when_the_agent_goes_away_while_the_session_starts_the_pane_and_the_aws_process_do_not_stay(
) {
    let mut r = Rig::build(Cli::Fake("hang"), Some(Duration::from_secs(30))).await;
    let api = TerminalAgentApi::new(std::sync::Arc::clone(&r.s.d.terminals));
    let from = r.s.app.mark();
    let asking = tokio::spawn(async move {
        api.request_remote(AgentRemoteRequest {
            tag: TAG.into(),
            agent: Some(AGENT.into()),
            project: "ap".into(),
            environment: "prod".into(),
            service: "sched".into(),
            shell_type: "shell".into(),
            reason: None,
            timeout: Duration::from_secs(60),
        })
        .await
    });
    let confirm = r.s.app.wait_confirm(from).await;
    r.s.app.answer(&confirm.request_id, "connect").await;
    let t = r.wait_connecting().await;
    // The fake CLI records its pid as it starts: abort only once it has, so the
    // "no process ever started" check cannot race the launch.
    eventually("the fake aws process to have started", || {
        !r.started_pids().is_empty()
    })
    .await;

    asking.abort();
    let _ = asking.await;

    eventually("the pane to be removed", || r.s.d.list().is_empty()).await;
    r.assert_nothing_remains("after the agent went away");
    r.assert_aws_processes_gone("after the agent went away")
        .await;
    let resolved = r.s.app.wait_resolved(from, &confirm.request_id).await;
    assert_eq!(resolved.outcome, "cancelled");
    assert!(!r.states(&t.terminal_id).contains(&TerminalStatus::Running));
}

// ═════════════════════════════════════════════════════════════════════════════
// C26: the audit trail
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_full_session_is_audited_in_order_and_never_contains_what_was_typed_printed_or_said() {
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;
    r.attach_ready(&c.terminal_id).await;
    r.type_line(&c.terminal_id, CANARY).await;
    r.wait_text(&c.terminal_id, &format!("you said: {CANARY}"))
        .await;
    r.type_line(&c.terminal_id, "exit").await;
    let closed = r.wait_closed(c.from, &c.terminal_id).await;
    r.assert_closed(&closed, &c, "remote_exit", Some(0));
    r.s.d
        .wait_audit("closed", |l| {
            l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str()
        })
        .await;

    assert_audit_in_order(
        &r.s.d,
        &[
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connected",
            "closed",
        ],
    );
    let closed_line =
        r.s.d
            .audit()
            .into_iter()
            .find(|l| l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str())
            .unwrap();
    assert_eq!(closed_line["reason"], "remote_exit", "{closed_line}");
    assert_eq!(closed_line["kind"], "ecs");
    assert_audit_has_no_content(&r.s.d, &[]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_dropped_session_is_audited_by_reason_and_never_by_content() {
    let mut r = Rig::start("drop_after_connect").await;
    let c = r.connect_ok().await;
    r.wait_closed(c.from, &c.terminal_id).await;
    r.s.d
        .wait_audit("closed", |l| {
            l["event"] == "closed" && l["terminal_id"] == c.terminal_id.as_str()
        })
        .await;

    assert_audit_in_order(
        &r.s.d,
        &[
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connected",
            "closed",
        ],
    );
    assert_audit_has_no_content(&r.s.d, &["Cannot perform", "EOF"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_connect_is_audited_by_reason_code_in_order() {
    let mut r = Rig::start("no_tasks").await;

    r.failed(args(), "no_running_task").await;

    assert_eq!(
        r.s.d.remote_audit_names(),
        [
            "remote_requested",
            "confirm_outcome:connect",
            "connect_started",
            "connect_failed"
        ]
    );
    let failed = r.s.d.remote_audit().pop().unwrap();
    assert_eq!(failed["reason_code"], "no_running_task", "{failed}");
    assert_audit_has_no_content(&r.s.d, &[]);
}

// ═════════════════════════════════════════════════════════════════════════════
// Review fix-ups: shared helpers
// ═════════════════════════════════════════════════════════════════════════════

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Set the string at JSON `pointer` in one of the daemon's vocabulary files.
fn set_json(r: &Rig, file: &str, pointer: &str, value: &str) {
    r.s.d.edit_ecs(file, |text| {
        let mut doc: Value = serde_json::from_str(&text).expect("valid json");
        *doc.pointer_mut(pointer)
            .unwrap_or_else(|| panic!("{pointer} is in {file}")) = json!(value);
        serde_json::to_string_pretty(&doc).unwrap()
    });
}

fn restore_fixtures(r: &Rig) {
    for name in ["config.json", "ecs-local.json"] {
        std::fs::copy(fixture_dir().join(name), r.s.d.ecs_file(name)).expect("restore fixture");
    }
}

fn file_bytes(r: &Rig, name: &str) -> Vec<u8> {
    std::fs::read(r.s.d.ecs_file(name)).expect("read the vocabulary file")
}

/// What the usual request resolves to when the fixtures are untouched: the
/// pin the daemon should record for it.
fn fixture_pin() -> TargetPin {
    let dir = fixture_dir();
    EcsVocabulary::load(&EcsPaths::new(
        dir.join("config.json"),
        dir.join("ecs-local.json"),
        dir.join("ecs.sh"),
    ))
    .expect("the fixtures load")
    .resolve("admin-portal", "production", "scheduler", "shell")
    .expect("the usual target resolves")
    .pin
}

/// The audit lines of one kind, in order.
fn audit_lines(r: &Rig, event: &str) -> Vec<Value> {
    r.s.d
        .audit()
        .into_iter()
        .filter(|l| l["event"] == event)
        .collect()
}

fn sorted_keys(v: &Value) -> Vec<String> {
    let mut keys: Vec<String> = v.as_object().expect("an object").keys().cloned().collect();
    keys.sort();
    keys
}

/// Close a connected shell and wait for it to be gone.
async fn close_shell(r: &mut Rig, c: &Connected) {
    r.s.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: c.terminal_id.clone(),
        })
        .await;
    r.wait_closed(c.from, &c.terminal_id).await;
}

fn ok_stub() -> Stub {
    Stub {
        sts_stderr: None,
        listed: vec![TASK_A],
        described: vec![(TASK_A, "RUNNING", true)],
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// B1: values that could change what runs never reach the command line
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn a_configuration_value_that_could_change_what_runs_is_refused_before_anyone_is_asked_and_aws_never_runs(
) {
    let mut r = Rig::start("ok").await;
    // (the code the agent is told, the hostile value, the file and the place)
    let cases = [
        (
            "unsafe_region",
            "us-east-2; id",
            "config.json",
            "/regions/production",
        ),
        (
            "unsafe_profile",
            "--profile",
            "ecs-local.json",
            "/profiles/production",
        ),
        (
            "unsafe_profile",
            "x y",
            "ecs-local.json",
            "/profiles/production",
        ),
        (
            "unsafe_cluster",
            "$(touch /tmp/pwned)",
            "config.json",
            "/projects/admin-portal/environments/production/cluster",
        ),
        (
            "unsafe_service_name",
            "svc|id",
            "config.json",
            "/projects/admin-portal/environments/production/services/scheduler/service",
        ),
        (
            "unsafe_container",
            "-x",
            "config.json",
            "/projects/admin-portal/environments/production/services/scheduler/container",
        ),
        (
            "unsafe_shell_command",
            "/bin/bash; touch /tmp/pwned",
            "config.json",
            "/shell_types/shell",
        ),
        (
            "unsafe_shell_command",
            "/bin/b\u{0430}sh",
            "config.json",
            "/shell_types/shell",
        ),
    ];
    for (code, value, file, pointer) in cases {
        restore_fixtures(&r);
        set_json(&r, file, pointer, value);
        let from = r.s.app.mark();

        let res = r.s.mcp.call(REQUEST, args()).await;

        assert_eq!(
            res,
            json!({
                "error": "remote_shells_not_configured",
                "detail": format!("the ECS configuration for this target has an unusable value ({code})"),
            }),
            "{value:?} in {file}"
        );
        assert!(
            !res.to_string().contains(value),
            "the value is quoted back to the agent: {res}"
        );
        r.s.app
            .assert_no_remote_frames(from, &format!("{code}: no sheet is sent"))
            .await;
        assert!(r.s.app.confirms_since(from).is_empty());
        assert!(
            r.calls().is_empty() && r.stub_lines().is_empty(),
            "{code}: aws was run: {:?}",
            r.calls()
        );
        assert!(!r.log.exists(), "{code}: the fake was started");
        r.assert_nothing_remains(code);
        assert!(
            r.s.d.remote_audit().is_empty(),
            "{code}: nothing was requested of the user: {:?}",
            r.s.d.remote_audit_names()
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// B1: what the user was shown is what runs
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn editing_the_data_while_the_sheet_is_up_changes_nothing_that_runs_and_the_audit_carries_the_original_digests(
) {
    let mut r = Rig::start("ok").await;
    let original_config = file_bytes(&r, "config.json");
    let original_local = file_bytes(&r, "ecs-local.json");
    let pin = fixture_pin();
    let (call, confirm) = r.s.ask(args()).await;
    assert_eq!(confirm.shell_command.as_deref(), Some("/bin/bash"));
    assert_eq!(confirm.cluster.as_deref(), Some("fake-prod-ecs"));
    assert_eq!(confirm.profile.as_deref(), Some("local-fake-prod-profile"));

    // The files change while the user is looking at the sheet: every word
    // that reaches the command line.
    set_json(&r, "config.json", "/shell_types/shell", "/bin/zsh");
    set_json(
        &r,
        "config.json",
        "/projects/admin-portal/environments/production/cluster",
        "edited-cluster",
    );
    let service_at = "/projects/admin-portal/environments/production/services/scheduler";
    set_json(
        &r,
        "config.json",
        &format!("{service_at}/container"),
        "edited-container",
    );
    set_json(
        &r,
        "config.json",
        &format!("{service_at}/service"),
        "edited-service",
    );
    set_json(&r, "config.json", "/regions/production", "eu-west-1");
    set_json(
        &r,
        "ecs-local.json",
        "/profiles/production",
        "edited-profile",
    );
    let edited_config = file_bytes(&r, "config.json");
    let edited_local = file_bytes(&r, "ecs-local.json");
    assert_ne!(edited_config, original_config, "harness: the edit applied");
    r.s.app.answer(&confirm.request_id, "connect").await;
    let res = r.s.mcp.finish(call).await;
    assert_eq!(res["ok"], true, "{res}");

    // What aws was asked to do is the original, in every call.
    let calls = r.calls();
    assert_eq!(calls.len(), 4, "{calls:?}");
    for call in &calls {
        assert!(
            has_pair(call, "--profile", "local-fake-prod-profile"),
            "{call:?}"
        );
        assert!(
            !call
                .iter()
                .any(|a| a.contains("edited") || a.contains("zsh") || a == "eu-west-1"),
            "an edited value reached aws: {call:?}"
        );
    }
    for call in &calls[1..3] {
        assert!(has_pair(call, "--region", "us-east-2"), "{call:?}");
        assert!(has_pair(call, "--cluster", "fake-prod-ecs"), "{call:?}");
    }
    assert!(has_pair(
        &calls[1],
        "--service-name",
        "production-fake-ap-scheduler"
    ));
    let exec = &r.exec_calls()[0];
    assert!(has_pair(exec, "--container", "main"), "{exec:?}");
    assert!(has_pair(exec, "--command", "/bin/bash"), "{exec:?}");

    // The audit records the digests of the original bytes, not of the edit.
    for event in ["connect_started", "connected"] {
        let lines = audit_lines(&r, event);
        assert_eq!(lines.len(), 1, "{event}: {lines:?}");
        let line = &lines[0];
        assert_eq!(
            line["config_sha256"],
            sha256_hex(&original_config),
            "{line}"
        );
        assert_eq!(line["local_sha256"], sha256_hex(&original_local), "{line}");
        assert_eq!(line["argv_sha256"], pin.argv_sha256, "{line}");
        assert_ne!(line["config_sha256"], sha256_hex(&edited_config), "{line}");
        assert_ne!(line["local_sha256"], sha256_hex(&edited_local), "{line}");
    }
    assert_eq!(pin.config_sha256, sha256_hex(&original_config));
    // Digests only: not the words they stand for.
    assert_audit_has_no_content(
        &r.s.d,
        &[
            "local-fake-prod-profile",
            "fake-prod-ecs",
            "/bin/bash",
            "production-fake-ap-scheduler",
            "us-east-2",
        ],
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_request_made_after_the_edit_sees_the_new_values_and_is_pinned_to_the_new_digests() {
    let mut r = Rig::start("ok").await;
    let first = r.connect_ok().await;
    let first_config = file_bytes(&r, "config.json");
    close_shell(&mut r, &first).await;

    set_json(&r, "config.json", "/shell_types/shell", "/bin/zsh");
    set_json(
        &r,
        "config.json",
        "/projects/admin-portal/environments/production/cluster",
        "edited-cluster",
    );
    let edited_config = file_bytes(&r, "config.json");
    let second = r.connect_ok().await;

    assert_eq!(second.confirm.shell_command.as_deref(), Some("/bin/zsh"));
    assert_eq!(second.confirm.cluster.as_deref(), Some("edited-cluster"));
    let exec = &r.exec_calls()[1];
    assert!(has_pair(exec, "--command", "/bin/zsh"), "{exec:?}");
    assert!(has_pair(exec, "--cluster", "edited-cluster"), "{exec:?}");
    assert!(has_pair(&r.exec_calls()[0], "--command", "/bin/bash"));
    let started = audit_lines(&r, "connect_started");
    assert_eq!(started.len(), 2, "{started:?}");
    assert_eq!(started[0]["config_sha256"], sha256_hex(&first_config));
    assert_eq!(started[1]["config_sha256"], sha256_hex(&edited_config));
    assert_ne!(started[0]["config_sha256"], started[1]["config_sha256"]);
    assert_ne!(started[0]["argv_sha256"], started[1]["argv_sha256"]);
    assert_eq!(
        started[0]["local_sha256"], started[1]["local_sha256"],
        "the personal file did not change"
    );
    let connected = audit_lines(&r, "connected");
    assert_eq!(connected[1]["config_sha256"], started[1]["config_sha256"]);
    assert_eq!(connected[1]["argv_sha256"], started[1]["argv_sha256"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_connect_lines_carry_the_digests_as_flat_fields_and_a_failed_line_carries_only_its_reason(
) {
    let mut r = Rig::start("no_tasks").await;

    r.failed(args(), "no_running_task").await;

    let pin = fixture_pin();
    let started = audit_lines(&r, "connect_started");
    assert_eq!(started.len(), 1);
    assert_eq!(
        sorted_keys(&started[0]),
        [
            "argv_sha256",
            "config_sha256",
            "event",
            "local_sha256",
            "tag",
            "target",
            "ts"
        ],
        "{}",
        started[0]
    );
    assert_eq!(started[0]["config_sha256"], pin.config_sha256);
    assert_eq!(
        started[0]["local_sha256"],
        pin.local_sha256.clone().unwrap()
    );
    assert_eq!(started[0]["argv_sha256"], pin.argv_sha256);
    for field in ["config_sha256", "local_sha256", "argv_sha256"] {
        let digest = started[0][field].as_str().unwrap();
        assert_eq!(digest.len(), 64, "{field}");
        assert!(
            digest
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
            "{field} is lowercase hex: {digest}"
        );
    }
    let failed = audit_lines(&r, "connect_failed");
    assert_eq!(failed.len(), 1);
    assert_eq!(
        sorted_keys(&failed[0]),
        ["event", "reason_code", "tag", "target", "ts"],
        "{}",
        failed[0]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn without_an_ecs_local_json_the_audit_has_no_local_digest_and_the_shared_profile_runs() {
    let mut r = Rig::start("ok").await;
    r.s.d.remove_ecs("ecs-local.json");
    let config = file_bytes(&r, "config.json");

    let c = r.connect_ok().await;

    assert_eq!(c.confirm.profile.as_deref(), Some("fake-prod-profile"));
    for event in ["connect_started", "connected"] {
        let lines = audit_lines(&r, event);
        assert_eq!(lines.len(), 1, "{event}");
        assert!(lines[0].get("local_sha256").is_none(), "{}", lines[0]);
        assert_eq!(lines[0]["config_sha256"], sha256_hex(&config));
        assert!(lines[0]["argv_sha256"].is_string());
    }
    assert!(has_pair(&r.calls()[0], "--profile", "fake-prod-profile"));
}

// ═════════════════════════════════════════════════════════════════════════════
// B2: nothing the AWS CLI said reaches the agent
// ═════════════════════════════════════════════════════════════════════════════

/// The agent's result is `{error, reason, remedy}` with the fixed remedy for
/// the reason, and none of the text AWS (or this machine) could have put in it.
async fn agent_sees_only_fixed_text(
    r: &mut Rig,
    a: Value,
    reason: &str,
    remedy: Option<&str>,
    aws_said: &[&str],
) -> Asked {
    let asked = r.failed(a, reason).await;
    assert_agent_result_is_fixed_text(r, &asked, remedy, aws_said);
    asked
}

fn assert_agent_result_is_fixed_text(
    r: &Rig,
    asked: &Asked,
    remedy: Option<&str>,
    aws_said: &[&str],
) {
    let reason = asked.res["reason"].as_str().unwrap_or_default();
    let keys: Vec<String> = sorted_keys(&asked.res);
    assert_eq!(keys, ["error", "reason", "remedy"], "{}", asked.res);
    assert_eq!(
        asked.res["remedy"],
        remedy.map_or(Value::Null, |r| json!(r)),
        "the remedy is the fixed one for {reason}"
    );
    let text = asked.res.to_string();
    let work = r.work.path().display().to_string();
    for leaked in [
        "123456789012",
        "arn:",
        "/Users",
        "/tmp",
        "/var/",
        "/home/",
        "Exception",
        "stderr",
        "nonexistent",
        work.as_str(),
    ]
    .iter()
    .chain(aws_said)
    {
        assert!(
            !text.contains(leaked),
            "{leaked:?} reached the agent for {reason}: {text}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_the_aws_session_has_expired() {
    let mut r = Rig::start("expired").await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "sso_expired",
        Some("Run `aws sso login --sso-session fake-sso-session`"),
        &["ExpiredToken", "security token", "GetCallerIdentity"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_no_task_is_running() {
    let mut r = Rig::start("no_tasks").await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "no_running_task",
        Some("Check that the service is up, or pick another service."),
        &[],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_exec_is_not_enabled() {
    let mut r = Rig::start("exec_disabled").await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "exec_not_enabled",
        Some("Enable ECS Exec on the service and redeploy it, or pick another service."),
        &[],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_the_session_manager_plugin_is_missing() {
    let mut r = Rig::start("plugin_missing").await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "session_manager_plugin_missing",
        Some("brew install --cask session-manager-plugin"),
        &[
            "SessionManagerPlugin",
            "Documentation",
            "docs.aws.amazon.com",
        ],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_there_is_no_profile_or_the_cli_does_not_know_it(
) {
    let mut r = Rig::start("ok").await;
    agent_sees_only_fixed_text(
        &mut r,
        args_with("environment", json!("canada")),
        "profile_not_configured",
        Some(PROFILE_REMEDY),
        &[],
    )
    .await;

    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some("The config profile (fake-prod-profile) could not be found"),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "profile_not_configured",
        Some(PROFILE_REMEDY),
        &["could not be found", "config profile"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_the_aws_cli_is_missing() {
    let mut r = Rig::build(Cli::Missing, None).await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "aws_cli_missing",
        Some("Install the AWS CLI: brew install awscli"),
        &["nowhere"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_the_session_never_begins() {
    let mut r = Rig::build(Cli::Fake("hang"), Some(Duration::from_secs(1))).await;
    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "connect_timeout",
        Some("Check your network and your AWS session, then try again."),
        &[],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_nothing_of_what_a_connection_that_dropped_before_it_began_printed() {
    let mut r = Rig::build(
        Cli::Tuned(
            ok_stub(),
            Tuning {
                exec_fails_with: Some(
                    "Something odd for 123456789012 arn:aws:iam::123456789012:role/x /Users/x/.aws/sso/cache `id` $(id) HOSTILE-WORDS",
                ),
                ..Tuning::default()
            },
        ),
        None,
    )
    .await;

    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "unknown",
        None,
        &["HOSTILE-WORDS", "Something odd", "$(id)"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_only_the_fixed_remedy_when_aws_denies_access_to_the_task() {
    let mut r = Rig::build(
        Cli::Tuned(
            ok_stub(),
            Tuning {
                exec_fails_with: Some(
                    "An error occurred (AccessDeniedException) when calling the ExecuteCommand operation: User: arn:aws:sts::123456789012:assumed-role/dev/me is not authorized to perform: ecs:ExecuteCommand (see /Users/x/.aws/sso/cache)",
                ),
                ..Tuning::default()
            },
        ),
        None,
    )
    .await;

    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "access_denied",
        Some("Your AWS role is not allowed to exec into this service; ask an admin for access."),
        &[
            "AccessDenied",
            "not authorized",
            "ExecuteCommand",
            "assumed-role",
        ],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_nothing_of_what_aws_said_when_the_task_is_not_ready_for_exec() {
    let mut r = Rig::build(
        Cli::Tuned(
            ok_stub(),
            Tuning {
                exec_fails_with: Some(
                    "An error occurred (TargetNotConnectedException) when calling the ExecuteCommand operation for 123456789012: internal error HOSTILE-WORDS",
                ),
                ..Tuning::default()
            },
        ),
        None,
    )
    .await;

    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "target_not_connected",
        None,
        &["TargetNotConnected", "internal error", "HOSTILE-WORDS"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_agent_is_told_nothing_of_an_aws_error_with_an_account_an_arn_a_path_and_a_throttle() {
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some("An error occurred (ThrottlingException) when calling the GetCallerIdentity operation for account 123456789012 (arn:aws:iam::123456789012:user/me): see /Users/x/.aws/sso/cache"),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;

    agent_sees_only_fixed_text(
        &mut r,
        args(),
        "aws_error",
        None,
        &["Throttling", "GetCallerIdentity", "sso/cache", "account"],
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_aws_cli_that_cannot_be_started_for_the_shell_fails_with_a_fixed_code_no_path_and_no_pane(
) {
    // The script passes the checks and then cannot be executed (its
    // interpreter is gone). A pty child that fails to exec is, to the daemon,
    // a process that ended before the session began; either way the agent is
    // told a fixed code and remedy, and nothing remains.
    let mut r = Rig::build(
        Cli::Tuned(
            ok_stub(),
            Tuning {
                unspawnable_after_checks: true,
                ..Tuning::default()
            },
        ),
        None,
    )
    .await;

    let asked = r.request(args()).await;

    assert_eq!(asked.res["error"], "connect_failed", "{}", asked.res);
    let reason = asked.res["reason"].as_str().unwrap_or_default();
    assert!(
        ["spawn_failed", "unknown"].contains(&reason),
        "{}",
        asked.res
    );
    assert_agent_result_is_fixed_text(
        &r,
        &asked,
        None,
        &["interpreter", "No such file", "os error", "aws"],
    );
    r.assert_nothing_remains("the shell could not be started");
    r.s.d
        .wait_audit("connect_failed", |l| l["event"] == "connect_failed")
        .await;
    assert!(
        !r.stub_lines()
            .iter()
            .any(|l| l.starts_with("ecs execute-command")),
        "the replaced script cannot have run"
    );
    assert!(audit_lines(&r, "connected").is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_operator_is_shown_a_sanitised_line_of_what_aws_said_and_the_audit_trail_never_is() {
    let stderr: &'static str = Box::leak(
        format!(
            "\u{1b}[31mBad thing\u{1b}[0m \u{202e}reversed {}\nsecond-line-of-noise",
            "y".repeat(500)
        )
        .into_boxed_str(),
    );
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some(stderr),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;

    let a = r.failed(args(), "aws_error").await;

    let resolved = r.s.app.wait_resolved(a.from, &a.confirm.request_id).await;
    let detail = resolved.detail.expect("the operator is given the line");
    assert!(detail.contains("Bad thing"), "{detail}");
    assert!(!detail.contains("second-line-of-noise"), "{detail}");
    assert!(
        !detail.chars().any(|c| c.is_control() || c == '\u{202e}'),
        "{detail:?}"
    );
    for line in detail.lines() {
        assert!(
            line.chars().count() <= 200,
            "{} chars",
            line.chars().count()
        );
    }
    let audit = r.s.d.audit_text();
    for said in ["Bad thing", "yyyyyyyy", "second-line", "reversed"] {
        assert!(
            !audit.contains(said),
            "{said} is in the audit trail:\n{audit}"
        );
    }
    assert!(!a.res.to_string().contains("Bad thing"), "{}", a.res);
}

#[tokio::test(flavor = "multi_thread")]
async fn for_an_unknown_ending_the_operator_gets_the_last_lines_sanitised_and_nobody_else_does() {
    let printed: &'static str = Box::leak(
        format!(
            "first-line-DROPPED\nsecond-line\n\u{1b}[31mthird line\u{1b}[0m \u{200b}zero\nfourth {}",
            "z".repeat(500)
        )
        .into_boxed_str(),
    );
    let mut r = Rig::build(
        Cli::Tuned(
            ok_stub(),
            Tuning {
                exec_fails_with: Some(printed),
                ..Tuning::default()
            },
        ),
        None,
    )
    .await;

    let a = r.failed(args(), "unknown").await;

    let resolved = r.s.app.wait_resolved(a.from, &a.confirm.request_id).await;
    let detail = resolved.detail.expect("the operator is given the lines");
    assert!(detail.contains("third line"), "{detail}");
    assert!(!detail.contains("first-line-DROPPED"), "{detail}");
    assert!(
        !detail.chars().any(|c| c.is_control() || c == '\u{200b}'),
        "{detail:?}"
    );
    for part in detail.split(" / ") {
        assert!(
            part.chars().count() <= 200,
            "{} chars",
            part.chars().count()
        );
    }
    let audit = r.s.d.audit_text();
    for said in ["second-line", "third line", "zzzzzzzz"] {
        assert!(
            !audit.contains(said),
            "{said} is in the audit trail:\n{audit}"
        );
    }
    assert!(a.res.get("detail").is_none(), "{}", a.res);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failure_with_nothing_to_quote_gives_the_operator_no_detail() {
    let mut r = Rig::start("no_tasks").await;

    let a = r.failed(args(), "no_running_task").await;

    let resolved = r.s.app.wait_resolved(a.from, &a.confirm.request_id).await;
    assert_eq!(resolved.detail, None);
}

// ═════════════════════════════════════════════════════════════════════════════
// Should-fix: what the AWS CLI runs with
// ═════════════════════════════════════════════════════════════════════════════

/// Every name a child of the daemon may have: the ones the daemon passes on,
/// the ones it sets, and what `/bin/sh` and python add by themselves, and what
/// this test's wrapper sets.
const ENV_ALLOWED: [&str; 22] = [
    "HOME",
    "USER",
    "LANG",
    "TMPDIR",
    "AWS_CONFIG_FILE",
    "AWS_SHARED_CREDENTIALS_FILE",
    "PATH",
    "TERM",
    "AWS_PAGER",
    "PWD",
    "OLDPWD",
    "SHLVL",
    "_",
    "LC_CTYPE",
    "LC_ALL",
    "PYTHONCOERCECLOCALE",
    "PYTHONUTF8",
    "__CF_USER_TEXT_ENCODING",
    // Set by the pty library for the shell's child, from the login database.
    "SHELL",
    "FAKE_AWS_MODE",
    "FAKE_AWS_LOG",
    "FAKE_AWS_ENV_LOG",
];

#[tokio::test(flavor = "multi_thread")]
async fn neither_the_helper_calls_nor_the_shell_are_started_with_any_of_the_daemons_other_variables(
) {
    // This test process holds variables the daemon must not pass on: cargo's
    // (CARGO_*) and the harness's own (NOSTROMO_*), at least.
    let mut r = Rig::start("ok").await;
    let c = r.connect_ok().await;

    let dumps: Vec<Value> = std::fs::read_to_string(&r.env_log)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(
        dumps.len(),
        4,
        "sts, list-tasks, describe-tasks, execute-command"
    );
    let subcommands = r.subcommands();
    for (dump, what) in dumps.iter().zip(&subcommands) {
        let env = dump["ENV"]
            .as_object()
            .unwrap_or_else(|| panic!("{what}: no ENV in {dump}"));
        for key in env.keys() {
            let upper = key.to_ascii_uppercase();
            assert!(!key.starts_with("NOSTROMO_"), "{what}: {key} was passed on");
            assert!(
                !key.starts_with("AWS_ENDPOINT_URL"),
                "{what}: {key} was passed on"
            );
            assert!(!key.starts_with("CARGO_"), "{what}: {key} was passed on");
            assert!(
                ENV_ALLOWED.contains(&key.as_str())
                    || !["TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"]
                        .iter()
                        .any(|w| upper.contains(w)),
                "{what}: {key} looks like a secret"
            );
            assert!(
                ENV_ALLOWED.contains(&key.as_str()),
                "{what}: {key} is not one of the variables the daemon passes on: {:?}",
                env.keys().collect::<Vec<_>>()
            );
        }
        // And what it is meant to pass on is there.
        assert_eq!(env["TERM"], "xterm-256color", "{what}");
        assert_eq!(env["AWS_PAGER"], "", "{what}");
        assert_eq!(
            env["HOME"].as_str(),
            std::env::var("HOME").ok().as_deref(),
            "{what}: HOME is passed on"
        );
    }
    close_shell(&mut r, &c).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// Should-fix: AWS's answers become argv only if they are task ARNs
// ═════════════════════════════════════════════════════════════════════════════

fn long_arn(len: usize) -> &'static str {
    let prefix = "arn:aws:ecs:us-east-2:123456789012:task/stub-cluster/";
    Box::leak(format!("{prefix}{}", "a".repeat(len - prefix.len())).into_boxed_str())
}

/// Things that are not task ARNs, as `list-tasks` / `describe-tasks` might
/// hand them over: safe to write into the stub (no single quote).
fn not_task_arns() -> Vec<&'static str> {
    vec![
        "--evil",
        "arn:aws:ecs:us-east-2:123456789012:task/c/x;touch",
        "arn:aws:iam::123456789012:role/x",
        "arn:aws:ecs:us-east-2:123456789012:task/c/a b",
        "arn:aws:ecs:us-east-2:123456789012:task/c/a\\nb",
        "arn:aws:ecs:us-east-2:123456789012:task/c/`id`",
        "arn:aws:ecs:us-east-2:123456789012:task/c/$(id)",
        "arn:aws:ecs:us-east-2:123456789012:task/c/a|b",
        "ARN:AWS:ECS:us-east-2:123456789012:task/c/x",
        " arn:aws:ecs:us-east-2:123456789012:task/c/x",
        "",
        long_arn(301),
    ]
}

/// The connect is refused as `aws_error`, no shell is started, and the
/// strange string is in no argv aws was run with and not in the agent's result.
async fn assert_refused_as_unexpected_answer(stub: Stub, strange: &str) {
    let mut r = Rig::build(Cli::Stub(stub), None).await;

    let a = r.failed(args(), "aws_error").await;

    let lines = r.stub_lines();
    assert!(
        !lines.iter().any(|l| l.starts_with("ecs execute-command")),
        "{strange:?}: a shell was started: {lines:?}"
    );
    assert!(r.started_pids().is_empty(), "{strange:?}");
    if !strange.is_empty() {
        let unescaped = strange.replace("\\n", "\n");
        for line in &lines {
            assert!(
                !line.contains(strange) && !line.contains(&unescaped),
                "{strange:?} was passed to aws: {line}"
            );
        }
        assert!(!a.res.to_string().contains(strange), "{}", a.res);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_listed_task_that_is_not_a_task_arn_is_never_passed_on_and_no_shell_is_started() {
    for strange in not_task_arns() {
        assert_refused_as_unexpected_answer(
            Stub {
                sts_stderr: None,
                listed: vec![strange],
                described: vec![(TASK_A, "RUNNING", true)],
            },
            strange,
        )
        .await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn one_strange_arn_among_good_ones_refuses_the_whole_answer() {
    assert_refused_as_unexpected_answer(
        Stub {
            sts_stderr: None,
            listed: vec![TASK_A, "--evil"],
            described: vec![(TASK_A, "RUNNING", true)],
        },
        "--evil",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_described_task_that_is_not_a_task_arn_is_never_chosen_and_no_shell_is_started() {
    for strange in not_task_arns() {
        assert_refused_as_unexpected_answer(
            Stub {
                sts_stderr: None,
                listed: vec![TASK_A],
                described: vec![(strange, "RUNNING", true)],
            },
            strange,
        )
        .await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn task_arns_of_every_real_shape_up_to_300_characters_still_connect() {
    for arn in [
        "arn:aws:ecs:ap-southeast-2:123456789012:task/my_cluster.v2-x/0123abcd",
        "arn:aws:ecs:us-east-2:123456789012:task/0123456789abcdef0123456789abcdef",
        long_arn(300),
    ] {
        let picked = task_picked(Stub {
            sts_stderr: None,
            listed: vec![arn],
            described: vec![(arn, "RUNNING", true)],
        })
        .await;
        assert_eq!(picked, arn);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Should-fix: nobody is watching, nothing starts
// ═════════════════════════════════════════════════════════════════════════════

fn slow_list_tasks() -> Cli {
    Cli::Tuned(
        ok_stub(),
        Tuning {
            list_sleep: Some("2"),
            ..Tuning::default()
        },
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn if_the_app_is_gone_by_the_time_the_task_is_found_no_shell_is_started() {
    let mut r = Rig::build(slow_list_tasks(), None).await;
    let (call, confirm) = r.s.ask(args()).await;
    r.s.app.answer(&confirm.request_id, "connect").await;
    eventually("the task lookup to begin", || {
        r.stub_lines()
            .iter()
            .any(|l| l.starts_with("ecs list-tasks"))
    })
    .await;

    // The user closes the app (a different, ordinary connection takes its
    // place in the harness so the rest of the rig keeps working).
    let stand_in = r.s.d.script(vec![], &[]).await;
    drop(std::mem::replace(&mut r.s.app, stand_in));
    let res = r.s.mcp.finish(call).await;

    assert_eq!(res["error"], "connect_failed", "{res}");
    assert_eq!(res["reason"], "operator_gone", "{res}");
    assert_eq!(
        res["remedy"], "Open Nostromo and request the shell again.",
        "{res}"
    );
    assert!(res.get("detail").is_none(), "{res}");
    let lines = r.stub_lines();
    assert!(
        !lines.iter().any(|l| l.starts_with("ecs execute-command")),
        "a production shell was started with nobody watching: {lines:?}"
    );
    assert!(r.started_pids().is_empty());
    r.assert_nothing_remains("the app went away before the shell started");
    r.s.d
        .wait_audit("connect_failed", |l| {
            l["event"] == "connect_failed" && l["reason_code"] == "operator_gone"
        })
        .await;
    assert!(audit_lines(&r, "connected").is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn with_the_app_still_there_after_a_slow_task_lookup_the_shell_connects() {
    let mut r = Rig::build(slow_list_tasks(), None).await;

    let c = r.connect_ok().await;

    assert!(r
        .stub_lines()
        .iter()
        .any(|l| l.starts_with("ecs execute-command")));
    assert_eq!(r.started_pids().len(), 1);
    close_shell(&mut r, &c).await;
}

// ═════════════════════════════════════════════════════════════════════════════
// Should-fix: a bare mention of a profile is not a missing profile
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread")]
async fn an_access_denied_that_names_the_profile_is_an_aws_error_and_not_a_missing_profile() {
    let mut r = Rig::build(
        Cli::Stub(Stub {
            sts_stderr: Some("An error occurred (AccessDeniedException) when calling the DescribeTasks operation: User: arn:aws:sts::123456789012:assumed-role/dev/me is not authorized to perform: ecs:DescribeTasks using profile fake-prod-profile"),
            listed: vec![],
            described: vec![],
        }),
        None,
    )
    .await;

    let a = r.failed(args(), "aws_error").await;

    assert_ne!(a.res["remedy"], PROFILE_REMEDY, "{}", a.res);
    assert_eq!(a.res["remedy"], Value::Null, "{}", a.res);
}
