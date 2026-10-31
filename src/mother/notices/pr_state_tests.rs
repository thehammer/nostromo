//! Learning that a Mother job's PR merged (MF2b): relay events, the `gh`
//! poll, `GhProbe`, and what the log and audit may carry.
//!
//! Everything is observed from outside: what the session port is handed, each
//! job's notice record, what the fake probe was asked, and the log capture.
//! No network, no `gh`: a fake [`PrStateProbe`], a fake [`CommandRunner`] and
//! the rig's `ManualClock`. Poll cycles are driven by hand.

use super::*;

use std::collections::VecDeque;
use std::time::Duration;

use async_trait::async_trait;

use crate::data::relay_client::{spawn_with, QueueSignal, RelayEvent, RelayHub, RelayStatus};
use crate::mother::notices::detect::JobEvent;
use crate::mother::notices::pr_state::{
    CommandOutput, CommandRunner, GhProbe, PrCandidate, PrRef, PrState, PrStateProbe, PrTracker,
    ProbeError, GH_TIMEOUT,
};
use crate::mother::notices::NoticeScope;

// ── fixtures ─────────────────────────────────────────────────────────────────

/// A PR in the relay's organisation (the status says `Carefeed` unless a test
/// changes it).
const COVERED: &str = "https://github.com/Carefeed/app/pull/7";
const COVERED_CANON: &str = "https://github.com/carefeed/app/pull/7";
/// A PR in an owner the relay does not send events for.
const FOREIGN: &str = "https://github.com/thehammer/nostromo/pull/3";
const FOREIGN_CANON: &str = FOREIGN;

fn pr_job(id: &str, pr: &str) -> MotherJob {
    job(F, id, "succeeded").with_pr(pr)
}

trait FinishedExt: Sized {
    fn finished(self, ms: i64) -> Self;
}

impl FinishedExt for MotherJob {
    fn finished(mut self, ms: i64) -> Self {
        self.finished_at = chrono::DateTime::from_timestamp_millis(ms);
        self
    }
}

/// The feed's first look is over and F's notice for it has been told and its
/// turn is done, so the next delivery is the one a test is about.
fn settle(r: &Rig) {
    r.after(30 * SEC);
    r.notice_turn(F);
}

fn event(kind: &str, repo: Option<&str>, number: Option<u64>, merged: Option<bool>) -> QueueSignal {
    QueueSignal::Event(RelayEvent {
        event_type: kind.to_owned(),
        repo: repo.map(str::to_owned),
        number,
        merged,
        ..Default::default()
    })
}

fn merged_event(repo: &str, number: u64) -> QueueSignal {
    event("pr.merged", Some(repo), Some(number), None)
}

fn closed_event(repo: &str, number: u64, merged: bool) -> QueueSignal {
    event("pr.closed", Some(repo), Some(number), Some(merged))
}

/// What the fake probe was asked, and what it answers (`Open` unless
/// scripted).
#[derive(Default)]
struct FakeProbe {
    calls: Mutex<Vec<String>>,
    answers: Mutex<HashMap<String, VecDeque<Result<PrState, ProbeError>>>>,
}

impl FakeProbe {
    fn answer(&self, canonical_url: &str, answer: Result<PrState, ProbeError>) {
        self.answers
            .lock()
            .unwrap()
            .entry(canonical_url.to_owned())
            .or_default()
            .push_back(answer);
    }

    /// Every URL probed so far, in order.
    fn urls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    fn count(&self) -> usize {
        self.calls.lock().unwrap().len()
    }

    /// The calls since the last `take`.
    fn take(&self) -> Vec<String> {
        std::mem::take(&mut *self.calls.lock().unwrap())
    }
}

#[async_trait]
impl PrStateProbe for FakeProbe {
    async fn state(&self, pr: &PrRef) -> Result<PrState, ProbeError> {
        let url = pr.url();
        self.calls.lock().unwrap().push(url.clone());
        self.answers
            .lock()
            .unwrap()
            .get_mut(&url)
            .and_then(VecDeque::pop_front)
            .unwrap_or(Ok(PrState::Open))
    }
}

struct Tracked {
    tracker: Arc<PrTracker>,
    probe: Arc<FakeProbe>,
    status: Arc<RelayStatus>,
}

/// A tracker on `r`'s engine and clock, the relay connected.
fn tracker_for(r: &Rig) -> Tracked {
    let probe = Arc::new(FakeProbe::default());
    let status = Arc::new(RelayStatus::new());
    status.set_connected(true);
    let clock: Arc<dyn Clock> = Arc::new(r.clock.clone());
    let tracker = PrTracker::new(r.engine.clone(), probe.clone(), status.clone(), clock);
    Tracked {
        tracker,
        probe,
        status,
    }
}

/// Run one poll cycle with the clock at `at_ms`.
async fn cycle_at(r: &Rig, t: &Tracked, at_ms: i64) {
    r.clock.set(at_ms);
    t.tracker.poll_cycle().await;
}

fn state_of(msg: &str, id: &str) -> Option<String> {
    attr(element_for(msg, id), "state")
}

fn sorted_urls(mut urls: Vec<String>) -> Vec<String> {
    urls.sort();
    urls
}

