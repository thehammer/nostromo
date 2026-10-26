//! Behavioural tests for Huey H5-3: the publish validator.
//!
//! `validate(input, publish, checks)` is the gate between what the model
//! sends through `huey.publish_report` and what becomes a report. It returns
//! the normalised publish, or every problem found (not just the first) so the
//! model can fix them all in one go.
//!
//! Every test starts from a publish that is known to be valid for the
//! fixture input, changes one thing, and asserts that the validator names
//! the matching rule. The fixture is built by hand (a few news items, a
//! digest of two projects with interests, a frame); nothing here touches
//! the disk, the network or a model.
//!
//! Fixture cast (all ids are issued by "the daemon" of this test):
//! - candidate stories `vendor-news:a1` .. `a12` (first party, one each),
//!   one cluster of a release `vendor-news:rel` with a blog post
//!   `blog:rel-post` that links to it, a blog item `blog:b1` and a forum
//!   item `forum:f1`;
//! - Also-in-the-news eligible items `vendor-news:n1`, `n2` and `a7`;
//! - projects `alpha` and `beta` (named "Alpha" and "Brightwater");
//! - interests `i1` care, `i2` want more, `i3` want less, `i4` ignore;
//! - checks `c1` (alpha text, found), `c2` (alpha dependency, found), `c3`
//!   (alpha dependency, NOT found), `c4` (beta text, found);
//! - a story shown last week: `vendor-news:old1`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use chrono::{DateTime, NaiveDate, TimeZone, Utc};

use nostromo::huey::budget::Mode;
use nostromo::huey::checks::{CheckResult, Probe};
use nostromo::huey::context::collectors::{PrRecord, PrState};
use nostromo::huey::context::digest::{build_digest, DigestInputs, ProjectContext};
use nostromo::huey::interests;
use nostromo::huey::items::{cluster, NewsItem, SourceClass};
use nostromo::huey::render::{self, Footer};
use nostromo::huey::run::{
    CurateInput, Publish, PublishAin, PublishCheck, PublishDrop, PublishNoted, PublishPick,
    ReportFrame,
};
use nostromo::huey::store::{LedgerEntry, Section};
use nostromo::huey::validate::{validate, Problem, Rule};

// ── The fixture ──────────────────────────────────────────────────────────────

fn at(day: u32, hour: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, day, hour, 0, 0).unwrap()
}

fn oct(day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, day).unwrap()
}

fn item(
    source: &str,
    key: &str,
    class: SourceClass,
    title: &str,
    links: &[&str],
    hour: u32,
) -> NewsItem {
    let url = format!("https://{source}.example.test/{key}");
    NewsItem {
        id: format!("{source}:{key}"),
        source_id: source.into(),
        class,
        title: title.into(),
        canonical_url: url.clone(),
        url,
        published_at: Some(at(26, hour)),
        first_seen_at: at(26, hour),
        text: String::new(),
        outbound_links: links.iter().map(|l| l.to_string()).collect(),
    }
}

fn first_party(key: &str, title: &str, hour: u32) -> NewsItem {
    item(
        "vendor-news",
        key,
        SourceClass::FirstParty,
        title,
        &[],
        hour,
    )
}

const INTERESTS: &str = "\
# Huey interests

## What I care about, and why
- **Agent harnesses**: how they run unattended.

## Want more of
- Practical write-ups with real benchmarks.

## Want less of
- Funding announcements.

## Ignore entirely
- Cryptocurrency price chatter.
";

fn project(id: &str, name: &str, pr_number: u64) -> ProjectContext {
    ProjectContext {
        id: id.into(),
        name: name.into(),
        root: PathBuf::from("/nonexistent/fixture").join(id),
        how_it_runs: "A small command line tool.".into(),
        prs: vec![PrRecord {
            repo: id.into(),
            number: pr_number,
            title: "Tidy the options".into(),
            state: PrState::Open,
            at: at(25, 10),
        }],
        boards: Vec::new(),
        jobs: Vec::new(),
        commits: Vec::new(),
        last_activity: at(25, 12),
    }
}

fn check(id: &str, project: &str, probe: Probe, found: bool) -> CheckResult {
    CheckResult {
        id: id.into(),
        project: project.into(),
        probe,
        found,
        detail: if found { "found" } else { "not found" }.into(),
        paths: Vec::new(),
    }
}

struct Fx {
    _tmp: tempfile::TempDir,
    input: CurateInput,
    checks: Vec<CheckResult>,
}

impl Fx {
    fn validate(&self, publish: &Publish) -> Result<Publish, Vec<Problem>> {
        validate(&self.input, publish, &self.checks)
    }

    fn total_words(&self, publish: &Publish) -> usize {
        render::word_counts(&self.input.render(publish)).total
    }

    fn body_words(&self, publish: &Publish) -> usize {
        render::word_counts(&self.input.render(publish)).body
    }
}

