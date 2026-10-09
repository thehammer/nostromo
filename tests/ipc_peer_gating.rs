//! Integration tests for peer-trust gating of Teri/Fred/work data on the IPC
//! server.
//!
//! `nostromd` serves the Mac app over a Unix socket and iOS/LAN clients over an
//! **unauthenticated** TCP listener. These tests pin the externally observable
//! contract, over real sockets:
//!
//! * a TCP peer never receives Teri/Fred/work frames (whatever its topic list
//!   says, including the empty "everything" list) and is told once, via
//!   `Withheld`, that they are not delivered on this transport;
//! * a TCP peer's sensitive *requests* are refused with
//!   `requires_secure_connection` and change nothing;
//! * a Unix peer gets all of it, and its requests reach the installed work
//!   services;
//! * the latest Teri/Fred/work frame per key is retained and replayed to a
//!   Unix client that subscribes later (never to a TCP client).
//!
//! Synchronisation notes: after `Subscribe` every helper sends a `Ping` and
//! reads until the `Pong`. The `Pong` is produced by the connection's main
//! loop, which only starts after every attach-time replay has been written, so
//! "Pong seen" means "subscription registered and replays flushed". "Nothing
//! sensitive arrived" is then proven with a *control frame* broadcast after the
//! sensitive ones: the broadcast channel is ordered, so once the control frame
//! shows up any earlier frame that was going to be delivered already has been.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::service::{
    install_fred_detail_service, install_work_service, reset_for_test, FredDetailService,
    WorkService,
};
use nostromo::data::work::{
    PicksSnapshot, SendOutcome, SendPreview, SendRequest, SourceState, SourceStatus, WorkDetail,
    WorkError, WorkItem, WorkResult, WorkSource,
};
use nostromo::ipc::{
    codec::{read_frame, write_frame},
    decisions::DecisionRegistry,
    protocol::{ClientMsg, ServerMsg, Topic, PROTOCOL_VERSION},
    server::Server,
    PtyManager, SessionManager,
};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};

// ── server harness ────────────────────────────────────────────────────────────

struct Harness {
    server: Server,
    socket_path: std::path::PathBuf,
    tcp_port: u16,
    _tmp: TempDir,
}

/// `Server::bind` on a temp Unix socket plus `bind_tcp` on an ephemeral port.
async fn spawn_server() -> Harness {
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::new()));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .expect("bind unix socket");

    let tcp_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind tcp listener");
    let tcp_port = tcp_listener.local_addr().expect("local addr").port();

    server.bind_tcp(
        tcp_listener,
        pty_mgr,
        session_mgr,
        tmp.path().join("perri-state"),
        decisions,
    );

    Harness { server, socket_path, tcp_port, _tmp: tmp }
}

impl Harness {
    fn broadcast(&self, msg: ServerMsg) {
        self.server.broadcast(msg);
    }

    async fn unix(&self, topics: Vec<Topic>) -> (UnixStream, Vec<ServerMsg>) {
        let mut s = UnixStream::connect(&self.socket_path).await.expect("unix connect");
        let replay = handshake(&mut s, topics).await;
        (s, replay)
    }

    async fn tcp(&self, topics: Vec<Topic>) -> (TcpStream, Vec<ServerMsg>) {
        let mut s = TcpStream::connect(("127.0.0.1", self.tcp_port)).await.expect("tcp connect");
        let replay = handshake(&mut s, topics).await;
        (s, replay)
    }
}

// ── generic wire helpers (one set serves UnixStream and TcpStream) ────────────

async fn send<S: AsyncWrite + Unpin>(stream: &mut S, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    write_frame(stream, &bytes).await.expect("write frame");
}

async fn recv<S: AsyncRead + Unpin>(stream: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Read frames until `done` accepts one; returns every frame read, the
/// accepting frame last.
async fn recv_until<S: AsyncRead + Unpin>(
    stream: &mut S,
    mut done: impl FnMut(&ServerMsg) -> bool,
) -> Vec<ServerMsg> {
    let mut frames = Vec::new();
    loop {
        let msg = recv(stream).await;
        let stop = done(&msg);
        frames.push(msg);
        if stop {
            return frames;
        }
    }
}

/// Hello -> Welcome -> Subscribe, then Ping and read until Pong. Returns the
/// frames that arrived between `Subscribe` and `Pong` (attach-time replays),
/// excluding the Pong itself.
async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    topics: Vec<Topic>,
) -> Vec<ServerMsg> {
    send(
        stream,
        &ClientMsg::Hello { client_id: "peer-gating-it".into(), protocol_version: PROTOCOL_VERSION },
    )
    .await;
    assert!(matches!(recv(stream).await, ServerMsg::Welcome { .. }));
    send(stream, &ClientMsg::Subscribe { topics, renders_decisions: false }).await;
    sync(stream).await
}

