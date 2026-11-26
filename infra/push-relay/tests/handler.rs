//! Behavioural tests for the push relay (W13). Hermetic: an in-memory `Store` and
//! `Secrets`, a fabricated `Clock`, an APNs stub on `wiremock`, and a P-256 key
//! generated at test time. No AWS, no Apple, no network, no sleeps.
//!
//! Numbers that are part of the contract (7 days, 600 s window, 60 pushes, 300 s
//! and 50 min caches) are written out literally here, not imported from the
//! crate, so that changing one in the source fails a test.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use p256::ecdsa::SigningKey;
use p256::pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding};
use push_relay::model::Record;
use push_relay::{ApnsCredentials, Clock, Relay, Request, Response, Secrets, Store};
use serde_json::{json, Value};
use wiremock::matchers::any;
use wiremock::{Mock, MockServer, ResponseTemplate};

// ─── fixtures ────────────────────────────────────────────────────────────────

/// A multiple of 600, so it is the start of a rate window.
const T0: i64 = 1_800_000_000;
const SEVEN_DAYS: i64 = 7 * 24 * 3600;
const PUSH_ID: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
const OTHER_PUSH_ID: &str = "ffeeddccbbaa99887766554433221100";
const DAEMON_TOKEN: &str = "daemon-token-v1";
const KEY_ID: &str = "KEYID12345";
const TEAM_ID: &str = "TEAMID6789";
const TOPIC: &str = "com.example.Nostromo";

struct FakeClock(AtomicI64);

impl FakeClock {
    fn set(&self, t: i64) {
        self.0.store(t, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Default)]
struct MemStore {
    records: Mutex<Vec<Record>>,
    /// (push_id, window) -> count.
    rate: Mutex<HashMap<(String, i64), u32>>,
    /// (push_id, window, expires_at) for each bump.
    rate_expiry: Mutex<Vec<(String, i64, i64)>>,
    fail_put: AtomicBool,
    fail_rate: AtomicBool,
    fail_read: AtomicBool,
    /// `records()` returns every device's records (a store that does not filter).
    leaky: AtomicBool,
    put_calls: AtomicUsize,
}

impl MemStore {
    fn insert(&self, r: Record) {
        self.records.lock().unwrap().push(r);
    }
    fn all(&self) -> Vec<Record> {
        self.records.lock().unwrap().clone()
    }
    fn preload_rate(&self, push_id: &str, window: i64, count: u32) {
        self.rate
            .lock()
            .unwrap()
            .insert((push_id.to_string(), window), count);
    }
}

#[async_trait]
impl Store for MemStore {
    async fn put_record(&self, record: &Record) -> Result<(), String> {
        self.put_calls.fetch_add(1, Ordering::SeqCst);
        if self.fail_put.load(Ordering::SeqCst) {
            return Err("dynamo put failed: STOREDETAIL".into());
        }
        self.records.lock().unwrap().push(record.clone());
        Ok(())
    }

    async fn records(&self, push_id: &str) -> Result<Vec<Record>, String> {
        if self.fail_read.load(Ordering::SeqCst) {
            return Err("dynamo query failed: STOREDETAIL".into());
        }
        let leaky = self.leaky.load(Ordering::SeqCst);
        Ok(self
            .records
            .lock()
            .unwrap()
            .iter()
            .filter(|r| leaky || r.push_id == push_id)
            .cloned()
            .collect())
    }

    async fn bump_rate(&self, push_id: &str, window: i64, expires_at: i64) -> Result<u32, String> {
        if self.fail_rate.load(Ordering::SeqCst) {
            return Err("dynamo update failed: STOREDETAIL".into());
        }
        self.rate_expiry
            .lock()
            .unwrap()
            .push((push_id.to_string(), window, expires_at));
        let mut rate = self.rate.lock().unwrap();
        let n = rate.entry((push_id.to_string(), window)).or_insert(0);
        *n += 1;
        Ok(*n)
    }
}

struct MemSecrets {
    token: Mutex<String>,
    creds: Mutex<ApnsCredentials>,
    token_reads: AtomicUsize,
    apns_reads: AtomicUsize,
    fail_token: AtomicBool,
    fail_apns: AtomicBool,
}

impl MemSecrets {
    fn set_token(&self, t: &str) {
        *self.token.lock().unwrap() = t.to_string();
    }
    fn set_topic(&self, t: &str) {
        self.creds.lock().unwrap().topic = t.to_string();
    }
}

#[async_trait]
impl Secrets for MemSecrets {
    async fn daemon_token(&self) -> Result<String, String> {
        self.token_reads.fetch_add(1, Ordering::SeqCst);
        if self.fail_token.load(Ordering::SeqCst) {
            return Err("AccessDenied: arn:aws:secretsmanager:SECRETDETAIL".into());
        }
        Ok(self.token.lock().unwrap().clone())
    }

    async fn apns(&self) -> Result<ApnsCredentials, String> {
        self.apns_reads.fetch_add(1, Ordering::SeqCst);
        if self.fail_apns.load(Ordering::SeqCst) {
            return Err("AccessDenied: arn:aws:secretsmanager:SECRETDETAIL".into());
        }
        Ok(self.creds.lock().unwrap().clone())
    }
}

/// A throwaway P-256 key: the private half as the PKCS#8 PEM the secret holds,
/// the public half to verify the provider token.
struct TestKey {
    private_pem: String,
    public_pem: String,
}

fn test_key() -> TestKey {
    let sk = SigningKey::random(&mut rand_core::OsRng);
    TestKey {
        private_pem: sk.to_pkcs8_pem(LineEnding::LF).unwrap().to_string(),
        public_pem: sk
            .verifying_key()
            .to_public_key_pem(LineEnding::LF)
            .unwrap(),
    }
}

struct Harness {
    relay: Relay,
    store: Arc<MemStore>,
    secrets: Arc<MemSecrets>,
    clock: Arc<FakeClock>,
    apns: MockServer,
    key: TestKey,
}

impl Harness {
    async fn new() -> Self {
        Self::with_response(ResponseTemplate::new(200)).await
    }

    async fn with_response(apns_reply: ResponseTemplate) -> Self {
        let apns = MockServer::start().await;
        Mock::given(any())
            .respond_with(apns_reply)
            .mount(&apns)
            .await;
        let base = apns.uri();
        Self::build(apns, base)
    }

    /// The APNs base points at a port nothing listens on.
    async fn unreachable() -> Self {
        let apns = MockServer::start().await;
        Self::build(apns, format!("http://127.0.0.1:{}", closed_port()))
    }

    fn build(apns: MockServer, base: String) -> Self {
        let key = test_key();
        let store = Arc::new(MemStore::default());
        let secrets = Arc::new(MemSecrets {
            token: Mutex::new(DAEMON_TOKEN.to_string()),
            creds: Mutex::new(ApnsCredentials {
                key_pem: key.private_pem.clone(),
                key_id: KEY_ID.into(),
                team_id: TEAM_ID.into(),
                topic: TOPIC.into(),
            }),
            token_reads: AtomicUsize::new(0),
            apns_reads: AtomicUsize::new(0),
            fail_token: AtomicBool::new(false),
            fail_apns: AtomicBool::new(false),
        });
        let clock = Arc::new(FakeClock(AtomicI64::new(T0)));
        let relay = Relay::new(store.clone(), secrets.clone(), clock.clone()).with_apns_base(base);
        Self {
            relay,
            store,
            secrets,
            clock,
            apns,
            key,
        }
    }

    async fn send(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        authorization: Option<&str>,
        body: Vec<u8>,
    ) -> Response {
        self.relay
            .handle(Request {
                method: method.into(),
                path: path.into(),
                query: query
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect::<BTreeMap<_, _>>(),
                authorization: authorization.map(str::to_string),
                body,
            })
            .await
    }

    /// `POST /push` with the daemon's bearer.
    async fn post(&self, body: &Value) -> Response {
        self.post_as(DAEMON_TOKEN, body).await
    }

    async fn post_as(&self, token: &str, body: &Value) -> Response {
        self.send(
            "POST",
            "/push",
            &[],
            Some(&format!("Bearer {token}")),
            serde_json::to_vec(body).unwrap(),
        )
        .await
    }

    async fn post_bytes(&self, body: &[u8]) -> Response {
        self.send(
            "POST",
            "/push",
            &[],
            Some(&format!("Bearer {DAEMON_TOKEN}")),
            body.to_vec(),
        )
        .await
    }

    async fn get_records(&self, query: &[(&str, &str)]) -> Response {
        self.send(
            "GET",
            "/records",
            query,
            Some(&format!("Bearer {DAEMON_TOKEN}")),
            vec![],
        )
        .await
    }

