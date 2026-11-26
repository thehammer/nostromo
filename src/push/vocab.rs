//! The closed vocabulary (W13): every fixed phrase a notification can say, and
//! the renderers that turn typed facts into `{title, body}`.
//!
//! This is the privacy boundary. A renderer's parameters are typed facts
//! (`items::Waiting`), never free text; the only strings that flow into a
//! notification from outside are validated host labels, validated job refs and
//! (for a personal host's non-work repository) a validated repository name.
//! [`conforms`] is the allow-list grammar a test uses to prove nothing else can
//! appear.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use regex::Regex;

use crate::push::items::{Detail, MotherReason, Waiting};
use crate::push::wire::{AgentClass, HostClass, PushKind};

// ── fixed phrases ────────────────────────────────────────────────────────────

/// Mother's `paused_reason` → phrase. Equals `tests/fixtures/push-vocab/reason_phrases.json`.
pub const MOTHER_PAUSED_REASONS: &[(&str, &str)] = &[
    ("user", "asked a question"),
    ("adherence_blocked", "blocked after review"),
    ("operator_hold", "held after a failure"),
    ("cost_cap", "paused at its spend cap"),
];
/// Mother's `activity` → phrase.
pub const MOTHER_ACTIVITIES: &[(&str, &str)] = &[("pipeline_blocked", "pipeline blocked")];
/// Any other reason.
pub const MOTHER_REASON_DEFAULT: &str = "needs you";
/// The agents a decision may name; anything else is [`AGENT_FALLBACK`].
pub const AGENT_CLASSES: &[(&str, &str)] = &[
    ("mother", "Mother"),
    ("perri", "Perri"),
    ("fred", "Fred"),
    ("teri", "Teri"),
    ("claudia", "Claudia"),
];
pub const AGENT_FALLBACK: &str = "A session";

pub const KIND_MOTHER: &str = "Mother";
pub const KIND_DECISION: &str = "Decision";
pub const KIND_REVIEW: &str = "Review";
pub const SUMMARY_TITLE: &str = "Waiting for you";
pub const NO_LONGER_NEEDS_YOU: &str = "no longer needs you";
/// The host label used when a name does not match the allowed shape (C6).
pub const HOST_FALLBACK: &str = "host";
const SEP: &str = " · ";

/// Review size: under 50 changed lines is small, up to 400 medium, above large.
pub const SIZE_SMALL_BELOW: u64 = 50;
pub const SIZE_MEDIUM_UP_TO: u64 = 400;

/// The phrase for a Mother reason.
pub fn reason_phrase(reason: MotherReason) -> &'static str {
    let key = match reason {
        MotherReason::Asked => "user",
        MotherReason::BlockedAfterReview => "adherence_blocked",
        MotherReason::HeldAfterFailure => "operator_hold",
        MotherReason::SpendCap => "cost_cap",
        MotherReason::PipelineBlocked => "pipeline_blocked",
        MotherReason::NeedsYou => return MOTHER_REASON_DEFAULT,
    };
    MOTHER_PAUSED_REASONS
        .iter()
        .chain(MOTHER_ACTIVITIES)
        .find(|(k, _)| *k == key)
        .map_or(MOTHER_REASON_DEFAULT, |(_, phrase)| phrase)
}

/// The name a decision shows for its asking agent.
pub fn agent_name(class: AgentClass) -> &'static str {
    let key = match class {
        AgentClass::Mother => "mother",
        AgentClass::Perri => "perri",
        AgentClass::Fred => "fred",
        AgentClass::Teri => "teri",
        AgentClass::Claudia => "claudia",
        AgentClass::Other => return AGENT_FALLBACK,
    };
    AGENT_CLASSES
        .iter()
        .find(|(k, _)| *k == key)
        .map_or(AGENT_FALLBACK, |(_, name)| name)
}