fn fixture(mode: Mode) -> Fx {
    let tight = mode == Mode::Tight;
    let tmp = tempfile::tempdir().unwrap();

    let mut candidate_items: Vec<NewsItem> = (1..=12)
        .map(|n| first_party(&format!("a{n}"), &format!("Gizmo story {n}"), 3))
        .collect();
    let release = item(
        "vendor-news",
        "rel",
        SourceClass::FirstParty,
        "Gizmo 9 released",
        &[],
        4,
    );
    let post = item(
        "blog",
        "rel-post",
        SourceClass::Curated,
        "Hands on with Gizmo 9",
        &[&release.url],
        5,
    );
    candidate_items.push(release);
    candidate_items.push(post);
    candidate_items.push(item(
        "blog",
        "b1",
        SourceClass::Curated,
        "Notes on batching",
        &[],
        6,
    ));
    candidate_items.push(item(
        "forum",
        "f1",
        SourceClass::Aggregator,
        "Roundup of gizmo links",
        &[],
        7,
    ));
    let candidates = cluster(&candidate_items);

    let ain_candidates = vec![
        first_party("n1", "Vendor SDK update", 2),
        first_party("n2", "Vendor docs refresh", 2),
        // Also a candidate story: first-party items may be both.
        candidate_items
            .iter()
            .find(|i| i.id == "vendor-news:a7")
            .unwrap()
            .clone(),
    ];

    let parsed = interests::parse(INTERESTS);
    let digest = build_digest(&DigestInputs {
        machine: "Testbox".into(),
        date: oct(26),
        version: 1,
        mode: None,
        interests: parsed,
        projects: vec![
            project("alpha", "Alpha", 1),
            project("beta", "Brightwater", 2),
        ],
        prs_available: true,
        posture: None,
        mother_queue: None,
        ideas: Vec::new(),
        todos: Vec::new(),
        notes: Vec::new(),
    });

    let mut items: BTreeMap<String, NewsItem> = BTreeMap::new();
    for i in candidate_items.iter().chain(&ain_candidates) {
        items.insert(i.id.clone(), i.clone());
    }
    let frame = ReportFrame {
        date: oct(26),
        version: 1,
        mode,
        clusters: candidates.clone(),
        items,
        source_names: BTreeMap::from([
            ("vendor-news".to_string(), "Vendor News".to_string()),
            ("blog".to_string(), "Practical Blog".to_string()),
            ("forum".to_string(), "Link Forum".to_string()),
        ]),
        project_names: BTreeMap::from([
            ("alpha".to_string(), "Alpha".to_string()),
            ("beta".to_string(), "Brightwater".to_string()),
        ]),
        footer: Footer::default(),
    };

    let input = CurateInput {
        date: oct(26),
        version: 1,
        mode,
        model: "sonnet".into(),
        max_budget_usd: 3.0,
        max_picks: if tight { 3 } else { 5 },
        also_noted: !tight,
        digest,
        candidates,
        ain_candidates,
        recent_shown: vec![LedgerEntry {
            item_id: "vendor-news:old1".into(),
            canonical_url: "https://vendor-news.example.test/old1".into(),
            date: oct(20),
            version: 1,
            section: Section::Pick,
        }],
        project_roots: BTreeMap::new(),
        report_dir: tmp.path().to_path_buf(),
        frame,
    };
    let checks = vec![
        check(
            "c1",
            "alpha",
            Probe::Text {
                term: "retry".into(),
            },
            true,
        ),
        check(
            "c2",
            "alpha",
            Probe::Dependency {
                name: "serde".into(),
            },
            true,
        ),
        check(
            "c3",
            "alpha",
            Probe::Dependency {
                name: "leftpad".into(),
            },
            false,
        ),
        check(
            "c4",
            "beta",
            Probe::Text {
                term: "batch".into(),
            },
            true,
        ),
    ];
    Fx {
        _tmp: tmp,
        input,
        checks,
    }
}

// ── Building publishes ───────────────────────────────────────────────────────

fn vn(key: &str) -> String {
    format!("vendor-news:{key}")
}

/// A valid pick on `item_id` for `project`, citing one of the project's checks.
fn pick(item_id: &str, project: &str, check_id: &str) -> PublishPick {
    PublishPick {
        item_ids: vec![item_id.to_string()],
        headline: format!("Headline for {item_id}"),
        what_happened: "A thing happened.".into(),
        project: project.into(),
        for_line: "Worth a look.".into(),
        anchors: vec![format!("{project}:how")],
        check: PublishCheck::Checked {
            text: "Looked in the repository.".into(),
            check_ids: vec![check_id.to_string()],
            facts: Vec::new(),
        },
        follow_up_of: None,
        whats_new: None,
    }
}

fn noted(item_id: &str, interest: &str) -> PublishNoted {
    PublishNoted {
        item_ids: vec![item_id.to_string()],
        line: "A smaller thing.".into(),
        interest: interest.into(),
    }
}

fn ain(item_id: &str) -> PublishAin {
    PublishAin {
        item_id: item_id.into(),
        headline: "Vendor ships a new SDK".into(),
        what_happened: "The vendor released a new SDK version this week.".into(),
    }
}

fn drop_of(item_id: &str) -> PublishDrop {
    PublishDrop {
        item_id: item_id.into(),
        reason: "duplicate coverage".into(),
    }
}

/// A publish that is valid for the normal fixture: five picks (checks and a
/// fact as evidence), the news line, two noted lines, two drops and one
/// ignored id.
fn base() -> Publish {
    let mut p3 = pick(&vn("a3"), "alpha", "c1");
    p3.check = PublishCheck::Checked {
        text: "The overview says so.".into(),
        check_ids: Vec::new(),
        facts: vec!["alpha:how".into()],
    };
    Publish {
        opener_gist: "A busy morning for gizmos.".into(),
        picks: vec![
            pick(&vn("a1"), "alpha", "c1"),
            pick(&vn("a2"), "beta", "c4"),
            p3,
            pick(&vn("a4"), "beta", "c4"),
            pick(&vn("a5"), "alpha", "c2"),
        ],
        also_in_the_news: Some(ain(&vn("n1"))),
        ain_skip_reason: None,
        also_noted: vec![noted("blog:b1", "i1"), noted("forum:f1", "i2")],
        dropped: vec![drop_of(&vn("a11")), drop_of(&vn("n2"))],
        ignored: vec![vn("a12")],
    }
}

