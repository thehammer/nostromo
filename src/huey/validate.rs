//! Every deterministic rule a `huey.publish_report` call must pass (A4).
//!
//! [`validate`] names every problem it finds, not just the first, so the model
//! can fix them all in one more attempt. Messages quote only ids (escaped and
//! capped, as picks does) and caps: never news text, digest text or anything
//! else the model could be made to echo.
//!
//! An accepted publish comes back normalised: an Also-in-the-news item the
//! model also put in Also noted "moves up" and leaves Also noted (AC43).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::data::work::picks::shown_ids;
use crate::huey::checks::{CheckResult, Probe};
use crate::huey::interests::InterestSection;
use crate::huey::render::{self, words};
use crate::huey::run::{CurateInput, Publish, PublishCheck};

/// Also-noted lines per report (AC6); none in tight mode (AC32).
pub const MAX_NOTED: usize = 5;
/// Words in the whole rendered report, footer included (AC8, D2).
pub const MAX_REPORT_WORDS: usize = 600;
/// A quiet report's body (no picks) must stay under this (AC9, D2).
pub const QUIET_BODY_WORDS: usize = 150;
/// Words in the Also-in-the-news line: headline plus what happened (AC8).
pub const MAX_AIN_WORDS: usize = 40;

/// Which rule a problem broke.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Rule {
    TooManyPicks,
    TooManyNoted,
    PickMissingField,
    UnknownItem,
    DuplicateItem,
    IgnoredUsed,
    UnknownProject,
    BadAnchor,
    CheckedWithoutEvidence,
    CheckContradicts,
    SecondToCheck,
    BadInterest,
    AinNotEligible,
    AinIsPick,
    AinNamesProject,
    AinTooLong,
    AinSkipWithoutReason,
    TooManyWords,
    QuietBodyTooLong,
    FollowUpUnknown,
    FollowUpWithoutWhatsNew,
}

/// One reason a publish was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub rule: Rule,
    pub message: String,
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// An id as a message may quote it.
fn shown(id: &str) -> String {
    shown_ids(&[id.to_string()])
}

/// Where a story was used, for the duplicate rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Place {
    Pick(usize),
    Ain,
    Noted(usize),
}

impl fmt::Display for Place {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Place::Pick(n) => write!(f, "pick {}", n + 1),
            Place::Ain => f.write_str("Also in the news"),
            Place::Noted(n) => write!(f, "Also noted {}", n + 1),
        }
    }
}

/// What the rules are checked against, worked out once per publish.
struct Facts<'a> {
    input: &'a CurateInput,
    checks: &'a [CheckResult],
    /// Item id → the candidate story (cluster index) it belongs to.
    story_of: BTreeMap<&'a str, usize>,
    ain_ids: BTreeSet<&'a str>,
    /// Ids of "What I care about" and "Want more of" bullets.
    allowed_interests: BTreeSet<&'a str>,
    recent_ids: BTreeSet<&'a str>,
}

impl<'a> Facts<'a> {
    fn new(input: &'a CurateInput, checks: &'a [CheckResult]) -> Self {
        let story_of = input
            .candidates
            .iter()
            .enumerate()
            .flat_map(|(n, c)| c.items.iter().map(move |i| (i.id.as_str(), n)))
            .collect();
        let allowed_interests = input
            .digest
            .interests
            .bullets
            .iter()
            .filter(|b| matches!(b.section, InterestSection::Care | InterestSection::WantMore))
            .map(|b| b.id.as_str())
            .collect();
        Self {
            input,
            checks,
            story_of,
            ain_ids: input.ain_candidates.iter().map(|i| i.id.as_str()).collect(),
            allowed_interests,
            recent_ids: input
                .recent_shown
                .iter()
                .map(|e| e.item_id.as_str())
                .collect(),
        }
    }

    fn is_candidate(&self, id: &str) -> bool {
        self.story_of.contains_key(id)
    }

    /// The story an id stands for: its candidate cluster, else the id itself.
    fn story(&self, id: &str) -> String {
        match self.story_of.get(id) {
            Some(n) => format!("#{n}"),
            None => format!("={id}"),
        }
    }

    fn project_anchors(&self, project: &str) -> Option<&BTreeSet<String>> {
        self.input.digest.project_anchors.get(project)
    }
}

