//! Bounded reads of Claude's own session files (`~/.claude/projects/*/<sid>.jsonl`).
//!
//! Files can be tens of MB: nothing here reads a whole file, and nothing runs
//! on the list path.

use crate::data::work::untrusted::one_line;
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Most bytes one tail refresh reads when more were appended.
pub const TAIL_MAX_BYTES: u64 = 4 << 20;
/// What is read instead when more than [`TAIL_MAX_BYTES`] were appended.
pub const TAIL_FALLBACK_BYTES: u64 = 256 << 10;
/// How much of the head a backfill reads.
pub const HEAD_BYTES: u64 = 512 << 10;

/// Test seam: overrides `~/.claude/projects`.
pub const PROJECTS_DIR_ENV: &str = "NOSTROMO_CLAUDE_PROJECTS_DIR";

pub fn projects_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os(PROJECTS_DIR_ENV).filter(|d| !d.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    Some(dirs_next::home_dir()?.join(".claude").join("projects"))
}

/// Claude's folder name for a working directory: every character that is not
/// an ASCII letter or digit becomes `-`.
pub fn encode_cwd(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The expected path of `sid`'s file for a conversation run in `cwd` (one
/// guess, no scan).
pub fn expected_path(sid: &str, cwd: &str) -> Option<PathBuf> {
    Some(
        projects_dir()?
            .join(encode_cwd(cwd))
            .join(format!("{sid}.jsonl")),
    )
}

/// Longest title and branch kept from a transcript (characters).
const MAX_TITLE_CHARS: usize = 120;
const MAX_BRANCH_CHARS: usize = 200;

/// Open `path` for reading only if it is a regular file: a symlink at the end
/// is refused (`O_NOFOLLOW`), and the open never blocks on a FIFO
/// (`O_NONBLOCK`), which is then refused as not a regular file.
pub fn open_regular(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if file.metadata()?.is_file() {
        Ok(file)
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "not a regular file",
        ))
    }
}

/// Is `path` a regular file (not a symlink) that really lives under the
/// projects folder? A symlinked folder cannot lead a read out of it.
pub fn is_safe_transcript(path: &Path) -> bool {
    let Some(root) = projects_dir().and_then(|r| r.canonicalize().ok()) else {
        return false;
    };
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return false;
    };
    meta.is_file()
        && path
            .canonicalize()
            .is_ok_and(|real| real.starts_with(&root))
}

/// Find `sid`'s file by trying every project folder (as `load_scrollback` does).
pub fn locate(sid: &str) -> Option<PathBuf> {
    if sid.is_empty() || sid.contains('/') || sid.contains("..") {
        return None;
    }
    let projects = projects_dir()?;
    for entry in std::fs::read_dir(projects).ok()?.flatten() {
        let candidate = entry.path().join(format!("{sid}.jsonl"));
        if is_safe_transcript(&candidate) {
            return Some(candidate);
        }
    }
    None
}

/// What a read of part of a transcript found.
#[derive(Debug, Default, PartialEq)]
pub struct Facts {
    /// `gitBranch` of the latest `user` record.
    pub branch: Option<String>,
    pub pr_numbers: Vec<u32>,
    /// `cwd` of the earliest record carrying one.
    pub cwd: Option<String>,
    pub title: Option<String>,
    /// The first real user message (head reads only).
    pub first_user: Option<String>,
    pub last_ts_ms: Option<i64>,
    pub model: Option<String>,
}

/// Read what was appended to `path` after `from` (at most [`TAIL_MAX_BYTES`];
/// if more, just the last [`TAIL_FALLBACK_BYTES`]). Returns the bytes, always
/// starting and ending on a line boundary, and the offset to resume from.
pub fn read_tail(path: &Path, from: u64) -> std::io::Result<(Vec<u8>, u64)> {
    let mut file = open_regular(path)?;
    let len = file.metadata()?.len();
    let mut start = if from > len { 0 } else { from };
    if len - start > TAIL_MAX_BYTES {
        start = len - TAIL_FALLBACK_BYTES;
    }
    file.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::with_capacity((len - start) as usize);
    file.take(len - start).read_to_end(&mut buf)?;
    // Mid-file start (a cut, not our own saved boundary): drop the partial line.
    let mut skipped = 0usize;
    if start > 0 && start != from {
        skipped = buf
            .iter()
            .position(|b| *b == b'\n')
            .map_or(buf.len(), |i| i + 1);
    }
    // Stop at the last newline: a line still being written is read next time.
    let end = buf
        .iter()
        .rposition(|b| *b == b'\n')
        .map_or(skipped, |i| i + 1);
    let end = end.max(skipped);
    let consumed = start + end as u64;
    Ok((buf[skipped..end].to_vec(), consumed))
}

/// Read up to the first [`HEAD_BYTES`] of `path`, cut at a line boundary.
pub fn read_head(path: &Path) -> std::io::Result<Vec<u8>> {
    let file = open_regular(path)?;
    let len = file.metadata()?.len();
    let mut buf = Vec::new();
    file.take(HEAD_BYTES).read_to_end(&mut buf)?;
    if len > HEAD_BYTES {
        if let Some(i) = buf.iter().rposition(|b| *b == b'\n') {
            buf.truncate(i + 1);
        }
    }
    Ok(buf)
}