/// A publish that is valid for the tight fixture.
fn tight_base() -> Publish {
    Publish {
        opener_gist: "A short report.".into(),
        picks: vec![
            pick(&vn("a1"), "alpha", "c1"),
            pick(&vn("a2"), "beta", "c4"),
            pick(&vn("a3"), "alpha", "c2"),
        ],
        also_in_the_news: Some(ain(&vn("n1"))),
        also_noted: Vec::new(),
        dropped: vec![drop_of(&vn("a11"))],
        ignored: vec![vn("a12")],
        ..Publish::default()
    }
}

fn filler(words: usize) -> String {
    vec!["w"; words].join(" ")
}

// ── Reading results ──────────────────────────────────────────────────────────

fn rules(result: Result<Publish, Vec<Problem>>) -> Vec<Rule> {
    match result {
        Ok(_) => panic!("expected the validator to refuse the publish"),
        Err(problems) => problems.iter().map(|p| p.rule).collect(),
    }
}

fn problems(result: Result<Publish, Vec<Problem>>) -> Vec<Problem> {
    match result {
        Ok(_) => panic!("expected the validator to refuse the publish"),
        Err(problems) => problems,
    }
}

#[track_caller]
fn accepted(fx: &Fx, publish: &Publish) -> Publish {
    match fx.validate(publish) {
        Ok(p) => p,
        Err(problems) => panic!(
            "expected the publish to be accepted, got: {:?}",
            problems
                .iter()
                .map(|p| format!("{:?}: {}", p.rule, p.message))
                .collect::<Vec<_>>()
        ),
    }
}

/// Apply `change` to the normal base publish and expect `rule` among the
/// problems.
#[track_caller]
fn refuses(label: &str, rule: Rule, change: impl FnOnce(&mut Publish)) {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    change(&mut p);
    let found = rules(fx.validate(&p));
    assert!(
        found.contains(&rule),
        "{label}: expected {rule:?} among {found:?}"
    );
}

/// The messages of the problems of `rule`, joined.
fn messages_of(problems: &[Problem], rule: Rule) -> String {
    problems
        .iter()
        .filter(|p| p.rule == rule)
        .map(|p| p.message.clone())
        .collect::<Vec<_>>()
        .join(" | ")
}

// ═════════════════════════════════════════════════════════════════════════════
// The control: a full, valid publish
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_full_valid_publish_is_accepted() {
    let fx = fixture(Mode::Normal);
    let out = accepted(&fx, &base());
    assert_eq!(out.picks.len(), 5);
    assert_eq!(out.also_in_the_news.as_ref().unwrap().item_id, vn("n1"));
    assert_eq!(out.also_noted.len(), 2);
    assert_eq!(out.dropped.len(), 2);
}

#[test]
fn h5_3_a_valid_tight_publish_is_accepted() {
    let fx = fixture(Mode::Tight);
    let out = accepted(&fx, &tight_base());
    assert_eq!(out.picks.len(), 3);
    assert!(out.also_noted.is_empty());
}

#[test]
fn h5_3_a_publish_with_no_picks_and_no_news_line_is_accepted_when_nothing_is_eligible() {
    let mut fx = fixture(Mode::Normal);
    fx.input.ain_candidates.clear();
    let quiet = Publish {
        opener_gist: "A quiet day.".into(),
        ..Publish::default()
    };
    accepted(&fx, &quiet);
}

#[test]
fn h5_3_a_problem_displays_as_its_message() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].item_ids = vec!["vendor-news:ghost".into()];
    for problem in problems(fx.validate(&p)) {
        assert_eq!(problem.to_string(), problem.message);
        assert!(!problem.message.trim().is_empty());
    }
}

#[test]
fn h5_3_every_problem_is_reported_not_just_the_first() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].project = "gamma".into(); // UnknownProject
    p.picks[1].item_ids = vec!["vendor-news:ghost".into()]; // UnknownItem
    p.picks[2].headline = "  ".into(); // PickMissingField
    p.also_noted[0].interest = "i3".into(); // BadInterest
    let found = rules(fx.validate(&p));
    for rule in [
        Rule::UnknownProject,
        Rule::UnknownItem,
        Rule::PickMissingField,
        Rule::BadInterest,
    ] {
        assert!(found.contains(&rule), "{rule:?} missing from {found:?}");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Caps: picks and Also noted
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_six_picks_are_refused_and_the_message_names_the_cap() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks.push(pick(&vn("a6"), "alpha", "c1"));
    let found = problems(fx.validate(&p));
    assert!(found.iter().any(|x| x.rule == Rule::TooManyPicks));
    assert!(
        messages_of(&found, Rule::TooManyPicks).contains('5'),
        "{found:?}"
    );
}

#[test]
fn h5_3_five_picks_are_within_the_cap() {
    let fx = fixture(Mode::Normal);
    let out = accepted(&fx, &base());
    assert_eq!(out.picks.len(), fx.input.max_picks);
}

#[test]
fn h5_3_tight_four_picks_are_refused_and_the_message_names_three() {
    let fx = fixture(Mode::Tight);
    let mut p = tight_base();
    p.picks.push(pick(&vn("a4"), "beta", "c4"));
    let found = problems(fx.validate(&p));
    assert!(found.iter().any(|x| x.rule == Rule::TooManyPicks));
    assert!(
        messages_of(&found, Rule::TooManyPicks).contains('3'),
        "{found:?}"
    );
}

