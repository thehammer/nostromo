//! The AWS CLI as the daemon runs it: found by absolute path, started without
//! a shell, bounded by a timeout.
//!
//! Three read-only helpers (`sts get-caller-identity`, `ecs list-tasks`,
//! `ecs describe-tasks`) run here; the interactive `execute-command` is started
//! by [`super::connect`] as a terminal's process. Every call is an argv array
//! (`tokio::process::Command`, never `sh -c`, T-2b-1), with `--output json`,
//! `AWS_PAGER=""` and a `PATH` the daemon sets, because launchd gives
//! `nostromd` almost none.
//!
//! Nothing here ever runs `aws sso login`: an expired session is reported, and
//! the user logs in themselves.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::Deserialize;
use tokio::process::Command;

use crate::config::TerminalConfig;
use crate::terminal::launcher::ConnectFailure;
use crate::terminal::session::SCRUBBED_ENV;

/// How long one helper call may take.
pub const HELPER_TIMEOUT: Duration = Duration::from_secs(10);
/// The environment variable that names the AWS CLI (after `[terminal] aws_cli`).
pub const AWS_CLI_ENV: &str = "NOSTROMO_AWS_CLI";
/// Where the CLI is looked for when nothing names it.
const DEFAULT_CLIS: [&str; 3] = [
    "/opt/homebrew/bin/aws",
    "/usr/local/bin/aws",
    "/usr/bin/aws",
];
/// What follows the CLI's own directory on the child's `PATH` (so
/// `session-manager-plugin` is found).
const FIXED_PATH: &str = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
/// `describe-tasks` takes at most this many tasks.
const DESCRIBE_BATCH: usize = 100;
/// The most of a helper's stderr that is kept.
const MAX_STDERR_BYTES: usize = 4096;

/// A resolved AWS CLI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AwsCli {
    pub exe: PathBuf,
    /// The `PATH` the CLI (and the plugin it starts) runs with.
    pub child_path: String,
}

impl AwsCli {
    /// The CLI at `exe`, with `PATH` = its directory, then the usual bins.
    pub fn at(exe: PathBuf) -> Self {
        let dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();
        Self {
            child_path: format!("{}:{FIXED_PATH}", dir.display()),
            exe,
        }
    }
}

/// Where the CLI may be: tried in order, the first executable file wins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AwsCliSource {
    candidates: Vec<PathBuf>,
}

impl AwsCliSource {
    /// `[terminal] aws_cli`, then `$NOSTROMO_AWS_CLI`, then the usual places.
    pub fn from_config(cfg: &TerminalConfig) -> Self {
        Self::from_config_and_env(cfg, std::env::var_os(AWS_CLI_ENV))
    }

    /// [`Self::from_config`] with the value of `$NOSTROMO_AWS_CLI` given.
    pub fn from_config_and_env(cfg: &TerminalConfig, env: Option<std::ffi::OsString>) -> Self {
        let env = env.map(PathBuf::from);
        let home = dirs_next::home_dir();
        let expand = |p: PathBuf| match (p.strip_prefix("~"), &home) {
            (Ok(rest), Some(home)) => home.join(rest),
            _ => p,
        };
        let candidates = cfg
            .aws_cli
            .iter()
            .cloned()
            .chain(env)
            .filter(|p| !p.as_os_str().is_empty())
            .map(expand)
            .chain(DEFAULT_CLIS.iter().map(PathBuf::from))
            .collect();
        Self { candidates }
    }

    /// Exactly `exe`, no fallbacks (tests, and anywhere the CLI is known).
    pub fn only(exe: impl Into<PathBuf>) -> Self {
        Self {
            candidates: vec![exe.into()],
        }
    }

