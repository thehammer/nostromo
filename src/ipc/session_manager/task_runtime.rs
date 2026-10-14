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
use crate::ipc::protocol::{ServerMsg, TaskDetailMsg, TaskMeta, TasksSnapshot};
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

    fn snapshot_of(&self, tasks: Vec<TaskMeta>) -> TasksSnapshot {
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

    /// Mark the poller as running; `false` when one already is.
    fn claim_poller(&self) -> bool {
        self.poller_running
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
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
    if runtime.claim_poller() {
        let shared = shared.clone();
        let handle = shared.runtime.clone();
        handle.spawn(poll_loop(shared));
    }
}

/// One poller: read, publish what changed, repeat while wanted.
async fn poll_loop(shared: Shared) {
    let runtime = Arc::clone(&shared.tasks);
    loop {
        let plan = if shared.exited.load(Ordering::SeqCst)
            || runtime.clients.load(Ordering::SeqCst) == 0
        {
            Vec::new()
        } else {
            runtime.poll_plan()
        };
        if plan.is_empty() {
            runtime.poller_running.store(false, Ordering::SeqCst);
            // A change may have landed between the check and the store.
            if !shared.exited.load(Ordering::SeqCst)
                && runtime.poll_wanted()
                && runtime.claim_poller()
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
    send: impl Fn(ServerMsg) -> bool,
    tag: String,
    runtime: Arc<TaskRuntime>,
) {
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
pub(super) fn tasks_msg(tag: &str, snapshot: &TasksSnapshot) -> ServerMsg {
    ServerMsg::SessionTasks {
        tag: tag.to_owned(),
        session_id: snapshot.session_id.clone(),
        daemon_epoch: snapshot.daemon_epoch.clone(),
        stop_supported: snapshot.stop_supported,
        tasks: snapshot.tasks.clone(),
    }
}

/// The `SessionTaskDetail` frame for a detail.
pub(super) fn detail_msg(tag: &str, detail: &TaskDetailMsg) -> ServerMsg {
    ServerMsg::SessionTaskDetail {
        tag: tag.to_owned(),
        task_id: detail.task_id.clone(),
        preview: detail.preview.clone(),
        progress_summary: detail.progress_summary.clone(),
        completion_summary: detail.completion_summary.clone(),
        prompt: detail.prompt.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::protocol::{ServerMsg, TaskEndReason, TaskKind, TaskStatus};
    use crate::ipc::stream_json::SessionState;
    use crate::ipc::tasks::parse_task_event;
    use serde_json::json;
    use tokio::sync::mpsc;

    fn event(subtype: &str, body: serde_json::Value) -> TaskEvent {
        parse_task_event(subtype, body.as_object().unwrap())
            .unwrap_or_else(|| panic!("{subtype} did not parse: {body}"))
    }

    fn started(id: &str, extra: serde_json::Value) -> TaskEvent {
        let mut body = json!({"task_id": id, "description": "a task"});
        body.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        event("task_started", body)
    }

    fn progress(id: &str, tokens: u64) -> TaskEvent {
        event("task_progress", json!({"task_id": id, "usage": {"total_tokens": tokens}}))
    }

    fn notified(id: &str, status: &str, extra: serde_json::Value) -> TaskEvent {
        let mut body = json!({"task_id": id, "status": status});
        body.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        event("task_notification", body)
    }

    fn level(ids: &[&str]) -> TaskEvent {
        event(
            "background_tasks_changed",
            json!({"tasks": ids.iter().map(|id| json!({"task_id": id, "task_type": "local_bash", "description": "d"})).collect::<Vec<_>>()}),
        )
    }

    fn runtime() -> (Arc<TaskRuntime>, Arc<Mutex<SessionTranscript>>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let transcript = Arc::new(Mutex::new(SessionTranscript::new()));
        let runtime = TaskRuntime::with_validator(
            Arc::clone(&transcript),
            Some("sess-1".into()),
            PathBuf::from("/work/repo"),
            OutputFileValidator::new(dir.path()),
        );
        (runtime, transcript, dir)
    }

    /// Let spawned tasks run (paused-time tests only).
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    fn drain(rx: &mut broadcast::Receiver<SessionEvent>) -> Vec<SessionEvent> {
        let mut out = vec![];
        while let Ok(ev) = rx.try_recv() {
            out.push(ev);
        }
        out
    }

    fn snapshots(events: &[SessionEvent]) -> Vec<Arc<TasksSnapshot>> {
        events
            .iter()
            .filter_map(|e| match e {
                SessionEvent::Tasks(s) => Some(Arc::clone(s)),
                _ => None,
            })
            .collect()
    }

    // ── publication ─────────────────────────────────────────────────────────

    #[test]
    fn the_first_task_event_is_published_at_once_with_the_session_and_daemon_ids() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);

        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash"})));

        let published = snapshots(&drain(&mut rx));
        assert_eq!(published.len(), 1);
        assert_eq!(published[0].session_id.as_deref(), Some("sess-1"));
        assert_eq!(published[0].daemon_epoch, daemon_epoch());
        assert_eq!(published[0].stop_supported, None);
        assert_eq!(published[0].tasks.len(), 1);
    }

    #[test]
    fn the_daemon_epoch_is_one_stable_id_per_process() {
        assert!(!daemon_epoch().is_empty());
        assert_eq!(daemon_epoch(), daemon_epoch());
    }

    #[test]
    fn a_task_started_after_its_tool_call_is_resolved_against_the_transcript() {
        let (rt, transcript, _dir) = runtime();
        {
            let mut t = transcript.lock().unwrap();
            t.ingest_line(r#"{"type":"user","message":{"role":"user","content":"watch it"},"isReplay":true}"#);
            t.ingest_line(r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_mon","name":"Monitor","input":{"command":"tail -f x"}}]}}"#);
        }
        let (tx, _rx) = broadcast::channel(16);

        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"})));

        let (snapshot, _) = rt.current();
        assert_eq!(snapshot.tasks[0].kind, TaskKind::Monitor);
        assert_eq!(snapshot.tasks[0].tool_name.as_deref(), Some("Monitor"));
    }

    #[test]
    fn the_end_of_the_session_publishes_every_task_stopped_at_once() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);
        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash"})));
        rt.on_event(&tx, &started("t2", json!({}))); // inside the window: deferred
        drain(&mut rx);

        rt.end_session(&tx);

        let published = snapshots(&drain(&mut rx));
        assert_eq!(published.len(), 1, "one final snapshot");
        let tasks = &published[0].tasks;
        assert_eq!(tasks.len(), 2, "the deferred task is in it");
        for t in tasks {
            assert_eq!((t.status, t.end_reason), (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded)));
        }
    }

    #[test]
    fn current_reports_the_state_even_when_nothing_was_published() {
        let (rt, _t, _dir) = runtime();
        let (tx, _rx) = broadcast::channel(16);
        rt.on_event(&tx, &started("t1", json!({"prompt": "do it"})));
        rt.on_event(&tx, &progress("t1", 42)); // deferred

        let (snapshot, details) = rt.current();

        assert_eq!(snapshot.tasks[0].total_tokens, Some(42));
        assert_eq!(details.len(), 1);
        assert_eq!(details[0].prompt.as_deref(), Some("do it"));
    }

    // ── the timer (paused time: no real waiting, no sleeps) ─────────────────

    #[tokio::test(start_paused = true)]
    async fn the_timer_publishes_a_deferred_change_when_the_window_ends() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);
        let exited = Arc::new(AtomicBool::new(false));
        rt.on_event(&tx, &started("t1", json!({})));
        rt.on_event(&tx, &progress("t1", 7));
        assert_eq!(snapshots(&drain(&mut rx)).len(), 1, "only the first change went out");
        let timer = tokio::spawn(drive_timer(Arc::clone(&rt), tx.clone(), Arc::clone(&exited)));
        settle().await;

        tokio::time::advance(Duration::from_millis(249)).await;
        settle().await;
        assert!(snapshots(&drain(&mut rx)).is_empty(), "the window is still open");

        tokio::time::advance(Duration::from_millis(1)).await;
        settle().await;
        let published = snapshots(&drain(&mut rx));
        assert_eq!(published.len(), 1);
        assert_eq!(published[0].tasks[0].total_tokens, Some(7));

        exited.store(true, Ordering::SeqCst);
        rt.set_clients(0);
        timer.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn the_timer_ends_a_vanished_task_exactly_when_its_grace_runs_out() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);
        let exited = Arc::new(AtomicBool::new(false));
        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash", "is_backgrounded": true})));
        rt.on_event(&tx, &level(&["t1"]));
        rt.on_event(&tx, &level(&[]));
        drain(&mut rx);
        let timer = tokio::spawn(drive_timer(Arc::clone(&rt), tx.clone(), Arc::clone(&exited)));
        settle().await;

        tokio::time::advance(Duration::from_millis(2_999)).await;
        settle().await;
        assert!(snapshots(&drain(&mut rx)).is_empty(), "still inside the grace");
        assert_eq!(rt.current().0.tasks[0].status, TaskStatus::Running);

        tokio::time::advance(Duration::from_millis(1)).await;
        settle().await;
        let published = snapshots(&drain(&mut rx));
        assert_eq!(published.len(), 1, "the vanish is published, not just recorded");
        let t = &published[0].tasks[0];
        assert_eq!((t.status, t.end_reason), (TaskStatus::Stopped, Some(TaskEndReason::Vanished)));

        exited.store(true, Ordering::SeqCst);
        rt.set_clients(0);
        timer.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_that_ends_for_real_inside_the_grace_is_never_published_as_vanished() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);
        let exited = Arc::new(AtomicBool::new(false));
        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash", "is_backgrounded": true})));
        rt.on_event(&tx, &level(&["t1"]));
        rt.on_event(&tx, &level(&[]));
        let timer = tokio::spawn(drive_timer(Arc::clone(&rt), tx.clone(), Arc::clone(&exited)));
        settle().await;
        tokio::time::advance(Duration::from_millis(2_000)).await;
        rt.on_event(&tx, &notified("t1", "completed", json!({})));

        tokio::time::advance(Duration::from_millis(5_000)).await;
        settle().await;

        let all = snapshots(&drain(&mut rx));
        assert!(
            all.iter().flat_map(|s| s.tasks.iter()).all(|t| t.end_reason != Some(TaskEndReason::Vanished)),
            "{all:?}"
        );
        assert_eq!(all.last().unwrap().tasks[0].status, TaskStatus::Completed);
        exited.store(true, Ordering::SeqCst);
        rt.set_clients(0);
        timer.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn the_timer_stops_once_the_session_has_exited() {
        let (rt, _t, _dir) = runtime();
        let (tx, _rx) = broadcast::channel(16);
        let exited = Arc::new(AtomicBool::new(false));
        let timer = tokio::spawn(drive_timer(Arc::clone(&rt), tx.clone(), Arc::clone(&exited)));
        settle().await;

        exited.store(true, Ordering::SeqCst);
        rt.end_session(&tx);

        tokio::time::timeout(Duration::from_secs(5), timer)
            .await
            .expect("the timer ends with the session")
            .unwrap();
    }

    // ── the forwarder ───────────────────────────────────────────────────────

    async fn next_frame(rx: &mut mpsc::UnboundedReceiver<ServerMsg>) -> ServerMsg {
        tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .expect("a frame within 10 s")
            .expect("the forwarder is still sending")
    }

    fn exit_code_of(msg: &ServerMsg) -> Option<i32> {
        match msg {
            ServerMsg::SessionExited { exit_code, .. } => *exit_code,
            other => panic!("expected SessionExited, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn the_forwarder_turns_every_session_event_into_its_frame_in_order() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(64);
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(rx, move |m| out_tx.send(m).is_ok(), "cody-1".into(), rt));
        let snapshot = TasksSnapshot {
            session_id: Some("sess-1".into()),
            daemon_epoch: "epoch-1".into(),
            stop_supported: Some(true),
            tasks: vec![],
        };

        tx.send(SessionEvent::State(SessionState::MidTurn)).unwrap();
        tx.send(SessionEvent::Tasks(Arc::new(snapshot))).unwrap();
        tx.send(SessionEvent::TaskDetail(Arc::new(TaskDetailMsg {
            task_id: "t1".into(),
            preview: Some("line".into()),
            ..Default::default()
        })))
        .unwrap();
        tx.send(SessionEvent::Exited { exit_code: Some(3) }).unwrap();
        tx.send(SessionEvent::PermanentlyDown { reason: crate::ipc::session_manager::StopReason::User }).unwrap();

        assert!(matches!(next_frame(&mut out).await, ServerMsg::SessionState { tag, state: SessionState::MidTurn } if tag == "cody-1"));
        match next_frame(&mut out).await {
            ServerMsg::SessionTasks { tag, session_id, daemon_epoch, stop_supported, tasks } => {
                assert_eq!(tag, "cody-1");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
                assert_eq!(daemon_epoch, "epoch-1");
                assert_eq!(stop_supported, Some(true));
                assert!(tasks.is_empty());
            }
            other => panic!("{other:?}"),
        }
        match next_frame(&mut out).await {
            ServerMsg::SessionTaskDetail { tag, task_id, preview, progress_summary, completion_summary, prompt } => {
                assert_eq!((tag.as_str(), task_id.as_str(), preview.as_deref()), ("cody-1", "t1", Some("line")));
                assert_eq!((progress_summary, completion_summary, prompt), (None, None, None));
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(3));
        assert!(matches!(next_frame(&mut out).await, ServerMsg::SessionDown { .. }));
        drop(tx);
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn a_forwarder_whose_client_is_gone_stops() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(8);
        let handle = tokio::spawn(forward_session_events(rx, |_| false, "cody-1".into(), rt));

        tx.send(SessionEvent::Exited { exit_code: None }).unwrap();

        tokio::time::timeout(Duration::from_secs(10), handle)
            .await
            .expect("the forwarder ends when its client is gone")
            .unwrap();
    }

    #[tokio::test]
    async fn a_forwarder_that_lagged_sends_the_current_tasks_then_their_details_before_going_on() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(2);
        // The task's whole story happens while the forwarder is not reading.
        rt.on_event(&tx, &started("agt", json!({"task_type": "local_agent", "prompt": "Read the config"})));
        rt.on_event(&tx, &notified("agt", "completed", json!({"summary": "All done"})));
        for code in 10..13 {
            tx.send(SessionEvent::Exited { exit_code: Some(code) }).unwrap();
        }
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(rx, move |m| out_tx.send(m).is_ok(), "cody-1".into(), Arc::clone(&rt)));

        // First: the current snapshot, which has the final state.
        let ServerMsg::SessionTasks { tag, session_id, tasks, .. } = next_frame(&mut out).await else {
            panic!("the first frame after a lag must be the current task list")
        };
        assert_eq!((tag.as_str(), session_id.as_deref()), ("cody-1", Some("sess-1")));
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].status, TaskStatus::Completed, "the state the dropped events described");
        // Then: its details.
        let ServerMsg::SessionTaskDetail { task_id, prompt, completion_summary, .. } = next_frame(&mut out).await else {
            panic!("the details follow the snapshot")
        };
        assert_eq!(task_id, "agt");
        assert_eq!(prompt.as_deref(), Some("Read the config"));
        assert_eq!(completion_summary.as_deref(), Some("All done"));
        // Only then: what was still in the channel, and what comes later.
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(11));
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(12));
        tx.send(SessionEvent::Exited { exit_code: Some(13) }).unwrap();
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(13));
        drop(tx);
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn a_lag_with_no_tasks_still_sends_the_empty_list_so_the_client_converges() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(2);
        for code in 0..5 {
            tx.send(SessionEvent::Exited { exit_code: Some(code) }).unwrap();
        }
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(rx, move |m| out_tx.send(m).is_ok(), "t".into(), rt));

        let ServerMsg::SessionTasks { tasks, .. } = next_frame(&mut out).await else { panic!("first frame") };
        assert!(tasks.is_empty());
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(3));
        drop(tx);
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn a_forwarder_that_never_lagged_does_not_repeat_the_task_list() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(64);
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(rx, move |m| out_tx.send(m).is_ok(), "t".into(), rt));
        tx.send(SessionEvent::Tasks(Arc::new(TasksSnapshot {
            session_id: None,
            daemon_epoch: "e".into(),
            stop_supported: None,
            tasks: vec![],
        })))
        .unwrap();
        tx.send(SessionEvent::Exited { exit_code: Some(1) }).unwrap();

        assert!(matches!(next_frame(&mut out).await, ServerMsg::SessionTasks { .. }));
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(1));
        drop(tx);
        handle.await.unwrap();
        assert!(out.try_recv().is_err(), "no extra frames");
    }

    #[test]
    fn a_new_task_with_no_text_publishes_its_snapshot_and_no_empty_detail_frame() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);

        rt.on_event(&tx, &started("t1", json!({"task_type": "local_bash"})));

        let events = drain(&mut rx);
        assert_eq!(snapshots(&events).len(), 1);
        let details: Vec<_> = events.iter().filter(|e| matches!(e, SessionEvent::TaskDetail(_))).collect();
        assert!(details.is_empty(), "a detail frame with no text says nothing: {details:?}");
    }
}
