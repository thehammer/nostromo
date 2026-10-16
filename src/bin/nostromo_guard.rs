//! `nostromo-guard pre-tool-use`: Nostromo's production-shell guard as a
//! Claude Code PreToolUse hook (design contract §5).
//!
//! Every daemon-hosted session runs it through the inline `--settings` hook
//! that `nostromo::approvals::guard::hook_settings_json` builds.
//!
//! 1. Reads the hook payload from stdin (at most [`MAX_STDIN`]).
//! 2. Runs `guard::evaluate` with the system tmux/ps probe.
//! 3. On a block: appends one `guard_blocked` audit entry, prints the deny
//!    JSON on stdout, exits 0. On an allow: prints nothing, exits 0.
//!
//! **Fails closed.** Any error (unreadable or oversized stdin, bad JSON, a
//! probe failure the decision depends on, an audit write failure), a panic,
//! or an unknown subcommand exits 2 with `FAIL_CLOSED_MESSAGE` on stderr,
//! which the CLI treats as a block. The session's hook wrapper turns a
//! missing binary into the same exit 2. A guard still running after
//! [`WATCHDOG`] exits 2 too: the session kills a hook at 30 s and lets the
//! call through, so the guard must never get that far.

use std::io::Read;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use nostromo::approvals::audit::{AuditLog, Entry, Event};
use nostromo::approvals::guard::{self, GuardVerdict, HookPayload, SystemPaneProbe, FAIL_CLOSED_MESSAGE};
use nostromo::approvals::ApprovalsPaths;

/// The largest hook payload accepted. Anything bigger is refused (blocked).
const MAX_STDIN: u64 = 4 * 1024 * 1024;

/// Exit status that makes the CLI block the call and show stderr.
const BLOCKING_ERROR: u8 = 2;

/// The guard's own deadline, well under the session's 30 s hook timeout.
const WATCHDOG: Duration = Duration::from_secs(20);

fn main() -> ExitCode {
    std::panic::set_hook(Box::new(|info| {
        eprintln!("{FAIL_CLOSED_MESSAGE} (guard panicked: {info})");
        std::process::exit(i32::from(BLOCKING_ERROR));
    }));
    start_watchdog();
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{FAIL_CLOSED_MESSAGE} ({e:#})");
            ExitCode::from(BLOCKING_ERROR)
        }
    }
}

/// Block (exit 2) if the guard hasn't finished within [`WATCHDOG`].
fn start_watchdog() {
    let after = watchdog_delay();
    std::thread::spawn(move || {
        std::thread::sleep(after);
        eprintln!("{FAIL_CLOSED_MESSAGE} (guard timed out after {after:?})");
        std::process::exit(i32::from(BLOCKING_ERROR));
    });
}

/// [`WATCHDOG`]; debug builds let a test shorten it.
fn watchdog_delay() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("NOSTROMO_GUARD_TEST_WATCHDOG_MS").ok().and_then(|v| v.parse().ok()) {
        return Duration::from_millis(ms);
    }
    WATCHDOG
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args != ["pre-tool-use"] {
        bail!("usage: nostromo-guard pre-tool-use (got {args:?})");
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("NOSTROMO_GUARD_TEST_PANIC").is_some_and(|v| v == "1") {
        panic!("NOSTROMO_GUARD_TEST_PANIC");
    }

    let mut input = Vec::new();
    std::io::stdin().take(MAX_STDIN + 1).read_to_end(&mut input).context("reading stdin")?;
    if input.len() as u64 > MAX_STDIN {
        bail!("hook payload larger than {MAX_STDIN} bytes");
    }
    let payload: HookPayload = serde_json::from_slice(&input).context("parsing the hook payload")?;

    let GuardVerdict::Block { rule_id, detail } = guard::evaluate(&payload, &SystemPaneProbe::new())? else {
        return Ok(());
    };
    // Log first: a block nobody can find later is a failure, and an exit 2
    // still blocks.
    let mut entry = Entry::new(
        Event::GuardBlocked {
            tool_name: payload.tool_name,
            input: payload.tool_input,
            rule: rule_id.to_owned(),
            detail: Some(detail),
        },
        chrono::Utc::now(),
    );
    entry.tag = std::env::var("NOSTROMO_FOCUS_TAG").ok().filter(|t| !t.is_empty());
    entry.session_id = payload.session_id;
    entry.tool_use_id = payload.tool_use_id;
    let paths = ApprovalsPaths::resolve();
    AuditLog::open(paths.dir())
        .and_then(|log| log.append(&entry))
        .with_context(|| format!("writing the audit log in {}", paths.dir().display()))?;
    println!("{}", guard::deny_output_json());
    Ok(())
}
