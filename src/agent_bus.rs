//! Agent activity pub/sub — tails `~/.claude/activity.jsonl` and broadcasts
//! structured `ActivityEvent` records to all subscribers.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tracing::{debug, warn};

/// A single agent activity event parsed from `activity.jsonl`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ActivityEvent {
    pub ts: chrono::DateTime<chrono::Utc>,
    pub agent: String,
    pub kind: String,
    pub summary: String,
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

    let path_for_watcher = path.clone();
    let mut watcher = notify::recommended_watcher(
        move |res: notify::Result<notify::Event>| match res {
            Ok(_) => {
                let _ = notify_tx.blocking_send(());
            }
            Err(e) => {
                warn!("notify watcher error: {e}");
            }
        },
    )?;

    watcher.watch(&path_for_watcher, RecursiveMode::NonRecursive)?;
    debug!(path = %path.display(), "activity.jsonl tailer started");

    while notify_rx.recv().await.is_some() {
        offset = drain_new_lines(&path, offset, &mut on_event);
    }

    Ok(())
}

/// Read all new lines since `offset`, call `on_event` for each valid one, and
/// return the new file offset.
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

    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
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

    reader.stream_position().unwrap_or(offset)
}