    async fn records_for(&self, push_id: &str) -> Vec<Value> {
        let r = self.get_records(&[("push_id", push_id)]).await;
        assert_eq!(r.status, 200, "GET /records: {}", r.body);
        json_of(&r)["records"].as_array().unwrap().clone()
    }

    async fn apns_requests(&self) -> Vec<wiremock::Request> {
        self.apns.received_requests().await.unwrap_or_default()
    }

    async fn only_apns_request(&self) -> wiremock::Request {
        let mut reqs = self.apns_requests().await;
        assert_eq!(reqs.len(), 1, "expected exactly one APNs call");
        reqs.remove(0)
    }
}

fn closed_port() -> u16 {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    l.local_addr().unwrap().port()
}

fn json_of(r: &Response) -> Value {
    serde_json::from_str(&r.body).unwrap_or_else(|e| panic!("not JSON ({e}): {}", r.body))
}

fn keys(v: &Value) -> BTreeSet<String> {
    v.as_object().unwrap().keys().cloned().collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn header(r: &wiremock::Request, name: &str) -> String {
    r.headers
        .get(name)
        .unwrap_or_else(|| panic!("APNs request has no {name} header"))
        .to_str()
        .unwrap()
        .to_string()
}

fn apns_body(r: &wiremock::Request) -> Value {
    serde_json::from_slice(&r.body).unwrap()
}

fn jwt_of(r: &wiremock::Request) -> String {
    header(r, "authorization")
        .strip_prefix("bearer ")
        .expect("authorization is `bearer <jwt>`")
        .to_string()
}

/// A valid request: an alert for a Mother job.
fn valid() -> Value {
    json!({
        "push_id": PUSH_ID,
        "apns_token": "0f".repeat(32),
        "environment": "sandbox",
        "push_type": "alert",
        "priority": 10,
        "expiration_unix": T0 + 3600,
        "collapse_id": "collapse-1",
        "thread_id": "thread-1",
        "interruption_level": "active",
        "title": "Job finished",
        "body": "Mother finished the job",
        "badge": 2,
        "mutable_content": false,
        "data": { "item": "item-1", "kind": "mother", "host": "sendai", "ref": "job-42" }
    })
}

fn with(f: impl FnOnce(&mut Value)) -> Value {
    let mut v = valid();
    f(&mut v);
    v
}

fn badge_only() -> Value {
    with(|v| {
        let o = v.as_object_mut().unwrap();
        o.remove("title");
        o.remove("body");
    })
}

// ─── W13-20: authentication ──────────────────────────────────────────────────

#[tokio::test]
async fn push_and_records_refuse_every_missing_or_wrong_bearer_with_401() {
    let wrong_headers: Vec<Option<&str>> = vec![
        None,
        Some(""),
        Some("Bearer "),
        Some("Bearer wrong-token"),
        Some("Bearer daemon-token-v1-extra"),
        Some("Bearer daemon-token-v"),
        Some("Basic daemon-token-v1"),
        Some("Token daemon-token-v1"),
        Some("daemon-token-v1"),
    ];
    let h = Harness::new().await;
    let body = with(|v| v["title"] = json!("LEAKMARK-title"));
    for auth in wrong_headers {
        let r = h
            .send(
                "POST",
                "/push",
                &[],
                auth,
                serde_json::to_vec(&body).unwrap(),
            )
            .await;
        assert_eq!(r.status, 401, "POST /push with {auth:?}: {}", r.body);
        assert!(!r.body.contains("LEAKMARK"), "401 echoed the request");

        let r = h
            .send("GET", "/records", &[("push_id", PUSH_ID)], auth, vec![])
            .await;
        assert_eq!(r.status, 401, "GET /records with {auth:?}: {}", r.body);
    }
    assert!(h.apns_requests().await.is_empty(), "APNs was called");
    assert!(h.store.all().is_empty(), "a record was written");
}

#[tokio::test]
async fn the_401_body_does_not_echo_the_presented_credential() {
    let h = Harness::new().await;
    let r = h.post_as("PRESENTED-SECRET-MARK", &valid()).await;
    assert_eq!(r.status, 401);
    assert!(!r.body.contains("PRESENTED-SECRET-MARK"));
    assert!(!r.body.contains(DAEMON_TOKEN));
}

#[tokio::test]
async fn an_empty_configured_token_never_authenticates_an_empty_bearer() {
    let h = Harness::new().await;
    h.secrets.set_token("");
    let r = h
        .send(
            "POST",
            "/push",
            &[],
            Some("Bearer "),
            serde_json::to_vec(&valid()).unwrap(),
        )
        .await;
    assert_eq!(r.status, 401);
    let r = h
        .send(
            "GET",
            "/records",
            &[("push_id", PUSH_ID)],
            Some("Bearer "),
            vec![],
        )
        .await;
    assert_eq!(r.status, 401);
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn the_daemon_bearer_is_accepted_on_both_endpoints() {
    let h = Harness::new().await;
    assert_eq!(h.post(&valid()).await.status, 200);
    assert_eq!(
        h.get_records(&[("push_id", PUSH_ID)]).await.status,
        200
    );
}

// ─── W13-20: the closed request schema ───────────────────────────────────────

async fn assert_refused(h: &Harness, label: &str, body: &Value) {
    let r = h.post(body).await;
    assert_eq!(r.status, 400, "{label}: expected 400, got {}: {}", r.status, r.body);
    assert!(
        !r.body.contains("LEAKMARK") && !r.body.contains("leakmark"),
        "{label}: the 400 echoed request content: {}",
        r.body
    );
}

#[tokio::test]
async fn unknown_fields_are_refused_at_the_top_level_and_inside_data() {
    let h = Harness::new().await;
    let cases = vec![
        ("top-level extra", with(|v| v["leakmark_extra"] = json!("LEAKMARK-v"))),
        ("repo smuggled", with(|v| v["repo"] = json!("LEAKMARK/repo"))),
        ("pr_url smuggled", with(|v| v["pr_url"] = json!("LEAKMARK"))),
        ("alert smuggled", with(|v| v["alert"] = json!({"title": "LEAKMARK"}))),
        (
            "data extra",
            with(|v| v["data"]["leakmark_extra"] = json!("LEAKMARK-v")),
        ),
        ("data.title", with(|v| v["data"]["title"] = json!("LEAKMARK"))),
        ("data.repo", with(|v| v["data"]["repo"] = json!("LEAKMARK"))),
    ];
    for (label, body) in &cases {
        assert_refused(&h, label, body).await;
    }
    assert!(h.apns_requests().await.is_empty());
    assert!(h.store.all().is_empty());
}

#[tokio::test]
async fn title_over_64_characters_is_refused_counting_characters_not_bytes() {
    let h = Harness::new().await;
    let ok = |t: String| with(move |v| v["title"] = json!(t));
    // ASCII boundary.
    assert_eq!(h.post(&ok("a".repeat(64))).await.status, 200);
    assert_refused(&h, "65 ascii", &ok(format!("LEAKMARK{}", "a".repeat(57)))).await;
    // Two-byte characters: 64 chars = 128 bytes is allowed, 65 is not.
    assert_eq!(h.post(&ok("é".repeat(64))).await.status, 200);
    assert_refused(&h, "65 two-byte", &ok("é".repeat(65))).await;
    // Four-byte characters.
    assert_eq!(h.post(&ok("🔔".repeat(64))).await.status, 200);
    assert_refused(&h, "65 four-byte", &ok("🔔".repeat(65))).await;
}

#[tokio::test]
async fn body_over_96_characters_is_refused_counting_characters_not_bytes() {
    let h = Harness::new().await;
    let ok = |t: String| with(move |v| v["body"] = json!(t));
    assert_eq!(h.post(&ok("b".repeat(96))).await.status, 200);
    assert_refused(&h, "97 ascii", &ok(format!("LEAKMARK{}", "b".repeat(89)))).await;
    assert_eq!(h.post(&ok("é".repeat(96))).await.status, 200);
    assert_refused(&h, "97 two-byte", &ok("é".repeat(97))).await;
    assert_eq!(h.post(&ok("🔔".repeat(96))).await.status, 200);
    assert_refused(&h, "97 four-byte", &ok("🔔".repeat(97))).await;
}

#[tokio::test]
async fn title_and_body_go_together_or_not_at_all() {
    let h = Harness::new().await;
    let title_only = with(|v| {
        v.as_object_mut().unwrap().remove("body");
    });
    let body_only = with(|v| {
        v.as_object_mut().unwrap().remove("title");
    });
    assert_refused(&h, "title without body", &title_only).await;
    assert_refused(&h, "body without title", &body_only).await;
    assert_refused(
        &h,
        "null body",
        &with(|v| v["body"] = Value::Null),
    )
    .await;
    // Neither is a badge-only push, which is valid.
    assert_eq!(h.post(&badge_only()).await.status, 200);
}

#[tokio::test]
async fn only_the_alert_push_type_exists() {
    let h = Harness::new().await;
    for t in ["background", "voip", "liveactivity", "Alert", ""] {
        assert_refused(&h, t, &with(|v| v["push_type"] = json!(t))).await;
    }
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn priority_must_be_5_or_10() {
    let h = Harness::new().await;
    for p in [json!(0), json!(1), json!(7), json!(9), json!(11), json!(256), json!(-1), json!("10"), json!(10.5)] {
        assert_refused(&h, &format!("priority {p}"), &with(|v| v["priority"] = p.clone())).await;
    }
    assert_eq!(h.post(&with(|v| v["priority"] = json!(5))).await.status, 200);
    assert_eq!(h.post(&with(|v| v["priority"] = json!(10))).await.status, 200);
}

#[tokio::test]
async fn push_id_must_be_32_lowercase_hex() {
    let h = Harness::new().await;
    let bad: Vec<String> = vec![
        String::new(),
        "a1b2c3".into(),
        PUSH_ID[..31].into(),
        format!("{PUSH_ID}0"),
        PUSH_ID.to_uppercase(),
        "g1b2c3d4e5f60718293a4b5c6d7e8f90".into(),
        "a1b2c3d4-e5f6-0718-293a-4b5c6d7e8f9".into(),
        "a1b2c3d4e5f60718293a4b5c6d7e8f9é".into(),
    ];
    for id in &bad {
        assert_refused(&h, &format!("push_id {id:?}"), &with(|v| v["push_id"] = json!(id))).await;
    }
    assert_eq!(h.post(&valid()).await.status, 200);
}

#[tokio::test]
async fn apns_token_must_be_non_empty_hex_of_at_most_200_characters() {
    let h = Harness::new().await;
    assert_eq!(
        h.post(&with(|v| v["apns_token"] = json!("a".repeat(200)))).await.status,
        200
    );
    assert_refused(&h, "201 chars", &with(|v| v["apns_token"] = json!("a".repeat(201)))).await;
    assert_refused(&h, "empty", &with(|v| v["apns_token"] = json!(""))).await;
    assert_refused(&h, "non-hex", &with(|v| v["apns_token"] = json!("zz".repeat(10)))).await;
    assert_refused(&h, "path traversal", &with(|v| v["apns_token"] = json!("../../v1/x"))).await;
    assert_refused(&h, "spaces", &with(|v| v["apns_token"] = json!("ab cd"))).await;
    assert_refused(&h, "slash", &with(|v| v["apns_token"] = json!("ab/cd"))).await;
}

#[tokio::test]
async fn collapse_id_is_bounded_at_64_bytes() {
    let h = Harness::new().await;
    assert_eq!(
        h.post(&with(|v| v["collapse_id"] = json!("c".repeat(64)))).await.status,
        200
    );
    assert_refused(&h, "65 bytes", &with(|v| v["collapse_id"] = json!("c".repeat(65)))).await;
    // 33 two-byte characters = 66 bytes: bytes, not characters, are counted.
    assert_refused(&h, "66 bytes", &with(|v| v["collapse_id"] = json!("é".repeat(33)))).await;
}

#[tokio::test]
async fn thread_id_is_bounded_at_64_bytes() {
    let h = Harness::new().await;
    assert_eq!(
        h.post(&with(|v| v["thread_id"] = json!("t".repeat(64)))).await.status,
        200
    );
    assert_refused(&h, "65 bytes", &with(|v| v["thread_id"] = json!("t".repeat(65)))).await;
}

#[tokio::test]
async fn the_routing_data_is_bounded() {
    let h = Harness::new().await;
    for (field, ok_len) in [("item", 64), ("host", 64), ("ref", 64)] {
        assert_eq!(
            h.post(&with(|v| v["data"][field] = json!("x".repeat(ok_len)))).await.status,
            200,
            "data.{field} at {ok_len}"
        );
        assert_refused(
            &h,
            &format!("data.{field} too long"),
            &with(|v| v["data"][field] = json!("x".repeat(ok_len + 1))),
        )
        .await;
    }
    assert_refused(&h, "empty item", &with(|v| v["data"]["item"] = json!(""))).await;
    assert_refused(&h, "empty host", &with(|v| v["data"]["host"] = json!(""))).await;
}

#[tokio::test]
async fn interruption_level_is_one_of_the_three_known_levels() {
    let h = Harness::new().await;
    for lvl in ["critical", "Active", "timesensitive", "time_sensitive", ""] {
        assert_refused(&h, lvl, &with(|v| v["interruption_level"] = json!(lvl))).await;
    }
    for lvl in ["active", "time-sensitive", "passive"] {
        assert_eq!(
            h.post(&with(|v| v["interruption_level"] = json!(lvl))).await.status,
            200,
            "{lvl}"
        );
    }
}

#[tokio::test]
async fn environment_and_data_kind_are_closed_vocabularies() {
    let h = Harness::new().await;
    assert_refused(&h, "env", &with(|v| v["environment"] = json!("staging"))).await;
    for kind in ["withdraw", "badge", "other", "Mother", ""] {
        assert_refused(&h, kind, &with(|v| v["data"]["kind"] = json!(kind))).await;
    }
}

#[tokio::test]
async fn every_required_field_is_required() {
    let h = Harness::new().await;
    for f in [
        "push_id",
        "apns_token",
        "environment",
        "push_type",
        "priority",
        "expiration_unix",
        "collapse_id",
        "thread_id",
        "interruption_level",
        "badge",
        "mutable_content",
        "data",
    ] {
        assert_refused(
            &h,
            &format!("missing {f}"),
            &with(|v| {
                v.as_object_mut().unwrap().remove(f);
            }),
        )
        .await;
    }
    for f in ["item", "kind", "host"] {
        assert_refused(
            &h,
            &format!("missing data.{f}"),
            &with(|v| {
                v["data"].as_object_mut().unwrap().remove(f);
            }),
        )
        .await;
    }
    // `ref` and `resolved` are optional.
    let r = h
        .post(&with(|v| {
            v["data"].as_object_mut().unwrap().remove("ref");
        }))
        .await;
    assert_eq!(r.status, 200);
    assert!(h.store.all().iter().all(|r| r.outcome == "accepted"));
}

#[tokio::test]
async fn badly_formed_bodies_are_refused_without_echoing_them() {
    let h = Harness::new().await;
    for raw in [
        &b""[..],
        b"not json LEAKMARK",
        b"{\"title\": \"LEAKMARK",
        b"[]",
        b"null",
        b"\"LEAKMARK\"",
        &[0xff, 0xfe, 0x00],
    ] {
        let r = h.post_bytes(raw).await;
        assert_eq!(r.status, 400, "{raw:?}: {}", r.body);
        assert!(!r.body.contains("LEAKMARK"), "400 echoed the body");
    }
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn a_refused_request_never_reaches_apns_or_the_store() {
    let h = Harness::new().await;
    assert_eq!(h.post(&with(|v| v["priority"] = json!(3))).await.status, 400);
    assert!(h.apns_requests().await.is_empty());
    assert!(h.store.all().is_empty());
}

#[tokio::test]
async fn unknown_paths_are_404_and_wrong_methods_are_405() {
    let h = Harness::new().await;
    let auth = Some("Bearer daemon-token-v1");
    for path in ["/", "/nope", "/push/", "/records/x", "/PUSH", "/push/extra", "/healthz"] {
        for method in ["GET", "POST"] {
            let r = h.send(method, path, &[], auth, vec![]).await;
            assert_eq!(r.status, 404, "{method} {path}: {}", r.body);
        }
    }
    for method in ["GET", "PUT", "DELETE", "PATCH", "HEAD"] {
        let r = h.send(method, "/push", &[], auth, vec![]).await;
        assert_eq!(r.status, 405, "{method} /push");
    }
    for method in ["POST", "PUT", "DELETE", "PATCH"] {
        let r = h.send(method, "/records", &[], auth, vec![]).await;
        assert_eq!(r.status, 405, "{method} /records");
    }
    assert!(h.apns_requests().await.is_empty());
}

// ─── W13-21: the delivery record ─────────────────────────────────────────────

#[tokio::test]
async fn a_successful_push_stores_exactly_one_record_with_exactly_five_fields() {
    let h = Harness::new().await;
    h.clock.set(T0 + 123);
    let r = h.post(&valid()).await;
    assert_eq!(r.status, 200);

    let stored = h.store.all();
    assert_eq!(stored.len(), 1);
    let record = serde_json::to_value(&stored[0]).unwrap();
    assert_eq!(
        keys(&record),
        set(&["push_id", "ts", "kind", "outcome", "expires_at"])
    );
    assert_eq!(record["push_id"], PUSH_ID);
    assert_eq!(record["ts"], T0 + 123);
    assert_eq!(record["expires_at"], T0 + 123 + SEVEN_DAYS);
    assert_eq!(record["kind"], "mother");
    assert_eq!(record["outcome"], "accepted");
}

#[tokio::test]
async fn the_records_endpoint_returns_the_same_five_fields_and_nothing_about_content() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    let records = h.records_for(PUSH_ID).await;
    assert_eq!(records.len(), 1);
    assert_eq!(
        keys(&records[0]),
        set(&["push_id", "ts", "kind", "outcome", "expires_at"])
    );
    let wire = serde_json::to_string(&records).unwrap();
    for content in ["Job finished", "Mother finished", "sendai", "job-42", "item-1"] {
        assert!(!wire.contains(content), "record leaks {content}");
    }
}

#[tokio::test]
async fn the_record_kind_follows_the_notification_kind() {
    for kind in ["mother", "decision", "review", "summary"] {
        let h = Harness::new().await;
        h.post(&with(|v| v["data"]["kind"] = json!(kind))).await;
        assert_eq!(h.store.all()[0].kind, kind);
    }
}

#[tokio::test]
async fn a_resolved_item_is_recorded_as_a_withdraw_and_a_missing_text_as_a_badge() {
    // resolved: true wins, with or without text.
    let h = Harness::new().await;
    h.post(&with(|v| v["data"]["resolved"] = json!(true))).await;
    assert_eq!(h.store.all()[0].kind, "withdraw");

    let h = Harness::new().await;
    h.post(&with(|v| {
        v["data"]["kind"] = json!("decision");
        v["data"]["resolved"] = json!(true);
    }))
    .await;
    assert_eq!(h.store.all()[0].kind, "withdraw");

    let h = Harness::new().await;
    h.post(&with(|v| {
        v.as_object_mut().unwrap().remove("title");
        v.as_object_mut().unwrap().remove("body");
        v["data"]["resolved"] = json!(true);
    }))
    .await;
    assert_eq!(h.store.all()[0].kind, "withdraw");

    // resolved: false is not a withdrawal.
    let h = Harness::new().await;
    h.post(&with(|v| v["data"]["resolved"] = json!(false))).await;
    assert_eq!(h.store.all()[0].kind, "mother");

    // No title or body: a badge.
    let h = Harness::new().await;
    h.post(&badge_only()).await;
    assert_eq!(h.store.all()[0].kind, "badge");
    let h = Harness::new().await;
    h.post(&with(|v| {
        let o = v.as_object_mut().unwrap();
        o.remove("title");
        o.remove("body");
        v["data"]["kind"] = json!("review");
        v["data"]["resolved"] = json!(false);
    }))
    .await;
    assert_eq!(h.store.all()[0].kind, "badge");
}

#[tokio::test]
async fn apns_accepting_the_push_is_recorded_accepted_and_returned() {
    let h = Harness::new().await;
    let r = h.post(&valid()).await;
    assert_eq!(r.status, 200);
    assert_eq!(json_of(&r), json!({"apns_status": 200, "apns_reason": null}));
    assert_eq!(h.store.all()[0].outcome, "accepted");
}

#[tokio::test]
async fn apns_refusing_the_push_is_recorded_rejected_and_the_relay_still_answers_200_with_apples_reason() {
    for (status, reason) in [
        (400, "BadDeviceToken"),
        (403, "InvalidProviderToken"),
        (410, "Unregistered"),
        (429, "TooManyRequests"),
    ] {
        let h = Harness::with_response(
            ResponseTemplate::new(status).set_body_json(json!({ "reason": reason })),
        )
        .await;
        let r = h.post(&valid()).await;
        assert_eq!(r.status, 200, "APNs {status}: {}", r.body);
        assert_eq!(
            json_of(&r),
            json!({"apns_status": status, "apns_reason": reason})
        );
        let stored = h.store.all();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].outcome, "rejected", "APNs {status}");
    }
}

#[tokio::test]
async fn only_a_short_camel_case_reason_from_apple_is_passed_on() {
    let cases: Vec<(ResponseTemplate, Option<&str>)> = vec![
        (ResponseTemplate::new(400).set_body_string("<html>LEAKMARK</html>"), None),
        (ResponseTemplate::new(400).set_body_json(json!({"reason": "Bad Device <b>"})), None),
        (ResponseTemplate::new(400).set_body_json(json!({"reason": "a".repeat(65)})), None),
        (ResponseTemplate::new(400).set_body_json(json!({"reason": 7})), None),
        (ResponseTemplate::new(400).set_body_json(json!({})), None),
        (ResponseTemplate::new(400), None),
    ];
    for (i, (tpl, expect)) in cases.into_iter().enumerate() {
        let h = Harness::with_response(tpl).await;
        let r = h.post(&valid()).await;
        assert_eq!(r.status, 200, "case {i}");
        let v = json_of(&r);
        assert_eq!(v["apns_status"], 400, "case {i}");
        assert_eq!(v["apns_reason"], json!(expect), "case {i}");
        assert!(!r.body.contains("LEAKMARK"), "case {i}: relay echoed Apple's body");
    }
    // The boundary: 64 alphanumeric characters is a reason.
    let h = Harness::with_response(
        ResponseTemplate::new(400).set_body_json(json!({"reason": "a".repeat(64)})),
    )
    .await;
    assert_eq!(json_of(&h.post(&valid()).await)["apns_reason"], "a".repeat(64));
}

#[tokio::test]
async fn an_unreachable_apns_is_a_502_with_an_error_record_and_no_retry() {
    let h = Harness::unreachable().await;
    let r = h.post(&valid()).await;
    assert_eq!(r.status, 502, "{}", r.body);
    assert!(!r.body.contains("127.0.0.1"), "502 leaked the upstream address");
    let stored = h.store.all();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].outcome, "error");
    assert_eq!(stored[0].push_id, PUSH_ID);
    assert_eq!(h.store.put_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn records_are_returned_for_the_requested_device_only() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    h.post(&with(|v| v["push_id"] = json!(OTHER_PUSH_ID))).await;

    let mine = h.records_for(PUSH_ID).await;
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["push_id"], PUSH_ID);
    let theirs = h.records_for(OTHER_PUSH_ID).await;
    assert_eq!(theirs.len(), 1);
    assert_eq!(theirs[0]["push_id"], OTHER_PUSH_ID);
    // A device with no pushes has none.
    assert!(h.records_for("00000000000000000000000000000000").await.is_empty());
}

