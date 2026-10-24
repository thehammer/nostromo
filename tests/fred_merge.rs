//! Multi-account Fred: the merged inbox and Today list, and the detail router.
//!
//! The merge functions are pure, so every test here builds per-account
//! snapshots exactly as the sources publish them (using the public
//! `failed` / `rate_limited` / `unauthenticated_with` constructors for the
//! failure shapes) and checks what the user would see.
//!
//! The rule that matters most (the rate-limit contract): a merged snapshot is
//! NEVER `Fresh` or `Empty` while any account is degraded or signed out, and a
//! failure is never swallowed: the merged error says which account failed.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Duration as ChronoDuration, TimeZone, Utc};
use nostromo::config::{FredAccount, FredProvider};
use nostromo::data::fred_accounts::{merge_calendars, merge_mailboxes, FredDetailRouter};
use nostromo::data::fred_calendar::{CalendarEvent, CalendarSnapshot};
use nostromo::data::fred_mailbox::{MailboxItem, MailboxSnapshot};
use nostromo::data::graph_client::DeviceFlowPrompt;
use nostromo::data::work::model::{SourceState, WorkDetail, WorkError};
use nostromo::data::work::service::FredDetailService;
use serde_json::Value;

// ═════════════════════════════════════════════════════════════════════════════
// Builders
// ═════════════════════════════════════════════════════════════════════════════

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 10, 12, 0, 0).unwrap()
}

fn at(minutes_from_now: i64) -> DateTime<Utc> {
    now() + ChronoDuration::minutes(minutes_from_now)
}

fn account(label: &str, provider: FredProvider) -> FredAccount {
    FredAccount {
        label: label.to_owned(),
        provider,
        email: None,
        token_cache: PathBuf::from(format!("/nonexistent/{label}.json")),
    }
}

fn personal() -> FredAccount {
    account("personal", FredProvider::Google)
}

fn family() -> FredAccount {
    account("family", FredProvider::Google)
}

fn work() -> FredAccount {
    account("work", FredProvider::Microsoft)
}

fn mail_item(id: &str, minutes_ago: i64, is_read: bool) -> MailboxItem {
    MailboxItem {
        id: id.to_owned(),
        from: format!("sender-of-{id} <{id}@example.com>"),
        subject: format!("subject of {id}"),
        received_at: Some(at(-minutes_ago)),
        is_read,
        ..Default::default()
    }
}

/// A healthy mailbox: last successful fetch `updated_minutes_ago` minutes ago.
fn fresh_mailbox(
    items: Vec<MailboxItem>,
    unread: usize,
    updated_minutes_ago: i64,
) -> MailboxSnapshot {
    let updated = at(-updated_minutes_ago);
    MailboxSnapshot {
        generated_at: Some(updated),
        unread_count: unread,
        state: if items.is_empty() && unread == 0 {
            SourceState::Empty
        } else {
            SourceState::Fresh
        },
        items,
        updated_at: Some(updated),
        ..Default::default()
    }
}

fn prompt(kind: &str) -> DeviceFlowPrompt {
    DeviceFlowPrompt {
        verification_uri: "https://accounts.example.test/signin".to_owned(),
        user_code: if kind == "browser" {
            String::new()
        } else {
            "ABCD-1234".to_owned()
        },
        expires_at: at(10),
        kind: kind.to_owned(),
        account: None,
        provider: None,
    }
}

fn fresh_calendar(events: Vec<CalendarEvent>, updated_minutes_ago: i64) -> CalendarSnapshot {
    let updated = at(-updated_minutes_ago);
    CalendarSnapshot {
        generated_at: Some(updated),
        state: if events.is_empty() {
            SourceState::Empty
        } else {
            SourceState::Fresh
        },
        events,
        sweater: "sage".to_owned(),
        updated_at: Some(updated),
        ..Default::default()
    }
}

fn cal_event(id: &str, start_in_minutes: i64, dedupe: Option<&str>) -> CalendarEvent {
    CalendarEvent {
        id: id.to_owned(),
        start: Some(at(start_in_minutes)),
        end: Some(at(start_in_minutes + 30)),
        title: format!("title of {id}"),
        status: "accepted".to_owned(),
        response_status: "accepted".to_owned(),
        dedupe_key: dedupe.map(str::to_owned),
        ..Default::default()
    }
}

fn mail_ids(s: &MailboxSnapshot) -> Vec<&str> {
    s.items.iter().map(|i| i.id.as_str()).collect()
}

fn cal_ids(s: &CalendarSnapshot) -> Vec<&str> {
    s.events.iter().map(|e| e.id.as_str()).collect()
}

fn merge_mail(parts: &[(&FredAccount, Option<&MailboxSnapshot>)]) -> MailboxSnapshot {
    merge_mailboxes(now(), parts)
}

fn merge_cal(parts: &[(&FredAccount, Option<&CalendarSnapshot>)]) -> CalendarSnapshot {
    merge_calendars(now(), parts)
}