/// Ping and read until Pong; returns everything before the Pong.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Vec<ServerMsg> {
    send(stream, &ClientMsg::Ping).await;
    let mut frames = recv_until(stream, |m| matches!(m, ServerMsg::Pong)).await;
    frames.pop(); // the Pong
    frames
}

// ── payload builders ──────────────────────────────────────────────────────────

fn fred_state(unread: usize) -> ServerMsg {
    ServerMsg::FredState {
        mailbox: MailboxSnapshot { unread_count: unread, ..Default::default() },
        calendar: CalendarSnapshot::default(),
    }
}

fn teri_state() -> ServerMsg {
    ServerMsg::TeriState {
        todos: TeriTodosSnapshot {
            items: vec![TeriTodo {
                id: 1,
                title: "secret-todo".into(),
                status: "open".into(),
                priority: 2,
                due_date: None,
                jira_key: None,
            }],
            ..Default::default()
        },
    }
}

fn source_status(source: WorkSource) -> ServerMsg {
    ServerMsg::WorkSourceStatus {
        status: SourceStatus {
            source,
            state: SourceState::Fresh,
            updated_at: None,
            reason: None,
            retry_at: None,
            count: 1,
            group_errors: vec![],
        },
    }
}

fn work_item(id: &str) -> WorkItem {
    serde_json::from_value(serde_json::json!({
        "id": id,
        "source": "repo_docs",
        "kind": "plan",
        "title": format!("title of {id}"),
    }))
    .expect("work item")
}

fn work_snapshot(source: WorkSource, group: Option<&str>, item_ids: &[&str]) -> ServerMsg {
    ServerMsg::WorkSnapshot {
        source,
        group: group.map(str::to_string),
        items: item_ids.iter().map(|id| work_item(id)).collect(),
    }
}

fn teri_picks() -> ServerMsg {
    ServerMsg::TeriPicks { picks: PicksSnapshot::default() }
}

fn work_detail(item_id: &str, title: &str) -> WorkDetail {
    WorkDetail {
        item_id: item_id.into(),
        title: title.into(),
        fields: vec![],
        markdown: String::new(),
        files: vec![],
        links: vec![],
    }
}

fn send_outcome() -> SendOutcome {
    SendOutcome { kind: "created".into(), focus_tag: Some("fake-focus".into()), job_id: None }
}

fn send_preview(item_id: &str) -> SendPreview {
    SendPreview {
        item_id: item_id.into(),
        agent: "cody".into(),
        working_directory: None,
        label: "fake-preview".into(),
        context: "fake context".into(),
        existing: vec![],
    }
}

fn focus_registry_updated() -> ServerMsg {
    ServerMsg::FocusRegistryUpdated { focuses: vec![] }
}

/// Every broadcast kind that carries (or answers a request for) Teri/Fred
/// data, including targeted-reply kinds a buggy daemon might broadcast.
fn all_sensitive_broadcasts() -> Vec<ServerMsg> {
    vec![
        fred_state(7),
        teri_state(),
        source_status(WorkSource::Jira),
        work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:plans/x.md"]),
        teri_picks(),
        ServerMsg::WorkDetail {
            request_id: "stray-detail".into(),
            result: WorkResult::Ok(work_detail("jira:X", "leaked")),
        },
        ServerMsg::WorkSendPreview {
            request_id: "stray-preview".into(),
            result: WorkResult::Ok(send_preview("jira:X")),
        },
        ServerMsg::WorkSendResult {
            request_id: "stray-send".into(),
            result: WorkResult::Ok(send_outcome()),
        },
    ]
}

