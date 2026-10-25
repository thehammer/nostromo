//! Opening a remote shell once the user has said Connect.
//!
//! [`RemoteLauncher`] is the seam between the confirm flow (2a, which decides
//! *whether* to connect) and the code that starts the shell. The daemon's
//! launcher is [`UnavailableLauncher`] until the real one lands; tests use
//! [`testing::FakeLauncher`]. Nothing calls a launcher before an operator's
//! `remote_shell_answer {decision: "connect"}` (`remote_request::run`).

use async_trait::async_trait;

use super::ecs::EcsTarget;
use crate::ipc::protocol::{TerminalInfo, TerminalRequester};

/// Where in the focus's pane tree a new terminal leaf goes (see
/// [`super::DEFAULT_RELATIVE_TO`], [`super::DEFAULT_POSITION`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Placement {
    pub relative_to: Option<String>,
    pub position: Option<String>,
}

/// Why a remote shell could not be opened. No pane exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectFailure {
    /// A short code for the audit trail and the app (`not_available`, …).
    pub reason_code: String,
    /// What happened, in a sentence.
    pub message: String,
    /// What the user can do about it.
    pub remedy: Option<String>,
}

/// Opens a remote shell. The returned terminal already has its pane.
///
/// The returned future may be dropped before it finishes (the agent that asked
/// went away): an implementation must clean up anything it started if so.
// newer clippy flags the macro-generated attribute as `double_must_use`.
#[allow(clippy::double_must_use)]
#[async_trait]
pub trait RemoteLauncher: Send + Sync {
    async fn connect(
        &self,
        target: &EcsTarget,
        tag: &str,
        placement: &Placement,
        requested_by: &TerminalRequester,
    ) -> Result<TerminalInfo, ConnectFailure>;
}

/// Fails every connect: this daemon cannot open remote shells yet.
pub struct UnavailableLauncher;

#[async_trait]
impl RemoteLauncher for UnavailableLauncher {
    async fn connect(
        &self,
        _target: &EcsTarget,
        _tag: &str,
        _placement: &Placement,
        _requested_by: &TerminalRequester,
    ) -> Result<TerminalInfo, ConnectFailure> {
        Err(ConnectFailure {
            reason_code: "not_available".into(),
            message: "This version of Nostromo cannot open remote shells yet.".into(),
            remedy: Some("Update Nostromo and restart the daemon.".into()),
        })
    }
}

/// Test support: a launcher that opens `/bin/cat` as an `ecs` terminal (or
/// fails on demand) and counts its calls. Not compiled into the daemon.
#[cfg(any(test, feature = "test-support"))]
pub mod testing {
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, Weak};

    use async_trait::async_trait;

    use super::{ConnectFailure, Placement, RemoteLauncher};
    use crate::ipc::protocol::{TerminalInfo, TerminalRequester, TerminalStatus};
    use crate::terminal::ecs::EcsTarget;
    use crate::terminal::session::TerminalSession;
    use crate::terminal::{store, OpenRemote, TerminalManager};

    /// Opens an `ecs`-kind terminal running `/bin/cat`, labelled
    /// `"<env> · <project> · <service> · <shell_type>"`, in the manager it was
    /// built for (held weakly: the manager owns its launcher).
    pub struct FakeLauncher {
        manager: Weak<Mutex<TerminalManager>>,
        calls: AtomicUsize,
        failure: Mutex<Option<ConnectFailure>>,
        last: Mutex<Option<(EcsTarget, String)>>,
    }

    impl FakeLauncher {
        /// A launcher whose connects succeed.
        pub fn new(manager: &Arc<Mutex<TerminalManager>>) -> Arc<Self> {
            Arc::new(Self {
                manager: Arc::downgrade(manager),
                calls: AtomicUsize::new(0),
                failure: Mutex::new(None),
                last: Mutex::new(None),
            })
        }

        /// A launcher whose connects fail with `failure`.
        pub fn failing(
            manager: &Arc<Mutex<TerminalManager>>,
            failure: ConnectFailure,
        ) -> Arc<Self> {
            let launcher = Self::new(manager);
            launcher.set_failure(Some(failure));
            launcher
        }

        /// Fail (`Some`) or succeed (`None`) from the next connect on.
        pub fn set_failure(&self, failure: Option<ConnectFailure>) {
            *self.failure.lock().unwrap_or_else(|e| e.into_inner()) = failure;
        }

        /// How many times `connect` has been called.
        pub fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }

        /// The target and focus tag of the latest `connect` call.
        pub fn last_call(&self) -> Option<(EcsTarget, String)> {
            self.last.lock().unwrap_or_else(|e| e.into_inner()).clone()
        }
    }

    #[async_trait]
    impl RemoteLauncher for FakeLauncher {
        async fn connect(
            &self,
            target: &EcsTarget,
            tag: &str,
            placement: &Placement,
            requested_by: &TerminalRequester,
        ) -> Result<TerminalInfo, ConnectFailure> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            *self.last.lock().unwrap_or_else(|e| e.into_inner()) =
                Some((target.clone(), tag.to_string()));
            if let Some(failure) = self
                .failure
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
            {
                return Err(failure);
            }
            let failed = |code: &str, message: &str| ConnectFailure {
                reason_code: code.into(),
                message: message.into(),
                remedy: None,
            };
            let manager = self
                .manager
                .upgrade()
                .ok_or_else(|| failed("daemon_stopping", "the terminal manager is gone"))?;
            let session = TerminalSession::spawn_argv(
                &["/bin/cat".to_string()],
                Path::new("/"),
                &[],
                store::DEFAULT_COLS,
                store::DEFAULT_ROWS,
            )
            .map_err(|e| failed("spawn_failed", &format!("{e:#}")))?;
            let label = format!(
                "{} · {} · {} · {}",
                target.environment, target.project, target.service, target.shell_type
            );
            let opened = manager
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .open_remote(
                    OpenRemote {
                        tag: tag.to_string(),
                        placement: placement.clone(),
                        requested_by: requested_by.clone(),
                        target: target.terminal_target(),
                        label,
                        status: TerminalStatus::Running,
                        watch: None,
                    },
                    session,
                );
            opened.map_err(|e| failed(e.code(), "the pane could not be opened"))
        }
    }
}