#[tokio::test]
async fn a_store_that_returns_other_devices_records_still_leaks_none() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    h.post(&with(|v| v["push_id"] = json!(OTHER_PUSH_ID))).await;
    h.store.leaky.store(true, Ordering::SeqCst);
    let mine = h.records_for(PUSH_ID).await;
    assert_eq!(mine.len(), 1);
    assert!(mine.iter().all(|r| r["push_id"] == PUSH_ID));
}

#[tokio::test]
async fn records_come_back_sorted_by_time_whatever_order_the_store_holds_them() {
    let h = Harness::new().await;
    for (ts, kind) in [(T0 - 100, "review"), (T0 - 300, "mother"), (T0 - 200, "decision")] {
        h.store.insert(Record {
            push_id: PUSH_ID.into(),
            ts,
            kind: kind.into(),
            outcome: "accepted".into(),
            expires_at: ts + SEVEN_DAYS,
        });
    }
    let got: Vec<i64> = h
        .records_for(PUSH_ID)
        .await
        .iter()
        .map(|r| r["ts"].as_i64().unwrap())
        .collect();
    assert_eq!(got, vec![T0 - 300, T0 - 200, T0 - 100]);
}

#[tokio::test]
async fn a_record_older_than_seven_days_is_never_returned_even_when_the_store_still_holds_it() {
    let h = Harness::new().await;
    let rec = |ts: i64| Record {
        push_id: PUSH_ID.into(),
        ts,
        kind: "mother".into(),
        outcome: "accepted".into(),
        // TTL deletion is lazy: the item is still in the table.
        expires_at: ts + SEVEN_DAYS,
    };
    h.store.insert(rec(T0 - SEVEN_DAYS - 1));
    h.store.insert(rec(T0 - 30 * 24 * 3600));
    h.store.insert(rec(T0 - SEVEN_DAYS + 1));
    h.store.insert(rec(T0));
    let got: Vec<i64> = h
        .records_for(PUSH_ID)
        .await
        .iter()
        .map(|r| r["ts"].as_i64().unwrap())
        .collect();
    assert_eq!(got, vec![T0 - SEVEN_DAYS + 1, T0]);
}