#[test]
fn h5_3_six_noted_lines_are_refused_and_the_message_names_the_cap() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_noted = [
        vn("a6"),
        vn("a7"),
        vn("a8"),
        vn("a9"),
        vn("a10"),
        "blog:b1".to_string(),
    ]
    .iter()
    .map(|id| noted(id, "i1"))
    .collect();
    let found = problems(fx.validate(&p));
    assert!(found.iter().any(|x| x.rule == Rule::TooManyNoted));
    assert!(
        messages_of(&found, Rule::TooManyNoted).contains('5'),
        "{found:?}"
    );
}

#[test]
fn h5_3_five_noted_lines_are_within_the_cap() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_noted = ["a6", "a7", "a8", "a9", "a10"]
        .iter()
        .map(|k| noted(&vn(k), "i1"))
        .collect();
    accepted(&fx, &p);
}

#[test]
fn h5_3_tight_mode_refuses_any_noted_line() {
    let fx = fixture(Mode::Tight);
    let mut p = tight_base();
    p.also_noted.push(noted("blog:b1", "i1"));
    assert!(rules(fx.validate(&p)).contains(&Rule::TooManyNoted));
}

// ═════════════════════════════════════════════════════════════════════════════
// Pick fields
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_pick_missing_a_field_is_refused() {
    refuses("empty headline", Rule::PickMissingField, |p| {
        p.picks[0].headline = String::new()
    });
    refuses("blank headline", Rule::PickMissingField, |p| {
        p.picks[0].headline = "   \t".into()
    });
    refuses("empty what_happened", Rule::PickMissingField, |p| {
        p.picks[1].what_happened = String::new()
    });
    refuses("empty for_line", Rule::PickMissingField, |p| {
        p.picks[2].for_line = " ".into()
    });
    refuses("empty item_ids", Rule::PickMissingField, |p| {
        p.picks[3].item_ids = Vec::new()
    });
    refuses("empty Checked text", Rule::PickMissingField, |p| {
        p.picks[4].check = PublishCheck::Checked {
            text: "  ".into(),
            check_ids: vec!["c2".into()],
            facts: Vec::new(),
        }
    });
    refuses("empty To check text", Rule::PickMissingField, |p| {
        p.picks[4].check = PublishCheck::ToCheck {
            text: String::new(),
        }
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// Item ids
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_an_item_id_the_run_never_issued_is_refused_wherever_it_appears() {
    let ghost = "vendor-news:ghost";
    refuses("pick", Rule::UnknownItem, |p| {
        p.picks[0].item_ids = vec![ghost.into()]
    });
    refuses(
        "pick with one good id and one ghost",
        Rule::UnknownItem,
        |p| p.picks[0].item_ids.push(ghost.into()),
    );
    refuses("noted", Rule::UnknownItem, |p| {
        p.also_noted[0].item_ids = vec![ghost.into()]
    });
    refuses("dropped", Rule::UnknownItem, |p| {
        p.dropped.push(drop_of(ghost))
    });
    refuses("ignored", Rule::UnknownItem, |p| {
        p.ignored.push(ghost.into())
    });
}

#[test]
fn h5_3_the_unknown_item_message_names_the_id() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].item_ids = vec!["vendor-news:ghost".into()];
    let found = problems(fx.validate(&p));
    assert!(
        messages_of(&found, Rule::UnknownItem).contains("vendor-news:ghost"),
        "{found:?}"
    );
}

#[test]
fn h5_3_dropped_and_ignored_ids_may_come_from_the_news_line_pool() {
    // n2 is only in the Also-in-the-news pool, not a candidate story. The
    // base publish drops it; ignoring it as well is fine.
    let fx = fixture(Mode::Normal);
    let mut p = base();
    assert!(p.dropped.iter().any(|d| d.item_id == vn("n2")));
    p.ignored.push(vn("n2"));
    accepted(&fx, &p);
}

#[test]
fn h5_3_a_news_line_item_outside_the_eligible_set_is_refused() {
    // A candidate story that is not first party is not eligible.
    refuses("a blog item", Rule::AinNotEligible, |p| {
        p.also_in_the_news = Some(ain("blog:b1"))
    });
    // A candidate story that simply is not in the pool.
    refuses("a candidate outside the pool", Rule::AinNotEligible, |p| {
        p.also_in_the_news = Some(ain(&vn("a9")))
    });
    // An id nobody issued.
    refuses("a ghost", Rule::AinNotEligible, |p| {
        p.also_in_the_news = Some(ain("vendor-news:ghost"))
    });
    // An eligible item the model also said to ignore.
    refuses("an ignored item", Rule::AinNotEligible, |p| {
        p.ignored.push(vn("n1"))
    });
}

#[test]
fn h5_3_the_news_line_may_be_an_item_that_is_also_a_candidate_story() {
    // a7 is in both pools and not picked.
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_in_the_news = Some(ain(&vn("a7")));
    accepted(&fx, &p);
}

// ═════════════════════════════════════════════════════════════════════════════
// The same story twice
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_the_same_story_in_two_places_is_refused() {
    refuses("two picks, same id", Rule::DuplicateItem, |p| {
        p.picks[1].item_ids = vec![vn("a1")]
    });
    refuses("pick and noted", Rule::DuplicateItem, |p| {
        p.also_noted[0].item_ids = vec![vn("a1")]
    });
    refuses("two noted lines, same id", Rule::DuplicateItem, |p| {
        p.also_noted[1].item_ids = p.also_noted[0].item_ids.clone()
    });
    refuses("pick and news line", Rule::DuplicateItem, |p| {
        p.picks[0].item_ids = vec![vn("n1")]
    });
    refuses("a pick and a drop", Rule::DuplicateItem, |p| {
        p.dropped.push(drop_of(&vn("a1")))
    });
    refuses("noted and a drop", Rule::DuplicateItem, |p| {
        p.dropped.push(drop_of("blog:b1"))
    });
    refuses("the news line and a drop", Rule::DuplicateItem, |p| {
        p.dropped.push(drop_of(&vn("n1")))
    });
}

#[test]
fn h5_3_two_members_of_one_story_in_two_places_are_refused() {
    // The release and the blog post about it are one story.
    refuses("pick and noted", Rule::DuplicateItem, |p| {
        p.picks[0].item_ids = vec![vn("rel")];
        p.also_noted[0].item_ids = vec!["blog:rel-post".into()];
    });
    refuses("two picks", Rule::DuplicateItem, |p| {
        p.picks[0].item_ids = vec![vn("rel")];
        p.picks[1].item_ids = vec!["blog:rel-post".into()];
    });
}

#[test]
fn h5_3_one_pick_may_cite_several_members_of_its_own_story() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].item_ids = vec![vn("rel"), "blog:rel-post".into()];
    accepted(&fx, &p);
}

