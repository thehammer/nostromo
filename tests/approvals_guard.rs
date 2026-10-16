//! The production-shell guard (AP0g, design contract §5): agents may not open a remote
//! ECS/SSM shell, nor type into a tmux pane that runs one, whatever the permission mode.
//!
//! Three layers, each tested from the outside:
//!
//! - `guard::evaluate`: the pure policy, against a fake `PaneProbe` and payload fixtures in
//!   `tests/fixtures/approvals/guard/` (`block_*.json` must block, `allow_*.json` must allow).
//! - `guard::hook_settings_json` / the `/bin/sh` wrapper it installs: the exact bytes Claude is
//!   started with, and the fail-closed behaviour when the guard binary cannot run.
//! - The `nostromo-guard` binary: stdout, exit code and the audit entry it leaves.
//!
//! The audit store itself is in `tests/approvals_audit.rs`. No test here touches process-wide
//! env: child processes get theirs through `Command::env`.

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

use nostromo::approvals::audit::{Entry, Event};
use nostromo::approvals::guard::{
    deny_output_json, evaluate, hook_settings_json, resolve_guard_path, GuardError, GuardVerdict, HookPayload,
    PaneInfo, PaneProbe, ProbeError, TmuxSocket, BLOCK_RUN_TASK, FAIL_CLOSED_MESSAGE, GUARD_BIN_ENV, GUARD_MESSAGE,
    GUARD_SENTINEL_PATH, RULE_COMMAND, RULE_TMUX_INPUT, RULE_TOOL_NAME,
};
use serde_json::{json, Value};

const GUARD_BIN: &str = env!("CARGO_BIN_EXE_nostromo-guard");

// ── a fake PaneProbe ─────────────────────────────────────────────────────────────────────

/// A tmux world made of data: panes per server, each pane's process-subtree arguments, optional
/// forced failures, and a count of every probe call (the fast path must make none).
#[derive(Default)]
struct FakeProbe {
    panes: HashMap<(TmuxSocket, String), PaneInfo>,
    pane_errors: HashMap<(TmuxSocket, String), ProbeError>,
    all: HashMap<TmuxSocket, Vec<PaneInfo>>,
    all_error: Option<ProbeError>,
    subtrees: HashMap<u32, Vec<String>>,
    next_pid: u32,
    calls: AtomicUsize,
}

impl FakeProbe {
    fn fresh_pid(&mut self) -> u32 {
        self.next_pid += 1;
        1000 + self.next_pid
    }

    /// A pane addressable as `-t <target>` on `socket`; it is also one of the server's panes.
    fn pane_on(mut self, socket: TmuxSocket, target: &str, title: &str, subtree: &[&str]) -> Self {
        let pid = self.fresh_pid();
        let info = PaneInfo { pid, title: title.into() };
        self.panes.insert((socket.clone(), target.into()), info.clone());
        self.all.entry(socket).or_default().push(info);
        self.subtrees.insert(pid, subtree.iter().map(|s| s.to_string()).collect());
        self
    }

    /// A pane that is on the server but not addressed by any `-t` in the test.
    fn other_pane_on(mut self, socket: TmuxSocket, title: &str, subtree: &[&str]) -> Self {
        let pid = self.fresh_pid();
        self.all.entry(socket).or_default().push(PaneInfo { pid, title: title.into() });
        self.subtrees.insert(pid, subtree.iter().map(|s| s.to_string()).collect());
        self
    }

    fn all_panes_fail_with(mut self, e: ProbeError) -> Self {
        self.all_error = Some(e);
        self
    }

    fn pane_lookup_fails_with(mut self, socket: TmuxSocket, target: &str, e: ProbeError) -> Self {
        self.pane_errors.insert((socket, target.into()), e);
        self
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl PaneProbe for FakeProbe {
    fn pane(&self, socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let key = (socket.clone(), target.to_string());
        if let Some(e) = self.pane_errors.get(&key) {
            return Err(e.clone());
        }
        Ok(self.panes.get(&key).cloned())
    }

    fn all_panes(&self, socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(e) = &self.all_error {
            return Err(e.clone());
        }
        Ok(self.all.get(socket).cloned().unwrap_or_default())
    }

    fn subtree_args(&self, pid: u32) -> Result<Vec<String>, ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.subtrees.get(&pid).cloned().unwrap_or_default())
    }

    fn servers(&self, _extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let mut out = vec![TmuxSocket::Default];
        out.extend(self.all.keys().filter(|s| **s != TmuxSocket::Default).cloned());
        Ok(out)
    }
}

fn timeout() -> ProbeError {
    ProbeError::Timeout("tmux".into())
}

const DEFAULT: TmuxSocket = TmuxSocket::Default;

/// A plain interactive local shell.
const LOCAL_SHELL: &[&str] = &["-zsh"];
/// A pane that is running an ECS Exec session.
const REMOTE_SHELL: &[&str] = &["-zsh", "session-manager-plugin {\"SessionId\":\"x\"} us-east-1 StartSession"];

// ── payload helpers ──────────────────────────────────────────────────────────────────────

fn payload_from(v: Value) -> HookPayload {
    serde_json::from_value(v).expect("a hook payload")
}

fn tool_call(tool: &str, tool_input: Value) -> HookPayload {
    payload_from(json!({
        "session_id": "s-1", "tool_use_id": "toolu_1", "hook_event_name": "PreToolUse",
        "permission_mode": "bypassPermissions", "cwd": "/tmp",
        "tool_name": tool, "tool_input": tool_input,
    }))
}

fn bash(command: &str) -> HookPayload {
    tool_call("Bash", json!({ "command": command, "description": "x" }))
}

fn rule_of(verdict: &Result<GuardVerdict, GuardError>) -> Option<&'static str> {
    match verdict {
        Ok(GuardVerdict::Block { rule_id, .. }) => Some(rule_id),
        _ => None,
    }
}

#[track_caller]
fn assert_blocked(verdict: Result<GuardVerdict, GuardError>, rule: &str, what: &str) {
    assert_eq!(rule_of(&verdict), Some(rule), "{what}: expected a block by `{rule}`, got {verdict:?}");
    if let Ok(GuardVerdict::Block { detail, .. }) = &verdict {
        assert!(!detail.is_empty(), "{what}: a block says what matched");
    }
}

#[track_caller]
fn assert_allowed(verdict: Result<GuardVerdict, GuardError>, what: &str) {
    assert_eq!(verdict, Ok(GuardVerdict::Allow), "{what}");
}

// ── fixtures ─────────────────────────────────────────────────────────────────────────────

struct Fixture {
    name: String,
    payload: HookPayload,
    raw: Value,
}

/// Every `tests/fixtures/approvals/guard/<prefix>*.json`, by name.
fn fixtures(prefix: &str) -> Vec<Fixture> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approvals/guard");
    let mut found: Vec<Fixture> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(prefix))
        .map(|p| {
            let text = std::fs::read_to_string(&p).unwrap();
            let raw: Value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
            Fixture {
                name: p.file_stem().unwrap().to_string_lossy().into_owned(),
                payload: serde_json::from_value(raw.clone()).unwrap_or_else(|e| panic!("{}: {e}", p.display())),
                raw,
            }
        })
        .collect();
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

