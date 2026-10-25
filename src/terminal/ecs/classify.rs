//! The pure parts of connecting an ECS shell: the argv that is run, and what
//! the AWS CLI's failures and endings mean.
//!
//! No I/O and no state here. The reason codes are a closed set: they go to the
//! audit trail, the app and the agent, each with fixed message and remedy text.
//! What the CLI printed never does (T-2b-2); at most a failure's `detail`
//! quotes one sanitised line of it, and that goes to the operator's app alone.
//! The daemon drops the captured text once it is classified.

use super::aws::{child_env, AwsCli, AwsRunError};
use super::vocab::EcsTarget;
use crate::terminal::launcher::ConnectFailure;

/// What the session-manager plugin prints once the session is up.
pub const CONNECTED_MARKER: &str = "Starting session with SessionId";
/// What it prints when the remote side ends the session.
pub const REMOTE_EXIT_MARKER: &str = "Exiting session with sessionId";
/// The most output the daemon holds to classify a connect or an ending.
pub const MAX_TAIL_BYTES: usize = 4 * 1024;
/// How much output is held once the session has begun: the last few lines,
/// enough to tell how it ended. (It is the remote shell's output by then.)
pub const CLOSE_TAIL_BYTES: usize = 512;

/// How much of a quoted stderr/output line a detail keeps.
const MAX_LINE_CHARS: usize = 200;
/// How many lines of unrecognised output an `unknown` failure's detail quotes.
const UNKNOWN_LINES: usize = 3;

/// The argv of the interactive session. Element 0 is the resolved `aws`; there
/// is no shell, and the shell command the user will get remotely is **one**
/// element, the value of `--command` (T6). Built by
/// [`EcsTarget::execute_command_args`], the same words the request pinned.
pub fn execute_command_argv(
    cli: &AwsCli,
    target: &EcsTarget,
    profile: &str,
    task_arn: &str,
) -> Vec<String> {
    let mut argv = vec![cli.exe.display().to_string()];
    argv.extend(target.execute_command_args(profile, task_arn));
    argv
}

/// The complete environment the session runs with: [`child_env`], and
/// nothing else of the daemon's.
pub fn execute_command_env(cli: &AwsCli) -> Vec<(String, String)> {
    child_env(cli)
}

/// A helper call (sts, list-tasks, describe-tasks) that failed.
pub fn classify_helper_failure(error: &AwsRunError, sso_session: &str) -> ConnectFailure {
    match error {
        AwsRunError::Failed { stderr } => classify_stderr(stderr, sso_session),
        AwsRunError::Timeout => aws_error("The AWS CLI did not answer in time.", None),
        AwsRunError::Spawn(_) => aws_error("The AWS CLI could not be started.", None),
        AwsRunError::BadOutput(_) => unexpected_answer(),
    }
}

/// The CLI answered with something that is not what the call returns (a task
/// ARN that is not one, say). Nothing of it is quoted.
pub fn unexpected_answer() -> ConnectFailure {
    aws_error("The AWS CLI gave an unexpected answer.", None)
}

fn classify_stderr(stderr: &str, sso_session: &str) -> ConnectFailure {
    if is_expired(stderr) {
        return sso_expired(sso_session);
    }
    // The CLI's own wording for a profile that is not in its config. A bare
    // mention of "profile" is not enough: an AccessDenied can name one.
    if stderr.contains("ProfileNotFound")
        || stderr.contains("Missing profile ")
        || (stderr.contains("The config profile (") && stderr.contains("could not be found"))
    {
        return profile_not_configured_failure();
    }
    aws_error("The AWS CLI reported an error.", first_line(stderr))
}

/// The CLI's output while connecting, once it exited before the session began.
pub fn classify_connect_failure(tail: &str, sso_session: &str) -> ConnectFailure {
    if tail.contains("SessionManagerPlugin is not found") {
        return failure(
            "session_manager_plugin_missing",
            "The Session Manager plugin is not installed.",
            Some("brew install --cask session-manager-plugin"),
        );
    }
    if is_expired(tail) {
        return sso_expired(sso_session);
    }
    if tail.contains("TargetNotConnectedException") {
        return failure(
            "target_not_connected",
            "The task is not ready for exec; try again in a minute or pick another service",
            None,
        );
    }
    if tail.contains("AccessDenied") {
        return failure(
            "access_denied",
            "AWS denied access to this task.",
            Some(
                "Your AWS role is not allowed to exec into this service; ask an admin for access.",
            ),
        );
    }
    let mut unknown = failure(
        "unknown",
        "The connection ended before the session began.",
        None,
    );
    let lines = last_lines(tail, UNKNOWN_LINES);
    unknown.detail = (!lines.is_empty()).then(|| lines.join(" / "));
    unknown
}