/// Scan JSONL `bytes` for the facts the history keeps. Unparseable lines are
/// skipped. The `last-prompt` record is never read.
pub fn scan(bytes: &[u8]) -> Facts {
    let mut f = Facts::default();
    for line in bytes.split(|b| *b == b'\n') {
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let kind = v.get("type").and_then(Value::as_str).unwrap_or("");
        match kind {
            "last-prompt" => {}
            "custom-title" => {
                if let Some(t) = v.get("customTitle").and_then(Value::as_str) {
                    f.title = Some(one_line(t, MAX_TITLE_CHARS)).filter(|t| !t.is_empty());
                }
            }
            "agent-name" => {
                if f.title.is_none() {
                    f.title = v
                        .get("agentName")
                        .and_then(Value::as_str)
                        .map(|t| one_line(t, MAX_TITLE_CHARS))
                        .filter(|t| !t.is_empty());
                }
            }
            "pr-link" => {
                if let Some(n) = v.get("prNumber").and_then(Value::as_u64) {
                    if let Ok(n) = u32::try_from(n) {
                        if !f.pr_numbers.contains(&n) {
                            f.pr_numbers.push(n);
                        }
                    }
                }
            }
            "user" | "assistant" => {
                if v.get("isSidechain").and_then(Value::as_bool) == Some(true) {
                    continue;
                }
                if f.cwd.is_none() {
                    f.cwd = v.get("cwd").and_then(Value::as_str).map(str::to_owned);
                }
                if let Some(ts) = v.get("timestamp").and_then(Value::as_str) {
                    if let Ok(t) = chrono::DateTime::parse_from_rfc3339(ts) {
                        f.last_ts_ms = Some(t.timestamp_millis());
                    }
                }
                if kind == "user" {
                    if let Some(b) = v.get("gitBranch").and_then(Value::as_str) {
                        let b = one_line(b, MAX_BRANCH_CHARS);
                        if !b.is_empty() {
                            f.branch = Some(b);
                        }
                    }
                    if f.first_user.is_none()
                        && v.get("isMeta").and_then(Value::as_bool) != Some(true)
                    {
                        f.first_user = user_text(&v).filter(|t| is_real_prompt(t));
                    }
                } else if let Some(m) = v.pointer("/message/model").and_then(Value::as_str) {
                    f.model = Some(m.to_owned());
                }
            }
            _ => {}
        }
    }
    f
}

/// The text of a `user` record whose content is a string or text blocks (not
/// a tool result).
fn user_text(v: &Value) -> Option<String> {
    match v.pointer("/message/content")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            if blocks
                .iter()
                .any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
            {
                return None;
            }
            let texts: Vec<&str> = blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect();
            (!texts.is_empty()).then(|| texts.join("\n"))
        }
        _ => None,
    }
}

/// Not a command/harness echo or an injected-context line.
fn is_real_prompt(text: &str) -> bool {
    let t = text.trim_start();
    !t.is_empty()
        && !t.starts_with('<')
        && !t.starts_with("Caveat:")
        && crate::ipc::stream_json::parse_injected_origin(text, false).is_none()
}

