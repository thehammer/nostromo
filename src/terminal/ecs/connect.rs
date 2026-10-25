//! Opening a remote ECS shell for real, after the user has said Connect.
//!
//! [`AwsEcsLauncher`] checks the AWS session, finds a task that can be exec'd
//! into, and starts `aws ecs execute-command` **as the terminal's process**:
//! an argv array, no shell anywhere (T6). The pane exists from the moment the
//! process starts, `connecting`; it becomes `running` when the session-manager
//! plugin says the session began, and is gone, with no pane left behind, when
//! it never does.
//!
//! The connection is the pane: when it ends the pane closes with a reason and
//! nothing reconnects (that lifecycle is in [`crate::terminal::TerminalManager`]).
//! `aws sso login` is never run here; an expired session is reported with the
//! command for the user to run.

use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use async_trait::async_trait;

use super::aws::{self, AwsCli, AwsCliSource, TaskInfo};
use super::classify::{
    classify_helper_failure, connect_timeout, exec_not_enabled, execute_command_argv,
    execute_command_env, no_running_task, profile_not_configured_failure,
};
use super::vocab::EcsTarget;
use super::watch::{ConnectEvent, RemoteWatch};
use crate::ipc::protocol::{TerminalInfo, TerminalRequester, TerminalStatus};
use crate::terminal::launcher::{ConnectFailure, Placement, RemoteLauncher};
use crate::terminal::session::TerminalSession;
use crate::terminal::{store, OpenRemote, TerminalManager};

/// How long a session may take to begin before the connect is given up.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(60);

/// Opens `ecs` terminals in the manager it was built for (held weakly: the
/// manager owns its launcher).
pub struct AwsEcsLauncher {
    manager: Weak<Mutex<TerminalManager>>,
    cli: AwsCliSource,
    connect_timeout: Duration,
}

impl AwsEcsLauncher {
    pub fn new(manager: &Arc<Mutex<TerminalManager>>, cli: AwsCliSource) -> Arc<Self> {
        Self::with_connect_timeout(manager, cli, CONNECT_TIMEOUT)
    }

    /// [`Self::new`] with a different [`CONNECT_TIMEOUT`] (tests).
    pub fn with_connect_timeout(
        manager: &Arc<Mutex<TerminalManager>>,
        cli: AwsCliSource,
        connect_timeout: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            manager: Arc::downgrade(manager),
            cli,
            connect_timeout,
        })
    }

    fn manager(&self) -> Result<Arc<Mutex<TerminalManager>>, ConnectFailure> {
        self.manager.upgrade().ok_or_else(|| ConnectFailure {
            reason_code: "daemon_stopping".into(),
            message: "The terminal manager is gone.".into(),
            remedy: None,
        })
    }
}

#[async_trait]
impl RemoteLauncher for AwsEcsLauncher {
    async fn connect(
        &self,
        target: &EcsTarget,
        tag: &str,
        placement: &Placement,
        requested_by: &TerminalRequester,
    ) -> Result<TerminalInfo, ConnectFailure> {
        let manager = self.manager()?;
        let profile = target
            .profile
            .as_deref()
            .ok_or_else(profile_not_configured_failure)?;
        let cli = self.cli.resolve()?;
        // Before anything is started: a focus that is full, an unwritable
        // audit trail or a bad placement must not cost a production session.
        lock(&manager)
            .check_can_open_remote(tag, placement)
            .map_err(|e| ConnectFailure {
                reason_code: e.code().into(),
                message: "The pane could not be opened.".into(),
                remedy: None,
            })?;
        let task_arn = find_task(&cli, target, profile).await?;

        // From here a process and a pane exist until this returns.
        let (watch, mut events) = RemoteWatch::new(&target.sso_session);
        let observer = Arc::clone(&watch);
        let session = TerminalSession::spawn_argv_observed(
            &execute_command_argv(&cli, target, profile, &task_arn),
            Path::new("/"),
            &execute_command_env(&cli),
            store::DEFAULT_COLS,
            store::DEFAULT_ROWS,
            Box::new(move |chunk| observer.observe(chunk)),
        )
        .map_err(|e| ConnectFailure {
            reason_code: "spawn_failed".into(),
            message: format!("The AWS CLI could not be started: {e:#}"),
            remedy: None,
        })?;
        let opened = lock(&manager).open_remote(
            OpenRemote {
                tag: tag.to_string(),
                placement: placement.clone(),
                requested_by: requested_by.clone(),
                target: target.terminal_target(),
                label: format!(
                    "{} · {} · {} · {}",
                    target.environment, target.project, target.service, target.shell_type
                ),
                status: TerminalStatus::Connecting,
                watch: Some(watch),
            },
            session,
        );
        let info = opened.map_err(|e| ConnectFailure {
            reason_code: e.code().into(),
            message: "The pane could not be opened.".into(),
            remedy: None,
        })?;

        // If the requester goes away while the session is starting, the pane
        // does not stay behind.
        let mut guard = Abandon {
            manager: &manager,
            terminal_id: &info.terminal_id,
            armed: true,
        };
        let result = self
            .wait_for_session(&manager, &info.terminal_id, &mut events)
            .await;
        guard.armed = false;
        result
    }
}