/// Why a session that was running ended: `remote_exit` (the remote side said
/// so), `sso_expired`, `network`, else `unknown`.
pub fn classify_close(tail: &str, remote_exit_seen: bool) -> &'static str {
    if remote_exit_seen || tail.contains(REMOTE_EXIT_MARKER) {
        return "remote_exit";
    }
    if is_expired(tail) {
        return "sso_expired";
    }
    let lower = tail.to_ascii_lowercase();
    if lower.contains("cannot perform start session")
        || lower.contains("connection reset")
        || lower.contains("websocket")
    {
        return "network";
    }
    "unknown"
}

pub fn profile_not_configured_failure() -> ConnectFailure {
    failure(
        "profile_not_configured",
        "No AWS profile is set up for this environment.",
        Some("Create ~/.claude/ecs-local.json with your AWS profiles (run ecs_setup in a shell)"),
    )
}

pub fn no_running_task() -> ConnectFailure {
    failure(
        "no_running_task",
        "No task is running for this service.",
        Some("Check that the service is up, or pick another service."),
    )
}

pub fn exec_not_enabled() -> ConnectFailure {
    failure(
        "exec_not_enabled",
        "ECS Exec is not enabled on this service's running tasks.",
        Some("Enable ECS Exec on the service and redeploy it, or pick another service."),
    )
}

pub fn connect_timeout() -> ConnectFailure {
    failure(
        "connect_timeout",
        "The session did not start in time.",
        Some("Check your network and your AWS session, then try again."),
    )
}

fn sso_expired(sso_session: &str) -> ConnectFailure {
    failure(
        "sso_expired",
        "Your AWS session has expired.",
        Some(&format!("Run `aws sso login --sso-session {sso_session}`")),
    )
}

/// `aws_error`: fixed `message`; `detail` is the CLI's own first line, for the
/// operator's app.
fn aws_error(message: &str, detail: Option<String>) -> ConnectFailure {
    let mut failure = failure("aws_error", message, None);
    failure.detail = detail;
    failure
}

fn failure(code: &str, message: &str, remedy: Option<&str>) -> ConnectFailure {
    ConnectFailure::new(code, message, remedy)
}

fn is_expired(text: &str) -> bool {
    [
        "ExpiredToken",
        "Token has expired",
        "UnauthorizedSSOToken",
        "The SSO session",
        "Error loading SSO Token",
        "InvalidGrantException",
    ]
    .iter()
    .any(|p| text.contains(p))
}

/// The first non-empty line, sanitised.
fn first_line(text: &str) -> Option<String> {
    text.lines().find_map(clean_line)
}

/// The last `n` non-empty lines, sanitised, in order.
fn last_lines(text: &str, n: usize) -> Vec<String> {
    let mut lines: Vec<String> = text.lines().rev().filter_map(clean_line).take(n).collect();
    lines.reverse();
    lines
}

/// A line without escape sequences or control characters, and without the
/// characters that hide or reorder text (bidi overrides and isolates,
/// zero-width characters, the byte-order mark); trimmed and cut to
/// [`MAX_LINE_CHARS`]; `None` when nothing is left.
fn clean_line(line: &str) -> Option<String> {
    let cleaned: String = strip_escapes(line)
        .chars()
        .filter(|c| !c.is_control() && !is_invisible(*c))
        .take(MAX_LINE_CHARS)
        .collect();
    let cleaned = cleaned.trim();
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

fn is_invisible(c: char) -> bool {
    matches!(
        c,
        '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2028}'..='\u{2029}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}'
    )
}

/// `text` without terminal escape sequences: CSI (`ESC [ … final-byte`), OSC
/// (`ESC ] … BEL` or `… ESC \`, a window title, say) and any other
/// two-character escape.
fn strip_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('[') => {
                for next in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&next) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(next) = chars.next() {
                    if next == '\u{7}' {
                        break;
                    }
                    if next == '\u{1b}' {
                        chars.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}