fn is_sensitive(msg: &ServerMsg) -> bool {
    matches!(
        msg,
        ServerMsg::FredState { .. }
            | ServerMsg::TeriState { .. }
            | ServerMsg::WorkSourceStatus { .. }
            | ServerMsg::WorkSnapshot { .. }
            | ServerMsg::TeriPicks { .. }
            | ServerMsg::WorkDetail { .. }
            | ServerMsg::WorkSendPreview { .. }
            | ServerMsg::WorkSendResult { .. }
    )
}

fn count<F: Fn(&ServerMsg) -> bool>(frames: &[ServerMsg], f: F) -> usize {
    frames.iter().filter(|m| f(m)).count()
}

fn assert_exactly_one_withheld(frames: &[ServerMsg]) {
    let withheld: Vec<&ServerMsg> =
        frames.iter().filter(|m| matches!(m, ServerMsg::Withheld { .. })).collect();
    assert_eq!(withheld.len(), 1, "expected exactly one Withheld, got frames: {frames:?}");
    match withheld[0] {
        ServerMsg::Withheld { topics, reason } => {
            assert_eq!(topics, &vec![Topic::Fred, Topic::Teri, Topic::Work]);
            assert_eq!(reason, "requires_secure_connection");
        }
        _ => unreachable!(),
    }
}

fn assert_no_sensitive(frames: &[ServerMsg]) {
    let leaked: Vec<&ServerMsg> = frames.iter().filter(|m| is_sensitive(m)).collect();
    assert!(leaked.is_empty(), "sensitive frames reached the peer: {leaked:?}");
}

// ── global service registry fakes ─────────────────────────────────────────────

/// Serialises tests that install fakes into the process-global registry.
static REGISTRY_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Holds the registry lock for a test's duration and clears the registry on
/// entry and on drop (so a failing test does not leak its fakes).
struct RegistryGuard {
    _lock: tokio::sync::MutexGuard<'static, ()>,
}

impl RegistryGuard {
    async fn acquire() -> Self {
        let lock = REGISTRY_LOCK.lock().await;
        reset_for_test();
        Self { _lock: lock }
    }
}

impl Drop for RegistryGuard {
    fn drop(&mut self) {
        reset_for_test();
    }
}

type Calls = Arc<Mutex<Vec<String>>>;

struct FakeWorkService {
    calls: Calls,
}

#[async_trait]
impl WorkService for FakeWorkService {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        self.calls.lock().unwrap().push(format!("work.detail:{item_id}"));
        Ok(work_detail(item_id, "from-work-service"))
    }
    async fn refresh(&self, source: Option<WorkSource>, fred: bool) -> Result<(), WorkError> {
        self.calls.lock().unwrap().push(format!("work.refresh:{source:?}:{fred}"));
        Ok(())
    }
    async fn refresh_picks(&self, reason: &str) -> Result<(), WorkError> {
        self.calls.lock().unwrap().push(format!("work.refresh_picks:{reason}"));
        Ok(())
    }
    async fn send_preview(&self, item_id: &str) -> Result<SendPreview, WorkError> {
        self.calls.lock().unwrap().push(format!("work.send_preview:{item_id}"));
        Ok(send_preview(item_id))
    }
    async fn send(&self, request: SendRequest) -> Result<SendOutcome, WorkError> {
        self.calls.lock().unwrap().push(format!(
            "work.send:{}:{}:{}:{}:{}",
            request.item_id,
            request.destination,
            request.agent,
            request.label,
            request.allow_duplicate
        ));
        Ok(send_outcome())
    }
}

struct FakeFredDetailService {
    calls: Calls,
}

#[async_trait]
impl FredDetailService for FakeFredDetailService {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        self.calls.lock().unwrap().push(format!("fred.detail:{item_id}"));
        Ok(work_detail(item_id, "from-fred-service"))
    }
}

/// Install both fakes, returning the shared call log.
fn install_fakes() -> Calls {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    install_work_service(Arc::new(FakeWorkService { calls: Arc::clone(&calls) }));
    install_fred_detail_service(Arc::new(FakeFredDetailService { calls: Arc::clone(&calls) }));
    calls
}