#[tokio::test]
async fn the_seven_day_boundary_is_exclusive() {
    let h = Harness::new().await;
    h.store.insert(Record {
        push_id: PUSH_ID.into(),
        ts: T0 - SEVEN_DAYS,
        kind: "mother".into(),
        outcome: "accepted".into(),
        expires_at: T0,
    });
    assert!(
        h.records_for(PUSH_ID).await.is_empty(),
        "a record exactly 7 days old is returned"
    );
}

#[tokio::test]
async fn a_pushed_record_stays_visible_for_seven_days_then_disappears() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    h.clock.set(T0 + SEVEN_DAYS - 1);
    assert_eq!(h.records_for(PUSH_ID).await.len(), 1);
    h.clock.set(T0 + SEVEN_DAYS);
    assert!(h.records_for(PUSH_ID).await.is_empty());
    // It is still in the table: the read, not the store, enforces the window.
    assert_eq!(h.store.all().len(), 1);
}

#[tokio::test]
async fn records_requires_a_valid_push_id_query() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    for q in [
        vec![],
        vec![("push_id", "")],
        vec![("push_id", "abc")],
        vec![("push_id", &PUSH_ID.to_uppercase()[..])],
        vec![("push_id", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")],
        vec![("push_id", &PUSH_ID[..31])],
        vec![("pushid", PUSH_ID)],
    ] {
        let r = h.get_records(&q).await;
        assert_eq!(r.status, 400, "{q:?}: {}", r.body);
        assert!(!r.body.contains(PUSH_ID));
    }
}

// ─── W13-22: logs carry no content ───────────────────────────────────────────

/// Events seen on this thread while a [`LogCapture`] guard is alive.
///
/// A process-wide router is installed as the global `tracing` subscriber (once),
/// and forwards each event to the capture registered for the emitting thread.
/// Scoped per-test subscribers would race: `tracing` caches whether a callsite is
/// enabled, and a parallel test with no subscriber can cache "disabled" first.
#[derive(Clone, Default)]
struct LogCapture(Arc<Mutex<Vec<LoggedEvent>>>);

#[derive(Debug, Clone)]
struct LoggedEvent {
    level: tracing::Level,
    /// field name -> value as printed.
    fields: BTreeMap<String, String>,
}

impl LoggedEvent {
    fn text(&self) -> String {
        format!("{} {:?}", self.level, self.fields)
    }
}

struct FieldVisitor(BTreeMap<String, String>);

impl tracing::field::Visit for FieldVisitor {
    fn record_str(&mut self, f: &tracing::field::Field, v: &str) {
        self.0.insert(f.name().to_string(), v.to_string());
    }
    fn record_debug(&mut self, f: &tracing::field::Field, v: &dyn std::fmt::Debug) {
        self.0.insert(f.name().to_string(), format!("{v:?}"));
    }
}

thread_local! {
    static SINK: std::cell::RefCell<Option<LogCapture>> = const { std::cell::RefCell::new(None) };
}

struct Router;

impl tracing::Subscriber for Router {
    fn enabled(&self, _: &tracing::Metadata<'_>) -> bool {
        true
    }
    fn new_span(&self, _: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }
    fn record(&self, _: &tracing::span::Id, _: &tracing::span::Record<'_>) {}
    fn record_follows_from(&self, _: &tracing::span::Id, _: &tracing::span::Id) {}
    fn event(&self, event: &tracing::Event<'_>) {
        SINK.with(|sink| {
            if let Some(capture) = sink.borrow().as_ref() {
                let mut v = FieldVisitor(BTreeMap::new());
                event.record(&mut v);
                capture.0.lock().unwrap().push(LoggedEvent {
                    level: *event.metadata().level(),
                    fields: v.0,
                });
            }
        });
    }
    fn enter(&self, _: &tracing::span::Id) {}
    fn exit(&self, _: &tracing::span::Id) {}
}

struct CaptureGuard;

impl Drop for CaptureGuard {
    fn drop(&mut self) {
        SINK.with(|sink| *sink.borrow_mut() = None);
    }
}

/// Start capturing this thread's `tracing` events (tests run on one thread each).
fn capture_logs() -> (LogCapture, CaptureGuard) {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        tracing::subscriber::set_global_default(Router).expect("no other global subscriber");
    });
    let capture = LogCapture::default();
    SINK.with(|sink| *sink.borrow_mut() = Some(capture.clone()));
    (capture, CaptureGuard)
}

