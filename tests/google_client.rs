//! `GoogleClient`: desktop loopback + PKCE sign-in, token refresh, and how
//! Google's HTTP failures are classified and reported.
//!
//! Every test runs its own wiremock "Google" (auth, token, Gmail and Calendar
//! endpoints all live on one mock server) and its own temp dir for the token
//! file. Nothing here talks to Google or touches the user's real token files.
//!
//! The "browser" is a plain `reqwest` GET against the loopback redirect URI the
//! client handed out in its sign-in prompt, exactly what Google's redirect does.
//!
//! Determinism: no fixed sleeps. Everything waits on a request/response or on
//! `wait_loopback()` with a generous bound.

use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::Arc;
use std::time::Duration;

use chrono::{Duration as ChronoDuration, Utc};
use nostromo::data::google_client::{
    failure_reason, GoogleClient, GoogleHttpError, GoogleOAuthClient, GoogleOptions,
};
use nostromo::data::graph_client::DeviceFlowPrompt;
use serde_json::{json, Value};
use tempfile::TempDir;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

const WAIT: Duration = Duration::from_secs(20);

const CLIENT_ID: &str = "test-client-id.apps.example";
const CLIENT_SECRET: &str = "test-client-secret-s3cr3t";
const EMAIL: &str = "me@example.com";

const TOKEN_PATH: &str = "/token";
const PROFILE_PATH: &str = "/gmail/v1/users/me/profile";
const PING_PATH: &str = "/gmail/v1/ping";

// ═════════════════════════════════════════════════════════════════════════════
// Harness
// ═════════════════════════════════════════════════════════════════════════════

struct Env {
    server: MockServer,
    dir: TempDir,
}

impl Env {
    async fn new() -> Self {
        Self {
            server: MockServer::start().await,
            dir: TempDir::new().unwrap(),
        }
    }

    /// The account's token file, inside a directory that does not exist yet
    /// (the client must create it with mode 0700).
    fn token_path(&self) -> PathBuf {
        self.dir.path().join("google").join("token.json")
    }

    fn opts(&self, ttl: Duration) -> GoogleOptions {
        let base = self.server.uri();
        GoogleOptions {
            auth_url: format!("{base}/auth"),
            token_url: format!("{base}{TOKEN_PATH}"),
            gmail_base: format!("{base}/gmail/v1"),
            calendar_base: format!("{base}/calendar/v3"),
            loopback_ttl: ttl,
            ..GoogleOptions::default()
        }
    }

    fn client_with_ttl(&self, expected_email: Option<&str>, ttl: Duration) -> GoogleClient {
        GoogleClient::with_options(
            "work".into(),
            expected_email.map(str::to_owned),
            GoogleOAuthClient::new(CLIENT_ID, CLIENT_SECRET),
            self.token_path(),
            self.opts(ttl),
        )
        .expect("google client builds")
    }

    fn client(&self, expected_email: Option<&str>) -> GoogleClient {
        self.client_with_ttl(expected_email, Duration::from_secs(60))
    }

    fn url(&self, p: &str) -> String {
        format!("{}{p}", self.server.uri())
    }

    async fn requests(&self) -> Vec<Request> {
        self.server
            .received_requests()
            .await
            .expect("request recording is enabled")
    }

    /// Form bodies of every POST to the token endpoint, in order.
    async fn token_posts(&self) -> Vec<HashMap<String, String>> {
        self.requests()
            .await
            .iter()
            .filter(|r| r.method.as_str() == "POST" && r.url.path() == TOKEN_PATH)
            .map(|r| url::form_urlencoded::parse(&r.body).into_owned().collect())
            .collect()
    }

    async fn count(&self, http_method: &str, p: &str) -> usize {
        self.requests()
            .await
            .iter()
            .filter(|r| r.method.as_str() == http_method && r.url.path() == p)
            .count()
    }
}

/// Seed a token file (creating its directory).
fn write_token(
    file: &Path,
    access: &str,
    refresh: Option<&str>,
    expires_in_secs: i64,
    email: Option<&str>,
) {
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(
        file,
        json!({
            "access_token": access,
            "refresh_token": refresh,
            "expires_at": (Utc::now() + ChronoDuration::seconds(expires_in_secs)).timestamp(),
            "email": email,
        })
        .to_string(),
    )
    .unwrap();
}

fn read_token(file: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(file).expect("token file exists"))
        .expect("token file is JSON")
}

async fn mount_token(server: &MockServer, body: Value) {
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(server)
        .await;
}

async fn mount_profile(server: &MockServer, email: &str) {
    Mock::given(method("GET"))
        .and(path(PROFILE_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "emailAddress": email,
            "historyId": "1000",
        })))
        .mount(server)
        .await;
}

/// `/gmail/v1/ping`: 200 only for `good_bearer`, 401 for anything else.
async fn mount_ping_accepting(server: &MockServer, good_bearer: &'static str) {
    Mock::given(method("GET"))
        .and(path(PING_PATH))
        .respond_with(move |req: &Request| {
            if bearer(req) == good_bearer {
                ResponseTemplate::new(200).set_body_json(json!({ "ok": true }))
            } else {
                ResponseTemplate::new(401)
                    .set_body_json(json!({ "error": { "status": "UNAUTHENTICATED" } }))
            }
        })
        .mount(server)
        .await;
}

