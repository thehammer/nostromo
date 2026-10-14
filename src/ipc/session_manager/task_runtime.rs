//! A session's background tasks, wired into the daemon: the registry
//! ([`crate::ipc::tasks`]) behind a lock, the publication of its snapshots and
//! details as [`SessionEvent`]s, the timer that ends vanished tasks and
//! flushes coalesced changes, and the poller that keeps each shell/monitor
//! task's one-line output preview fresh.
//!
//! Lock order: the hub lock may be held while the transcript lock is taken
//! (to look up a call's tool name); never the other way round. Events are
//! published while the hub lock is held so that two publishers cannot reorder
//! snapshots (a snapshot replaces the previous one).
//!
//! The preview text is output-derived: it only ever leaves in
//! `SessionTaskDetail`, a `LocalOnly` frame (see `peer.rs`).

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use tokio::sync::{broadcast, Notify};

use super::control::control;
use super::{lock_recover, SessionEvent, Shared};
use crate::ipc::protocol::{TaskDetailMsg, TasksSnapshot};
use crate::ipc::stream_json::SessionTranscript;
use crate::ipc::task_output::{
    is_valid_task_id, last_nonempty_line, root_of_output_path, sanitize, OutputFileValidator,
    TAIL_MAX_BYTES,
};
use crate::ipc::tasks::{PreviewTarget, TaskEvent, TaskEventKind, TaskHub, TaskOutput};

/// How often a running task's output is read for its preview.
pub(super) const PREVIEW_INTERVAL: Duration = Duration::from_secs(1);

/// The random id of this daemon process (see `TasksSnapshot::daemon_epoch`).
pub(super) fn daemon_epoch() -> &'static str {
    static EPOCH: OnceLock<String> = OnceLock::new();
    EPOCH.get_or_init(|| uuid::Uuid::new_v4().to_string())
}

/// Milliseconds since the Unix epoch, advancing with tokio's clock so tests
/// can pause time. Fixed at construction to the wall time then.
struct TaskClock {
    base_epoch_ms: u64,
    started: tokio::time::Instant,
}

impl TaskClock {
    fn new() -> Self {
        let base_epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        Self {
            base_epoch_ms,
            started: tokio::time::Instant::now(),
        }
    }

    fn now_ms(&self) -> u64 {
        self.base_epoch_ms + self.started.elapsed().as_millis() as u64
    }
}

/// What the poller and the path ladder remember between reads.
struct FileState {
    validator: OutputFileValidator,
    /// A root was learned from a path the CLI reported.
    root_learned: bool,
    /// The directory of an output file that validated: its siblings are
    /// where the other tasks' files are.
    known_dir: Option<PathBuf>,
    /// Tasks the poller read while they ran.
    polled: HashSet<String>,
    /// Ended tasks whose final read happened.
    finalized: HashSet<String>,
}

/// One session's task state. Shared by the reader thread, the timer, the
/// poller, and the attach/forwarder paths.
pub(super) struct TaskRuntime {
    hub: Mutex<TaskHub>,
    transcript: Arc<Mutex<SessionTranscript>>,
    clock: TaskClock,
    session_id: Option<String>,
    /// The CLI's working directory (for the derived output path).
    cwd: PathBuf,
    /// Clients attached to the session.
    clients: AtomicUsize,
    poller_running: AtomicBool,
    /// Wakes the timer: something changed, or the session ended.
    wake: Notify,
    files: Mutex<FileState>,
}

impl TaskRuntime {
    pub(super) fn new(
        transcript: Arc<Mutex<SessionTranscript>>,
        session_id: Option<String>,
        cwd: PathBuf,
    ) -> Arc<Self> {
        Self::with_validator(transcript, session_id, cwd, OutputFileValidator::for_current_user())
    }

    /// [`Self::new`] with the validator to use (tests inject a temp root).
    pub(super) fn with_validator(
        transcript: Arc<Mutex<SessionTranscript>>,
        session_id: Option<String>,
        cwd: PathBuf,
        validator: OutputFileValidator,
    ) -> Arc<Self> {
        Arc::new(Self {
            hub: Mutex::new(TaskHub::new()),
            transcript,
            clock: TaskClock::new(),
            session_id: session_id.filter(|s| !s.is_empty()),
            cwd,
            clients: AtomicUsize::new(0),
            poller_running: AtomicBool::new(false),
            wake: Notify::new(),
            files: Mutex::new(FileState {
                validator,
                root_learned: false,
                known_dir: None,
                polled: HashSet::new(),
                finalized: HashSet::new(),
            }),
        })
    }

