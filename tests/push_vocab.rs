//! W13-1..6, W13-33, W13-36: what a push notification may say.
//!
//! The privacy boundary of the push feature. Every notification is built from a
//! closed vocabulary (the kind, the host name, a short reference and fixed
//! phrases and numbers Nostromo generates). No text a worker, an agent, a person
//! or GitHub wrote may reach the title or body, on any host, for any kind.
//!
//! The items here are derived the way the engine derives them
//! (`items::mother_items`, `review_items`, `decision_item`) from inputs whose
//! free-text fields each hold a `MARKER-...` string, then rendered with the
//! public renderers. The tests assert that no marker survives, that
//! `vocab::conforms` accepts what is rendered and REJECTS every marker injected
//! into it (it is an allow-list, not a deny-list), and that the strings are
//! exactly the PRD's (`docs/prds/push-relay.md`, "What a notification says").
//!
//! The whole-relay-request version of the marker property (the serialised POST
//! body) is in `tests/push_engine.rs`.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, TimeZone, Utc};
use nostromo::config::PushConfig;
use nostromo::data::perri_queue::PrQueueItem;
use nostromo::mother::MotherJob;
use nostromo::push::items::{decision_item, mother_items, review_items, DecisionFacts, Waiting};
use nostromo::push::vocab::{self, RenderContext, VocabContext};
use nostromo::push::wire::{AgentClass, HostClass, Presence};
use serde_json::{json, Value};

// ── fixtures ─────────────────────────────────────────────────────────────────

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 26, 12, 0, 0).unwrap()
}

/// Every string a worker, an agent, a person or GitHub could have written.
const MARKERS: &[&str] = &[
    "MARKER-question",
    "MARKER-title",
    "MARKER-plan",
    "MARKER-branch",
    "MARKER-repo",
    "MARKER-notes",
    "MARKER-activity-text",
    "MARKER-failure",
    "MARKER-label",
    "MARKER-focus",
    "MARKER-session",
    "MARKER-prompt",
    "MARKER-detail",
    "MARKER-choice-label",
    "MARKER-choice-detail",
    "MARKER-pr-title",
    "MARKER-author",
    "MARKER-owner",
    "MARKER-labels",
];

fn assert_no_marker(text: &str) {
    assert!(
        !text.to_ascii_lowercase().contains("marker"),
        "free text reached a notification: {text:?}"
    );
}

fn work_owners() -> Vec<String> {
    PushConfig::default().resolved_work_owners()
}

fn hosts_with(host: &str, class: Option<HostClass>) -> BTreeMap<String, HostClass> {
    let mut m = BTreeMap::new();
    if let Some(class) = class {
        m.insert(host.to_string(), class);
    }
    m
}

/// A Mother job whose every free-text field holds a marker. `paused_reason`,
/// `activity` and `pr_url` are the only fields the vocabulary may read.
fn marked_job(
    id: &str,
    paused_reason: Option<&str>,
    activity: Option<&str>,
    pr_url: Option<&str>,
) -> MotherJob {
    let mut v = json!({
        "id": id,
        "state": "awaiting",
        "title": "MARKER-title",
        "repo": "MARKER-repo",
        "plan_path": "/home/op/MARKER-plan.md",
        "question": "MARKER-question",
        "adherence_notes": "MARKER-notes",
        "current_activity": "MARKER-activity-text",
        "failure_reason": "MARKER-failure",
        "branch": "MARKER-branch",
        "isolation": "MARKER-isolation",
        "origin": {"label": "MARKER-label", "focus_name": "MARKER-focus", "session": "MARKER-session"},
    });
    let obj = v.as_object_mut().unwrap();
    if let Some(r) = paused_reason {
        obj.insert("paused_reason".into(), json!(r));
    }
    if let Some(a) = activity {
        obj.insert("activity".into(), json!(a));
    }
    if let Some(u) = pr_url {
        obj.insert("pr_url".into(), json!(u));
    }
    serde_json::from_value(v).expect("a Mother job")
}

fn job_id(suffix: &str) -> String {
    format!("20261101T120000Z-{suffix}")
}

fn mother_item(host: &str, job: MotherJob) -> Waiting {
    let mut items = mother_items(host, &[job]);
    assert_eq!(items.len(), 1, "one awaiting job is one item");
    items.remove(0)
}

fn marked_pr(repo: &str, number: u64, changed_lines: Option<u64>) -> PrQueueItem {
    PrQueueItem {
        repo: repo.into(),
        number,
        title: "MARKER-pr-title".into(),
        author: "MARKER-author".into(),
        bucket: "requested".into(),
        url: "https://github.com/MARKER-owner/MARKER-repo/pull/1".into(),
        tickets: vec!["MARKER-labels".into()],
        changed_lines,
        ..Default::default()
    }
}

fn review_item(host: &str, repo: &str, number: u64, changed_lines: Option<u64>) -> Waiting {
    let mut items = review_items(host, &[marked_pr(repo, number, changed_lines)]);
    assert_eq!(items.len(), 1);
    items.remove(0)
}

fn facts(
    agent: Option<AgentClass>,
    choices: usize,
    deadline: Option<DateTime<Utc>>,
    repo: Option<&str>,
    owner: Option<&str>,
) -> DecisionFacts {
    DecisionFacts {
        request_id: "req-1".into(),
        choices,
        deadline,
        agent,
        presence: Some(Presence::Active),
        repo: repo.map(str::to_string),
        owner: owner.map(str::to_string),
    }
}

