//! The bridge's own log: `~/.nostromo/logs/mcp-bridge-<pid>.log`.
//!
//! Content-free by construction: [`BridgeLog::line`] takes only a pty id, an
//! event code and an attempt count, so a frame's contents cannot reach it.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

/// How many `mcp-bridge-*.log` files are kept (newest by mtime).
pub const MAX_LOG_FILES: usize = 20;
/// Hard cap on one log file's size.
pub const MAX_LOG_BYTES: u64 = 256 * 1024;

pub struct BridgeLog {
    file: File,
    size: u64,
}

impl BridgeLog {
    /// Create (or append to) `dir/mcp-bridge-<pid>.log` with mode 0600 and
    /// prune older bridge logs so only the newest [`MAX_LOG_FILES`] remain.
    pub fn open(dir: &Path, pid: u32) -> std::io::Result<Self> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        let name = format!("mcp-bridge-{pid}.log");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .mode(0o600)
            .open(dir.join(&name))?;
        let size = file.metadata()?.len();
        prune(dir, &name);
        Ok(Self { file, size })
    }

    /// Append one event line: timestamp, pty id, event code, attempt count.
    pub fn line(&mut self, pty_id: &str, event: &str, attempt: Option<u32>) {
        let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let mut text = format!("{ts} pty={pty_id} event={event}");
        if let Some(n) = attempt {
            text.push_str(&format!(" attempt={n}"));
        }
        text.push('\n');
        if self.size + text.len() as u64 > MAX_LOG_BYTES {
            self.trim();
        }
        if self.file.write_all(text.as_bytes()).is_ok() {
            self.size += text.len() as u64;
        }
    }

    /// Drop the oldest lines, keeping about the newest half of the cap.
    fn trim(&mut self) {
        let mut all = Vec::new();
        let mut handle = &self.file;
        if handle.seek(SeekFrom::Start(0)).is_err() || handle.read_to_end(&mut all).is_err() {
            return;
        }
        let keep_from = all.len().saturating_sub((MAX_LOG_BYTES / 2) as usize);
        let start = if keep_from == 0 {
            0
        } else {
            all[keep_from..]
                .iter()
                .position(|b| *b == b'\n')
                .map_or(all.len(), |i| keep_from + i + 1)
        };
        let tail = &all[start..];
        if self.file.set_len(0).is_ok() && self.file.write_all(tail).is_ok() {
            self.size = tail.len() as u64;
        }
    }
}

/// Remove all but the newest [`MAX_LOG_FILES`] `mcp-bridge-*.log` files in
/// `dir`; `keep` (our own file) is never removed.
fn prune(dir: &Path, keep: &str) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut logs: Vec<(std::time::SystemTime, String)> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if !(name.starts_with("mcp-bridge-") && name.ends_with(".log")) {
                return None;
            }
            let mtime = e.metadata().ok()?.modified().ok()?;
            Some((mtime, name))
        })
        .collect();
    logs.sort_by(|a, b| b.cmp(a)); // newest first
    let mut kept = 0;
    for (_, name) in logs {
        if name == keep || kept < MAX_LOG_FILES {
            kept += 1;
            continue;
        }
        let _ = fs::remove_file(dir.join(name));
    }
}