/// Refresh `sid`'s branch and PR numbers from what was appended to its
/// transcript since the last refresh (bounded; see [`read_tail`]). Blocking:
/// run it on its own thread, never under a lock. Does nothing for a
/// conversation the history does not hold.
pub fn refresh_tail(history: &super::store::ConversationHistory, sid: &str) {
    let Some(entry) = history.get(sid) else {
        return;
    };
    let cached = entry.transcript_path.clone();
    let path = cached
        .clone()
        .filter(|p| is_safe_transcript(p))
        .or_else(|| locate(sid));
    let Some(path) = path else {
        return;
    };
    // A relocated file starts again from the top of its tail.
    let from = if cached.as_ref() == Some(&path) {
        entry.tail_offset
    } else {
        0
    };
    let Ok((bytes, offset)) = read_tail(&path, from) else {
        return;
    };
    let facts = scan(&bytes);
    history.apply_tail(
        sid,
        &path,
        offset,
        facts.branch,
        &facts.pr_numbers,
        super::now_ms(),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(v: serde_json::Value) -> String {
        format!("{v}\n")
    }

    #[test]
    fn scan_finds_branch_prs_title_cwd_and_the_first_real_prompt() {
        let mut s = String::new();
        s += &line(serde_json::json!({"type":"custom-title","customTitle":"My focus"}));
        s += &line(
            serde_json::json!({"type":"user","cwd":"/w/x","gitBranch":"main","isMeta":true,
            "message":{"content":"meta text"}}),
        );
        s += &line(
            serde_json::json!({"type":"user","cwd":"/w/x","gitBranch":"main",
            "message":{"content":"<command-name>/model</command-name>"}}),
        );
        s += &line(
            serde_json::json!({"type":"user","cwd":"/w/x","gitBranch":"main",
            "timestamp":"2026-11-10T10:00:00Z","message":{"content":"Add the picker"}}),
        );
        s += &line(serde_json::json!({"type":"pr-link","prNumber":12}));
        s += &line(serde_json::json!({"type":"pr-link","prNumber":12}));
        s += &line(serde_json::json!({"type":"last-prompt","lastPrompt":"NEVERREAD"}));
        s += &line(
            serde_json::json!({"type":"user","gitBranch":"feat/y","message":{"content":"later"}}),
        );
        s += "not json\n";
        let f = scan(s.as_bytes());
        assert_eq!(f.title.as_deref(), Some("My focus"));
        assert_eq!(f.cwd.as_deref(), Some("/w/x"));
        assert_eq!(f.branch.as_deref(), Some("feat/y"));
        assert_eq!(f.pr_numbers, vec![12]);
        assert_eq!(f.first_user.as_deref(), Some("Add the picker"));
        assert!(f.last_ts_ms.is_some());
    }

    #[test]
    fn read_tail_reads_only_appended_complete_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.jsonl");
        std::fs::write(&p, "{\"a\":1}\n{\"b\":2}\n{\"c\"").unwrap();
        let (bytes, off) = read_tail(&p, 0).unwrap();
        assert_eq!(bytes, b"{\"a\":1}\n{\"b\":2}\n");
        assert_eq!(off, 16);
        std::fs::write(&p, "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n").unwrap();
        let (bytes, off2) = read_tail(&p, off).unwrap();
        assert_eq!(bytes, b"{\"c\":3}\n");
        assert_eq!(off2, 24);
    }

    #[test]
    fn a_huge_append_reads_only_the_last_256k() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("big.jsonl");
        let mut data = vec![b'x'; (TAIL_MAX_BYTES + 10) as usize];
        data.push(b'\n');
        data.extend_from_slice(b"{\"type\":\"pr-link\",\"prNumber\":7}\n");
        std::fs::write(&p, data).unwrap();
        let (bytes, _) = read_tail(&p, 0).unwrap();
        assert!(bytes.len() as u64 <= TAIL_FALLBACK_BYTES);
        assert_eq!(scan(&bytes).pr_numbers, vec![7]);
    }

    #[test]
    fn titles_and_branches_from_a_transcript_are_one_clean_capped_line() {
        let long = "T".repeat(500);
        let mut s = String::new();
        s += &line(serde_json::json!({"type":"custom-title",
            "customTitle": format!("My\u{202E}fo\u{0007}cus\nsecond {long}")}));
        s += &line(serde_json::json!({"type":"user","gitBranch":"feat/\u{200B}x\u{202E}y\nz"}));
        let f = scan(s.as_bytes());
        let title = f.title.unwrap();
        assert!(title.starts_with("Myfocus second T"), "{title}");
        assert_eq!(title.chars().count(), MAX_TITLE_CHARS);
        assert_eq!(f.branch.as_deref(), Some("feat/xy z"));
        // The agent name takes the same path.
        let f = scan(
            line(serde_json::json!({"type":"agent-name","agentName":format!("a\u{202E}b{long}")}))
                .as_bytes(),
        );
        let name = f.title.unwrap();
        assert!(
            name.starts_with("ab") && name.chars().count() == MAX_TITLE_CHARS,
            "{name}"
        );
        // A branch is capped.
        let f =
            scan(line(serde_json::json!({"type":"user","gitBranch":"b".repeat(1000)})).as_bytes());
        assert_eq!(f.branch.unwrap().chars().count(), MAX_BRANCH_CHARS);
    }

    /// Run `f` on a thread and fail if it has not returned in five seconds
    /// (a read that blocks on a FIFO would hang the background pass).
    fn within_five_seconds<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(f());
        });
        rx.recv_timeout(std::time::Duration::from_secs(5))
            .expect("the read hung")
    }

    #[test]
    fn a_fifo_is_never_read_and_never_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let fifo = dir.path().join("pipe.jsonl");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let (tail, head, unreadable) = within_five_seconds({
            let fifo = fifo.clone();
            move || {
                (
                    read_tail(&fifo, 0).is_err(),
                    read_head(&fifo).is_err(),
                    crate::conversations::list::check_unreadable(&fifo),
                )
            }
        });
        assert!(tail && head && unreadable);
    }

    #[test]
    fn a_symlink_is_never_followed_out_of_the_transcripts() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("elsewhere.jsonl");
        std::fs::write(&real, "{\"type\":\"user\"}\n").unwrap();
        let link = dir.path().join("link.jsonl");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(read_tail(&link, 0).is_err());
        assert!(read_head(&link).is_err());
        assert!(crate::conversations::list::check_unreadable(&link));
        // The real file reads fine.
        assert!(read_tail(&real, 0).is_ok());
        assert!(!crate::conversations::list::check_unreadable(&real));
    }

    #[test]
    fn encode_cwd_matches_claudes_folder_naming() {
        assert_eq!(encode_cwd("/Users/a/Code/my.repo"), "-Users-a-Code-my-repo");
    }
}