// ═════════════════════════════════════════════════════════════════════════════
// Mailbox: the happy path
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn two_fresh_accounts_interleave_by_time_with_account_prefixed_ids() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(
        vec![mail_item("p-new", 30, false), mail_item("p-old", 90, false)],
        4,
        1,
    );
    let fm = fresh_mailbox(
        vec![mail_item("f-new", 10, false), mail_item("f-mid", 60, false)],
        3,
        2,
    );

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(
        mail_ids(&merged),
        vec![
            "family:f-new",
            "personal:p-new",
            "family:f-mid",
            "personal:p-old"
        ],
        "one list, newest first, each id prefixed with its account label"
    );
    let accounts: Vec<Option<&str>> = merged.items.iter().map(|i| i.account.as_deref()).collect();
    assert_eq!(
        accounts,
        vec![
            Some("family"),
            Some("personal"),
            Some("family"),
            Some("personal")
        ]
    );
    assert_eq!(merged.unread_count, 7, "unread is the sum across accounts");
    assert_eq!(merged.state, SourceState::Fresh);
    assert!(!merged.stale && merged.error.is_none() && merged.auth_prompt.is_none());
    assert_eq!(merged.accounts.len(), 2);
    assert_eq!(merged.generated_at, Some(now()));
}

#[test]
fn merged_rows_keep_their_content_and_only_the_id_and_account_change() {
    let p = personal();
    let mut original = mail_item("m1", 5, false);
    original.vip = true;
    original.is_invite = true;
    original.web_link = Some("https://mail.google.com/mail/?authuser=a%40b.c#all/t1".to_owned());
    let pm = fresh_mailbox(vec![original.clone()], 1, 1);

    let merged = merge_mail(&[(&p, Some(&pm))]);

    let row = &merged.items[0];
    assert_eq!(row.id, "personal:m1");
    assert_eq!(row.account.as_deref(), Some("personal"));
    assert_eq!(row.from, original.from);
    assert_eq!(row.subject, original.subject);
    assert_eq!(row.received_at, original.received_at);
    assert!(row.vip && row.is_invite && !row.is_read);
    assert_eq!(row.web_link, original.web_link);
}

#[test]
fn unread_rows_come_before_read_rows_across_accounts_like_a_single_inbox() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p-read-newest", 1, true)], 0, 1);
    let fm = fresh_mailbox(vec![mail_item("f-unread-old", 500, false)], 1, 1);

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(
        mail_ids(&merged),
        vec!["family:f-unread-old", "personal:p-read-newest"]
    );
}

#[test]
fn two_empty_accounts_are_empty() {
    let (p, f) = (personal(), family());
    let (pm, fm) = (fresh_mailbox(vec![], 0, 1), fresh_mailbox(vec![], 0, 1));

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::Empty);
    assert!(merged.items.is_empty() && merged.unread_count == 0);
}

#[test]
fn one_account_with_mail_and_one_empty_is_fresh() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 1);
    let fm = fresh_mailbox(vec![], 0, 1);

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::Fresh);
    assert_eq!(mail_ids(&merged), vec!["personal:p1"]);
}

#[test]
fn a_microsoft_and_a_google_account_merge_the_same_way() {
    let (p, w) = (personal(), work());
    let pm = fresh_mailbox(vec![mail_item("g1", 20, false)], 1, 1);
    let wm = fresh_mailbox(vec![mail_item("AAMk=", 10, false)], 1, 1);

    let merged = merge_mail(&[(&p, Some(&pm)), (&w, Some(&wm))]);

    assert_eq!(mail_ids(&merged), vec!["work:AAMk=", "personal:g1"]);
    let providers: Vec<&str> = merged
        .accounts
        .iter()
        .map(|a| a.provider.as_str())
        .collect();
    assert_eq!(providers, vec!["google", "microsoft"]);
}

// ═════════════════════════════════════════════════════════════════════════════
// Mailbox: degraded accounts
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_failed_account_with_no_data_makes_the_merge_stale_and_never_hides_the_failure() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(
        vec![mail_item("p1", 5, false), mail_item("p2", 9, false)],
        5,
        1,
    );
    let fm = MailboxSnapshot::failed(None, "Mail is unavailable right now".to_owned());
    assert_eq!(
        fm.state,
        SourceState::Error,
        "precondition: how a source reports it"
    );

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::Stale, "{merged:?}");
    assert!(merged.stale);
    assert_eq!(
        mail_ids(&merged),
        vec!["personal:p1", "personal:p2"],
        "only the healthy account contributes rows"
    );
    assert_eq!(
        merged.unread_count, 5,
        "the failed account adds nothing, not a made-up zero"
    );
    let error = merged.error.as_deref().expect("the failure is reported");
    assert!(error.starts_with("family: "), "names the account: {error}");
    assert!(error.contains("Mail is unavailable right now"), "{error}");
    assert!(
        !error.contains("personal"),
        "the healthy account is not blamed: {error}"
    );
}