/// Check `publish` against every rule. `checks` are this run's check results.
/// `Ok` is the publish as it will be rendered (Also-in-the-news moved up out
/// of Also noted); `Err` lists every problem.
pub fn validate(
    input: &CurateInput,
    publish: &Publish,
    checks: &[CheckResult],
) -> Result<Publish, Vec<Problem>> {
    let facts = Facts::new(input, checks);
    let mut problems: Vec<Problem> = Vec::new();
    let mut add = |rule: Rule, message: String| problems.push(Problem { rule, message });

    caps(input, publish, &mut add);
    for (n, pick) in publish.picks.iter().enumerate() {
        pick_rules(&facts, n, pick, &mut add);
    }
    if publish
        .picks
        .iter()
        .filter(|p| matches!(p.check, PublishCheck::ToCheck { .. }))
        .count()
        > 1
    {
        add(
            Rule::SecondToCheck,
            "at most one pick may end in \"To check\"; make the others Checked (cite a check or a how-it-runs fact) or move them to Also noted".into(),
        );
    }
    noted_rules(&facts, publish, &mut add);
    let normalised = id_rules(&facts, publish, &mut add);
    ain_rules(&facts, publish, &mut add);
    drop_and_ignore_rules(&facts, publish, &mut add);
    word_rules(input, &normalised, &mut add);

    if problems.is_empty() {
        Ok(normalised)
    } else {
        Err(problems)
    }
}

fn caps(input: &CurateInput, publish: &Publish, add: &mut impl FnMut(Rule, String)) {
    if publish.picks.len() > input.max_picks {
        add(
            Rule::TooManyPicks,
            format!(
                "at most {} picks today; got {}",
                input.max_picks,
                publish.picks.len()
            ),
        );
    }
    let max_noted = if input.also_noted { MAX_NOTED } else { 0 };
    if publish.also_noted.len() > max_noted {
        add(
            Rule::TooManyNoted,
            if input.also_noted {
                format!(
                    "at most {MAX_NOTED} Also noted lines; got {}",
                    publish.also_noted.len()
                )
            } else {
                "no Also noted lines today (budget is tight); move them to dropped".into()
            },
        );
    }
}

fn blank(text: &str) -> bool {
    text.trim().is_empty()
}

fn pick_rules(
    facts: &Facts<'_>,
    n: usize,
    pick: &crate::huey::run::PublishPick,
    add: &mut impl FnMut(Rule, String),
) {
    let which = format!("pick {}", n + 1);
    let check_text = match &pick.check {
        PublishCheck::Checked { text, .. } | PublishCheck::ToCheck { text } => text,
    };
    let missing: Vec<&str> = [
        ("item_ids", pick.item_ids.is_empty()),
        ("headline", blank(&pick.headline)),
        ("what_happened", blank(&pick.what_happened)),
        ("for_line", blank(&pick.for_line)),
        ("check.text", blank(check_text)),
    ]
    .into_iter()
    .filter_map(|(field, empty)| empty.then_some(field))
    .collect();
    if !missing.is_empty() {
        add(
            Rule::PickMissingField,
            format!("{which} is missing {}", missing.join(", ")),
        );
    }

    let unknown: Vec<String> = pick
        .item_ids
        .iter()
        .filter(|id| !facts.is_candidate(id))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        add(
            Rule::UnknownItem,
            format!(
                "{which} names items that are not candidates in this run: {}",
                shown_ids(&unknown)
            ),
        );
    }

    let project = pick.project.as_str();
    if !facts.input.digest.projects.iter().any(|p| p == project) {
        add(
            Rule::UnknownProject,
            format!(
                "{which}: {} is not a project in the digest (use an id from \"Projects in flight\")",
                shown(project)
            ),
        );
        return;
    }
    let none = BTreeSet::new();
    let own = facts.project_anchors(project).unwrap_or(&none);
    anchor_rules(facts, &which, project, own, &pick.anchors, add);
    if let PublishCheck::Checked {
        check_ids,
        facts: f,
        ..
    } = &pick.check
    {
        checked_rules(facts, &which, project, check_ids, f, add);
    }
    if let Some(of) = &pick.follow_up_of {
        if !facts.recent_ids.contains(of.as_str()) {
            add(
                Rule::FollowUpUnknown,
                format!(
                    "{which}: follow_up_of {} is not an item from the recent reports list",
                    shown(of)
                ),
            );
        }
        if pick.whats_new.as_deref().is_none_or(blank) {
            add(
                Rule::FollowUpWithoutWhatsNew,
                format!("{which} is a follow-up: say what is new in whats_new"),
            );
        }
    }
}