fn bearer(req: &Request) -> String {
    req.headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
        .to_owned()
}

/// `S256`: base64url (no padding) of the SHA-256 of the verifier.
fn s256(verifier: &str) -> String {
    oauth2::PkceCodeChallenge::from_code_verifier_sha256(&oauth2::PkceCodeVerifier::new(
        verifier.to_owned(),
    ))
    .as_str()
    .to_owned()
}

struct ParsedPrompt {
    query: HashMap<String, String>,
}

impl ParsedPrompt {
    fn new(prompt: &DeviceFlowPrompt) -> Self {
        let url = url::Url::parse(&prompt.verification_uri).expect("verification_uri is a URL");
        let query = url.query_pairs().into_owned().collect();
        Self { query }
    }
    fn redirect_uri(&self) -> String {
        self.query
            .get("redirect_uri")
            .expect("redirect_uri param")
            .clone()
    }
    fn state(&self) -> String {
        self.query.get("state").expect("state param").clone()
    }
}

/// What Google's redirect does: the browser GETs the loopback URI.
async fn browser_get(redirect_uri: &str, query: &[(&str, &str)]) -> reqwest::Response {
    tokio::time::timeout(
        WAIT,
        reqwest::Client::new().get(redirect_uri).query(query).send(),
    )
    .await
    .expect("loopback answered in time")
    .expect("loopback is reachable")
}

/// Deliver the redirect while waiting for the flow's outcome. `wait_loopback`
/// waits for a flow *in flight*, so it must be listening before the browser
/// lands; `join!` polls it first.
async fn finish_in_browser(
    client: &GoogleClient,
    redirect_uri: &str,
    query: &[(&str, &str)],
) -> (anyhow::Result<String>, reqwest::Response) {
    tokio::join!(
        within("wait_loopback", client.wait_loopback()),
        browser_get(redirect_uri, query)
    )
}

async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(WAIT, fut)
        .await
        .unwrap_or_else(|_| panic!("timed out: {what}"))
}

/// After a flow ended, the next `ensure_authed()` must hand out a new prompt.
/// The listener task clears its own entry just after publishing the outcome, so
/// allow a moment for that to land; the prompt must differ from `old_state`'s.
async fn next_prompt_after_flow_ended(client: &GoogleClient, old_state: &str) -> DeviceFlowPrompt {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let prompt = client
            .ensure_authed()
            .await
            .expect("ensure_authed does not fail")
            .expect("signed out: a prompt is offered");
        if ParsedPrompt::new(&prompt).state() != old_state {
            return prompt;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "still handing out the ended flow's prompt"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Run a failing GET against the mock and return the typed error.
async fn http_error(status: u16, body: Value, retry_after: Option<&str>) -> (anyhow::Error, Env) {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-good", Some("rt"), 3600, Some(EMAIL));
    let mut template = ResponseTemplate::new(status).set_body_json(body);
    if let Some(v) = retry_after {
        template = template.insert_header("Retry-After", v);
    }
    Mock::given(method("GET"))
        .and(path(PING_PATH))
        .respond_with(template)
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));
    let err = within(
        "failing get_json",
        client.get_json::<Value>(&client.gmail_url("/ping")),
    )
    .await
    .expect_err("a non-2xx answer is an error");
    (err, env)
}

fn typed(e: &anyhow::Error) -> &GoogleHttpError {
    e.downcast_ref::<GoogleHttpError>()
        .expect("error carries a GoogleHttpError")
}

fn google_error(status: u16, reason: Option<&str>, retry_after: Option<u64>) -> anyhow::Error {
    GoogleHttpError {
        status: reqwest::StatusCode::from_u16(status).unwrap(),
        path: "/gmail/v1/x".into(),
        reason: reason.map(str::to_owned),
        retry_after: retry_after.map(Duration::from_secs),
    }
    .into()
}

fn google_error_body(reason: &str) -> Value {
    json!({ "error": { "code": 403, "message": "m", "errors": [{ "reason": reason, "domain": "usageLimits" }] } })
}

