//! What the MCP `fred.*` tools tell an agent about signing in and about
//! multiple accounts.
//!
//! A Google sign-in prompt is a browser URL carrying `state`, `login_hint` (the
//! account's email), `client_id` and the PKCE challenge. None of that belongs
//! in an agent's context, so a browser prompt is reported as its `kind` and the
//! `account` to sign in to, and never as a URL. A Microsoft device-code prompt
//! is public by design (URL + short code) and is reported as before.

use chrono::{DateTime, Duration, TimeZone, Utc};
use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::{AccountStatus, MailboxSnapshot};
use nostromo::data::graph_client::DeviceFlowPrompt;
use nostromo::data::work::model::SourceState;
use nostromo::mcp::state::McpSharedState;
use nostromo::mcp::tools::fred as fred_tools;
use serde_json::Value;
use tokio::sync::watch;

const BROWSER_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth?client_id=1234-secretclient.apps.googleusercontent.com&state=STATE-SECRET-777&login_hint=me%40example.com&code_challenge=CHALLENGE-SECRET-42&redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2F";

/// Everything in `BROWSER_URL` an agent must never see.
const URL_SECRETS: &[&str] = &[
    "accounts.google.com",
    "client_id",
    "secretclient",
    "STATE-SECRET-777",
    "CHALLENGE-SECRET-42",
    "login_hint",
    "me%40example.com",
    "me@example.com",
    "127.0.0.1",
    "oauth2",
];

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 10, 12, 0, 0).unwrap()
}

fn browser_prompt(account: Option<&str>) -> DeviceFlowPrompt {
    DeviceFlowPrompt {
        verification_uri: BROWSER_URL.to_owned(),
        user_code: String::new(),
        expires_at: now() + Duration::minutes(10),
        kind: "browser".to_owned(),
        account: account.map(str::to_owned),
        provider: account.map(|_| "google".to_owned()),
    }
}

fn device_prompt(account: Option<&str>) -> DeviceFlowPrompt {
    DeviceFlowPrompt {
        verification_uri: "https://microsoft.com/devicelogin".to_owned(),
        user_code: "ABCD-1234".to_owned(),
        expires_at: now() + Duration::minutes(15),
        kind: "device_code".to_owned(),
        account: account.map(str::to_owned),
        provider: account.map(|_| "microsoft".to_owned()),
    }
}

fn signed_out(prompt: DeviceFlowPrompt) -> (MailboxSnapshot, CalendarSnapshot) {
    (
        MailboxSnapshot::unauthenticated_with(prompt.clone(), "Sign in to see your mail".into()),
        CalendarSnapshot::unauthenticated_with(prompt, "Sign in to see your calendar".into()),
    )
}

fn state_with(mailbox: MailboxSnapshot, calendar: CalendarSnapshot) -> McpSharedState {
    let mut state = McpSharedState::for_test();
    state.fred_mailbox_rx = watch::channel(Some(mailbox)).1;
    state.fred_calendar_rx = watch::channel(Some(calendar)).1;
    state
}

/// Every tool that can carry the prompt: `(tool name, its output)`.
fn all_tool_outputs(state: &McpSharedState) -> Vec<(&'static str, Value)> {
    vec![
        ("get_state", fred_tools::get_state(state)),
        ("list_unread_emails", fred_tools::list_unread_emails(state)),
        (
            "list_calendar_events",
            fred_tools::list_calendar_events(state, &fred_tools::CalendarEventsInput::default()),
        ),
    ]
}

// ═════════════════════════════════════════════════════════════════════════════
// Browser (Google) prompts
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_browser_sign_in_is_reported_as_kind_and_account_with_no_url() {
    let (mailbox, calendar) = signed_out(browser_prompt(Some("family")));
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        assert_eq!(out["state"], "unauthenticated", "{tool}: {out}");
        let auth = out.get("auth").unwrap_or_else(|| {
            panic!("{tool}: the agent must still learn a sign-in is needed: {out}")
        });
        assert_eq!(auth["kind"], "browser", "{tool}: {auth}");
        assert_eq!(
            auth["account"], "family",
            "{tool}: says which account to sign in to"
        );
        assert!(
            auth.get("verification_uri").is_none(),
            "{tool}: no URL key: {auth}"
        );
        assert!(
            auth.get("user_code").is_none(),
            "{tool}: a browser prompt has no code: {auth}"
        );
    }
}