fn anchor_rules(
    facts: &Facts<'_>,
    which: &str,
    project: &str,
    own: &BTreeSet<String>,
    anchors: &[String],
    add: &mut impl FnMut(Rule, String),
) {
    let digest = &facts.input.digest;
    if anchors.is_empty() {
        add(
            Rule::BadAnchor,
            format!("{which} needs at least one anchor id from {}'s lines in the digest; a story with no concrete anchor belongs in Also noted", shown(project)),
        );
        return;
    }
    let unknown: Vec<String> = anchors
        .iter()
        .filter(|a| !digest.anchors.contains(*a))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        add(
            Rule::BadAnchor,
            format!(
                "{which} names anchors that are not in the digest: {}",
                shown_ids(&unknown)
            ),
        );
    }
    let foreign: Vec<String> = anchors
        .iter()
        .filter(|a| {
            digest
                .project_anchors
                .iter()
                .any(|(p, set)| p != project && set.contains(*a))
        })
        .cloned()
        .collect();
    if !foreign.is_empty() {
        add(
            Rule::BadAnchor,
            format!(
                "{which} is for {} but names other projects' anchors: {}",
                shown(project),
                shown_ids(&foreign)
            ),
        );
    }
    if !anchors.iter().any(|a| own.contains(a)) {
        add(
            Rule::BadAnchor,
            format!(
                "{which} names none of {}'s own anchors; cite the concrete line it affects",
                shown(project)
            ),
        );
    }
}

fn checked_rules(
    facts: &Facts<'_>,
    which: &str,
    project: &str,
    check_ids: &[String],
    fact_ids: &[String],
    add: &mut impl FnMut(Rule, String),
) {
    let how = format!("{project}:how");
    let mut valid = 0usize;
    let mut bad: Vec<String> = Vec::new();
    for id in check_ids {
        match facts.checks.iter().find(|c| &c.id == id) {
            Some(c) if c.project == project => {
                valid += 1;
                if matches!(c.probe, Probe::Dependency { .. }) && !c.found {
                    add(
                        Rule::CheckContradicts,
                        format!(
                            "{which} cites {}, which found the dependency is not used, so the project is not affected; drop it or make it Also noted",
                            shown(id)
                        ),
                    );
                }
            }
            _ => bad.push(id.clone()),
        }
    }
    for id in fact_ids {
        if id == &how && facts.input.digest.anchors.contains(id) {
            valid += 1;
        } else {
            bad.push(id.clone());
        }
    }
    if !bad.is_empty() {
        add(
            Rule::CheckedWithoutEvidence,
            format!(
                "{which} cites what is not a check of {} from this run nor its how-it-runs fact ({}): {}",
                shown(project),
                shown(&how),
                shown_ids(&bad)
            ),
        );
    } else if valid == 0 {
        add(
            Rule::CheckedWithoutEvidence,
            format!(
                "{which} says Checked but cites nothing: add a check_ids entry (call huey.check_project) or the fact {}, or make it To check",
                shown(&how)
            ),
        );
    }
}

fn noted_rules(facts: &Facts<'_>, publish: &Publish, add: &mut impl FnMut(Rule, String)) {
    for (n, noted) in publish.also_noted.iter().enumerate() {
        let which = format!("Also noted {}", n + 1);
        if noted.item_ids.is_empty() {
            add(Rule::UnknownItem, format!("{which} names no item"));
        }
        let unknown: Vec<String> = noted
            .item_ids
            .iter()
            .filter(|id| !facts.is_candidate(id))
            .cloned()
            .collect();
        if !unknown.is_empty() {
            add(
                Rule::UnknownItem,
                format!(
                    "{which} names items that are not candidates in this run: {}",
                    shown_ids(&unknown)
                ),
            );
        }
        if !facts.allowed_interests.contains(noted.interest.as_str()) {
            add(
                Rule::BadInterest,
                format!(
                    "{which}: interest {} is not a \"What I care about\" or \"Want more of\" id",
                    shown(&noted.interest)
                ),
            );
        }
    }
}

