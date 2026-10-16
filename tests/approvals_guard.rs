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

use nostromo::approvals::audit::{Entry, Event, MAX_RECORDED_STRING_BYTES};
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
    pending: HashMap<(TmuxSocket, String), String>,
    pending_errors: HashMap<(TmuxSocket, String), ProbeError>,
    next_pid: u32,
    calls: AtomicUsize,
    pending_calls: AtomicUsize,
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

    /// The line the cursor is on in pane `target` (what `pending_input` reports).
    fn pending_on(mut self, socket: TmuxSocket, target: &str, line: &str) -> Self {
        self.pending.insert((socket, target.into()), line.into());
        self
    }

    fn pending_fails_with(mut self, socket: TmuxSocket, target: &str, e: ProbeError) -> Self {
        self.pending_errors.insert((socket, target.into()), e);
        self
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    /// How many times the guard asked what a pane has typed on its prompt line.
    fn pending_calls(&self) -> usize {
        self.pending_calls.load(Ordering::SeqCst)
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

    fn pending_input(&self, socket: &TmuxSocket, target: &str) -> Result<Option<String>, ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.pending_calls.fetch_add(1, Ordering::SeqCst);
        let key = (socket.clone(), target.to_string());
        if let Some(e) = self.pending_errors.get(&key) {
            return Err(e.clone());
        }
        Ok(self.pending.get(&key).cloned())
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
    // if-shell, bind-key, run-shell, … run tmux commands the guard can't see. (`source-file` was
    // here too: round 2 makes it allowed while a pane is remote when the call has no input
    // command, see `benign_tmux_source_file_of_a_plain_path_is_allowed_while_a_pane_is_remote`.)
    for command in [
        "tmux if-shell true 'pi -t %7 cat'",
        "tmux if true 'loa /tmp/x'",
        "tmux bind-key x pi -t %7 cat",
        "tmux run-shell -C 'pi -t %7 cat'",
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

// ── regressions: bypasses found in the follow-up automated security review ──────────────

#[test]
fn bypass_a_tmux_command_alias_is_not_a_safe_command() {
    // `command-alias` makes any name a tmux command; a name tmux doesn't define can't be told.
    let command = "tmux set -s command-alias[100] zz=send-keys; tmux zz -t %7 x";
    let remote = FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
    assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, command);
    let local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
    assert_allowed(evaluate(&bash(command), &local), command);
}

#[test]
fn bypass_opaque_tmux_text_is_checked_whatever_the_word_order() {
    // The input verb comes before `tmux` in a string the tokenizer can't follow.
    let command = r#"python3 -c "k='send-keys -t %7 x'; import os; os.system('tmux ' + k)""#;
    let remote = FakeProbe::default().other_pane_on(DEFAULT, "production:ap:portal", REMOTE_SHELL);
    assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, command);
    assert_allowed(evaluate(&bash(command), &FakeProbe::default()), "no remote pane");
}

#[test]
fn bypass_a_tmux_word_hidden_from_the_text_count() {
    // `$'\x74mux'` is tmux only after quote removal; it used to hide the opaque python call.
    let command = r#"$'\x74mux' ls; python3 -c "import os; os.system('tmux send-keys -t %7 x')""#;
    let remote = FakeProbe::default().pane_on(DEFAULT, "%7", "bash", REMOTE_SHELL);
    assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, command);
    let local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
    assert_allowed(evaluate(&bash(command), &local), command);
}

#[test]
fn bypass_aws_option_values_the_option_pattern_did_not_model() {
    // Inside a string the tokenizer can't follow, `--query a b` broke the option-shaped regex.
    for command in [
        r#"python3 -c "import os; os.system('aws ecs --query a b execute-command --cluster c')""#,
        r#"python3 -c "import os; os.system('aws ssm --query a b start-session --target i-1')""#,
    ] {
        assert_blocked(evaluate(&bash(command), &FakeProbe::default()), RULE_COMMAND, command);
    }
}

#[test]
fn bypass_unsetting_the_tmux_environment_moves_the_server() {
    let world = || {
        FakeProbe::default()
            .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL)
            .other_pane_on(TmuxSocket::Path("/tmp/tmux-501/default".into()), "production:ap:portal", REMOTE_SHELL)
    };
    for command in [
        "unset TMUX; tmux send-keys -t %7 x",
        "env -u TMUX tmux send-keys -t %7 x",
        "env -i tmux send-keys -t %7 x",
        "env --ignore-environment tmux send-keys -t %7 x",
    ] {
        assert_blocked(evaluate(&bash(command), &world()), RULE_TMUX_INPUT, command);
        let all_local = FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(command), &all_local), command);
    }
}

#[test]
fn bypass_a_command_alias_change_is_checked_against_the_server() {
    // Once set, `command-alias[100] ls=send-keys` makes a later `tmux ls -t %7 x` type into %7.
    let command = "tmux set -s command-alias[100] ls=send-keys";
    let remote = FakeProbe::default().other_pane_on(DEFAULT, "production:ap:portal", REMOTE_SHELL);
    assert_blocked(evaluate(&bash(command), &remote), RULE_TMUX_INPUT, command);
    let local = FakeProbe::default().other_pane_on(DEFAULT, "zsh", LOCAL_SHELL);
    assert_allowed(evaluate(&bash(command), &local), command);
}

#[test]
fn bypass_aws_service_and_operation_on_different_lines_of_opaque_text() {
    let command = "python3 -c \"import os; os.system('''aws ecs --profile p\nexecute-command --cluster c''')\"";
    assert_blocked(evaluate(&bash(command), &FakeProbe::default()), RULE_COMMAND, command);
}

// ── regressions: review fix-ups (split typing, expansions, renamed tmux, relative targets) ─
//
// Every `bypass_*` test below failed on the code that preceded its fix.

const REMOTE_TITLE: &str = "production:ap:portal";

fn work() -> TmuxSocket {
    TmuxSocket::Name("work".into())
}

/// A server with one local pane, `%0`.
fn local_world() -> FakeProbe {
    FakeProbe::default().pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL)
}

/// `%0` local and `%1` an ECS shell.
fn remote_pane_world() -> FakeProbe {
    FakeProbe::default().pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL).pane_on(DEFAULT, "%1", REMOTE_TITLE, REMOTE_SHELL)
}

/// `%0` and `%1` local, and a remote pane nobody addresses.
fn remote_elsewhere_world() -> FakeProbe {
    FakeProbe::default()
        .pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL)
        .other_pane_on(DEFAULT, REMOTE_TITLE, REMOTE_SHELL)
}

/// `%0` and `%1` local, nothing remote anywhere.
fn all_local_world() -> FakeProbe {
    FakeProbe::default().pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL).pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL)
}

/// Every command must be blocked by `rule` in the world `world` builds. Reports all that are not,
/// so one run shows the whole gap.
#[track_caller]
fn assert_all_blocked(commands: &[&str], rule: &str, what: &str, world: impl Fn() -> FakeProbe) {
    let failures: Vec<String> = commands
        .iter()
        .filter_map(|c| {
            let verdict = evaluate(&bash(c), &world());
            (rule_of(&verdict) != Some(rule)).then(|| format!("  {c:?} -> {verdict:?}"))
        })
        .collect();
    assert!(failures.is_empty(), "{what}: expected a block by `{rule}` for:\n{}", failures.join("\n"));
}

/// Every command must be allowed in the world `world` builds. Reports all that are not.
#[track_caller]
fn assert_all_allowed(commands: &[&str], what: &str, world: impl Fn() -> FakeProbe) {
    let failures: Vec<String> = commands
        .iter()
        .filter_map(|c| {
            let verdict = evaluate(&bash(c), &world());
            (verdict != Ok(GuardVerdict::Allow)).then(|| format!("  {c:?} -> {verdict:?}"))
        })
        .collect();
    assert!(failures.is_empty(), "{what}: expected an allow for:\n{}", failures.join("\n"));
}

// ── B1: markers typed through split send-keys arguments ──────────────────────────────────

const TYPED_MARKERS: &[&str] = &[
    // arguments are joined with no separator; Space and Enter are keys
    "tmux send-keys -t %0 ecs_c onnect Space ap Enter",
    "tmux send-keys -t %0 e c s _ c o n n e c t Enter",
    r#"tmux send-keys -t %0 "aws ecs exe" "cute-command --cluster c" Enter"#,
    r#"tmux send-keys -t %0 "aws ssm start-" "session --target i-1" Enter"#,
    // across calls of one command string
    "tmux send-keys -l 'ecs_'; tmux send-keys -l 'connect'",
    "tmux send-keys -l 'ecs_' && tmux send-keys -l 'connect'",
    "tmux send-keys -t %0 -l 'ecs_'; tmux send-keys -t %2 -l 'connect'",
    "tmux send-keys -t %0 -l ecs_; sleep 1; tmux send-keys -t %0 -l connect",
    r"tmux send-keys -t %0 -l ecs_ \; send-keys -t %0 -l connect",
    "/tmp/t send-keys -t %0 -l ecs_; /tmp/t send-keys -t %0 -l connect",
    // -H takes hex bytes: this spells ecs_connect
    "tmux send-keys -t %0 -H 65 63 73 5f 63 6f 6e 6e 65 63 74",
    // typed text that is a marker only after line editing
    "tmux send-keys -t %0 ecs_cX BSpace onnect",
    "tmux send-keys -t %0 nnect Home ecs_co End",
    "tmux send-keys -t %0 ecs_conect Left Left Left n",
    "tmux send-keys -t %0 ecs_connec Left Right t",
    "tmux send-keys -t %0 ecs_connec Home End t",
    // a buffer filled in pieces, then pasted
    "tmux set-buffer -b a 'ecs_'; tmux set-buffer -a -b a 'connect'; tmux paste-buffer -b a -t %0",
    "tmux set-buffer 'aws ecs exec'; tmux set-buffer -a 'ute-command'; tmux paste-buffer -t %0",
    // text the pane's shell expands into a marker
    "tmux send-keys -t %0 -l 'ecs_${U}connect'",
    "tmux send-keys -t %0 -l 'aws ecs execute-comman{d,}'",
    "tmux send-keys -t %0 -l 'ecs_{connect,}'",
];