// ── PrRef ────────────────────────────────────────────────────────────────────

#[test]
fn a_pr_url_parses_to_lowercased_owner_name_and_number() {
    let pr = PrRef::parse("https://github.com/Owner/Name/pull/12").expect("a PR url");
    assert_eq!(pr.owner, "owner");
    assert_eq!(pr.name, "name");
    assert_eq!(pr.number, 12);
    assert_eq!(pr.url(), "https://github.com/owner/name/pull/12");
}

#[test]
fn a_pr_url_tolerates_a_sub_page_a_query_and_a_fragment() {
    for url in [
        "https://github.com/Owner/Name/pull/12/files",
        "https://github.com/Owner/Name/pull/12/files/",
        "https://github.com/Owner/Name/pull/12/",
        "https://github.com/Owner/Name/pull/12?foo=1",
        "https://github.com/Owner/Name/pull/12/files?foo=1#diff-abc",
        "https://github.com/Owner/Name/pull/12#issuecomment-1",
    ] {
        let pr = PrRef::parse(url).unwrap_or_else(|| panic!("{url} is a PR url"));
        assert_eq!(pr.url(), "https://github.com/owner/name/pull/12", "{url}");
    }
}

#[test]
fn only_a_github_https_pull_url_is_a_pr() {
    for url in [
        "",
        "http://github.com/o/n/pull/12",
        "https://gitlab.com/o/n/pull/12",
        "https://github.com.evil.example/o/n/pull/12",
        "https://github.com/o/n/issues/12",
        "https://github.com/o/n/pull/abc",
        "https://github.com/o/n/pull/12abc",
        "https://github.com/o/n/pull/-1",
        "https://github.com/o/n/pull/",
        "https://github.com/o/n/pull",
        "https://github.com/o/pull/12",
        "https://github.com/pull/12",
        "https://github.com/x/o/n/pull/12",
        "https://github.com/o/n/commit/abcdef",
        "https://github.com/",
        "not a url",
    ] {
        assert_eq!(PrRef::parse(url), None, "{url:?} is not a PR we track");
    }
}

// ── relay -> engine ──────────────────────────────────────────────────────────

#[test]
fn a_pr_merged_event_wakes_the_focus_that_queued_the_job_once() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);

    // The repo is matched without regard to case.
    t.tracker.on_signal(&merged_event("carefeed/APP", 7));
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "the merge is one delivery: {ds:#?}");
    assert_eq!(ds[1].tag, F);
    assert_eq!(state_of(&ds[1].fresh, "j1").as_deref(), Some("pr_merged"));
    assert_eq!(r.status("j1"), (NoticeStatus::Told, None), "it woke F");

    t.tracker.on_signal(&merged_event("carefeed/APP", 7));
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2, "the same event again says nothing");
    assert_eq!(t.probe.count(), 0, "no probe for a relayed merge");
}

#[test]
fn a_pr_closed_event_that_merged_is_a_merge() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);

    t.tracker.on_signal(&closed_event("Carefeed/app", 7, true));
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "{ds:#?}");
    assert_eq!(state_of(&ds[1].fresh, "j1").as_deref(), Some("pr_merged"));
}

#[test]
fn a_pr_closed_event_that_did_not_merge_is_quiet_and_rides_along() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);

    t.tracker.on_signal(&closed_event("carefeed/app", 7, false));
    r.after(HOUR);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1, "a closed PR never starts a turn");

    r.jobs(&[pr_job("j1", COVERED), job(F, "j2", "succeeded")]);
    r.after(30 * SEC);
    let msg = r.last_delivery(F).fresh;
    assert_eq!(state_of(&msg, "j1").as_deref(), Some("pr_closed"));
    assert_eq!(state_of(&msg, "j2").as_deref(), Some("succeeded"));
}

#[test]
fn events_that_name_no_tracked_pr_or_are_not_merges_change_nothing() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);

    for signal in [
        // another number, another repo, another owner
        merged_event("carefeed/app", 8),
        merged_event("carefeed/other", 7),
        merged_event("acme/app", 7),
        // no repo, no number
        event("pr.merged", None, Some(7), None),
        event("pr.merged", Some("carefeed/app"), None, None),
        // not merges
        event("pr.opened", Some("carefeed/app"), Some(7), None),
        event("ci.completed", Some("carefeed/app"), None, None),
        event("pr.review_requested", Some("carefeed/app"), Some(7), None),
        QueueSignal::Reconnected,
    ] {
        t.tracker.on_signal(&signal);
    }
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1, "{:#?}", r.deliveries());
    assert_eq!(r.notice("j1").last_state, Some(JobEvent::Succeeded));

    // None of that used the job up: its own merge still lands.
    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 2);
}

#[test]
fn an_event_for_a_pr_no_job_has_is_ignored() {
    let r = Rig::new();
    r.jobs(&[job(F, "plain", "succeeded")]);
    settle(&r);
    let t = tracker_for(&r);
    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1);
}

