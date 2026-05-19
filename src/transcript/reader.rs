//! Async file-tailing reader for Claude Code JSONL session logs.
//!
//! `TranscriptReader::spawn` starts a background task that:
//!
//! 1. Computes the log path via `path::jsonl_path`.
//! 2. Waits for the file to appear (using `notify`), then opens it.
//! 3. Reads complete lines, decoding each as a `Record`.
//! 4. Translates records → `TranscriptEntry` values and publishes a
//!    `TranscriptSnapshot` on a `watch` channel after each batch.
//! 5. Parks on EOF, then resumes on `notify::Event::Modify`.
//!
//! The task never panics; errors are logged and the loop retries.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{oneshot, watch};
use tracing::{trace, warn};

use super::{
    path::jsonl_path,
    record::{ContentBlock, Record, UserContent},
    snapshot::{TranscriptEntry, TranscriptSnapshot},
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Background JSONL tail reader.
///
/// Drop this struct to signal the background task to shut down (via the
/// internal oneshot).  The task also shuts down when the watch receiver is
/// dropped.
pub struct TranscriptReader {
    _shutdown_tx: oneshot::Sender<()>,
}

impl TranscriptReader {
    /// Spawn a background task that tails `(cwd, session_id)` and publishes
    /// snapshots.  Returns `(reader, rx)` — keep `reader` alive to keep the
    /// task running; read updates from `rx`.
    pub fn spawn(
        cwd: PathBuf,
        session_id: String,
    ) -> (Self, watch::Receiver<TranscriptSnapshot>) {
        let path = jsonl_path(&cwd, &session_id);
        let initial = TranscriptSnapshot {
            entries: Arc::new(Vec::new()),
            path: path.clone(),
            session_id: session_id.clone(),
        };
        let (tx, rx) = watch::channel(initial);
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

        tokio::spawn(run_reader(path, session_id, tx, shutdown_rx));

        (Self { _shutdown_tx: shutdown_tx }, rx)
    }
}

// ── Background task ───────────────────────────────────────────────────────────

async fn run_reader(
    path: PathBuf,
    session_id: String,
    tx: watch::Sender<TranscriptSnapshot>,
    mut shutdown: oneshot::Receiver<()>,
) {
    // Channel for notify → async boundary.
    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(32);

    // Install a file-system watcher on the *parent directory* (the file may
    // not exist yet).
    let mut watcher = install_watcher(&path, notify_tx.clone());
    if watcher.is_none() {
        warn!(
            ?path,
            "transcript: could not install fs watcher; falling back to 500ms poll"
        );
    }

    let mut entries: Vec<TranscriptEntry> = Vec::new();
    let mut byte_offset: u64 = 0;

    loop {
        // Check shutdown.
        if shutdown.try_recv().is_ok() {
            break;
        }

        // Wait for the file to exist.
        if !path.exists() {
            wait_for_signal(&mut notify_rx, &mut shutdown, Duration::from_millis(500)).await;
            if watcher.is_none() {
                watcher = install_watcher(&path, notify_tx.clone());
            }
            continue;
        }

        // Read new lines starting at byte_offset.
        match read_new_lines(&path, byte_offset).await {
            Ok((new_lines, new_offset)) => {
                let changed = !new_lines.is_empty();
                let mut turn_ended = false;

                for line in new_lines {
                    match serde_json::from_str::<Record>(&line) {
                        Ok(record) => {
                            if record_to_entries(&record, &mut entries) {
                                turn_ended = true;
                            }
                        }
                        Err(e) => {
                            trace!(?path, error = %e, "transcript: parse error, skipping line");
                        }
                    }
                }

                byte_offset = new_offset;

                if changed || turn_ended {
                    let snap = TranscriptSnapshot {
                        entries: Arc::new(entries.clone()),
                        path: path.clone(),
                        session_id: session_id.clone(),
                    };
                    // Ignore send error — watch channel is gone, time to exit.
                    if tx.send(snap).is_err() {
                        break;
                    }
                }
            }
            Err(e) => {
                warn!(?path, error = %e, "transcript: read error");
                // Reset offset on read error to recover from file truncation.
                byte_offset = 0;
            }
        }

        // Park until the file changes (or poll interval).
        wait_for_signal(&mut notify_rx, &mut shutdown, Duration::from_millis(500)).await;
    }
}

/// Read all complete lines from `path` starting at `byte_offset`.
/// Returns `(lines, new_byte_offset)`.
///
/// `pub(crate)` so that `context_usage` can reuse this primitive without
/// duplicating the file-tailing logic.
pub(crate) async fn read_new_lines(path: &PathBuf, byte_offset: u64) -> anyhow::Result<(Vec<String>, u64)> {
    let mut file = tokio::fs::File::open(path).await?;
    tokio::io::AsyncSeekExt::seek(&mut file, std::io::SeekFrom::Start(byte_offset)).await?;

    let mut reader = BufReader::new(file);
    let mut lines = Vec::new();
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break; // EOF
        }
        // Only keep lines that are terminated (not a partial write).
        if line.ends_with('\n') {
            lines.push(line.trim_end_matches('\n').trim_end_matches('\r').to_string());
        }
        // else: partial line, stop — we'll re-read it next time.
    }

    // Compute new offset: original + bytes consumed.
    let bytes_consumed: u64 = lines
        .iter()
        .map(|l| l.len() as u64 + 1 /* newline */)
        .sum();
    Ok((lines, byte_offset + bytes_consumed))
}