/// The tmux world each fixture that needs one is evaluated in. A fixture that mentions tmux but
/// has no entry here is a bug in this test, not a silent empty world.
fn probe_for(name: &str) -> FakeProbe {
    let work = || TmuxSocket::Name("work".into());
    match name {
        "block_tmux_send_keys_pane_running_session_manager_plugin" => {
            FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL)
        }
        "block_tmux_send_keys_pane_titled_production" => {
            FakeProbe::default().pane_on(DEFAULT, "prod:1.0", "production:ap:portal", LOCAL_SHELL)
        }
        "block_tmux_paste_buffer_remote_pane" => FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL),
        "block_tmux_named_socket_send_remote_pane" => {
            // The remote pane is on the `work` server; the default server has only a local pane.
            FakeProbe::default()
                .pane_on(work(), "%7", "bash", REMOTE_SHELL)
                .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL)
        }
        "block_tmux_send_keys_untargeted_while_a_pane_is_remote" => FakeProbe::default()
            .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, "demo:ap:portal", LOCAL_SHELL),
        "allow_tmux_send_keys_local_pane_while_another_is_remote" => FakeProbe::default()
            .pane_on(DEFAULT, "%3", "zsh", LOCAL_SHELL)
            .pane_on(DEFAULT, "%8", "production:ap:portal", REMOTE_SHELL),
        "allow_tmux_send_keys_untargeted_no_pane_is_remote" => FakeProbe::default()
            .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, "vim", &["vim notes.md"]),
        "allow_tmux_send_keys_untargeted_no_tmux_server" => FakeProbe::default(),
        _ if is_tmux_fixture(name) => panic!("fixture `{name}` needs a probe setup in probe_for()"),
        _ => FakeProbe::default(),
    }
}

/// Fixtures about input to a tmux pane (as opposed to ones that merely mention a tmux-named tool).
fn is_tmux_fixture(name: &str) -> bool {
    name.starts_with("block_tmux_") || name.starts_with("allow_tmux_")
}

/// The rule that owns each block fixture.
fn rule_for(name: &str) -> &'static str {
    if name.starts_with("block_tool_name_") {
        RULE_TOOL_NAME
    } else if name.starts_with("block_tmux_") {
        RULE_TMUX_INPUT
    } else {
        RULE_COMMAND
    }
}

/// Fixtures the `nostromo-guard` binary can be tested on with no tmux server reachable: the
/// ones whose verdict does not depend on a pane.
fn needs_a_tmux_world(name: &str) -> bool {
    is_tmux_fixture(name) && name != "allow_tmux_send_keys_untargeted_no_tmux_server"
}

fn mentions_tmux(p: &HookPayload) -> bool {
    serde_json::to_string(&p.tool_input).unwrap().to_lowercase().contains("tmux")
}

// ── evaluate: blocks ─────────────────────────────────────────────────────────────────────

#[test]
fn the_fixture_set_covers_what_the_guard_is_for() {
    // Guards the iteration tests below against passing on an empty or half-deleted directory.
    let blocks: Vec<String> = fixtures("block_").into_iter().map(|f| f.name).collect();
    let allows: Vec<String> = fixtures("allow_").into_iter().map(|f| f.name).collect();
    assert!(blocks.len() >= 20, "{blocks:?}");
    assert!(allows.len() >= 10, "{allows:?}");
    for must in ["block_ecs_connect", "block_aws_ssm_start_session", "block_tool_name_mcp_ecs_connect"] {
        assert!(blocks.iter().any(|b| b == must), "{must} missing from {blocks:?}");
    }
}

#[test]
fn every_block_fixture_is_blocked_by_the_rule_that_owns_it() {
    for f in fixtures("block_") {
        let probe = probe_for(&f.name);
        assert_blocked(evaluate(&f.payload, &probe), rule_for(&f.name), &f.name);
    }
}

#[test]
fn a_remote_shell_stays_blocked_in_every_permission_mode() {
    // Criterion 12: no mode (bypass, dontAsk, acceptEdits, default) can turn a block into an allow.
    for f in fixtures("block_") {
        for mode in ["bypassPermissions", "dontAsk", "acceptEdits", "default"] {
            let mut payload = f.payload.clone();
            payload.permission_mode = Some(mode.into());
            let probe = probe_for(&f.name);
            assert_blocked(evaluate(&payload, &probe), rule_for(&f.name), &format!("{} in {mode}", f.name));
        }
    }
}

#[test]
fn run_task_is_blocked_while_the_run_task_decision_stands() {
    // User question U-B, decided yes. Flipping BLOCK_RUN_TASK is a deliberate act that must
    // also change these fixtures.
    const { assert!(BLOCK_RUN_TASK) };
    assert_blocked(evaluate(&bash("ecs_run_task ap production portal migrate"), &FakeProbe::default()), RULE_COMMAND, "ecs_run_task");
    assert_blocked(evaluate(&bash("aws ecs run-task --cluster c --task-definition td"), &FakeProbe::default()), RULE_COMMAND, "aws ecs run-task");
}

#[test]
fn the_fields_command_cmd_and_script_are_all_scanned_on_any_tool() {
    for (tool, field) in [("Bash", "command"), ("PowerShell", "command"), ("Monitor", "command"), ("Custom", "cmd"), ("Custom", "script")] {
        let p = tool_call(tool, json!({ field: "aws ssm start-session --target i-1" }));
        assert_blocked(evaluate(&p, &FakeProbe::default()), RULE_COMMAND, &format!("{tool}.{field}"));
    }
}

#[test]
fn ecs_shell_tools_are_blocked_by_name_including_mcp_tools_and_any_case() {
    for tool in [
        "ecs_connect",
        "ecs_shell",
        "ecs_open_tmux_pane",
        "ecs_run_task",
        "mcp__ecs__ecs_connect",
        "mcp__carefeed__ecs_shell",
        "mcp__x__ecs_open_tmux_pane",
        "ECS_CONNECT",
    ] {
        assert_blocked(evaluate(&tool_call(tool, json!({})), &FakeProbe::default()), RULE_TOOL_NAME, tool);
    }
    // Whatever the input says, the tool name decides first.
    let p = tool_call("ecs_connect", json!({ "command": "tmux send-keys -t %7 x" }));
    let probe = FakeProbe::default();
    assert_blocked(evaluate(&p, &probe), RULE_TOOL_NAME, "name beats input");
    assert_eq!(probe.calls(), 0);
}

#[test]
fn read_only_ecs_tools_and_commands_are_not_blocked_by_name() {
    for tool in ["ecs_info", "ecs_build_command", "ecs_copy_command", "mcp__ecs__ecs_build_command", "Read", "Bash"] {
        assert_allowed(evaluate(&tool_call(tool, json!({})), &FakeProbe::default()), tool);
    }
}

#[test]
fn a_block_by_the_command_rule_does_not_need_to_look_at_any_pane() {
    let probe = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
    let p = bash("tmux send-keys -t %7 x; ecs_connect ap production portal");

    assert_blocked(evaluate(&p, &probe), RULE_COMMAND, "command wins");
    assert_eq!(probe.calls(), 0, "no tmux or ps was run");
}

#[test]
fn every_block_that_needs_no_pane_is_decided_without_probing() {
    for f in fixtures("block_").into_iter().filter(|f| !is_tmux_fixture(&f.name)) {
        let probe = probe_for(&f.name);
        assert_blocked(evaluate(&f.payload, &probe), rule_for(&f.name), &f.name);
        assert_eq!(probe.calls(), 0, "{}", f.name);
    }
}