// ═════════════════════════════════════════════════════════════════════════════
// Loopback sign-in
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn loopback_sign_in_stores_the_token_after_the_browser_redirect() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, EMAIL).await;
    let client = env.client(Some(EMAIL));

    let prompt = within("ensure_authed", client.ensure_authed())
        .await
        .unwrap()
        .expect("no token yet: a sign-in prompt is offered");

    // The prompt: a browser link for this account, with PKCE and offline access.
    assert_eq!(prompt.kind, "browser");
    assert_eq!(prompt.account.as_deref(), Some("work"));
    assert_eq!(prompt.provider.as_deref(), Some("google"));
    assert!(prompt.expires_at > Utc::now());
    let parsed = ParsedPrompt::new(&prompt);
    assert!(
        prompt.verification_uri.starts_with(&env.url("/auth")),
        "the link goes to the configured auth endpoint: {}",
        prompt.verification_uri
    );
    assert_eq!(parsed.query["client_id"], CLIENT_ID);
    assert_eq!(parsed.query["response_type"], "code");
    assert_eq!(parsed.query["access_type"], "offline");
    assert_eq!(parsed.query["prompt"], "consent");
    assert_eq!(parsed.query["login_hint"], EMAIL);
    assert_eq!(parsed.query["code_challenge_method"], "S256");
    assert!(!parsed.query["code_challenge"].is_empty());
    assert!(!parsed.query["state"].is_empty());
    let scopes: std::collections::BTreeSet<&str> = parsed.query["scope"].split(' ').collect();
    assert_eq!(
        scopes,
        [
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/gmail.readonly"
        ]
        .into_iter()
        .collect(),
        "read-only scopes, nothing else"
    );
    assert!(
        !prompt.verification_uri.contains(CLIENT_SECRET),
        "the client secret never goes into the browser URL"
    );

    // The redirect target is a loopback address on this machine.
    let redirect = url::Url::parse(&parsed.redirect_uri()).unwrap();
    assert_eq!(redirect.host_str(), Some("127.0.0.1"));
    assert!(redirect.port().is_some());

    // The browser comes back with a code.
    let (outcome, resp) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "abc"), ("state", &parsed.state())],
    )
    .await;
    assert!(
        resp.status().is_success(),
        "the user sees a success page, got {}",
        resp.status()
    );
    assert_eq!(outcome.expect("sign-in succeeds"), EMAIL);

    // Code exchange: authorization_code + PKCE verifier + client secret.
    let posts = env.token_posts().await;
    assert_eq!(posts.len(), 1, "exactly one code exchange");
    let form = &posts[0];
    assert_eq!(form["grant_type"], "authorization_code");
    assert_eq!(form["code"], "abc");
    assert_eq!(form["client_id"], CLIENT_ID);
    assert_eq!(form["client_secret"], CLIENT_SECRET);
    assert_eq!(form["redirect_uri"], parsed.redirect_uri());
    assert_eq!(
        s256(&form["code_verifier"]),
        parsed.query["code_challenge"],
        "the verifier sent to the token endpoint matches the challenge sent to the browser"
    );

    // The profile was read with the new access token to learn who signed in.
    let profile_req = env
        .requests()
        .await
        .into_iter()
        .find(|r| r.url.path() == PROFILE_PATH)
        .expect("profile was fetched");
    assert_eq!(bearer(&profile_req), "at-1");

    // Persisted: private file in a private directory, with the email.
    let file = env.token_path();
    let file_mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
    let dir_mode = std::fs::metadata(file.parent().unwrap())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(file_mode, 0o600, "token file mode");
    assert_eq!(dir_mode, 0o700, "token directory mode");
    let stored = read_token(&file);
    assert_eq!(stored["email"], EMAIL);
    assert_eq!(stored["access_token"], "at-1");
    assert_eq!(stored["refresh_token"], "rt-1");

    // Signed in now: no more prompts, and nothing but GETs (plus the token POST).
    assert!(client.ensure_authed().await.unwrap().is_none());
    assert_eq!(client.stored_email().await.as_deref(), Some(EMAIL));
    for r in env.requests().await {
        let ok = r.method.as_str() == "GET"
            || (r.method.as_str() == "POST" && r.url.path() == TOKEN_PATH);
        assert!(
            ok,
            "Google is only ever read: {} {}",
            r.method,
            r.url.path()
        );
    }
}

#[tokio::test]
async fn the_sign_in_link_has_no_login_hint_when_no_email_is_configured() {
    let env = Env::new().await;
    let client = env.client(None);

    let prompt = client.ensure_authed().await.unwrap().expect("prompt");

    assert!(!ParsedPrompt::new(&prompt).query.contains_key("login_hint"));
}

#[tokio::test]
async fn run_loopback_until_done_hands_over_the_prompt_and_returns_the_email() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, EMAIL).await;
    let client = env.client(None);
    let seen: Arc<std::sync::Mutex<Option<DeviceFlowPrompt>>> = Arc::default();

    let seen_in_cb = seen.clone();
    let result = within(
        "run_loopback_until_done",
        client.run_loopback_until_done(move |prompt| {
            *seen_in_cb.lock().unwrap() = Some(prompt.clone());
            // The "browser" completes the sign-in once it has the link.
            let parsed = ParsedPrompt::new(prompt);
            tokio::spawn(async move {
                browser_get(
                    &parsed.redirect_uri(),
                    &[("code", "abc"), ("state", &parsed.state())],
                )
                .await;
            });
        }),
    )
    .await;

    assert_eq!(result.expect("sign-in completes"), EMAIL);
    let prompt = seen
        .lock()
        .unwrap()
        .clone()
        .expect("callback received the prompt");
    assert_eq!(prompt.kind, "browser");
    assert_eq!(prompt.account.as_deref(), Some("work"));
    assert!(env.token_path().exists());
}