#[test]
fn bypass_split_send_keys_arguments_spell_a_marker() {
    // No tmux server, or only a local pane: the text itself is what is wrong.
    assert_all_blocked(TYPED_MARKERS, RULE_COMMAND, "no tmux server", FakeProbe::default);
    assert_all_blocked(TYPED_MARKERS, RULE_COMMAND, "a local pane", local_world);
}

#[test]
fn a_marker_typed_through_send_keys_is_decided_without_probing() {
    for command in TYPED_MARKERS {
        let probe = local_world();
        let verdict = evaluate(&bash(command), &probe);
        assert_eq!(rule_of(&verdict), Some(RULE_COMMAND), "{command}: {verdict:?}");
        assert_eq!(probe.calls(), 0, "{command}: no tmux was asked");
    }
}

#[test]
fn typing_ordinary_text_into_a_local_pane_stays_allowed() {
    const TYPED: &[&str] = &[
        "tmux send-keys -t %0 'cargo test' Enter",
        "tmux send-keys -t %0 C-c",
        "tmux send-keys -t %0 -l 'echo ecs'",
        "tmux send-keys -t %0 'ls ~/Code/ecs-tools' Enter",
        "tmux send-keys -t %0 -l 'ecs_' ; tmux send-keys -t %0 'info'",
        "tmux send-keys -t %0 -l 'aws ecs describe-clusters'",
        // with -l every argument is text, so `BSpace` is not a key: this types `ecs_conXBSpacenect`
        "tmux send-keys -t %0 -l ecs_conX BSpace nect",
        // editing that does not end in a marker
        "tmux send-keys -t %0 ecs_connec Left x",
        // Enter ends the line: the shell sees `ecs_` and then `connect`
        "tmux send-keys -t %0 ecs_ Enter connect",
    ];
    assert_all_allowed(TYPED, "no tmux server", FakeProbe::default);
    assert_all_allowed(TYPED, "a local pane", local_world);
}

#[test]
fn bypass_a_marker_completed_on_the_prompt_line_the_pane_already_holds() {
    // The pane shows `ecs_` at its prompt; typing `connect` finishes the command.
    for (pending, command) in [
        ("user@host % ecs_", "tmux send-keys -t %0 -l connect"),
        ("user@host % ecs_", "tmux send-keys -t %0 connect Enter"),
        ("aws ecs ", "tmux send-keys -t %0 -l execute-command"),
        ("$ aws ssm start-", "tmux send-keys -t %0 -l session"),
        ("% session-manager-", "tmux send-keys -t %0 -l plugin"),
    ] {
        let probe = local_world().pending_on(DEFAULT, "%0", pending);
        assert_blocked(evaluate(&bash(command), &probe), RULE_COMMAND, &format!("{pending:?} + {command}"));
    }
}

#[test]
fn text_the_pane_shows_does_not_count_unless_the_typed_text_completes_a_marker_with_it() {
    for (pending, command) in [
        // the marker is entirely in what the pane already shows
        ("output: ecs_connect", "tmux send-keys -t %0 -l ls Enter"),
        ("output: ecs_connect", "tmux send-keys -t %0 Space ls Enter"),
        ("user@host % # was: aws ecs execute-command", "tmux send-keys -t %0 -l ' && ls'"),
        // joined, it is not a marker
        ("user@host % ecs ", "tmux send-keys -t %0 -l connect"),
        ("user@host % ecs_", "tmux send-keys -t %0 -l info"),
    ] {
        let probe = local_world().pending_on(DEFAULT, "%0", pending);
        assert_allowed(evaluate(&bash(command), &probe), &format!("{pending:?} + {command}"));
    }
}

#[test]
fn a_pane_whose_prompt_line_cannot_be_read_does_not_stop_typing_into_it() {
    let command = "tmux send-keys -t %0 -l connect";

    assert_allowed(evaluate(&bash(command), &local_world()), "pending_input says it cannot tell (Ok(None))");

    let failing = local_world().pending_fails_with(DEFAULT, "%0", timeout());
    let verdict = evaluate(&bash(command), &failing);
    assert_allowed(verdict, "pending_input fails: the call is not an error and not a block");
    assert!(failing.pending_calls() >= 1, "it was asked");
}

#[test]
fn the_prompt_line_is_only_read_when_something_is_typed() {
    for command in ["tmux send-keys -t %0 Enter", "tmux send-keys -t %0 C-c", "tmux send-keys -t %0 Enter Enter"] {
        let probe = local_world().pending_on(DEFAULT, "%0", "user@host % ecs_");
        assert_allowed(evaluate(&bash(command), &probe), command);
        assert_eq!(probe.pending_calls(), 0, "{command}: nothing typed, so nothing to join");
    }
}

// ── B2: brace expansion and empty expansions ─────────────────────────────────────────────

/// Command lines real bash runs as a marker, with the environment each needs to do so.
const EXPANDS_TO_A_MARKER: &[(&str, &[(&str, &str)])] = &[
    ("ecs_{connect,} ap production portal", &[]),
    ("ecs_{conn,x}{ect,} ap", &[]),
    ("ecs_{connect,{a,b}} ap", &[]),
    ("ecs_run_tas{k,} ap production portal", &[]),
    ("aws ecs execute-comman{d,} --cluster c", &[]),
    ("aws ssm start-sessio{n,} --target i-1", &[]),
    ("aws ecs run-tas{k,} --cluster c", &[]),
    ("aws ec{s,} execute-command --cluster c", &[]),
    ("aws {ecs,execute-command} --cluster c", &[]),
    ("ecs_${U}connect ap production portal", &[]),
    ("ecs_$@connect ap", &[]),
    ("ecs_$*connect ap", &[]),
    ("ecs_$()connect ap", &[]),
    ("ecs_``connect ap", &[]),
    ("ecs_$(echo)connect ap", &[]),
    ("ecs_c${x:-o}nnect ap", &[]),
    ("aws ecs execute-${U}command --cluster c", &[]),
    ("aws ecs run-${U}task --cluster c", &[]),
    (r#""ecs_"$U"connect" ap production portal"#, &[]),
    ("${P}session-manager-plugin x", &[]),
    // an earlier word that is only known at run time can be the service
    ("aws $S execute-command --cluster c", &[("S", "ecs")]),
];

fn real_bash() -> Option<&'static str> {
    ["/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"].into_iter().find(|p| Path::new(p).is_file())
}

/// The words real bash makes of `line`. Nothing but `printf` runs (plus whatever a `$( )` in
/// the line holds, which here is only `echo`), in an empty environment.
fn bash_words(shell: &str, line: &str, env: &[(&str, &str)]) -> Vec<String> {
    let out = Command::new(shell)
        .args(["--norc", "--noprofile", "-c"])
        .arg(format!("printf '%s\\n' {line}"))
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .envs(env.iter().copied())
        .output()
        .expect("run bash");
    assert!(out.status.success(), "bash rejected {line:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).lines().map(str::to_owned).collect()
}

/// Whether these words, run as a command, would open a remote shell (the rule, restated).
fn words_open_a_remote_shell(words: &[String]) -> bool {
    let lower: Vec<String> = words.iter().map(|w| w.to_lowercase()).collect();
    if lower.iter().any(|w| ["ecs_connect", "ecs_shell", "ecs_open_tmux_pane", "ecs_run_task", "session-manager-plugin"].contains(&w.as_str())) {
        return true;
    }
    let then = |first: &str, op: &str| lower.iter().position(|w| w == first).is_some_and(|i| lower[i + 1..].iter().any(|w| w == op));
    then("ecs", "execute-command") || then("ssm", "start-session") || then("ecs", "run-task")
}

#[test]
fn bypass_expansions_that_real_bash_turns_into_a_marker_are_blocked() {
    let shell = real_bash();
    if shell.is_none() {
        eprintln!("no bash installed: checking the guard without the proof that bash expands these");
    }
    let mut failures = Vec::new();
    for (line, env) in EXPANDS_TO_A_MARKER {
        if let Some(shell) = shell {
            let words = bash_words(shell, line, env);
            if !words_open_a_remote_shell(&words) {
                failures.push(format!("  TEST BUG: bash does not turn {line:?} into a marker: {words:?}"));
            }
        }
        let verdict = evaluate(&bash(line), &FakeProbe::default());
        if rule_of(&verdict) != Some(RULE_COMMAND) {
            failures.push(format!("  {line:?} -> {verdict:?}"));
        }
    }
    assert!(failures.is_empty(), "expected a block by `{RULE_COMMAND}` for:\n{}", failures.join("\n"));
}

#[test]
fn bypass_brace_and_empty_expansions_spell_a_marker_inside_wrappers() {
    let mut commands: Vec<String> = Vec::new();
    for inner in ["ecs_{connect,} ap production portal", "aws ecs execute-comman{d,} --cluster c", "ecs_${U}connect ap"] {
        commands.push(format!("bash -c '{inner}'"));
        commands.push(format!("sh -c \"{inner}\""));
        commands.push(format!("eval \"{inner}\""));
        commands.push(format!("eval '{inner}'"));
        commands.push(format!("bash <<EOF\n{inner}\nEOF"));
        commands.push(format!("bash <<'EOF'\n{inner}\nEOF"));
        commands.push(format!("cd /tmp && {inner}"));
        commands.push(format!("echo start; ({inner})"));
    }
    let refs: Vec<&str> = commands.iter().map(String::as_str).collect();
    assert_all_blocked(&refs, RULE_COMMAND, "wrapped", FakeProbe::default);
}

/// Run `evaluate` on its own thread so a guard that tries to enumerate a huge expansion fails
/// this test instead of hanging the run.
fn evaluate_within(command: &str, limit: std::time::Duration) -> Result<GuardVerdict, GuardError> {
    let command = command.to_owned();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(evaluate(&bash(&command), &FakeProbe::default()));
    });
    rx.recv_timeout(limit).unwrap_or_else(|_| panic!("evaluate did not finish within {limit:?}"))
}