/// Wait (bounded) until the call log holds at least `n` entries, then return a
/// copy. Used for requests that have no reply frame.
async fn wait_for_calls(calls: &Calls, n: usize) -> Vec<String> {
    for _ in 0..200 {
        {
            let c = calls.lock().unwrap();
            if c.len() >= n {
                return c.clone();
            }
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("expected at least {n} service calls, saw {:?}", calls.lock().unwrap());
}

/// Time for the retained-frame cache task to observe a broadcast.
async fn let_retention_settle() {
    tokio::time::sleep(Duration::from_millis(150)).await;
}

// ── 1-2. TCP peers never receive sensitive broadcasts ─────────────────────────

#[tokio::test]
async fn a_tcp_client_subscribed_to_everything_never_receives_teri_fred_or_work_frames() {
    let h = spawn_server().await;
    let (mut tcp, mut seen) = h.tcp(vec![]).await;

    for msg in all_sensitive_broadcasts() {
        h.broadcast(msg);
    }
    // Control: a non-sensitive broadcast sent AFTER the sensitive ones proves
    // the client is alive and subscribed, and (channel order) that every
    // earlier frame destined for it has already been written.
    h.broadcast(focus_registry_updated());
    seen.extend(
        recv_until(&mut tcp, |m| matches!(m, ServerMsg::FocusRegistryUpdated { .. })).await,
    );

    assert_no_sensitive(&seen);
    assert_exactly_one_withheld(&seen);
}

#[tokio::test]
async fn a_tcp_client_that_names_the_fred_teri_and_work_topics_explicitly_still_receives_nothing_sensitive() {
    let h = spawn_server().await;
    let (mut tcp, mut seen) = h.tcp(vec![Topic::Fred, Topic::Teri, Topic::Work]).await;

    for msg in all_sensitive_broadcasts() {
        h.broadcast(msg);
    }
    // `FocusRegistryUpdated` is topic-filtered out for this subscription, so
    // use an unfiltered broadcast as the ordered control frame.
    h.broadcast(ServerMsg::Pong);
    seen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);

    assert_no_sensitive(&seen);
    assert_exactly_one_withheld(&seen);
}

#[tokio::test]
async fn a_tcp_client_is_told_once_after_subscribing_that_teri_fred_and_work_are_withheld() {
    let h = spawn_server().await;
    let (mut tcp, replay) = h.tcp(vec![]).await;

    assert_exactly_one_withheld(&replay);

    // Later traffic (including a second control round-trip) never repeats it.
    let later = sync(&mut tcp).await;
    assert_eq!(count(&later, |m| matches!(m, ServerMsg::Withheld { .. })), 0);
}

// ── 3. Unix peers receive everything ──────────────────────────────────────────

#[tokio::test]
async fn a_unix_client_subscribed_to_everything_receives_every_teri_fred_and_work_frame_and_no_withheld_notice() {
    let h = spawn_server().await;
    let (mut unix, mut seen) = h.unix(vec![]).await;

    for msg in all_sensitive_broadcasts() {
        h.broadcast(msg);
    }
    h.broadcast(focus_registry_updated());
    seen.extend(
        recv_until(&mut unix, |m| matches!(m, ServerMsg::FocusRegistryUpdated { .. })).await,
    );

    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::Withheld { .. })), 0, "{seen:?}");
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::FredState { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::TeriState { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::TeriPicks { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::WorkDetail { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::WorkSendPreview { .. })), 1);
    assert_eq!(count(&seen, |m| matches!(m, ServerMsg::WorkSendResult { .. })), 1);
}

// ── 4. TCP peers' sensitive requests are refused and change nothing ───────────

fn expect_refused_code(code: &str) {
    assert_eq!(code, "requires_secure_connection");
}