#[test]
fn a_browser_sign_in_url_and_its_parts_appear_nowhere_in_any_tool_output() {
    let (mailbox, calendar) = signed_out(browser_prompt(Some("family")));
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        let text = out.to_string();
        for secret in URL_SECRETS {
            assert!(!text.contains(secret), "{tool} leaks {secret:?}: {text}");
        }
        let auth = out["auth"].to_string();
        assert!(
            !auth.contains("http"),
            "{tool}: no URL string at all in the prompt: {auth}"
        );
        assert!(!auth.contains("://"), "{tool}: {auth}");
    }
}

#[test]
fn a_browser_prompt_without_an_account_label_still_hides_the_url() {
    // A single Google account configured the old way carries no label.
    let (mailbox, calendar) = signed_out(browser_prompt(None));
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        let auth = &out["auth"];
        assert_eq!(auth["kind"], "browser", "{tool}: {out}");
        assert!(auth.get("verification_uri").is_none(), "{tool}: {auth}");
        assert!(
            auth.get("account").is_none(),
            "{tool}: no account to name: {auth}"
        );
        for secret in URL_SECRETS {
            assert!(!out.to_string().contains(secret), "{tool} leaks {secret:?}");
        }
    }
}

#[test]
fn a_merged_snapshot_with_a_signed_out_google_account_names_it_without_the_url() {
    // What the merge produces: the prompt carries the account to sign in to.
    let prompt = browser_prompt(Some("family"));
    let mailbox = MailboxSnapshot {
        generated_at: Some(now()),
        state: SourceState::Unauthenticated,
        error: Some("family: Sign in to Google (family) to see your mail".into()),
        auth_prompt: Some(prompt.clone()),
        accounts: vec![
            AccountStatus {
                account: "personal".into(),
                provider: "google".into(),
                state: SourceState::Fresh,
                updated_at: Some(now()),
                ..Default::default()
            },
            AccountStatus {
                account: "family".into(),
                provider: "google".into(),
                state: SourceState::Unauthenticated,
                error: Some("Sign in to Google (family) to see your mail".into()),
                ..Default::default()
            },
        ],
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        auth_prompt: Some(prompt),
        state: SourceState::Unauthenticated,
        error: Some("family: Sign in".into()),
        ..Default::default()
    };
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        assert_eq!(out["auth"]["account"], "family", "{tool}: {out}");
        for secret in URL_SECRETS {
            assert!(
                !out.to_string().contains(secret),
                "{tool} leaks {secret:?}: {out}"
            );
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Device-code (Microsoft) prompts keep their URL and code
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_device_code_sign_in_still_reports_its_url_and_code() {
    let (mailbox, calendar) = signed_out(device_prompt(None));
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        let auth = &out["auth"];
        assert_eq!(
            auth["verification_uri"], "https://microsoft.com/devicelogin",
            "{tool}: {auth}"
        );
        assert_eq!(auth["user_code"], "ABCD-1234", "{tool}: {auth}");
        assert!(auth.get("expires_at").is_some(), "{tool}: {auth}");
        assert!(
            auth.get("kind").is_none() && auth.get("account").is_none(),
            "{tool}: a device-code prompt keeps its original three keys: {auth}"
        );
    }
}

#[test]
fn a_device_code_sign_in_for_a_named_account_keeps_the_original_three_keys() {
    let (mailbox, calendar) = signed_out(device_prompt(Some("work")));
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        let auth = &out["auth"];
        let mut keys: Vec<&String> = auth.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            ["expires_at", "user_code", "verification_uri"],
            "{tool}: {auth}"
        );
        assert_eq!(
            auth["verification_uri"], "https://microsoft.com/devicelogin",
            "{tool}"
        );
        assert_eq!(auth["user_code"], "ABCD-1234", "{tool}");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Per-account status
// ═════════════════════════════════════════════════════════════════════════════

fn status(account: &str, provider: &str, state: SourceState, error: Option<&str>) -> AccountStatus {
    AccountStatus {
        account: account.into(),
        provider: provider.into(),
        state,
        error: error.map(str::to_owned),
        retry_at: None,
        updated_at: matches!(state, SourceState::Fresh | SourceState::Stale).then(now),
    }
}

#[test]
fn per_account_status_is_listed_by_label_when_there_are_several_accounts() {
    let mailbox = MailboxSnapshot {
        generated_at: Some(now()),
        state: SourceState::Stale,
        stale: true,
        updated_at: Some(now()),
        error: Some("family: Mail fetch failed".into()),
        accounts: vec![
            status("personal", "google", SourceState::Fresh, None),
            status(
                "family",
                "google",
                SourceState::Error,
                Some("Mail fetch failed"),
            ),
        ],
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        generated_at: Some(now()),
        state: SourceState::Fresh,
        sweater: "sage".into(),
        updated_at: Some(now()),
        accounts: vec![
            status("personal", "google", SourceState::Fresh, None),
            status("family", "google", SourceState::Fresh, None),
        ],
        ..Default::default()
    };
    let state = state_with(mailbox, calendar);

    let unread = fred_tools::list_unread_emails(&state);
    let accounts = unread["accounts"].as_array().expect("an accounts array");
    assert_eq!(accounts.len(), 2, "{unread}");
    assert_eq!(accounts[0]["label"], "personal");
    assert_eq!(accounts[0]["provider"], "google");
    assert_eq!(accounts[0]["state"], "fresh");
    assert_eq!(accounts[1]["label"], "family");
    assert_eq!(accounts[1]["state"], "error");
    assert_eq!(accounts[1]["error"], "Mail fetch failed");

    let overview = fred_tools::get_state(&state);
    assert_eq!(
        overview["accounts"].as_array().map(Vec::len),
        Some(2),
        "the mailbox's accounts: {overview}"
    );
    assert_eq!(
        overview["calendar_accounts"].as_array().map(Vec::len),
        Some(2),
        "the calendar's accounts, even though the mailbox is the worse source: {overview}"
    );

    let events =
        fred_tools::list_calendar_events(&state, &fred_tools::CalendarEventsInput::default());
    assert_eq!(
        events["accounts"].as_array().map(Vec::len),
        Some(2),
        "{events}"
    );
}

#[test]
fn a_single_account_setup_has_no_accounts_key_in_any_tool_output() {
    let mailbox = MailboxSnapshot {
        generated_at: Some(now()),
        state: SourceState::Empty,
        updated_at: Some(now()),
        ..Default::default()
    };
    let calendar = CalendarSnapshot {
        generated_at: Some(now()),
        state: SourceState::Empty,
        sweater: "sage".into(),
        updated_at: Some(now()),
        ..Default::default()
    };
    let state = state_with(mailbox, calendar);

    for (tool, out) in all_tool_outputs(&state) {
        assert!(out.get("accounts").is_none(), "{tool}: {out}");
        assert!(out.get("calendar_accounts").is_none(), "{tool}: {out}");
    }
}

#[test]
fn account_status_carries_no_sign_in_url_or_token() {
    let mailbox = MailboxSnapshot {
        generated_at: Some(now()),
        state: SourceState::Unauthenticated,
        error: Some("family: Sign in".into()),
        auth_prompt: Some(browser_prompt(Some("family"))),
        accounts: vec![status(
            "family",
            "google",
            SourceState::Unauthenticated,
            Some("Sign in"),
        )],
        ..Default::default()
    };
    let state = state_with(mailbox, CalendarSnapshot::default());

    let accounts = fred_tools::get_state(&state)["accounts"].to_string();

    for secret in URL_SECRETS {
        assert!(!accounts.contains(secret), "{secret:?} in {accounts}");
    }
    assert!(!accounts.contains("token"), "{accounts}");
}
