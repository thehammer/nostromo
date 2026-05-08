//! Agent activity pub/sub — tails `~/.claude/activity.jsonl` and broadcasts
//! structured `ActivityEvent` records to all subscribers.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;
use tracing::{debug, warn};

/// A single agent activity event parsed from `activity.jsonl`.
#[derive(Debug, Clone, serde::Deserialize)]
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

    /// Start tailing `path` in the background.  Creates parent dirs and an
    /// empty file if absent.  Returns immediately; the watcher runs on a
    /// spawned tokio task.
    pub fn start_tail(self: Arc<Self>, path: PathBuf) {
        tokio::spawn(async move {
            if let Err(e) = self.run_tailer(path).await {
                warn!("activity.jsonl tailer exited with error: {e:#}");
            }
        });
    }

    async fn run_tailer(self: Arc<Self>, path: PathBuf) -> anyhow::Result<()> {
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
            let meta = f.metadata()?;
            meta.len()
        };

        // Bridge notify's std-thread callback into a tokio mpsc.
        let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

        use notify::{RecursiveMode, Watcher};

        let path_for_watcher = path.clone();
        let mut watcher = notify::recommended_watcher(
            move |res: notify::Result<notify::Event>| {
                match res {
                    Ok(_) => {
                        let _ = notify_tx.blocking_send(());
                    }
                    Err(e) => {
                        warn!("notify watcher error: {e}");
                    }
                }
            },
        )?;

        watcher.watch(&path_for_watcher, RecursiveMode::NonRecursive)?;

        debug!(path = %path.display(), "activity.jsonl tailer started");

        // Process events as they arrive.
        while notify_rx.recv().await.is_some() {
            offset = self.drain_new_lines(&path, offset);
        }

        Ok(())
    }

    /// Read all new lines since `offset`, publish them, and return the new offset.
    fn drain_new_lines(&self, path: &PathBuf, mut offset: u64) -> u64 {
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
                Ok(0) => break, // EOF
                Ok(_) => {
                    let trimmed = line.trim_end();
                    if trimmed.is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<ActivityEvent>(trimmed) {
                        Ok(ev) => {
                            {
                                let mut recent = self.recent.lock().unwrap();
                                if recent.len() >= 64 {
                                    recent.pop_front();
                                }
                                recent.push_back(ev.clone());
                            }
                            let _ = self.tx.send(ev);
                        }
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

        // Update offset to current EOF position.
        reader.stream_position().unwrap_or(offset)
    }
}

impl Default for AgentBus {
    fn default() -> Self {
        Self::new()
    }
}
