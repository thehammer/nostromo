//! Background reader that tracks context-window usage for a Claude REPL session.
//!
//! Tails the active session JSONL (same file as `TranscriptReader`) and
//! publishes the latest `ContextUsage` on a `watch::Receiver` after every
//! assistant turn that carries a `usage` block.
//!
//! Reuses the file-tailing primitives from `crate::transcript::reader` —
//! `read_new_lines`, `install_watcher`, and `wait_for_signal` — so there is
//! no duplicated notify/offset logic.

use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::{oneshot, watch};
use tracing::{trace, warn};

use crate::transcript::{
    path::jsonl_path,
    reader::{install_watcher, read_new_lines, wait_for_signal},
    record::Record,
};

// ── Context window constant ───────────────────────────────────────────────────

/// Assumed context-window size (tokens) for Sonnet models.
///
/// FIXME(multi-model): v1 hard-codes the Sonnet 200K window.
/// When multiple models need to be handled, look up the window size
/// from `ContextUsage::model` via a model registry (e.g. `models.toml`).
pub const SONNET_CONTEXT_WINDOW_TOKENS: u64 = 200_000;

// ── Public types ──────────────────────────────────────────────────────────────

/// The latest context-usage snapshot for a Claude REPL session.
#[derive(Debug, Clone)]
pub struct ContextUsage {
    /// Cumulative tokens that consume context window space in this turn.
    ///
    /// Computed as `input_tokens + cache_creation_input_tokens +
    /// cache_read_input_tokens`.  Output tokens are not counted because
    /// they do not occupy the context window.
    pub cumulative_tokens: u64,
    /// Model string from the session record, if present.
    pub model: Option<String>,
    /// Context usage as a percentage of the assumed window size (0.0–100.0).
    ///
    /// FIXME(multi-model): denominator is hard-coded to
    /// `SONNET_CONTEXT_WINDOW_TOKENS`.
    pub pct: f32,
}

/// Background task handle for context-usage tailing.
///
/// Drop this to shut down the background task.
pub struct ContextUsageReader {
    _shutdown_tx: oneshot::Sender<()>,
}

impl ContextUsageReader {
    /// Spawn a background task that tails `(cwd, session_id)` and publishes
    /// `Option<ContextUsage>` snapshots.
    ///
    /// Returns `(reader, rx)`.  Keep `reader` alive to keep the task running;
    /// drop it to request shutdown.  The `rx` always holds the latest value.
    ///
    /// If called outside a Tokio runtime (e.g. in unit tests) the background
    /// task is silently skipped and the receiver will stay `None` indefinitely.
    pub fn spawn(
        cwd: PathBuf,
        session_id: String,
    ) -> (Self, watch::Receiver<Option<ContextUsage>>) {
        let (tx, rx) = watch::channel(None);
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

        // Only start the background task when a Tokio runtime is available.
        // Outside a runtime (e.g. unit tests) the receiver stays `None`.
        if tokio::runtime::Handle::try_current().is_ok() {
            let path = jsonl_path(&cwd, &session_id);
            tokio::spawn(run_context_reader(path, tx, shutdown_rx));
        }

        (Self { _shutdown_tx: shutdown_tx }, rx)
    }
}

// ── Background task ───────────────────────────────────────────────────────────