#[test]
fn h5_3_the_duplicate_message_names_the_id() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[1].item_ids = vec![vn("a1")];
    let found = problems(fx.validate(&p));
    assert!(
        messages_of(&found, Rule::DuplicateItem).contains("vendor-news:a1"),
        "{found:?}"
    );
}

#[test]
fn h5_3_a_news_line_that_is_also_noted_moves_up_and_leaves_the_noted_list() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_noted.push(noted(&vn("n1"), "i1")); // n1 is the news line
    let out = accepted(&fx, &p);
    assert_eq!(out.also_in_the_news.as_ref().unwrap().item_id, vn("n1"));
    assert!(
        out.also_noted
            .iter()
            .all(|n| !n.item_ids.contains(&vn("n1"))),
        "the noted entry moved up: {:?}",
        out.also_noted
    );
    // The other noted lines are untouched.
    assert_eq!(out.also_noted.len(), 2);
    assert_eq!(out.picks, base().picks);
}

// ═════════════════════════════════════════════════════════════════════════════
// Ignored ids
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_an_ignored_id_used_in_the_report_is_refused() {
    refuses("ignored pick", Rule::IgnoredUsed, |p| {
        p.ignored.push(vn("a1"))
    });
    refuses("ignored noted", Rule::IgnoredUsed, |p| {
        p.ignored.push("blog:b1".into())
    });
    refuses(
        "ignored in a story the pick covers",
        Rule::IgnoredUsed,
        |p| {
            p.picks[0].item_ids = vec![vn("rel")];
            p.ignored.push(vn("rel"));
        },
    );
}

#[test]
fn h5_3_an_ignored_news_line_item_is_not_eligible() {
    refuses("ignored news line", Rule::AinNotEligible, |p| {
        p.ignored.push(vn("n1"))
    });
}

#[test]
fn h5_3_the_ignored_message_names_the_id() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.ignored.push(vn("a1"));
    let found = problems(fx.validate(&p));
    assert!(
        messages_of(&found, Rule::IgnoredUsed).contains("vendor-news:a1"),
        "{found:?}"
    );
}

#[test]
fn h5_3_an_item_may_be_both_ignored_and_dropped() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.dropped.push(drop_of(&vn("a12"))); // a12 is already ignored
    accepted(&fx, &p);
}

// ═════════════════════════════════════════════════════════════════════════════
// Projects and anchors
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_project_not_in_the_digest_is_refused_by_name() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].project = "gamma".into();
    let found = problems(fx.validate(&p));
    assert!(found.iter().any(|x| x.rule == Rule::UnknownProject));
    assert!(
        messages_of(&found, Rule::UnknownProject).contains("gamma"),
        "{found:?}"
    );
}

#[test]
fn h5_3_a_project_is_named_by_its_id_not_its_display_name() {
    refuses("display name", Rule::UnknownProject, |p| {
        p.picks[1].project = "Brightwater".into()
    });
    refuses("empty", Rule::UnknownProject, |p| {
        p.picks[1].project = String::new()
    });
}

#[test]
fn h5_3_a_pick_needs_anchors_from_its_own_project() {
    refuses("no anchors", Rule::BadAnchor, |p| {
        p.picks[0].anchors = Vec::new()
    });
    refuses("an anchor the digest never issued", Rule::BadAnchor, |p| {
        p.picks[0].anchors = vec!["alpha:nope".into()]
    });
    refuses("another project's anchor", Rule::BadAnchor, |p| {
        p.picks[0].anchors = vec!["beta:how".into()]
    });
    refuses(
        "an own anchor beside another project's",
        Rule::BadAnchor,
        |p| p.picks[0].anchors = vec!["alpha:how".into(), "beta:pr#2".into()],
    );
    refuses(
        "a valid anchor beside one the digest never issued",
        Rule::BadAnchor,
        |p| p.picks[0].anchors = vec!["alpha:how".into(), "alpha:nope".into()],
    );
    refuses(
        "only an anchor that belongs to no project",
        Rule::BadAnchor,
        |p| p.picks[0].anchors = vec!["i1".into()],
    );
}

#[test]
fn h5_3_a_pick_may_add_a_shared_anchor_to_one_from_its_own_project() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    // i1 is an interest line: in the digest, in no project.
    p.picks[0].anchors = vec!["alpha:how".into(), "i1".into(), "alpha:pr#1".into()];
    accepted(&fx, &p);
}