fn decision(
    host: &str,
    agent: Option<AgentClass>,
    choices: usize,
    deadline: Option<DateTime<Utc>>,
    repo: Option<&str>,
    owner: Option<&str>,
) -> Waiting {
    decision_item(host, &facts(agent, choices, deadline, repo, owner), now())
}

/// Render an alert for `w` on a context with the given host classes.
fn alert(
    w: &Waiting,
    hosts: &BTreeMap<String, HostClass>,
    reviews_waiting: usize,
) -> (String, String) {
    let owners = work_owners();
    let reviews = BTreeMap::from([(w.host.clone(), reviews_waiting)]);
    let ctx = RenderContext {
        hosts,
        work_owners: &owners,
        reviews_waiting: &reviews,
        now: now(),
    };
    let r = vocab::render_alert(w, &ctx).expect("an alert");
    (r.title, r.body)
}

fn withdrawal(w: &Waiting, hosts: &BTreeMap<String, HostClass>) -> (String, String) {
    let owners = work_owners();
    let reviews = BTreeMap::new();
    let ctx = RenderContext {
        hosts,
        work_owners: &owners,
        reviews_waiting: &reviews,
        now: now(),
    };
    let r = vocab::render_withdrawal(w, &ctx).expect("a withdrawal");
    (r.title, r.body)
}

fn vctx(hosts: &[&str], repos: &[&str]) -> VocabContext {
    VocabContext {
        hosts: hosts.iter().map(|s| s.to_string()).collect(),
        repos: repos.iter().map(|s| s.to_string()).collect(),
    }
}

fn conforms(text: &str, ctx: &VocabContext) -> bool {
    vocab::conforms(text, ctx).is_ok()
}

// ── W13-1, W13-2: Mother ─────────────────────────────────────────────────────

/// The Mother reasons, each with how the job says it and the sentence it gets.
/// The PRD fixes the phrases and shows two sentences (`asked a question`,
/// `is blocked after review`); the others follow the same pattern.
type ReasonCase = (
    &'static str,
    Option<&'static str>,
    Option<&'static str>,
    &'static str,
);

fn mother_reasons() -> Vec<ReasonCase> {
    vec![
        ("user", Some("user"), None, "Job 3f9a1c2e asked a question"),
        (
            "adherence_blocked",
            Some("adherence_blocked"),
            None,
            "Job 3f9a1c2e is blocked after review",
        ),
        (
            "operator_hold",
            Some("operator_hold"),
            None,
            "Job 3f9a1c2e is held after a failure",
        ),
        (
            "cost_cap",
            Some("cost_cap"),
            None,
            "Job 3f9a1c2e is paused at its spend cap",
        ),
        (
            "pipeline_blocked (activity)",
            None,
            Some("pipeline_blocked"),
            "Job 3f9a1c2e is pipeline blocked",
        ),
        (
            "unknown",
            Some("MARKER-some-future-reason"),
            Some("MARKER-some-future-activity"),
            "Job 3f9a1c2e needs you",
        ),
    ]
}

#[test]
fn a_work_host_mother_job_says_only_kind_host_ref_and_reason() {
    // The PRD's example, with markers in question, title, plan, branch and repo.
    let job = marked_job(
        &job_id("3f9a1c2e"),
        Some("user"),
        None,
        Some("https://github.com/thehammer/bishop/pull/9"),
    );
    let item = mother_item("kobe", job);
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let (title, body) = alert(&item, &hosts, 0);
    assert_eq!(title, "Mother · kobe");
    assert_eq!(body, "Job 3f9a1c2e asked a question");
}

#[test]
fn an_unclassified_host_renders_exactly_like_a_work_host() {
    for (name, reason, activity, _) in mother_reasons() {
        for pr_url in [None, Some("https://github.com/thehammer/bishop/pull/9")] {
            let item = mother_item(
                "kobe",
                marked_job(&job_id("3f9a1c2e"), reason, activity, pr_url),
            );
            let work = alert(&item, &hosts_with("kobe", Some(HostClass::Work)), 0);
            let unclassified = alert(&item, &hosts_with("kobe", None), 0);
            assert_eq!(work, unclassified, "{name} / {pr_url:?}");
            assert_eq!(
                withdrawal(&item, &hosts_with("kobe", Some(HostClass::Work))),
                withdrawal(&item, &hosts_with("kobe", None)),
                "{name} / {pr_url:?}: withdrawal"
            );
        }
    }
}

#[test]
fn each_mother_reason_maps_to_its_phrase_and_an_unknown_one_to_needs_you() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    for (name, reason, activity, want) in mother_reasons() {
        let item = mother_item(
            "kobe",
            marked_job(&job_id("3f9a1c2e"), reason, activity, None),
        );
        let (title, body) = alert(&item, &hosts, 0);
        assert_eq!(title, "Mother · kobe", "{name}");
        assert_eq!(body, want, "{name}");
    }
}

#[test]
fn a_paused_reason_wins_over_the_activity() {
    // `user` with a pipeline_blocked activity is still a question to answer.
    let item = mother_item(
        "kobe",
        marked_job(
            &job_id("3f9a1c2e"),
            Some("user"),
            Some("pipeline_blocked"),
            None,
        ),
    );
    let (_, body) = alert(&item, &hosts_with("kobe", Some(HostClass::Work)), 0);
    assert_eq!(body, "Job 3f9a1c2e asked a question");
}