async fn run_context_reader(
    path: PathBuf,
    tx: watch::Sender<Option<ContextUsage>>,
    mut shutdown: oneshot::Receiver<()>,
) {
    let (notify_tx, mut notify_rx) = tokio::sync::mpsc::channel::<()>(32);

    let mut watcher = install_watcher(&path, notify_tx.clone());
    if watcher.is_none() {
        warn!(
            ?path,
            "context_usage: could not install fs watcher; falling back to 500ms poll"
        );
    }

    let mut byte_offset: u64 = 0;

    loop {
        if shutdown.try_recv().is_ok() {
            break;
        }

        if !path.exists() {
            wait_for_signal(&mut notify_rx, &mut shutdown, Duration::from_millis(500)).await;
            if watcher.is_none() {
                watcher = install_watcher(&path, notify_tx.clone());
            }
            continue;
        }

        match read_new_lines(&path, byte_offset).await {
            Ok((new_lines, new_offset)) => {
                byte_offset = new_offset;

                for line in new_lines {
                    match serde_json::from_str::<Record>(&line) {
                        Ok(Record::Assistant { message, .. }) => {
                            if let Some(usage) = &message.usage {
                                // FIXME(multi-model): denominator is hard-coded to
                                // SONNET_CONTEXT_WINDOW_TOKENS; use model lookup when
                                // multi-model support is added.
                                let cumulative_tokens = usage.input_tokens
                                    + usage.cache_creation_input_tokens
                                    + usage.cache_read_input_tokens;
                                let pct = cumulative_tokens as f32
                                    / SONNET_CONTEXT_WINDOW_TOKENS as f32
                                    * 100.0;
                                let snapshot = ContextUsage {
                                    cumulative_tokens,
                                    model: None,
                                    pct,
                                };
                                if tx.send(Some(snapshot)).is_err() {
                                    return; // receiver dropped
                                }
                            }
                        }
                        Ok(_) => {
                            // User records, Other — skip.
                        }
                        Err(e) => {
                            trace!(?path, error = %e, "context_usage: parse error, skipping line");
                        }
                    }
                }
            }
            Err(e) => {
                warn!(?path, error = %e, "context_usage: read error");
                byte_offset = 0;
            }
        }

        wait_for_signal(&mut notify_rx, &mut shutdown, Duration::from_millis(500)).await;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    // Helper: write lines to a temp file and return its path.
    fn write_jsonl(lines: &[&str]) -> NamedTempFile {
        let mut f = NamedTempFile::new().unwrap();
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
        f.flush().unwrap();
        f
    }

    #[test]
    fn pct_calculation() {
        // input=100k + cache_read=50k → cumulative=150k → pct=75%
        let usage = crate::transcript::record::Usage {
            input_tokens: 100_000,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 50_000,
            output_tokens: 10_000,
        };
        let cumulative = usage.input_tokens
            + usage.cache_creation_input_tokens
            + usage.cache_read_input_tokens;
        let pct = cumulative as f32 / SONNET_CONTEXT_WINDOW_TOKENS as f32 * 100.0;
        assert!(
            (pct - 75.0).abs() < 0.001,
            "expected 75.0%, got {pct}"
        );
    }

    #[tokio::test]
    async fn latest_assistant_wins() {
        // Two assistant records; published value should reflect the LAST one.
        let record1 = r#"{"type":"assistant","uuid":"a","timestamp":"t","message":{"role":"assistant","content":[],"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}"#;
        let record2 = r#"{"type":"assistant","uuid":"b","timestamp":"t","message":{"role":"assistant","content":[],"usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}"#;

        let tmpfile = write_jsonl(&[record1, record2]);
        let path = tmpfile.path().to_path_buf();

        // Read lines directly (unit-test the parsing logic).
        let (lines, _) = read_new_lines(&path, 0).await.unwrap();
        let mut last_pct: Option<f32> = None;
        for line in &lines {
            if let Ok(Record::Assistant { message, .. }) = serde_json::from_str(line) {
                if let Some(usage) = &message.usage {
                    let cum = usage.input_tokens
                        + usage.cache_creation_input_tokens
                        + usage.cache_read_input_tokens;
                    last_pct = Some(cum as f32 / SONNET_CONTEXT_WINDOW_TOKENS as f32 * 100.0);
                }
            }
        }
        let pct = last_pct.expect("should have parsed a usage");
        assert!(
            (pct - 50.0).abs() < 0.001,
            "expected 50.0% (100k/200k), got {pct}"
        );
    }

    #[tokio::test]
    async fn missing_usage_yields_none() {
        // Assistant record with no usage field → no update published.
        let record = r#"{"type":"assistant","uuid":"a","timestamp":"t","message":{"role":"assistant","content":[]}}"#;
        let tmpfile = write_jsonl(&[record]);
        let path = tmpfile.path().to_path_buf();

        let (lines, _) = read_new_lines(&path, 0).await.unwrap();
        let mut found_usage = false;
        for line in &lines {
            if let Ok(Record::Assistant { message, .. }) = serde_json::from_str(line) {
                if message.usage.is_some() {
                    found_usage = true;
                }
            }
        }
        assert!(!found_usage, "should find no usage when field is absent");
    }

    #[tokio::test]
    async fn non_assistant_records_ignored() {
        // User record + Other record — neither should contribute usage.
        let user_record = r#"{"type":"user","uuid":"a","timestamp":"t","message":{"role":"user","content":"hello"}}"#;
        let other_record = r#"{"type":"agent-setting","key":"foo","value":"bar"}"#;
        let tmpfile = write_jsonl(&[user_record, other_record]);
        let path = tmpfile.path().to_path_buf();

        let (lines, _) = read_new_lines(&path, 0).await.unwrap();
        let mut usage_count = 0usize;
        for line in &lines {
            if let Ok(Record::Assistant { message, .. }) = serde_json::from_str(line) {
                if message.usage.is_some() {
                    usage_count += 1;
                }
            }
        }
        assert_eq!(usage_count, 0, "non-assistant records must not contribute usage");
    }
}