/// Translate one `Record` into `TranscriptEntry` values appended to `out`.
/// Returns `true` if a turn ended (assistant `stop_reason` non-null).
fn record_to_entries(record: &Record, out: &mut Vec<TranscriptEntry>) -> bool {
    match record {
        Record::User { message, .. } => {
            match &message.content {
                UserContent::Text(s) => {
                    if !s.is_empty() {
                        out.push(TranscriptEntry::UserMessage(s.clone()));
                    }
                }
                UserContent::Blocks(blocks) => {
                    // Concatenate text blocks into a single UserMessage entry.
                    let text = blocks
                        .iter()
                        .filter_map(|b| {
                            if let ContentBlock::Text { text } = b {
                                Some(text.as_str())
                            } else {
                                None
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    if !text.is_empty() {
                        out.push(TranscriptEntry::UserMessage(text));
                    }
                    // Also emit ToolResult entries — tool results travel in
                    // user messages as the response to assistant tool calls.
                    for block in blocks {
                        if let ContentBlock::ToolResult { tool_use_id, content } = block {
                            out.push(TranscriptEntry::ToolResult {
                                tool_use_id: tool_use_id.clone(),
                                content: content.as_display(),
                            });
                        }
                    }
                }
            }
            false
        }

        Record::Assistant { message, .. } => {
            for block in &message.content {
                match block {
                    ContentBlock::Text { text } => {
                        if !text.is_empty() {
                            out.push(TranscriptEntry::AssistantText(text.clone()));
                        }
                    }
                    ContentBlock::Thinking { thinking, .. } => {
                        if !thinking.is_empty() {
                            out.push(TranscriptEntry::Thinking(thinking.clone()));
                        }
                    }
                    ContentBlock::ToolUse { name, input, .. } => {
                        out.push(TranscriptEntry::ToolUse {
                            name: name.clone(),
                            input: input.clone(),
                        });
                    }
                    ContentBlock::ToolResult { tool_use_id, content } => {
                        out.push(TranscriptEntry::ToolResult {
                            tool_use_id: tool_use_id.clone(),
                            content: content.as_display(),
                        });
                    }
                    ContentBlock::Unknown => {}
                }
            }
            let turn_ended = message.stop_reason.is_some();
            if turn_ended {
                out.push(TranscriptEntry::TurnEnd);
            }
            turn_ended
        }

        Record::Other => false,
    }
}

// ── Notify watcher ────────────────────────────────────────────────────────────

pub(crate) type BoxedWatcher = Box<dyn notify::Watcher + Send>;

/// Install a filesystem watcher on the parent directory of `path`, firing
/// `notify_tx` on every modification event that touches `path`.
///
/// `pub(crate)` so that `context_usage` can share the same notify machinery
/// without duplicating the watcher setup.
pub(crate) fn install_watcher(path: &PathBuf, notify_tx: tokio::sync::mpsc::Sender<()>) -> Option<BoxedWatcher> {
    use notify::{RecursiveMode, Watcher};

    let target = path.clone();
    let watcher_result = notify::recommended_watcher(
        move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                if ev.paths.iter().any(|p| p == &target) {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => {
                warn!("transcript notify error: {e}");
            }
        },
    );

    match watcher_result {
        Ok(mut watcher) => {
            let watch_dir = path
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."));

            if let Err(e) = watcher.watch(&watch_dir, RecursiveMode::NonRecursive) {
                warn!(?path, "transcript: watcher watch() failed: {e}");
                return None;
            }
            Some(Box::new(watcher))
        }
        Err(e) => {
            warn!(?path, "transcript: could not create watcher: {e}");
            None
        }
    }
}

/// Wait for a notify signal, a shutdown signal, or a poll-interval timeout.
pub(crate) async fn wait_for_signal(
    notify_rx: &mut tokio::sync::mpsc::Receiver<()>,
    shutdown: &mut oneshot::Receiver<()>,
    timeout: Duration,
) {
    tokio::select! {
        _ = notify_rx.recv() => {}
        _ = &mut *shutdown => {}
        _ = tokio::time::sleep(timeout) => {}
    }
}