impl LogCapture {
    fn take(&self) -> Vec<LoggedEvent> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}

const LOG_MARKERS: [&str; 10] = [
    "TITLEMARK",
    "BODYMARK",
    "HOSTMARK",
    "REFMARK",
    "ITEMMARK",
    "THREADMARK",
    "COLLAPSEMARK",
    "c0ffee0badc0de5ec7e7a9", // the APNs token
    "daemon-token-v1",
    "BEGIN PRIVATE KEY",
];

fn marked() -> Value {
    with(|v| {
        v["title"] = json!("TITLEMARK");
        v["body"] = json!("BODYMARK");
        v["collapse_id"] = json!("COLLAPSEMARK");
        v["thread_id"] = json!("THREADMARK");
        v["apns_token"] = json!("c0ffee0badc0de5ec7e7a9");
        v["data"] = json!({"item": "ITEMMARK", "kind": "decision", "host": "HOSTMARK", "ref": "REFMARK"});
    })
}

fn assert_no_content_in(events: &[LoggedEvent], what: &str) {
    for e in events {
        let t = e.text();
        for m in LOG_MARKERS {
            assert!(!t.contains(m), "{what}: log line contains {m}: {t}");
        }
        assert!(!t.contains(PUSH_ID), "{what}: full push_id logged: {t}");
        assert!(!t.contains("eyJ"), "{what}: provider token logged: {t}");
    }
}

#[tokio::test]
async fn a_handled_push_logs_only_its_kind_a_six_hex_device_prefix_and_the_apns_status() {
    let (capture, _guard) = capture_logs();
    let h = Harness::new().await;
    let r = h.post(&marked()).await;
    assert_eq!(r.status, 200);

    let events = capture.take();
    assert!(!events.is_empty(), "the handler logged nothing");
    assert_no_content_in(&events, "success");

    // Every field other than the free-text message is one of the three facts.
    let allowed = ["decision", &PUSH_ID[..6], "200"];
    for e in &events {
        for (name, value) in &e.fields {
            if name == "message" {
                continue;
            }
            assert!(
                allowed.contains(&value.as_str()),
                "unexpected log field {name}={value}"
            );
        }
    }
    let seen: String = events.iter().map(LoggedEvent::text).collect::<Vec<_>>().join("\n");
    assert!(seen.contains("decision"), "kind not logged: {seen}");
    assert!(seen.contains(&PUSH_ID[..6]), "push_id prefix not logged: {seen}");
    assert!(seen.contains("200"), "APNs status not logged: {seen}");
    assert!(!seen.contains(&PUSH_ID[..7]), "more than six hex characters of push_id: {seen}");
}

#[tokio::test]
async fn no_path_through_the_handler_logs_content() {
    let (capture, _guard) = capture_logs();

    // APNs refuses.
    let h = Harness::with_response(
        ResponseTemplate::new(400).set_body_json(json!({"reason": "BadDeviceToken"})),
    )
    .await;
    h.post(&marked()).await;
    // A refused request, with markers in the offending fields and an unknown field.
    h.post(&with(|v| {
        v["title"] = json!("TITLEMARK".repeat(20));
        v["data"]["host"] = json!("HOSTMARK");
        v["refmark_unknown"] = json!("REFMARK");
    }))
    .await;
    h.post_bytes(b"{\"title\": \"TITLEMARK").await;
    // A wrong bearer.
    h.post_as("daemon-token-v1-wrong", &marked()).await;
    // The rate ceiling.
    h.store.preload_rate(PUSH_ID, T0 / 600, 60);
    assert_eq!(h.post(&marked()).await.status, 429);
    // A failing record write, and a failing secret.
    h.store.preload_rate(PUSH_ID, T0 / 600, 0);
    h.store.fail_put.store(true, Ordering::SeqCst);
    h.post(&marked()).await;
    h.secrets.fail_apns.store(true, Ordering::SeqCst);
    h.clock.set(T0 + 100_000);
    h.post(&marked()).await;
    // APNs unreachable.
    let h2 = Harness::unreachable().await;
    h2.post(&marked()).await;
    // Reads.
    h.get_records(&[("push_id", PUSH_ID)]).await;

    let events = capture.take();
    assert!(!events.is_empty());
    assert_no_content_in(&events, "all paths");
}