#[test]
fn h5_3_the_bad_anchor_message_names_the_anchor() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].anchors = vec!["alpha:nope".into(), "alpha:how".into()];
    let found = problems(fx.validate(&p));
    assert!(
        messages_of(&found, Rule::BadAnchor).contains("alpha:nope"),
        "{found:?}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// "Checked" needs evidence
// ═════════════════════════════════════════════════════════════════════════════

fn checked(check_ids: &[&str], facts: &[&str]) -> PublishCheck {
    PublishCheck::Checked {
        text: "Looked at it.".into(),
        check_ids: check_ids.iter().map(|s| s.to_string()).collect(),
        facts: facts.iter().map(|s| s.to_string()).collect(),
    }
}

#[test]
fn h5_3_checked_without_a_valid_citation_is_refused() {
    refuses("no citation at all", Rule::CheckedWithoutEvidence, |p| {
        p.picks[0].check = checked(&[], &[])
    });
    refuses("a check id nobody ran", Rule::CheckedWithoutEvidence, |p| {
        p.picks[0].check = checked(&["c99"], &[])
    });
    refuses(
        "another project's check",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&["c4"], &[]),
    );
    refuses(
        "a fact that is not the project's how-it-runs line",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&[], &["alpha:pr#1"]),
    );
    refuses(
        "another project's how-it-runs line",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&[], &["beta:how"]),
    );
    refuses(
        "a fact the digest never issued",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&[], &["alpha:nope"]),
    );
}

#[test]
fn h5_3_one_bad_citation_spoils_a_good_one() {
    refuses(
        "a good check beside a ghost check",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&["c1", "c99"], &[]),
    );
    refuses(
        "a good check beside a bad fact",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&["c1"], &["alpha:pr#1"]),
    );
    refuses(
        "a good fact beside a ghost check",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&["c99"], &["alpha:how"]),
    );
    refuses(
        "a good fact beside another project's check",
        Rule::CheckedWithoutEvidence,
        |p| p.picks[0].check = checked(&["c4"], &["alpha:how"]),
    );
}

#[test]
fn h5_3_checked_is_accepted_with_a_check_of_the_picks_project_or_its_how_it_runs_fact() {
    let fx = fixture(Mode::Normal);
    for check in [
        checked(&["c1"], &[]),
        checked(&["c1", "c2"], &[]),
        checked(&[], &["alpha:how"]),
        checked(&["c1"], &["alpha:how"]),
    ] {
        let mut p = base();
        p.picks[0].check = check.clone();
        accepted(&fx, &p);
    }
}

#[test]
fn h5_3_a_check_that_says_a_dependency_is_absent_contradicts_a_claim_that_it_is_used() {
    // c3: alpha has no dependency `leftpad`.
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].check = checked(&["c3"], &[]);
    let found = rules(fx.validate(&p));
    assert!(found.contains(&Rule::CheckContradicts), "{found:?}");
    // It is a citation, so it is not "without evidence" as well.
    assert!(!found.contains(&Rule::CheckedWithoutEvidence), "{found:?}");
    // The same project's dependency check that found the dependency is fine.
    let mut ok = base();
    ok.picks[0].check = checked(&["c2"], &[]);
    accepted(&fx, &ok);
}

// ═════════════════════════════════════════════════════════════════════════════
// At most one "To check"
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_second_to_check_pick_is_refused() {
    let to_check = |text: &str| PublishCheck::ToCheck { text: text.into() };
    let fx = fixture(Mode::Normal);

    let mut one = base();
    one.picks[0].check = to_check("Read the changelog.");
    accepted(&fx, &one);

    let mut two = base();
    two.picks[0].check = to_check("Read the changelog.");
    two.picks[3].check = to_check("Try it on a branch.");
    assert!(rules(fx.validate(&two)).contains(&Rule::SecondToCheck));
}

// ═════════════════════════════════════════════════════════════════════════════
// Also noted: interests
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_noted_line_needs_a_care_or_want_more_interest() {
    let fx = fixture(Mode::Normal);
    for interest in ["i1", "i2"] {
        let mut p = base();
        p.also_noted[0].interest = interest.into();
        accepted(&fx, &p);
    }
    for (label, interest) in [
        ("want less", "i3"),
        ("ignore", "i4"),
        ("unknown", "i99"),
        ("empty", ""),
        ("an anchor that is not an interest", "alpha:how"),
    ] {
        refuses(label, Rule::BadInterest, |p| {
            p.also_noted[0].interest = interest.into()
        });
    }
}

#[test]
fn h5_3_the_bad_interest_message_names_the_interest() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_noted[0].interest = "i3".into();
    let found = problems(fx.validate(&p));
    assert!(
        messages_of(&found, Rule::BadInterest).contains("i3"),
        "{found:?}"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The Also-in-the-news line
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_the_news_line_may_not_name_a_project() {
    for (label, headline, what) in [
        (
            "id in the headline",
            "Alpha ships a thing",
            "A new release.",
        ),
        (
            "id in the text",
            "Vendor ships a thing",
            "Useful for beta users.",
        ),
        (
            "display name in the headline",
            "Brightwater gets a feature",
            "A new release.",
        ),
        (
            "display name in the text",
            "Vendor ships a thing",
            "Works with Brightwater.",
        ),
        ("upper case", "ALPHA ships a thing", "A new release."),
        (
            "mixed case",
            "Vendor ships a thing",
            "Made for bRiGhTwAtEr.",
        ),
    ] {
        refuses(label, Rule::AinNamesProject, |p| {
            p.also_in_the_news = Some(PublishAin {
                item_id: vn("n1"),
                headline: headline.into(),
                what_happened: what.into(),
            })
        });
    }
}

#[test]
fn h5_3_a_project_name_inside_a_longer_word_is_not_a_mention() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.also_in_the_news = Some(PublishAin {
        item_id: vn("n1"),
        headline: "Alphabet soup of betamax tapes".into(),
        what_happened: "Nothing to do with any project.".into(),
    });
    accepted(&fx, &p);
}