#[test]
fn a_signed_out_account_makes_the_merge_unauthenticated_and_keeps_the_other_accounts_mail() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 1);
    let fm = MailboxSnapshot::unauthenticated_with(
        prompt("browser"),
        "Sign in to Google (family) to see your mail".to_owned(),
    );

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::Unauthenticated);
    let prompt = merged
        .auth_prompt
        .as_ref()
        .expect("the sign-in prompt is carried");
    assert_eq!(
        prompt.account.as_deref(),
        Some("family"),
        "says which account to sign in"
    );
    assert_eq!(prompt.provider.as_deref(), Some("google"));
    assert_eq!(prompt.kind, "browser");
    assert_eq!(
        mail_ids(&merged),
        vec!["personal:p1"],
        "fresh mail stays visible"
    );
    assert_eq!(merged.unread_count, 1);
    assert!(
        merged
            .error
            .as_deref()
            .is_some_and(|e| e.starts_with("family: ")),
        "{:?}",
        merged.error
    );
}

#[test]
fn the_prompt_comes_from_the_signed_out_account_even_when_it_is_listed_first() {
    let (p, f) = (personal(), family());
    let pm = MailboxSnapshot::unauthenticated_with(prompt("device_code"), "Sign in".to_owned());
    let fm = fresh_mailbox(vec![mail_item("f1", 5, false)], 1, 1);

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::Unauthenticated);
    let prompt = merged.auth_prompt.expect("prompt");
    assert_eq!(prompt.account.as_deref(), Some("personal"));
    assert_eq!(
        prompt.user_code, "ABCD-1234",
        "a device-code prompt keeps its code"
    );
}

#[test]
fn accounts_that_have_not_reported_yet_are_loading() {
    let (p, f) = (personal(), family());

    let none = merge_mail(&[(&p, None), (&f, None)]);
    assert_eq!(none.state, SourceState::Loading);
    assert!(none.items.is_empty());

    let loading = MailboxSnapshot::default();
    assert_eq!(loading.state, SourceState::Loading, "precondition");
    let explicit = merge_mail(&[(&p, Some(&loading)), (&f, Some(&loading))]);
    assert_eq!(explicit.state, SourceState::Loading);
}

#[test]
fn two_rate_limited_accounts_with_no_data_are_rate_limited_until_the_earlier_retry() {
    let (p, f) = (personal(), family());
    let (soon, later) = (at(2), at(9));
    let pm = MailboxSnapshot::rate_limited(None, "Google is rate limiting".to_owned(), later);
    let fm = MailboxSnapshot::rate_limited(None, "Google is rate limiting".to_owned(), soon);

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.state, SourceState::RateLimited, "{merged:?}");
    assert_eq!(
        merged.retry_at,
        Some(soon),
        "the earliest time anyone will ask again"
    );
    assert!(merged.items.is_empty());
    assert!(merged.error.is_some());
}

#[test]
fn updated_at_is_the_oldest_last_good_fetch_among_accounts_with_data() {
    let (p, f, w) = (personal(), family(), work());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 3);
    let fm = fresh_mailbox(vec![mail_item("f1", 5, false)], 1, 20);
    // No data yet: must not drag the merged timestamp to "never".
    let wm = MailboxSnapshot::failed(None, "down".to_owned());

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm)), (&w, Some(&wm))]);

    assert_eq!(merged.updated_at, Some(at(-20)));
}

#[test]
fn a_stale_account_reports_its_last_good_fetch_as_the_merged_updated_at() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 1);
    let good_then = fresh_mailbox(vec![mail_item("f1", 5, false)], 1, 45);
    let fm = MailboxSnapshot::failed(Some(&good_then), "Mail fetch failed".to_owned());
    assert_eq!(fm.state, SourceState::Stale, "precondition");

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(
        merged.updated_at,
        Some(at(-45)),
        "the merge is only as fresh as its stalest part"
    );
    assert_eq!(merged.state, SourceState::Stale);
    assert_eq!(
        mail_ids(&merged),
        vec!["personal:p1", "family:f1"],
        "stale rows are still shown"
    );
    assert_eq!(merged.unread_count, 2);
}

#[test]
fn per_account_health_is_reported_for_every_account_in_config_order() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 7);
    let fm = MailboxSnapshot::failed(None, "Mail fetch failed".to_owned());

    let merged = merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]);

    assert_eq!(merged.accounts.len(), 2);
    let (a, b) = (&merged.accounts[0], &merged.accounts[1]);
    assert_eq!(
        (a.account.as_str(), a.provider.as_str()),
        ("personal", "google")
    );
    assert_eq!(a.state, SourceState::Fresh);
    assert_eq!(a.updated_at, Some(at(-7)));
    assert!(a.error.is_none());
    assert_eq!(
        (b.account.as_str(), b.provider.as_str()),
        ("family", "google")
    );
    assert_eq!(b.state, SourceState::Error);
    assert_eq!(
        b.error.as_deref(),
        Some("Mail fetch failed"),
        "per-account errors are not prefixed"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// The matrix: no combination of account states may look healthy when it is not
// ═════════════════════════════════════════════════════════════════════════════

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Loading,
    Fresh,
    Empty,
    Stale,
    RateLimitedWithData,
    RateLimitedNoData,
    Error,
    Unauthenticated,
    NotConfigured,
}