#[test]
fn once_merged_a_later_closed_event_says_nothing() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);
    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    r.notice_turn(F);
    assert_eq!(r.deliveries().len(), 2);

    t.tracker.on_signal(&closed_event("carefeed/app", 7, false));
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2);
    r.jobs(&[pr_job("j1", COVERED), job(F, "j2", "succeeded")]);
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 3, "{ds:#?}");
    assert_eq!(
        ids(&ds[2].merged),
        sorted(&["j2"]),
        "j1 is not mentioned again: {}",
        ds[2].merged
    );
    assert_eq!(r.notice("j1").last_state, Some(JobEvent::PrMerged));
}

// ── one announcement however it is learnt ────────────────────────────────────

#[tokio::test]
async fn a_relayed_merge_then_a_poll_that_says_merged_is_one_announcement() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);
    t.probe.answer(COVERED_CANON, Ok(PrState::Merged));

    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 2);

    t.status.set_connected(false);
    let base = r.now();
    cycle_at(&r, &t, base + 10 * MIN).await;
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2, "announced once");
    assert_eq!(t.probe.count(), 0, "an announced job is not probed");
}

#[tokio::test]
async fn a_polled_merge_then_a_relayed_one_is_one_announcement() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);
    t.status.set_connected(false);
    t.probe.answer(COVERED_CANON, Ok(PrState::Merged));

    let base = r.now();
    cycle_at(&r, &t, base).await;
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 2);
    assert_eq!(
        state_of(&r.last_delivery(F).fresh, "j1").as_deref(),
        Some("pr_merged")
    );

    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2, "announced once");
}

#[tokio::test]
async fn after_a_restart_a_repeated_merge_report_announces_nothing_and_is_not_probed() {
    let r = Rig::with_store();
    r.jobs(&[]);
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);
    let t = tracker_for(&r);
    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 2, "succeeded, then the merge");

    let r = r.restart();
    r.jobs(&[pr_job("j1", COVERED)]);
    let t = tracker_for(&r);
    t.status.set_connected(false);
    t.probe.answer(COVERED_CANON, Ok(PrState::Merged));

    t.tracker.on_signal(&merged_event("carefeed/app", 7));
    let base = r.now();
    cycle_at(&r, &t, base + 10 * MIN).await;
    r.after(30 * SEC);
    r.after(HOUR);
    assert!(
        r.deliveries().is_empty(),
        "a restart re-announced a merge: {:#?}",
        r.deliveries()
    );
    assert_eq!(t.probe.count(), 0, "the job has its outcome: no probe");
}

// ── pr_candidates ────────────────────────────────────────────────────────────

#[test]
fn candidates_are_unknown_until_the_engine_has_seen_the_feed() {
    let r = Rig::with_store();
    assert_eq!(r.engine.pr_candidates(), None);
    r.jobs(&[]);
    assert_eq!(r.engine.pr_candidates(), Some(Vec::new()));
}

#[test]
fn a_candidate_names_the_job_and_its_pr_url() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN), job(F, "plain", "succeeded")]);
    assert_eq!(
        r.engine.pr_candidates(),
        Some(vec![PrCandidate {
            job_id: "j1".to_owned(),
            pr_url: FOREIGN.to_owned(),
        }])
    );
}

// ── poll: who is probed, and when ────────────────────────────────────────────

#[tokio::test]
async fn a_job_in_an_owner_the_relay_does_not_cover_is_probed_even_while_the_relay_is_connected() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    assert!(t.status.connected());

    cycle_at(&r, &t, r.now()).await;
    assert_eq!(t.probe.urls(), vec![FOREIGN_CANON.to_owned()]);
}

#[tokio::test]
async fn a_polled_merge_is_announced_once_and_the_job_is_never_probed_again() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    t.probe.answer(FOREIGN_CANON, Ok(PrState::Merged));
    let base = r.now();

    cycle_at(&r, &t, base).await;
    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "{ds:#?}");
    assert_eq!(state_of(&ds[1].fresh, "j1").as_deref(), Some("pr_merged"));

    for k in 1..=5 {
        cycle_at(&r, &t, base + k * HOUR).await;
    }
    assert_eq!(t.probe.count(), 1, "a merged PR is not probed again");
    assert_eq!(r.deliveries().len(), 2);
}

#[tokio::test]
async fn a_polled_close_is_quiet_and_the_job_is_never_probed_again() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    t.probe.answer(FOREIGN_CANON, Ok(PrState::Closed));
    let base = r.now();

    cycle_at(&r, &t, base).await;
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1, "a closed PR never wakes");

    for k in 1..=5 {
        cycle_at(&r, &t, base + k * HOUR).await;
    }
    assert_eq!(t.probe.count(), 1, "a closed PR is not probed again");

    r.jobs(&[pr_job("j1", FOREIGN), job(F, "j2", "succeeded")]);
    r.after(30 * SEC);
    assert_eq!(
        state_of(&r.last_delivery(F).fresh, "j1").as_deref(),
        Some("pr_closed")
    );
}