#[test]
fn a_quota_pause_produces_no_item() {
    for reason in ["quota_5h", "quota_weekly", "quota_"] {
        let job = marked_job(&job_id("3f9a1c2e"), Some(reason), None, None);
        assert!(job.is_awaiting());
        assert!(mother_items("kobe", &[job]).is_empty(), "{reason}");
    }
    // Also when the job is otherwise held for the operator (a gate hold).
    let job: MotherJob = serde_json::from_value(json!({
        "id": job_id("3f9a1c2e"), "state": "awaiting", "paused_reason": "quota_5h", "activity": "gate_hold",
    }))
    .unwrap();
    assert!(mother_items("kobe", &[job]).is_empty());
}

#[test]
fn a_personal_host_names_the_repository_only_when_its_owner_is_known_and_personal() {
    let personal = hosts_with("sendai", Some(HostClass::Personal));

    // Known personal owner (from the job's pr_url): the bare repository name.
    let with_owner = mother_item(
        "sendai",
        marked_job(
            &job_id("7c01d4aa"),
            Some("adherence_blocked"),
            None,
            Some("https://github.com/thehammer/bishop/pull/12"),
        ),
    );
    assert_eq!(
        alert(&with_owner, &personal, 0),
        (
            "Mother · sendai · bishop".into(),
            "Job 7c01d4aa is blocked after review".into()
        )
    );

    // A work owner (Carefeed), whatever the case: no name.
    for url in [
        "https://github.com/Carefeed/admin-portal/pull/4821",
        "https://github.com/carefeed/admin-portal/pull/4821",
    ] {
        let item = mother_item(
            "sendai",
            marked_job(
                &job_id("7c01d4aa"),
                Some("adherence_blocked"),
                None,
                Some(url),
            ),
        );
        assert_eq!(
            alert(&item, &personal, 0),
            (
                "Mother · sendai".into(),
                "Job 7c01d4aa is blocked after review".into()
            ),
            "{url}"
        );
    }

    // Only a bare repo name and no pr_url: the owner is unknown, which is a work owner.
    let bare = mother_item(
        "sendai",
        marked_job(&job_id("7c01d4aa"), Some("adherence_blocked"), None, None),
    );
    assert_eq!(
        alert(&bare, &personal, 0),
        (
            "Mother · sendai".into(),
            "Job 7c01d4aa is blocked after review".into()
        )
    );
}

#[test]
fn a_personal_owner_pr_url_shows_no_name_on_a_work_or_unclassified_host() {
    let job = marked_job(
        &job_id("7c01d4aa"),
        Some("user"),
        None,
        Some("https://github.com/thehammer/bishop/pull/12"),
    );
    for class in [Some(HostClass::Work), None] {
        let item = mother_item("kobe", job.clone());
        let (title, _) = alert(&item, &hosts_with("kobe", class), 0);
        assert_eq!(title, "Mother · kobe", "{class:?}");
    }
}

#[test]
fn a_job_with_an_unreadable_ref_is_named_a_job_not_by_its_id() {
    // The suffix must be 8 lowercase hex characters, else the job is just "A job".
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    for suffix in [
        "zzzzzzzz",
        "3F9A1C2E",
        "3f9a1c2",
        "3f9a1c2e0",
        "MARKER-x",
        "",
    ] {
        let item = mother_item(
            "kobe",
            marked_job(
                &format!("20261101T120000Z-{suffix}"),
                Some("user"),
                None,
                None,
            ),
        );
        let (title, body) = alert(&item, &hosts, 0);
        assert_eq!(title, "Mother · kobe", "{suffix:?}");
        assert_eq!(body, "A job asked a question", "{suffix:?}");
        let w = withdrawal(&item, &hosts);
        assert_eq!(w.1, "A job no longer needs you", "{suffix:?}");
    }
}

// ── W13-3: Decision ──────────────────────────────────────────────────────────

#[test]
fn a_decision_names_the_agent_the_choices_and_the_minutes_left() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let item = decision(
        "kobe",
        Some(AgentClass::Claudia),
        3,
        Some(now() + Duration::minutes(4) + Duration::seconds(59)),
        None,
        None,
    );
    assert_eq!(
        alert(&item, &hosts, 0),
        (
            "Decision · kobe".into(),
            "Claudia is waiting on you · 3 choices · times out in 4 min".into()
        )
    );
}

#[test]
fn a_decision_with_no_timeout_has_no_timeout_phrase() {
    let hosts = hosts_with("sendai", None);
    let item = decision("sendai", None, 2, None, None, None);
    assert_eq!(
        alert(&item, &hosts, 0),
        (
            "Decision · sendai".into(),
            "A session is waiting on you · 2 choices".into()
        )
    );
}

#[test]
fn minutes_left_round_down_and_below_a_minute_say_under_1_min() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let cases: &[(i64, &str)] = &[
        (300, "times out in 5 min"),
        (299, "times out in 4 min"),
        (240, "times out in 4 min"),
        (239, "times out in 3 min"),
        (61, "times out in 1 min"),
        (60, "times out in 1 min"),
        (59, "times out in under 1 min"),
        (1, "times out in under 1 min"),
        (0, "times out in under 1 min"),
        // Already past: never "0 min", never negative.
        (-30, "times out in under 1 min"),
    ];
    for (secs, phrase) in cases {
        let item = decision(
            "kobe",
            Some(AgentClass::Perri),
            2,
            Some(now() + Duration::seconds(*secs)),
            None,
            None,
        );
        let (_, body) = alert(&item, &hosts, 0);
        assert_eq!(
            body,
            format!("Perri is waiting on you · 2 choices · {phrase}"),
            "{secs}s left"
        );
        assert!(!body.contains("0 min"), "{body}");
    }
}