const KINDS: [Kind; 9] = [
    Kind::Loading,
    Kind::Fresh,
    Kind::Empty,
    Kind::Stale,
    Kind::RateLimitedWithData,
    Kind::RateLimitedNoData,
    Kind::Error,
    Kind::Unauthenticated,
    Kind::NotConfigured,
];

impl Kind {
    fn state(self) -> SourceState {
        match self {
            Kind::Loading => SourceState::Loading,
            Kind::Fresh => SourceState::Fresh,
            Kind::Empty => SourceState::Empty,
            Kind::Stale => SourceState::Stale,
            Kind::RateLimitedWithData | Kind::RateLimitedNoData => SourceState::RateLimited,
            Kind::Error => SourceState::Error,
            Kind::Unauthenticated => SourceState::Unauthenticated,
            Kind::NotConfigured => SourceState::NotConfigured,
        }
    }

    fn degraded(self) -> bool {
        matches!(
            self,
            Kind::Stale
                | Kind::RateLimitedWithData
                | Kind::RateLimitedNoData
                | Kind::Error
                | Kind::NotConfigured
        )
    }

    fn has_error(self) -> bool {
        self.degraded() || self == Kind::Unauthenticated
    }

    /// Rows or events this account shows in the merge.
    fn rows(self) -> usize {
        match self {
            Kind::Fresh | Kind::Stale | Kind::RateLimitedWithData => 1,
            _ => 0,
        }
    }

    fn mailbox(self, tag: &str) -> Option<MailboxSnapshot> {
        let good = || fresh_mailbox(vec![mail_item(&format!("{tag}1"), 5, false)], 1, 30);
        Some(match self {
            Kind::Loading => return None,
            Kind::Fresh => good(),
            Kind::Empty => fresh_mailbox(vec![], 0, 30),
            Kind::Stale => MailboxSnapshot::failed(Some(&good()), "stale reason".to_owned()),
            Kind::RateLimitedWithData => {
                MailboxSnapshot::rate_limited(Some(&good()), "throttled".to_owned(), at(5))
            }
            Kind::RateLimitedNoData => {
                MailboxSnapshot::rate_limited(None, "throttled".to_owned(), at(5))
            }
            Kind::Error => MailboxSnapshot::failed(None, "broken".to_owned()),
            Kind::Unauthenticated => {
                MailboxSnapshot::unauthenticated_with(prompt("browser"), "sign in".to_owned())
            }
            Kind::NotConfigured => MailboxSnapshot {
                generated_at: Some(at(0)),
                state: SourceState::NotConfigured,
                error: Some("not set up".to_owned()),
                ..Default::default()
            },
        })
    }

    fn calendar(self, tag: &str) -> Option<CalendarSnapshot> {
        let good = || fresh_calendar(vec![cal_event(&format!("{tag}1"), 60, None)], 30);
        Some(match self {
            Kind::Loading => return None,
            Kind::Fresh => good(),
            Kind::Empty => fresh_calendar(vec![], 30),
            Kind::Stale => CalendarSnapshot::failed(Some(&good()), "stale reason".to_owned()),
            Kind::RateLimitedWithData => {
                CalendarSnapshot::rate_limited(Some(&good()), "throttled".to_owned(), at(5))
            }
            Kind::RateLimitedNoData => {
                CalendarSnapshot::rate_limited(None, "throttled".to_owned(), at(5))
            }
            Kind::Error => CalendarSnapshot::failed(None, "broken".to_owned()),
            Kind::Unauthenticated => {
                CalendarSnapshot::unauthenticated_with(prompt("browser"), "sign in".to_owned())
            }
            Kind::NotConfigured => CalendarSnapshot {
                generated_at: Some(at(0)),
                sweater: "sage".to_owned(),
                state: SourceState::NotConfigured,
                error: Some("not set up".to_owned()),
                ..Default::default()
            },
        })
    }
}

/// What the matrix checks, identical for the mailbox and the calendar.
struct Outcome {
    state: SourceState,
    stale: bool,
    error: Option<String>,
    has_prompt: bool,
    retry_at: Option<DateTime<Utc>>,
    rows: usize,
    account_states: Vec<(String, SourceState)>,
}