// ─── W13-23: the SAM template ────────────────────────────────────────────────

fn template() -> serde_yaml::Value {
    let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/template.yaml"))
        .expect("template.yaml");
    serde_yaml::from_str(&text).expect("template.yaml is YAML")
}

/// `!Ref X` / `!GetAtt X.Y` as ("!Ref", "X").
fn tagged(v: &serde_yaml::Value) -> Option<(String, String)> {
    match v {
        serde_yaml::Value::Tagged(t) => Some((
            t.tag.to_string(),
            t.value.as_str().unwrap_or_default().to_string(),
        )),
        _ => None,
    }
}

fn resources_of_type(t: &serde_yaml::Value, ty: &str) -> Vec<(String, serde_yaml::Value)> {
    t["Resources"]
        .as_mapping()
        .expect("Resources")
        .iter()
        .filter(|(_, v)| v["Type"].as_str() == Some(ty))
        .map(|(k, v)| (k.as_str().unwrap().to_string(), v.clone()))
        .collect()
}

fn one(t: &serde_yaml::Value, ty: &str) -> (String, serde_yaml::Value) {
    let mut found = resources_of_type(t, ty);
    assert_eq!(found.len(), 1, "expected exactly one {ty}");
    found.remove(0)
}

fn list_of(v: &serde_yaml::Value) -> Vec<serde_yaml::Value> {
    match v {
        serde_yaml::Value::Sequence(s) => s.clone(),
        other => vec![other.clone()],
    }
}

#[test]
fn the_log_group_keeps_logs_for_seven_days() {
    let t = template();
    let (_, group) = one(&t, "AWS::Logs::LogGroup");
    assert_eq!(group["Properties"]["RetentionInDays"].as_i64(), Some(7));
    // It is the function's own log group.
    let name = match &group["Properties"]["LogGroupName"] {
        serde_yaml::Value::Tagged(t) => t.value.as_str().unwrap().to_string(),
        other => other.as_str().unwrap().to_string(),
    };
    assert!(name.starts_with("/aws/lambda/"), "{name}");
}

#[test]
fn the_table_expires_items_on_expires_at() {
    let t = template();
    let (_, table) = one(&t, "AWS::DynamoDB::Table");
    let ttl = &table["Properties"]["TimeToLiveSpecification"];
    assert_eq!(ttl["AttributeName"].as_str(), Some("expires_at"));
    assert_eq!(ttl["Enabled"].as_bool(), Some(true));
}

#[test]
fn the_function_url_is_public_because_the_bearer_is_checked_in_code() {
    let t = template();
    let (_, f) = one(&t, "AWS::Serverless::Function");
    assert_eq!(
        f["Properties"]["FunctionUrlConfig"]["AuthType"].as_str(),
        Some("NONE")
    );
}

#[test]
fn the_function_may_only_put_query_and_update_the_table_and_read_the_two_secrets() {
    let t = template();
    let (_, f) = one(&t, "AWS::Serverless::Function");
    let policies = list_of(&f["Properties"]["Policies"]);

    // No managed policies, only inline statements.
    let mut statements = Vec::new();
    for p in &policies {
        let s = p.get("Statement").unwrap_or_else(|| panic!("policy {p:?} is not an inline statement"));
        statements.extend(list_of(s));
    }
    assert_eq!(statements.len(), 2, "expected the table and the secrets, nothing else");

    // No wildcard anywhere in what is granted.
    fn walk(v: &serde_yaml::Value, out: &mut Vec<String>) {
        match v {
            serde_yaml::Value::String(s) => out.push(s.clone()),
            serde_yaml::Value::Sequence(s) => s.iter().for_each(|x| walk(x, out)),
            serde_yaml::Value::Mapping(m) => m.iter().for_each(|(_, x)| walk(x, out)),
            serde_yaml::Value::Tagged(t) => walk(&t.value, out),
            _ => {}
        }
    }
    let mut strings = Vec::new();
    walk(&serde_yaml::Value::Sequence(statements.clone()), &mut strings);
    assert!(
        strings.iter().all(|s| !s.contains('*')),
        "a wildcard in the policy: {strings:?}"
    );

    let mut table_actions = None;
    let mut secret_actions = None;
    for s in &statements {
        assert_eq!(s["Effect"].as_str(), Some("Allow"));
        let actions: BTreeSet<String> = list_of(&s["Action"])
            .iter()
            .map(|a| a.as_str().unwrap().to_string())
            .collect();
        let resources: Vec<(String, String)> = list_of(&s["Resource"])
            .iter()
            .map(|r| tagged(r).expect("a resource is a !Ref or !GetAtt, not a literal"))
            .collect();
        if actions.iter().all(|a| a.starts_with("dynamodb:")) {
            table_actions = Some(actions);
            assert_eq!(resources, vec![("!GetAtt".to_string(), "DeliveryTable.Arn".to_string())]);
        } else {
            secret_actions = Some(actions);
            let names: BTreeSet<(String, String)> = resources.into_iter().collect();
            assert_eq!(
                names,
                [
                    ("!Ref".to_string(), "DaemonTokenSecret".to_string()),
                    ("!Ref".to_string(), "ApnsSecret".to_string())
                ]
                .into_iter()
                .collect()
            );
        }
    }
    assert_eq!(
        table_actions.unwrap(),
        set(&["dynamodb:PutItem", "dynamodb:Query", "dynamodb:UpdateItem"])
    );
    assert_eq!(secret_actions.unwrap(), set(&["secretsmanager:GetSecretValue"]));
}

#[test]
fn the_apns_secret_is_shaped_the_way_the_relay_reads_it() {
    let t = template();
    let (_, secret) = resources_of_type(&t, "AWS::SecretsManager::Secret")
        .into_iter()
        .find(|(n, _)| n == "ApnsSecret")
        .expect("ApnsSecret");
    let placeholder = secret["Properties"]["SecretString"].as_str().unwrap();
    let creds: ApnsCredentials = serde_json::from_str(placeholder).expect("secret parses as credentials");
    assert_eq!(creds.topic, "REPLACE");
}

// ─── W13-37 and the APNs request ─────────────────────────────────────────────

#[tokio::test]
async fn mutable_content_true_sets_aps_mutable_content_to_1() {
    let h = Harness::new().await;
    h.post(&with(|v| v["mutable_content"] = json!(true))).await;
    let aps = &apns_body(&h.only_apns_request().await)["aps"];
    assert_eq!(aps["mutable-content"], json!(1));
}

#[tokio::test]
async fn mutable_content_false_leaves_the_key_out_entirely() {
    let h = Harness::new().await;
    h.post(&with(|v| v["mutable_content"] = json!(false))).await;
    let body = apns_body(&h.only_apns_request().await);
    assert!(
        body["aps"].get("mutable-content").is_none(),
        "aps carries mutable-content: {}",
        body["aps"]
    );
    assert!(!body.to_string().contains("mutable"));
}

#[tokio::test]
async fn the_apns_request_has_the_expected_path_headers_and_a_json_body() {
    let h = Harness::new().await;
    h.post(&with(|v| {
        v["priority"] = json!(5);
        v["expiration_unix"] = json!(T0 + 7200);
        v["collapse_id"] = json!("collapse-xyz");
    }))
    .await;
    let req = h.only_apns_request().await;
    assert_eq!(req.method.as_str(), "POST");
    assert_eq!(req.url.path(), format!("/3/device/{}", "0f".repeat(32)));
    assert_eq!(header(&req, "apns-push-type"), "alert");
    assert_eq!(header(&req, "apns-priority"), "5");
    assert_eq!(header(&req, "apns-expiration"), (T0 + 7200).to_string());
    assert_eq!(header(&req, "apns-collapse-id"), "collapse-xyz");
    assert_eq!(header(&req, "apns-topic"), TOPIC);
    assert!(header(&req, "authorization").starts_with("bearer "));
    assert!(header(&req, "content-type").starts_with("application/json"));
}

#[tokio::test]
async fn priority_10_and_a_past_expiration_map_to_the_headers() {
    let h = Harness::new().await;
    h.post(&with(|v| {
        v["priority"] = json!(10);
        v["expiration_unix"] = json!(-50);
    }))
    .await;
    let req = h.only_apns_request().await;
    assert_eq!(header(&req, "apns-priority"), "10");
    // Apple reads 0 as "do not store"; a negative number is not a valid header.
    assert_eq!(header(&req, "apns-expiration"), "0");
}