/// The one-story-one-place rule over picks, Also in the news and Also noted.
/// Returns the publish with an Also-in-the-news item moved up out of Also noted.
fn id_rules(facts: &Facts<'_>, publish: &Publish, add: &mut impl FnMut(Rule, String)) -> Publish {
    let mut normalised = publish.clone();
    let ain_story = publish
        .also_in_the_news
        .as_ref()
        .map(|a| facts.story(&a.item_id));
    // Also noted lines that only repeat the Also-in-the-news story move up.
    normalised.also_noted.retain(|n| {
        !(ain_story.is_some()
            && n.item_ids
                .iter()
                .any(|id| Some(facts.story(id)) == ain_story))
    });

    // Story → where it was first used, and by which id.
    let mut used: BTreeMap<String, (Place, String)> = BTreeMap::new();
    let mut dupes: Vec<String> = Vec::new();
    let mut claim =
        |used: &mut BTreeMap<String, (Place, String)>, place: Place, id: &str| match used
            .get(&facts.story(id))
        {
            Some((p, _)) if *p == place => {}
            Some((p, first)) => dupes.push(format!(
                "{} ({place}) is the same story as {} ({p})",
                shown(id),
                shown(first)
            )),
            None => {
                used.insert(facts.story(id), (place, id.to_string()));
            }
        };
    for (n, p) in normalised.picks.iter().enumerate() {
        for id in &p.item_ids {
            claim(&mut used, Place::Pick(n), id);
        }
    }
    // An Also-in-the-news item that is a pick is its own rule.
    if let Some(a) = &normalised.also_in_the_news {
        if !matches!(
            used.get(&facts.story(&a.item_id)),
            Some((Place::Pick(_), _))
        ) {
            claim(&mut used, Place::Ain, &a.item_id);
        }
    }
    for (n, noted) in normalised.also_noted.iter().enumerate() {
        for id in &noted.item_ids {
            claim(&mut used, Place::Noted(n), id);
        }
    }
    if !dupes.is_empty() {
        add(
            Rule::DuplicateItem,
            format!("each story may appear once: {}", dupes.join("; ")),
        );
    }
    normalised
}

fn ain_rules(facts: &Facts<'_>, publish: &Publish, add: &mut impl FnMut(Rule, String)) {
    let ignored: BTreeSet<&str> = publish.ignored.iter().map(String::as_str).collect();
    let pick_stories: BTreeSet<String> = publish
        .picks
        .iter()
        .flat_map(|p| p.item_ids.iter())
        .map(|id| facts.story(id))
        .collect();
    let pick_ids: BTreeSet<&str> = publish
        .picks
        .iter()
        .flat_map(|p| p.item_ids.iter())
        .map(String::as_str)
        .collect();
    let Some(ain) = &publish.also_in_the_news else {
        let open = facts
            .ain_ids
            .iter()
            .any(|id| !pick_ids.contains(id) && !ignored.contains(id));
        if open && publish.ain_skip_reason.as_deref().is_none_or(blank) {
            add(
                Rule::AinSkipWithoutReason,
                "choose an Also-in-the-news line from its candidates, or, only when every candidate is a minor fix, set ain_skip_reason".into(),
            );
        }
        return;
    };
    let id = ain.item_id.as_str();
    if !facts.ain_ids.contains(id) || ignored.contains(id) {
        add(
            Rule::AinNotEligible,
            format!(
                "Also in the news: {} is not one of its candidates",
                shown(id)
            ),
        );
    }
    if pick_ids.contains(id) || pick_stories.contains(&facts.story(id)) {
        add(
            Rule::AinIsPick,
            format!("Also in the news: {} is already a pick", shown(id)),
        );
    }
    let text = format!("{} {}", ain.headline, ain.what_happened);
    let named: Vec<String> = project_terms(facts)
        .into_iter()
        .filter(|term| names_word(&text, term))
        .collect();
    if !named.is_empty() {
        add(
            Rule::AinNamesProject,
            format!(
                "Also in the news is not tied to your work: remove the project names {}",
                shown_ids(&named)
            ),
        );
    }
    let n = words(&ain.headline) + words(&ain.what_happened);
    if n > MAX_AIN_WORDS {
        add(
            Rule::AinTooLong,
            format!("Also in the news is {n} words; at most {MAX_AIN_WORDS}"),
        );
    }
}

