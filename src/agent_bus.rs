//! Agent activity pub/sub — tails `~/.claude/activity.jsonl` and broadcasts
//! structured `ActivityEvent` records to all subscribers.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tracing::{debug, warn};

/// A single agent activity event parsed from `activity.jsonl`.
///
/// The first four fields are the original schema; every field added since
/// (the ambient-activity-path wedge) is `#[serde(default)]` so an old
/// 4-field line still deserializes, and `Option` fields skip serialization
/// when absent so events that don't carry them stay compact on the wire.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ActivityEvent {
    pub ts: chrono::DateTime<chrono::Utc>,
    pub agent: String,
    pub kind: String,
    pub summary: String,

    /// Focus tag this event is attributed to, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_tag: Option<String>,
    /// The `claude` `session_id` the event's process reported, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Subagent id, when this event originated from a subagent. `None` means
    /// the main-agent stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    /// Subagent type (e.g. `"cody"`), set when `agent_id` is set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
    /// The subagent's parent agent id, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_agent_id: Option<String>,
    /// Tool name, for `kind == "tool_use"` events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// Claude Code's `tool_use_id`, when the source hook payload carried one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    /// Working directory reported by the hook payload, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Per-stream monotonic sequence number, assigned by
    /// `activity::store::ActivityStore::ingest`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<u64>,
}

/// Global agent bus.  All views can subscribe to the receiver.
pub struct AgentBus {
    tx: broadcast::Sender<ActivityEvent>,
    recent: Arc<Mutex<VecDeque<ActivityEvent>>>,
}

impl AgentBus {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(256);
        Self {
            tx,
            recent: Arc::new(Mutex::new(VecDeque::with_capacity(64))),
        }
    }

    /// Subscribe to the live event stream.
    pub fn subscribe(&self) -> broadcast::Receiver<ActivityEvent> {
        self.tx.subscribe()
    }

    /// Snapshot of the most recent ≤64 events (newest last).
    pub fn recent_snapshot(&self) -> Vec<ActivityEvent> {
        self.recent.lock().unwrap().iter().cloned().collect()
    }

    /// Inject an event received from the daemon into the bus.
    ///
    /// Updates the recent-events ring buffer and broadcasts to all in-process
    /// subscribers, exactly as if the tailer had produced it.
    pub fn push_external(&self, event: ActivityEvent) {
        {
            let mut recent = self.recent.lock().unwrap();
            if recent.len() >= 64 {
                recent.pop_front();
            }
            recent.push_back(event.clone());
        }
        let _ = self.tx.send(event);
    }

    /// Start tailing `path` in the background.  Creates parent dirs and an
    /// empty file if absent.  Returns immediately; the watcher runs on a
    /// spawned tokio task.
    pub fn start_tail(self: Arc<Self>, path: PathBuf) {
        tokio::spawn(async move {
            let bus = Arc::clone(&self);
            if let Err(e) = tail_activity_jsonl(path, move |ev| bus.push_external(ev)).await {
                warn!("activity.jsonl tailer exited with error: {e:#}");
            }
        });
    }
}

impl Default for AgentBus {
    fn default() -> Self {
        Self::new()
    }
}

// ── free tailer function ──────────────────────────────────────────────────────

/// Tail `path` (the `activity.jsonl` file) and call `on_event` for each new
/// `ActivityEvent`.
///
/// Used by both the in-process `AgentBus::start_tail` and the `nostromd`
/// daemon.  Creates the parent directory and an empty file if they don't exist.
pub async fn tail_activity_jsonl<F>(path: PathBuf, mut on_event: F) -> anyhow::Result<()>
where
    F: FnMut(ActivityEvent) + Send + 'static,
{
    // Ensure parent dir + file exist.
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if !path.exists() {
        std::fs::write(&path, "")?;
    }

    // Seek to EOF so we only process new lines from this point forward.
    let mut offset: u64 = {
        let f = std::fs::File::open(&path)?;
        f.metadata()?.len()
    };

    // Bridge notify's std-thread callback into a tokio mpsc.
    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    // Watch the *parent directory*, not the file itself (D8): a
    // deleted+recreated `activity.jsonl` gets a different inode, and a
    // file-level watch would go silently dead forever the moment the
    // original inode disappears. Filter callbacks to events that plausibly
    // touch our target file — by filename rather than full-path equality,
    // since a platform watcher backend (e.g. macOS FSEvents) may report a
    // canonicalized/resolved path that no longer matches `path` verbatim (a
    // missed match here would silently resurrect the "dead tailer" bug D8
    // exists to fix, so this comparison deliberately errs permissive).
    let watch_target_name = path.file_name().map(|n| n.to_owned());
    let parent_dir = path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));

    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(event) => {
                let relevant = watch_target_name.is_none()
                    || event
                        .paths
                        .iter()
                        .any(|p| p.file_name() == watch_target_name.as_deref());
                if relevant {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => {
                warn!("notify watcher error: {e}");
            }
        })?;

    watcher.watch(&parent_dir, RecursiveMode::NonRecursive)?;
    debug!(path = %path.display(), "activity.jsonl tailer started");

    while notify_rx.recv().await.is_some() {
        offset = drain_new_lines(&path, offset, &mut on_event);
    }

    Ok(())
}