fn check_pair(a: Kind, b: Kind, o: &Outcome) {
    let ctx = format!(
        "{a:?} + {b:?} -> {:?} (stale={}, error={:?})",
        o.state, o.stale, o.error
    );

    // Never healthy while an account is degraded or signed out.
    if a.degraded() || b.degraded() || a == Kind::Unauthenticated || b == Kind::Unauthenticated {
        assert!(
            !matches!(o.state, SourceState::Fresh | SourceState::Empty),
            "claims health while an account is not healthy: {ctx}"
        );
    }
    if a == Kind::Unauthenticated || b == Kind::Unauthenticated {
        assert_eq!(o.state, SourceState::Unauthenticated, "{ctx}");
    }
    if a == Kind::Loading && b == Kind::Loading {
        assert_eq!(o.state, SourceState::Loading, "{ctx}");
    }
    // An account that has not reported yet may hold anything, so the merge is
    // never Fresh or Empty while one is still loading.
    if a == Kind::Loading || b == Kind::Loading {
        assert!(
            !matches!(o.state, SourceState::Fresh | SourceState::Empty),
            "claims health while an account is still loading: {ctx}"
        );
    }
    if [a, b]
        .iter()
        .all(|k| matches!(k, Kind::Fresh | Kind::Empty))
    {
        let expected = if a == Kind::Fresh || b == Kind::Fresh {
            SourceState::Fresh
        } else {
            SourceState::Empty
        };
        assert_eq!(o.state, expected, "{ctx}");
    }

    // A failure is always told, and names the account it came from.
    if a.has_error() || b.has_error() {
        let error = o
            .error
            .as_deref()
            .unwrap_or_else(|| panic!("failure swallowed: {ctx}"));
        if a.has_error() {
            assert!(error.contains("personal: "), "{ctx}");
        }
        if b.has_error() {
            assert!(error.contains("family: "), "{ctx}");
        }
    } else {
        assert!(o.error.is_none(), "an error appeared from nowhere: {ctx}");
    }

    // The same honesty rules every source snapshot obeys.
    match o.state {
        SourceState::Fresh | SourceState::Empty => {
            assert!(o.error.is_none() && !o.stale && !o.has_prompt, "{ctx}")
        }
        SourceState::Stale => assert!(o.stale && o.error.is_some(), "{ctx}"),
        SourceState::Error | SourceState::NotConfigured => assert!(o.error.is_some(), "{ctx}"),
        SourceState::RateLimited => assert!(o.retry_at.is_some() && o.error.is_some(), "{ctx}"),
        SourceState::Unauthenticated => assert!(o.has_prompt && o.error.is_some(), "{ctx}"),
        SourceState::Loading => {}
    }

    // Nothing an account has to show is dropped; nothing is invented.
    assert_eq!(o.rows, a.rows() + b.rows(), "{ctx}");

    // Every account's own state is reported, in order.
    assert_eq!(
        o.account_states,
        vec![
            ("personal".to_owned(), a.state()),
            ("family".to_owned(), b.state())
        ],
        "{ctx}"
    );
}

#[test]
fn mailbox_merge_is_never_healthy_while_any_account_is_not_across_every_pair_of_states() {
    let (p, f) = (personal(), family());
    for a in KINDS {
        for b in KINDS {
            let (pm, fm) = (a.mailbox("p"), b.mailbox("f"));
            let merged = merge_mail(&[(&p, pm.as_ref()), (&f, fm.as_ref())]);
            check_pair(
                a,
                b,
                &Outcome {
                    state: merged.state,
                    stale: merged.stale,
                    error: merged.error.clone(),
                    has_prompt: merged.auth_prompt.is_some(),
                    retry_at: merged.retry_at,
                    rows: merged.items.len(),
                    account_states: merged
                        .accounts
                        .iter()
                        .map(|s| (s.account.clone(), s.state))
                        .collect(),
                },
            );
        }
    }
}