#[test]
fn the_asking_agent_is_one_of_a_fixed_set_and_anything_else_is_a_session() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let cases = [
        (Some(AgentClass::Mother), "Mother"),
        (Some(AgentClass::Perri), "Perri"),
        (Some(AgentClass::Fred), "Fred"),
        (Some(AgentClass::Teri), "Teri"),
        (Some(AgentClass::Claudia), "Claudia"),
        (Some(AgentClass::Other), "A session"),
        (None, "A session"),
    ];
    for (agent, name) in cases {
        let item = decision("kobe", agent, 2, None, None, None);
        let (_, body) = alert(&item, &hosts, 0);
        assert_eq!(
            body,
            format!("{name} is waiting on you · 2 choices"),
            "{agent:?}"
        );
    }
}

#[test]
fn a_single_choice_still_reads_as_a_count_of_choices() {
    let item = decision("kobe", None, 1, None, None, None);
    let (_, body) = alert(&item, &hosts_with("kobe", None), 0);
    assert!(
        body.starts_with("A session is waiting on you · 1 choice"),
        "{body}"
    );
    assert!(conforms(&body, &vctx(&["kobe"], &[])), "{body}");
}

// ── W13-4: Review ────────────────────────────────────────────────────────────

#[test]
fn a_review_renders_pr_number_size_and_how_many_are_waiting() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let item = review_item("kobe", "Carefeed/admin-portal", 4821, Some(10));
    assert_eq!(
        alert(&item, &hosts, 3),
        (
            "Review · kobe".into(),
            "PR #4821 · small change · 3 waiting".into()
        )
    );
}

#[test]
fn review_size_buckets_are_49_small_50_medium_400_medium_401_large_and_unknown_omitted() {
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let cases: &[(Option<u64>, &str)] = &[
        (Some(0), "PR #4821 · small change · 3 waiting"),
        (Some(49), "PR #4821 · small change · 3 waiting"),
        (Some(50), "PR #4821 · medium change · 3 waiting"),
        (Some(400), "PR #4821 · medium change · 3 waiting"),
        (Some(401), "PR #4821 · large change · 3 waiting"),
        (Some(1_000_000), "PR #4821 · large change · 3 waiting"),
        // Unknown: the size is omitted, never guessed.
        (None, "PR #4821 · 3 waiting"),
    ];
    for (lines, want) in cases {
        let item = review_item("kobe", "Carefeed/admin-portal", 4821, *lines);
        let (_, body) = alert(&item, &hosts, 3);
        assert_eq!(&body, want, "{lines:?} changed lines");
    }
}

#[test]
fn a_review_on_a_personal_host_shows_a_repository_only_for_a_personal_owner() {
    let personal = hosts_with("sendai", Some(HostClass::Personal));
    // The PRD's illustration (cannot occur while the queue holds only Carefeed PRs).
    let mine = review_item("sendai", "thehammer/bishop", 212, Some(900));
    assert_eq!(
        alert(&mine, &personal, 1),
        (
            "Review · sendai · bishop".into(),
            "PR #212 · large change · 1 waiting".into()
        )
    );
    // A work owner's repository: no name, in any case.
    for repo in ["Carefeed/admin-portal", "carefeed/admin-portal"] {
        let work = review_item("sendai", repo, 4821, Some(10));
        assert_eq!(
            alert(&work, &personal, 1),
            (
                "Review · sendai".into(),
                "PR #4821 · small change · 1 waiting".into()
            ),
            "{repo}"
        );
    }
    // A personal owner's repository on a work host: still none.
    let on_work = review_item("kobe", "thehammer/bishop", 212, Some(900));
    assert_eq!(
        alert(&on_work, &hosts_with("kobe", Some(HostClass::Work)), 1).0,
        "Review · kobe"
    );
}

#[test]
fn a_work_owner_added_by_the_operator_hides_that_owners_repositories_too() {
    let owners = PushConfig {
        work_owners: vec!["Acme".into()],
        ..Default::default()
    }
    .resolved_work_owners();
    assert_eq!(owners, ["Carefeed", "Acme"]);
    let personal = hosts_with("sendai", Some(HostClass::Personal));
    let reviews = BTreeMap::from([("sendai".to_string(), 1usize)]);
    let ctx = RenderContext {
        hosts: &personal,
        work_owners: &owners,
        reviews_waiting: &reviews,
        now: now(),
    };
    let acme = review_item("sendai", "acme/widgets", 7, Some(10));
    let mine = review_item("sendai", "thehammer/bishop", 8, Some(10));
    assert_eq!(
        vocab::render_alert(&acme, &ctx).unwrap().title,
        "Review · sendai"
    );
    assert_eq!(
        vocab::render_alert(&mine, &ctx).unwrap().title,
        "Review · sendai · bishop"
    );
}

// ── W13-4, W13-36: the owner rule for every kind ─────────────────────────────