/// The digest's project ids and names.
fn project_terms(facts: &Facts<'_>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for id in &facts.input.digest.projects {
        out.insert(id.clone());
        if let Some(name) = facts.input.frame.project_names.get(id) {
            out.insert(name.clone());
        }
    }
    out.retain(|t| !t.trim().is_empty());
    out
}

/// Does `text` mention `term` as a whole word, ignoring case?
fn names_word(text: &str, term: &str) -> bool {
    let text = text.to_lowercase();
    let term = term.to_lowercase();
    let is_word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
    text.match_indices(&term).any(|(at, m)| {
        !is_word(text[..at].chars().next_back()) && !is_word(text[at + m.len()..].chars().next())
    })
}

fn drop_and_ignore_rules(facts: &Facts<'_>, publish: &Publish, add: &mut impl FnMut(Rule, String)) {
    let known = |id: &str| facts.is_candidate(id) || facts.ain_ids.contains(id);
    let shown_ids_set: BTreeSet<&str> = publish
        .picks
        .iter()
        .flat_map(|p| p.item_ids.iter())
        .chain(publish.also_in_the_news.iter().map(|a| &a.item_id))
        .chain(publish.also_noted.iter().flat_map(|n| n.item_ids.iter()))
        .map(String::as_str)
        .collect();

    let unknown: Vec<String> = publish
        .dropped
        .iter()
        .map(|d| &d.item_id)
        .chain(publish.ignored.iter())
        .filter(|id| !known(id))
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if !unknown.is_empty() {
        add(
            Rule::UnknownItem,
            format!(
                "dropped or ignored items that are not candidates in this run: {}",
                shown_ids(&unknown)
            ),
        );
    }
    let dropped_and_shown: Vec<String> = publish
        .dropped
        .iter()
        .map(|d| d.item_id.clone())
        .filter(|id| shown_ids_set.contains(id.as_str()))
        .collect();
    if !dropped_and_shown.is_empty() {
        add(
            Rule::DuplicateItem,
            format!(
                "an item shown in the report cannot also be dropped: {}",
                shown_ids(&dropped_and_shown)
            ),
        );
    }
    // The Also-in-the-news line has its own rule for an ignored item.
    let ain = publish
        .also_in_the_news
        .as_ref()
        .map(|a| a.item_id.as_str());
    let ignored_used: Vec<String> = publish
        .ignored
        .iter()
        .filter(|id| shown_ids_set.contains(id.as_str()) && Some(id.as_str()) != ain)
        .cloned()
        .collect();
    if !ignored_used.is_empty() {
        add(
            Rule::IgnoredUsed,
            format!(
                "items judged under Ignore entirely may only be dropped: {}",
                shown_ids(&ignored_used)
            ),
        );
    }
}

fn word_rules(input: &CurateInput, publish: &Publish, add: &mut impl FnMut(Rule, String)) {
    let counts = render::word_counts(&input.render(publish));
    if counts.total > MAX_REPORT_WORDS {
        add(
            Rule::TooManyWords,
            format!(
                "the report renders to {} words; at most {MAX_REPORT_WORDS}, footer included: shorten or cut",
                counts.total
            ),
        );
    }
    if publish.picks.is_empty() && counts.body >= QUIET_BODY_WORDS {
        add(
            Rule::QuietBodyTooLong,
            format!(
                "a report with no picks must stay under {QUIET_BODY_WORDS} words before the footer; it is {}",
                counts.body
            ),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_name_counts_only_as_a_whole_word() {
        assert!(names_word("Nostromo ships today", "nostromo"));
        assert!(names_word("the (nostromo) app", "Nostromo"));
        assert!(!names_word("nostromos ships", "nostromo"));
        assert!(!names_word("mothership", "mother"));
        assert!(names_word("a mother-board", "mother"));
    }
}