#[tokio::test]
async fn an_open_pr_says_nothing_and_is_probed_again_no_sooner_than_five_minutes_later() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    let base = r.now();

    cycle_at(&r, &t, base).await;
    assert_eq!(t.probe.count(), 1);
    assert_eq!(r.deliveries().len(), 1, "open: nothing to say");

    cycle_at(&r, &t, base + MIN).await;
    cycle_at(&r, &t, base + 4 * MIN + 59 * SEC).await;
    assert_eq!(t.probe.count(), 1, "not before five minutes");
    cycle_at(&r, &t, base + 5 * MIN).await;
    assert_eq!(t.probe.count(), 2, "at five minutes");
    cycle_at(&r, &t, base + 5 * MIN + 59 * SEC).await;
    assert_eq!(t.probe.count(), 2, "the gap runs from the last probe");
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1);
}

#[tokio::test]
async fn a_job_in_the_relays_organisation_is_probed_only_while_the_relay_is_down() {
    let r = Rig::new();
    r.jobs(&[
        pr_job("lower", "https://github.com/carefeed/app/pull/1"),
        pr_job("upper", "https://github.com/CAREFEED/app/pull/2"),
    ]);
    settle(&r);
    let t = tracker_for(&r);
    let base = r.now();

    t.status.set_connected(true);
    for k in 0..4 {
        cycle_at(&r, &t, base + k * 10 * MIN).await;
    }
    assert_eq!(t.probe.count(), 0, "the relay covers them");

    t.status.set_connected(false);
    cycle_at(&r, &t, base + HOUR).await;
    assert_eq!(
        sorted_urls(t.probe.take()),
        vec![
            "https://github.com/carefeed/app/pull/1".to_owned(),
            "https://github.com/carefeed/app/pull/2".to_owned(),
        ],
        "with the relay down they are polled like any other"
    );
}

#[tokio::test]
async fn the_relays_organisation_is_the_one_its_ack_named() {
    let r = Rig::new();
    r.jobs(&[
        pr_job("carefeed", COVERED),
        pr_job("acme", "https://github.com/Acme/app/pull/4"),
    ]);
    settle(&r);
    let t = tracker_for(&r);
    t.status.set_org(Some("acme".to_owned()));
    cycle_at(&r, &t, r.now()).await;
    assert_eq!(
        t.probe.urls(),
        vec![COVERED_CANON.to_owned()],
        "Acme is covered now, Carefeed is not"
    );
}

#[tokio::test]
async fn after_a_reconnect_the_next_cycle_sweeps_every_covered_job_once() {
    let r = Rig::new();
    r.jobs(&[
        pr_job("c1", "https://github.com/Carefeed/app/pull/1"),
        pr_job("c2", "https://github.com/Carefeed/app/pull/2"),
    ]);
    settle(&r);
    let t = tracker_for(&r);
    let base = r.now();

    // While the relay was down they were probed.
    t.status.set_connected(false);
    cycle_at(&r, &t, base).await;
    assert_eq!(t.probe.take().len(), 2);

    // It is back: events missed in between are gone, so one sweep, even
    // though they were probed a minute ago.
    t.status.set_connected(true);
    t.tracker.on_signal(&QueueSignal::Reconnected);
    cycle_at(&r, &t, base + MIN).await;
    assert_eq!(
        sorted_urls(t.probe.take()),
        vec![
            "https://github.com/carefeed/app/pull/1".to_owned(),
            "https://github.com/carefeed/app/pull/2".to_owned(),
        ]
    );

    cycle_at(&r, &t, base + 2 * MIN).await;
    cycle_at(&r, &t, base + 30 * MIN).await;
    assert_eq!(t.probe.count(), 0, "the sweep is not repeated");
}

#[tokio::test]
async fn a_sweep_asked_for_before_the_engine_saw_any_jobs_waits_for_them() {
    let r = Rig::with_store();
    assert_eq!(r.engine.pr_candidates(), None);
    let t = tracker_for(&r);
    t.tracker.on_signal(&QueueSignal::Reconnected);
    let base = r.now();
    cycle_at(&r, &t, base).await;
    assert_eq!(t.probe.count(), 0);

    r.jobs(&[pr_job("c1", COVERED)]);
    cycle_at(&r, &t, base + MIN).await;
    assert_eq!(
        t.probe.take(),
        vec![COVERED_CANON.to_owned()],
        "the pending sweep runs once jobs appear"
    );
    cycle_at(&r, &t, base + 2 * MIN).await;
    assert_eq!(t.probe.count(), 0, "once");
}

#[tokio::test]
async fn a_cycle_probes_at_most_twenty_jobs_oldest_checked_first() {
    let r = Rig::new();
    let url = |n: u32| format!("https://github.com/thehammer/nostromo/pull/{n}");
    let jobs: Vec<MotherJob> = (1..=25)
        .map(|n| pr_job(&format!("j{n}"), &url(n)))
        .collect();
    r.jobs(&jobs);
    settle(&r);
    let t = tracker_for(&r);
    let base = r.now();
    let all: Vec<String> = (1..=25).map(url).collect();

    cycle_at(&r, &t, base).await;
    let first = sorted_urls(t.probe.take());
    assert_eq!(first.len(), 20, "at most twenty per cycle");
    let mut rest: Vec<String> = all.iter().filter(|u| !first.contains(u)).cloned().collect();
    assert_eq!(rest.len(), 5);
    rest.sort();

    // Never-checked jobs go before any that were checked.
    cycle_at(&r, &t, base + MIN).await;
    assert_eq!(sorted_urls(t.probe.take()), rest, "the other five next");

    // All 25 are due again: the twenty checked longest ago go first.
    cycle_at(&r, &t, base + 6 * MIN).await;
    assert_eq!(sorted_urls(t.probe.take()), first);

    cycle_at(&r, &t, base + 7 * MIN).await;
    assert_eq!(sorted_urls(t.probe.take()), rest);
}

