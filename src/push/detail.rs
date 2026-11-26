//! On-phone enrichment text (W16): the one line a personal host's notification
//! may gain on the phone, served to a paired device over its authenticated
//! socket (`PushDetail`), never through the relay.
//!
//! The rule is **default-deny**. [`ItemText`] is captured when a frame arrives,
//! with the facts that decide whether it may ever be shown, and
//! [`PushEngine::push_detail`] re-checks everything that can change (the host
//! class, the work owners) at the moment of the request. Text is returned only
//! for an item that is all of:
//!
//! * on a host the operator classified `personal` (a `work` satellite sends
//!   metadata only, so the primary holds no text for it either);
//! * not PHI-scoped (its repository, plan path, PR URL or origin focus names a
//!   PHI repository), not on a sensitive tag, not a job queued from a work item;
//! * in a repository whose owner is known and is not a work owner.
//!
//! The text is the first line, at most [`MAX_TEXT_CHARS`] characters, of exactly
//! one field per kind: a Mother job's `question`, a PR's `title`, a decision's
//! `prompt`. Nothing else is read: not a decision's `detail`, not its choice
//! labels, not a job's notes, plan, branch, author or labels.

use crate::config::PushConfig;
use crate::data::perri_queue::PrQueueItem;
use crate::ipc::peer::SensitiveTags;
use crate::ipc::uplink::PhiScope;
use crate::mother::MotherJob;
use crate::push::items::{ItemKey, Waiting};
use crate::push::wire::HostClass;

/// The longest line a notification gains, in characters.
pub const MAX_TEXT_CHARS: usize = 140;

/// The longest `item_ref` echoed back. Real refs are 16 hex characters.
pub const MAX_ITEM_REF_BYTES: usize = 64;

/// What the engine kept about one item's text, and what decides whether it may
/// leave. The deciding inputs are kept, not the verdict, so a PHI repository
/// added to the config or a tag that turns sensitive after the item arrived
/// takes effect on the next request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemText {
    /// The first line, already bounded; `None` when the source had none.
    pub line: Option<String>,
    /// Path-like strings (repository, plan path, PR URL) searched for a PHI repository.
    phi_paths: Vec<String>,
    /// Names (a focus name) compared with the PHI repositories.
    phi_names: Vec<String>,
    /// A decision's tag, checked against the sensitive-tag registry.
    tag: Option<String>,
    /// A Mother job's id, checked against the registry of jobs queued from work items.
    job_id: Option<String>,
    /// Queued from a work item: never carries text.
    work_send: bool,
}

/// The first non-blank line of `text`, control characters removed, at most
/// [`MAX_TEXT_CHARS`] characters (cut on a character boundary; the cut is marked
/// with an ellipsis that counts toward the limit). `None` if nothing is left.
pub fn first_line(text: &str) -> Option<String> {
    let line = text
        .lines()
        .map(|l| {
            l.chars()
                .map(|c| if matches!(c, '\t' | '\r') { ' ' } else { c })
                .filter(|c| !c.is_control() && !is_invisible_format(*c))
                .collect::<String>()
        })
        .map(|l| l.trim().to_string())
        .find(|l| !l.is_empty())?;
    if line.chars().count() <= MAX_TEXT_CHARS {
        return Some(line);
    }
    let mut cut: String = line.chars().take(MAX_TEXT_CHARS - 1).collect();
    cut = cut.trim_end().to_string();
    cut.push('…');
    Some(cut)
}

/// Characters that draw nothing or change how the text around them reads: zero-width and
/// bidirectional controls, line and paragraph separators, the byte-order mark.
fn is_invisible_format(c: char) -> bool {
    // Joiners (U+200C, U+200D) stay: they belong to emoji sequences and Persian words.
    matches!(
        c,
        '\u{061C}'
            | '\u{200B}'
            | '\u{200E}'..='\u{200F}'
            | '\u{2028}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}'
    )
}

/// Captures an item's text with what decides its release.
pub struct Capture;