#[test]
fn the_owner_rule_is_the_same_for_mother_decision_and_review_items() {
    // (host class, owner, repo shown?)
    let cases: &[(Option<HostClass>, Option<&str>, bool)] = &[
        (Some(HostClass::Personal), Some("thehammer"), true),
        (Some(HostClass::Personal), Some("Carefeed"), false),
        (Some(HostClass::Personal), Some("CAREFEED"), false),
        (Some(HostClass::Personal), None, false),
        (Some(HostClass::Work), Some("thehammer"), false),
        (Some(HostClass::Work), None, false),
        (None, Some("thehammer"), false),
        (None, None, false),
    ];
    for (class, owner, shown) in cases {
        let hosts = hosts_with("sendai", *class);
        let url = owner.map(|o| format!("https://github.com/{o}/bishop/pull/3"));
        let mother = mother_item(
            "sendai",
            marked_job(&job_id("3f9a1c2e"), Some("user"), None, url.as_deref()),
        );
        let dec = decision(
            "sendai",
            Some(AgentClass::Claudia),
            2,
            None,
            Some("bishop"),
            *owner,
        );
        let review = review_item(
            "sendai",
            &format!("{}/bishop", owner.unwrap_or("MARKER-owner")),
            3,
            Some(10),
        );
        // A review's owner is always known (it is in `owner/repo`).
        let review_shows = *shown;
        for (kind, item, expect) in [
            ("mother", &mother, *shown),
            ("decision", &dec, *shown),
            ("review", &review, review_shows),
        ] {
            if kind == "review" && owner.is_none() {
                continue; // a review always has an owner; covered above
            }
            let (title, _) = alert(item, &hosts, 1);
            let name = title.contains("bishop");
            assert_eq!(
                name, expect,
                "{kind} on {class:?} with owner {owner:?}: {title}"
            );
            // No other repository text ever appears.
            assert_no_marker(&title);
        }
    }
}

#[test]
fn a_decision_whose_focus_remote_is_a_work_owner_or_has_no_remote_shows_no_name() {
    let personal = hosts_with("sendai", Some(HostClass::Personal));
    let carefeed = decision(
        "sendai",
        None,
        2,
        None,
        Some("admin-portal"),
        Some("Carefeed"),
    );
    let no_remote = decision("sendai", None, 2, None, Some("admin-portal"), None);
    let mine = decision("sendai", None, 2, None, Some("bishop"), Some("thehammer"));
    assert_eq!(alert(&carefeed, &personal, 0).0, "Decision · sendai");
    assert_eq!(alert(&no_remote, &personal, 0).0, "Decision · sendai");
    assert_eq!(alert(&mine, &personal, 0).0, "Decision · sendai · bishop");
}

#[test]
fn a_repository_name_that_is_not_name_shaped_is_dropped_not_shown() {
    let personal = hosts_with("sendai", Some(HostClass::Personal));
    let forty = "a".repeat(40);
    let forty_one = "a".repeat(41);
    for (repo, shown) in [
        ("bishop", true),
        ("my.repo_name-2", true),
        (forty.as_str(), true),
        (forty_one.as_str(), false),
        ("", false),
        ("two words", false),
        ("slash/name", false),
        ("MARKER repo with spaces", false),
        ("naïve", false),
    ] {
        let item = decision("sendai", None, 2, None, Some(repo), Some("thehammer"));
        let (title, _) = alert(&item, &personal, 0);
        assert_eq!(
            title.contains(repo) && !repo.is_empty(),
            shown,
            "{repo:?}: {title}"
        );
        if !shown {
            assert_eq!(title, "Decision · sendai", "{repo:?}");
        }
    }
}

// ── host labels ──────────────────────────────────────────────────────────────

#[test]
fn a_host_name_that_is_not_label_shaped_reads_as_the_literal_host() {
    let sixteen = format!("a{}", "b".repeat(15));
    let seventeen = format!("a{}", "b".repeat(16));
    for (name, label) in [
        ("kobe", "kobe"),
        ("tokyo-2", "tokyo-2"),
        (sixteen.as_str(), sixteen.as_str()),
        (seventeen.as_str(), "host"),
        ("Kobe", "host"),
        ("1kobe", "host"),
        ("kobe laptop", "host"),
        ("MARKER-host", "host"),
        ("kobe.local", "host"),
        ("", "host"),
    ] {
        let item = mother_item(
            name,
            marked_job(&job_id("3f9a1c2e"), Some("user"), None, None),
        );
        let (title, _) = alert(&item, &hosts_with(name, None), 0);
        assert_eq!(title, format!("Mother · {label}"), "{name:?}");
        assert_eq!(vocab::host_label(name), label);
    }
}

// ── W13-5: Summary ───────────────────────────────────────────────────────────

fn summary_for(items: &[Waiting], oldest: Option<DateTime<Utc>>) -> (String, String) {
    let refs: Vec<&Waiting> = items.iter().collect();
    let s = vocab::render_summary(&refs, oldest, now());
    (s.title, s.body)
}

#[test]
fn a_summary_counts_by_host_and_the_age_of_the_oldest() {
    let items = vec![
        mother_item(
            "kobe",
            marked_job(&job_id("3f9a1c2e"), Some("user"), None, None),
        ),
        review_item("kobe", "Carefeed/admin-portal", 4821, Some(10)),
        review_item("sendai", "thehammer/bishop", 212, Some(900)),
    ];
    assert_eq!(
        summary_for(&items, Some(now() - Duration::hours(14))),
        (
            "Waiting for you".into(),
            "3 items · 2 on kobe, 1 on sendai · oldest 14 h".into()
        )
    );
}

#[test]
fn a_summary_never_contains_a_repository_name_even_from_a_personal_host() {
    let items = vec![
        mother_item(
            "sendai",
            marked_job(
                &job_id("7c01d4aa"),
                Some("user"),
                None,
                Some("https://github.com/thehammer/bishop/pull/12"),
            ),
        ),
        review_item("sendai", "thehammer/bishop", 212, Some(900)),
        decision(
            "sendai",
            Some(AgentClass::Claudia),
            2,
            None,
            Some("bishop"),
            Some("thehammer"),
        ),
    ];
    let (title, body) = summary_for(&items, Some(now() - Duration::hours(3)));
    for text in [&title, &body] {
        assert!(!text.contains("bishop"), "{text}");
        assert_no_marker(text);
    }
    assert_eq!(body, "3 items · 3 on sendai · oldest 3 h");
    // And the allow-list agrees: a summary with a repository in it does not conform.
    let with_repo = format!("{body} · bishop");
    assert!(
        !conforms(&with_repo, &vctx(&["sendai"], &["bishop"])),
        "{with_repo}"
    );
}