#[test]
fn calendar_merge_is_never_healthy_while_any_account_is_not_across_every_pair_of_states() {
    let (p, f) = (personal(), family());
    for a in KINDS {
        for b in KINDS {
            let (pc, fc) = (a.calendar("p"), b.calendar("f"));
            let merged = merge_cal(&[(&p, pc.as_ref()), (&f, fc.as_ref())]);
            check_pair(
                a,
                b,
                &Outcome {
                    state: merged.state,
                    stale: merged.stale,
                    error: merged.error.clone(),
                    has_prompt: merged.auth_prompt.is_some(),
                    retry_at: merged.retry_at,
                    rows: merged.events.len(),
                    account_states: merged
                        .accounts
                        .iter()
                        .map(|s| (s.account.clone(), s.state))
                        .collect(),
                },
            );
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Calendar
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn calendars_interleave_by_start_time_with_prefixed_ids_and_account() {
    let (p, f) = (personal(), family());
    let pc = fresh_calendar(
        vec![cal_event("p1", 30, None), cal_event("p2", 180, None)],
        1,
    );
    let fc = fresh_calendar(vec![cal_event("f1", 90, None)], 1);

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert_eq!(
        cal_ids(&merged),
        vec!["personal:p1", "family:f1", "personal:p2"]
    );
    let owners: Vec<Option<&str>> = merged.events.iter().map(|e| e.account.as_deref()).collect();
    assert_eq!(
        owners,
        vec![Some("personal"), Some("family"), Some("personal")]
    );
    assert_eq!(merged.state, SourceState::Fresh);
    assert_eq!(merged.accounts.len(), 2);
    assert_eq!(merged.generated_at, Some(now()));
}

#[test]
fn a_meeting_invited_to_both_accounts_is_listed_once_from_the_first_account() {
    let (p, f) = (personal(), family());
    let pc = fresh_calendar(
        vec![cal_event("p-copy", 60, Some("uid-standup@example.com"))],
        1,
    );
    let fc = fresh_calendar(
        vec![
            cal_event("f-copy", 60, Some("uid-standup@example.com")),
            cal_event("f-own", 120, Some("uid-school@example.com")),
        ],
        1,
    );

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);
    assert_eq!(cal_ids(&merged), vec!["personal:p-copy", "family:f-own"]);
    assert_eq!(merged.events[0].account.as_deref(), Some("personal"));

    // "First" means config order, not alphabetical or anything else.
    let flipped = merge_cal(&[(&f, Some(&fc)), (&p, Some(&pc))]);
    assert_eq!(cal_ids(&flipped), vec!["family:f-copy", "family:f-own"]);
}

#[test]
fn recurring_instances_and_events_without_a_shared_key_are_not_mistaken_for_duplicates() {
    let (p, f) = (personal(), family());
    // Same series (same uid) at a different time is a different occurrence.
    let pc = fresh_calendar(vec![cal_event("p-mon", 60, Some("uid-weekly"))], 1);
    let fc = fresh_calendar(
        vec![
            cal_event("f-tue", 60 + 24 * 60, Some("uid-weekly")),
            // No key at all: two unkeyed events at the same time stay separate.
            cal_event("f-plain", 60, None),
        ],
        1,
    );
    let pc = CalendarSnapshot {
        events: [pc.events, vec![cal_event("p-plain", 60, None)]].concat(),
        ..pc
    };

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert_eq!(merged.events.len(), 4, "{:?}", cal_ids(&merged));
    for id in [
        "personal:p-mon",
        "family:f-tue",
        "personal:p-plain",
        "family:f-plain",
    ] {
        assert!(
            cal_ids(&merged).contains(&id),
            "{id} missing from {:?}",
            cal_ids(&merged)
        );
    }
}

#[test]
fn next_meeting_and_sweater_are_recomputed_over_the_merged_list() {
    let (p, f) = (personal(), family());
    // On its own the personal calendar's next meeting is 3 hours out (sage).
    let pc = CalendarSnapshot {
        next: Some(nostromo::data::fred_calendar::NextEvent {
            title: "title of p-late".to_owned(),
            in_minutes: 180,
        }),
        ..fresh_calendar(vec![cal_event("p-late", 180, None)], 1)
    };
    // The family calendar has one in 10 minutes (amber).
    let fc = fresh_calendar(vec![cal_event("f-soon", 10, None)], 1);

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    let next = merged.next.expect("a next meeting");
    assert_eq!(next.title, "title of f-soon");
    assert_eq!(next.in_minutes, 10);
    assert_eq!(merged.sweater, "amber");
}

#[test]
fn next_meeting_ignores_events_that_are_over_cancelled_declined_or_all_day() {
    let (p, f) = (personal(), family());
    let mut cancelled = cal_event("cancelled", 5, None);
    cancelled.status = "cancelled".to_owned();
    cancelled.is_cancelled = true;
    let mut all_day = cal_event("all-day", 1, None);
    all_day.is_all_day = true;
    let pc = fresh_calendar(vec![cancelled, all_day, cal_event("past", -90, None)], 1);
    let fc = fresh_calendar(vec![cal_event("real", 3, None)], 1);

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    let next = merged.next.expect("next");
    assert_eq!(next.title, "title of real");
    assert_eq!(merged.sweater, "red", "3 minutes away");
}

#[test]
fn with_no_upcoming_meeting_there_is_no_next_and_the_sweater_is_calm() {
    let (p, f) = (personal(), family());
    let pc = fresh_calendar(vec![cal_event("past", -90, None)], 1);
    let fc = fresh_calendar(vec![], 1);

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert!(merged.next.is_none());
    assert_eq!(merged.sweater, "sage");
}

#[test]
fn a_failed_calendar_account_keeps_the_other_accounts_events_and_is_named_in_the_error() {
    let (p, f) = (personal(), family());
    let pc = fresh_calendar(vec![cal_event("p1", 20, None)], 1);
    let fc = CalendarSnapshot::failed(None, "Calendar fetch failed".to_owned());

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert_eq!(merged.state, SourceState::Stale);
    assert!(merged.stale);
    assert_eq!(cal_ids(&merged), vec!["personal:p1"]);
    assert!(merged
        .error
        .as_deref()
        .is_some_and(|e| e.starts_with("family: ")));
    assert!(
        merged.next.is_some(),
        "the healthy account's next meeting still shows"
    );
}

#[test]
fn a_signed_out_calendar_account_carries_its_label_in_the_prompt() {
    let (p, f) = (personal(), family());
    let pc = fresh_calendar(vec![cal_event("p1", 20, None)], 1);
    let fc = CalendarSnapshot::unauthenticated_with(prompt("browser"), "Sign in".to_owned());

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert_eq!(merged.state, SourceState::Unauthenticated);
    assert_eq!(
        merged
            .auth_prompt
            .as_ref()
            .and_then(|p| p.account.as_deref()),
        Some("family")
    );
    assert_eq!(cal_ids(&merged), vec!["personal:p1"]);
}

#[test]
fn two_rate_limited_calendars_wait_for_the_earlier_retry() {
    let (p, f) = (personal(), family());
    let pc = CalendarSnapshot::rate_limited(None, "slow down".to_owned(), at(8));
    let fc = CalendarSnapshot::rate_limited(None, "slow down".to_owned(), at(3));

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]);

    assert_eq!(merged.state, SourceState::RateLimited);
    assert_eq!(merged.retry_at, Some(at(3)));
}