#[tokio::test]
async fn a_failed_probe_backs_off_five_ten_twenty_forty_then_sixty_minutes_and_a_success_resets() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    let base = r.now();
    for _ in 0..6 {
        t.probe.answer(FOREIGN_CANON, Err(ProbeError::Exit));
    }
    t.probe.answer(FOREIGN_CANON, Ok(PrState::Open));
    t.probe.answer(FOREIGN_CANON, Err(ProbeError::Timeout));

    // (probe at, then the gap before the next one)
    let series = [
        (0, 5),
        (5, 10),
        (15, 20),
        (35, 40),
        (75, 60),
        (135, 60), // capped, not 80
    ];
    let mut expected = 0;
    for (at, gap) in series {
        cycle_at(&r, &t, base + at * MIN).await;
        expected += 1;
        assert_eq!(t.probe.count(), expected, "probed at +{at} min");
        cycle_at(&r, &t, base + (at + gap) * MIN - SEC).await;
        assert_eq!(
            t.probe.count(),
            expected,
            "not probed a second before +{} min",
            at + gap
        );
    }

    // The success at +195 min resets the series to five minutes...
    cycle_at(&r, &t, base + 195 * MIN).await;
    assert_eq!(t.probe.count(), expected + 1, "the seventh probe succeeds");
    cycle_at(&r, &t, base + 200 * MIN - SEC).await;
    assert_eq!(t.probe.count(), expected + 1);
    // ... so the next failure starts again at five, not at 120.
    cycle_at(&r, &t, base + 200 * MIN).await;
    assert_eq!(t.probe.count(), expected + 2);
    cycle_at(&r, &t, base + 205 * MIN - SEC).await;
    assert_eq!(t.probe.count(), expected + 2);
    cycle_at(&r, &t, base + 205 * MIN).await;
    assert_eq!(
        t.probe.count(),
        expected + 3,
        "five minutes after one failure"
    );
}

#[tokio::test]
async fn a_failed_probe_announces_nothing_and_keeps_the_job_tracked() {
    let r = Rig::new();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    settle(&r);
    let t = tracker_for(&r);
    t.probe.answer(FOREIGN_CANON, Err(ProbeError::Spawn));
    t.probe.answer(FOREIGN_CANON, Ok(PrState::Merged));
    let base = r.now();

    cycle_at(&r, &t, base).await;
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 1);
    assert_eq!(
        r.engine.pr_candidates().map(|c| c.len()),
        Some(1),
        "still tracked"
    );
    cycle_at(&r, &t, base + HOUR + 10 * MIN).await;
    r.after(30 * SEC);
    assert_eq!(r.deliveries().len(), 2, "the retry's merge is announced");
}

// ── poll: who is no longer or never probed ───────────────────────────────────

#[tokio::test]
async fn a_job_is_probed_until_two_weeks_after_it_finished() {
    let r = Rig::new();
    r.jobs(&[
        pr_job("old", "https://github.com/thehammer/a/pull/1").finished(T0 - 15 * DAY),
        pr_job("recent", "https://github.com/thehammer/a/pull/2").finished(T0 - 13 * DAY),
        job(F, "running", "running").with_pr("https://github.com/thehammer/a/pull/3"),
    ]);
    let t = tracker_for(&r);
    cycle_at(&r, &t, T0).await;
    assert_eq!(
        sorted_urls(t.probe.take()),
        vec![
            "https://github.com/thehammer/a/pull/2".to_owned(),
            "https://github.com/thehammer/a/pull/3".to_owned(),
        ],
        "finished 15 days ago is out; finished 13 days ago and running are in"
    );

    // Two days later the 13-day job is 15 days old.
    r.clock.set(T0 + 2 * DAY);
    r.jobs(&[
        pr_job("old", "https://github.com/thehammer/a/pull/1").finished(T0 - 15 * DAY),
        pr_job("recent", "https://github.com/thehammer/a/pull/2").finished(T0 - 13 * DAY),
        job(F, "running", "running").with_pr("https://github.com/thehammer/a/pull/3"),
    ]);
    cycle_at(&r, &t, T0 + 2 * DAY).await;
    assert_eq!(
        t.probe.take(),
        vec!["https://github.com/thehammer/a/pull/3".to_owned()]
    );
}

#[tokio::test]
async fn a_job_that_left_the_feed_is_not_probed() {
    let r = Rig::new();
    r.jobs(&[
        pr_job("stays", "https://github.com/thehammer/a/pull/1"),
        pr_job("leaves", "https://github.com/thehammer/a/pull/2"),
    ]);
    let t = tracker_for(&r);
    r.jobs(&[pr_job("stays", "https://github.com/thehammer/a/pull/1")]);
    cycle_at(&r, &t, r.now()).await;
    assert_eq!(
        t.probe.take(),
        vec!["https://github.com/thehammer/a/pull/1".to_owned()]
    );
}