    /// A background-task event from the CLI.
    pub(super) fn on_event(&self, tx: &broadcast::Sender<SessionEvent>, event: &TaskEvent) {
        if let TaskEventKind::Notification(n) = &event.kind {
            if let Some(path) = &n.output_file {
                self.learn_root(path);
            }
        }
        {
            let lookup = self.tool_lookup();
            let mut hub = lock_recover(&self.hub);
            let out = hub.on_event(event, self.clock.now_ms(), &lookup);
            self.publish(tx, out);
        }
        self.wake.notify_one();
    }

    /// The CLI process ended: end every task with it and publish at once.
    pub(super) fn end_session(&self, tx: &broadcast::Sender<SessionEvent>) {
        {
            let lookup = self.tool_lookup();
            let mut hub = lock_recover(&self.hub);
            let out = hub.end_session(self.clock.now_ms(), &lookup);
            self.publish(tx, out);
        }
        self.wake.notify_one();
    }

    /// A client attached or detached: `count` are attached now.
    pub(super) fn set_clients(&self, count: usize) {
        self.clients.store(count, Ordering::SeqCst);
        self.wake.notify_one();
    }

    /// The current snapshot and every detail, for an attaching client or a
    /// forwarder that lagged.
    pub(super) fn current(&self) -> (Arc<TasksSnapshot>, Vec<Arc<TaskDetailMsg>>) {
        let lookup = self.tool_lookup();
        let hub = lock_recover(&self.hub);
        let (tasks, details) = hub.current(&lookup);
        (
            Arc::new(self.snapshot_of(tasks)),
            details.into_iter().map(Arc::new).collect(),
        )
    }

    // ── timer ───────────────────────────────────────────────────────────────

    /// Publish what is due and end the tasks whose grace ran out.
    fn run_due(&self, tx: &broadcast::Sender<SessionEvent>) {
        let lookup = self.tool_lookup();
        let mut hub = lock_recover(&self.hub);
        let out = hub.on_tick(self.clock.now_ms(), &lookup);
        self.publish(tx, out);
    }

    /// Milliseconds until something is due, `None` when nothing is.
    fn until_next_wakeup(&self) -> Option<u64> {
        let next = lock_recover(&self.hub).next_wakeup()?;
        Some(next.saturating_sub(self.clock.now_ms()))
    }

    // ── internals ───────────────────────────────────────────────────────────