// ── evaluate: allows ─────────────────────────────────────────────────────────────────────

#[test]
fn every_allow_fixture_is_allowed() {
    for f in fixtures("allow_") {
        let probe = probe_for(&f.name);
        assert_allowed(evaluate(&f.payload, &probe), &f.name);
        if !mentions_tmux(&f.payload) {
            assert_eq!(probe.calls(), 0, "{}: nothing about tmux, so no pane was probed", f.name);
        }
    }
}

#[test]
fn a_call_that_never_mentions_ecs_ssm_session_manager_or_tmux_makes_no_probe_calls() {
    // The fast path (T-AP0g-3): the common case costs no process spawn at all.
    let remote_world = || {
        FakeProbe::default().pane_on(DEFAULT, "%7", "production:ap:portal", REMOTE_SHELL)
    };
    let calls = [
        bash("git status"),
        bash("ls -la"),
        bash("cargo test --workspace && git diff --stat"),
        tool_call("Write", json!({ "file_path": "/tmp/a.txt", "content": "hello" })),
        tool_call("Read", json!({ "file_path": "/etc/hosts" })),
    ];
    for p in calls {
        let probe = remote_world();
        assert_allowed(evaluate(&p, &probe), &format!("{:?}", p.tool_input));
        assert_eq!(probe.calls(), 0, "{:?}", p.tool_input);
    }
}

#[test]
fn only_command_cmd_and_script_fields_are_read_so_prose_about_ecs_is_not_a_command() {
    let text = "Run `aws ecs execute-command …` yourself; ecs_connect is forbidden. Also `tmux send-keys -t %7 x`.";
    for tool_input in [
        json!({ "file_path": "/tmp/doc.md", "content": text }),
        json!({ "file_path": "/tmp/doc.md", "old_string": "a", "new_string": text }),
        json!({ "prompt": text }),
        json!({ "description": text, "command": "git status" }),
    ] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%7", "production:ap:portal", REMOTE_SHELL);
        assert_allowed(evaluate(&tool_call("Write", tool_input.clone()), &probe), &tool_input.to_string());
        assert_eq!(probe.calls(), 0);
    }
}

#[test]
fn a_payload_without_tool_input_is_treated_as_empty_input() {
    let p = payload_from(json!({ "tool_name": "Read" }));
    assert_allowed(evaluate(&p, &FakeProbe::default()), "Read with no input");

    let p = payload_from(json!({ "tool_name": "mcp__ecs__ecs_connect" }));
    assert_blocked(evaluate(&p, &FakeProbe::default()), RULE_TOOL_NAME, "an ECS tool with no input");
}

#[test]
fn a_payload_without_tool_name_does_not_parse() {
    let err = serde_json::from_value::<HookPayload>(json!({ "tool_input": { "command": "ls" } }));
    assert!(err.is_err());
}

// ── evaluate: tmux input ─────────────────────────────────────────────────────────────────

fn send_to(target: &str) -> HookPayload {
    bash(&format!("tmux send-keys -t {target} ls Enter"))
}

#[test]
fn a_pane_whose_title_names_a_remote_environment_is_remote() {
    for title in [
        "production:ap:portal",
        "prod:ap:portal",
        "demo:ap:portal",
        "canada:x:y",
        "can:x:y",
        "ca:x:y",
        "staging:x:y",
        "stg:x:y",
        "stage:x:y",
        "PRODUCTION:ap:portal",
    ] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%5", title, LOCAL_SHELL);
        assert_blocked(evaluate(&send_to("%5"), &probe), RULE_TMUX_INPUT, title);
    }
}

#[test]
fn a_pane_whose_title_only_resembles_a_remote_environment_is_not_remote() {
    for title in [
        "productivity notes",
        "prod-notes",
        "product:x:y",
        "canary:x:y",
        "work:prod:x",
        "zsh",
        "Claude Code",
        "",
    ] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%5", title, LOCAL_SHELL);
        assert_allowed(evaluate(&send_to("%5"), &probe), title);
    }
}

#[test]
fn a_pane_running_a_remote_shell_is_remote_whatever_its_title() {
    for marker in [
        "session-manager-plugin {\"SessionId\":\"abc\"} us-east-1 StartSession",
        "aws ecs execute-command --cluster c --task t --interactive --command bash",
        "aws ssm start-session --target i-1",
        "ecs_connect ap production portal",
    ] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%5", "just a shell", &["-zsh", marker]);
        assert_blocked(evaluate(&send_to("%5"), &probe), RULE_TMUX_INPUT, marker);
    }
}

#[test]
fn a_pane_running_ordinary_programs_is_not_remote() {
    let probe = FakeProbe::default().pane_on(
        DEFAULT,
        "%5",
        "editor",
        &["-zsh", "vim notes.md", "ssh devbox", "aws s3 ls", "aws ecs describe-services --cluster c --services s"],
    );
    assert_allowed(evaluate(&send_to("%5"), &probe), "ordinary processes");
}

#[test]
fn every_tmux_input_verb_is_checked_not_just_send_keys() {
    for command in [
        "tmux send-keys -t %7 x",
        "tmux send -t %7 x",
        "tmux paste-buffer -t %7",
        "tmux pasteb -t %7",
        "tmux pipe-pane -t %7 'cat > /tmp/x'",
        "tmux pipep -t %7 'cat'",
        "tmux load-buffer /tmp/x",
        "tmux set-buffer hello",
        "tmux setb hello",
    ] {
        // For the verbs that take no -t the guard cannot tell which pane: any remote pane blocks.
        let probe = FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(command), &probe), RULE_TMUX_INPUT, command);
    }
}

#[test]
fn tmux_input_to_a_local_pane_is_allowed_even_when_another_pane_is_remote() {
    let probe = FakeProbe::default()
        .pane_on(DEFAULT, "%3", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "%8", "production:ap:portal", REMOTE_SHELL);
    assert_allowed(evaluate(&send_to("%3"), &probe), "a local pane");
    assert_blocked(evaluate(&send_to("%8"), &probe), RULE_TMUX_INPUT, "the remote pane");
}

#[test]
fn the_tmux_server_is_the_one_the_command_names() {
    let probe = FakeProbe::default()
        .pane_on(TmuxSocket::Name("work".into()), "%7", "bash", REMOTE_SHELL)
        .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL)
        .pane_on(TmuxSocket::Path("/tmp/s.sock".into()), "%7", "bash", REMOTE_SHELL);

    assert_allowed(evaluate(&bash("tmux send-keys -t %7 x"), &probe), "default server, local pane");
    assert_blocked(evaluate(&bash("tmux -L work send-keys -t %7 x"), &probe), RULE_TMUX_INPUT, "-L work");
    assert_blocked(evaluate(&bash("tmux -S /tmp/s.sock send-keys -t %7 x"), &probe), RULE_TMUX_INPUT, "-S path");
}

#[test]
fn tmux_is_still_checked_when_invoked_by_path_or_inside_bash_c() {
    let remote = || FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
    let local = || FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
    for command in [
        "/opt/homebrew/bin/tmux send-keys -t %7 x",
        "bash -c 'tmux send-keys -t %7 x'",
        "sh -c \"tmux send-keys -t %7 x\"",
        "cd /tmp && tmux send-keys -t %7 x",
        "echo hi | tmux load-buffer - ; tmux paste-buffer -t %7",
    ] {
        assert_blocked(evaluate(&bash(command), &remote()), RULE_TMUX_INPUT, command);
        assert_allowed(evaluate(&bash(command), &local()), command);
    }
}