#[test]
fn calendar_updated_at_is_the_oldest_among_accounts_with_data() {
    let (p, f, w) = (personal(), family(), work());
    let pc = fresh_calendar(vec![cal_event("p1", 20, None)], 2);
    let fc = fresh_calendar(vec![cal_event("f1", 25, None)], 15);
    let wc = CalendarSnapshot::failed(None, "down".to_owned());

    let merged = merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc)), (&w, Some(&wc))]);

    assert_eq!(merged.updated_at, Some(at(-15)));
}

#[test]
fn a_loading_account_keeps_the_merge_loading_never_fresh_or_empty() {
    let (p, f) = (personal(), family());
    let fresh = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 30);
    let empty = fresh_mailbox(vec![], 0, 30);

    for healthy in [&fresh, &empty] {
        assert_eq!(
            merge_mail(&[(&p, Some(healthy)), (&f, None)]).state,
            SourceState::Loading
        );
        assert_eq!(
            merge_mail(&[(&p, None), (&f, Some(healthy))]).state,
            SourceState::Loading
        );
    }
    let cal = fresh_calendar(vec![cal_event("p1", 20, None)], 2);
    assert_eq!(
        merge_cal(&[(&p, Some(&cal)), (&f, None)]).state,
        SourceState::Loading
    );
    assert_eq!(
        merge_cal(&[(&p, Some(&fresh_calendar(vec![], 2))), (&f, None)]).state,
        SourceState::Loading
    );
}

#[test]
fn all_loading_calendars_are_loading() {
    let (p, f) = (personal(), family());
    assert_eq!(
        merge_cal(&[(&p, None), (&f, None)]).state,
        SourceState::Loading
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// Wire shape: single-account output is untouched
// ═════════════════════════════════════════════════════════════════════════════

fn json_of<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v).unwrap()
}

#[test]
fn a_legacy_mailbox_snapshot_has_no_account_or_accounts_keys() {
    let snap = MailboxSnapshot {
        state: SourceState::Fresh,
        unread_count: 1,
        items: vec![mail_item("m1", 1, false)],
        updated_at: Some(at(0)),
        ..Default::default()
    };

    let v = json_of(&snap);

    assert!(v.get("accounts").is_none(), "{v}");
    assert!(v["items"][0].get("account").is_none(), "{v}");
}

#[test]
fn a_legacy_calendar_snapshot_has_no_account_or_accounts_keys_and_never_a_dedupe_key() {
    let snap = fresh_calendar(
        vec![cal_event("e1", 10, Some("secret-ical-uid@example.com"))],
        1,
    );

    let v = json_of(&snap);

    assert!(v.get("accounts").is_none(), "{v}");
    assert!(v["events"][0].get("account").is_none(), "{v}");
    let text = v.to_string();
    assert!(!text.contains("dedupe"), "{text}");
    assert!(
        !text.contains("secret-ical-uid"),
        "the cross-account key never leaves the daemon: {text}"
    );
}

#[test]
fn a_merged_snapshot_serialises_its_accounts_and_row_owners_but_not_the_dedupe_key() {
    let (p, f) = (personal(), family());
    let pm = fresh_mailbox(vec![mail_item("p1", 5, false)], 1, 1);
    let fm = fresh_mailbox(vec![mail_item("f1", 6, false)], 1, 1);
    let pc = fresh_calendar(vec![cal_event("p1", 20, Some("uid-1"))], 1);
    let fc = fresh_calendar(vec![cal_event("f1", 25, Some("uid-2"))], 1);

    let mail = json_of(&merge_mail(&[(&p, Some(&pm)), (&f, Some(&fm))]));
    let cal = json_of(&merge_cal(&[(&p, Some(&pc)), (&f, Some(&fc))]));

    assert_eq!(mail["accounts"].as_array().map(Vec::len), Some(2), "{mail}");
    assert_eq!(mail["items"][0]["account"], "personal");
    assert_eq!(cal["accounts"].as_array().map(Vec::len), Some(2), "{cal}");
    assert_eq!(cal["events"][0]["account"], "personal");
    assert!(!cal.to_string().contains("uid-1"), "{cal}");
}