    fn tool_lookup(&self) -> impl Fn(&str) -> Option<String> + '_ {
        move |id| lock_recover(&self.transcript).tool_name_of(id).map(str::to_owned)
    }

    fn snapshot_of(&self, tasks: Vec<crate::ipc::protocol::TaskMeta>) -> TasksSnapshot {
        TasksSnapshot {
            session_id: self.session_id.clone(),
            daemon_epoch: daemon_epoch().to_owned(),
            // Learned by the capability probe (a later slice).
            stop_supported: None,
            tasks,
        }
    }

    fn publish(&self, tx: &broadcast::Sender<SessionEvent>, out: Vec<TaskOutput>) {
        for item in out {
            let event = match item {
                TaskOutput::Snapshot(tasks) => {
                    SessionEvent::Tasks(Arc::new(self.snapshot_of(tasks)))
                }
                TaskOutput::Detail(detail) => SessionEvent::TaskDetail(Arc::new(detail)),
            };
            let _ = tx.send(event);
        }
    }

    /// The first path the CLI reports teaches the root its files live under.
    fn learn_root(&self, reported: &str) {
        let mut files = lock_recover(&self.files);
        if files.root_learned {
            return;
        }
        if let Some(root) = root_of_output_path(std::path::Path::new(reported)) {
            files.validator.add_root(root);
            files.root_learned = true;
        }
    }

    // ── preview ─────────────────────────────────────────────────────────────

    /// A poller is needed: a client is attached and there is a task to read.
    fn poll_wanted(&self) -> bool {
        self.clients.load(Ordering::SeqCst) > 0 && !self.poll_plan().is_empty()
    }

    /// What the poller reads next: every running shell/monitor task, and the
    /// ended ones due their final read.
    fn poll_plan(&self) -> Vec<PreviewTarget> {
        let lookup = self.tool_lookup();
        let targets = lock_recover(&self.hub).registry().preview_targets(&lookup);
        let files = lock_recover(&self.files);
        targets
            .into_iter()
            .filter(|t| {
                !t.terminal
                    || (!files.finalized.contains(&t.task_id)
                        && (files.polled.contains(&t.task_id) || t.preview.is_none()))
            })
            .collect()
    }

    /// The files a task's output may be in, most authoritative first.
    fn candidate_paths(&self, target: &PreviewTarget) -> Vec<PathBuf> {
        let id = &target.task_id;
        let name = format!("{id}.output");
        let mut paths: Vec<PathBuf> = Vec::new();
        paths.extend(target.output_file.iter().map(PathBuf::from));
        if let Some(tool_use_id) = &target.tool_use_id {
            let known = lock_recover(&self.transcript)
                .background_output_path(tool_use_id)
                .map(PathBuf::from);
            paths.extend(known);
        }
        let files = lock_recover(&self.files);
        paths.extend(files.known_dir.iter().map(|d| d.join(&name)));
        if let Some(session_id) = &self.session_id {
            let cwd = self.cwd.to_string_lossy();
            let slashes = cwd.replace('/', "-");
            let non_alnum: String = cwd
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            let mut dirs = vec![slashes];
            if dirs[0] != non_alnum {
                dirs.push(non_alnum);
            }
            for root in files.validator.roots() {
                for dir in &dirs {
                    paths.push(root.join(dir).join(session_id).join("tasks").join(&name));
                }
            }
        }
        paths.dedup();
        paths
    }

    /// Read the tail of the first candidate file that validates. `None`: no
    /// file could be read.
    async fn read_file_tail(&self, target: &PreviewTarget) -> Option<Vec<u8>> {
        for path in self.candidate_paths(target) {
            let validator = lock_recover(&self.files).validator.clone();
            let id = target.task_id.clone();
            let read_path = path.clone();
            let read = tokio::task::spawn_blocking(move || {
                validator.read_tail(&read_path, &id, TAIL_MAX_BYTES)
            })
            .await;
            if let Ok(Ok(tail)) = read {
                if let Some(dir) = path.parent() {
                    lock_recover(&self.files).known_dir = Some(dir.to_path_buf());
                }
                return Some(tail.bytes);
            }
        }
        None
    }
}

/// The timer of a session: flushes coalesced changes and ends vanished tasks.
/// Runs until the session's CLI has exited.
pub(super) async fn drive_timer(
    runtime: Arc<TaskRuntime>,
    tx: broadcast::Sender<SessionEvent>,
    exited: Arc<AtomicBool>,
) {
    loop {
        if exited.load(Ordering::SeqCst) {
            return;
        }
        runtime.run_due(&tx);
        // `notified()` is created before the next wakeup is computed, and
        // `notify_one` stores a permit when nobody waits: no lost wakeups.
        let notified = runtime.wake.notified();
        match runtime.until_next_wakeup() {
            Some(ms) => {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(ms)) => {}
                    _ = notified => {}
                }
            }
            None => notified.await,
        }
    }
}

/// Start the preview poller if it is wanted and not already running.
pub(super) fn ensure_poller(shared: &Shared) {
    let runtime = &shared.tasks;
    if shared.exited.load(Ordering::SeqCst) || !runtime.poll_wanted() {
        return;
    }
    if runtime
        .poller_running
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        let shared = shared.clone();
        let handle = shared.runtime.clone();
        handle.spawn(poll_loop(shared));
    }
}

/// One poller: read, publish what changed, repeat while wanted.
async fn poll_loop(shared: Shared) {
    let runtime = Arc::clone(&shared.tasks);
    loop {
        let plan = if shared.exited.load(Ordering::SeqCst) {
            Vec::new()
        } else if runtime.clients.load(Ordering::SeqCst) == 0 {
            Vec::new()
        } else {
            runtime.poll_plan()
        };
        if plan.is_empty() {
            runtime.poller_running.store(false, Ordering::SeqCst);
            // A change may have landed between the check and the store.
            if !shared.exited.load(Ordering::SeqCst)
                && runtime.poll_wanted()
                && runtime
                    .poller_running
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_ok()
            {
                continue;
            }
            return;
        }
        let mut reads = tokio::task::JoinSet::new();
        for target in plan {
            let shared = shared.clone();
            reads.spawn(async move {
                let line = read_preview(&shared, &target).await;
                (target, line)
            });
        }
        while let Some(done) = reads.join_next().await {
            let Ok((target, line)) = done else { continue };
            record_read(&shared, &target, line);
        }
        tokio::time::sleep(PREVIEW_INTERVAL).await;
    }
}