#[test]
fn h5_3_the_news_line_is_capped_at_forty_words() {
    let fx = fixture(Mode::Normal);
    let line = |words_in_text: usize| PublishAin {
        item_id: vn("n1"),
        headline: "Vendor ships SDK".into(), // 3 words
        what_happened: filler(words_in_text),
    };
    let mut ok = base();
    ok.also_in_the_news = Some(line(37)); // 3 + 37 = 40
    accepted(&fx, &ok);

    let mut long = base();
    long.also_in_the_news = Some(line(38)); // 41
    assert!(rules(fx.validate(&long)).contains(&Rule::AinTooLong));
}

#[test]
fn h5_3_the_news_line_may_not_be_a_pick() {
    // a7 is in both pools.
    let mut p = base();
    p.picks[0].item_ids = vec![vn("a7")];
    p.also_in_the_news = Some(ain(&vn("a7")));
    let fx = fixture(Mode::Normal);
    assert!(rules(fx.validate(&p)).contains(&Rule::AinIsPick));
}

#[test]
fn h5_3_skipping_the_news_line_needs_a_reason_while_something_is_eligible() {
    let fx = fixture(Mode::Normal);
    let skip = |reason: Option<&str>| {
        let mut p = base();
        p.also_in_the_news = None;
        p.ain_skip_reason = reason.map(str::to_string);
        p
    };
    assert!(rules(fx.validate(&skip(None))).contains(&Rule::AinSkipWithoutReason));
    assert!(rules(fx.validate(&skip(Some("")))).contains(&Rule::AinSkipWithoutReason));
    assert!(rules(fx.validate(&skip(Some("   ")))).contains(&Rule::AinSkipWithoutReason));
    accepted(&fx, &skip(Some("Nothing new that is not already picked.")));
}

#[test]
fn h5_3_skipping_the_news_line_needs_no_reason_when_nothing_is_eligible() {
    // Nothing eligible at all.
    let mut fx = fixture(Mode::Normal);
    fx.input.ain_candidates.clear();
    let mut p = base();
    p.also_in_the_news = None;
    p.dropped.retain(|d| d.item_id != vn("n2"));
    accepted(&fx, &p);

    // Everything eligible is already a pick or ignored.
    let mut fx = fixture(Mode::Normal);
    fx.input
        .ain_candidates
        .retain(|i| i.id == vn("a7") || i.id == vn("n2"));
    let mut p = base();
    p.also_in_the_news = None;
    p.picks[0].item_ids = vec![vn("a7")];
    p.dropped.retain(|d| d.item_id != vn("n2"));
    p.ignored.push(vn("n2"));
    accepted(&fx, &p);
}

#[test]
fn h5_3_a_tight_report_keeps_the_news_line_rules() {
    let fx = fixture(Mode::Tight);
    let mut p = tight_base();
    p.also_in_the_news = None;
    assert!(rules(fx.validate(&p)).contains(&Rule::AinSkipWithoutReason));
    p.ain_skip_reason = Some("Nothing worth a line today.".into());
    accepted(&fx, &p);
}

// ═════════════════════════════════════════════════════════════════════════════
// Word caps
// ═════════════════════════════════════════════════════════════════════════════

/// `base()` with `n` extra one-letter words spread over the picks' "what
/// happened" paragraphs (at most 180 each, under the paragraph cap).
fn base_with_filler(n: usize) -> Publish {
    let mut p = base();
    let mut left = n;
    for pick in &mut p.picks {
        let k = left.min(180);
        if k > 0 {
            pick.what_happened = format!("{} {}", pick.what_happened, filler(k));
            left -= k;
        }
    }
    assert_eq!(left, 0, "the fixture cannot carry {n} filler words");
    p
}

#[test]
fn h5_3_a_report_over_six_hundred_words_is_refused() {
    let fx = fixture(Mode::Normal);
    let plain = fx.total_words(&base());
    assert!(plain < 600, "the base publish is {plain} words");

    let at_cap = base_with_filler(600 - plain);
    assert_eq!(fx.total_words(&at_cap), 600, "harness: tuned to the cap");
    accepted(&fx, &at_cap);

    let over = base_with_filler(601 - plain);
    assert_eq!(fx.total_words(&over), 601, "harness: one word over");
    let found = problems(fx.validate(&over));
    assert!(
        found.iter().any(|x| x.rule == Rule::TooManyWords),
        "{found:?}"
    );
}

/// A report with no picks, a news line, and `n` filler words spread over the
/// opener and two noted lines.
fn quiet_with_filler(n: usize) -> Publish {
    let mut left = n;
    let mut take = |cap: usize| {
        let k = left.min(cap);
        left -= k;
        k
    };
    let opener_words = take(90);
    let first_words = take(90);
    let second_words = take(90);
    assert_eq!(left, 0, "the fixture cannot carry {n} filler words");
    let with = |text: &str, k: usize| {
        if k == 0 {
            text.to_string()
        } else {
            format!("{text} {}", filler(k))
        }
    };
    Publish {
        opener_gist: with("Quiet.", opener_words),
        also_in_the_news: Some(ain(&vn("n1"))),
        also_noted: vec![
            PublishNoted {
                item_ids: vec!["blog:b1".into()],
                line: with("Noted.", first_words),
                interest: "i1".into(),
            },
            PublishNoted {
                item_ids: vec!["forum:f1".into()],
                line: with("Noted too.", second_words),
                interest: "i2".into(),
            },
        ],
        ..Publish::default()
    }
}