#[test]
fn a_summary_of_one_item_and_with_a_host_that_has_no_valid_label() {
    let items = vec![mother_item(
        "Kobe Laptop",
        marked_job(&job_id("3f9a1c2e"), Some("user"), None, None),
    )];
    let (_, body) = summary_for(&items, Some(now() - Duration::hours(2)));
    assert_eq!(body, "1 item · 1 on host · oldest 2 h");
}

#[test]
fn a_summary_renders_without_an_age_when_none_is_known_and_always_conforms() {
    let items = vec![
        mother_item(
            "kobe",
            marked_job(&job_id("3f9a1c2e"), Some("user"), None, None),
        ),
        review_item("sendai", "thehammer/bishop", 212, Some(900)),
    ];
    let ctx = vctx(&["kobe", "sendai"], &[]);
    for oldest in [
        None,
        Some(now()),
        Some(now() - Duration::seconds(30)),
        Some(now() - Duration::minutes(59)),
        Some(now() - Duration::hours(14)),
        Some(now() - Duration::days(9)),
    ] {
        let (title, body) = summary_for(&items, oldest);
        assert_eq!(title, "Waiting for you");
        assert!(
            conforms(&title, &ctx) && conforms(&body, &ctx),
            "{oldest:?}: {body}"
        );
        assert_no_marker(&body);
    }
}

// ── withdrawals ──────────────────────────────────────────────────────────────

#[test]
fn a_withdrawal_replaces_the_notification_with_the_ref_and_no_longer_needs_you() {
    let kobe = hosts_with("kobe", Some(HostClass::Work));
    let mother = mother_item(
        "kobe",
        marked_job(&job_id("3f9a1c2e"), Some("user"), None, None),
    );
    assert_eq!(
        withdrawal(&mother, &kobe),
        (
            "Mother · kobe".into(),
            "Job 3f9a1c2e no longer needs you".into()
        )
    );
    let review = review_item("kobe", "Carefeed/admin-portal", 4821, Some(10));
    assert_eq!(
        withdrawal(&review, &kobe),
        (
            "Review · kobe".into(),
            "PR #4821 no longer needs you".into()
        )
    );
    let dec = decision("kobe", Some(AgentClass::Claudia), 3, None, None, None);
    assert_eq!(
        withdrawal(&dec, &kobe),
        (
            "Decision · kobe".into(),
            "Claudia no longer needs you".into()
        )
    );
    let session = decision("kobe", None, 3, None, None, None);
    assert_eq!(
        withdrawal(&session, &kobe),
        (
            "Decision · kobe".into(),
            "A session no longer needs you".into()
        )
    );
}

#[test]
fn a_withdrawal_keeps_the_title_of_the_notification_it_replaces_repository_included() {
    let personal = hosts_with("sendai", Some(HostClass::Personal));
    let item = mother_item(
        "sendai",
        marked_job(
            &job_id("7c01d4aa"),
            Some("user"),
            None,
            Some("https://github.com/thehammer/bishop/pull/12"),
        ),
    );
    assert_eq!(alert(&item, &personal, 0).0, "Mother · sendai · bishop");
    assert_eq!(withdrawal(&item, &personal).0, "Mother · sendai · bishop");
}

#[test]
fn no_longer_needs_you_is_part_of_the_vocabulary() {
    assert_eq!(vocab::NO_LONGER_NEEDS_YOU, "no longer needs you");
    let ctx = vctx(&["kobe"], &[]);
    for text in [
        "Job 3f9a1c2e no longer needs you",
        "A job no longer needs you",
        "PR #4821 no longer needs you",
        "Claudia no longer needs you",
        "Mother no longer needs you",
        "A session no longer needs you",
    ] {
        assert!(conforms(text, &ctx), "{text}");
    }
    assert!(!conforms("MARKER-question no longer needs you", &ctx));
    assert!(!conforms(
        "Job 3f9a1c2e no longer needs you MARKER-detail",
        &ctx
    ));
}

// ── attention items are count-only ───────────────────────────────────────────

#[test]
fn an_attention_item_has_no_alert_and_no_withdrawal_text() {
    let job: MotherJob = serde_json::from_value(json!({
        "id": job_id("3f9a1c2e"), "state": "running",
        "attention_reasons": [{"reason": "progress_stalled", "since": "2026-11-26T11:00:00Z", "acked": false}],
    }))
    .unwrap();
    let items = mother_items("kobe", &[job]);
    assert_eq!(items.len(), 1);
    assert!(items[0].is_count_only());
    let owners = work_owners();
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    let reviews = BTreeMap::new();
    let ctx = RenderContext {
        hosts: &hosts,
        work_owners: &owners,
        reviews_waiting: &reviews,
        now: now(),
    };
    assert!(vocab::render_alert(&items[0], &ctx).is_none());
    assert!(vocab::render_withdrawal(&items[0], &ctx).is_none());
}

// ── W13-6: the allow-list ────────────────────────────────────────────────────

