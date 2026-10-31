//! Connecting the engine to the daemon: the session manager as its
//! [`SessionPort`], the worker thread that feeds it turn events and timers, and
//! the tasks that feed it the job list and publish its state.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;

use super::{NoticeEngine, SessionPort};
use crate::ipc::protocol::ServerMsg;
use crate::ipc::session_manager::{
    NoticeDelivery, SessionManager, TurnEvent, MOTHER_NOTICE_KEY_PREFIX,
};
use crate::mother::JobsFeed;

/// How often the worker thread looks at the timers.
pub const TICK_EVERY: Duration = Duration::from_secs(1);
/// State changes are published at most this often.
pub const PUBLISH_DEBOUNCE: Duration = Duration::from_millis(250);

/// The session manager as a [`SessionPort`]. Holds it weakly: the engine
/// never keeps the manager alive.
pub struct ManagerPort(std::sync::Weak<Mutex<SessionManager>>);

impl ManagerPort {
    pub fn new(sessions: &Arc<Mutex<SessionManager>>) -> Self {
        Self(Arc::downgrade(sessions))
    }
}

impl SessionPort for ManagerPort {
    fn deliver(
        &self,
        tag: &str,
        key: &str,
        merged: &str,
        fresh: &str,
    ) -> anyhow::Result<NoticeDelivery> {
        let sessions = self
            .0
            .upgrade()
            .ok_or_else(|| anyhow::anyhow!("session manager gone"))?;
        let mut mgr = sessions.lock().unwrap_or_else(|e| e.into_inner());
        mgr.inject_notice(tag, key, merged, fresh)
    }

    fn withdraw(&self, tag: &str) {
        if let Some(sessions) = self.0.upgrade() {
            sessions
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .drop_injected_prefix(tag, MOTHER_NOTICE_KEY_PREFIX);
        }
    }
}

/// Connect `engine` to the session manager: deliveries go through it, its
/// focus registry pushes reach the engine, and every session's turn events
/// are handed to one worker thread (which also runs the timers every
/// [`TICK_EVERY`]). The thread ends when the manager drops its hook.
pub fn attach(engine: &Arc<NoticeEngine>, sessions: &Arc<Mutex<SessionManager>>) {
    engine.set_port(Arc::new(ManagerPort::new(sessions)));
    let (tx, rx) = std::sync::mpsc::channel::<(String, TurnEvent)>();
    {
        let mut mgr = sessions.lock().unwrap_or_else(|e| e.into_inner());
        mgr.configure_notice_engine(Arc::clone(engine));
        mgr.set_turn_hook(Arc::new(move |tag: &str, event: &TurnEvent| {
            let _ = tx.send((tag.to_owned(), event.clone()));
        }));
    }
    let weak = Arc::downgrade(engine);
    let spawned = std::thread::Builder::new()
        .name("mother-notices".into())
        .spawn(move || {
            let mut last_tick = std::time::Instant::now();
            loop {
                let next = rx.recv_timeout(TICK_EVERY);
                let Some(engine) = weak.upgrade() else {
                    break;
                };
                match next {
                    Ok((tag, event)) => engine.on_turn(&tag, &event),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
                if last_tick.elapsed() >= TICK_EVERY {
                    engine.tick();
                    last_tick = std::time::Instant::now();
                }
            }
        });
    if spawned.is_err() {
        tracing::warn!("mother notice worker could not start: notices are off");
    }
}

/// Feed every published job list to `engine`, in order.
pub fn spawn_feed_watcher(
    engine: Arc<NoticeEngine>,
    feed: &JobsFeed,
) -> tokio::task::JoinHandle<()> {
    let mut rx = feed.jobs_rx();
    tokio::spawn(async move {
        while rx.changed().await.is_ok() {
            let jobs = rx.borrow_and_update().clone();
            let engine = Arc::clone(&engine);
            let _ = tokio::task::spawn_blocking(move || engine.on_jobs(&jobs)).await;
        }
    })
}

/// Publish the engine's changes (debounced [`PUBLISH_DEBOUNCE`]): the
/// `MotherNoticeState` frame, and the job list re-annotated through the feed
/// (so MCP readers see the same notice records) as a `MotherJobs` frame.
///
/// `republish` (the IPC server's "retained frames were lost" signal) resends
/// the state frame, so a client subscribing later still gets it.
pub fn spawn_publisher(
    engine: Arc<NoticeEngine>,
    feed: JobsFeed,
    tx: tokio::sync::broadcast::Sender<ServerMsg>,
    republish: Option<watch::Receiver<u64>>,
) -> tokio::task::JoinHandle<()> {
    let mut changes = engine.changes();
    let mut listening = republish.is_some();
    let (_keep, idle) = watch::channel(0u64);
    let mut republish = republish.unwrap_or(idle);
    tokio::spawn(async move {
        let _ = tx.send(engine.state_msg());
        loop {
            tokio::select! {
                changed = changes.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    tokio::time::sleep(PUBLISH_DEBOUNCE).await;
                    changes.borrow_and_update();
                    let _ = tx.send(engine.state_msg());
                    if let Some(jobs) = feed.republish_annotations() {
                        let _ = tx.send(ServerMsg::MotherJobs { jobs });
                    }
                }
                lost = republish.changed(), if listening => {
                    if lost.is_err() {
                        listening = false;
                        continue;
                    }
                    let _ = tx.send(engine.state_msg());
                }
            }
        }
    })
}