#[tokio::test]
async fn a_callback_with_the_wrong_state_is_refused_and_the_real_one_still_works() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, EMAIL).await;
    let client = env.client(None);
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    // A forged / stray hit: wrong state, and no state at all.
    let wrong = browser_get(
        &parsed.redirect_uri(),
        &[("code", "evil"), ("state", "not-the-state")],
    )
    .await;
    assert_eq!(wrong.status().as_u16(), 400);
    let missing = browser_get(&parsed.redirect_uri(), &[("code", "evil")]).await;
    assert_eq!(missing.status().as_u16(), 400);
    assert!(
        env.token_posts().await.is_empty(),
        "a refused callback never reaches the token endpoint"
    );
    assert!(!env.token_path().exists());

    // The flow is still alive for the genuine redirect.
    let (outcome, ok) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "abc"), ("state", &parsed.state())],
    )
    .await;
    assert!(ok.status().is_success());
    assert_eq!(outcome.unwrap(), EMAIL);
    let posts = env.token_posts().await;
    assert_eq!(posts.len(), 1);
    assert_eq!(
        posts[0]["code"], "abc",
        "only the genuine code was exchanged"
    );
}

#[tokio::test]
async fn only_get_on_the_callback_path_is_answered_other_requests_get_404() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, EMAIL).await;
    let client = env.client(None);
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);
    let redirect = url::Url::parse(&parsed.redirect_uri()).unwrap();
    let state = parsed.state();
    let query = [("code", "abc"), ("state", state.as_str())];

    // POST to the right path with the right state.
    let post = tokio::time::timeout(
        WAIT,
        reqwest::Client::new()
            .post(redirect.as_str())
            .query(&query)
            .send(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(post.status().as_u16(), 404);

    // GET on a different path with the right state.
    let mut other = redirect.clone();
    other.set_path("/somewhere/else");
    let elsewhere = browser_get(other.as_str(), &query).await;
    assert_eq!(elsewhere.status().as_u16(), 404);

    let root = {
        let mut r = redirect.clone();
        r.set_path("/");
        browser_get(r.as_str(), &query).await
    };
    assert_eq!(root.status().as_u16(), 404);

    assert!(
        env.token_posts().await.is_empty(),
        "none of those started a code exchange"
    );

    // And the real redirect still completes the sign-in.
    let (outcome, _) = finish_in_browser(&client, &parsed.redirect_uri(), &query).await;
    assert_eq!(outcome.unwrap(), EMAIL);
}

#[tokio::test]
async fn cancelling_in_the_browser_ends_the_flow_without_a_token_and_the_next_attempt_gets_a_new_link(
) {
    let env = Env::new().await;
    let client = env.client(None);
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let (outcome, _) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("error", "access_denied"), ("state", &parsed.state())],
    )
    .await;

    assert!(
        outcome.is_err(),
        "a cancelled sign-in is reported as a failure"
    );
    assert!(!env.token_path().exists(), "no token is stored");
    assert!(env.token_posts().await.is_empty(), "no code was exchanged");

    let next = next_prompt_after_flow_ended(&client, &parsed.state()).await;
    let next_parsed = ParsedPrompt::new(&next);
    assert_ne!(
        next_parsed.state(),
        parsed.state(),
        "a fresh flow has a fresh state"
    );
    assert_ne!(next_parsed.redirect_uri(), "", "and its own listener");
}

#[tokio::test]
async fn an_error_callback_with_the_wrong_state_does_not_cancel_the_flow() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, EMAIL).await;
    let client = env.client(None);
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let forged = browser_get(
        &parsed.redirect_uri(),
        &[("error", "access_denied"), ("state", "forged")],
    )
    .await;
    assert_eq!(forged.status().as_u16(), 400);

    let (outcome, _) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "abc"), ("state", &parsed.state())],
    )
    .await;
    assert_eq!(outcome.unwrap(), EMAIL);
}

#[tokio::test]
async fn signing_in_as_a_different_google_account_persists_nothing_and_asks_again() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-other", "refresh_token": "rt-other", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, "someone.else@example.com").await;
    let client = env.client(Some(EMAIL));
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let (outcome, _) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "abc"), ("state", &parsed.state())],
    )
    .await;

    assert!(outcome.is_err(), "the wrong account is a failed sign-in");
    assert!(
        !env.token_path().exists(),
        "the other account's token is never written"
    );
    assert!(client.stored_email().await.is_none());
    let again = next_prompt_after_flow_ended(&client, &parsed.state()).await;
    assert_eq!(again.kind, "browser");
}

#[tokio::test]
async fn an_account_check_ignores_email_case() {
    let env = Env::new().await;
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600 }),
    )
    .await;
    mount_profile(&env.server, "Me@Example.COM").await;
    let client = env.client(Some("ME@example.com"));
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let (outcome, _) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "abc"), ("state", &parsed.state())],
    )
    .await;

    assert!(outcome.is_ok(), "{outcome:?}");
    assert!(env.token_path().exists());
}