#[test]
fn h5_3_a_report_with_no_picks_keeps_its_body_under_a_hundred_and_fifty_words() {
    let fx = fixture(Mode::Normal);
    let plain = fx.body_words(&quiet_with_filler(0));
    assert!(plain < 149, "the quiet publish is {plain} body words");

    let under = quiet_with_filler(149 - plain);
    assert_eq!(fx.body_words(&under), 149, "harness: tuned under the cap");
    accepted(&fx, &under);

    let at_cap = quiet_with_filler(150 - plain);
    assert_eq!(fx.body_words(&at_cap), 150, "harness: tuned to the cap");
    assert!(rules(fx.validate(&at_cap)).contains(&Rule::QuietBodyTooLong));
}

#[test]
fn h5_3_the_footer_does_not_count_toward_the_quiet_body() {
    let mut fx = fixture(Mode::Normal);
    fx.input.frame.footer.in_flight = (0..30).map(|n| format!("project{n}")).collect();
    let counts = render::word_counts(&fx.input.render(&quiet_with_filler(0)));
    assert!(counts.footer >= 30, "harness: a long footer, {counts:?}");

    // A body one word under the cap stays accepted however long the footer is.
    let under = quiet_with_filler(149 - counts.body);
    let counts = render::word_counts(&fx.input.render(&under));
    assert_eq!(counts.body, 149, "harness: tuned under the cap");
    assert!(
        counts.total >= 150,
        "harness: the footer pushes the total over"
    );
    accepted(&fx, &under);
}

#[test]
fn h5_3_the_quiet_body_rule_does_not_apply_once_there_is_a_pick() {
    let fx = fixture(Mode::Normal);
    // Body well over 150 words, but five picks and under 600 in all.
    let p = base_with_filler(200);
    assert!(fx.body_words(&p) >= 150);
    accepted(&fx, &p);
}

// ═════════════════════════════════════════════════════════════════════════════
// Follow-ups
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_follow_up_must_name_an_item_shown_in_the_last_fourteen_days() {
    let fx = fixture(Mode::Normal);
    let mut ok = base();
    ok.picks[0].follow_up_of = Some(vn("old1"));
    ok.picks[0].whats_new = Some("A patch release landed since.".into());
    accepted(&fx, &ok);

    let mut unknown = base();
    unknown.picks[0].follow_up_of = Some(vn("never-shown"));
    unknown.picks[0].whats_new = Some("A patch release landed since.".into());
    let found = problems(fx.validate(&unknown));
    assert!(found.iter().any(|x| x.rule == Rule::FollowUpUnknown));
    assert!(
        messages_of(&found, Rule::FollowUpUnknown).contains("vendor-news:never-shown"),
        "{found:?}"
    );

    // An item of today's own candidates was not shown before.
    let mut today = base();
    today.picks[0].follow_up_of = Some(vn("a2"));
    today.picks[0].whats_new = Some("Something new.".into());
    assert!(rules(fx.validate(&today)).contains(&Rule::FollowUpUnknown));
}

#[test]
fn h5_3_a_follow_up_needs_a_whats_new_line() {
    let fx = fixture(Mode::Normal);
    for whats_new in [None, Some(String::new()), Some("  ".to_string())] {
        let mut p = base();
        p.picks[0].follow_up_of = Some(vn("old1"));
        p.picks[0].whats_new = whats_new;
        assert!(
            rules(fx.validate(&p)).contains(&Rule::FollowUpWithoutWhatsNew),
            "whats_new missing must be refused"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// One story per line, and no blank lines (review follow-ups)
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn h5_3_a_pick_naming_two_stories_is_refused() {
    // Packing stories into one pick would sidestep the cap and the
    // honest-pick rule (the second story gets no for_line or check).
    refuses("pick", Rule::MixedStories, |p| {
        p.picks[0].item_ids = vec![vn("a1"), vn("a6")]
    });
    refuses("also noted", Rule::MixedStories, |p| {
        p.also_noted[0].item_ids = vec!["blog:b1".into(), vn("a6")]
    });
}

#[test]
fn h5_3_the_mixed_story_message_names_the_ids() {
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].item_ids = vec![vn("a1"), vn("a6")];
    let found = problems(fx.validate(&p));
    let text = messages_of(&found, Rule::MixedStories);
    assert!(
        text.contains("vendor-news:a1") && text.contains("vendor-news:a6"),
        "{found:?}"
    );
}

#[test]
fn h5_3_a_blank_news_line_or_noted_line_is_refused() {
    refuses("blank news headline", Rule::LineMissingText, |p| {
        p.also_in_the_news.as_mut().unwrap().headline = "  ".into()
    });
    refuses("blank news what_happened", Rule::LineMissingText, |p| {
        p.also_in_the_news.as_mut().unwrap().what_happened = String::new()
    });
    refuses("blank noted line", Rule::LineMissingText, |p| {
        p.also_noted[0].line = " ".into()
    });
}

#[test]
fn h5_3_a_follow_up_is_judged_even_when_the_project_is_unknown() {
    // Every problem in one refusal: an unknown project does not hide the
    // follow-up problems, so the model does not spend an attempt finding them.
    let fx = fixture(Mode::Normal);
    let mut p = base();
    p.picks[0].project = "nowhere".into();
    p.picks[0].follow_up_of = Some("vendor-news:never-shown".into());
    let found = rules(fx.validate(&p));
    for rule in [
        Rule::UnknownProject,
        Rule::FollowUpUnknown,
        Rule::FollowUpWithoutWhatsNew,
    ] {
        assert!(found.contains(&rule), "{rule:?} among {found:?}");
    }
}