/// Publish a read's result, and note the task as polled or finalized.
fn record_read(shared: &Shared, target: &PreviewTarget, line: Option<String>) {
    let runtime = &shared.tasks;
    {
        let mut files = lock_recover(&runtime.files);
        if target.terminal {
            files.finalized.insert(target.task_id.clone());
        } else {
            files.polled.insert(target.task_id.clone());
        }
    }
    let Some(line) = line else { return };
    if target.preview.as_deref() == Some(line.as_str()) {
        return;
    }
    let lookup = runtime.tool_lookup();
    let mut hub = lock_recover(&runtime.hub);
    let out = hub.set_preview(&target.task_id, Some(line), runtime.clock.now_ms(), &lookup);
    runtime.publish(&shared.event_tx, out);
    drop(hub);
    runtime.wake.notify_one();
}

/// The last non-empty sanitised output line of a task: from its file when a
/// validated path is known, else from the CLI's own `get_task_output`. `None`
/// when nothing could be read (the last preview then stays).
async fn read_preview(shared: &Shared, target: &PreviewTarget) -> Option<String> {
    if !is_valid_task_id(&target.task_id) {
        return None;
    }
    if let Some(bytes) = shared.tasks.read_file_tail(target).await {
        return last_nonempty_line(&sanitize(&bytes));
    }
    let reply = control(
        shared,
        serde_json::json!({ "subtype": "get_task_output", "task_id": target.task_id }),
    )
    .await
    .ok()?;
    let output = reply.body.get("output")?.as_str()?;
    last_nonempty_line(&sanitize(output.as_bytes()))
}

/// Forward one session's events to one client, in order. On `Lagged` the
/// events skipped may have held the latest snapshot or detail, so the current
/// ones are sent before carrying on.
pub(super) async fn forward_session_events(
    mut rx: broadcast::Receiver<SessionEvent>,
    send: impl Fn(crate::ipc::protocol::ServerMsg) -> bool,
    tag: String,
    runtime: Arc<TaskRuntime>,
) {
    use crate::ipc::protocol::ServerMsg;
    loop {
        match rx.recv().await {
            Ok(ev) => {
                let msg = match ev {
                    SessionEvent::Delta(delta) => ServerMsg::SessionTurnDelta {
                        tag: tag.clone(),
                        delta,
                    },
                    SessionEvent::State(state) => ServerMsg::SessionState {
                        tag: tag.clone(),
                        state,
                    },
                    SessionEvent::Exited { exit_code } => ServerMsg::SessionExited {
                        tag: tag.clone(),
                        exit_code,
                    },
                    SessionEvent::PermanentlyDown { reason } => ServerMsg::SessionDown {
                        tag: tag.clone(),
                        reason,
                    },
                    SessionEvent::Tasks(snapshot) => tasks_msg(&tag, &snapshot),
                    SessionEvent::TaskDetail(detail) => detail_msg(&tag, &detail),
                };
                if !send(msg) {
                    break; // client disconnected
                }
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!(tag = %tag, "session forwarder lagged {n}");
                let (snapshot, details) = runtime.current();
                if !send(tasks_msg(&tag, &snapshot)) {
                    break;
                }
                for detail in details {
                    if !send(detail_msg(&tag, &detail)) {
                        return;
                    }
                }
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// The `SessionTasks` frame for a snapshot.
pub(super) fn tasks_msg(tag: &str, snapshot: &TasksSnapshot) -> crate::ipc::protocol::ServerMsg {
    crate::ipc::protocol::ServerMsg::SessionTasks {
        tag: tag.to_owned(),
        session_id: snapshot.session_id.clone(),
        daemon_epoch: snapshot.daemon_epoch.clone(),
        stop_supported: snapshot.stop_supported,
        tasks: snapshot.tasks.clone(),
    }
}

/// The `SessionTaskDetail` frame for a detail.
pub(super) fn detail_msg(tag: &str, detail: &TaskDetailMsg) -> crate::ipc::protocol::ServerMsg {
    crate::ipc::protocol::ServerMsg::SessionTaskDetail {
        tag: tag.to_owned(),
        task_id: detail.task_id.clone(),
        preview: detail.preview.clone(),
        progress_summary: detail.progress_summary.clone(),
        completion_summary: detail.completion_summary.clone(),
        prompt: detail.prompt.clone(),
    }
}