#[tokio::test]
async fn a_rejected_code_exchange_fails_the_sign_in_and_stores_nothing() {
    let env = Env::new().await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "error": "invalid_grant" })))
        .mount(&env.server)
        .await;
    let client = env.client(None);
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let (outcome, _) = finish_in_browser(
        &client,
        &parsed.redirect_uri(),
        &[("code", "bad"), ("state", &parsed.state())],
    )
    .await;

    let err = outcome.expect_err("sign-in fails");
    assert!(!format!("{err:#}").contains(CLIENT_SECRET));
    assert!(!env.token_path().exists());
}

#[tokio::test]
async fn an_unanswered_sign_in_link_expires_and_the_next_attempt_gets_a_new_one() {
    let env = Env::new().await;
    let client = env.client_with_ttl(None, Duration::from_millis(250));
    let prompt = client.ensure_authed().await.unwrap().unwrap();
    let parsed = ParsedPrompt::new(&prompt);

    let outcome = within("wait_loopback", client.wait_loopback()).await;

    assert!(outcome.is_err(), "nobody came back in time");
    let next = next_prompt_after_flow_ended(&client, &parsed.state()).await;
    assert_ne!(ParsedPrompt::new(&next).state(), parsed.state());
}

#[tokio::test]
async fn ensure_authed_while_a_sign_in_is_pending_returns_the_same_prompt() {
    let env = Env::new().await;
    let client = env.client(None);

    let first = client.ensure_authed().await.unwrap().unwrap();
    let second = client.ensure_authed().await.unwrap().unwrap();

    assert_eq!(
        first.verification_uri, second.verification_uri,
        "one pending flow, one link"
    );
}

#[tokio::test]
async fn clones_of_one_client_share_the_same_sign_in() {
    let env = Env::new().await;
    let mailbox_side = env.client(None);
    let calendar_side = mailbox_side.clone();

    let a = mailbox_side.ensure_authed().await.unwrap().unwrap();
    let b = calendar_side.ensure_authed().await.unwrap().unwrap();

    assert_eq!(a.verification_uri, b.verification_uri);
}

#[tokio::test]
async fn a_token_written_to_disk_while_signed_out_is_picked_up_without_the_browser() {
    let env = Env::new().await;
    let client = env.client(Some(EMAIL));
    let prompt = client.ensure_authed().await.unwrap().expect("signed out");
    assert_eq!(prompt.kind, "browser");

    // The `nostromo-google-auth` CLI signs in and writes the file.
    write_token(
        &env.token_path(),
        "at-cli",
        Some("rt-cli"),
        3600,
        Some(EMAIL),
    );

    assert!(
        client.ensure_authed().await.unwrap().is_none(),
        "a valid token file ends the pending sign-in"
    );
    // And it is the token used for requests.
    mount_ping_accepting(&env.server, "at-cli").await;
    let ok: Value = client
        .get_json(&client.gmail_url("/ping"))
        .await
        .expect("authorised with the file's token");
    assert_eq!(ok["ok"], true);
}

// ═════════════════════════════════════════════════════════════════════════════
// Cached tokens and account identity
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_valid_cached_token_needs_no_request_and_no_prompt() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-cached",
        Some("rt"),
        3600,
        Some(EMAIL),
    );
    let client = env.client(Some(EMAIL));

    assert!(client.ensure_authed().await.unwrap().is_none());

    assert!(env.requests().await.is_empty(), "nothing is sent to Google");
    assert_eq!(client.stored_email().await.as_deref(), Some(EMAIL));
}

#[tokio::test]
async fn a_token_file_for_a_different_account_is_not_used() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-other",
        Some("rt-other"),
        3600,
        Some("someone.else@example.com"),
    );
    // Built after the file exists: the daemon's normal start-up order.
    let client = env.client(Some(EMAIL));

    let outcome = client.ensure_authed().await.unwrap();

    assert!(
        outcome.is_some(),
        "another account's token must not sign this account in"
    );
    assert!(
        env.requests().await.is_empty(),
        "and it is never sent to Google"
    );
}

#[tokio::test]
async fn a_token_file_for_a_different_account_that_appears_later_is_not_used() {
    let env = Env::new().await;
    let client = env.client(Some(EMAIL));
    assert!(client.ensure_authed().await.unwrap().is_some());

    write_token(
        &env.token_path(),
        "at-other",
        Some("rt-other"),
        3600,
        Some("someone.else@example.com"),
    );

    assert!(client.ensure_authed().await.unwrap().is_some());
}