#[tokio::test]
async fn a_tcp_client_s_work_and_fred_requests_are_refused_with_requires_secure_connection_and_reach_no_service() {
    let _guard = RegistryGuard::acquire().await;
    let calls = install_fakes();
    let h = spawn_server().await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    // WorkSend -> WorkSendResult refusal
    send(
        &mut tcp,
        &ClientMsg::WorkSend {
            request_id: "r-send".into(),
            item_id: "jira:X".into(),
            destination: "focus".into(),
            agent: "cody".into(),
            working_directory: None,
            label: "x".into(),
            context: "ctx".into(),
            allow_duplicate: false,
        },
    )
    .await;
    match recv(&mut tcp).await {
        ServerMsg::WorkSendResult { request_id, result: WorkResult::Err(e) } => {
            assert_eq!(request_id, "r-send");
            expect_refused_code(&e.code);
        }
        other => panic!("expected refused WorkSendResult, got {other:?}"),
    }

    // WorkDetailRequest -> WorkDetail refusal (both a work id and a Fred id)
    for (rid, item) in [("r-detail", "jira:X"), ("r-detail-mail", "mail:abc")] {
        send(
            &mut tcp,
            &ClientMsg::WorkDetailRequest { request_id: rid.into(), item_id: item.into() },
        )
        .await;
        match recv(&mut tcp).await {
            ServerMsg::WorkDetail { request_id, result: WorkResult::Err(e) } => {
                assert_eq!(request_id, rid);
                expect_refused_code(&e.code);
            }
            other => panic!("expected refused WorkDetail for {item}, got {other:?}"),
        }
    }

    // WorkSendPreviewRequest -> WorkSendPreview refusal
    send(
        &mut tcp,
        &ClientMsg::WorkSendPreviewRequest { request_id: "r-prev".into(), item_id: "jira:X".into() },
    )
    .await;
    match recv(&mut tcp).await {
        ServerMsg::WorkSendPreview { request_id, result: WorkResult::Err(e) } => {
            assert_eq!(request_id, "r-prev");
            expect_refused_code(&e.code);
        }
        other => panic!("expected refused WorkSendPreview, got {other:?}"),
    }

    // FredSeed -> WorkSendResult refusal; specifically NOT the "no fred
    // session" answer, which would mean the request was actually processed.
    send(&mut tcp, &ClientMsg::FredSeed { request_id: "r-seed".into(), text: "hello fred".into() })
        .await;
    match recv(&mut tcp).await {
        ServerMsg::WorkSendResult { request_id, result: WorkResult::Err(e) } => {
            assert_eq!(request_id, "r-seed");
            assert_ne!(e.code, "fred_not_running", "FredSeed was processed instead of refused");
            expect_refused_code(&e.code);
        }
        other => panic!("expected refused WorkSendResult for FredSeed, got {other:?}"),
    }

    // PicksRefresh / WorkRefresh have no result frame: plain Error.
    send(&mut tcp, &ClientMsg::PicksRefresh { reason: "manual".into() }).await;
    match recv(&mut tcp).await {
        ServerMsg::Error { message } => {
            assert!(message.starts_with("requires_secure_connection"), "{message}")
        }
        other => panic!("expected Error for PicksRefresh, got {other:?}"),
    }
    send(&mut tcp, &ClientMsg::WorkRefresh { source: None, fred: true }).await;
    match recv(&mut tcp).await {
        ServerMsg::Error { message } => {
            assert!(message.starts_with("requires_secure_connection"), "{message}")
        }
        other => panic!("expected Error for WorkRefresh, got {other:?}"),
    }

    // The refusals did not close the connection...
    sync(&mut tcp).await;
    // ...and nothing was delegated (give any wrongly-spawned task time to run).
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(calls.lock().unwrap().is_empty(), "services were called: {:?}", calls.lock().unwrap());
}

// ── 5. Unix peers' requests reach the services ────────────────────────────────

#[tokio::test]
async fn a_unix_client_s_work_requests_reach_the_work_service_and_get_its_answers_back() {
    let _guard = RegistryGuard::acquire().await;
    let calls = install_fakes();
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;

    // WorkSend
    send(
        &mut unix,
        &ClientMsg::WorkSend {
            request_id: "r-send".into(),
            item_id: "jira:X".into(),
            destination: "focus".into(),
            agent: "cody".into(),
            working_directory: Some("/tmp/repo".into()),
            label: "lbl".into(),
            context: "ctx".into(),
            allow_duplicate: true,
        },
    )
    .await;
    match recv(&mut unix).await {
        ServerMsg::WorkSendResult { request_id, result } => {
            assert_eq!(request_id, "r-send");
            assert_eq!(result, WorkResult::Ok(send_outcome()));
        }
        other => panic!("expected WorkSendResult, got {other:?}"),
    }

    // WorkSendPreviewRequest
    send(
        &mut unix,
        &ClientMsg::WorkSendPreviewRequest { request_id: "r-prev".into(), item_id: "jira:X".into() },
    )
    .await;
    match recv(&mut unix).await {
        ServerMsg::WorkSendPreview { request_id, result } => {
            assert_eq!(request_id, "r-prev");
            assert_eq!(result, WorkResult::Ok(send_preview("jira:X")));
        }
        other => panic!("expected WorkSendPreview, got {other:?}"),
    }

    // WorkRefresh / PicksRefresh have no reply frame; observe the service.
    send(&mut unix, &ClientMsg::WorkRefresh { source: Some(WorkSource::Jira), fred: true }).await;
    send(&mut unix, &ClientMsg::PicksRefresh { reason: "manual".into() }).await;

    let seen = wait_for_calls(&calls, 4).await;
    assert!(seen.contains(&"work.send:jira:X:focus:cody:lbl:true".to_string()), "{seen:?}");
    assert!(seen.contains(&"work.send_preview:jira:X".to_string()), "{seen:?}");
    assert!(seen.contains(&"work.refresh:Some(Jira):true".to_string()), "{seen:?}");
    assert!(seen.contains(&"work.refresh_picks:manual".to_string()), "{seen:?}");
}