/// How a reason reads in a sentence: `asked a question` and `needs you` follow
/// the job directly, the others take `is`.
fn reason_sentence(reason: MotherReason) -> String {
    let phrase = reason_phrase(reason);
    match reason {
        MotherReason::Asked | MotherReason::NeedsYou => phrase.to_string(),
        _ => format!("is {phrase}"),
    }
}

// ── context ──────────────────────────────────────────────────────────────────

/// What a renderer needs besides the item: how hosts are classified, which
/// owners are work owners, how many reviews wait per host, and the time.
#[derive(Debug, Clone)]
pub struct RenderContext<'a> {
    pub hosts: &'a BTreeMap<String, HostClass>,
    pub work_owners: &'a [String],
    /// Reviews waiting on the operator, per host label.
    pub reviews_waiting: &'a BTreeMap<String, usize>,
    pub now: DateTime<Utc>,
}

/// A rendered notification text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    pub title: String,
    pub body: String,
}

fn host_regex() -> Regex {
    Regex::new(r"^[a-z][a-z0-9-]{0,15}$").unwrap()
}

/// A host's label as a notification says it: the name if it has the allowed
/// shape, else the literal `host`.
pub fn host_label(host: &str) -> &str {
    if host_regex().is_match(host) {
        host
    } else {
        HOST_FALLBACK
    }
}

/// The repository name a notification may show for an item on `host`: only on
/// a personal host, only when the owner is known and is not a work owner (an
/// unknown owner counts as one), and only if the name has the allowed shape.
pub fn shown_repo<'a>(
    host: &str,
    repo: Option<&'a str>,
    owner: Option<&str>,
    ctx: &RenderContext<'_>,
) -> Option<&'a str> {
    if ctx.hosts.get(host).copied().unwrap_or_default() != HostClass::Personal {
        return None;
    }
    let owner = owner?;
    if ctx
        .work_owners
        .iter()
        .any(|w| w.eq_ignore_ascii_case(owner))
    {
        return None;
    }
    let repo = repo?;
    let ok = (1..=40).contains(&repo.len())
        && repo
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-');
    ok.then_some(repo)
}

fn kind_label(kind: PushKind) -> &'static str {
    match kind {
        PushKind::Mother => KIND_MOTHER,
        PushKind::Decision => KIND_DECISION,
        PushKind::Review => KIND_REVIEW,
    }
}

fn repo_of(w: &Waiting) -> (Option<&str>, Option<&str>) {
    match &w.detail {
        Detail::Mother { repo, owner, .. } | Detail::Decision { repo, owner, .. } => {
            (repo.as_deref(), owner.as_deref())
        }
        Detail::Review { repo, owner, .. } => (Some(repo.as_str()), owner.as_deref()),
        Detail::Attention => (None, None),
    }
}

fn title_of(w: &Waiting, ctx: &RenderContext<'_>) -> String {
    let mut title = format!("{}{SEP}{}", kind_label(w.kind()), host_label(&w.host));
    let (repo, owner) = repo_of(w);
    if let Some(repo) = shown_repo(&w.host, repo, owner, ctx) {
        title.push_str(SEP);
        title.push_str(repo);
    }
    title
}

// ── renderers ────────────────────────────────────────────────────────────────

/// The size phrase of a review, or `None` when the line count is unknown.
pub fn size_phrase(changed_lines: Option<u64>) -> Option<&'static str> {
    changed_lines.map(|n| {
        if n < SIZE_SMALL_BELOW {
            "small change"
        } else if n <= SIZE_MEDIUM_UP_TO {
            "medium change"
        } else {
            "large change"
        }
    })
}