// ═════════════════════════════════════════════════════════════════════════════
// Refresh
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn an_expired_token_is_refreshed_and_the_refresh_token_survives_a_response_without_one() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-old",
        Some("rt-old"),
        -10,
        Some(EMAIL),
    );
    // Google's refresh answers carry no refresh_token; hand out a distinct
    // access token each time.
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(move |_: &Request| {
            let n = counter.fetch_add(1, SeqCst) + 1;
            ResponseTemplate::new(200)
                .set_body_json(json!({ "access_token": format!("at-{n}"), "expires_in": 3600 }))
        })
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));

    assert!(
        client.ensure_authed().await.unwrap().is_none(),
        "refreshed, no prompt needed"
    );

    let posts = env.token_posts().await;
    assert_eq!(posts.len(), 1);
    assert_eq!(posts[0]["grant_type"], "refresh_token");
    assert_eq!(posts[0]["refresh_token"], "rt-old");
    assert_eq!(posts[0]["client_id"], CLIENT_ID);
    assert_eq!(posts[0]["client_secret"], CLIENT_SECRET);
    let on_disk = read_token(&env.token_path());
    assert_eq!(on_disk["access_token"], "at-1");
    assert_eq!(
        on_disk["refresh_token"], "rt-old",
        "the refresh token is kept on disk"
    );
    assert_eq!(on_disk["email"], EMAIL, "so is the recorded email");

    // The refresh token is still held in memory: a later 401 refreshes with it.
    mount_ping_accepting(&env.server, "at-2").await;
    let ok: Value = client
        .get_json(&client.gmail_url("/ping"))
        .await
        .expect("401 -> refresh -> retry succeeds");
    assert_eq!(ok["ok"], true);
    let posts = env.token_posts().await;
    assert_eq!(posts.len(), 2);
    assert_eq!(
        posts[1]["refresh_token"], "rt-old",
        "the same refresh token is used again"
    );
    assert_eq!(read_token(&env.token_path())["refresh_token"], "rt-old");
}

#[tokio::test]
async fn a_rotated_refresh_token_replaces_the_old_one() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-old",
        Some("rt-old"),
        -10,
        Some(EMAIL),
    );
    mount_token(
        &env.server,
        json!({ "access_token": "at-1", "refresh_token": "rt-new", "expires_in": 3600 }),
    )
    .await;
    let client = env.client(Some(EMAIL));

    assert!(client.ensure_authed().await.unwrap().is_none());

    assert_eq!(read_token(&env.token_path())["refresh_token"], "rt-new");
}

#[tokio::test]
async fn a_revoked_refresh_token_asks_for_sign_in_and_is_not_retried_every_poll() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-old",
        Some("rt-revoked"),
        -10,
        Some(EMAIL),
    );
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({
            "error": "invalid_grant",
            "error_description": "Token has been expired or revoked."
        })))
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));

    let first = client
        .ensure_authed()
        .await
        .expect("invalid_grant is not an error")
        .expect("sign-in is needed");
    assert_eq!(first.kind, "browser");
    let second = client
        .ensure_authed()
        .await
        .unwrap()
        .expect("still signed out");

    assert_eq!(first.verification_uri, second.verification_uri);
    assert_eq!(
        env.token_posts().await.len(),
        1,
        "the rejected refresh token is not sent again"
    );
}

#[tokio::test]
async fn a_transient_refresh_failure_is_an_error_not_a_sign_in_prompt() {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-old", Some("rt"), -10, Some(EMAIL));
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(503).set_body_string("try later"))
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));

    let outcome = client.ensure_authed().await;

    assert!(
        outcome.is_err(),
        "Google being down must not make the user sign in again"
    );
    assert!(env.token_path().exists(), "and the stored token is kept");
    assert_eq!(read_token(&env.token_path())["refresh_token"], "rt");
}

#[tokio::test]
async fn a_401_refreshes_once_and_retries_the_request() {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-stale", Some("rt"), 3600, Some(EMAIL));
    mount_token(
        &env.server,
        json!({ "access_token": "at-fresh", "expires_in": 3600 }),
    )
    .await;
    mount_ping_accepting(&env.server, "at-fresh").await;
    let client = env.client(Some(EMAIL));

    let ok: Value = within("get_json", client.get_json(&client.gmail_url("/ping")))
        .await
        .expect("retry succeeds");

    assert_eq!(ok["ok"], true);
    assert_eq!(env.token_posts().await.len(), 1, "exactly one refresh");
    let pings: Vec<String> = env
        .requests()
        .await
        .iter()
        .filter(|r| r.url.path() == PING_PATH)
        .map(bearer)
        .collect();
    assert_eq!(
        pings,
        vec!["at-stale".to_owned(), "at-fresh".to_owned()],
        "stale token first, then the new one"
    );
    assert_eq!(
        read_token(&env.token_path())["access_token"],
        "at-fresh",
        "the new token is persisted"
    );
}

#[tokio::test]
async fn a_401_that_cannot_be_refreshed_is_a_401_error_and_never_data() {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-stale", Some("rt"), 3600, Some(EMAIL));
    // The refresh fails outright. The data endpoint would happily serve a
    // retry sent with any other token, so a client that "retried anyway" with
    // something else would show up as data.
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(500))
        .mount(&env.server)
        .await;
    mount_ping_accepting(&env.server, "at-stale-but-accepted-only-if-unrejected").await;
    let client = env.client(Some(EMAIL));

    let err = within(
        "get_json",
        client.get_json::<Value>(&client.gmail_url("/ping")),
    )
    .await
    .expect_err("a failed refresh after a 401 is a failure");

    assert_eq!(typed(&err).status.as_u16(), 401);
    assert_eq!(
        env.token_posts().await.len(),
        1,
        "one refresh attempt, no loop"
    );
    assert_eq!(
        env.count("GET", PING_PATH).await,
        1,
        "no retry without a new token"
    );
}