#[test]
fn bypass_a_word_with_more_expansions_than_the_cap_is_blocked_not_enumerated() {
    // 26 * 26 * 26 = 17576 words, and the cap is 4096 per word.
    for command in [
        "echo {a..z}{a..z}{a..z}",
        "bash -c 'echo {a..z}{a..z}{a..z}'",
        "echo {a,b,c,d,e,f,g,h}{a,b,c,d,e,f,g,h}{a,b,c,d,e,f,g,h}{a,b,c,d,e,f,g,h}{a,b,c,d,e,f,g,h}",
        // 26^8 is about 2 * 10^11: counting it must not mean building it
        "echo {a..z}{a..z}{a..z}{a..z}{a..z}{a..z}{a..z}{a..z}",
    ] {
        let verdict = evaluate_within(command, std::time::Duration::from_secs(20));
        assert_blocked(verdict, RULE_COMMAND, command);
    }
}

#[test]
fn numeric_ranges_and_small_expansions_are_not_counted_against_the_cap() {
    assert_all_allowed(
        &[
            "echo {1..100000}",
            "for i in {1..5000}; do echo $i; done",
            "echo {a..z}{a..z}",
            "mkdir -p src/{a,b,c}/{x,y,z}",
        ],
        "under the cap",
        FakeProbe::default,
    );
}

#[test]
fn benign_commands_stay_allowed() {
    const BENIGN: &[&str] = &[
        "tmux ls",
        "tmux capture-pane -p -t %0",
        r#"git commit -m "fix ecs""#,
        "cargo test",
        "echo ecs",
        "ls ~/Code/ecs-tools",
        "cp file.{js,ts,tsx} dir/",
        "mkdir -p src/{a,b,c}/{x,y,z}",
        r#"echo ${HOME}/bin $PATH "$@""#,
        "rm -rf build/{debug,release}",
        r#"curl -d '{"a":1,"b":2}' http://localhost/x"#,
        "aws ecs describe-clusters --cluster c",
        "aws ecs list-tasks",
        "aws s3 ls",
        "docker build -t ${name}-task .",
        "echo $ECS_CONNECT",
        "echo ${X:-default}",
        "uv pip install foo",
        "grep pi file",
        "cargo run",
        "npm run build",
        "git log --oneline | head",
        "ssh-keygen -t ed25519",
        "kubectl get pods",
        r#"python3 -c "print('hello')""#,
        "ls /opt/homebrew/bin",
    ];
    let mut failures = Vec::new();
    for (world, probe) in [("no tmux server", FakeProbe::default as fn() -> FakeProbe), ("a local-only tmux server", local_world as fn() -> FakeProbe)] {
        for command in BENIGN {
            let verdict = evaluate(&bash(command), &probe());
            if verdict != Ok(GuardVerdict::Allow) {
                failures.push(format!("  [{world}] {command:?} -> {verdict:?}"));
            }
        }
    }
    assert!(failures.is_empty(), "ordinary commands must not be blocked:\n{}", failures.join("\n"));
}

// ── B3: a renamed, linked or obfuscated tmux is still tmux ───────────────────────────────

/// Input commands aimed at `%1`, through a tmux the text does not call `tmux`.
const RENAMED_TMUX_TO_PANE_1: &[&str] = &[
    "ln -s $(which tmux) /tmp/t; /tmp/t send-keys -t %1 x Enter",
    "/tmp/t send-keys -t %1 x Enter",
    "tm[u]x send-keys -t %1 x Enter",
    "t* send-keys -t %1 x Enter",
    "tm$Uux send-keys -t %1 x Enter",
    "tm{u,u}x send-keys -t %1 x Enter",
    "tmu${U}x send-keys -t %1 x Enter",
    "cd /opt/homebrew/bin; ./t?ux send-keys -t %1 x Enter",
    "exec -a x /opt/homebrew/bin/tmu? send-keys -t %1 x Enter",
    "xargs /tmp/t send-keys -t %1 x",
    "/tmp/t pasteb -t %1",
    "/tmp/t send -t %1 x",
    "/tmp/t pipe-pane -t %1 'cat'",
];

#[test]
fn bypass_a_renamed_tmux_is_still_tmux() {
    assert_all_blocked(RENAMED_TMUX_TO_PANE_1, RULE_TMUX_INPUT, "%1 is a remote pane", remote_pane_world);
}

#[test]
fn a_renamed_tmux_typing_into_a_local_pane_is_allowed() {
    // (`ln -s $(which tmux) …` names tmux as a word of its own, which can reasonably make the
    // call "can't tell" while a remote pane is open anywhere: it is only held to the worlds
    // with no remote pane.)
    let aimed_at_a_local_pane: Vec<&str> = RENAMED_TMUX_TO_PANE_1.iter().copied().filter(|c| !c.starts_with("ln -s")).collect();
    assert_all_allowed(&aimed_at_a_local_pane, "%1 is local, a remote pane is elsewhere", remote_elsewhere_world);
    assert_all_allowed(RENAMED_TMUX_TO_PANE_1, "no remote pane", all_local_world);
    assert_all_allowed(RENAMED_TMUX_TO_PANE_1, "no tmux server", FakeProbe::default);
}

#[test]
fn bypass_a_renamed_tmux_with_no_target_is_checked_against_every_pane_of_the_server() {
    let untargeted = [
        "/tmp/t send-keys x Enter",
        "tm[u]x send-keys x Enter",
        "tm$Uux send-keys x Enter",
        "xargs /tmp/t send-keys x",
        "/tmp/t paste-buffer",
    ];
    assert_all_blocked(&untargeted, RULE_TMUX_INPUT, "a remote pane exists", remote_elsewhere_world);
    assert_all_allowed(&untargeted, "no remote pane", all_local_world);
}

#[test]
fn bypass_a_renamed_tmux_on_a_named_server_is_checked_on_that_server() {
    let command = "/tmp/t -L work send-keys -t %1 x";
    let remote_on_work = || FakeProbe::default().pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL).pane_on(work(), "%1", REMOTE_TITLE, REMOTE_SHELL);
    let local_on_work = || FakeProbe::default().pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL).pane_on(work(), "%1", "zsh", LOCAL_SHELL);
    assert_blocked(evaluate(&bash(command), &remote_on_work()), RULE_TMUX_INPUT, command);
    assert_allowed(evaluate(&bash(command), &local_on_work()), command);
}

#[test]
fn bypass_tmux_driven_from_an_interpreter_is_checked_against_every_pane_of_every_server() {
    let commands = [
        r#"python3 -c 'import libtmux; s=libtmux.Server(); s.panes[0].send_keys("x")'"#,
        r#"python3 -c 'import os; os.system("t"+"mux send-keys -t %1 x Enter")'"#,
    ];
    assert_all_blocked(&commands, RULE_TMUX_INPUT, "remote pane on the default server", remote_pane_world);
    assert_all_blocked(&commands, RULE_TMUX_INPUT, "remote pane on another server", || {
        FakeProbe::default().pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL).other_pane_on(work(), REMOTE_TITLE, REMOTE_SHELL)
    });
    assert_all_allowed(&commands, "no remote pane", all_local_world);
    assert_all_allowed(&commands, "no tmux server", FakeProbe::default);
}