#[test]
fn input_whose_target_cannot_be_read_is_blocked_if_any_pane_on_the_server_is_remote() {
    for command in [
        r#"tmux send-keys "$P" x"#,
        r#"tmux send-keys -t "$(cat /tmp/target)" x"#,
        "tmux send-keys -t $TARGET x",
        r#"tmux send-keys -t "$T" x"#,
    ] {
        let remote_by_title = FakeProbe::default()
            .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, "staging:x:y", LOCAL_SHELL);
        assert_blocked(evaluate(&bash(command), &remote_by_title), RULE_TMUX_INPUT, command);

        let remote_by_process = FakeProbe::default()
            .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, "shell", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(command), &remote_by_process), RULE_TMUX_INPUT, command);

        let all_local = FakeProbe::default()
            .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, "editor", &["vim"]);
        assert_allowed(evaluate(&bash(command), &all_local), command);

        assert_allowed(evaluate(&bash(command), &FakeProbe::default()), "no tmux server answers");
    }
}

#[test]
fn a_remote_pane_on_another_server_does_not_block_input_that_cannot_be_aimed() {
    let probe = FakeProbe::default().other_pane_on(TmuxSocket::Name("work".into()), "demo:ap:portal", REMOTE_SHELL);
    assert_allowed(evaluate(&bash(r#"tmux send-keys "$P" x"#), &probe), "default server has no remote pane");
    assert_blocked(evaluate(&bash(r#"tmux -L work send-keys "$P" x"#), &probe), RULE_TMUX_INPUT, "work server does");
}

#[test]
fn a_target_that_does_not_resolve_is_treated_as_unknown_and_the_server_decides() {
    // `-t %9` is not a pane the probe knows: tmux would error, but the guard must not assume safe.
    let with_remote = FakeProbe::default().pane_on(DEFAULT, "%1", "production:ap:portal", REMOTE_SHELL);
    assert_blocked(evaluate(&send_to("%9"), &with_remote), RULE_TMUX_INPUT, "unknown target, remote pane exists");

    let all_local = FakeProbe::default().pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL);
    assert_allowed(evaluate(&send_to("%9"), &all_local), "unknown target, no remote pane");
}

#[test]
fn a_probe_that_fails_where_the_answer_matters_is_an_error_not_an_allow() {
    // Can't tell which pane, and the server could not even be listed.
    let probe = FakeProbe::default().all_panes_fail_with(timeout());
    let verdict = evaluate(&bash(r#"tmux send-keys "$P" x"#), &probe);
    assert!(matches!(verdict, Err(GuardError::Probe(_))), "{verdict:?}");

    // A named target whose lookup timed out falls back to the whole server ...
    let remote_elsewhere = FakeProbe::default()
        .pane_lookup_fails_with(DEFAULT, "%7", timeout())
        .other_pane_on(DEFAULT, "prod:ap:portal", LOCAL_SHELL);
    assert_blocked(evaluate(&send_to("%7"), &remote_elsewhere), RULE_TMUX_INPUT, "lookup failed, remote pane exists");

    let all_local = FakeProbe::default()
        .pane_lookup_fails_with(DEFAULT, "%7", timeout())
        .other_pane_on(DEFAULT, "zsh", LOCAL_SHELL);
    assert_allowed(evaluate(&send_to("%7"), &all_local), "lookup failed, no pane is remote");

    // ... and if that fails too there is no answer.
    let both = FakeProbe::default()
        .pane_lookup_fails_with(DEFAULT, "%7", timeout())
        .all_panes_fail_with(timeout());
    let verdict = evaluate(&send_to("%7"), &both);
    assert!(matches!(verdict, Err(GuardError::Probe(_))), "{verdict:?}");
}

#[test]
fn a_tmux_command_the_guard_cannot_parse_is_checked_against_every_pane() {
    // tmux reached through python: the guard cannot see the command, only that tmux input is
    // involved, so it asks whether any pane is remote.
    let command = r#"python3 -c "import os; os.system('tmux send-keys -t %7 x')""#;

    let remote = FakeProbe::default().other_pane_on(DEFAULT, "demo:ap:portal", REMOTE_SHELL);
    assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, "remote pane exists");

    assert_allowed(evaluate(&bash(command), &FakeProbe::default()), "no remote pane");
}

#[test]
fn tmux_commands_that_send_no_input_are_allowed_without_probing() {
    // The gate is textual: `tmux` plus an input verb. Reading panes and listing them is fine.
    for command in ["tmux list-panes -a", "tmux ls", "tmux capture-pane -p -t %7", "tmux display-message -p -t %7 '#{pane_title}'"] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%7", "production:ap:portal", REMOTE_SHELL);
        assert_allowed(evaluate(&bash(command), &probe), command);
        assert_eq!(probe.calls(), 0, "{command}");
    }
}

// ── hook_settings_json, deny_output_json, messages ───────────────────────────────────────

#[test]
fn the_messages_are_the_contract_text() {
    assert_eq!(
        GUARD_MESSAGE,
        "Blocked by Nostromo's production-shell guard: agents may not open or type into production shells. Give the user the command to run themselves."
    );
    assert_eq!(
        FAIL_CLOSED_MESSAGE,
        "Blocked by Nostromo's production-shell guard: the guard could not run, so this call was blocked."
    );
    assert_eq!(GUARD_SENTINEL_PATH, "/nonexistent/nostromo-guard");
}

#[test]
fn the_deny_output_is_the_exact_pre_tool_use_deny_decision() {
    let expected = r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked by Nostromo's production-shell guard: agents may not open or type into production shells. Give the user the command to run themselves."}}"#;
    assert_eq!(deny_output_json(), expected);
    assert!(deny_output_json().contains(GUARD_MESSAGE));
}

#[test]
fn the_session_settings_json_is_byte_for_byte_the_contract() {
    let expected = r##"{"disableAllHooks":false,"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"'/opt/x/nostromo-guard' pre-tool-use || { echo \"Blocked by Nostromo's production-shell guard: the guard could not run, so this call was blocked.\" >&2; exit 2; }","timeout":30}]}]}}"##;

    let json = hook_settings_json(Path::new("/opt/x/nostromo-guard"));

    assert_eq!(json, expected);
    let parsed: Value = serde_json::from_str(&json).expect("valid JSON");
    assert_eq!(parsed["disableAllHooks"], json!(false), "a user setting cannot switch the guard off");
}

#[test]
fn a_guard_path_with_spaces_and_quotes_is_shell_quoted_inside_valid_json() {
    let json = hook_settings_json(Path::new("/tmp/my dir/it's/nostromo-guard"));
    let command = hook_command_of(&json);
    assert!(command.starts_with(r"'/tmp/my dir/it'\''s/nostromo-guard' pre-tool-use"), "{command}");

    let json = hook_settings_json(Path::new(r#"/tmp/a"b\c/nostromo-guard"#));
    let command = hook_command_of(&json);
    assert!(command.starts_with(r#"'/tmp/a"b\c/nostromo-guard' pre-tool-use"#), "{command}");
}

#[test]
fn the_guard_path_resolves_to_a_nostromo_guard_binary_or_the_failing_sentinel() {
    let resolved = resolve_guard_path();
    if std::env::var_os(GUARD_BIN_ENV).is_none_or(|v| v.is_empty()) {
        assert_eq!(resolved.file_name().and_then(|n| n.to_str()), Some("nostromo-guard"), "{resolved:?}");
    }
}

fn hook_command_of(settings_json: &str) -> String {
    let settings: Value = serde_json::from_str(settings_json).expect("settings are valid JSON");
    settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        .as_str()
        .expect("a command string")
        .to_owned()
}

// ── subprocess harness ───────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct Run {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn run_with_stdin(mut cmd: Command, stdin: &[u8]) -> Run {
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn");
    let mut input = child.stdin.take().unwrap();
    let data = stdin.to_vec();
    // The child may exit without reading everything (oversized or refused input): ignore EPIPE.
    let writer = std::thread::spawn(move || {
        let _ = input.write_all(&data);
    });
    let out = child.wait_with_output().expect("wait");
    writer.join().unwrap();
    Run {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

/// A hermetic home for one guard run: its own approvals dir, HOME and an empty TMUX_TMPDIR, so
/// no real tmux server, audit log or config can be reached.
struct Sandbox {
    _root: tempfile::TempDir,
    approvals: PathBuf,
    home: PathBuf,
    tmux_tmp: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let tmux_tmp = root.path().join("tmux");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&tmux_tmp).unwrap();
        Self { approvals: root.path().join("approvals"), home, tmux_tmp, _root: root }
    }

    fn arm(&self, cmd: &mut Command) {
        cmd.env("NOSTROMO_APPROVALS_DIR", &self.approvals)
            .env("HOME", &self.home)
            .env("TMUX_TMPDIR", &self.tmux_tmp)
            .env("NOSTROMO_FOCUS_TAG", "focus-x")
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .env_remove("NOSTROMO_GUARD_TEST_PANIC");
    }

    fn guard(&self, args: &[&str], stdin: &[u8]) -> Run {
        self.guard_with(args, stdin, |_| {})
    }

    fn guard_with(&self, args: &[&str], stdin: &[u8], tweak: impl FnOnce(&mut Command)) -> Run {
        let mut cmd = Command::new(GUARD_BIN);
        cmd.args(args);
        self.arm(&mut cmd);
        tweak(&mut cmd);
        run_with_stdin(cmd, stdin)
    }

    fn pre_tool_use(&self, payload: &Value) -> Run {
        self.guard(&["pre-tool-use"], payload.to_string().as_bytes())
    }

    /// Every audit line written so far, with the file it is in.
    fn audit_lines(&self) -> Vec<(String, Entry)> {
        let Ok(read) = std::fs::read_dir(&self.approvals) else { return vec![] };
        let mut out = vec![];
        for f in read {
            let path = f.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            if !(name.starts_with("audit-") && name.ends_with(".jsonl")) {
                continue;
            }
            for line in std::fs::read_to_string(&path).unwrap().lines() {
                let entry: Entry = serde_json::from_str(line).unwrap_or_else(|e| panic!("{name}: `{line}`: {e}"));
                out.push((name.clone(), entry));
            }
        }
        out
    }
}

fn mode_of(p: &Path) -> u32 {
    std::fs::metadata(p).unwrap().permissions().mode() & 0o777
}

fn trimmed(s: &str) -> &str {
    s.trim()
}

// ── the nostromo-guard binary ────────────────────────────────────────────────────────────

#[test]
fn a_blocked_call_prints_the_deny_decision_and_leaves_exactly_one_audit_entry() {
    let blocks: Vec<Fixture> = fixtures("block_").into_iter().filter(|f| !needs_a_tmux_world(&f.name)).collect();
    assert!(blocks.len() >= 15, "{}", blocks.len());
    for f in blocks {
        let sb = Sandbox::new();

        let run = sb.pre_tool_use(&f.raw);

        assert_eq!(run.code, Some(0), "{}: {run:?}", f.name);
        assert_eq!(trimmed(&run.stdout), deny_output_json(), "{}", f.name);
        let lines = sb.audit_lines();
        assert_eq!(lines.len(), 1, "{}: one audit entry per block: {lines:?}", f.name);
        let (file, entry) = &lines[0];
        assert_eq!(entry.v, 1, "{}", f.name);
        assert_eq!(entry.tag.as_deref(), Some("focus-x"), "{}", f.name);
        assert_eq!(entry.session_id.as_deref(), Some("s-1"), "{}", f.name);
        assert_eq!(entry.tool_use_id.as_deref(), Some("toolu_1"), "{}", f.name);
        assert_eq!(file, &format!("audit-{}.jsonl", entry.ts.format("%Y-%m-%d")), "{}: UTC daily file", f.name);
        let age = chrono::Utc::now() - entry.ts;
        assert!(age.num_seconds().abs() < 120, "{}: ts is now: {}", f.name, entry.ts);
        match &entry.event {
            Event::GuardBlocked { tool_name, input, rule, .. } => {
                assert_eq!(tool_name, f.raw["tool_name"].as_str().unwrap(), "{}", f.name);
                assert_eq!(input, &f.raw["tool_input"], "{}: the full input, as received", f.name);
                assert_eq!(rule, rule_for(&f.name), "{}", f.name);
            }
            other => panic!("{}: expected guard_blocked, got {other:?}", f.name),
        }
    }
}

#[test]
fn an_allowed_call_prints_nothing_and_writes_no_audit_entry() {
    let allows: Vec<Fixture> = fixtures("allow_").into_iter().filter(|f| !needs_a_tmux_world(&f.name)).collect();
    assert!(allows.len() >= 8, "{}", allows.len());
    for f in allows {
        let sb = Sandbox::new();

        let run = sb.pre_tool_use(&f.raw);

        assert_eq!(run.code, Some(0), "{}: {run:?}", f.name);
        assert_eq!(run.stdout, "", "{}", f.name);
        assert!(sb.audit_lines().is_empty(), "{}", f.name);
        assert!(!sb.approvals.exists() || std::fs::read_dir(&sb.approvals).unwrap().next().is_none(), "{}: no audit file", f.name);
    }
}

#[test]
fn input_that_cannot_be_aimed_is_allowed_when_no_tmux_server_answers_and_when_tmux_is_missing() {
    let payload = json!({ "tool_name": "Bash", "tool_input": { "command": r#"tmux send-keys "$P" x"# } });

    let no_server = Sandbox::new().pre_tool_use(&payload);
    assert_eq!((no_server.code, no_server.stdout.as_str()), (Some(0), ""), "{no_server:?}");

    // `tmux` is not on PATH at all (a tmux outside /usr/bin and /bin is not found).
    let no_tmux = Sandbox::new().guard_with(&["pre-tool-use"], payload.to_string().as_bytes(), |c| {
        c.env("PATH", "/usr/bin:/bin");
    });
    assert_eq!((no_tmux.code, no_tmux.stdout.as_str()), (Some(0), ""), "{no_tmux:?}");
}

#[test]
fn a_large_ordinary_payload_is_still_evaluated_and_allowed() {
    let content = "a".repeat(1024 * 1024);
    let payload = json!({ "tool_name": "Write", "tool_input": { "file_path": "/tmp/big.txt", "content": content } });

    let run = Sandbox::new().pre_tool_use(&payload);

    assert_eq!((run.code, run.stdout.as_str()), (Some(0), ""), "{:?}", run.stderr);
}

#[test]
fn a_payload_with_no_tool_input_is_judged_on_its_tool_name() {
    let sb = Sandbox::new();

    let run = sb.pre_tool_use(&json!({ "session_id": "s-1", "tool_use_id": "toolu_9", "tool_name": "mcp__ecs__ecs_connect" }));

    assert_eq!(run.code, Some(0), "{run:?}");
    assert_eq!(trimmed(&run.stdout), deny_output_json());
    let lines = sb.audit_lines();
    assert_eq!(lines.len(), 1);
    match &lines[0].1.event {
        Event::GuardBlocked { input, rule, .. } => {
            assert_eq!(input, &json!({}), "missing tool_input is recorded as {{}}");
            assert_eq!(rule, RULE_TOOL_NAME);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_audit_directory_and_file_are_private_to_the_user() {
    let sb = Sandbox::new();
    assert!(!sb.approvals.exists(), "the guard must create it itself");

    sb.pre_tool_use(&json!({ "tool_name": "Bash", "tool_input": { "command": "ecs_connect ap production portal" } }));

    assert_eq!(mode_of(&sb.approvals), 0o700);
    let files: Vec<_> = std::fs::read_dir(&sb.approvals).unwrap().map(|e| e.unwrap().path()).collect();
    assert_eq!(files.len(), 1, "{files:?}");
    assert_eq!(mode_of(&files[0]), 0o600);
}

#[test]
fn a_block_is_never_downgraded_to_an_allow_when_the_audit_log_cannot_be_written() {
    let sb = Sandbox::new();
    // The approvals "directory" is a file, so no audit line can be written.
    std::fs::write(&sb.approvals, "not a directory").unwrap();

    let run = sb.pre_tool_use(&json!({ "tool_name": "Bash", "tool_input": { "command": "ecs_connect ap production portal" } }));

    let denied = trimmed(&run.stdout) == deny_output_json() && run.code == Some(0);
    let failed_closed = run.code == Some(2);
    assert!(denied || failed_closed, "must deny or fail closed, never allow: {run:?}");
}

#[test]
fn input_the_guard_cannot_understand_fails_closed() {
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("not JSON", b"this is not json".to_vec()),
        ("empty stdin", vec![]),
        ("a JSON array", b"[1,2,3]".to_vec()),
        ("no tool_name", br#"{"tool_input":{"command":"ls"}}"#.to_vec()),
        ("truncated JSON", br#"{"tool_name":"Bash","tool_input":{"command":"l"#.to_vec()),
    ];
    for (what, stdin) in cases {
        let run = Sandbox::new().guard(&["pre-tool-use"], &stdin);
        assert_eq!(run.code, Some(2), "{what}: {run:?}");
        assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{what}: {}", run.stderr);
        assert_eq!(run.stdout, "", "{what}");
    }
}

#[test]
fn stdin_over_four_mebibytes_fails_closed() {
    let command = "x".repeat(4 * 1024 * 1024 + 16);
    let payload = json!({ "tool_name": "Bash", "tool_input": { "command": command } });

    let run = Sandbox::new().pre_tool_use(&payload);

    assert_eq!(run.code, Some(2), "{:?}", run.stderr);
    assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{}", run.stderr);
    assert_eq!(run.stdout, "");
}

#[test]
fn an_unknown_or_missing_subcommand_fails_closed() {
    for args in [&["frobnicate"][..], &[][..]] {
        let run = Sandbox::new().guard(args, br#"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#);
        assert_eq!(run.code, Some(2), "{args:?}: {run:?}");
        assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{args:?}: {}", run.stderr);
        assert_eq!(run.stdout, "", "{args:?}");
    }
}

#[test]
fn a_panic_inside_the_guard_fails_closed() {
    // Debug builds honour NOSTROMO_GUARD_TEST_PANIC (the tests run in debug).
    if !cfg!(debug_assertions) {
        return;
    }
    for payload in [
        json!({ "tool_name": "Bash", "tool_input": { "command": "git status" } }),
        json!({ "tool_name": "Bash", "tool_input": { "command": "ecs_connect ap production portal" } }),
    ] {
        let sb = Sandbox::new();
        let run = sb.guard_with(&["pre-tool-use"], payload.to_string().as_bytes(), |c| {
            c.env("NOSTROMO_GUARD_TEST_PANIC", "1");
        });
        assert_eq!(run.code, Some(2), "{run:?}");
        assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{}", run.stderr);
        assert_eq!(run.stdout, "");
    }
}

// ── the /bin/sh wrapper Claude runs ──────────────────────────────────────────────────────

fn run_hook_command(command: &str, sb: &Sandbox, stdin: &[u8]) -> Run {
    let mut cmd = Command::new("/bin/sh");
    cmd.arg("-c").arg(command);
    sb.arm(&mut cmd);
    run_with_stdin(cmd, stdin)
}

fn write_script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn when_the_guard_binary_is_missing_the_hook_blocks_the_call() {
    // T-AP0g-2: a wrong or deleted path must not turn the guard off.
    let command = hook_command_of(&hook_settings_json(Path::new("/nonexistent/dir/nostromo-guard")));

    let run = run_hook_command(&command, &Sandbox::new(), br#"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#);

    assert_eq!(run.code, Some(2), "{run:?}");
    assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{}", run.stderr);
}

#[test]
fn when_the_guard_binary_crashes_the_hook_blocks_the_call() {
    let dir = tempfile::tempdir().unwrap();
    let broken = dir.path().join("nostromo-guard");
    write_script(&broken, "exit 1");
    let command = hook_command_of(&hook_settings_json(&broken));

    let run = run_hook_command(&command, &Sandbox::new(), b"{}");

    assert_eq!(run.code, Some(2), "{run:?}");
    assert!(run.stderr.contains(FAIL_CLOSED_MESSAGE), "{}", run.stderr);
}

#[test]
fn the_hook_runs_a_guard_whose_path_has_spaces_and_quotes() {
    let dir = tempfile::tempdir().unwrap();
    let odd = dir.path().join("my dir").join("it's").join("nostromo-guard");
    write_script(&odd, r#"printf 'ran:%s' "$1""#);
    let command = hook_command_of(&hook_settings_json(&odd));

    let run = run_hook_command(&command, &Sandbox::new(), b"{}");

    assert_eq!((run.code, run.stdout.as_str()), (Some(0), "ran:pre-tool-use"), "{run:?}");
}

#[test]
fn through_the_hook_a_remote_shell_is_denied_and_an_ordinary_call_is_silent() {
    let command = hook_command_of(&hook_settings_json(Path::new(GUARD_BIN)));

    let blocked = run_hook_command(
        &command,
        &Sandbox::new(),
        br#"{"session_id":"s","tool_use_id":"t","tool_name":"Bash","tool_input":{"command":"aws ssm start-session --target i-1"}}"#,
    );
    assert_eq!(blocked.code, Some(0), "{blocked:?}");
    assert_eq!(trimmed(&blocked.stdout), deny_output_json());

    let allowed = run_hook_command(
        &command,
        &Sandbox::new(),
        br#"{"session_id":"s","tool_use_id":"t","tool_name":"Bash","tool_input":{"command":"git status"}}"#,
    );
    assert_eq!((allowed.code, allowed.stdout.as_str()), (Some(0), ""), "{allowed:?}");

    let garbage = run_hook_command(&command, &Sandbox::new(), b"garbage");
    assert_eq!(garbage.code, Some(2), "{garbage:?}");
}

// ── the real probe, against a private tmux server ────────────────────────────────────────

/// A throwaway tmux server on the sandbox's own TMUX_TMPDIR (never the user's server).
struct PrivateTmux<'a> {
    sb: &'a Sandbox,
}

impl<'a> PrivateTmux<'a> {
    /// `None` when tmux is not installed (the probe cannot be exercised then).
    fn start(sb: &'a Sandbox, first_pane_shell_command: &str) -> Option<Self> {
        let ok = Command::new("tmux").arg("-V").output().map(|o| o.status.success()).unwrap_or(false);
        if !ok {
            eprintln!("tmux is not installed: skipping the real-probe test");
            return None;
        }
        let this = Self { sb };
        let out = this.tmux(&["new-session", "-d", "-x", "100", "-y", "30", first_pane_shell_command]);
        assert!(out.status.success(), "tmux new-session: {}", String::from_utf8_lossy(&out.stderr));
        Some(this)
    }

    fn tmux(&self, args: &[&str]) -> std::process::Output {
        let mut cmd = Command::new("tmux");
        cmd.args(args);
        self.sb.arm(&mut cmd);
        cmd.output().expect("tmux")
    }

    fn first_pane_id(&self) -> String {
        let out = self.tmux(&["list-panes", "-a", "-F", "#{pane_id}"]);
        String::from_utf8_lossy(&out.stdout).lines().next().expect("a pane").trim().to_owned()
    }

    fn title_it(&self, pane: &str, title: &str) {
        let out = self.tmux(&["select-pane", "-t", pane, "-T", title]);
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    }
}

impl Drop for PrivateTmux<'_> {
    fn drop(&mut self) {
        let _ = self.tmux(&["kill-server"]);
    }
}

#[test]
fn against_a_real_tmux_server_input_to_a_production_titled_pane_is_blocked_and_to_a_local_pane_is_not() {
    let sb = Sandbox::new();
    let Some(tmux) = PrivateTmux::start(&sb, "sleep 300") else { return };
    let pane = tmux.first_pane_id();
    let send = json!({ "session_id": "s", "tool_use_id": "t", "tool_name": "Bash",
                       "tool_input": { "command": format!("tmux send-keys -t {pane} 'ls' Enter") } });

    tmux.title_it(&pane, "zsh");
    let local = sb.pre_tool_use(&send);
    assert_eq!((local.code, local.stdout.as_str()), (Some(0), ""), "a local pane: {local:?}");

    tmux.title_it(&pane, "production:ap:portal");
    let remote = sb.pre_tool_use(&send);
    assert_eq!(remote.code, Some(0), "{remote:?}");
    assert_eq!(trimmed(&remote.stdout), deny_output_json(), "a pane titled like an ECS shell");

    let untargeted = json!({ "session_id": "s", "tool_use_id": "t", "tool_name": "Bash",
                             "tool_input": { "command": r#"tmux send-keys "$P" x"# } });
    let any_remote = sb.pre_tool_use(&untargeted);
    assert_eq!(trimmed(&any_remote.stdout), deny_output_json(), "can't tell, and a pane is remote: {any_remote:?}");

    tmux.title_it(&pane, "zsh");
    let none_remote = sb.pre_tool_use(&untargeted);
    assert_eq!((none_remote.code, none_remote.stdout.as_str()), (Some(0), ""), "{none_remote:?}");
}

#[test]
fn against_a_real_tmux_server_a_pane_running_a_session_manager_plugin_is_blocked_whatever_its_title() {
    let sb = Sandbox::new();
    // The pane's shell carries the marker in its own arguments, as a real `aws ecs execute-command` would.
    let Some(tmux) = PrivateTmux::start(&sb, "sleep 300; : session-manager-plugin") else { return };
    let pane = tmux.first_pane_id();
    tmux.title_it(&pane, "just a shell");

    let run = sb.pre_tool_use(&json!({ "session_id": "s", "tool_use_id": "t", "tool_name": "Bash",
                                       "tool_input": { "command": format!("tmux send-keys -t {pane} x") } }));

    assert_eq!(trimmed(&run.stdout), deny_output_json(), "{run:?}");
}

// ── latency ──────────────────────────────────────────────────────────────────────────────

/// Not a gate on every run (machines differ): `cargo test --test approvals_guard -- --ignored --nocapture`.
/// The contract's target is p95 < 20 ms on the fast path.
#[test]
#[ignore = "benchmark: run explicitly with --ignored --nocapture"]
fn guard_binary_latency_bench() {
    let sb = Sandbox::new();
    let payload = json!({ "session_id": "s", "tool_use_id": "t", "tool_name": "Bash", "tool_input": { "command": "git status" } })
        .to_string();
    let mut ms: Vec<f64> = Vec::with_capacity(200);
    for _ in 0..200 {
        let start = std::time::Instant::now();
        let run = sb.guard(&["pre-tool-use"], payload.as_bytes());
        ms.push(start.elapsed().as_secs_f64() * 1000.0);
        assert_eq!((run.code, run.stdout.as_str()), (Some(0), ""), "{run:?}");
    }
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50 = ms[ms.len() / 2];
    let p95 = ms[(ms.len() * 95) / 100];
    eprintln!("nostromo-guard fast path over {} runs: p50 = {p50:.1} ms, p95 = {p95:.1} ms (target p95 < 20 ms)", ms.len());
    println!("guard_latency p50_ms={p50:.1} p95_ms={p95:.1}");
}

// ── regressions: bypasses found in security review ───────────────────────────────────────
//
// Each test names the bypass it pins. Every one of them was allowed before its fix.

#[test]
fn bypass_tmux_short_verb_prefixes_reach_the_pane_rule() {
    // tmux runs any unambiguous prefix of a command name: `tmux pi -t %7 cat` is pipe-pane.
    for verb in ["pi", "pip", "pipe-p", "pa", "pas", "paste", "send-k", "send-p", "send-prefix", "SEND-KEYS"] {
        let command = format!("tmux {verb} -t %7 x");
        let remote = FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(&command), &remote), RULE_TMUX_INPUT, &command);
        let local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(&command), &local), &command);
    }
}

#[test]
fn bypass_tmux_short_buffer_verbs_are_checked_against_the_server() {
    // `loa` is load-buffer: the buffer is pasted later, so whichever pane gets it can't be told.
    for verb in ["loa", "lo", "load-b", "set-b", "setb"] {
        let command = format!("tmux {verb} /tmp/x");
        let remote = FakeProbe::default().other_pane_on(DEFAULT, "production:ap:portal", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(&command), &remote), RULE_TMUX_INPUT, &command);
        let local = FakeProbe::default().other_pane_on(DEFAULT, "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(&command), &local), &command);
    }
}

#[test]
fn bypass_tmux_commands_that_run_other_tmux_commands_are_checked() {
    // if-shell, bind-key, run-shell, source-file, … run tmux commands the guard can't see.
    for command in [
        "tmux if-shell true 'pi -t %7 cat'",
        "tmux if true 'loa /tmp/x'",
        "tmux bind-key x pi -t %7 cat",
        "tmux run-shell -C 'pi -t %7 cat'",
        "tmux source-file /tmp/cmds.tmux",
        "tmux source /tmp/cmds.tmux",
        "tmux set-hook -g pane-focus-in 'pi -t %7 cat'",
        "tmux confirm-before 'pi -t %7 cat'",
        "tmux command-prompt -I x 'pi -t %7 cat'",
        "tmux \"$VERB\" -t %7 x",
    ] {
        let remote = FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, command);
        let local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(command), &local), command);
    }
}

#[test]
fn tmux_short_names_of_read_only_commands_still_make_no_probe_calls() {
    for command in ["tmux ls", "tmux lsp -a", "tmux display -p x", "tmux set -g mouse on", "tmux show -g", "tmux kill-server"] {
        let probe = FakeProbe::default().pane_on(DEFAULT, "%7", "production:ap:portal", REMOTE_SHELL);
        assert_allowed(evaluate(&bash(command), &probe), command);
        assert_eq!(probe.calls(), 0, "{command}");
    }
}

#[test]
fn bypass_uppercase_tmux_is_tmux() {
    // macOS file systems are case-insensitive: `TMUX` runs tmux. Paired with a lowercase call
    // to a local pane, the uppercase one used to go unseen.
    for upper in ["TMUX send-keys -t %7 x", "/opt/homebrew/bin/TMUX send-keys -t %7 x", "Tmux send -t %7 x"] {
        let command = format!("{upper}; tmux send-keys -t %3 y");
        let remote = FakeProbe::default()
            .pane_on(DEFAULT, "%3", "zsh", LOCAL_SHELL)
            .pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
        assert_blocked(evaluate(&bash(&command), &remote), RULE_TMUX_INPUT, &command);
        let local = FakeProbe::default()
            .pane_on(DEFAULT, "%3", "zsh", LOCAL_SHELL)
            .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(&command), &local), &command);
    }
}

#[test]
fn bypass_a_server_the_guard_cannot_name_is_checked_on_every_server() {
    // %7 is local on the default server; the remote pane is on another server.
    let world = || {
        FakeProbe::default()
            .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL)
            .other_pane_on(TmuxSocket::Path("/tmp/other/tmux-501/default".into()), "production:ap:portal", REMOTE_SHELL)
    };
    for command in [
        r#"tmux -L "$S" send-keys -t %7 x"#,
        r#"tmux -S "$SOCK" send-keys -t %7 x"#,
        "TMUX_TMPDIR=/tmp/other tmux send-keys -t %7 x",
        "TMUX=/tmp/other/tmux-501/default,1,0 tmux send-keys -t %7 x",
        "export TMUX_TMPDIR=/tmp/other; tmux send-keys -t %7 x",
        "TMUX_TMPDIR=/tmp/other tmux -L work send-keys -t %7 x",
        r#"python3 -c "import os; os.system('tmux -L work send-keys -t %7 x')""#,
    ] {
        assert_blocked(evaluate(&bash(command), &world()), RULE_TMUX_INPUT, command);
        let all_local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(command), &all_local), command);
    }
}

#[test]
fn bypass_aws_global_options_between_the_service_and_the_operation() {
    for command in [
        "aws ecs --profile p execute-command --cluster c --task t --interactive --command bash",
        "aws ecs --region us-east-1 --profile=p execute-command --cluster c --task t --interactive --command bash",
        "aws --profile p ecs --debug execute-command --cluster c --task t --interactive --command bash",
        "aws ecs --query 'a b' execute-command --cluster c --task t --interactive --command bash",
        "aws ssm --region us-east-1 start-session --target i-1",
        "aws ecs --profile p run-task --cluster c --task-definition td",
        "python3 -c \"import os; os.system('aws ecs --profile p execute-command --cluster c')\"",
    ] {
        assert_blocked(evaluate(&bash(command), &FakeProbe::default()), RULE_COMMAND, command);
    }
    assert_allowed(
        evaluate(&bash("aws ecs --profile p describe-services --cluster c --services s"), &FakeProbe::default()),
        "a read-only call with global options",
    );
}

#[test]
fn bypass_running_the_output_of_ecs_build_command() {
    // ecs_build_command prints the `aws ecs execute-command …` line; running that output opens the shell.
    for command in [
        r#"eval "$(ecs_build_command ap production portal)""#,
        "eval `ecs_build_command ap production portal`",
        "source <(ecs_build_command ap production portal)",
        ". <(ecs_build_command ap production portal)",
        "bash <(ecs_build_command ap production portal)",
        r#"bash -c "$(ecs_build_command ap production portal)""#,
        "$(ecs_build_command ap production portal)",
        "ecs_build_command ap production portal | bash",
        "ecs_build_command ap production portal | sh -s",
        "ecs_build_command ap production portal |& zsh",
        "ecs_build_command ap production portal |\nbash",
        "ecs_build_command ap production portal | cat | bash",
        "(ecs_build_command ap production portal) | bash",
        "{ ecs_build_command ap production portal; } | source /dev/stdin",
        "ecs_build_command ap production portal > >(bash)",
        "source ~/.claude/layers/carefeed/lib/services/ecs/ecs.sh && eval \"$(ecs_build_command ap production portal)\"",
    ] {
        assert_blocked(evaluate(&bash(command), &FakeProbe::default()), RULE_COMMAND, command);
    }
    for command in [
        "ecs_build_command ap production portal",
        "ecs_build_command ap production portal | pbcopy",
        "ecs_build_command ap production portal || echo failed",
        "source ~/.claude/layers/carefeed/lib/services/ecs/ecs.sh && ecs_build_command ap production portal",
    ] {
        assert_allowed(evaluate(&bash(command), &FakeProbe::default()), command);
    }
}

#[test]
fn bypass_a_guard_that_outlives_the_hook_timeout_blocks_instead() {
    // The session kills a hook at 30 s and lets the call through; the guard's watchdog exits 2
    // first. Stdin is left open so the guard waits forever.
    let sandbox = Sandbox::new();
    let mut cmd = Command::new(GUARD_BIN);
    cmd.arg("pre-tool-use").env("NOSTROMO_GUARD_TEST_WATCHDOG_MS", "300");
    sandbox.arm(&mut cmd);
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let started = std::time::Instant::now();
    let mut child = cmd.spawn().expect("spawn");
    let _held_open = child.stdin.take();
    let out = child.wait_with_output().expect("wait");
    assert!(started.elapsed() < std::time::Duration::from_secs(10), "the watchdog fired");
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains(FAIL_CLOSED_MESSAGE) && stderr.contains("timed out"), "{stderr}");
}

#[test]
fn bypass_a_tmux_planted_on_path_does_not_answer_for_the_real_one() {
    let fixed = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/opt/local/bin/tmux"];
    if !fixed.iter().any(|p| Path::new(p).is_file()) {
        eprintln!("skipped: no tmux at a fixed install path");
        return;
    }
    let sandbox = Sandbox::new();
    let bin = sandbox.home.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let marker = sandbox.home.join("planted-tmux-ran");
    let fake = bin.join("tmux");
    std::fs::write(&fake, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());

    let payload = json!({"tool_name": "Bash", "tool_input": {"command": "tmux send-keys \"$P\" x"}});
    let run = sandbox.guard_with(&["pre-tool-use"], payload.to_string().as_bytes(), |c| {
        c.env("PATH", &path);
    });
    assert_eq!(run.code, Some(0), "{run:?}");
    assert!(!marker.exists(), "the guard ran the tmux planted on PATH");
}
