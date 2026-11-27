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
use crate::push::items::{Detail, Waiting};
use crate::push::wire::HostClass;

/// The longest line a notification gains, in characters.
pub const MAX_TEXT_CHARS: usize = 140;

/// The longest `item_ref` echoed back, in characters. Real refs are 16 hex characters.
pub const MAX_ITEM_REF_CHARS: usize = 64;

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

/// The first non-blank line of `text`, as one printable line: lines end at `\n`, `\r`, VT, FF, NEL,
/// U+2028 and U+2029 (the same characters the phone treats as line breaks, so no text is glued
/// together by deleting a break); a tab is a space; control characters and invisible format
/// characters are dropped; runs of spaces collapse. At most [`MAX_TEXT_CHARS`] characters, cut on a
/// character boundary and never between a zero-width joiner and what it joins; the cut is marked with
/// an ellipsis that counts toward the limit. `None` if nothing is left.
///
/// `tests/fixtures/push-detail/text_cases.json` is read by this function's tests and by the phone's
/// `NotificationContentComposer.flattened`: the two must agree.
pub fn first_line(text: &str) -> Option<String> {
    let line = text
        .split(is_line_break)
        .map(|l| {
            l.chars()
                .map(|c| if c == '\t' { ' ' } else { c })
                .filter(|c| !c.is_control() && !is_invisible_format(*c))
                .collect::<String>()
        })
        .map(|l| {
            l.split(' ')
                .filter(|w| !w.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        })
        .map(|l| l.trim().to_string())
        .find(|l| !l.is_empty())?;
    if line.chars().count() <= MAX_TEXT_CHARS {
        return Some(line);
    }
    let mut cut: String = line.chars().take(MAX_TEXT_CHARS - 1).collect();
    // No crate for grapheme clusters is vendored: back off a dangling joiner instead, so a cut never
    // leaves `👨‍` (an emoji waiting for the rest of its sequence).
    while cut.ends_with('\u{200D}') {
        cut.pop();
    }
    cut = cut.trim_end().to_string();
    cut.push('…');
    Some(cut)
}

/// Where a line ends: LF, VT, FF, CR, NEL, line separator, paragraph separator.
fn is_line_break(c: char) -> bool {
    matches!(
        c,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Characters that draw nothing or change how the text around them reads: every Unicode format
/// character (category Cf) except the joiners, plus the tag block (a known way to hide ASCII text),
/// the Mongolian vowel separator and the Hangul fillers. Written out because the standard library has
/// no general category; `NotificationContentComposer.isInvisibleFormat` lists the same ranges, and the
/// phone's tests fail if its Unicode database knows a format character this list does not.
fn is_invisible_format(c: char) -> bool {
    // Joiners (U+200C, U+200D) stay: they belong to emoji sequences and Persian words.
    matches!(
        c as u32,
        0x00AD
            | 0x0600..=0x0605
            | 0x061C
            | 0x06DD
            | 0x070F
            | 0x0890..=0x0891
            | 0x08E2
            | 0x115F..=0x1160
            | 0x180E
            | 0x200B
            | 0x200E..=0x200F
            | 0x2028..=0x202E
            | 0x2060..=0x206F
            | 0x3164
            | 0xFEFF
            | 0xFFA0
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
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
    // A decision that names no repository cannot be checked against the PHI repositories, so it is
    // denied whoever its owner is (`ask_decision` always sets both, so this guards a future caller).
    if matches!(&item.detail, Detail::Decision { repo: None, .. }) {
        return None;
    }
    // An unknown owner counts as a work owner. A count-only attention item has no owner either, so
    // this also keeps it text-less.
    let owner = owner_of(item).filter(|o| !o.is_empty())?;
    if cfg
        .resolved_work_owners()
        .iter()
        .any(|w| w.eq_ignore_ascii_case(owner))
    {
        return None;
    }
    text.line.clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::items::ItemKey;

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

    fn personal_cfg() -> PushConfig {
        let mut cfg = PushConfig::default();
        cfg.hosts.insert("sendai".into(), HostClass::Personal);
        cfg
    }

    fn waiting_with_owner(owner: &str) -> Waiting {
        Waiting {
            key: ItemKey::Mother {
                host: "sendai".into(),
                job_id: "20261126T100000Z-0a1b2c3d".into(),
            },
            item_ref: "0123456789abcdef".into(),
            host: "sendai".into(),
            start: None,
            detail: Detail::Mother {
                job_ref: None,
                reason: crate::push::items::MotherReason::Asked,
                repo: Some("nostromo".into()),
                owner: Some(owner.into()),
            },
            preexisting: false,
        }
    }

    fn job(label: Option<&str>) -> MotherJob {
        serde_json::from_value(serde_json::json!({
            "id": "20261126T100000Z-0a1b2c3d", "state": "awaiting", "repo": "nostromo",
            "title": "t", "question": "Which branch?",
            "origin": { "label": label },
        }))
        .unwrap()
    }

    /// `mother_items` already drops a work-send job's owner, so through the engine the owner rule
    /// denies it first; this proves the work-send flag denies it on its own.
    #[test]
    fn a_work_send_job_has_no_text_even_when_every_other_rule_allows_it() {
        let cfg = personal_cfg();
        let sensitive = SensitiveTags::in_memory();
        let item = waiting_with_owner("thehammer");

        let allowed = Capture::mother(&job(None));
        assert_eq!(
            text_for(&item, Some(&allowed), &cfg, &sensitive),
            Some("Which branch?".into()),
            "control: the same job, not queued from a work item"
        );
        let work = Capture::mother(&job(Some(crate::mother::WORK_SEND_JOB_LABEL)));
        assert_eq!(text_for(&item, Some(&work), &cfg, &sensitive), None);
    }

    #[test]
    fn control_characters_never_survive() {
        assert_eq!(first_line("a\u{1b}[31mb\u{0}c"), Some("a[31mbc".into()));
    }

    #[test]
    fn every_line_break_ends_the_line_and_is_never_deleted() {
        for br in [
            "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
        ] {
            assert_eq!(
                first_line(&format!("first{br}SECONDLINE")),
                Some("first".into()),
                "{br:?}"
            );
            assert_eq!(
                first_line(&format!("{br}{br}  second{br}third")),
                Some("second".into()),
                "{br:?}"
            );
        }
    }

    #[test]
    fn a_cut_never_leaves_a_dangling_zero_width_joiner() {
        let (man, woman, girl) = ('\u{1F468}', '\u{1F469}', '\u{1F467}');
        // 137 letters, the man, a joiner, the woman, a joiner, the girl: 142 characters. The first
        // 139 end on the first joiner, which would leave the man waiting for the rest of his family.
        let line = format!("{}{man}\u{200D}{woman}\u{200D}{girl}", "a".repeat(137));
        assert_eq!(
            first_line(&line),
            Some(format!("{}{man}…", "a".repeat(137)))
        );
    }

    #[test]
    fn a_decision_that_names_an_owner_but_no_repository_has_no_text() {
        let cfg = personal_cfg();
        let sensitive = SensitiveTags::in_memory();
        let mut item = waiting_with_owner("thehammer");
        item.detail = Detail::Decision {
            agent: crate::push::wire::AgentClass::Claudia,
            choices: 2,
            deadline: None,
            presence: None,
            repo: Some("nostromo".into()),
            owner: Some("thehammer".into()),
        };
        let text = Capture::decision("focus", Some("nostromo"), "Ship it?");
        assert_eq!(
            text_for(&item, Some(&text), &cfg, &sensitive),
            Some("Ship it?".into()),
            "control: the same decision with its repository"
        );
        if let Detail::Decision { repo, .. } = &mut item.detail {
            *repo = None;
        }
        let text = Capture::decision("focus", None, "Ship it?");
        assert_eq!(text_for(&item, Some(&text), &cfg, &sensitive), None);
    }
}