#[tokio::test]
async fn the_provider_token_is_an_es256_jwt_for_the_team_and_key_that_verifies() {
    let h = Harness::new().await;
    h.clock.set(T0 + 17);
    h.post(&valid()).await;
    let jwt = jwt_of(&h.only_apns_request().await);

    let header = jsonwebtoken::decode_header(&jwt).unwrap();
    assert_eq!(header.alg, Algorithm::ES256);
    assert_eq!(header.kid.as_deref(), Some(KEY_ID));

    let mut v = Validation::new(Algorithm::ES256);
    v.required_spec_claims.clear();
    v.validate_exp = false;
    let good = DecodingKey::from_ec_pem(h.key.public_pem.as_bytes()).unwrap();
    let claims = jsonwebtoken::decode::<Value>(&jwt, &good, &v).expect("signature verifies").claims;
    assert_eq!(claims["iss"], TEAM_ID);
    assert_eq!(claims["iat"], T0 + 17);

    // The check is meaningful: another key does not verify it.
    let other = DecodingKey::from_ec_pem(test_key().public_pem.as_bytes()).unwrap();
    assert!(jsonwebtoken::decode::<Value>(&jwt, &other, &v).is_err());
}

#[tokio::test]
async fn an_alert_carries_title_body_level_thread_sound_badge_and_the_routing_keys() {
    let h = Harness::new().await;
    h.post(&with(|v| {
        v["data"]["resolved"] = json!(false);
        v["interruption_level"] = json!("time-sensitive");
    }))
    .await;
    let body = apns_body(&h.only_apns_request().await);
    assert_eq!(
        keys(&body),
        set(&["aps", "item", "kind", "host", "ref", "resolved"])
    );
    assert_eq!(
        keys(&body["aps"]),
        set(&["alert", "interruption-level", "thread-id", "sound", "badge"])
    );
    assert_eq!(
        body["aps"]["alert"],
        json!({"title": "Job finished", "body": "Mother finished the job"})
    );
    assert_eq!(body["aps"]["interruption-level"], "time-sensitive");
    assert_eq!(body["aps"]["thread-id"], "thread-1");
    assert_eq!(body["aps"]["sound"], "default");
    assert_eq!(body["aps"]["badge"], 2);
    assert_eq!(body["item"], "item-1");
    assert_eq!(body["kind"], "mother");
    assert_eq!(body["host"], "sendai");
    assert_eq!(body["ref"], "job-42");
    assert_eq!(body["resolved"], false);
}

#[tokio::test]
async fn an_active_alert_makes_a_sound_and_a_passive_one_does_not() {
    for (level, sound) in [("active", true), ("time-sensitive", true), ("passive", false)] {
        let h = Harness::new().await;
        h.post(&with(|v| v["interruption_level"] = json!(level))).await;
        let aps = apns_body(&h.only_apns_request().await)["aps"].clone();
        assert_eq!(aps["interruption-level"], level);
        assert_eq!(aps.get("sound").is_some(), sound, "{level}: {aps}");
        if sound {
            assert_eq!(aps["sound"], "default");
        }
    }
}

#[tokio::test]
async fn a_badge_only_push_sends_nothing_but_the_badge_in_aps() {
    let h = Harness::new().await;
    h.post(&with(|v| {
        let o = v.as_object_mut().unwrap();
        o.remove("title");
        o.remove("body");
        v["badge"] = json!(7);
    }))
    .await;
    let body = apns_body(&h.only_apns_request().await);
    assert_eq!(body["aps"], json!({"badge": 7}));
    // Still an `alert` push type, as the plan says (the device corrects the badge).
    assert_eq!(
        header(&h.only_apns_request().await, "apns-push-type"),
        "alert"
    );
}

#[tokio::test]
async fn routing_keys_the_request_did_not_have_are_left_out_not_sent_as_null() {
    let h = Harness::new().await;
    h.post(&with(|v| {
        v["data"].as_object_mut().unwrap().remove("ref");
    }))
    .await;
    let body = apns_body(&h.only_apns_request().await);
    assert_eq!(keys(&body), set(&["aps", "item", "kind", "host"]));
}

#[tokio::test]
async fn the_apns_body_carries_no_bearer_token_push_id_or_collapse_id() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    let req = h.only_apns_request().await;
    let body = String::from_utf8(req.body.clone()).unwrap();
    assert!(!body.contains(PUSH_ID), "the relay's device reference reached Apple");
    assert!(!body.contains(DAEMON_TOKEN));
    assert!(!body.contains("collapse-1"));
}

/// Records which host name the client asked to resolve, then points it at a port
/// nothing listens on, so the call fails without touching the network.
struct RecordingResolver {
    asked: Arc<Mutex<Vec<String>>>,
    port: u16,
}

impl reqwest::dns::Resolve for RecordingResolver {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        self.asked.lock().unwrap().push(name.as_str().to_string());
        let addr = SocketAddr::from(([127, 0, 0, 1], self.port));
        Box::pin(async move {
            Ok(Box::new(std::iter::once(addr)) as reqwest::dns::Addrs)
        })
    }
}

#[tokio::test]
async fn the_environment_picks_apples_sandbox_or_production_host() {
    for (environment, host) in [
        ("sandbox", "api.sandbox.push.apple.com"),
        ("production", "api.push.apple.com"),
    ] {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let client = reqwest::Client::builder()
            .no_proxy()
            .dns_resolver(Arc::new(RecordingResolver {
                asked: asked.clone(),
                port: closed_port(),
            }))
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap();
        let req: push_relay::model::PushRequest =
            serde_json::from_value(with(|v| v["environment"] = json!(environment))).unwrap();
        let sent = push_relay::apns::send(&client, None, "jwt", TOPIC, &req).await;
        assert!(sent.is_err(), "nothing listens there");
        assert_eq!(*asked.lock().unwrap(), vec![host.to_string()], "{environment}");
    }
}

