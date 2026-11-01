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

mod verbs;

pub(super) use verbs::{ensure_probe, read_output, stop_task};
pub use verbs::{OutputReply, StopReport};

use super::control::{control, says_unsupported, CONTROL_TIMEOUT};
use super::{lock_recover, SessionEvent, Shared};
use crate::ipc::protocol::{ServerMsg, TaskDetailMsg, TaskMeta, TasksSnapshot};
use crate::ipc::stream_json::SessionTranscript;
use crate::ipc::task_output::{
    current_uid, is_valid_task_id, last_nonempty_line, learnable_root, sanitize,
    OutputFileValidator, TAIL_MAX_BYTES,
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

/// Knobs of how a session reads and controls its tasks. The defaults are the
/// daemon's; integration tests turn them (a short wait, a temp output root, a
/// count of file opens).
#[derive(Clone, Default)]
pub struct TaskIoConfig {
    /// How long a task control request waits for the CLI.
    pub control_timeout: Option<Duration>,
    /// The only root output files may live under, instead of the CLI's
    /// `/private/tmp/claude-<uid>`.
    pub output_root: Option<PathBuf>,
    /// Counts every attempt to open an output file.
    pub open_counter: Option<Arc<AtomicUsize>>,
}

impl TaskIoConfig {
    fn validator(&self) -> OutputFileValidator {
        let validator = match &self.output_root {
            Some(root) => OutputFileValidator::new(root),
            None => OutputFileValidator::for_current_user(),
        };
        match &self.open_counter {
            Some(counter) => validator.with_open_counter(Arc::clone(counter)),
            None => validator,
        }
    }
}

/// After the CLI failed to answer `get_task_output`, how long before asking again.
const CLI_TAIL_BACKOFF_MS: u64 = 30_000;

/// Whether the CLI's own `get_task_output` is worth asking.
#[derive(Default)]
struct CliTail {
    /// The CLI answered "unsupported": never ask again this session.
    unsupported: bool,
    /// Do not ask before this time (a failed or timed-out request).
    retry_at_ms: u64,
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
    cli_tail: Mutex<CliTail>,
    /// How long a task control request waits for the CLI.
    control_timeout: Duration,
    /// Whether the CLI can stop tasks: `None` until learned.
    stop_supported: Mutex<Option<bool>>,
    /// The capability probe was sent (at most once per CLI process).
    probe_started: AtomicBool,
}

impl TaskRuntime {
    pub(super) fn new(
        transcript: Arc<Mutex<SessionTranscript>>,
        session_id: Option<String>,
        cwd: PathBuf,
        io: &TaskIoConfig,
    ) -> Arc<Self> {
        Self::build(
            transcript,
            session_id,
            cwd,
            io.validator(),
            io.control_timeout.unwrap_or(CONTROL_TIMEOUT),
        )
    }

    /// [`Self::new`] with the validator to use (tests inject a temp root).
    #[cfg(test)]
    pub(super) fn with_validator(
        transcript: Arc<Mutex<SessionTranscript>>,
        session_id: Option<String>,
        cwd: PathBuf,
        validator: OutputFileValidator,
    ) -> Arc<Self> {
        Self::build(transcript, session_id, cwd, validator, CONTROL_TIMEOUT)
    }

    fn build(
        transcript: Arc<Mutex<SessionTranscript>>,
        session_id: Option<String>,
        cwd: PathBuf,
        validator: OutputFileValidator,
        control_timeout: Duration,
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
            cli_tail: Mutex::new(CliTail::default()),
            control_timeout,
            stop_supported: Mutex::new(None),
            probe_started: AtomicBool::new(false),
        })
    }

    /// A background-task event from the CLI.
    pub(super) fn on_event(&self, tx: &broadcast::Sender<SessionEvent>, event: &TaskEvent) {
        if let TaskEventKind::Notification(n) = &event.kind {
            if let Some(path) = &n.output_file {
                self.learn_root(&n.task_id, path);
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
        move |id| {
            lock_recover(&self.transcript)
                .tool_name_of(id)
                .map(str::to_owned)
        }
    }

    fn snapshot_of(&self, tasks: Vec<TaskMeta>) -> TasksSnapshot {
        TasksSnapshot {
            session_id: self.session_id.clone(),
            daemon_epoch: daemon_epoch().to_owned(),
            stop_supported: *lock_recover(&self.stop_supported),
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

    /// The first output path the CLI reports for this session teaches the
    /// root its files live under. Only a path of the exact shape
    /// `<root>/<cwd>/<this session's id>/tasks/<task id>.output` counts, so a
    /// path that merely ends in `tasks/` cannot widen what the daemon reads.
    /// The root must also be this user's `claude-<uid>` folder directly under
    /// `/tmp` or `/private/tmp` (see [`learnable_root`]); anything else
    /// teaches nothing and leaves the lesson for a later path.
    fn learn_root(&self, task_id: &str, reported: &str) {
        let Some(session_id) = &self.session_id else {
            return;
        };
        let path = std::path::Path::new(reported);
        let shaped = path.file_name().and_then(|n| n.to_str())
            == Some(&format!("{task_id}.output"))
            && path
                .ancestors()
                .nth(2)
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                == Some(session_id.as_str());
        if !shaped {
            return;
        }
        let mut files = lock_recover(&self.files);
        if files.root_learned {
            return;
        }
        if let Some(root) = learnable_root(path, current_uid()) {
            files.validator.add_root(root);
            files.root_learned = true;
        }
    }

    // ── preview ─────────────────────────────────────────────────────────────

    /// May the poller ask the CLI for a task's output now?
    fn cli_tail_allowed(&self) -> bool {
        let tail = lock_recover(&self.cli_tail);
        !tail.unsupported && self.clock.now_ms() >= tail.retry_at_ms
    }

    fn note_cli_tail_answer(&self, answer: &Result<(), String>) {
        let mut tail = lock_recover(&self.cli_tail);
        match answer {
            Ok(()) => tail.retry_at_ms = 0,
            Err(reason) => {
                if says_unsupported(reason) {
                    tail.unsupported = true;
                } else {
                    tail.retry_at_ms = self.clock.now_ms() + CLI_TAIL_BACKOFF_MS;
                }
            }
        }
    }

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
        let mut files = lock_recover(&self.files);
        // The bookkeeping follows the registry: an evicted task is forgotten,
        // and a task that runs (again) is not finalized.
        let known: HashSet<&str> = targets.iter().map(|t| t.task_id.as_str()).collect();
        files.polled.retain(|id| known.contains(id.as_str()));
        files.finalized.retain(|id| known.contains(id.as_str()));
        for t in targets.iter().filter(|t| !t.terminal) {
            files.finalized.remove(&t.task_id);
        }
        targets
            .into_iter()
            .filter(|t| !t.housekeeping)
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
        let tail = self
            .first_readable(target, |validator, path, id| {
                validator.read_tail(path, id, TAIL_MAX_BYTES)
            })
            .await?;
        Some(tail.bytes)
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
    if !shared.tasks.cli_tail_allowed() {
        return None;
    }
    let reply = control(
        shared,
        serde_json::json!({ "subtype": "get_task_output", "task_id": target.task_id }),
    )
    .await;
    shared
        .tasks
        .note_cli_tail_answer(&reply.as_ref().map(|_| ()).map_err(|f| f.reason.clone()));
    let output = reply.ok()?.body.get("output")?.as_str()?.to_owned();
    let output = output.as_str();
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
                    SessionEvent::TurnOrigin { turn_id, origin } => ServerMsg::SessionTurnOrigin {
                        tag: tag.clone(),
                        turn_id,
                        origin,
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
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        event("task_started", body)
    }

    fn progress(id: &str, tokens: u64) -> TaskEvent {
        event(
            "task_progress",
            json!({"task_id": id, "usage": {"total_tokens": tokens}}),
        )
    }

    fn notified(id: &str, status: &str, extra: serde_json::Value) -> TaskEvent {
        let mut body = json!({"task_id": id, "status": status});
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        event("task_notification", body)
    }

    fn level(ids: &[&str]) -> TaskEvent {
        event(
            "background_tasks_changed",
            json!({"tasks": ids.iter().map(|id| json!({"task_id": id, "task_type": "local_bash", "description": "d"})).collect::<Vec<_>>()}),
        )
    }

    fn runtime() -> (
        Arc<TaskRuntime>,
        Arc<Mutex<SessionTranscript>>,
        tempfile::TempDir,
    ) {
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
            t.ingest_line(
                r#"{"type":"user","message":{"role":"user","content":"watch it"},"isReplay":true}"#,
            );
            t.ingest_line(r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_mon","name":"Monitor","input":{"command":"tail -f x"}}]}}"#);
        }
        let (tx, _rx) = broadcast::channel(16);

        rt.on_event(
            &tx,
            &started(
                "t1",
                json!({"task_type": "local_bash", "tool_use_id": "toolu_mon"}),
            ),
        );

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
            assert_eq!(
                (t.status, t.end_reason),
                (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded))
            );
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
        assert_eq!(
            snapshots(&drain(&mut rx)).len(),
            1,
            "only the first change went out"
        );
        let timer = tokio::spawn(drive_timer(
            Arc::clone(&rt),
            tx.clone(),
            Arc::clone(&exited),
        ));
        settle().await;

        tokio::time::advance(Duration::from_millis(249)).await;
        settle().await;
        assert!(
            snapshots(&drain(&mut rx)).is_empty(),
            "the window is still open"
        );

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
        rt.on_event(
            &tx,
            &started(
                "t1",
                json!({"task_type": "local_bash", "is_backgrounded": true}),
            ),
        );
        rt.on_event(&tx, &level(&["t1"]));
        rt.on_event(&tx, &level(&[]));
        drain(&mut rx);
        let timer = tokio::spawn(drive_timer(
            Arc::clone(&rt),
            tx.clone(),
            Arc::clone(&exited),
        ));
        settle().await;

        tokio::time::advance(Duration::from_millis(2_999)).await;
        settle().await;
        assert!(
            snapshots(&drain(&mut rx)).is_empty(),
            "still inside the grace"
        );
        assert_eq!(rt.current().0.tasks[0].status, TaskStatus::Running);

        tokio::time::advance(Duration::from_millis(1)).await;
        settle().await;
        let published = snapshots(&drain(&mut rx));
        assert_eq!(
            published.len(),
            1,
            "the vanish is published, not just recorded"
        );
        let t = &published[0].tasks[0];
        assert_eq!(
            (t.status, t.end_reason),
            (TaskStatus::Stopped, Some(TaskEndReason::Vanished))
        );

        exited.store(true, Ordering::SeqCst);
        rt.set_clients(0);
        timer.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_that_ends_for_real_inside_the_grace_is_never_published_as_vanished() {
        let (rt, _t, _dir) = runtime();
        let (tx, mut rx) = broadcast::channel(16);
        let exited = Arc::new(AtomicBool::new(false));
        rt.on_event(
            &tx,
            &started(
                "t1",
                json!({"task_type": "local_bash", "is_backgrounded": true}),
            ),
        );
        rt.on_event(&tx, &level(&["t1"]));
        rt.on_event(&tx, &level(&[]));
        let timer = tokio::spawn(drive_timer(
            Arc::clone(&rt),
            tx.clone(),
            Arc::clone(&exited),
        ));
        settle().await;
        tokio::time::advance(Duration::from_millis(2_000)).await;
        rt.on_event(&tx, &notified("t1", "completed", json!({})));

        tokio::time::advance(Duration::from_millis(5_000)).await;
        settle().await;

        let all = snapshots(&drain(&mut rx));
        assert!(
            all.iter()
                .flat_map(|s| s.tasks.iter())
                .all(|t| t.end_reason != Some(TaskEndReason::Vanished)),
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
        let timer = tokio::spawn(drive_timer(
            Arc::clone(&rt),
            tx.clone(),
            Arc::clone(&exited),
        ));
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
        let handle = tokio::spawn(forward_session_events(
            rx,
            move |m| out_tx.send(m).is_ok(),
            "cody-1".into(),
            rt,
        ));
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
        tx.send(SessionEvent::Exited { exit_code: Some(3) })
            .unwrap();
        tx.send(SessionEvent::PermanentlyDown {
            reason: crate::ipc::session_manager::StopReason::User,
        })
        .unwrap();

        assert!(
            matches!(next_frame(&mut out).await, ServerMsg::SessionState { tag, state: SessionState::MidTurn } if tag == "cody-1")
        );
        match next_frame(&mut out).await {
            ServerMsg::SessionTasks {
                tag,
                session_id,
                daemon_epoch,
                stop_supported,
                tasks,
            } => {
                assert_eq!(tag, "cody-1");
                assert_eq!(session_id.as_deref(), Some("sess-1"));
                assert_eq!(daemon_epoch, "epoch-1");
                assert_eq!(stop_supported, Some(true));
                assert!(tasks.is_empty());
            }
            other => panic!("{other:?}"),
        }
        match next_frame(&mut out).await {
            ServerMsg::SessionTaskDetail {
                tag,
                task_id,
                preview,
                progress_summary,
                completion_summary,
                prompt,
            } => {
                assert_eq!(
                    (tag.as_str(), task_id.as_str(), preview.as_deref()),
                    ("cody-1", "t1", Some("line"))
                );
                assert_eq!(
                    (progress_summary, completion_summary, prompt),
                    (None, None, None)
                );
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(3));
        assert!(matches!(
            next_frame(&mut out).await,
            ServerMsg::SessionDown { .. }
        ));
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
        rt.on_event(
            &tx,
            &started(
                "agt",
                json!({"task_type": "local_agent", "prompt": "Read the config"}),
            ),
        );
        rt.on_event(
            &tx,
            &notified("agt", "completed", json!({"summary": "All done"})),
        );
        for code in 10..13 {
            tx.send(SessionEvent::Exited {
                exit_code: Some(code),
            })
            .unwrap();
        }
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(
            rx,
            move |m| out_tx.send(m).is_ok(),
            "cody-1".into(),
            Arc::clone(&rt),
        ));

        // First: the current snapshot, which has the final state.
        let ServerMsg::SessionTasks {
            tag,
            session_id,
            tasks,
            ..
        } = next_frame(&mut out).await
        else {
            panic!("the first frame after a lag must be the current task list")
        };
        assert_eq!(
            (tag.as_str(), session_id.as_deref()),
            ("cody-1", Some("sess-1"))
        );
        assert_eq!(tasks.len(), 1);
        assert_eq!(
            tasks[0].status,
            TaskStatus::Completed,
            "the state the dropped events described"
        );
        // Then: its details.
        let ServerMsg::SessionTaskDetail {
            task_id,
            prompt,
            completion_summary,
            ..
        } = next_frame(&mut out).await
        else {
            panic!("the details follow the snapshot")
        };
        assert_eq!(task_id, "agt");
        assert_eq!(prompt.as_deref(), Some("Read the config"));
        assert_eq!(completion_summary.as_deref(), Some("All done"));
        // Only then: what was still in the channel, and what comes later.
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(11));
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(12));
        tx.send(SessionEvent::Exited {
            exit_code: Some(13),
        })
        .unwrap();
        assert_eq!(exit_code_of(&next_frame(&mut out).await), Some(13));
        drop(tx);
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn a_lag_with_no_tasks_still_sends_the_empty_list_so_the_client_converges() {
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(2);
        for code in 0..5 {
            tx.send(SessionEvent::Exited {
                exit_code: Some(code),
            })
            .unwrap();
        }
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let handle = tokio::spawn(forward_session_events(
            rx,
            move |m| out_tx.send(m).is_ok(),
            "t".into(),
            rt,
        ));

        let ServerMsg::SessionTasks { tasks, .. } = next_frame(&mut out).await else {
            panic!("first frame")
        };
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
        let handle = tokio::spawn(forward_session_events(
            rx,
            move |m| out_tx.send(m).is_ok(),
            "t".into(),
            rt,
        ));
        tx.send(SessionEvent::Tasks(Arc::new(TasksSnapshot {
            session_id: None,
            daemon_epoch: "e".into(),
            stop_supported: None,
            tasks: vec![],
        })))
        .unwrap();
        tx.send(SessionEvent::Exited { exit_code: Some(1) })
            .unwrap();

        assert!(matches!(
            next_frame(&mut out).await,
            ServerMsg::SessionTasks { .. }
        ));
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
        let details: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, SessionEvent::TaskDetail(_)))
            .collect();
        assert!(
            details.is_empty(),
            "a detail frame with no text says nothing: {details:?}"
        );
    }

    // ── which output paths teach the output root ─────────────────────────────

    fn roots_of(rt: &TaskRuntime) -> Vec<PathBuf> {
        lock_recover(&rt.files).validator.roots().to_vec()
    }

    fn report_output_file(rt: &TaskRuntime, task_id: &str, path: &str) {
        let (tx, _rx) = broadcast::channel(16);
        rt.on_event(
            &tx,
            &notified(task_id, "completed", json!({"output_file": path})),
        );
    }

    #[test]
    fn a_reported_output_path_that_is_not_this_sessions_own_task_file_never_widens_the_readable_roots(
    ) {
        // (task id, reported path): each merely resembles `<root>/<cwd>/<session>/tasks/<task>.output`.
        let cases = [
            ("t1", "/elsewhere/-work-repo/sess-1/tasks/other.output"), // not this task's file name
            ("t1", "/elsewhere/-work-repo/sess-1/tasks/t1.output.bak"), // not exactly `<task>.output`
            ("t1", "/elsewhere/-work-repo/other-session/tasks/t1.output"), // another session's folder
            ("t1", "/home/alice/work/tasks/t1.output"), // ends in tasks/<id>.output under a parent of home
            ("t1", "/Users/alice/tasks/t1.output"),
            ("t1", "/tasks/t1.output"),
            ("t1", "tasks/t1.output"), // relative
            ("t1", "/elsewhere/-work-repo/sess-1/notasks/t1.output"), // not a `tasks` folder
            ("t1", "/elsewhere/sess-1/other/tasks/t1.output"), // the session id is at the wrong level
        ];
        for (task_id, path) in cases {
            let (rt, _t, dir) = runtime();

            report_output_file(&rt, task_id, path);

            assert_eq!(
                roots_of(&rt),
                vec![dir.path().to_path_buf()],
                "{path} must not teach a root"
            );
        }
    }

    #[test]
    fn without_a_session_id_no_reported_path_teaches_a_root() {
        let dir = tempfile::tempdir().unwrap();
        let rt = TaskRuntime::with_validator(
            Arc::new(Mutex::new(SessionTranscript::new())),
            None,
            PathBuf::from("/work/repo"),
            OutputFileValidator::new(dir.path()),
        );

        report_output_file(&rt, "t1", "/elsewhere/-work-repo/sess-1/tasks/t1.output");

        assert_eq!(roots_of(&rt), vec![dir.path().to_path_buf()]);
    }

    #[test]
    fn the_first_path_of_the_exact_shape_teaches_its_root_and_later_ones_do_not() {
        let (rt, _t, dir) = runtime();
        let uid = crate::ipc::task_output::current_uid();
        // Paths of the wrong shape first: they must not use up the one lesson.
        report_output_file(&rt, "t1", "/decoy/-work-repo/other-session/tasks/t1.output");
        report_output_file(&rt, "t1", "/decoy/-work-repo/sess-1/tasks/other.output");
        assert_eq!(roots_of(&rt), vec![dir.path().to_path_buf()]);

        let real_root = PathBuf::from(format!("/tmp/claude-{uid}"));
        report_output_file(
            &rt,
            "t1",
            &format!("/tmp/claude-{uid}/-work-repo/sess-1/tasks/t1.output"),
        );
        assert_eq!(
            roots_of(&rt),
            vec![dir.path().to_path_buf(), real_root.clone()]
        );

        report_output_file(
            &rt,
            "t2",
            &format!("/private/tmp/claude-{uid}/-work-repo/sess-1/tasks/t2.output"),
        );
        assert_eq!(
            roots_of(&rt),
            vec![dir.path().to_path_buf(), real_root],
            "only the first root is learned"
        );
    }

    #[test]
    fn a_path_outside_the_cli_tmp_root_teaches_nothing_and_does_not_use_up_the_lesson() {
        let (rt, _t, dir) = runtime();
        let uid = crate::ipc::task_output::current_uid();

        // Right shape for this session and task, wrong place: a document
        // folder, a tmp root of someone else, a path that climbs out.
        report_output_file(
            &rt,
            "t1",
            "/Users/h/Documents/-work-repo/sess-1/tasks/t1.output",
        );
        report_output_file(
            &rt,
            "t1",
            &format!("/tmp/claude-{}/-work-repo/sess-1/tasks/t1.output", uid + 1),
        );
        report_output_file(
            &rt,
            "t1",
            &format!("/var/folders/ab/T/claude-{uid}/-work-repo/sess-1/tasks/t1.output"),
        );
        report_output_file(
            &rt,
            "t1",
            &format!("/tmp/claude-{uid}/../../Users/h/-work-repo/sess-1/tasks/t1.output"),
        );
        assert_eq!(
            roots_of(&rt),
            vec![dir.path().to_path_buf()],
            "nothing taught"
        );

        report_output_file(
            &rt,
            "t1",
            &format!("/tmp/claude-{uid}/-work-repo/sess-1/tasks/t1.output"),
        );

        assert_eq!(
            roots_of(&rt),
            vec![
                dir.path().to_path_buf(),
                PathBuf::from(format!("/tmp/claude-{uid}"))
            ],
            "a later real-shaped path still teaches"
        );
    }

    // ── what the poller is asked to read ─────────────────────────────────────

    #[test]
    fn housekeeping_tasks_are_left_out_of_the_poll_plan_running_or_ended() {
        let (rt, _t, _dir) = runtime();
        let (tx, _rx) = broadcast::channel(64);
        rt.on_event(&tx, &started("live", json!({"task_type": "local_bash"})));
        rt.on_event(
            &tx,
            &started(
                "ambient",
                json!({"task_type": "local_bash", "ambient": true}),
            ),
        );
        rt.on_event(
            &tx,
            &started(
                "skipped",
                json!({"task_type": "monitor_mcp", "skip_transcript": true}),
            ),
        );
        rt.on_event(
            &tx,
            &started(
                "ambient-ended",
                json!({"task_type": "local_bash", "ambient": true}),
            ),
        );
        rt.on_event(&tx, &notified("ambient-ended", "completed", json!({})));
        rt.on_event(
            &tx,
            &started("live-ended", json!({"task_type": "local_bash"})),
        );
        rt.on_event(&tx, &notified("live-ended", "completed", json!({})));
        rt.on_event(
            &tx,
            &started("flagged-late", json!({"task_type": "local_bash"})),
        );
        rt.on_event(
            &tx,
            &notified(
                "flagged-late",
                "completed",
                json!({"skip_transcript": true}),
            ),
        );

        let plan: Vec<String> = rt.poll_plan().into_iter().map(|t| t.task_id).collect();

        assert_eq!(plan, ["live", "live-ended"]);
    }

    #[test]
    fn a_session_with_only_housekeeping_tasks_needs_no_poller_however_many_clients_are_attached() {
        let (rt, _t, _dir) = runtime();
        let (tx, _rx) = broadcast::channel(16);
        rt.set_clients(2);
        rt.on_event(
            &tx,
            &started(
                "ambient",
                json!({"task_type": "monitor_ws", "ambient": true}),
            ),
        );
        assert!(!rt.poll_wanted());

        rt.on_event(&tx, &started("live", json!({"task_type": "local_bash"})));
        assert!(rt.poll_wanted());
    }

    // ── asking the CLI for a task's output backs off ─────────────────────────

    #[tokio::test(start_paused = true)]
    async fn after_a_failed_answer_the_cli_is_not_asked_again_for_thirty_seconds() {
        let (rt, _t, _dir) = runtime();
        assert!(
            rt.cli_tail_allowed(),
            "a CLI nobody has asked yet may be asked"
        );

        rt.note_cli_tail_answer(&Err("No task found with ID".into()));

        assert!(!rt.cli_tail_allowed());
        tokio::time::advance(Duration::from_millis(29_999)).await;
        assert!(!rt.cli_tail_allowed(), "still inside the backoff");
        tokio::time::advance(Duration::from_millis(1)).await;
        assert!(
            rt.cli_tail_allowed(),
            "thirty seconds on, the CLI may be asked again"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_failure_after_the_backoff_starts_a_new_backoff() {
        let (rt, _t, _dir) = runtime();
        rt.note_cli_tail_answer(&Err("the session did not answer within 10 s".into()));
        tokio::time::advance(Duration::from_secs(30)).await;
        assert!(rt.cli_tail_allowed());

        rt.note_cli_tail_answer(&Err("the session did not answer within 10 s".into()));

        assert!(!rt.cli_tail_allowed());
        tokio::time::advance(Duration::from_millis(29_999)).await;
        assert!(!rt.cli_tail_allowed());
        tokio::time::advance(Duration::from_millis(1)).await;
        assert!(rt.cli_tail_allowed());
    }

    #[tokio::test(start_paused = true)]
    async fn an_answer_from_the_cli_ends_the_backoff() {
        let (rt, _t, _dir) = runtime();
        rt.note_cli_tail_answer(&Err("No task found with ID".into()));
        assert!(!rt.cli_tail_allowed());

        rt.note_cli_tail_answer(&Ok(()));

        assert!(
            rt.cli_tail_allowed(),
            "no need to wait out the rest of the backoff"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_cli_that_does_not_support_get_task_output_is_never_asked_again() {
        for text in [
            "Unsupported control request subtype",
            "UNSUPPORTED",
            "get_task_output is not supported by this CLI",
            "Unknown control request subtype: get_task_output",
            "unknown subtype",
        ] {
            let (rt, _t, _dir) = runtime();

            rt.note_cli_tail_answer(&Err(text.into()));

            assert!(!rt.cli_tail_allowed(), "{text}");
            tokio::time::advance(Duration::from_secs(24 * 3600)).await;
            assert!(
                !rt.cli_tail_allowed(),
                "{text}: a day later the CLI is still not asked"
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn other_failures_only_back_off_and_are_not_taken_for_lack_of_support() {
        for text in [
            "No task found with ID",
            "unknown task",
            "the session did not answer within 10 s",
            "the session exited",
            "the session refused the change",
        ] {
            let (rt, _t, _dir) = runtime();

            rt.note_cli_tail_answer(&Err(text.into()));
            assert!(!rt.cli_tail_allowed(), "{text}");
            tokio::time::advance(Duration::from_secs(30)).await;

            assert!(
                rt.cli_tail_allowed(),
                "{text}: the CLI may be asked again after the backoff"
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_success_does_not_undo_an_unsupported_verdict() {
        let (rt, _t, _dir) = runtime();
        rt.note_cli_tail_answer(&Err("Unsupported control request subtype".into()));

        rt.note_cli_tail_answer(&Ok(()));

        assert!(!rt.cli_tail_allowed());
    }

    // ── the lag resend, as a network peer receives it ────────────────────────

    /// What a peer of `trust` is sent when its forwarder lagged over a task's whole story (whose
    /// texts are `SECRET-OUTPUT-` sentinels). The frames go through the same `outbound` filter the
    /// server applies to every targeted frame.
    async fn frames_after_a_lag(
        trust: crate::ipc::peer::PeerTrust,
        tag: &str,
        sensitive: bool,
    ) -> Vec<ServerMsg> {
        use crate::ipc::peer::{outbound, SensitiveTags};
        let (rt, _t, _dir) = runtime();
        let (tx, rx) = broadcast::channel::<SessionEvent>(2);
        rt.on_event(
            &tx,
            &started(
                "agt",
                json!({"task_type": "local_agent", "prompt": "SECRET-OUTPUT-PROMPT"}),
            ),
        );
        rt.on_event(
            &tx,
            &notified("agt", "completed", json!({"summary": "SECRET-OUTPUT-DONE"})),
        );
        for code in 10..13 {
            tx.send(SessionEvent::Exited {
                exit_code: Some(code),
            })
            .unwrap();
        }
        let tags = SensitiveTags::in_memory();
        if sensitive {
            tags.mark_tag(tag);
        }
        let (out_tx, mut out) = mpsc::unbounded_channel();
        let peer = move |msg: ServerMsg| match outbound(trust, msg, &tags) {
            Some(msg) => out_tx.send(msg).is_ok(),
            None => true,
        };
        let handle = tokio::spawn(forward_session_events(rx, peer, tag.into(), rt));
        drop(tx);
        handle.await.unwrap();
        let mut frames = vec![];
        while let Ok(frame) = out.try_recv() {
            frames.push(frame);
        }
        frames
    }

    #[tokio::test]
    async fn after_a_lag_a_local_peer_is_resent_the_task_list_and_its_texts() {
        use crate::ipc::peer::PeerTrust;
        for sensitive in [false, true] {
            let frames = frames_after_a_lag(PeerTrust::LocalOther, "cody-1", sensitive).await;
            let wire = serde_json::to_string(&frames).unwrap();
            assert!(
                frames
                    .iter()
                    .any(|f| matches!(f, ServerMsg::SessionTasks { .. })),
                "{wire}"
            );
            assert!(
                wire.contains("SECRET-OUTPUT-PROMPT") && wire.contains("SECRET-OUTPUT-DONE"),
                "the control: {wire}"
            );
        }
    }

    #[tokio::test]
    async fn after_a_lag_a_network_peer_is_resent_the_task_list_of_an_ordinary_tag_but_never_a_detail(
    ) {
        use crate::ipc::peer::PeerTrust;
        let frames = frames_after_a_lag(PeerTrust::Tcp, "cody-1", false).await;
        let wire = serde_json::to_string(&frames).unwrap();

        let lists: Vec<_> = frames
            .iter()
            .filter(|f| matches!(f, ServerMsg::SessionTasks { .. }))
            .collect();
        assert_eq!(lists.len(), 1, "{wire}");
        assert!(
            !frames
                .iter()
                .any(|f| matches!(f, ServerMsg::SessionTaskDetail { .. })),
            "{wire}"
        );
        assert!(!wire.contains("SECRET-OUTPUT"), "{wire}");
    }

    #[tokio::test]
    async fn after_a_lag_a_network_peer_is_resent_nothing_of_a_sensitive_tag() {
        use crate::ipc::peer::PeerTrust;
        let frames = frames_after_a_lag(PeerTrust::Tcp, "cody-1", true).await;

        assert!(
            frames.is_empty(),
            "{}",
            serde_json::to_string(&frames).unwrap()
        );
    }
}