    /// The first candidate that is an absolute path to an executable file.
    pub fn resolve(&self) -> Result<AwsCli, ConnectFailure> {
        self.candidates
            .iter()
            .find(|p| p.is_absolute() && is_executable(p))
            .map(|p| AwsCli::at(p.clone()))
            .ok_or_else(|| ConnectFailure {
                reason_code: "aws_cli_missing".into(),
                message: "The AWS CLI was not found.".into(),
                remedy: Some("Install the AWS CLI: brew install awscli".into()),
            })
    }
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Why a helper call did not give an answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AwsRunError {
    /// The CLI could not be started.
    Spawn(String),
    /// It did not finish within [`HELPER_TIMEOUT`] (and was killed).
    Timeout,
    /// It exited non-zero; `stderr` is the first [`MAX_STDERR_BYTES`] of it.
    Failed { stderr: String },
    /// It exited zero with output that is not what the call returns.
    BadOutput(String),
}

/// A task as `describe-tasks` reports it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TaskInfo {
    #[serde(rename = "taskArn")]
    pub arn: String,
    #[serde(rename = "lastStatus", default)]
    pub last_status: String,
    #[serde(rename = "enableExecuteCommand", default)]
    pub exec_enabled: bool,
}

/// `aws sts get-caller-identity`: is the profile's session valid?
pub async fn sts_get_caller_identity(cli: &AwsCli, profile: &str) -> Result<(), AwsRunError> {
    run_json(cli, &["sts", "get-caller-identity", "--profile", profile])
        .await
        .map(drop)
}

/// The ARNs of the service's RUNNING tasks.
pub async fn list_running_tasks(
    cli: &AwsCli,
    profile: &str,
    region: &str,
    cluster: &str,
    service_name: &str,
) -> Result<Vec<String>, AwsRunError> {
    #[derive(Deserialize)]
    struct Listed {
        #[serde(rename = "taskArns", default)]
        task_arns: Vec<String>,
    }
    let out = run_json(
        cli,
        &[
            "ecs",
            "list-tasks",
            "--profile",
            profile,
            "--region",
            region,
            "--cluster",
            cluster,
            "--service-name",
            service_name,
            "--desired-status",
            "RUNNING",
        ],
    )
    .await?;
    serde_json::from_value::<Listed>(out)
        .map(|l| l.task_arns)
        .map_err(|e| AwsRunError::BadOutput(format!("list-tasks: {e}")))
}

/// What `describe-tasks` says about `arns` (in batches of 100), in the order
/// of `arns`.
pub async fn describe_tasks(
    cli: &AwsCli,
    profile: &str,
    region: &str,
    cluster: &str,
    arns: &[String],
) -> Result<Vec<TaskInfo>, AwsRunError> {
    #[derive(Deserialize)]
    struct Described {
        #[serde(default)]
        tasks: Vec<TaskInfo>,
    }
    let mut found: Vec<TaskInfo> = Vec::new();
    for batch in arns.chunks(DESCRIBE_BATCH) {
        let mut args = vec![
            "ecs",
            "describe-tasks",
            "--profile",
            profile,
            "--region",
            region,
            "--cluster",
            cluster,
            "--tasks",
        ];
        args.extend(batch.iter().map(String::as_str));
        let out = run_json(cli, &args).await?;
        let described = serde_json::from_value::<Described>(out)
            .map_err(|e| AwsRunError::BadOutput(format!("describe-tasks: {e}")))?;
        found.extend(described.tasks);
    }
    found.sort_by_key(|t| arns.iter().position(|a| *a == t.arn).unwrap_or(usize::MAX));
    Ok(found)
}

/// Run `aws <args> --output json` and parse its stdout.
async fn run_json(cli: &AwsCli, args: &[&str]) -> Result<serde_json::Value, AwsRunError> {
    let mut command = Command::new(&cli.exe);
    command
        .args(args)
        .args(["--output", "json"])
        .env("PATH", &cli.child_path)
        .env("AWS_PAGER", "")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // The same variables the terminal's own child never inherits.
    for key in SCRUBBED_ENV {
        command.env_remove(key);
    }
    let child = command
        .spawn()
        .map_err(|e| AwsRunError::Spawn(e.to_string()))?;
    // On timeout the future (and with it the child) is dropped: it is killed.
    let output = tokio::time::timeout(HELPER_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| AwsRunError::Timeout)?
        .map_err(|e| AwsRunError::Spawn(e.to_string()))?;
    if !output.status.success() {
        let stderr = &output.stderr[..output.stderr.len().min(MAX_STDERR_BYTES)];
        return Err(AwsRunError::Failed {
            stderr: String::from_utf8_lossy(stderr).into_owned(),
        });
    }
    serde_json::from_slice(&output.stdout).map_err(|e| AwsRunError::BadOutput(e.to_string()))
}