impl AwsEcsLauncher {
    /// Wait for the session to begin (`running`), for the terminal to be gone
    /// (its reason is the failure) or for the timeout (killed, removed).
    async fn wait_for_session(
        &self,
        manager: &Arc<Mutex<TerminalManager>>,
        terminal_id: &str,
        events: &mut tokio::sync::mpsc::UnboundedReceiver<ConnectEvent>,
    ) -> Result<TerminalInfo, ConnectFailure> {
        let deadline = tokio::time::sleep(self.connect_timeout);
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                event = events.recv() => match event {
                    Some(ConnectEvent::Connected) => {
                        // `None`: it ended first; its failure is already queued.
                        let promoted = lock(manager).promote_remote(terminal_id);
                        if let Some(info) = promoted {
                            return Ok(info);
                        }
                    }
                    Some(ConnectEvent::Failed(failure)) => return Err(failure),
                    None => return Err(ConnectFailure {
                        reason_code: "unknown".into(),
                        message: "The connection ended unexpectedly.".into(),
                        remedy: None,
                    }),
                },
                () = &mut deadline => {
                    let failure = connect_timeout();
                    let aborted = lock(manager).abort_connecting(terminal_id, &failure.reason_code);
                    if aborted {
                        return Err(failure);
                    }
                    // It ended on its own at the same moment: that is the reason.
                    while let Ok(event) = events.try_recv() {
                        if let ConnectEvent::Failed(failure) = event {
                            return Err(failure);
                        }
                    }
                    return Err(failure);
                }
            }
        }
    }
}

/// Dropped before the connect finished (the request was cancelled): the pane
/// that was opened for it is removed.
struct Abandon<'a> {
    manager: &'a Arc<Mutex<TerminalManager>>,
    terminal_id: &'a str,
    armed: bool,
}

impl Drop for Abandon<'_> {
    fn drop(&mut self) {
        if self.armed {
            lock(self.manager).abort_connecting(self.terminal_id, "connect_abandoned");
        }
    }
}

/// Check the session, then pick the task to exec into: the first RUNNING task
/// of the service with ECS Exec enabled (as `ecs_get_task_arn` does).
async fn find_task(
    cli: &AwsCli,
    target: &EcsTarget,
    profile: &str,
) -> Result<String, ConnectFailure> {
    let failed = |e: aws::AwsRunError| classify_helper_failure(&e, &target.sso_session);
    aws::sts_get_caller_identity(cli, profile)
        .await
        .map_err(failed)?;
    let arns = aws::list_running_tasks(
        cli,
        profile,
        &target.region,
        &target.cluster,
        &target.service_name,
    )
    .await
    .map_err(failed)?;
    if arns.is_empty() {
        return Err(no_running_task());
    }
    let tasks = aws::describe_tasks(cli, profile, &target.region, &target.cluster, &arns)
        .await
        .map_err(failed)?;
    pick_task(&tasks)
}

/// The first RUNNING task with exec enabled. `no_running_task` when none is
/// running at all; `exec_not_enabled` when some run but none can be exec'd into.
fn pick_task(tasks: &[TaskInfo]) -> Result<String, ConnectFailure> {
    let mut running = tasks
        .iter()
        .filter(|t| t.last_status == "RUNNING")
        .peekable();
    if running.peek().is_none() {
        return Err(no_running_task());
    }
    running
        .find(|t| t.exec_enabled)
        .map(|t| t.arn.clone())
        .ok_or_else(exec_not_enabled)
}

fn lock(manager: &Arc<Mutex<TerminalManager>>) -> std::sync::MutexGuard<'_, TerminalManager> {
    manager.lock().unwrap_or_else(|e| e.into_inner())
}