// ─── caching ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn the_daemon_token_is_re_read_at_most_every_300_seconds() {
    let h = Harness::new().await;
    assert_eq!(h.post(&valid()).await.status, 200);
    assert_eq!(h.secrets.token_reads.load(Ordering::SeqCst), 1);
    h.clock.set(T0 + 1);
    assert_eq!(h.post(&valid()).await.status, 200);
    h.clock.set(T0 + 299);
    assert_eq!(h.post(&valid()).await.status, 200);
    assert_eq!(h.get_records(&[("push_id", PUSH_ID)]).await.status, 200);
    assert_eq!(
        h.secrets.token_reads.load(Ordering::SeqCst),
        1,
        "re-read inside the 300 s window"
    );
    h.clock.set(T0 + 300);
    assert_eq!(h.post(&valid()).await.status, 200);
    assert_eq!(h.secrets.token_reads.load(Ordering::SeqCst), 2, "not re-read at 300 s");
    h.clock.set(T0 + 599);
    h.post(&valid()).await;
    assert_eq!(h.secrets.token_reads.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn a_rotated_daemon_token_takes_effect_after_the_window_and_not_before() {
    let h = Harness::new().await;
    assert_eq!(h.post(&valid()).await.status, 200);
    h.secrets.set_token("daemon-token-v2");

    h.clock.set(T0 + 299);
    assert_eq!(h.post_as("daemon-token-v1", &valid()).await.status, 200, "old token, inside window");
    assert_eq!(h.post_as("daemon-token-v2", &valid()).await.status, 401, "new token, inside window");

    h.clock.set(T0 + 300);
    assert_eq!(h.post_as("daemon-token-v2", &valid()).await.status, 200, "new token, after window");
    assert_eq!(h.post_as("daemon-token-v1", &valid()).await.status, 401, "old token, after window");
}

#[tokio::test]
async fn the_apns_credentials_and_provider_token_last_50_minutes() {
    let h = Harness::new().await;
    h.post(&valid()).await;
    h.secrets.set_topic("com.example.Rotated");

    h.clock.set(T0 + 600);
    h.post(&valid()).await;
    h.clock.set(T0 + 2999);
    h.post(&valid()).await;
    assert_eq!(
        h.secrets.apns_reads.load(Ordering::SeqCst),
        1,
        "APNs credentials re-read inside 50 minutes"
    );
    h.clock.set(T0 + 3000);
    h.post(&valid()).await;
    assert_eq!(
        h.secrets.apns_reads.load(Ordering::SeqCst),
        2,
        "APNs credentials not re-read at 50 minutes"
    );

    let reqs = h.apns_requests().await;
    assert_eq!(reqs.len(), 4);
    let iat = |r: &wiremock::Request| {
        let mut v = Validation::new(Algorithm::ES256);
        v.required_spec_claims.clear();
        v.validate_exp = false;
        let key = DecodingKey::from_ec_pem(h.key.public_pem.as_bytes()).unwrap();
        jsonwebtoken::decode::<Value>(&jwt_of(r), &key, &v).unwrap().claims["iat"]
            .as_i64()
            .unwrap()
    };
    // The provider token is signed once per window, and re-signed after it.
    assert_eq!(iat(&reqs[0]), T0);
    assert_eq!(iat(&reqs[1]), T0);
    assert_eq!(iat(&reqs[2]), T0);
    assert_eq!(jwt_of(&reqs[0]), jwt_of(&reqs[2]));
    assert_eq!(iat(&reqs[3]), T0 + 3000);
    assert_ne!(jwt_of(&reqs[0]), jwt_of(&reqs[3]));
    // The topic comes from the same cached secret.
    assert_eq!(header(&reqs[2], "apns-topic"), TOPIC);
    assert_eq!(header(&reqs[3], "apns-topic"), "com.example.Rotated");
}

#[tokio::test]
async fn a_failed_secret_read_is_not_cached() {
    let h = Harness::new().await;
    h.secrets.fail_apns.store(true, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 503);
    h.secrets.fail_apns.store(false, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 200);

    let h = Harness::new().await;
    h.secrets.fail_token.store(true, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 503);
    h.secrets.fail_token.store(false, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 200);
}

// ─── rate ceiling ────────────────────────────────────────────────────────────

#[tokio::test]
async fn the_61st_push_for_one_device_in_ten_minutes_is_429_and_never_reaches_apns() {
    let h = Harness::new().await;
    for i in 1..=60 {
        let r = h.post(&valid()).await;
        assert_eq!(r.status, 200, "push {i}: {}", r.body);
    }
    assert_eq!(h.apns_requests().await.len(), 60);

    let r = h.post(&valid()).await;
    assert_eq!(r.status, 429, "{}", r.body);
    assert_eq!(h.apns_requests().await.len(), 60, "the 61st reached APNs");
    let r = h.post(&valid()).await;
    assert_eq!(r.status, 429);
    assert_eq!(h.apns_requests().await.len(), 60);
}

#[tokio::test]
async fn the_rate_ceiling_is_per_device() {
    let h = Harness::new().await;
    for _ in 0..61 {
        h.post(&valid()).await;
    }
    assert_eq!(h.post(&valid()).await.status, 429);
    let other = with(|v| v["push_id"] = json!(OTHER_PUSH_ID));
    assert_eq!(h.post(&other).await.status, 200);
}

#[tokio::test]
async fn the_rate_ceiling_resets_when_the_ten_minute_window_rolls_over() {
    let h = Harness::new().await;
    for _ in 0..60 {
        h.post(&valid()).await;
    }
    assert_eq!(h.post(&valid()).await.status, 429);
    h.clock.set(T0 + 599);
    assert_eq!(h.post(&valid()).await.status, 429, "still the same window at 599 s");
    h.clock.set(T0 + 600);
    assert_eq!(h.post(&valid()).await.status, 200, "a new window at 600 s");
    // And the new window has its own budget of 60.
    for _ in 0..59 {
        assert_eq!(h.post(&valid()).await.status, 200);
    }
    assert_eq!(h.post(&valid()).await.status, 429);
}

#[tokio::test]
async fn the_rate_counter_outlives_its_window() {
    let h = Harness::new().await;
    h.clock.set(T0 + 123);
    h.post(&valid()).await;
    let bumps = h.store.rate_expiry.lock().unwrap().clone();
    assert_eq!(bumps.len(), 1);
    let (_, _, expires_at) = &bumps[0];
    assert!(*expires_at >= T0 + 600, "the counter expires before its window ends");
    assert!(*expires_at <= T0 + 3600, "the counter lingers for hours");
}

#[tokio::test]
async fn refused_requests_do_not_spend_the_rate_budget() {
    let h = Harness::new().await;
    for _ in 0..70 {
        assert_eq!(h.post(&with(|v| v["priority"] = json!(3))).await.status, 400);
    }
    for _ in 0..70 {
        assert_eq!(
            h.post_as("wrong", &valid()).await.status,
            401
        );
    }
    assert_eq!(h.post(&valid()).await.status, 200);
}

// ─── failures ────────────────────────────────────────────────────────────────

fn assert_opaque_503(r: &Response) {
    assert_eq!(r.status, 503, "{}", r.body);
    for leak in ["SECRETDETAIL", "STOREDETAIL", "arn:aws", "AccessDenied", "dynamo", "secretsmanager"] {
        assert!(!r.body.contains(leak), "503 leaks {leak}: {}", r.body);
    }
}

#[tokio::test]
async fn an_unreadable_daemon_token_is_a_503_without_detail_on_both_endpoints() {
    let h = Harness::new().await;
    h.secrets.fail_token.store(true, Ordering::SeqCst);
    assert_opaque_503(&h.post(&valid()).await);
    assert_opaque_503(&h.get_records(&[("push_id", PUSH_ID)]).await);
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn unreadable_apns_credentials_are_a_503_without_detail_and_no_apns_call() {
    let h = Harness::new().await;
    h.secrets.fail_apns.store(true, Ordering::SeqCst);
    assert_opaque_503(&h.post(&valid()).await);
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn a_key_that_is_not_a_valid_signing_key_is_a_503_without_detail() {
    let h = Harness::new().await;
    h.secrets.creds.lock().unwrap().key_pem = "-----BEGIN PRIVATE KEY-----\nLEAKMARK\n-----END PRIVATE KEY-----\n".into();
    let r = h.post(&valid()).await;
    assert_opaque_503(&r);
    assert!(!r.body.contains("LEAKMARK"));
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn a_failing_rate_counter_is_a_503_without_detail_and_no_apns_call() {
    let h = Harness::new().await;
    h.store.fail_rate.store(true, Ordering::SeqCst);
    assert_opaque_503(&h.post(&valid()).await);
    assert!(h.apns_requests().await.is_empty());
}

#[tokio::test]
async fn a_failing_record_read_is_a_503_without_detail() {
    let h = Harness::new().await;
    h.store.fail_read.store(true, Ordering::SeqCst);
    assert_opaque_503(&h.get_records(&[("push_id", PUSH_ID)]).await);
}

#[tokio::test]
async fn a_failing_put_record_does_not_fail_the_push() {
    let h = Harness::new().await;
    h.store.fail_put.store(true, Ordering::SeqCst);
    let r = h.post(&valid()).await;
    assert_eq!(r.status, 200, "{}", r.body);
    assert_eq!(json_of(&r), json!({"apns_status": 200, "apns_reason": null}));
    assert!(!r.body.contains("STOREDETAIL"));
    assert_eq!(h.apns_requests().await.len(), 1);
    assert_eq!(h.store.put_calls.load(Ordering::SeqCst), 1, "the write was attempted");

    // The same for a push APNs refused.
    let h = Harness::with_response(
        ResponseTemplate::new(410).set_body_json(json!({"reason": "Unregistered"})),
    )
    .await;
    h.store.fail_put.store(true, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 200);

    // And for an unreachable APNs: still the 502, not a 503.
    let h = Harness::unreachable().await;
    h.store.fail_put.store(true, Ordering::SeqCst);
    assert_eq!(h.post(&valid()).await.status, 502);
}

// ─── the credentials never print their key ───────────────────────────────────

#[test]
fn apns_credentials_never_print_the_key() {
    let creds = ApnsCredentials {
        key_pem: "-----BEGIN PRIVATE KEY-----\nKEYBODYMARK\n-----END PRIVATE KEY-----\n".into(),
        key_id: KEY_ID.into(),
        team_id: TEAM_ID.into(),
        topic: TOPIC.into(),
    };
    for printed in [format!("{creds:?}"), format!("{creds:#?}"), format!("{:?}", Some(&creds))] {
        assert!(!printed.contains("KEYBODYMARK"), "{printed}");
        assert!(!printed.contains("PRIVATE KEY"), "{printed}");
    }
}

#[test]
fn apns_credentials_parse_from_the_secret_json() {
    let creds: ApnsCredentials = serde_json::from_value(json!({
        "key_pem": "pem", "key_id": "kid", "team_id": "team", "topic": "com.x.y"
    }))
    .unwrap();
    assert_eq!(
        (creds.key_pem.as_str(), creds.key_id.as_str(), creds.team_id.as_str(), creds.topic.as_str()),
        ("pem", "kid", "team", "com.x.y")
    );
}