/// Every title and body the matrix renders, with the context that makes them valid.
fn rendered_matrix() -> Vec<(String, String, VocabContext)> {
    let mut out = Vec::new();
    let classes = [
        ("kobe", Some(HostClass::Work)),
        ("sendai", Some(HostClass::Personal)),
        ("tokyo", None),
    ];
    for (host, class) in classes {
        let hosts = hosts_with(host, class);
        let ctx = vctx(&[host], &["bishop"]);
        let mut push = |w: &Waiting, waiting: usize| {
            let (t, b) = alert(w, &hosts, waiting);
            out.push((t, b, ctx.clone()));
            let (t, b) = withdrawal(w, &hosts);
            out.push((t, b, ctx.clone()));
        };
        for (_, reason, activity, _) in mother_reasons() {
            for url in [
                None,
                Some("https://github.com/thehammer/bishop/pull/12"),
                Some("https://github.com/Carefeed/admin-portal/pull/12"),
            ] {
                push(
                    &mother_item(host, marked_job(&job_id("3f9a1c2e"), reason, activity, url)),
                    0,
                );
            }
        }
        for agent in [
            None,
            Some(AgentClass::Other),
            Some(AgentClass::Claudia),
            Some(AgentClass::Teri),
        ] {
            for deadline in [
                None,
                Some(now() + Duration::seconds(45)),
                Some(now() + Duration::minutes(7)),
            ] {
                for choices in [1, 3] {
                    push(
                        &decision(
                            host,
                            agent,
                            choices,
                            deadline,
                            Some("bishop"),
                            Some("thehammer"),
                        ),
                        0,
                    );
                }
            }
        }
        for lines in [None, Some(49), Some(50), Some(400), Some(401)] {
            for repo in ["Carefeed/admin-portal", "thehammer/bishop"] {
                push(&review_item(host, repo, 4821, lines), 3);
            }
        }
    }
    out
}

#[test]
fn nothing_a_worker_agent_or_person_wrote_reaches_a_title_or_body_for_any_kind_class_or_reason() {
    let rendered = rendered_matrix();
    assert!(
        rendered.len() > 150,
        "the matrix shrank: {}",
        rendered.len()
    );
    for (title, body, _) in &rendered {
        assert_no_marker(title);
        assert_no_marker(body);
        for marker in MARKERS {
            assert!(
                !title.contains(marker) && !body.contains(marker),
                "{marker}: {title} / {body}"
            );
        }
    }
}

#[test]
fn the_repository_appears_in_the_matrix_only_on_a_personal_host_with_a_personal_owner() {
    for (title, _, _) in rendered_matrix() {
        if title.contains("bishop") {
            assert!(title.contains(" · sendai · bishop"), "{title}");
        }
        assert!(!title.contains("admin-portal"), "{title}");
    }
}

#[test]
fn every_rendered_title_and_body_conforms_to_the_vocabulary() {
    for (title, body, ctx) in rendered_matrix() {
        assert!(conforms(&title, &ctx), "title {title:?}");
        assert!(conforms(&body, &ctx), "body {body:?}");
    }
}

/// Every way to put `marker` into `text`: around it, alone, and in place of each word.
fn injections(text: &str, marker: &str) -> Vec<String> {
    let mut variants = vec![
        format!("{text} {marker}"),
        format!("{marker} {text}"),
        format!("{text} · {marker}"),
        format!("{text}: {marker}"),
        marker.to_string(),
    ];
    let words: Vec<&str> = text.split(' ').collect();
    for i in 0..words.len() {
        let mut w = words.clone();
        w[i] = marker;
        variants.push(w.join(" "));
    }
    variants
}

#[test]
fn conforms_rejects_every_marker_injected_into_a_conforming_string() {
    // Distinct (host, text) pairs: the same text renders for many inputs.
    let mut seen = std::collections::BTreeSet::new();
    let mut texts: Vec<(String, VocabContext)> = Vec::new();
    for (title, body, ctx) in rendered_matrix() {
        for text in [title, body] {
            if seen.insert((ctx.hosts.clone(), text.clone())) {
                texts.push((text, ctx.clone()));
            }
        }
    }
    assert!(texts.len() > 60, "the matrix shrank: {}", texts.len());
    let mut checked = 0;
    for (i, (text, ctx)) in texts.iter().enumerate() {
        assert!(conforms(text, ctx), "the control must conform: {text:?}");
        // Every text gets one marker (rotating, so each is used); a few get all of them.
        let markers: Vec<&str> = if i % 10 == 0 {
            MARKERS.to_vec()
        } else {
            vec![MARKERS[i % MARKERS.len()]]
        };
        for marker in markers {
            for v in injections(text, marker) {
                assert!(
                    !conforms(&v, ctx),
                    "an allow-list must refuse {v:?} (from {text:?})"
                );
                checked += 1;
            }
        }
    }
    assert!(checked > 1_000, "only {checked} injections checked");
}