/// "times out in 4 min" (whole minutes, rounded down) or "times out in under 1
/// min" below a minute. `None` with no deadline.
pub fn timeout_phrase(deadline: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Option<String> {
    let secs = (deadline? - now).num_seconds().max(0);
    Some(if secs < 60 {
        "times out in under 1 min".to_string()
    } else {
        format!("times out in {} min", secs / 60)
    })
}

/// The alert for an item, or `None` for a count-only one.
pub fn render_alert(w: &Waiting, ctx: &RenderContext<'_>) -> Option<Rendered> {
    let body = match &w.detail {
        Detail::Attention => return None,
        Detail::Mother {
            job_ref, reason, ..
        } => {
            let what = match job_ref {
                Some(r) => format!("Job {r}"),
                None => "A job".to_string(),
            };
            format!("{what} {}", reason_sentence(*reason))
        }
        Detail::Decision {
            agent,
            choices,
            deadline,
            ..
        } => {
            let mut parts = vec![
                format!("{} is waiting on you", agent_name(*agent)),
                format!(
                    "{choices} {}",
                    if *choices == 1 { "choice" } else { "choices" }
                ),
            ];
            parts.extend(timeout_phrase(*deadline, ctx.now));
            parts.join(SEP)
        }
        Detail::Review {
            number,
            changed_lines,
            ..
        } => {
            let waiting = ctx
                .reviews_waiting
                .get(&w.host)
                .copied()
                .unwrap_or(1)
                .max(1);
            let mut parts = vec![format!("PR #{number}")];
            parts.extend(size_phrase(*changed_lines).map(str::to_string));
            parts.push(format!("{waiting} waiting"));
            parts.join(SEP)
        }
    };
    Some(Rendered {
        title: title_of(w, ctx),
        body,
    })
}

/// The short reference a withdrawal names: `Job 3f9a1c2e`, `PR #4821`, or the
/// decision's agent from the fixed set.
pub fn item_ref_text(w: &Waiting) -> Option<String> {
    match &w.detail {
        Detail::Attention => None,
        Detail::Mother { job_ref, .. } => Some(match job_ref {
            Some(r) => format!("Job {r}"),
            None => "A job".to_string(),
        }),
        Detail::Decision { agent, .. } => Some(agent_name(*agent).to_string()),
        Detail::Review { number, .. } => Some(format!("PR #{number}")),
    }
}

/// The passive replacement that takes the place of an item's delivered
/// notification: the same title, `<ref> no longer needs you`.
pub fn render_withdrawal(w: &Waiting, ctx: &RenderContext<'_>) -> Option<Rendered> {
    Some(Rendered {
        title: title_of(w, ctx),
        body: format!("{} {NO_LONGER_NEEDS_YOU}", item_ref_text(w)?),
    })
}

/// A Summary of everything waiting: counts by host and the age of the oldest
/// item. Never a repository name.
pub fn render_summary(
    waiting: &[&Waiting],
    oldest: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Rendered {
    let mut per_host: BTreeMap<&str, usize> = BTreeMap::new();
    for w in waiting {
        *per_host.entry(host_label(&w.host)).or_default() += 1;
    }
    let mut hosts: Vec<(&str, usize)> = per_host.into_iter().collect();
    hosts.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    let total = waiting.len();
    let split = hosts
        .iter()
        .map(|(host, n)| format!("{n} on {host}"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut parts = vec![
        format!("{total} {}", if total == 1 { "item" } else { "items" }),
        split,
    ];
    if let Some(oldest) = oldest {
        let mins = (now - oldest).num_minutes().max(0);
        parts.push(if mins < 60 {
            format!("oldest {} min", mins.max(1))
        } else if mins < 48 * 60 {
            format!("oldest {} h", mins / 60)
        } else {
            format!("oldest {} d", mins / (24 * 60))
        });
    }
    Rendered {
        title: SUMMARY_TITLE.to_string(),
        body: parts.join(SEP),
    }
}

// ── the allow-list ───────────────────────────────────────────────────────────

/// The first part of a string that is not in the vocabulary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offending(pub String);

/// What [`conforms`] allows besides the fixed phrases: the host labels and the
/// repository names that may appear.
#[derive(Debug, Clone, Default)]
pub struct VocabContext {
    pub hosts: Vec<String>,
    pub repos: Vec<String>,
}

fn alternatives<'a>(words: impl IntoIterator<Item = &'a str>) -> String {
    words
        .into_iter()
        .map(regex::escape)
        .collect::<Vec<_>>()
        .join("|")
}

/// Does `text` belong to the closed vocabulary? A title or a body is accepted
/// only if it matches one of the grammars below exactly; free text, a name or a
/// number that is not in a numeric slot is rejected. This is an allow-list: the
/// tests inject markers and assert rejection.
pub fn conforms(text: &str, ctx: &VocabContext) -> Result<(), Offending> {
    // The phrases that take `is` (`asked a question` and `needs you` do not).
    let is_reasons = alternatives(
        MOTHER_PAUSED_REASONS
            .iter()
            .filter(|(key, _)| *key != "user")
            .chain(MOTHER_ACTIVITIES)
            .map(|(_, phrase)| *phrase),
    );
    let agents = alternatives(
        AGENT_CLASSES
            .iter()
            .map(|(_, n)| *n)
            .chain(std::iter::once(AGENT_FALLBACK)),
    );
    let host = {
        let mut hosts: Vec<&str> = ctx.hosts.iter().map(String::as_str).collect();
        hosts.push(HOST_FALLBACK);
        alternatives(hosts)
    };
    let repo = alternatives(ctx.repos.iter().map(String::as_str));
    let repo_part = if repo.is_empty() {
        String::new()
    } else {
        format!("(?: · (?:{repo}))?")
    };
    let kinds = alternatives([KIND_MOTHER, KIND_DECISION, KIND_REVIEW]);
    let job = "(?:Job [0-9a-f]{8}|A job)";
    let patterns = [
        // Titles.
        format!("^(?:{kinds}) · (?:{host}){repo_part}$"),
        format!("^{}$", regex::escape(SUMMARY_TITLE)),
        // Mother job bodies: the phrase table, with `is` where the sentence needs it.
        format!(
            "^{job} (?:{}|{}|is (?:{is_reasons}))$",
            regex::escape(reason_phrase(MotherReason::Asked)),
            regex::escape(MOTHER_REASON_DEFAULT),
        ),
        // Decisions.
        format!(
            "^(?:{agents}) is waiting on you · [0-9]+ choices?(?: · times out in (?:[0-9]+ min|under 1 min))?$"
        ),
        // Reviews.
        "^PR #[0-9]+(?: · (?:small|medium|large) change)? · [0-9]+ waiting$".to_string(),
        // Withdrawals.
        format!(
            "^(?:{job}|PR #[0-9]+|{agents}) {}$",
            regex::escape(NO_LONGER_NEEDS_YOU)
        ),
        // Summaries.
        format!(
            "^[0-9]+ items? · [0-9]+ on (?:{host})(?:, [0-9]+ on (?:{host}))* · oldest [0-9]+ (?:min|h|d)$"
        ),
        format!("^[0-9]+ items? · [0-9]+ on (?:{host})(?:, [0-9]+ on (?:{host}))*$"),
    ];
    if patterns
        .iter()
        .any(|p| Regex::new(p).is_ok_and(|re| re.is_match(text)))
    {
        Ok(())
    } else {
        Err(Offending(text.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The phrase tables equal the file the phone's `ReasonPhrases` also
    /// asserts, so the app and the lock screen say the same thing.
    #[test]
    fn the_phrase_tables_equal_the_shared_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/push-vocab/reason_phrases.json"
        ))
        .unwrap();
        let table = |name: &str, rows: &[(&str, &str)]| {
            let obj = fixture[name]
                .as_object()
                .unwrap_or_else(|| panic!("{name}"));
            assert_eq!(obj.len(), rows.len(), "{name}");
            for (k, v) in rows {
                assert_eq!(obj[*k], *v, "{name}.{k}");
            }
        };
        table("mother_paused_reason", MOTHER_PAUSED_REASONS);
        table("mother_activity", MOTHER_ACTIVITIES);
        table("agent_class", AGENT_CLASSES);
        assert_eq!(fixture["mother_reason_default"], MOTHER_REASON_DEFAULT);
        assert_eq!(fixture["agent_fallback"], AGENT_FALLBACK);
    }
}