#[test]
fn bypass_a_path_that_resolves_to_the_real_tmux_is_tmux_whatever_it_is_called() {
    let fixed = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/opt/local/bin/tmux"];
    let Some(real) = fixed.iter().find(|p| Path::new(p).is_file()) else {
        eprintln!("skipped: no tmux at a fixed install path");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let zz = dir.path().join("zz");
    std::os::unix::fs::symlink(real, &zz).unwrap();
    let zz = zz.display();

    // A tmux command that is not an input verb: it can run other tmux commands, so it can't be told.
    let indirect = [format!("{zz} run-shell 'true'"), format!("{zz} \"$VERB\" -t %1 x")];
    let indirect: Vec<&str> = indirect.iter().map(String::as_str).collect();
    assert_all_blocked(&indirect, RULE_TMUX_INPUT, "a remote pane exists", remote_elsewhere_world);
    assert_all_allowed(&indirect, "no remote pane", all_local_world);
    assert_all_allowed(&indirect, "no tmux server", FakeProbe::default);

    let direct = [format!("{zz} send-keys -t %1 x")];
    let direct: Vec<&str> = direct.iter().map(String::as_str).collect();
    assert_all_blocked(&direct, RULE_TMUX_INPUT, "%1 is remote", remote_pane_world);
    assert_all_allowed(&direct, "%1 is local", remote_elsewhere_world);

    // Control: a link to a program that is not tmux gets no tmux treatment for its arguments.
    let other = dir.path().join("yy");
    std::os::unix::fs::symlink("/bin/echo", &other).unwrap();
    let not_tmux = [format!("{} \"$VERB\" -t %1 x", other.display())];
    let not_tmux: Vec<&str> = not_tmux.iter().map(String::as_str).collect();
    assert_all_allowed(&not_tmux, "a link to echo", remote_elsewhere_world);
}

#[test]
fn bypass_respawn_pane_with_k_kills_the_production_shell() {
    let kills_remote = [
        "tmux respawn-pane -k -t %1 'zsh'",
        "tmux respawn-pane -kt %1",
        "tmux respawn-pane -t %1 -k",
        "tmux respawnp -k -t %1",
    ];
    assert_all_blocked(&kills_remote, RULE_TMUX_INPUT, "%1 is remote", remote_pane_world);

    // Without -k, respawn-pane refuses to touch a live pane; -k on a local pane is fine.
    assert_all_allowed(&["tmux respawn-pane -t %1", "tmux respawn-pane -k -t %0", "tmux respawn-pane -kt %0"], "harmless", remote_pane_world);
    assert_all_allowed(&kills_remote, "%1 is local", remote_elsewhere_world);
}

#[test]
fn bypass_respawn_pane_with_k_and_a_target_that_cannot_be_told_is_checked_against_the_server() {
    let dynamic = [r#"tmux respawn-pane -k "$P""#, r#"tmux respawn-pane -k -t "$P""#, "tmux respawn-pane -k"];
    assert_all_blocked(&dynamic, RULE_TMUX_INPUT, "a remote pane exists", remote_elsewhere_world);
    assert_all_allowed(&dynamic, "no remote pane", all_local_world);
    assert_all_allowed(&dynamic, "no tmux server", FakeProbe::default);
}

#[test]
fn tmux_commands_that_are_not_input_stay_allowed_while_a_pane_is_remote() {
    assert_all_allowed(
        &[
            "tmux ls",
            "tmux capture-pane -p -t %0",
            "tmux display-message -p -t %0 '#{pane_title}'",
            "tmux list-panes -a",
            "ls -la",
            "cargo test",
            "git commit -m x",
            r#"python3 -c "print(1)""#,
            "/tmp/t send-keys -t %0 x Enter",
            "tm[u]x send-keys -t %0 x Enter",
        ],
        "a remote pane is open elsewhere",
        remote_pane_world,
    );
}

#[test]
fn a_command_that_names_no_marker_and_no_tmux_makes_no_probe_calls() {
    for command in ["cargo test", "ls ~/Code/ecs-tools", "git commit -m x", "ls -la", r#"python3 -c "print(1)""#, "echo ecs"] {
        let probe = remote_pane_world();
        assert_allowed(evaluate(&bash(command), &probe), command);
        assert_eq!(probe.calls(), 0, "{command}");
    }
}

// ── nits ─────────────────────────────────────────────────────────────────────────────────

#[test]
fn bypass_relative_pane_targets_are_resolved_by_tmux_from_where_the_agent_is_so_they_cannot_be_told() {
    for target in ["{next}", "{previous}", "{last}", "{top}", "{up-of}", ":+1", "!"] {
        let command = format!("tmux send-keys -t {target} x");
        // A probe resolves the target from its own position, so it can answer "a local pane"
        // for a target that, for the agent, is the remote one.
        let remote = FakeProbe::default().pane_on(DEFAULT, target, "zsh", LOCAL_SHELL).other_pane_on(DEFAULT, REMOTE_TITLE, REMOTE_SHELL);
        assert_blocked(evaluate(&bash(&command), &remote), RULE_TMUX_INPUT, &command);

        let all_local = FakeProbe::default().pane_on(DEFAULT, target, "zsh", LOCAL_SHELL).other_pane_on(DEFAULT, "zsh", LOCAL_SHELL);
        assert_allowed(evaluate(&bash(&command), &all_local), &command);
    }
}

#[test]
fn bypass_tmux_pane_from_the_environment_aims_input_at_a_pane_the_guard_cannot_name() {
    // The remote pane is on a server the default lookup would never visit.
    let world = || {
        FakeProbe::default()
            .pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL)
            .other_pane_on(TmuxSocket::Path("/tmp/other/tmux-501/default".into()), REMOTE_TITLE, REMOTE_SHELL)
    };
    let commands = ["TMUX_PANE=%1 tmux send-keys x", "export TMUX_PANE=%1; tmux send-keys x", "env TMUX_PANE=%1 tmux send-keys x"];
    assert_all_blocked(&commands, RULE_TMUX_INPUT, "a remote pane on another server", world);
    assert_all_allowed(&commands, "all panes local", || FakeProbe::default().pane_on(DEFAULT, "%7", "zsh", LOCAL_SHELL));
}

#[test]
fn tool_names_that_contain_an_ecs_shell_tool_are_blocked_by_name() {
    for tool in [
        "mcp__x__ecs_connect_tool",
        "ecs_connect_session",
        "my_ecs_shell",
        "mcp__a__ecs_open_tmux_pane_v2",
        "ecs_run_task2",
    ] {
        assert_blocked(evaluate(&tool_call(tool, json!({})), &FakeProbe::default()), RULE_TOOL_NAME, tool);
    }
    for tool in ["Bash", "mcp__x__ecs_info", "ecs_build_command", "ecs_copy_command", "mcp__x__ecs_list_tasks", "Read"] {
        assert_allowed(evaluate(&tool_call(tool, json!({})), &FakeProbe::default()), tool);
    }
}

#[test]
fn bypass_the_audit_entry_of_a_block_shows_hidden_characters_and_is_capped() {
    let sb = Sandbox::new();
    let command = format!("\u{202e}ecs_connect ap production portal {}", "x".repeat(100 * 1024));
    let payload = json!({ "session_id": "s-1", "tool_use_id": "toolu_1", "tool_name": "Bash",
                          "tool_input": { "command": command, "description": "x" } });

    let run = sb.pre_tool_use(&payload);

    assert_eq!(run.code, Some(0), "{:?}", run.stderr);
    assert_eq!(trimmed(&run.stdout), deny_output_json());
    let lines = sb.audit_lines();
    assert_eq!(lines.len(), 1, "{}", lines.len());
    match &lines[0].1.event {
        Event::GuardBlocked { input, detail, .. } => {
            let recorded = input["command"].as_str().expect("the command is recorded");
            assert!(!recorded.contains('\u{202e}'), "a raw U+202E reached the log");
            assert!(recorded.contains("\u{27E8}U+202E\u{27E9}"), "it is shown as its code point");
            assert!(recorded.contains("ecs_connect"), "what was matched is still readable");
            assert!(recorded.contains("\u{2026}[truncated"), "the cut is marked");
            assert!(recorded.len() <= MAX_RECORDED_STRING_BYTES + 64, "{} bytes recorded", recorded.len());
            assert_eq!(input["description"], json!("x"), "other fields are kept");
            assert!(!detail.as_deref().unwrap_or_default().contains('\u{202e}'), "detail: {detail:?}");
        }
        other => panic!("{other:?}"),
    }
    for file in std::fs::read_dir(&sb.approvals).unwrap() {
        let text = std::fs::read_to_string(file.unwrap().path()).unwrap();
        assert!(!text.contains('\u{202e}'), "the audit file holds a raw U+202E");
    }
}

#[test]
fn bypass_a_symlinked_audit_file_is_not_written_through_by_the_guard() {
    let sb = Sandbox::new();
    std::fs::create_dir_all(&sb.approvals).unwrap();
    let victim = sb.home.join("victim.txt");
    std::fs::write(&victim, "keep me\n").unwrap();
    // Today's file, whichever UTC day the run lands on.
    let today = chrono::Utc::now().date_naive();
    for offset in [-1, 0, 1] {
        let day = today + chrono::Duration::days(offset);
        std::os::unix::fs::symlink(&victim, sb.approvals.join(format!("audit-{}.jsonl", day.format("%Y-%m-%d")))).unwrap();
    }

    let run = sb.pre_tool_use(&json!({ "tool_name": "Bash", "tool_input": { "command": "ecs_connect ap production portal" } }));

    let denied = trimmed(&run.stdout) == deny_output_json() && run.code == Some(0);
    assert!(denied || run.code == Some(2), "must deny or fail closed, never allow: {run:?}");
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep me\n", "the link target was written to");
}

#[test]
fn the_guards_own_tmux_probes_ignore_the_agents_tmux_environment() {
    let ok = Command::new("tmux").arg("-V").output().map(|o| o.status.success()).unwrap_or(false);
    if !ok {
        eprintln!("tmux is not installed: skipping the scrubbed-environment test");
        return;
    }
    // A short path: a unix socket path is limited to about 100 bytes.
    let dir = tempfile::Builder::new().prefix("rg").tempdir_in("/tmp").unwrap();
    let sock = dir.path().join("s");
    let sb = Sandbox::new();
    let tmux = |args: &[&str]| {
        let out = Command::new("tmux")
            .arg("-S")
            .arg(&sock)
            .args(["-f", "/dev/null"])
            .args(args)
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .output()
            .expect("tmux");
        assert!(out.status.success(), "tmux {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    struct KillServer<'a>(&'a Path);
    impl Drop for KillServer<'_> {
        fn drop(&mut self) {
            let _ = Command::new("tmux").arg("-S").arg(self.0).arg("kill-server").output();
        }
    }
    tmux(&["new-session", "-d", "-x", "100", "-y", "30", "sleep 300"]);
    let _cleanup = KillServer(&sock);
    let pane = tmux(&["list-panes", "-a", "-F", "#{pane_id}"]).lines().next().expect("a pane").trim().to_owned();
    let payload = json!({ "session_id": "s", "tool_use_id": "t", "tool_name": "Bash",
                          "tool_input": { "command": format!("tmux -S {} send-keys -t {pane} x", sock.display()) } });
    let hostile = |c: &mut Command| {
        c.env("TMUX", "/nonexistent/sock,1,0").env("TMUX_PANE", "%99").env("TMUX_TMPDIR", dir.path());
    };

    tmux(&["select-pane", "-t", pane.as_str(), "-T", REMOTE_TITLE]);
    let remote = sb.guard_with(&["pre-tool-use"], payload.to_string().as_bytes(), hostile);
    assert_eq!(remote.code, Some(0), "{remote:?}");
    assert_eq!(trimmed(&remote.stdout), deny_output_json(), "a remote pane is still found: {remote:?}");

    tmux(&["select-pane", "-t", pane.as_str(), "-T", "zsh"]);
    let local = sb.guard_with(&["pre-tool-use"], payload.to_string().as_bytes(), hostile);
    assert_eq!((local.code, local.stdout.as_str()), (Some(0), ""), "a local pane is still allowed: {local:?}");
}

// ── round 2 review fixes (B4: tmux state changes, B5: editing keys, false positives) ─────
//
// RED tests: every `bypass_*` test below fails on the code that precedes its fix, and so do
// the `benign_*` tests that name a mention of a marker or `tmux source-file`. Tests for things
// that must stay blocked or allowed may already pass; they pin the behaviour while the fixes land.

type World = fn() -> FakeProbe;

fn three_worlds() -> [(&'static str, World); 3] {
    [
        ("no tmux server", FakeProbe::default as World),
        ("a local-only tmux server", local_world as World),
        ("a remote pane is open", remote_pane_world as World),
    ]
}

/// Every command in every one of the three worlds: allowed (`expect == None`) or blocked by the
/// rule named. Reports every (world, command) that is not.
#[track_caller]
fn assert_in_every_world(commands: &[&str], what: &str, expect: Option<&str>) {
    let mut failures = Vec::new();
    for (world_name, world) in three_worlds() {
        for command in commands {
            let verdict = evaluate(&bash(command), &world());
            let ok = match expect {
                None => verdict == Ok(GuardVerdict::Allow),
                Some(rule) => rule_of(&verdict) == Some(rule),
            };
            if !ok {
                failures.push(format!("  [{world_name}] {command:?} -> {verdict:?}"));
            }
        }
    }
    let wanted = expect.map_or_else(|| "an allow".to_owned(), |r| format!("a block by `{r}`"));
    assert!(failures.is_empty(), "{what}: expected {wanted} for:\n{}", failures.join("\n"));
}

/// Every command must be blocked, by whichever rule. Reports all that are not.
#[track_caller]
fn assert_all_blocked_by_any_rule(commands: &[&str], what: &str, world: impl Fn() -> FakeProbe) {
    let failures: Vec<String> = commands
        .iter()
        .filter_map(|c| {
            let verdict = evaluate(&bash(c), &world());
            (!matches!(verdict, Ok(GuardVerdict::Block { .. }))).then(|| format!("  {c:?} -> {verdict:?}"))
        })
        .collect();
    assert!(failures.is_empty(), "{what}: expected a block (any rule) for:\n{}", failures.join("\n"));
}

// ── B4: a state-changing tmux command in the same call moves what a target means ─────────
//
// The guard resolves `-t prod` to the pane that is active when the hook runs. An earlier command
// in the same call can change which pane that is. So with any state-changing (or "can't tell")
// tmux command in the call, every target that is not a `%N` pane id is "can't tell".

/// `%0` is local, `%1` is an ECS shell, and every other target the tests aim at resolves to a
/// LOCAL pane: a guard that looks only at what the target resolves to now would allow them.
fn state_change_world() -> FakeProbe {
    FakeProbe::default()
        .pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "%1", REMOTE_TITLE, REMOTE_SHELL)
        .pane_on(DEFAULT, "prod", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "work:0.1", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "prod:1.0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "{last}", "zsh", LOCAL_SHELL)
}

/// The same targets, no remote pane anywhere.
fn state_change_all_local_world() -> FakeProbe {
    FakeProbe::default()
        .pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "%1", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "prod", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "work:0.1", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "prod:1.0", "zsh", LOCAL_SHELL)
        .pane_on(DEFAULT, "{last}", "zsh", LOCAL_SHELL)
}

/// tmux commands that change what the active pane / window / session is, or may (an unknown name
/// may be a `command-alias`; `if-shell` and `run-shell` run anything).
const TMUX_STATE_CHANGES: &[&str] = &[
    "tmux select-pane -t %0",
    "tmux select-pane -U",
    "tmux select-window -t 0",
    "tmux select-layout even-horizontal",
    "tmux last-pane",
    "tmux last-window",
    "tmux kill-pane -t %0",
    "tmux kill-window -t 1",
    "tmux swap-pane -U",
    "tmux swap-window -t 1",
    "tmux join-pane -s %0",
    "tmux break-pane -d",
    "tmux move-window -t 5",
    "tmux move-pane -t 1",
    "tmux next-window",
    "tmux next-layout",
    "tmux previous-window",
    "tmux previous-layout",
    "tmux new-window -d",
    "tmux split-window -d",
    "tmux new-session -d -s x",
    "tmux rename-window x",
    "tmux rename-session x",
    // aliases and prefixes tmux accepts
    "tmux selectp -t %0",
    "tmux selectw -t 0",
    "tmux lastp",
    "tmux killp -t %0",
    "tmux select-p -t %0",
    "tmux swapp -U",
    "tmux neww -d",
    "tmux splitw -d",
    // a name tmux does not define may be a command-alias for any of the above
    "tmux foo",
    // commands that run other commands
    "tmux if-shell true 'select-pane -t %0'",
    "tmux run-shell 'tmux select-pane -t %0'",
];

fn then_send_keys(first: &str, target: &str) -> String {
    format!("{first}; tmux send-keys -t {target} x")
}

#[test]
fn bypass_a_tmux_state_change_before_a_send_keys_makes_every_session_or_window_target_unknown() {
    // The examples from the review, spelled out.
    let spelled_out = [
        "tmux select-pane -t %0; tmux send-keys -t prod 'echo PWNED' Enter",
        "tmux kill-pane -t %1; tmux send-keys -t prod x",
        "tmux last-pane; tmux send-keys -t prod x",
        "tmux select-pane -U; tmux send-keys -t prod x",
        "tmux select-window -t 0 && tmux send-keys -t 0 x",
        r"tmux select-pane -t %0 \; send-keys -t prod x",
        r"tmux select-pane -t %0 \; send-keys -t 0 x",
        "tmux select-pane -t %0 || tmux send-keys -t prod x",
        "tmux select-pane -t %0\ntmux send-keys -t prod x",
        "bash -c 'tmux select-pane -t %0; tmux send-keys -t prod x'",
        "cd /tmp && tmux select-pane -t %0 && tmux send-keys -t work:0.1 x",
        // the change may come after the send in the text: a call is one unit
        "tmux send-keys -t prod x; tmux select-pane -t %0",
        // no target at all
        "tmux select-pane -t %0; tmux send-keys x",
    ];
    assert_all_blocked(&spelled_out, RULE_TMUX_INPUT, "a state change in the same call", state_change_world);
}

#[test]
fn bypass_every_kind_of_tmux_state_change_defeats_session_window_and_unqualified_targets() {
    let mut commands = Vec::new();
    for change in TMUX_STATE_CHANGES {
        for target in ["prod", "0", "work:0.1", "prod:1.0", "{last}"] {
            commands.push(then_send_keys(change, target));
        }
        commands.push(format!("{change}; tmux send-keys x"));
    }
    let refs: Vec<&str> = commands.iter().map(String::as_str).collect();
    assert_all_blocked(&refs, RULE_TMUX_INPUT, "a state change in the same call", state_change_world);
}

#[test]
fn bypass_a_pane_id_after_a_state_change_is_still_probed_and_a_remote_one_is_blocked() {
    assert_all_blocked(
        &[
            "tmux select-pane -t %0; tmux send-keys -t %1 x",
            "tmux last-pane; tmux send-keys -t %1 x Enter",
            "tmux new-window -d; tmux send-keys -t %1 x",
        ],
        RULE_TMUX_INPUT,
        "%1 is the remote pane, whatever ran first",
        state_change_world,
    );
}

#[test]
fn tmux_input_without_a_state_change_in_the_call_still_follows_what_the_target_resolves_to() {
    // The existing behaviour: nothing earlier in the call can move `prod`, so it is the pane it
    // resolves to (a local one), and a remote pane elsewhere on the server does not matter.
    assert_all_allowed(
        &[
            "tmux send-keys -t prod x",
            "tmux send-keys -t 0 x",
            "tmux send-keys -t work:0.1 x",
            "tmux send-keys -t %0 x; tmux send-keys -t prod y",
        ],
        "no state change in the call",
        state_change_world,
    );
}

#[test]
fn tmux_state_changes_followed_by_input_to_a_pane_id_that_is_local_stay_allowed() {
    // `%N` ids are stable: nothing in the call moves them, so the probe's answer stands.
    assert_all_allowed(
        &[
            "tmux select-pane -t %0; tmux send-keys -t %0 x",
            "tmux last-pane; tmux send-keys -t %0 x Enter",
            "tmux new-window -d; tmux send-keys -t %0 'cargo test' Enter",
            r"tmux select-pane -t %0 \; send-keys -t %0 x",
            "tmux kill-window -t 1; tmux send-keys -t %0 x",
        ],
        "a stable pane id that is local",
        state_change_world,
    );
}

#[test]
fn tmux_read_only_commands_before_a_send_keys_do_not_make_its_target_unknown() {
    assert_all_allowed(
        &[
            "tmux list-panes; tmux send-keys -t prod x",
            "tmux list-panes -a; tmux send-keys -t prod x",
            "tmux list-windows; tmux send-keys -t 0 x",
            "tmux list-sessions; tmux send-keys -t prod x",
            "tmux ls; tmux send-keys -t prod x",
            "tmux display-message -p x; tmux send-keys -t prod x",
            "tmux capture-pane -p -t prod; tmux send-keys -t prod x",
            "tmux send-keys -t prod x; tmux list-panes",
        ],
        "read-only tmux commands change nothing",
        state_change_world,
    );
}

#[test]
fn tmux_state_changes_with_no_remote_pane_anywhere_are_allowed() {
    let mut commands = vec![
        "tmux select-pane -t %0; tmux send-keys -t prod x".to_owned(),
        "tmux last-pane; tmux send-keys -t prod x".to_owned(),
        "tmux select-window -t 0 && tmux send-keys -t 0 x".to_owned(),
    ];
    for change in TMUX_STATE_CHANGES {
        commands.push(then_send_keys(change, "prod"));
        commands.push(format!("{change}; tmux send-keys x"));
    }
    let refs: Vec<&str> = commands.iter().map(String::as_str).collect();
    assert_all_allowed(&refs, "nothing remote to type into", all_local_world);
    assert_all_allowed(&refs, "nothing remote to type into, targets resolve to local panes", state_change_all_local_world);
    assert_all_allowed(&refs, "no tmux server", FakeProbe::default);
}

// ── B5: editing and meta keys assemble a marker in a local pane ──────────────────────────
//
// `Key::Other` acts like a space, but `M-b`, `C-y`, `C-t` … edit the line. A call that mixes
// literal text with a key the line-editor model cannot apply exactly is "can't tell".

/// `%0` and `%2` are local; nothing is remote.
fn pane_two_world() -> FakeProbe {
    FakeProbe::default().pane_on(DEFAULT, "%0", "zsh", LOCAL_SHELL).pane_on(DEFAULT, "%2", "zsh", LOCAL_SHELL)
}

/// `%0` and `%2` are local, and an ECS shell is open (`%1`).
fn pane_two_with_remote_elsewhere_world() -> FakeProbe {
    pane_two_world().pane_on(DEFAULT, "%1", REMOTE_TITLE, REMOTE_SHELL)
}

/// Each of these types `ecs_connect` (or another marker) at a bash prompt, by editing the line.
const EDITING_KEYS_SPELL_A_MARKER: &[&str] = &[
    // from the review
    "tmux send-keys -t %2 connect M-b ecs_ Enter",
    "tmux send-keys -t %2 connect M-Left ecs_ Enter",
    "tmux send-keys -t %2 connect C-Left ecs_ Enter",
    "tmux send-keys -t %2 connect C-u ecs_ C-y Enter",
    "tmux send-keys -t %2 ecs_connetc C-t Enter",
    // word motion and word deletion
    "tmux send-keys -t %2 ecs Home M-f _connect Enter",
    "tmux send-keys -t %2 ecs Home C-Right _connect Enter",
    "tmux send-keys -t %2 ecs_junk Left Left Left Left M-d connect Enter",
    "tmux send-keys -t %2 ecs_junk M-BSpace connect Enter",
    "tmux send-keys -t %2 connect M-b ecs_ M-f Enter",
    // transposition, undo
    "tmux send-keys -t %2 ecs_ connect M-t Enter",
    "tmux send-keys -t %2 ecs_ X 'C-_' connect Enter",
    "tmux send-keys -t %2 ecs_ X C-x C-u connect Enter",
    // kill and yank
    "tmux send-keys -t %2 connect C-w ecs_ C-y Enter",
    "tmux send-keys -t %2 connect Home C-k ecs_ C-y Enter",
    "tmux send-keys -t %2 connect C-a C-k ecs_ C-y Enter",
    // in the same command string as the text, in two send-keys
    "tmux send-keys -t %2 connect; tmux send-keys -t %2 M-b ecs_ Enter",
];

/// The same, written with keys the line-editor model does apply (these block today and must keep
/// blocking: they pin the modelled keys next to the ones that are not).
const MODELLED_KEYS_SPELL_A_MARKER: &[&str] = &[
    "tmux send-keys -t %2 connect C-a ecs_ Enter",
    "tmux send-keys -t %2 nnect Home ecs_co End Enter",
    "tmux send-keys -t %2 ecs_cnnect C-b C-b C-b C-b C-b o Enter",
    "tmux send-keys -t %2 ecs_conect C-b C-b C-b C-b C-f n Enter",
    "tmux send-keys -t %2 ecs_connec Left Left Right Right t Enter",
    "tmux send-keys -t %2 connect Home ecs_ End Enter",
];

#[test]
fn bypass_editing_and_meta_keys_assemble_a_marker_in_a_local_pane() {
    assert_all_blocked(EDITING_KEYS_SPELL_A_MARKER, RULE_COMMAND, "no tmux server", FakeProbe::default);
    assert_all_blocked(EDITING_KEYS_SPELL_A_MARKER, RULE_COMMAND, "only local panes", pane_two_world);
}

#[test]
fn bypass_editing_and_meta_keys_assemble_a_marker_while_a_remote_pane_is_open() {
    // The marker text is found whatever else is on the server; or the call is "can't tell".
    assert_all_blocked_by_any_rule(EDITING_KEYS_SPELL_A_MARKER, "a remote pane is open elsewhere", pane_two_with_remote_elsewhere_world);
}

#[test]
fn bypass_editing_and_meta_keys_assemble_an_aws_marker_in_a_local_pane() {
    let commands = [
        "tmux send-keys -t %2 execute-command M-b 'aws ecs ' Enter",
        "tmux send-keys -t %2 start-session M-b 'aws ssm ' Enter",
        "tmux send-keys -t %2 manager-plugin M-b session- Enter",
        "tmux send-keys -t %2 ecs_shell C-w ecs_ C-y Enter",
    ];
    assert_all_blocked(&commands, RULE_COMMAND, "no tmux server", FakeProbe::default);
    assert_all_blocked(&commands, RULE_COMMAND, "only local panes", pane_two_world);
}

#[test]
fn modelled_editing_keys_that_spell_a_marker_stay_blocked() {
    assert_all_blocked(MODELLED_KEYS_SPELL_A_MARKER, RULE_COMMAND, "no tmux server", FakeProbe::default);
    assert_all_blocked(MODELLED_KEYS_SPELL_A_MARKER, RULE_COMMAND, "only local panes", pane_two_world);
}

const MIXED_WITH_AN_UNMODELLED_KEY: &[&str] = &[
    "tmux send-keys -t %2 'ls' M-b 'x'",
    "tmux send-keys -t %2 'ls -la' M-f Enter",
    "tmux send-keys -t %2 'git status' C-r",
    "tmux send-keys -t %2 'make test' M-d Enter",
    "tmux send-keys -t %2 'ls' C-t Enter",
    "tmux send-keys -t %2 'ls' C-y Enter",
];

#[test]
fn bypass_text_mixed_with_a_key_the_editor_cannot_apply_is_blocked_while_a_remote_pane_is_open() {
    // Fail closed: the line cannot be told, and typing into the wrong shell is worse than a
    // refused keystroke. Whether the rule is `command` or `tmux_input` is the guard's choice.
    assert_all_blocked_by_any_rule(MIXED_WITH_AN_UNMODELLED_KEY, "a remote pane is open elsewhere", pane_two_with_remote_elsewhere_world);
}

#[test]
fn text_mixed_with_a_key_the_editor_cannot_apply_is_allowed_when_it_cannot_spell_a_marker_and_nothing_is_remote() {
    assert_all_allowed(MIXED_WITH_AN_UNMODELLED_KEY, "no tmux server", FakeProbe::default);
    assert_all_allowed(MIXED_WITH_AN_UNMODELLED_KEY, "only local panes", pane_two_world);
}

#[test]
fn ordinary_typing_into_a_local_pane_stays_allowed_with_and_without_a_remote_pane_elsewhere() {
    let ordinary = [
        "tmux send-keys -t %2 ls Enter",
        "tmux send-keys -t %2 C-c",
        "tmux send-keys -t %2 'git status' Enter",
        "tmux send-keys -t %2 'cargo test' Enter",
        "tmux send-keys -t %2 Up Enter",
        "tmux send-keys -t %2 C-l",
        "tmux send-keys -t %2 Escape",
        // modelled exactly, and the result is not a marker
        "tmux send-keys -t %2 'ls -la' Left Left x Enter",
        "tmux send-keys -t %2 'git log --oneline' Home 'echo ' Enter",
    ];
    assert_all_allowed(&ordinary, "no tmux server", FakeProbe::default);
    assert_all_allowed(&ordinary, "only local panes", pane_two_world);
    assert_all_allowed(&ordinary, "a remote pane is open elsewhere", pane_two_with_remote_elsewhere_world);
}

// ── false positives: commands that only MENTION a marker ─────────────────────────────────
//
// A command whose every simple command is an inert program (its arguments are data: git
// commit/log/grep/…, grep, rg, echo, printf, cat/tee/wc/head/tail/sed/awk on files, `gh pr
// create`) and that never puts a marker in command position is not a way to open a shell.

const INERT_MENTIONS: &[&str] = &[
    r#"git commit -m "fix: guard blocks ecs_connect in the shell""#,
    "git commit -m 'docs: aws ecs execute-command is blocked'",
    r#"git commit -m "docs: aws ssm start-session and session-manager-plugin are blocked""#,
    r#"git commit -m "feat: ecs_shell, ecs_run_task and ecs_open_tmux_pane are blocked""#,
    "git grep -n ecs_connect",
    "git log --grep=ecs_connect",
    "git log --oneline -S execute-command",
    "git show HEAD | grep ecs_connect",
    "git diff | grep -n execute-command | head",
    "git add src/ecs_connect.rs",
    r#"git tag -a v1 -m "ecs_connect guard""#,
    r#"git notes add -m "mentions ecs_connect""#,
    "grep -rn ecs_connect docs src",
    "grep -n 'aws ecs execute-command' notes.md",
    "egrep -c 'ecs_shell|ecs_connect' notes.md",
    "fgrep ecs_connect notes.md",
    r#"rg "ecs_connect|execute-command""#,
    "rg -n session-manager-plugin docs",
    "ag ecs_connect src",
    r#"echo "ecs_connect is blocked""#,
    "echo 'aws ecs execute-command is blocked'",
    r#"printf 'ecs_connect\n' > notes.txt"#,
    "echo ecs_connect >> notes.txt",
    r#"echo "ecs_connect" | tee notes.txt"#,
    "wc -l docs/ecs_connect.md",
    "head -n 5 ecs_shell.md",
    "sed -n '1,20p' ecs_connect.md",
    "awk '/ecs_connect/ { print $1 }' notes.md",
    r#"gh pr create --title t --body "mentions ecs_connect""#,
    r#"gh pr comment 5 --body "the guard blocks aws ecs execute-command""#,
    // here-documents written into a file
    "cat <<'EOF' > notes.md\n# Guard\nThe guard blocks ecs_connect and aws ecs execute-command.\nEOF",
    "cat >> notes.md <<EOF\nThe guard blocks ecs_connect.\nEOF",
    "cat > notes.md <<'EOF'\nexample: ecs_connect ap production portal\nEOF",
];

#[test]
fn benign_commands_that_only_mention_a_marker_are_allowed_in_every_world() {
    assert_in_every_world(INERT_MENTIONS, "an inert command that mentions a marker", None);
}

#[test]
fn benign_commands_that_only_mention_a_tmux_input_command_are_allowed_while_a_pane_is_remote() {
    assert_in_every_world(
        &[
            r#"echo "tmux send-keys is how the guard works""#,
            r#"git commit -m "tmux send-keys guard""#,
            "grep -rn 'tmux send-keys' docs src",
            "rg 'send-keys|paste-buffer' src",
            r#"git commit -m "fix: tmux paste-buffer and pipe-pane are input commands""#,
            "echo 'tmux respawn-pane -k kills the shell' >> notes.md",
        ],
        "an inert command that mentions a tmux input command",
        None,
    );
}

#[test]
fn benign_tmux_source_file_of_a_plain_path_is_allowed_while_a_pane_is_remote() {
    // It was "can't tell" (a sourced file may hold any tmux command). With no input command in
    // the same command it cannot type into anything the guard is told about.
    assert_in_every_world(
        &["tmux source-file ~/.tmux.conf", "tmux source-file /tmp/x.conf", "tmux source ~/.tmux.conf"],
        "source-file with no input command in the call",
        None,
    );
}

#[test]
fn tmux_source_file_beside_an_input_command_to_a_remote_pane_is_still_blocked() {
    assert_all_blocked(
        &["tmux source-file ~/.tmux.conf; tmux send-keys -t %1 x", r"tmux source-file ~/.tmux.conf \; send-keys -t %1 x"],
        RULE_TMUX_INPUT,
        "an input command to the remote pane",
        remote_pane_world,
    );
}

#[test]
fn bypass_an_unresolvable_target_is_blocked_while_a_pane_is_remote_and_the_block_says_why() {
    // Session `work` does not exist on the server: the probe answers Ok(None) for the pane.
    // Fail closed (it may be a pane the probe cannot see yet), but say exactly why.
    let command = "tmux send-keys -t work:0.1 ls Enter";
    match evaluate(&bash(command), &remote_pane_world()) {
        Ok(GuardVerdict::Block { rule_id, detail }) => {
            assert_eq!(rule_id, RULE_TMUX_INPUT, "{detail}");
            assert!(detail.contains("work:0.1"), "the detail names the target: {detail:?}");
            assert!(detail.contains("could not be resolved"), "the detail says why: {detail:?}");
        }
        other => panic!("expected a block by `{RULE_TMUX_INPUT}`, got {other:?}"),
    }
    // Nothing remote on the server: nothing to protect, so it is allowed.
    assert_allowed(evaluate(&bash(command), &local_world()), "unresolvable target, no remote pane");
    assert_allowed(evaluate(&bash(command), &all_local_world()), "unresolvable target, all panes local");
}

// ── the exemption must not open a hole: these stay blocked in every world ────────────────

#[test]
fn bypass_inert_a_marker_piped_into_a_shell_or_interpreter_is_blocked() {
    assert_in_every_world(
        &[
            "echo ecs_connect | sh",
            "echo 'ecs_connect' | bash",
            "echo ecs_connect | env sh",
            "echo ecs_connect | eval",
            "echo ecs_connect | /bin/sh",
            "echo ecs_connect | zsh",
            "echo ecs_connect | sh -s",
            r#"echo "ecs_connect" | tee /dev/stderr | sh"#,
            "printf 'ecs_connect\\n' | xargs",
            "printf 'ecs_connect\\n' | xargs sh -c",
            "git log --grep=x | echo ecs_connect | sh",
            "cat <<EOF | sh\necs_connect ap\nEOF",
            "cat <<'EOF' | bash\necs_connect ap\nEOF",
            "git show HEAD | grep ecs_connect | sh",
        ],
        "a marker that reaches a shell",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_a_marker_in_command_position_anywhere_in_the_command_is_blocked() {
    assert_in_every_world(
        &[
            "git commit -m x; ecs_connect",
            "echo x | grep y; ecs_connect ap",
            "echo hi && ecs_connect ap",
            "echo hi || ecs_connect ap",
            "git commit -m x && aws ecs execute-command --cluster c",
            "echo hi; aws ssm start-session --target i-1",
            "echo hi; session-manager-plugin x",
            "echo hi; ecs_shell ap",
            "git log | head; ecs_run_task ap production portal migrate",
            "ecs_connect ap",
            "(ecs_connect ap)",
            "{ ecs_connect ap; }",
            "if true; then ecs_connect ap; fi",
            "echo hi &\necs_connect ap",
        ],
        "a marker in command position",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_a_marker_run_through_a_wrapper_command_is_blocked() {
    assert_in_every_world(
        &["sudo ecs_connect", "env ecs_connect", "command ecs_connect", "exec ecs_connect", "nohup ecs_connect ap", "time ecs_connect ap", "xargs ecs_connect"],
        "a wrapper in front of a marker",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_a_marker_inside_a_command_substitution_in_command_position_is_blocked() {
    assert_in_every_world(
        &[
            "$(echo ecs_connect)",
            "`echo ecs_connect`",
            "echo $(ecs_connect ap)",
            "echo `ecs_connect ap`",
            "echo \"$(ecs_connect ap)\"",
            "echo hi; source <(echo ecs_connect)",
            "echo hi; . <(echo ecs_connect)",
            "cat > notes.md <<EOF\nrun $(ecs_connect ap)\nEOF",
            "cat > notes.md <<EOF\nrun `ecs_connect ap`\nEOF",
        ],
        "a marker that a substitution runs",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_a_shell_is_not_an_inert_program_and_nor_is_its_input() {
    assert_in_every_world(
        &[
            "bash -c 'echo ecs_connect'",
            "sh -c \"echo ecs_connect\"",
            "eval 'echo ecs_connect'",
            "bash <<EOF\necs_connect ap\nEOF",
            "bash <<'EOF'\necs_connect ap\nEOF",
            "sh <<EOF\necho hi\necs_connect ap\nEOF",
            "cat <<EOF > x.sh\nthe text\nEOF\nbash x.sh && ecs_connect",
            "echo ecs_connect > /dev/tcp/h/1",
            "echo ecs_connect > /dev/tcp/h/1 && echo done",
        ],
        "a shell, or a command that reaches one",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_a_command_that_cannot_be_parsed_is_not_exempt() {
    assert_in_every_world(
        &[
            "echo ecs_connect \"unterminated",
            "git commit -m \"ecs_connect",
            "git commit -m x; echo 'ecs_connect",
            "echo ecs_connect $(unterminated",
            "echo ecs_connect (",
            "git log --grep=ecs_connect | (",
            "echo hi; ecs_connect ap \"",
        ],
        "an inert command beside something the parser cannot read",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_inert_programs_that_can_run_a_program_are_not_inert_when_they_do() {
    // Each of these is "inert" by name and runs its argument by option or by program text.
    assert_in_every_world(
        &[
            "awk 'BEGIN { system(\"ecs_connect ap\") }'",
            "awk 'BEGIN { \"ecs_connect ap\" | getline x }'",
            "sed -n '1e ecs_connect ap' notes.md",
            "rg --pre ecs_connect x docs",
            "git -c core.pager=ecs_connect log",
            "git -c alias.x='!ecs_connect ap' x",
            "git -c core.sshCommand=ecs_connect fetch",
        ],
        "an inert program told to run a marker",
        Some(RULE_COMMAND),
    );
}

#[test]
fn bypass_expansion_only_command_word_is_blocked() {
    // The guard does not track assignments, but a command word made of nothing except two or
    // more expansions can be anything, including a marker built in the line before.
    assert_in_every_world(
        &[
            "$a$b ap",
            "${a}${b} ap",
            "$a$b",
            "a=ecs_; b=connect; $a$b",
            "a=ecs_; b=connect; ${a}${b} ap production portal",
            "a=x; $a$b",
            "echo hi && $a$b ap",
            "git commit -m x; $a$b",
            "echo hi | $a$b",
        ],
        "a command word made only of expansions",
        Some(RULE_COMMAND),
    );
}

#[test]
fn benign_command_words_with_literal_parts_and_expansions_in_argument_position_are_allowed() {
    // (A lone `$CC` or `$EDITOR` as the command word is deliberately not decided here.)
    assert_in_every_world(
        &[
            "$HOME/bin/tool run",
            "${DIR}/${NAME} --flag",
            "echo $a$b",
            "ls $a$b",
            "cp $a$b dest",
            "out=$a$b",
            "for x in $a$b; do echo $x; done",
            "echo ${a}${b} > notes.txt",
        ],
        "expansions that are not the whole command word",
        None,
    );
}

// ── the benign corpus ────────────────────────────────────────────────────────────────────

#[test]
fn benign_corpus_has_no_false_positives() {
    const CORPUS: &[&str] = &[
        // git
        "git status",
        "git diff --stat",
        "git log --oneline -20",
        "git checkout -b feature/x",
        "git add -A",
        r#"git commit -m "fix: handle empty input""#,
        "git push -u origin HEAD",
        "git pull --rebase",
        "git stash list",
        "git rebase origin/main",
        "git branch -a",
        "git remote -v",
        "git fetch --all --prune",
        "git show HEAD~1 --stat",
        "git blame src/main.rs",
        r#"git commit -m "fix: guard blocks ecs_connect in the shell""#,
        "git commit -m 'docs: explain aws ecs execute-command is blocked'",
        r#"git commit -m "tmux send-keys guard""#,
        r#"git commit -m "chore: mention session-manager-plugin in docs""#,
        "git grep -n ecs_connect",
        "git log --grep=ecs_connect",
        "git show HEAD | grep ecs_connect",
        "git diff | grep -n execute-command | head",
        // cargo and make
        "cargo build --release",
        "cargo test --lib",
        "cargo clippy --all-targets -- -D warnings",
        "cargo fmt --check",
        "cargo run -- --help",
        "cargo check",
        "cargo doc --no-deps",
        "make",
        "make test",
        "make install-daemon",
        "make -j8 build",
        // files and the shell
        "ls -la",
        "ls ~/Code/ecs-tools",
        "cat README.md",
        "head -n 20 Cargo.toml",
        "tail -f /tmp/log.txt",
        "wc -l src/*.rs",
        "find . -name '*.rs' -not -path './target/*'",
        "mkdir -p build/{debug,release}",
        "rm -rf target/debug/incremental",
        "cp file.{js,ts} dir/",
        "mv old.txt new.txt",
        "pwd",
        "which cargo",
        "du -sh target",
        "sort -u names.txt",
        "diff a.txt b.txt",
        "chmod +x scripts/run.sh",
        "touch notes.md",
        "echo $PATH",
        r#"echo ${HOME}/bin $PATH "$@""#,
        "echo ${X:-default}",
        // searching
        "grep -rn TODO src",
        "grep -rn ecs_connect docs src",
        r#"rg "ecs_connect|execute-command""#,
        r#"rg -n "fn main" src"#,
        "rg --files -g '*.rs' | head",
        "egrep -c 'ecs_shell' notes.md",
        // echo, printf, here-documents
        r#"echo "ecs_connect is blocked""#,
        r#"echo "tmux send-keys is how the guard works""#,
        r#"printf 'ecs_connect\n' > notes.txt"#,
        "echo ecs_connect >> notes.txt",
        "cat <<'EOF' > notes.md\n# Guard\nThe guard blocks ecs_connect.\nEOF",
        "cat >> notes.md <<EOF\nThe guard blocks aws ecs execute-command.\nEOF",
        // aws (read-only)
        "aws s3 ls",
        "aws s3 cp build.zip s3://bucket/build.zip",
        "aws ecs list-clusters",
        "aws ecs describe-services --cluster c --services s",
        "aws ecs list-tasks --cluster c",
        "aws ecs describe-task-definition --task-definition td",
        "aws sts get-caller-identity",
        "aws logs tail /ecs/portal --since 10m",
        "aws ssm get-parameter --name /x/y",
        "aws ecr get-login-password --region us-east-1",
        // node
        "npm install",
        "npm run build",
        "npm test -- --watch=false",
        "npx prettier --check .",
        "node script.js",
        // docker
        "docker ps",
        "docker build -t app:latest .",
        "docker compose up -d",
        "docker logs -f app",
        "docker exec -it app sh",
        // ssh
        "ssh devbox",
        "ssh -L 8080:localhost:80 devbox",
        "ssh-add -l",
        "ssh-keygen -t ed25519",
        "scp file devbox:/tmp/",
        // gh
        "gh pr list",
        "gh pr view 123 --json title",
        r#"gh pr create --title t --body "mentions ecs_connect""#,
        "gh pr checks 12",
        r#"gh pr comment 5 --body "mentions ecs_connect""#,
        // terraform and friends
        "terraform plan -out=tfplan",
        "terraform fmt -check",
        "terraform validate",
        "terraform apply tfplan",
        "kubectl get pods",
        r#"python3 -c "print('hello')""#,
        "curl -s localhost:8080/health",
        // tmux
        "tmux ls",
        "tmux new -d -s x",
        "tmux send-keys -t %0 'cargo test' Enter",
        "tmux capture-pane -p -t %0",
        "tmux list-panes -a",
        "tmux display-message -p '#{pane_title}'",
        "tmux source-file ~/.tmux.conf",
    ];
    assert!(CORPUS.len() >= 105, "the corpus is {} commands", CORPUS.len());

    let mut failures = Vec::new();
    for (world_name, world) in three_worlds() {
        for command in CORPUS {
            let verdict = evaluate(&bash(command), &world());
            if verdict != Ok(GuardVerdict::Allow) {
                failures.push(format!("  [{world_name}] {command:?} -> {verdict:?}"));
            }
        }
    }
    assert!(failures.is_empty(), "ordinary commands must not be blocked:\n{}", failures.join("\n"));
}

// ── round 2, Cody's extras: what the inert exemption must not let through ────────────────

#[test]
fn bypass_inert_a_command_substitution_the_tokenizer_skips_still_runs() {
    // `${x:-$(…)}`, `$(( a[$(…)] ))` and `$[ ]` run commands the tokenizer does not parse.
    assert_all_blocked(
        &[
            "echo ${x:-$(ecs_connect ap)}",
            "echo $((a[$(ecs_connect ap)]))",
            "echo $[a[$(ecs_connect ap)]]",
            "echo hi > /dev/tcp/localhost/1; ecs_connect ap",
            "echo ecs_connect > /dev/tcp/localhost/1",
        ],
        RULE_COMMAND,
        "inert program, hidden command",
        FakeProbe::default,
    );
}

#[test]
fn bypass_a_source_file_before_a_send_to_a_session_target_is_checked_against_the_server() {
    // `source-file` is allowed alone, but it may change what `prod` names.
    let world = || {
        FakeProbe::default()
            .pane_on(DEFAULT, "prod", "zsh", LOCAL_SHELL)
            .other_pane_on(DEFAULT, REMOTE_TITLE, REMOTE_SHELL)
    };
    assert_all_blocked(
        &["tmux source-file ~/.tmux.conf; tmux send-keys -t prod x Enter"],
        RULE_TMUX_INPUT,
        "source-file may select another pane",
        world,
    );
    assert_all_allowed(&["tmux source-file ~/.tmux.conf"], "source-file alone", world);
}