#[test]
fn conforms_rejects_arbitrary_free_text_and_near_misses_of_the_grammar() {
    let ctx = vctx(&["kobe", "sendai"], &["bishop"]);
    for text in [
        "",
        "Please approve the deploy to production",
        "Mother · kobe · secret-repo",
        "Mother · elsewhere",
        "Mother · kobe · bishop · extra",
        "Job 3f9a1c2e asked a question: why is the build red?",
        "Job 3F9A1C2E asked a question",
        "Job 3f9a1c2 asked a question",
        "Job 3f9a1c2e is asked a question",
        "Job 3f9a1c2e is needs you",
        "Job 3f9a1c2e is blocked after review and force-pushed",
        "Job 3f9a1c2e is paused at $4.20 spend",
        "Claudia in my-project is waiting on you · 3 choices",
        "Bob is waiting on you · 3 choices",
        "Claudia is waiting on you · three choices",
        "Claudia is waiting on you · 3 choices · times out in soon",
        "Claudia is waiting on you · 3 choices · times out in -1 min",
        "PR #4821 · tiny change · 3 waiting",
        "PR #4821 · small change",
        "PR #abc · small change · 3 waiting",
        "PR #4821 · small change · 3 waiting · by alice",
        "Review: Fix the thing",
        "Waiting for you: 3 secrets",
        "3 items · 2 on elsewhere",
        "3 items · 2 on kobe, 1 on sendai · oldest 14 weeks",
        "3 items · 2 on kobe · bishop",
        "Mother",
        "Mother · ",
        " Mother · kobe",
        "Mother · kobe ",
        "Mother · kobe\nJob 3f9a1c2e asked a question",
    ] {
        assert!(!conforms(text, &ctx), "must not conform: {text:?}");
    }
    // The controls: the same grammar's good strings.
    for text in [
        "Mother · kobe",
        "Mother · sendai · bishop",
        "Job 3f9a1c2e asked a question",
        "Claudia is waiting on you · 3 choices · times out in 4 min",
        "A session is waiting on you · 2 choices · times out in under 1 min",
        "PR #4821 · small change · 3 waiting",
        "PR #4821 · 3 waiting",
        "Waiting for you",
        "3 items · 2 on kobe, 1 on sendai · oldest 14 h",
    ] {
        assert!(conforms(text, &ctx), "must conform: {text:?}");
    }
}

#[test]
fn conforms_allows_a_repository_or_a_host_only_when_the_context_names_it() {
    // The allow-list is closed over what the context says is allowed.
    assert!(conforms(
        "Mother · sendai · bishop",
        &vctx(&["sendai"], &["bishop"])
    ));
    assert!(!conforms(
        "Mother · sendai · bishop",
        &vctx(&["sendai"], &[])
    ));
    assert!(!conforms(
        "Mother · sendai · bishop",
        &vctx(&["sendai"], &["other"])
    ));
    assert!(conforms("Mother · kobe", &vctx(&["kobe"], &[])));
    assert!(!conforms("Mother · kobe", &vctx(&["sendai"], &[])));
    // The fallback label is always allowed.
    assert!(conforms("Mother · host", &vctx(&[], &[])));
}

// ── W13-33: the shared phrase table ──────────────────────────────────────────

fn reason_fixture() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/push-vocab/reason_phrases.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture")).expect("json")
}

#[test]
fn the_vocab_tables_equal_the_shared_reason_phrases_fixture() {
    let fixture = reason_fixture();
    let table = |name: &str, rows: &[(&str, &str)]| {
        let obj = fixture[name]
            .as_object()
            .unwrap_or_else(|| panic!("{name}"));
        assert_eq!(obj.len(), rows.len(), "{name}: rows differ");
        for (k, v) in rows {
            assert_eq!(obj[*k], *v, "{name}.{k}");
        }
    };
    table("mother_paused_reason", vocab::MOTHER_PAUSED_REASONS);
    table("mother_activity", vocab::MOTHER_ACTIVITIES);
    table("agent_class", vocab::AGENT_CLASSES);
    assert_eq!(
        fixture["mother_reason_default"],
        vocab::MOTHER_REASON_DEFAULT
    );
    assert_eq!(fixture["agent_fallback"], vocab::AGENT_FALLBACK);
}

#[test]
fn what_a_job_renders_for_each_fixture_reason_is_the_fixtures_phrase() {
    // The renderer, not just the constants, follows the shared file.
    let fixture = reason_fixture();
    let hosts = hosts_with("kobe", Some(HostClass::Work));
    for (reason, phrase) in fixture["mother_paused_reason"].as_object().unwrap() {
        let item = mother_item(
            "kobe",
            marked_job(&job_id("3f9a1c2e"), Some(reason), None, None),
        );
        let (_, body) = alert(&item, &hosts, 0);
        assert!(body.ends_with(phrase.as_str().unwrap()), "{reason}: {body}");
        assert!(body.starts_with("Job 3f9a1c2e "), "{body}");
    }
    for (activity, phrase) in fixture["mother_activity"].as_object().unwrap() {
        let item = mother_item(
            "kobe",
            marked_job(&job_id("3f9a1c2e"), None, Some(activity), None),
        );
        let (_, body) = alert(&item, &hosts, 0);
        assert!(
            body.ends_with(phrase.as_str().unwrap()),
            "{activity}: {body}"
        );
    }
    let default = fixture["mother_reason_default"].as_str().unwrap();
    let item = mother_item("kobe", marked_job(&job_id("3f9a1c2e"), None, None, None));
    assert!(alert(&item, &hosts, 0).1.ends_with(default));
    for (agent, name) in fixture["agent_class"].as_object().unwrap() {
        let class: AgentClass = serde_json::from_value(json!(agent)).expect("an agent class");
        let item = decision("kobe", Some(class), 2, None, None, None);
        assert!(
            alert(&item, &hosts, 0)
                .1
                .starts_with(name.as_str().unwrap()),
            "{agent}"
        );
    }
    let fallback = fixture["agent_fallback"].as_str().unwrap();
    let item = decision("kobe", Some(AgentClass::Other), 2, None, None, None);
    assert!(alert(&item, &hosts, 0).1.starts_with(fallback));
}