#[tokio::test]
async fn a_401_whose_refresh_token_was_revoked_is_a_401_error() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-stale",
        Some("rt-revoked"),
        3600,
        Some(EMAIL),
    );
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "error": "invalid_grant" })))
        .mount(&env.server)
        .await;
    mount_ping_accepting(&env.server, "something-else").await;
    let client = env.client(Some(EMAIL));

    let err = client
        .get_json::<Value>(&client.gmail_url("/ping"))
        .await
        .expect_err("401");

    assert_eq!(typed(&err).status.as_u16(), 401);
}

// After a failed 401 refresh the dead token must not be re-read from disk and
// treated as signed in.
#[tokio::test]
async fn after_a_401_with_a_revoked_refresh_token_the_next_check_asks_for_sign_in() {
    let env = Env::new().await;
    // The access token still looks valid by its expiry, but Google rejects it
    // and the refresh token was revoked: only a new sign-in can help.
    write_token(
        &env.token_path(),
        "at-stale",
        Some("rt-revoked"),
        3600,
        Some(EMAIL),
    );
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "error": "invalid_grant" })))
        .mount(&env.server)
        .await;
    mount_ping_accepting(&env.server, "nothing-matches").await;
    let client = env.client(Some(EMAIL));
    assert!(client.ensure_authed().await.unwrap().is_none());
    client
        .get_json::<Value>(&client.gmail_url("/ping"))
        .await
        .expect_err("401");

    let outcome = client.ensure_authed().await.unwrap();

    assert!(
        outcome.is_some(),
        "a token Google rejected and cannot refresh must not count as signed in"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// HTTP error classification
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_429_is_a_throttle() {
    let (err, _env) = http_error(
        429,
        json!({ "error": { "status": "RESOURCE_EXHAUSTED" } }),
        None,
    )
    .await;
    let http = typed(&err);
    assert_eq!(http.status.as_u16(), 429);
    assert!(http.is_throttle());
}

#[tokio::test]
async fn a_403_rate_limit_exceeded_is_a_throttle() {
    let (err, _env) = http_error(403, google_error_body("rateLimitExceeded"), None).await;
    assert!(typed(&err).is_throttle());
}

#[tokio::test]
async fn a_403_user_rate_limit_exceeded_is_a_throttle() {
    let (err, _env) = http_error(403, google_error_body("userRateLimitExceeded"), None).await;
    assert!(typed(&err).is_throttle());
}

#[tokio::test]
async fn a_503_with_retry_after_is_a_throttle_and_keeps_the_wait() {
    let (err, _env) = http_error(
        503,
        json!({ "error": { "status": "UNAVAILABLE" } }),
        Some("7"),
    )
    .await;
    let http = typed(&err);
    assert!(http.is_throttle());
    assert_eq!(http.retry_after, Some(Duration::from_secs(7)));
}

#[tokio::test]
async fn a_retry_after_is_capped_at_fifteen_minutes() {
    let (err, _env) = http_error(429, json!({}), Some("86400")).await;
    assert_eq!(typed(&err).retry_after, Some(Duration::from_secs(15 * 60)));
}

#[tokio::test]
async fn a_plain_403_forbidden_is_not_a_throttle() {
    let (err, _env) = http_error(403, google_error_body("forbidden"), None).await;
    let http = typed(&err);
    assert_eq!(http.status.as_u16(), 403);
    assert!(!http.is_throttle());
}

#[tokio::test]
async fn a_503_without_retry_after_and_a_500_are_not_throttles() {
    let (err, _env) = http_error(503, json!({}), None).await;
    assert!(!typed(&err).is_throttle());
    let (err, _env) = http_error(500, json!({}), None).await;
    assert!(!typed(&err).is_throttle());
}

#[tokio::test]
async fn an_error_message_carries_neither_the_response_body_nor_the_query_string() {
    let env = Env::new().await;
    write_token(
        &env.token_path(),
        "at-secret-token-value",
        Some("rt"),
        3600,
        Some(EMAIL),
    );
    Mock::given(method("GET"))
        .and(path(PING_PATH))
        .respond_with(ResponseTemplate::new(500).set_body_json(json!({
            "error": { "code": 500, "message": "BODY-MARKER-9f3a: subject of a private mail" }
        })))
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));
    let url = client.gmail_url("/ping?q=QUERY-MARKER-77c1&pageToken=TOKEN-MARKER-5d");

    let err = client.get_json::<Value>(&url).await.expect_err("500");

    for text in [
        format!("{err}"),
        format!("{err:#}"),
        format!("{err:?}"),
        failure_reason("Mail fetch failed", &err),
    ] {
        assert!(
            !text.contains("BODY-MARKER"),
            "response body leaked: {text}"
        );
        assert!(
            !text.contains("QUERY-MARKER"),
            "query string leaked: {text}"
        );
        assert!(!text.contains("TOKEN-MARKER"), "page token leaked: {text}");
        assert!(
            !text.contains("at-secret-token-value"),
            "access token leaked: {text}"
        );
    }
    assert_eq!(typed(&err).status.as_u16(), 500);
}