#[tokio::test]
async fn a_unix_client_s_detail_request_for_a_jira_item_is_answered_by_the_work_service() {
    let _guard = RegistryGuard::acquire().await;
    let calls = install_fakes();
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;

    send(
        &mut unix,
        &ClientMsg::WorkDetailRequest { request_id: "r-1".into(), item_id: "jira:X".into() },
    )
    .await;
    match recv(&mut unix).await {
        ServerMsg::WorkDetail { request_id, result } => {
            assert_eq!(request_id, "r-1");
            assert_eq!(result, WorkResult::Ok(work_detail("jira:X", "from-work-service")));
        }
        other => panic!("expected WorkDetail, got {other:?}"),
    }
    assert_eq!(*calls.lock().unwrap(), vec!["work.detail:jira:X".to_string()]);
}

#[tokio::test]
async fn a_unix_client_s_detail_requests_for_mail_and_event_items_go_to_the_fred_detail_service_not_the_work_service() {
    let _guard = RegistryGuard::acquire().await;
    let calls = install_fakes();
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;

    for (rid, item) in [("r-mail", "mail:abc"), ("r-event", "event:abc")] {
        send(
            &mut unix,
            &ClientMsg::WorkDetailRequest { request_id: rid.into(), item_id: item.into() },
        )
        .await;
        match recv(&mut unix).await {
            ServerMsg::WorkDetail { request_id, result } => {
                assert_eq!(request_id, rid);
                assert_eq!(result, WorkResult::Ok(work_detail(item, "from-fred-service")));
            }
            other => panic!("expected WorkDetail for {item}, got {other:?}"),
        }
    }

    assert_eq!(
        *calls.lock().unwrap(),
        vec!["fred.detail:mail:abc".to_string(), "fred.detail:event:abc".to_string()],
        "mail:/event: ids must be served by the Fred detail service only"
    );
}

// ── 6. FredSeed with no Fred session ──────────────────────────────────────────

#[tokio::test]
async fn a_unix_client_seeding_fred_when_no_fred_session_is_live_is_told_fred_not_running() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;

    send(&mut unix, &ClientMsg::FredSeed { request_id: "r-seed".into(), text: "hi".into() }).await;
    match recv(&mut unix).await {
        ServerMsg::WorkSendResult { request_id, result: WorkResult::Err(e) } => {
            assert_eq!(request_id, "r-seed");
            assert_eq!(e.code, "fred_not_running");
        }
        other => panic!("expected WorkSendResult Err(fred_not_running), got {other:?}"),
    }
}

// ── 7. Retained replay ────────────────────────────────────────────────────────

/// Broadcast one of each retained kind (distinguishable payloads), then let the
/// retention task observe them.
async fn broadcast_retained_set(h: &Harness) {
    h.broadcast(fred_state(7));
    h.broadcast(teri_state());
    h.broadcast(source_status(WorkSource::Jira));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:a.md"]));
    h.broadcast(teri_picks());
    let_retention_settle().await;
}