#[test]
fn snapshots_from_before_multi_account_still_parse() {
    let mailbox: MailboxSnapshot = serde_json::from_str(
        r#"{"generated_at":null,"unread_count":1,"items":[{"from":"a","subject":"b","received_at":null,"vip":false,"is_invite":false,"is_read":false}],"stale":false,"error":null}"#,
    )
    .unwrap();
    assert!(mailbox.accounts.is_empty());
    assert_eq!(mailbox.items[0].account, None);

    let calendar: CalendarSnapshot = serde_json::from_str(
        r#"{"events":[],"next":null,"sweater":"sage","stale":false,"error":null}"#,
    )
    .unwrap();
    assert!(calendar.accounts.is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// Detail router
// ═════════════════════════════════════════════════════════════════════════════

/// A per-account detail service that records what it was asked for.
struct Recorder {
    calls: Mutex<Vec<String>>,
    fail_with: Option<WorkError>,
}

impl Recorder {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            fail_with: None,
        })
    }

    fn failing(code: &str) -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            fail_with: Some(WorkError::new(code, "boom")),
        })
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl FredDetailService for Recorder {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        self.calls.lock().unwrap().push(item_id.to_owned());
        if let Some(e) = &self.fail_with {
            return Err(e.clone());
        }
        Ok(WorkDetail {
            item_id: item_id.to_owned(),
            title: format!("detail of {item_id}"),
            fields: vec![("From".to_owned(), "someone".to_owned())],
            markdown: "body".to_owned(),
            files: vec![],
            links: vec![],
        })
    }
}

fn router(services: &[(&str, &Arc<Recorder>)]) -> FredDetailRouter {
    let map: HashMap<String, Arc<dyn FredDetailService>> = services
        .iter()
        .map(|(label, s)| {
            (
                (*label).to_owned(),
                Arc::clone(*s) as Arc<dyn FredDetailService>,
            )
        })
        .collect();
    FredDetailRouter::new(map)
}

#[tokio::test]
async fn a_mail_id_reaches_its_accounts_service_without_the_label_and_comes_back_with_it() {
    let (personal_svc, family_svc) = (Recorder::new(), Recorder::new());
    let r = router(&[("personal", &personal_svc), ("family", &family_svc)]);

    let d = r.detail("mail:personal:abc").await.expect("detail");

    assert_eq!(
        personal_svc.calls(),
        vec!["mail:abc"],
        "the service sees its own native id"
    );
    assert!(
        family_svc.calls().is_empty(),
        "other accounts are not asked"
    );
    assert_eq!(
        d.item_id, "mail:personal:abc",
        "the Mac matches the response by the id it asked for"
    );
    assert_eq!(d.title, "detail of mail:abc");
    assert_eq!(d.fields, vec![("From".to_owned(), "someone".to_owned())]);
    assert_eq!(d.markdown, "body");
}

#[tokio::test]
async fn an_event_id_reaches_the_service_of_the_account_it_names() {
    let (personal_svc, work_svc) = (Recorder::new(), Recorder::new());
    let r = router(&[("personal", &personal_svc), ("work", &work_svc)]);

    let d = r.detail("event:work:xyz").await.expect("detail");

    assert_eq!(work_svc.calls(), vec!["event:xyz"]);
    assert!(personal_svc.calls().is_empty());
    assert_eq!(d.item_id, "event:work:xyz");
}

#[tokio::test]
async fn a_native_id_that_itself_contains_colons_is_passed_through_whole() {
    let svc = Recorder::new();
    let r = router(&[("personal", &svc)]);

    let d = r.detail("mail:personal:a:b:c").await.expect("detail");

    assert_eq!(
        svc.calls(),
        vec!["mail:a:b:c"],
        "the label ends at the first colon"
    );
    assert_eq!(d.item_id, "mail:personal:a:b:c");
}

#[tokio::test]
async fn an_unknown_account_label_is_not_found_and_asks_nobody() {
    let svc = Recorder::new();
    let r = router(&[("personal", &svc)]);

    for id in ["mail:nobody:abc", "event:nobody:abc", "mail:Personal:abc"] {
        let e = r.detail(id).await.expect_err(id);
        assert_eq!(e.code, "not_found", "{id}");
    }
    assert!(svc.calls().is_empty());
}

#[tokio::test]
async fn ids_without_a_label_or_a_known_kind_are_not_found() {
    let svc = Recorder::new();
    let r = router(&[("personal", &svc)]);

    for id in [
        "mail:abc", // legacy single-account shape: no label
        "event:abc",
        "mail:",
        "event:",
        "",
        "pr:personal:abc", // not a Fred kind
        "personal:abc",
        "abc",
    ] {
        let e = r.detail(id).await.expect_err(id);
        assert_eq!(e.code, "not_found", "{id:?}");
    }
    assert!(svc.calls().is_empty(), "{:?}", svc.calls());
}

#[tokio::test]
async fn an_error_from_the_accounts_service_reaches_the_caller_unchanged() {
    let broken = Recorder::failing("unauthenticated");
    let fine = Recorder::new();
    let r = router(&[("family", &broken), ("personal", &fine)]);

    let e = r.detail("mail:family:abc").await.expect_err("error");

    assert_eq!(e.code, "unauthenticated");
    assert_eq!(e.message, "boom");
    assert!(
        r.detail("mail:personal:abc").await.is_ok(),
        "one account failing does not affect another"
    );
}

#[tokio::test]
async fn a_router_with_no_services_answers_not_found() {
    let r = FredDetailRouter::new(HashMap::new());

    let e = r.detail("mail:personal:abc").await.expect_err("error");

    assert_eq!(e.code, "not_found");
}