// ═════════════════════════════════════════════════════════════════════════════
// Plain-English failure reasons
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn failure_reason_for_401_says_the_sign_in_was_rejected() {
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(401, None, None)),
        "Mail fetch failed: Google rejected the sign-in (401); sign-in will be retried"
    );
}

#[test]
fn failure_reason_for_403_says_access_was_denied() {
    assert_eq!(
        failure_reason(
            "Calendar fetch failed",
            &google_error(403, Some("forbidden"), None)
        ),
        "Calendar fetch failed: Google denied access (403)"
    );
}

#[test]
fn failure_reason_for_throttles_says_google_is_rate_limiting() {
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(429, None, None)),
        "Mail fetch failed: Google is rate limiting requests (429)"
    );
    assert_eq!(
        failure_reason(
            "Mail fetch failed",
            &google_error(403, Some("rateLimitExceeded"), None)
        ),
        "Mail fetch failed: Google is rate limiting requests (403)"
    );
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(503, None, Some(5))),
        "Mail fetch failed: Google is rate limiting requests (503)"
    );
}

#[test]
fn failure_reason_for_5xx_says_google_is_unavailable() {
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(503, None, None)),
        "Mail fetch failed: Google is unavailable (503)"
    );
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(500, None, None)),
        "Mail fetch failed: Google is unavailable (500)"
    );
}

#[test]
fn failure_reason_for_any_other_status_is_unexpected_response() {
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(404, None, None)),
        "Mail fetch failed: unexpected response from Google"
    );
    assert_eq!(
        failure_reason("Mail fetch failed", &google_error(400, None, None)),
        "Mail fetch failed: unexpected response from Google"
    );
}

#[test]
fn failure_reason_for_a_non_http_failure_is_unexpected_response() {
    assert_eq!(
        failure_reason(
            "Mail fetch failed",
            &anyhow::anyhow!("something odd happened")
        ),
        "Mail fetch failed: unexpected response from Google"
    );
}

#[test]
fn failure_reason_survives_anyhow_context_around_the_http_error() {
    let wrapped = google_error(429, None, None).context("while fetching the inbox");
    assert_eq!(
        failure_reason("Mail fetch failed", &wrapped),
        "Mail fetch failed: Google is rate limiting requests (429)"
    );
}

#[tokio::test]
async fn failure_reason_for_an_unreachable_google_says_could_not_reach() {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-good", Some("rt"), 3600, Some(EMAIL));
    let client = env.client(Some(EMAIL));
    // A port nothing listens on: bind, note the port, close.
    let closed = {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        listener.local_addr().unwrap().port()
    };

    let err = within(
        "get_json",
        client.get_json::<Value>(&format!("http://127.0.0.1:{closed}/gmail/v1/ping")),
    )
    .await
    .expect_err("connection refused");

    assert_eq!(
        failure_reason("Mail fetch failed", &err),
        "Mail fetch failed: could not reach Google"
    );
}

#[tokio::test]
async fn failure_reason_for_a_200_that_is_not_json_is_unexpected_response() {
    let env = Env::new().await;
    write_token(&env.token_path(), "at-good", Some("rt"), 3600, Some(EMAIL));
    Mock::given(method("GET"))
        .and(path(PING_PATH))
        .respond_with(
            ResponseTemplate::new(200).set_body_string("<html>captive portal BODY-MARKER</html>"),
        )
        .mount(&env.server)
        .await;
    let client = env.client(Some(EMAIL));

    let err = client
        .get_json::<Value>(&client.gmail_url("/ping"))
        .await
        .expect_err("not JSON");

    assert_eq!(
        failure_reason("Mail fetch failed", &err),
        "Mail fetch failed: unexpected response from Google"
    );
    assert!(!format!("{err:#}").contains("BODY-MARKER"));
}

// ═════════════════════════════════════════════════════════════════════════════
// Secrets in Debug output
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn debug_output_of_the_oauth_client_does_not_contain_the_secret() {
    let text = format!("{:?}", GoogleOAuthClient::new(CLIENT_ID, CLIENT_SECRET));
    assert!(!text.contains(CLIENT_SECRET), "{text}");
}

#[test]
fn the_oauth_client_file_loader_never_echoes_the_file_contents_in_errors() {
    let web = GoogleOAuthClient::from_json(
        &json!({ "web": { "client_id": "i", "client_secret": CLIENT_SECRET } }).to_string(),
    )
    .unwrap_err();
    assert!(!format!("{web:#}").contains(CLIENT_SECRET));
    let broken = GoogleOAuthClient::from_json(&format!(
        "{{\"installed\": {{\"client_secret\": \"{CLIENT_SECRET}\""
    ))
    .unwrap_err();
    assert!(!format!("{broken:#}").contains(CLIENT_SECRET));
}