/// Read all new *complete* lines since `offset`, call `on_event` for each
/// valid one, and return the new file offset.
///
/// A torn/partial final line (no trailing `\n` yet — e.g. a writer's flush
/// landed mid-line) is never committed: the returned offset only ever
/// advances past bytes that ended in a newline, so the partial line is
/// re-read in full once the rest of it lands, rather than being silently
/// dropped (D8).
fn drain_new_lines<F: FnMut(ActivityEvent)>(
    path: &PathBuf,
    mut offset: u64,
    on_event: &mut F,
) -> u64 {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            warn!("could not open {}: {e}", path.display());
            return offset;
        }
    };

    // Detect file rotation / truncation.
    let file_len = file.metadata().map(|m| m.len()).unwrap_or(0);
    if file_len < offset {
        debug!("activity.jsonl appears rotated; resetting offset to 0");
        offset = 0;
    }

    let mut reader = BufReader::new(file);
    if let Err(e) = reader.seek(SeekFrom::Start(offset)) {
        warn!("seek error: {e}");
        return offset;
    }

    // Track the committed offset separately from what `read_line` consumes:
    // a torn final line must not move `committed_offset` past its start.
    let mut committed_offset = offset;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(n) => {
                if !line.ends_with('\n') {
                    // Torn line — the rest hasn't been written yet. Stop
                    // here without committing past it.
                    break;
                }
                committed_offset += n as u64;
                let trimmed = line.trim_end();
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<ActivityEvent>(trimmed) {
                    Ok(ev) => on_event(ev),
                    Err(e) => {
                        debug!("skipping malformed activity line: {e}");
                    }
                }
            }
            Err(e) => {
                warn!("read error in activity.jsonl tailer: {e}");
                break;
            }
        }
    }

    committed_offset
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn append(path: &std::path::Path, s: &str) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        write!(f, "{s}").unwrap();
    }

    // ── 1. schema growth is backward- and forward-compatible ─────────────────

    #[test]
    fn a_pre_change_four_field_line_deserializes_with_new_fields_none() {
        let raw = r#"{"ts":"2026-08-19T00:00:00Z","agent":"perri","kind":"tool_use","summary":"reading a file"}"#;
        let ev: ActivityEvent =
            serde_json::from_str(raw).expect("old 4-field shape must still parse");
        assert_eq!(ev.agent, "perri");
        assert_eq!(ev.kind, "tool_use");
        assert_eq!(ev.summary, "reading a file");
        assert!(ev.focus_tag.is_none());
        assert!(ev.session_id.is_none());
        assert!(ev.agent_id.is_none());
        assert!(ev.agent_type.is_none());
        assert!(ev.parent_agent_id.is_none());
        assert!(ev.tool_name.is_none());
        assert!(ev.tool_use_id.is_none());
        assert!(ev.cwd.is_none());
        assert!(ev.seq.is_none());
    }

    #[test]
    fn a_fully_populated_line_round_trips() {
        let ev = ActivityEvent {
            ts: chrono::Utc::now(),
            agent: "cody".into(),
            kind: "tool_use".into(),
            summary: "editing src/main.rs".into(),
            focus_tag: Some("cody-core-1234".into()),
            session_id: Some("sess-1".into()),
            agent_id: Some("agent-1".into()),
            agent_type: Some("cody".into()),
            parent_agent_id: Some("agent-0".into()),
            tool_name: Some("Edit".into()),
            tool_use_id: Some("tu-1".into()),
            cwd: Some("/tmp".into()),
            seq: Some(3),
        };
        let json = serde_json::to_string(&ev).unwrap();
        let back: ActivityEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back.focus_tag, ev.focus_tag);
        assert_eq!(back.session_id, ev.session_id);
        assert_eq!(back.agent_id, ev.agent_id);
        assert_eq!(back.agent_type, ev.agent_type);
        assert_eq!(back.parent_agent_id, ev.parent_agent_id);
        assert_eq!(back.tool_name, ev.tool_name);
        assert_eq!(back.tool_use_id, ev.tool_use_id);
        assert_eq!(back.cwd, ev.cwd);
        assert_eq!(back.seq, ev.seq);
    }

    // ── 2. drain_new_lines offset advancement ─────────────────────────────────

    #[test]
    fn a_torn_final_line_is_reread_not_dropped() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();

        let complete =
            r#"{"ts":"2026-08-19T00:00:00Z","agent":"a","kind":"tool_use","summary":"one"}"#;
        append(&path, &format!("{complete}\n"));

        let mut events = vec![];
        let offset = drain_new_lines(&path, 0, &mut |ev| events.push(ev));
        assert_eq!(events.len(), 1, "the complete line must be parsed");

        // Append a partial line with no trailing newline yet.
        let partial = r#"{"ts":"2026-08-19T00:00:01Z","agent":"a","kind":"tool_use","summary":"tw"#;
        append(&path, partial);

        let mut events2 = vec![];
        let offset2 = drain_new_lines(&path, offset, &mut |ev| events2.push(ev));
        assert!(
            events2.is_empty(),
            "a torn line must not be parsed as an event yet"
        );
        assert_eq!(
            offset2, offset,
            "the offset must not advance past the start of a partial line"
        );

        // The rest of the line (plus its newline) arrives.
        append(&path, "o\"}\n");

        let mut events3 = vec![];
        let _offset3 = drain_new_lines(&path, offset2, &mut |ev| events3.push(ev));
        assert_eq!(
            events3.len(),
            1,
            "the now-complete line must be parsed exactly once"
        );
        assert_eq!(events3[0].summary, "two");
    }

    // ── 3. truncation resets the offset instead of erroring forever ──────────

    #[test]
    fn file_truncation_resets_offset_to_zero_instead_of_erroring_forever() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();

        let long_line = r#"{"ts":"2026-08-19T00:00:00Z","agent":"a","kind":"tool_use","summary":"a longer line so the offset is well past zero"}"#;
        append(&path, &format!("{long_line}\n"));
        let offset = drain_new_lines(&path, 0, &mut |_| {});
        assert!(offset > 0);

        // Truncate, then write a fresh, complete line.
        std::fs::write(&path, "").unwrap();
        let short_line =
            r#"{"ts":"2026-08-19T00:00:01Z","agent":"b","kind":"tool_use","summary":"fresh"}"#;
        append(&path, &format!("{short_line}\n"));

        let mut events = vec![];
        let new_offset = drain_new_lines(&path, offset, &mut |ev| events.push(ev));
        assert_eq!(
            events.len(),
            1,
            "post-truncation content must be re-read from offset 0"
        );
        assert_eq!(events[0].agent, "b");
        assert!(new_offset > 0);
    }

    // ── 4. deleted + recreated file (different inode) ─────────────────────────

    /// Exercises the D8 directory-watch hardening above: `tail_activity_jsonl`
    /// watches the parent directory rather than the file itself, so a
    /// deleted+recreated file (a different inode) is still picked up instead
    /// of leaving the watch silently dead.
    #[tokio::test]
    async fn deleted_and_recreated_file_is_still_picked_up_by_the_tailer() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("activity.jsonl");

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ActivityEvent>();
        let watch_path = path.clone();
        tokio::spawn(async move {
            let _ = tail_activity_jsonl(watch_path, move |ev| {
                let _ = tx.send(ev);
            })
            .await;
        });

        // Give the tailer a moment to start watching, then delete + recreate
        // the file with a fresh inode and write a line to it.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        std::fs::remove_file(&path).unwrap();
        let line = r#"{"ts":"2026-08-19T00:00:00Z","agent":"a","kind":"tool_use","summary":"post-recreate"}"#;
        std::fs::write(&path, format!("{line}\n")).unwrap();

        let ev = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("timed out waiting for the tailer to notice the recreated file")
            .expect("channel closed");
        assert_eq!(ev.summary, "post-recreate");
    }
}