#[tokio::test]
async fn only_jobs_someone_would_be_told_about_are_probed() {
    // (what the job and the settings are, how the rig is set up before the
    // feed, after it, and whether the job is probed)
    type Setup = fn(&Rig);
    let cases: Vec<(&str, MotherJob, Setup, Setup, bool)> = vec![
        (
            "a verified job (control)",
            job(F, "x", "running").with_pr(FOREIGN),
            |_| {},
            |_| {},
            true,
        ),
        (
            "a quiet focus is still told",
            job(F, "x", "running").with_pr(FOREIGN),
            |r| {
                r.engine
                    .apply_settings(NoticeScope::Focus, Some(F), Some(NotifyLevel::Quiet), None)
                    .unwrap()
            },
            |_| {},
            true,
        ),
        (
            "a job set to quiet is still told",
            job(F, "x", "running")
                .with_pr(FOREIGN)
                .notify(NotifyLevel::Quiet),
            |_| {},
            |_| {},
            true,
        ),
        (
            "an unverified origin",
            job_of_kind(OriginKind::Unverified, Some(F), "x", "running").with_pr(FOREIGN),
            |_| {},
            |_| {},
            false,
        ),
        (
            "an unknown origin",
            job_of_kind(OriginKind::Unknown, None, "x", "running").with_pr(FOREIGN),
            |_| {},
            |_| {},
            false,
        ),
        (
            "a job the user queued",
            job_of_kind(OriginKind::You, None, "x", "running").with_pr(FOREIGN),
            |_| {},
            |_| {},
            false,
        ),
        (
            "a closed focus",
            job(F, "x", "running").with_pr(FOREIGN),
            |_| {},
            |r| r.engine.on_registry(&[], &[F.to_owned()]),
            false,
        ),
        (
            "a job set to off",
            job(F, "x", "running")
                .with_pr(FOREIGN)
                .notify(NotifyLevel::Off),
            |_| {},
            |_| {},
            false,
        ),
        (
            "a focus set to off",
            job(F, "x", "running").with_pr(FOREIGN),
            |r| {
                r.engine
                    .apply_settings(NoticeScope::Focus, Some(F), Some(NotifyLevel::Off), None)
                    .unwrap()
            },
            |_| {},
            false,
        ),
        (
            "the global switch off",
            job(F, "x", "running").with_pr(FOREIGN),
            |r| {
                r.engine
                    .apply_settings(NoticeScope::Global, None, None, Some(false))
                    .unwrap()
            },
            |_| {},
            false,
        ),
        ("no PR url", job(F, "x", "running"), |_| {}, |_| {}, false),
        (
            "a url that is not a PR",
            job(F, "x", "running").with_pr("https://github.com/thehammer/nostromo/issues/3"),
            |_| {},
            |_| {},
            false,
        ),
    ];

    for (what, j, before, after, probed) in cases {
        let r = Rig::new();
        before(&r);
        r.jobs(&[j]);
        after(&r);
        let t = tracker_for(&r);
        t.status.set_connected(false);
        cycle_at(&r, &t, r.now()).await;
        cycle_at(&r, &t, r.now() + 10 * MIN).await;
        assert_eq!(
            t.probe.count() > 0,
            probed,
            "{what}: probed {:?}",
            t.probe.urls()
        );
    }
}

#[tokio::test]
async fn with_the_global_switch_off_there_are_no_candidates_and_no_probes() {
    let r = Rig::new();
    r.engine
        .apply_settings(NoticeScope::Global, None, None, Some(false))
        .unwrap();
    r.jobs(&[pr_job("j1", FOREIGN)]);
    assert_eq!(r.engine.pr_candidates(), Some(Vec::new()));
    let t = tracker_for(&r);
    t.status.set_connected(false);
    t.tracker.on_signal(&QueueSignal::Reconnected);
    let base = r.now();
    for k in 0..5 {
        cycle_at(&r, &t, base + k * 10 * MIN).await;
    }
    assert_eq!(t.probe.count(), 0);
}

#[tokio::test]
async fn nothing_is_probed_when_nothing_is_trackable() {
    let r = Rig::new();
    let t = tracker_for(&r);
    t.status.set_connected(false);
    t.tracker.on_signal(&QueueSignal::Reconnected);
    let base = r.now();
    for k in 0..5 {
        cycle_at(&r, &t, base + k * 10 * MIN).await;
    }
    r.jobs(&[
        job(F, "no-pr", "succeeded"),
        job(F, "odd", "succeeded").with_pr("https://example.com/pull/1"),
    ]);
    for k in 5..10 {
        cycle_at(&r, &t, base + k * 10 * MIN).await;
    }
    assert_eq!(t.probe.count(), 0);
}

// ── GhProbe ──────────────────────────────────────────────────────────────────

/// A runner that records each call and answers with a fixed result.
struct FakeRunner {
    calls: Mutex<Vec<(String, Vec<String>, Duration)>>,
    result: Mutex<Result<CommandOutput, ProbeError>>,
}

