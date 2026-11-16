//! One-time backfill of the history from the session-id history that already
//! exists, on a background thread. Never blocks start-up or the list.

use super::first_prompt::{self, FirstPrompt, Reason};
use super::store::{main_checkout_of, ConversationEntry, ConversationHistory, MAX_PRS};
use super::transcript;
use crate::ipc::peer::SensitiveTags;

/// The agent a focus tag belongs to: tags are `<agent>-<8 hex>`, or the bare
/// agent name for a built-in.
pub fn agent_of_tag(tag: &str) -> &str {
    match tag.rsplit_once('-') {
        Some((agent, id)) if id.len() == 8 && id.bytes().all(|b| b.is_ascii_hexdigit()) => agent,
        _ => tag,
    }
}

/// Backfill from `(tag, sid, last_seen_ms)` records. `restricted(tag)` skips
/// unattended sessions. Sensitivity fails closed: a degraded registry marks
/// every entry sensitive. Does nothing if already backfilled.
pub fn run(
    history: &ConversationHistory,
    sources: Vec<(String, String, i64)>,
    sensitive: &SensitiveTags,
    restricted: impl Fn(&str) -> bool,
) {
    if history.backfilled() {
        return;
    }
    let enabled = history.first_prompts_enabled();
    let mut found = Vec::new();
    for (tag, sid, last_seen) in sources {
        if restricted(&tag) {
            continue;
        }
        let agent = agent_of_tag(&tag);
        let is_sensitive = sensitive.is_degraded() || sensitive.focus_is_sensitive(&tag, agent);
        let mut e = ConversationEntry::new(&sid, &tag, agent, agent, last_seen);
        e.make_visible();
        e.sensitive = is_sensitive;
        match transcript::locate(&sid) {
            None => history.note_not_found(&sid),
            Some(path) => fill_from(&mut e, &path, enabled),
        }
        if is_sensitive {
            e.branch = None;
            if matches!(e.first_prompt, FirstPrompt::Text(_)) {
                e.first_prompt = FirstPrompt::Withheld(Reason::SensitiveConversation);
            }
        }
        found.push(e);
    }
    history.finish_backfill(found, super::now_ms());
}

fn fill_from(e: &mut ConversationEntry, path: &std::path::Path, enabled: bool) {
    e.transcript_path = Some(path.to_path_buf());
    let Ok(head_bytes) = transcript::read_head(path) else {
        return;
    };
    fill_with_head(e, path, transcript::scan(&head_bytes), enabled);
}

/// The rest of [`fill_from`], given the head already read and scanned: the
/// last 256 KiB for the branch, PR numbers and last activity.
pub(super) fn fill_with_head(
    e: &mut ConversationEntry,
    path: &std::path::Path,
    head: transcript::Facts,
    enabled: bool,
) {
    let len = std::fs::metadata(path).map_or(0, |m| m.len());
    // The last 256 KiB for the branch, PR numbers and last activity.
    let tail_from = len.saturating_sub(transcript::TAIL_FALLBACK_BYTES);
    let (tail_bytes, offset) = transcript::read_tail(path, tail_from).unwrap_or_default();
    let tail = transcript::scan(&tail_bytes);
    e.tail_offset = offset;
    if let Some(cwd) = head.cwd {
        e.main_checkout = main_checkout_of(&cwd);
        e.project_path = Some(cwd);
    }
    if let Some(t) = head.title {
        e.title = t;
    }
    e.branch = tail.branch.or(head.branch);
    e.model = tail.model.or(head.model);
    // The newest few: later `pr-link` records come last.
    e.pr_numbers = tail.pr_numbers;
    let excess = e.pr_numbers.len().saturating_sub(MAX_PRS);
    e.pr_numbers.drain(..excess);
    if let Some(ts) = tail.last_ts_ms.or(head.last_ts_ms) {
        e.last_active_ms = ts;
    }
    if let Some(text) = head.first_user {
        e.first_prompt = first_prompt::derive(&text, false, e.sensitive, enabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backfill_keeps_the_newest_eight_pr_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let mut body =
            String::from("{\"type\":\"user\",\"cwd\":\"/w/x\",\"message\":{\"content\":\"hi\"}}\n");
        for n in 1..=12 {
            body += &format!("{{\"type\":\"pr-link\",\"prNumber\":{n}}}\n");
        }
        std::fs::write(&path, body).unwrap();
        let mut e = ConversationEntry::new("s", "cody-aaaa1111", "cody", "cody", 0);
        fill_from(&mut e, &path, true);
        assert_eq!(e.pr_numbers, vec![5, 6, 7, 8, 9, 10, 11, 12]);
    }

    #[test]
    fn agent_comes_off_the_tag() {
        assert_eq!(agent_of_tag("cody-1a2b3c4d"), "cody");
        assert_eq!(agent_of_tag("fred"), "fred");
        assert_eq!(agent_of_tag("claudia-ffffffff"), "claudia");
        assert_eq!(agent_of_tag("my-agent"), "my-agent");
    }
}