fn fred_unread_counts(frames: &[ServerMsg]) -> Vec<usize> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::FredState { mailbox, .. } => Some(mailbox.unread_count),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_unix_client_subscribing_to_fred_after_the_fact_is_replayed_the_latest_fred_state_only() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    // No new broadcast is sent from here on: whatever arrives is a replay.
    let (_unix, replay) = h.unix(vec![Topic::Fred]).await;

    assert_eq!(fred_unread_counts(&replay), vec![7], "{replay:?}");
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriState { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriPicks { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::Withheld { .. })), 0);
}

#[tokio::test]
async fn a_unix_client_subscribing_to_teri_after_the_fact_is_replayed_the_teri_state_only() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    let (_unix, replay) = h.unix(vec![Topic::Teri]).await;

    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriState { .. })), 1, "{replay:?}");
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::FredState { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriPicks { .. })), 0);
}

#[tokio::test]
async fn a_unix_client_subscribing_to_work_after_the_fact_is_replayed_status_snapshots_and_picks() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    let (_unix, replay) = h.unix(vec![Topic::Work]).await;

    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 1, "{replay:?}");
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriPicks { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::FredState { .. })), 0);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriState { .. })), 0);
}

#[tokio::test]
async fn a_unix_client_subscribing_to_everything_after_the_fact_is_replayed_every_retained_frame() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    let (_unix, replay) = h.unix(vec![]).await;

    assert_eq!(fred_unread_counts(&replay), vec![7], "{replay:?}");
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriState { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::TeriPicks { .. })), 1);
    assert_eq!(count(&replay, |m| matches!(m, ServerMsg::Withheld { .. })), 0);
}

#[tokio::test]
async fn a_tcp_client_subscribing_after_the_fact_is_replayed_none_of_the_retained_frames() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    for topics in [vec![], vec![Topic::Fred, Topic::Teri, Topic::Work]] {
        let (mut tcp, replay) = h.tcp(topics).await;

        assert_no_sensitive(&replay);
        assert_exactly_one_withheld(&replay);

        // And nothing sensitive trickles in afterwards either: the Pong that
        // `sync` waits for is produced after all attach-time writes.
        let later = sync(&mut tcp).await;
        assert!(later.is_empty(), "unexpected frames after replay: {later:?}");
    }
}

#[tokio::test]
async fn only_the_latest_fred_state_is_replayed_to_a_late_subscriber_and_only_once() {
    let h = spawn_server().await;
    h.broadcast(fred_state(3));
    h.broadcast(fred_state(9));
    let_retention_settle().await;

    let (_unix, replay) = h.unix(vec![Topic::Fred]).await;

    assert_eq!(fred_unread_counts(&replay), vec![9], "{replay:?}");
}

#[tokio::test]
async fn work_snapshots_for_different_groups_are_retained_separately_and_each_keeps_only_its_latest() {
    let h = spawn_server().await;
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:old.md"]));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-b"), &["doc:repo-b:b.md"]));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:new.md"]));
    let_retention_settle().await;

    let (_unix, replay) = h.unix(vec![Topic::Work]).await;

    let mut groups: Vec<(String, Vec<String>)> = replay
        .iter()
        .filter_map(|m| match m {
            ServerMsg::WorkSnapshot { group, items, .. } => Some((
                group.clone().unwrap_or_default(),
                items.iter().map(|i| i.id.clone()).collect(),
            )),
            _ => None,
        })
        .collect();
    groups.sort();

    assert_eq!(
        groups,
        vec![
            ("repo-a".to_string(), vec!["doc:repo-a:new.md".to_string()]),
            ("repo-b".to_string(), vec!["doc:repo-b:b.md".to_string()]),
        ],
        "{replay:?}"
    );
}

#[tokio::test]
async fn work_source_statuses_for_different_sources_are_retained_separately() {
    let h = spawn_server().await;
    h.broadcast(source_status(WorkSource::Jira));
    h.broadcast(source_status(WorkSource::Sentry));
    h.broadcast(source_status(WorkSource::Jira));
    let_retention_settle().await;

    let (_unix, replay) = h.unix(vec![Topic::Work]).await;

    let mut sources: Vec<String> = replay
        .iter()
        .filter_map(|m| match m {
            ServerMsg::WorkSourceStatus { status } => Some(status.source.as_str().to_string()),
            _ => None,
        })
        .collect();
    sources.sort();
    assert_eq!(sources, vec!["jira".to_string(), "sentry".to_string()], "{replay:?}");
}