impl FakeRunner {
    fn answering(result: Result<CommandOutput, ProbeError>) -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            result: Mutex::new(result),
        })
    }

    fn printing(stdout: &str) -> Arc<Self> {
        Self::answering(Ok(CommandOutput {
            success: true,
            stdout: stdout.to_owned(),
        }))
    }

    fn calls(&self) -> Vec<(String, Vec<String>, Duration)> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl CommandRunner for FakeRunner {
    async fn run(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<CommandOutput, ProbeError> {
        self.calls
            .lock()
            .unwrap()
            .push((program.to_owned(), args.to_vec(), timeout));
        self.result.lock().unwrap().clone()
    }
}

fn pr5() -> PrRef {
    PrRef {
        owner: "o".to_owned(),
        name: "n".to_owned(),
        number: 5,
    }
}

async fn state_from(stdout: &str) -> Result<PrState, ProbeError> {
    GhProbe::new(FakeRunner::printing(stdout), "gh".to_owned())
        .state(&pr5())
        .await
}

#[tokio::test]
async fn gh_is_asked_for_the_prs_state_and_merge_time_by_its_canonical_url() {
    let runner = FakeRunner::printing(r#"{"state":"OPEN","mergedAt":null}"#);
    let probe = GhProbe::new(runner.clone(), "/opt/bin/gh".to_owned());
    let pr = PrRef::parse("https://github.com/O/N/pull/5/files?x=1").unwrap();
    probe.state(&pr).await.unwrap();

    let calls = runner.calls();
    assert_eq!(calls.len(), 1);
    let (program, args, timeout) = &calls[0];
    assert_eq!(program, "/opt/bin/gh");
    assert_eq!(
        args,
        &[
            "pr".to_owned(),
            "view".to_owned(),
            "https://github.com/o/n/pull/5".to_owned(),
            "--json".to_owned(),
            "state,mergedAt".to_owned(),
        ]
    );
    assert_eq!(*timeout, GH_TIMEOUT);
    assert_eq!(GH_TIMEOUT, Duration::from_secs(20));
}

#[tokio::test]
async fn gh_output_is_read_as_merged_closed_or_open() {
    assert_eq!(
        state_from(r#"{"state":"MERGED","mergedAt":"2026-10-30T10:00:00Z"}"#).await,
        Ok(PrState::Merged)
    );
    assert_eq!(
        state_from(r#"{"state":"CLOSED","mergedAt":null}"#).await,
        Ok(PrState::Closed)
    );
    assert_eq!(
        state_from("{\"state\":\"OPEN\",\"mergedAt\":null}\n").await,
        Ok(PrState::Open)
    );
}

#[tokio::test]
async fn gh_output_that_is_not_a_known_state_is_a_parse_error() {
    for stdout in [
        r#"{"state":"DRAFT","mergedAt":null}"#,
        r#"{"state":"merged-ish"}"#,
        r#"{"mergedAt":null}"#,
        "not json",
        "",
        "[]",
    ] {
        assert_eq!(
            state_from(stdout).await,
            Err(ProbeError::Parse),
            "{stdout:?}"
        );
    }
}

#[tokio::test]
async fn a_gh_that_fails_or_cannot_run_is_an_error_of_that_class() {
    let failed = FakeRunner::answering(Ok(CommandOutput {
        success: false,
        stdout: r#"{"state":"MERGED","mergedAt":"2026-10-30T10:00:00Z"}"#.to_owned(),
    }));
    assert_eq!(
        GhProbe::new(failed, "gh".to_owned()).state(&pr5()).await,
        Err(ProbeError::Exit),
        "a failure status is a failure whatever it printed"
    );
    for error in [ProbeError::Timeout, ProbeError::Spawn] {
        let runner = FakeRunner::answering(Err(error));
        assert_eq!(
            GhProbe::new(runner, "gh".to_owned()).state(&pr5()).await,
            Err(error)
        );
    }
}

// ── MF2b-1: from the relay's socket to the focus that queued the job ─────────

#[tokio::test]
async fn a_merge_the_relay_sends_wakes_the_focus_that_queued_the_job() {
    use futures::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;

    let r = Rig::new();
    r.jobs(&[pr_job("j1", COVERED)]);
    settle(&r);

    // A relay that acks the subscription and reports the merge.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let mut ws = tokio_tungstenite::accept_async(stream).await.expect("ws");
        let _subscribe = ws.next().await;
        let frames = [
            r#"{"type":"ack","events":["pr.merged","pr.closed"]}"#,
            r#"{"type":"event","event_type":"pr.merged","repo":"Carefeed/app","number":7,"merged":true}"#,
        ];
        for frame in frames {
            ws.send(Message::Text(frame.to_owned()))
                .await
                .expect("send");
        }
        while ws.next().await.is_some() {}
    });

    let mut hub = RelayHub::new();
    let signals = hub.channel();
    let status = hub.status();
    let probe = Arc::new(FakeProbe::default());
    let clock: Arc<dyn Clock> = Arc::new(r.clock.clone());
    let tracker = PrTracker::new(r.engine.clone(), probe.clone(), status, clock);
    let tracker_task = tracker.spawn(signals);
    let relay_task = spawn_with(format!("ws://{addr}/subscribe"), "tok".into(), hub);

    // Wait for the engine to hear of the merge (a condition, not a time).
    let mut changes = r.engine.changes();
    loop {
        if r.notice("j1").last_state == Some(JobEvent::PrMerged) {
            break;
        }
        changes.changed().await.expect("the engine is alive");
    }

    r.after(30 * SEC);
    let ds = r.deliveries();
    assert_eq!(ds.len(), 2, "exactly one delivery for the merge: {ds:#?}");
    assert_eq!(ds[1].tag, F);
    assert_eq!(state_of(&ds[1].fresh, "j1").as_deref(), Some("pr_merged"));
    r.after(HOUR);
    assert_eq!(r.deliveries().len(), 2, "and no more");

    relay_task.abort();
    tracker_task.abort();
    server.abort();
}

// ── MF2b-8: nothing sensitive in the log or the audit ────────────────────────

#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

#[tokio::test]
async fn nothing_the_tracker_logs_at_trace_or_audits_carries_a_repo_title_or_command_output() {
    let captured = Captured::default();
    let writer = captured.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .finish();
    let _guard = tracing::subscriber::set_default(subscriber);
    tracing::trace!("pr-canary-capture-check");

    let secret = |n: u32| format!("https://github.com/SECRET-ORG/SECRET-REPO/pull/{n}");
    let r = Rig::with_store();
    r.jobs(&[]);
    r.jobs(&[
        pr_job("polled", &secret(9)).titled("SECRET-TITLE"),
        pr_job("relayed", &secret(10)).titled("SECRET-TITLE"),
    ]);
    settle(&r);

    // The poll goes through the real GhProbe, on a runner that fails every
    // way and prints command output the log must never carry.
    let runner = FakeRunner::answering(Err(ProbeError::Timeout));
    let probe = Arc::new(GhProbe::new(
        runner.clone(),
        "/opt/SECRET-GH-PATH/gh".to_owned(),
    ));
    let status = Arc::new(RelayStatus::new());
    status.set_connected(true);
    let clock: Arc<dyn Clock> = Arc::new(r.clock.clone());
    let tracker = PrTracker::new(r.engine.clone(), probe, status, clock);

    // Relay events: ignored ones, a quiet close, and a merge.
    tracker.on_signal(&QueueSignal::Event(RelayEvent {
        event_type: "pr.closed".to_owned(),
        repo: Some("SECRET-ORG/SECRET-REPO".to_owned()),
        number: Some(77),
        merged: Some(false),
        title: Some("SECRET-TITLE".to_owned()),
        url: Some(secret(77)),
        ..Default::default()
    }));
    tracker.on_signal(&QueueSignal::Event(RelayEvent {
        event_type: "pr.merged".to_owned(),
        repo: Some("SECRET-ORG/SECRET-REPO".to_owned()),
        number: Some(10),
        title: Some("SECRET-TITLE".to_owned()),
        url: Some(secret(10)),
        ..Default::default()
    }));
    tracker.on_signal(&QueueSignal::Reconnected);

    let base = r.now();
    let script: [(i64, Result<CommandOutput, ProbeError>); 6] = [
        (0, Err(ProbeError::Timeout)),
        (
            5,
            Ok(CommandOutput {
                success: false,
                stdout: "SECRET-STDERR gh: could not resolve SECRET-ORG/SECRET-REPO".to_owned(),
            }),
        ),
        (
            15,
            Ok(CommandOutput {
                success: true,
                stdout: "SECRET-STDERR is not json".to_owned(),
            }),
        ),
        (35, Err(ProbeError::Spawn)),
        (
            75,
            Ok(CommandOutput {
                success: true,
                stdout: r#"{"state":"OPEN","mergedAt":null}"#.to_owned(),
            }),
        ),
        (
            80,
            Ok(CommandOutput {
                success: true,
                stdout: r#"{"state":"MERGED","mergedAt":"2026-10-30T10:00:00Z"}"#.to_owned(),
            }),
        ),
    ];
    for (minute, answer) in script {
        *runner.result.lock().unwrap() = answer;
        r.clock.set(base + minute * MIN);
        tracker.poll_cycle().await;
    }
    r.after(30 * SEC);
    assert!(
        !runner.calls().is_empty(),
        "the poll ran through the probe: {:?}",
        runner.calls().len()
    );
    assert!(
        r.deliveries().len() >= 2,
        "both merges were announced: {:#?}",
        r.deliveries()
    );

    let logged = captured.text();
    assert!(
        logged.contains("pr-canary-capture-check"),
        "the capture works: {logged}"
    );
    let audit = std::fs::read_to_string(r.audit_path()).unwrap_or_default();
    for sentinel in [
        "SECRET-ORG",
        "SECRET-REPO",
        "SECRET-TITLE",
        "SECRET-STDERR",
        "SECRET-GH-PATH",
    ] {
        assert!(
            !logged.contains(sentinel),
            "{sentinel} in the log:\n{logged}"
        );
        assert!(
            !audit.contains(sentinel),
            "{sentinel} in the audit:\n{audit}"
        );
    }
}
