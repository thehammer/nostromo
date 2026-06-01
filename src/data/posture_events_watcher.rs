//! Tail-watcher for `~/.claude/budget-posture.events.jsonl`.
//!
//! On startup, seeks to the current end-of-file position so no historical
//! events are replayed into the UI.  On each file-change notification, reads
//! any bytes appended since the last known offset, splits on newlines, and
//! emits an `AppEvent::PostureThresholdCrossed` for each valid
//! `threshold_crossed` event.
//!
//! Partial (unterminated) lines are buffered across watch cycles — a line
//! that arrives mid-write is safely held and processed when the newline lands.
//!
//! Modelled on `rate_limits_watcher.rs`.

use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::{data::rate_limits::PostureThresholdEvent, event::AppEvent};

/// Spawn the background posture-events tail-watcher.
///
/// The watcher seeks to EOF on start (no history replay), then emits
/// `AppEvent::PostureThresholdCrossed` for each new event line.
pub fn spawn(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        if let Err(e) = run(tx).await {
            warn!("posture events watcher exited with error: {e:#}");
        }
    });
}

async fn run(tx: mpsc::UnboundedSender<AppEvent>) -> anyhow::Result<()> {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    let path = home.join(".claude").join("budget-posture.events.jsonl");

    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(16);

    use notify::{RecursiveMode, Watcher};

    let watch_dir = path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/tmp"))
        .to_path_buf();

    let target = path.clone();
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                if ev.paths.iter().any(|p| p == &target) {
                    let _ = notify_tx.blocking_send(());
                }
            }
            Err(e) => warn!("posture events notify error: {e}"),
        })?;

    // Only watch when the parent directory exists (skip error on fresh installs).
    if watch_dir.exists() {
        watcher.watch(&watch_dir, RecursiveMode::NonRecursive)?;
    }

    // Seek to EOF — do NOT replay history accumulated before this session.
    let mut offset: u64 = path
        .exists()
        .then(|| std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0))
        .unwrap_or(0);

    // Bytes from the last incomplete (unterminated) line, carried across cycles.
    let mut partial: Vec<u8> = Vec::new();

    debug!(
        path = %path.display(),
        offset,
        "posture events watcher started (tail from EOF)"
    );

    while notify_rx.recv().await.is_some() {
        let (new_offset, new_partial) = read_new_events(&path, offset, partial, &tx);
        offset = new_offset;
        partial = new_partial;
    }

    Ok(())
}

/// Read bytes appended to `path` since `offset`, emit events, return the new
/// offset and any unterminated trailing bytes (buffered for the next cycle).
fn read_new_events(
    path: &std::path::Path,
    offset: u64,
    mut partial: Vec<u8>,
    tx: &mpsc::UnboundedSender<AppEvent>,
) -> (u64, Vec<u8>) {
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return (offset, partial),
    };
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return (offset, partial);
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() || buf.is_empty() {
        return (offset, partial);
    }

    let new_offset = offset + buf.len() as u64;

    // Combine leftover partial bytes with the new chunk.
    partial.extend_from_slice(&buf);

    // Find the last newline — everything after it is the new partial.
    let last_nl = partial.iter().rposition(|&b| b == b'\n');
    let new_partial = match last_nl {
        Some(pos) => {
            let remainder = partial[pos + 1..].to_vec();
            partial.truncate(pos + 1); // keep through the \n
            remainder
        }
        None => {
            // No newline yet — entire buffer is partial; wait for more bytes.
            return (new_offset, partial);
        }
    };

    // Emit one event per complete line.
    let text = String::from_utf8_lossy(&partial);
    for line in text.split('\n') {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(ev) = PostureThresholdEvent::parse_line(trimmed) {
            if tx.send(AppEvent::PostureThresholdCrossed(ev)).is_err() {
                // Channel closed — app is shutting down.
                return (new_offset, new_partial);
            }
        }
    }

    (new_offset, new_partial)
}