impl Capture {
    /// A Mother job's text, from its `question`.
    pub fn mother(job: &MotherJob) -> ItemText {
        ItemText {
            line: job.question.as_deref().and_then(first_line),
            phi_paths: [
                Some(job.repo.as_str()),
                job.plan_path.as_deref(),
                job.pr_url.as_deref(),
            ]
            .into_iter()
            .flatten()
            .map(str::to_string)
            .collect(),
            phi_names: job
                .origin
                .as_ref()
                .and_then(|o| o.focus_name.clone())
                .into_iter()
                .collect(),
            tag: None,
            job_id: Some(job.id.clone()),
            work_send: job.is_work_send(),
        }
    }

    /// A PR's text, from its `title`.
    pub fn review(pr: &PrQueueItem) -> ItemText {
        ItemText {
            line: first_line(&pr.title),
            phi_paths: vec![pr.repo.clone()],
            phi_names: Vec::new(),
            tag: None,
            job_id: None,
            work_send: false,
        }
    }

    /// A decision's text, from its `prompt` only.
    pub fn decision(tag: &str, repo: Option<&str>, prompt: &str) -> ItemText {
        ItemText {
            line: first_line(prompt),
            phi_paths: repo.map(str::to_string).into_iter().collect(),
            phi_names: Vec::new(),
            tag: Some(tag.to_string()),
            job_id: None,
            work_send: false,
        }
    }
}

impl ItemText {
    /// May this text leave at all: not PHI-scoped, not on a sensitive tag, not a
    /// work send. Judged against the current PHI repositories and sensitive tags.
    fn shareable(&self, phi: &PhiScope, sensitive: &SensitiveTags) -> bool {
        !self.work_send
            && !self.phi_paths.iter().any(|p| phi.path_is_phi(p))
            && !self.phi_names.iter().any(|n| phi.name_is_phi(n))
            && !self
                .tag
                .as_deref()
                .is_some_and(|t| sensitive.tag_is_sensitive(t))
            && !self
                .job_id
                .as_deref()
                .is_some_and(|j| sensitive.job_is_sensitive(j))
    }
}

/// The owner of the item's repository, as the item carries it.
pub fn owner_of(item: &Waiting) -> Option<&str> {
    use crate::push::items::Detail;
    match &item.detail {
        Detail::Mother { owner, .. } | Detail::Decision { owner, .. } => owner.as_deref(),
        Detail::Review { owner, .. } => owner.as_deref(),
        Detail::Attention => None,
    }
}

/// The text the phone may show for `item`, or `None`. The single place the
/// egress rule lives.
pub fn text_for(
    item: &Waiting,
    text: Option<&ItemText>,
    cfg: &PushConfig,
    sensitive: &SensitiveTags,
) -> Option<String> {
    let text = text?;
    if !text.shareable(&PhiScope::new(cfg.resolved_phi_repos()), sensitive) {
        return None;
    }
    if crate::push::host_class(cfg, &item.host) != HostClass::Personal {
        return None;
    }
    // An unknown owner counts as a work owner.
    let owner = owner_of(item).filter(|o| !o.is_empty())?;
    if cfg
        .resolved_work_owners()
        .iter()
        .any(|w| w.eq_ignore_ascii_case(owner))
    {
        return None;
    }
    // Count-only items have no source text, and never will.
    if matches!(item.key, ItemKey::Attention { .. }) {
        return None;
    }
    text.line.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_non_blank_line_is_taken_and_bounded() {
        assert_eq!(first_line("\n  \nHello\nworld"), Some("Hello".into()));
        assert_eq!(first_line(""), None);
        assert_eq!(first_line(" \n\t "), None);
        let long = "x".repeat(300);
        let line = first_line(&long).unwrap();
        assert_eq!(line.chars().count(), MAX_TEXT_CHARS);
        assert!(line.ends_with('…'));
        let exact = "y".repeat(MAX_TEXT_CHARS);
        assert_eq!(first_line(&exact), Some(exact));
    }

    #[test]
    fn the_cut_is_on_a_character_boundary() {
        let long = "é".repeat(300);
        let line = first_line(&long).unwrap();
        assert_eq!(line.chars().count(), MAX_TEXT_CHARS);
    }

    #[test]
    fn control_characters_never_survive() {
        assert_eq!(first_line("a\u{1b}[31mb\u{0}c"), Some("a[31mbc".into()));
    }
}
