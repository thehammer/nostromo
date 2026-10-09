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

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
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
    pane_registry::{PaneContentProvider, PaneRegistry},
    protocol::{
        ClientMsg, DecisionResolution, FocusMeta, NotificationLevel, PaneContentWire, PaneTree,
        ServerMsg, SessionAction, Topic, PROTOCOL_VERSION,
    },
    server::Server,
    session_manager::CLAUDE_BIN_ENV,
    stream_json::{SessionState, Turn, TurnDelta},
    PtyManager, SessionManager,
};
use nostromo::mcp::tools::create_focus::create_focus;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};

// ── server harness ────────────────────────────────────────────────────────────

struct Harness {
    server: Server,
    socket_path: std::path::PathBuf,
    tcp_port: u16,
    session_mgr: Arc<Mutex<SessionManager>>,
    decisions: Arc<Mutex<DecisionRegistry>>,
    _tmp: TempDir,
}

/// `Server::bind` on a temp Unix socket plus `bind_tcp` on an ephemeral port.
async fn spawn_server() -> Harness {
    install_fake_claude();
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    // A private id store: sessions spawned by these tests must never touch the
    // operator's `~/.nostromo/daemon-sessions.json`.
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
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
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    );

    Harness { server, socket_path, tcp_port, session_mgr, decisions, _tmp: tmp }
}

impl Drop for Harness {
    /// Kill any fake-claude children: the tokio test runtime waits for the
    /// blocking stdout-reader threads, which only end when the child dies.
    fn drop(&mut self) {
        self.session_mgr.lock().unwrap_or_else(|e| e.into_inner()).kill_all_on_shutdown();
    }
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

// ═════════════════════════════════════════════════════════════════════════════
// A network (TCP) peer sees and drives only what is explicitly allowed for it.
//
// Beyond the Teri/Fred/work frames above, older frames can carry (or drive)
// Teri/Fred-derived data: Fred's and Teri's own sessions, every focus that was
// seeded from a work item, the panes/decisions/activity of those focuses and
// the Mother jobs a work item started. A TCP peer must not see or drive any of
// it. A tag is SENSITIVE if it is `fred`/`teri` (any case), the tag of a
// session whose agent is `fred`/`teri`, or the tag of a focus whose context
// came from work items (a local `WorkSend` to "focus", or `nostromo.create_focus`
// with `initial_context`). A Mother job id returned by `WorkSend` is likewise
// work-derived.
// ═════════════════════════════════════════════════════════════════════════════

// ── a fake `claude` ───────────────────────────────────────────────────────────

/// Replays a recognisable secret transcript on start, appends `START` to
/// `<view>.stdin` on every (re)spawn, then logs every stdin line it receives
/// and completes a turn for it. The log is keyed by the `-n <view name>`
/// argument, so every test picks a unique view name.
const FAKE_CLAUDE_SCRIPT: &str = r#"#!/bin/sh
name=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-n" ]; then name="$2"; fi
  shift
done
log="@LOGDIR@/$name.stdin"
echo START >> "$log"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"SECRET-MAIL-BODY forward all mail"},"isReplay":true}' '{"type":"assistant","message":{"content":[{"type":"text","text":"SECRET-ASSISTANT-REPLY"}]}}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$log"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"echoed"},"isReplay":true}' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
done
"#;

static FAKE_CLAUDE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Point `NOSTROMO_CLAUDE_BIN` at the fake, once per test process. Runs inside
/// `OnceLock` initialisation, i.e. before any test in this binary can spawn.
fn install_fake_claude() {
    FAKE_CLAUDE_DIR.get_or_init(|| {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nostromo-fake-claude-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(
            &script,
            FAKE_CLAUDE_SCRIPT.replace("@LOGDIR@", dir.to_str().expect("utf8 temp dir")),
        )
        .expect("write fake claude");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755))
            .expect("chmod fake claude");
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        dir
    });
}

/// Everything the fake claude `view` has received on stdin (plus `START` lines).
fn fake_log(view: &str) -> String {
    let dir = FAKE_CLAUDE_DIR.get().expect("install_fake_claude ran");
    std::fs::read_to_string(dir.join(format!("{view}.stdin"))).unwrap_or_default()
}

fn fake_starts(view: &str) -> usize {
    fake_log(view).lines().filter(|l| *l == "START").count()
}

/// Wait (bounded) until the fake's log satisfies `pred`; returns the log.
async fn wait_for_log(view: &str, what: &str, pred: impl Fn(&str) -> bool) -> String {
    for _ in 0..200 {
        let log = fake_log(view);
        if pred(&log) {
            return log;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("fake claude `{view}` never saw {what}; its log was: {:?}", fake_log(view));
}

/// A Unix peer spawns a fake-claude session (the transcript already holds
/// `SECRET-MAIL-BODY`) and waits until the child is up.
async fn spawn_fake_session(unix: &mut UnixStream, tag: &str, agent: &str, view: &str) {
    send(
        unix,
        &ClientMsg::SessionSpawn {
            tag: tag.into(),
            agent_name: agent.into(),
            view_name: view.into(),
            cwd: None,
            session_id: Some(format!("sid-{view}")),
            remote_control: false,
        },
    )
    .await;
    let frames =
        recv_until(unix, |m| matches!(m, ServerMsg::SessionSpawned { .. } | ServerMsg::Error { .. }))
            .await;
    assert!(
        matches!(frames.last(), Some(ServerMsg::SessionSpawned { .. })),
        "a Unix peer must be able to spawn `{tag}`: {frames:?}"
    );
    wait_for_log(view, "START", |l| l.contains("START")).await;
}

fn json_of(frames: &[ServerMsg]) -> String {
    frames.iter().map(|m| serde_json::to_string(m).unwrap()).collect::<Vec<_>>().join("\n")
}

/// Read frames until one's JSON contains `needle`; returns the frames read.
async fn recv_until_json_contains<S: AsyncRead + Unpin>(stream: &mut S, needle: &str) -> Vec<ServerMsg> {
    recv_until(stream, |m| serde_json::to_string(m).unwrap().contains(needle)).await
}

/// Send one request and read everything the daemon answers before the `Pong`
/// that follows it (targeted replies are ordered ahead of the `Pong`).
async fn attack<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S, msg: ClientMsg) -> Vec<ServerMsg> {
    send(stream, &msg).await;
    sync(stream).await
}

fn assert_refused(frames: &[ServerMsg], what: &str) {
    let refused = frames.iter().any(
        |m| matches!(m, ServerMsg::Error { message } if message.contains("requires_secure_connection")),
    );
    assert!(
        refused,
        "{what}: expected an `error` frame containing `requires_secure_connection`, got {frames:?}"
    );
}

fn is_transcript_frame(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::SessionTurns { .. }
            | ServerMsg::SessionTurnDelta { .. }
            | ServerMsg::SessionState { .. }
            | ServerMsg::SessionSummaryUpdate { .. }
            | ServerMsg::SessionPermissionRequest { .. }
    )
}

fn assert_no_transcript(frames: &[ServerMsg]) {
    let leaked: Vec<&ServerMsg> = frames.iter().filter(|m| is_transcript_frame(m)).collect();
    assert!(leaked.is_empty(), "session transcript frames reached the network peer: {leaked:?}");
    assert!(
        !json_of(frames).contains("SECRET-MAIL-BODY"),
        "the secret transcript reached the network peer"
    );
}

/// A Unix peer, already attached to `tag` (whose fake child is `view`), sends a
/// uniquely-marked message and waits until the turn it caused has completed.
async fn unix_completes_a_turn(unix: &mut UnixStream, tag: &str, view: &str, marker: &str) -> Vec<ServerMsg> {
    send(unix, &ClientMsg::SessionSend { tag: tag.into(), text: marker.into(), images: vec![] }).await;
    wait_for_log(view, marker, |l| l.contains(marker)).await;
    recv_until_json_contains(unix, "echoed").await
}

// ── work-derived focuses and jobs ─────────────────────────────────────────────

/// Tag of a focus created from a work item (the Jira title is in the tag).
const W: &str = "cody-secret-jira-title";

/// A `WorkService` whose `send` returns a fixed outcome, optionally after
/// really spawning the focus's fake-claude session the way the real service
/// would.
struct ScriptedWorkService {
    outcome: SendOutcome,
    spawn: Option<(Arc<Mutex<SessionManager>>, String, String, String)>, // mgr, tag, agent, view
}

#[async_trait]
impl WorkService for ScriptedWorkService {
    async fn detail(&self, item_id: &str) -> Result<WorkDetail, WorkError> {
        Ok(work_detail(item_id, "scripted"))
    }
    async fn refresh(&self, _source: Option<WorkSource>, _fred: bool) -> Result<(), WorkError> {
        Ok(())
    }
    async fn refresh_picks(&self, _reason: &str) -> Result<(), WorkError> {
        Ok(())
    }
    async fn send_preview(&self, item_id: &str) -> Result<SendPreview, WorkError> {
        Ok(send_preview(item_id))
    }
    async fn send(&self, request: SendRequest) -> Result<SendOutcome, WorkError> {
        if let Some((mgr, tag, agent, view)) = &self.spawn {
            let mut mgr = mgr.lock().unwrap();
            mgr.spawn_session(tag.clone(), agent.clone(), view.clone(), None, Some(format!("sid-{view}")), false)
                .map_err(|e| WorkError::new("spawn_failed", e.to_string()))?;
            mgr.send_user_message(tag, &request.context, &[])
                .map_err(|e| WorkError::new("seed_failed", e.to_string()))?;
        }
        Ok(self.outcome.clone())
    }
}

/// A Unix peer sends a work item to a focus/job through `service` and waits for
/// the (successful) result, i.e. until the daemon has finished the send.
async fn work_send_via(unix: &mut UnixStream, service: ScriptedWorkService, destination: &str) {
    install_work_service(Arc::new(service));
    send(
        unix,
        &ClientMsg::WorkSend {
            request_id: "r-derive".into(),
            item_id: "jira:SECRET-1".into(),
            destination: destination.into(),
            agent: "cody".into(),
            working_directory: None,
            label: "SECRET-JIRA-TITLE".into(),
            context: "WORK-CONTEXT: summarise the confidential ticket".into(),
            allow_duplicate: false,
        },
    )
    .await;
    let frames = recv_until(unix, |m| matches!(m, ServerMsg::WorkSendResult { .. })).await;
    match frames.last() {
        Some(ServerMsg::WorkSendResult { result: WorkResult::Ok(_), .. }) => {}
        other => panic!("the local work send must succeed, got {other:?}"),
    }
}

/// Make `tag` a work-derived focus (no real session behind it).
async fn derive_focus(unix: &mut UnixStream, tag: &str) {
    let outcome = SendOutcome { kind: "created".into(), focus_tag: Some(tag.into()), job_id: None };
    work_send_via(unix, ScriptedWorkService { outcome, spawn: None }, "focus").await;
}

fn mcp_state(h: &Harness) -> McpSharedState {
    McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
        session_mgr: Arc::clone(&h.session_mgr),
        broadcast_tx: h.server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions: Arc::clone(&h.decisions),
        tickets: Default::default(),
    })
}

// ── H1/H2: a TCP peer cannot read or drive a sensitive session ────────────────

#[tokio::test]
async fn a_tcp_client_cannot_attach_to_the_fred_session_and_never_receives_its_transcript() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    spawn_fake_session(&mut unix, "fred", "fred", "v-attach-fred").await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let mut seen = attack(&mut tcp, ClientMsg::SessionAttach { tag: "fred".into() }).await;
    assert_refused(&seen, "session_attach fred");

    // Control: a Unix peer attaches and does see the transcript (so the test
    // cannot pass because there was nothing to leak), and a later turn streams
    // to it — anything wrongly registered for the TCP peer would stream too.
    send(&mut unix, &ClientMsg::SessionAttach { tag: "fred".into() }).await;
    recv_until_json_contains(&mut unix, "SECRET-MAIL-BODY").await;
    unix_completes_a_turn(&mut unix, "fred", "v-attach-fred", "UNIX-MARKER-1").await;

    seen.extend(sync(&mut tcp).await);
    assert_no_transcript(&seen);
}

#[tokio::test]
async fn the_fred_and_teri_session_tags_are_protected_whatever_their_case() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    spawn_fake_session(&mut unix, "Fred", "cody", "v-case-fred").await;
    spawn_fake_session(&mut unix, "TERI", "cody", "v-case-teri").await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let mut seen = vec![];
    for tag in ["Fred", "TERI"] {
        let frames = attack(&mut tcp, ClientMsg::SessionAttach { tag: tag.into() }).await;
        assert_refused(&frames, &format!("session_attach {tag}"));
        seen.extend(frames);
    }
    assert_no_transcript(&seen);
}

#[tokio::test]
async fn a_tcp_client_cannot_send_interrupt_or_control_a_sensitive_session_and_nothing_changes() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let view = "v-ops-fred";
    spawn_fake_session(&mut unix, "fred", "fred", view).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let attacks = [
        (
            "session_send",
            ClientMsg::SessionSend { tag: "fred".into(), text: "ATTACKER-TEXT".into(), images: vec![] },
        ),
        ("session_interrupt", ClientMsg::SessionInterrupt { tag: "fred".into() }),
        (
            "session_control stop",
            ClientMsg::SessionControl { tag: "fred".into(), action: SessionAction::Stop },
        ),
        (
            "session_control restart",
            ClientMsg::SessionControl { tag: "fred".into(), action: SessionAction::Restart },
        ),
        (
            "session_control new_session",
            ClientMsg::SessionControl { tag: "fred".into(), action: SessionAction::NewSession },
        ),
    ];
    let mut seen = vec![];
    for (what, msg) in attacks {
        let frames = attack(&mut tcp, msg).await;
        assert_refused(&frames, what);
        seen.extend(frames);
    }
    assert_no_transcript(&seen);

    // No side effect: the same child is still alive and still serving a local
    // peer (a stop or restart would have killed it or started a second one),
    // and it never received the attacker's message or an interrupt.
    send(&mut unix, &ClientMsg::SessionSend { tag: "fred".into(), text: "UNIX-MARKER-2".into(), images: vec![] })
        .await;
    let log = wait_for_log(view, "the local peer's message", |l| l.contains("UNIX-MARKER-2")).await;
    assert!(!log.contains("ATTACKER-TEXT"), "the attacker's text reached Fred: {log:?}");
    assert!(!log.contains("interrupt"), "an interrupt reached Fred: {log:?}");
    assert_eq!(fake_starts(view), 1, "Fred's session was restarted: {log:?}");
}

#[tokio::test]
async fn a_tcp_client_s_fred_seed_and_session_send_deliver_nothing_to_a_live_fred_session_while_a_unix_client_s_are_delivered() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let view = "v-seed-fred";
    spawn_fake_session(&mut unix, "fred", "fred", view).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let seed = attack(
        &mut tcp,
        ClientMsg::FredSeed { request_id: "r-seed".into(), text: "ATTACKER-SEED".into() },
    )
    .await;
    assert!(
        seed.iter().any(|m| matches!(
            m,
            ServerMsg::WorkSendResult { request_id, result: WorkResult::Err(e) }
                if request_id == "r-seed" && e.code == "requires_secure_connection"
        )),
        "FredSeed must be refused: {seed:?}"
    );
    let send_frames = attack(
        &mut tcp,
        ClientMsg::SessionSend { tag: "fred".into(), text: "ATTACKER-SEND".into(), images: vec![] },
    )
    .await;
    assert_refused(&send_frames, "session_send fred");

    // Control: a Unix peer's seed and send are both delivered, and the log
    // holds exactly those -- no attacker text, ever.
    let seeded = attack(
        &mut unix,
        ClientMsg::FredSeed { request_id: "r-unix-seed".into(), text: "UNIX-SEED".into() },
    )
    .await;
    assert!(
        seeded.iter().any(|m| matches!(
            m,
            ServerMsg::WorkSendResult { result: WorkResult::Ok(o), .. } if o.kind == "seeded"
        )),
        "a Unix peer's FredSeed must reach the live Fred session: {seeded:?}"
    );
    send(&mut unix, &ClientMsg::SessionSend { tag: "fred".into(), text: "UNIX-SEND".into(), images: vec![] })
        .await;
    let log = wait_for_log(view, "the local peer's seed and send", |l| {
        l.contains("UNIX-SEED") && l.contains("UNIX-SEND")
    })
    .await;
    assert!(!log.contains("ATTACKER"), "attacker text was delivered to Fred: {log:?}");
}

#[tokio::test]
async fn a_tcp_client_cannot_spawn_a_session_under_a_sensitive_tag_or_for_a_fred_or_teri_agent() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let cases = [
        ("tag fred", "fred", "cody", "v-spawn-a"),
        ("tag TERI (case-insensitive)", "TERI", "cody", "v-spawn-b"),
        ("agent fred under a benign tag", "innocuous-a", "fred", "v-spawn-c"),
        ("agent Teri under a benign tag", "innocuous-b", "Teri", "v-spawn-d"),
    ];
    for (what, tag, agent, view) in cases {
        let frames = attack(
            &mut tcp,
            ClientMsg::SessionSpawn {
                tag: tag.into(),
                agent_name: agent.into(),
                view_name: view.into(),
                cwd: None,
                session_id: Some(format!("sid-{view}")),
                remote_control: false,
            },
        )
        .await;
        assert_refused(&frames, &format!("session_spawn with {what}"));
    }

    // No side effect: nothing was started, and no session exists.
    tokio::time::sleep(Duration::from_millis(300)).await;
    for (what, _, _, view) in cases {
        assert_eq!(fake_starts(view), 0, "session_spawn with {what} started a child");
    }
    let listed = attack(&mut unix, ClientMsg::SessionList).await;
    let sessions = listed
        .iter()
        .find_map(|m| match m {
            ServerMsg::SessionListResp { sessions } => Some(sessions.clone()),
            _ => None,
        })
        .expect("session_list_resp");
    assert!(sessions.is_empty(), "sessions were created: {sessions:?}");
}

#[tokio::test]
async fn a_tcp_client_s_session_list_omits_sensitive_sessions_while_a_unix_client_still_sees_them() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    spawn_fake_session(&mut unix, "fred", "fred", "v-list-fred").await;
    spawn_fake_session(&mut unix, "scratch", "teri", "v-list-teri-agent").await;
    spawn_fake_session(&mut unix, "cody-x", "cody", "v-list-cody").await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let tags_of = |frames: &[ServerMsg]| -> BTreeSet<String> {
        frames
            .iter()
            .find_map(|m| match m {
                ServerMsg::SessionListResp { sessions } => {
                    Some(sessions.iter().map(|s| s.tag.clone()).collect())
                }
                _ => None,
            })
            .expect("session_list_resp")
    };

    let unix_tags = tags_of(&attack(&mut unix, ClientMsg::SessionList).await);
    assert_eq!(
        unix_tags,
        ["cody-x", "fred", "scratch"].map(String::from).into_iter().collect::<BTreeSet<_>>(),
        "control: a Unix peer sees every session"
    );
    let tcp_tags = tags_of(&attack(&mut tcp, ClientMsg::SessionList).await);
    assert_eq!(
        tcp_tags,
        ["cody-x"].map(String::from).into_iter().collect::<BTreeSet<_>>(),
        "a TCP peer sees neither the `fred` session nor a session whose agent is `teri`"
    );
}

#[tokio::test]
async fn a_tcp_client_can_still_attach_to_and_converse_with_a_non_sensitive_session() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let view = "v-plain-cody";
    spawn_fake_session(&mut unix, "cody-x", "cody", view).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let frames = attack(&mut tcp, ClientMsg::SessionAttach { tag: "cody-x".into() }).await;
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::SessionTurns { tag, .. } if tag == "cody-x")),
        "an ordinary session's transcript must still reach a TCP peer: {frames:?}"
    );
    assert!(frames.iter().any(|m| matches!(m, ServerMsg::SessionState { tag, .. } if tag == "cody-x")));

    send(&mut tcp, &ClientMsg::SessionSend { tag: "cody-x".into(), text: "TCP-HELLO".into(), images: vec![] })
        .await;
    wait_for_log(view, "the TCP peer's message", |l| l.contains("TCP-HELLO")).await;
    recv_until_json_contains(&mut tcp, "echoed").await;
}

#[tokio::test]
async fn session_transcript_frames_for_a_sensitive_tag_are_never_broadcast_to_a_tcp_client() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    derive_focus(&mut unix, W).await;
    let (mut tcp, mut tseen) = h.tcp(vec![]).await;

    let turn = || Turn {
        id: "t0".into(),
        user_input: "SECRET-MAIL-BODY".into(),
        timestamp: None,
        blocks: vec![],
        is_complete: false,
    };
    for tag in ["fred", "teri", W] {
        h.broadcast(ServerMsg::SessionTurns { tag: tag.into(), turns: vec![turn()] });
        h.broadcast(ServerMsg::SessionTurnDelta {
            tag: tag.into(),
            delta: TurnDelta::TurnStarted { turn: turn() },
        });
        h.broadcast(ServerMsg::SessionState { tag: tag.into(), state: SessionState::MidTurn });
        h.broadcast(ServerMsg::SessionSummaryUpdate { tag: tag.into(), summary: "SECRET-SUMMARY".into() });
        h.broadcast(ServerMsg::SessionPermissionRequest {
            tag: tag.into(),
            request_id: "p1".into(),
            tool: "Bash".into(),
            input: json!({"command": "cat SECRET-MAIL-BODY"}),
        });
    }
    // Control: the same frames for an ordinary tag still flow, so the test
    // cannot pass by dropping every session frame.
    h.broadcast(ServerMsg::SessionState { tag: "cody-x".into(), state: SessionState::Idle });
    h.broadcast(ServerMsg::Pong);
    tseen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);

    assert_no_transcript(
        &tseen
            .iter()
            .filter(|m| !matches!(m, ServerMsg::SessionState { tag, .. } if tag == "cody-x"))
            .cloned()
            .collect::<Vec<_>>(),
    );
    assert!(
        tseen.iter().any(|m| matches!(m, ServerMsg::SessionState { tag, .. } if tag == "cody-x")),
        "control: an ordinary session's state must still reach a TCP peer: {tseen:?}"
    );
}

// ── H1: work-derived focuses are as protected as Fred ────────────────────────

#[tokio::test]
async fn a_tcp_client_cannot_attach_to_or_drive_a_focus_that_was_created_by_sending_a_work_item() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let view = "v-work-focus";
    let outcome = SendOutcome { kind: "created".into(), focus_tag: Some(W.into()), job_id: None };
    let service = ScriptedWorkService {
        outcome,
        spawn: Some((Arc::clone(&h.session_mgr), W.into(), "cody".into(), view.into())),
    };
    work_send_via(&mut unix, service, "focus").await;
    wait_for_log(view, "the seeded work context", |l| l.contains("WORK-CONTEXT")).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let mut seen = vec![];
    for (what, msg) in [
        ("session_attach", ClientMsg::SessionAttach { tag: W.into() }),
        (
            "session_send",
            ClientMsg::SessionSend { tag: W.into(), text: "ATTACKER-TEXT".into(), images: vec![] },
        ),
        ("session_interrupt", ClientMsg::SessionInterrupt { tag: W.into() }),
        (
            "session_control stop",
            ClientMsg::SessionControl { tag: W.into(), action: SessionAction::Stop },
        ),
    ] {
        let frames = attack(&mut tcp, msg).await;
        assert_refused(&frames, &format!("{what} on a work-derived focus"));
        seen.extend(frames);
    }
    assert_no_transcript(&seen);

    // No side effect, and the local peer is unaffected.
    send(&mut unix, &ClientMsg::SessionSend { tag: W.into(), text: "UNIX-MARKER-3".into(), images: vec![] })
        .await;
    let log = wait_for_log(view, "the local peer's message", |l| l.contains("UNIX-MARKER-3")).await;
    assert!(!log.contains("ATTACKER-TEXT"), "{log:?}");
    assert_eq!(fake_starts(view), 1, "{log:?}");
}

#[tokio::test]
async fn a_tcp_client_cannot_attach_to_or_drive_a_focus_created_through_create_focus_with_initial_context() {
    let h = spawn_server().await;
    let state = mcp_state(&h);
    let view = "SECRET-JIRA-TITLE-A";

    let created = create_focus(
        &state,
        &json!({"agent": "cody", "title": view, "initial_context": "SEED-CONTEXT-A"}),
        None,
    )
    .await;
    let tag = created["focus_id"].as_str().expect("focus_id").to_string();
    wait_for_log(view, "the seeded context", |l| l.contains("SEED-CONTEXT-A")).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let mut seen = vec![];
    for (what, msg) in [
        ("session_attach", ClientMsg::SessionAttach { tag: tag.clone() }),
        (
            "session_send",
            ClientMsg::SessionSend { tag: tag.clone(), text: "ATTACKER-TEXT".into(), images: vec![] },
        ),
        ("session_interrupt", ClientMsg::SessionInterrupt { tag: tag.clone() }),
        (
            "session_control restart",
            ClientMsg::SessionControl { tag: tag.clone(), action: SessionAction::Restart },
        ),
    ] {
        let frames = attack(&mut tcp, msg).await;
        assert_refused(&frames, &format!("{what} on a create_focus-with-context focus"));
        seen.extend(frames);
    }
    assert_no_transcript(&seen);
    let log = fake_log(view);
    assert!(!log.contains("ATTACKER-TEXT"), "{log:?}");
    assert_eq!(fake_starts(view), 1, "the focus's session was restarted: {log:?}");
}

#[tokio::test]
async fn a_focus_created_through_create_focus_without_initial_context_is_an_ordinary_focus_a_tcp_client_may_attach_to() {
    let h = spawn_server().await;
    let state = mcp_state(&h);
    let view = "BENIGN-TITLE-A";

    let created =
        create_focus(&state, &json!({"agent": "cody", "title": view}), None).await;
    let tag = created["focus_id"].as_str().expect("focus_id").to_string();
    wait_for_log(view, "START", |l| l.contains("START")).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let frames = attack(&mut tcp, ClientMsg::SessionAttach { tag: tag.clone() }).await;
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::SessionTurns { tag: t, .. } if *t == tag)),
        "an ordinary created focus must stay attachable over TCP: {frames:?}"
    );
}

// ── H3: panes, layout, notifications, decisions, activity ────────────────────

fn activity_event(summary: &str, focus_tag: Option<&str>) -> nostromo::agent_bus::ActivityEvent {
    serde_json::from_value(json!({
        "ts": "2026-10-09T12:00:00Z",
        "agent": "cody",
        "kind": "tool_use",
        "summary": summary,
        "focus_tag": focus_tag,
    }))
    .expect("activity event")
}

fn pane_content(tag: &str) -> ServerMsg {
    ServerMsg::PaneContent {
        tag: tag.into(),
        pane_id: "p1".into(),
        content: PaneContentWire::Text { text: format!("pane-body-of-{tag}") },
        freshness: None,
        address: None,
    }
}

/// One frame of every focus-scoped kind H3 covers, for `tag`.
fn focus_scoped_frames(tag: &str) -> Vec<ServerMsg> {
    vec![
        pane_content(tag),
        ServerMsg::FocusLayout { tag: tag.into(), tree: PaneTree::repl_leaf(), focused_pane: None },
        ServerMsg::Notification { tag: tag.into(), level: NotificationLevel::Info, message: format!("note-for-{tag}") },
        ServerMsg::DecisionRequest {
            tag: tag.into(),
            request_id: format!("req-{tag}"),
            prompt: format!("prompt-for-{tag}"),
            detail: None,
            choices: vec![],
            context_pane_id: None,
        },
        ServerMsg::DecisionResolved {
            tag: tag.into(),
            request_id: format!("req-{tag}"),
            resolution: DecisionResolution::Answered,
            choice_id: None,
        },
        ServerMsg::Activity(activity_event(&format!("ACT-SUMMARY-{tag}"), Some(tag))),
        ServerMsg::ActivitySnapshot { tag: tag.into(), streams: vec![] },
    ]
}

const SCOPED_KINDS: [&str; 7] = [
    "pane_content",
    "focus_layout",
    "notification",
    "decision_request",
    "decision_resolved",
    "activity",
    "activity_snapshot",
];

/// `(kind, tag)` of every focus-scoped frame among `frames`.
fn scoped(frames: &[ServerMsg]) -> BTreeSet<(&'static str, Option<String>)> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::PaneContent { tag, .. } => Some(("pane_content", Some(tag.clone()))),
            ServerMsg::FocusLayout { tag, .. } => Some(("focus_layout", Some(tag.clone()))),
            ServerMsg::Notification { tag, .. } => Some(("notification", Some(tag.clone()))),
            ServerMsg::DecisionRequest { tag, .. } => Some(("decision_request", Some(tag.clone()))),
            ServerMsg::DecisionResolved { tag, .. } => Some(("decision_resolved", Some(tag.clone()))),
            ServerMsg::Activity(e) => Some(("activity", e.focus_tag.clone())),
            ServerMsg::ActivitySnapshot { tag, .. } => Some(("activity_snapshot", Some(tag.clone()))),
            _ => None,
        })
        .collect()
}

fn expected_scoped(kinds: &[&'static str], tags: &[&str]) -> BTreeSet<(&'static str, Option<String>)> {
    kinds.iter().flat_map(|k| tags.iter().map(move |t| (*k, Some(t.to_string())))).collect()
}

fn health_probe() -> ServerMsg {
    ServerMsg::ActivityHealth {
        ingesting: true,
        reason: Some("health-probe".into()),
        last_event_at: None,
        hook_installed: true,
    }
}

#[tokio::test]
async fn a_tcp_client_never_receives_pane_layout_notification_decision_or_activity_broadcasts_for_a_sensitive_focus() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, mut useen) = h.unix(vec![]).await;
    derive_focus(&mut unix, W).await;
    let (mut tcp, mut tseen) = h.tcp(vec![]).await;

    for tag in ["fred", "teri", W, "cody-x"] {
        for msg in focus_scoped_frames(tag) {
            h.broadcast(msg);
        }
    }
    // Unattributed activity (no focus) may come from anywhere, including a
    // Fred session: withheld from network peers. Health is not data.
    h.broadcast(ServerMsg::Activity(activity_event("ACT-SUMMARY-unattributed", None)));
    h.broadcast(health_probe());
    h.broadcast(ServerMsg::Pong);
    tseen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);
    useen.extend(recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await);

    // Control: a Unix peer receives every one of them.
    let mut everything = expected_scoped(&SCOPED_KINDS, &["fred", "teri", W, "cody-x"]);
    everything.insert(("activity", None));
    assert_eq!(scoped(&useen), everything, "control: a Unix peer must see every focus");

    // A TCP peer receives the ordinary focus's frames and nothing else.
    assert_eq!(
        scoped(&tseen),
        expected_scoped(&SCOPED_KINDS, &["cody-x"]),
        "a TCP peer must receive only the non-sensitive focus's frames (and no unattributed activity)"
    );
    assert!(
        tseen.iter().any(|m| matches!(m, ServerMsg::ActivityHealth { reason: Some(r), .. } if r == "health-probe")),
        "activity_health is not data about a focus and must still flow: {tseen:?}"
    );
}

/// Pane registry + pane content provider seeded for `tags`, the way the daemon
/// does it.
struct FixedPanes(Vec<ServerMsg>);

impl PaneContentProvider for FixedPanes {
    fn bound_pane_contents(&self) -> Vec<ServerMsg> {
        self.0.clone()
    }
}

fn seed_panes(h: &Harness, tags: &[&str]) {
    let registry = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    for tag in tags {
        registry.lock().unwrap().get_or_init(tag);
    }
    let mut mgr = h.session_mgr.lock().unwrap();
    mgr.configure_mcp_bridge(registry, "/tmp/ft-unused.sock".into(), "/tmp/ft-unused.json".into());
    mgr.configure_pane_content_provider(Arc::new(FixedPanes(tags.iter().map(|t| pane_content(t)).collect())));
}

#[tokio::test]
async fn a_tcp_client_connecting_is_not_replayed_the_layout_or_pane_content_of_a_sensitive_focus() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![Topic::Focuses]).await;
    derive_focus(&mut unix, W).await;
    seed_panes(&h, &["fred", "teri", W, "cody-x"]);

    let (_unix2, unix_replay) = h.unix(vec![Topic::Layout]).await;
    assert_eq!(
        scoped(&unix_replay),
        expected_scoped(&["focus_layout", "pane_content"], &["fred", "teri", W, "cody-x"]),
        "control: a Unix peer is replayed every focus's layout and pane content"
    );

    for topics in [vec![Topic::Layout], vec![]] {
        let (_tcp, tcp_replay) = h.tcp(topics.clone()).await;
        let layout_and_content: BTreeSet<_> = scoped(&tcp_replay)
            .into_iter()
            .filter(|(k, _)| *k == "focus_layout" || *k == "pane_content")
            .collect();
        assert_eq!(
            layout_and_content,
            expected_scoped(&["focus_layout", "pane_content"], &["cody-x"]),
            "a TCP peer (topics {topics:?}) must be replayed only the ordinary focus's layout and pane content"
        );
        assert!(
            !json_of(&tcp_replay).contains("pane-body-of-fred"),
            "pane content of Fred reached a TCP peer on replay"
        );
    }
}

/// Seed the daemon's focus registry and activity store for `tags`.
fn seed_activity(h: &Harness, tags: &[&str]) {
    let mut mgr = h.session_mgr.lock().unwrap();
    mgr.set_focus_registry(tags.iter().map(|t| meta(t, t, "cody", false)).collect());
    for tag in tags {
        mgr.ingest_activity_event(activity_event(&format!("ACT-SUMMARY-{tag}"), Some(tag)));
    }
}

#[tokio::test]
async fn a_tcp_client_connecting_is_not_replayed_activity_snapshots_of_a_sensitive_focus() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![Topic::Focuses]).await;
    derive_focus(&mut unix, W).await;
    seed_activity(&h, &["fred", "teri", W, "cody-x"]);

    let (_unix2, unix_replay) = h.unix(vec![Topic::Activity]).await;
    assert_eq!(
        scoped(&unix_replay),
        expected_scoped(&["activity_snapshot"], &["fred", "teri", W, "cody-x"]),
        "control: a Unix peer is replayed every focus's activity snapshot"
    );

    // (A client that names no topics is today not replayed activity at all;
    // what it must never be replayed is a sensitive focus's snapshot.)
    for topics in [vec![Topic::Activity], vec![]] {
        let (_tcp, tcp_replay) = h.tcp(topics.clone()).await;
        let snapshots: BTreeSet<_> =
            scoped(&tcp_replay).into_iter().filter(|(k, _)| *k == "activity_snapshot").collect();
        let ordinary_only = expected_scoped(&["activity_snapshot"], &["cody-x"]);
        if topics.is_empty() {
            assert!(
                snapshots.is_subset(&ordinary_only),
                "a TCP peer (topics []) was replayed a sensitive focus's activity: {snapshots:?}"
            );
        } else {
            assert_eq!(
                snapshots, ordinary_only,
                "a TCP peer (topics {topics:?}) must be replayed only the ordinary focus's activity"
            );
            assert!(
                tcp_replay.iter().any(|m| matches!(m, ServerMsg::ActivityHealth { .. })),
                "activity_health must still be replayed: {tcp_replay:?}"
            );
        }
        assert!(
            !json_of(&tcp_replay).contains("ACT-SUMMARY-fred"),
            "Fred's activity reached a TCP peer on replay"
        );
    }
}

#[tokio::test]
async fn a_tcp_client_asking_for_the_activity_snapshot_of_a_sensitive_focus_is_not_given_it() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![Topic::Focuses]).await;
    derive_focus(&mut unix, W).await;
    seed_activity(&h, &["fred", W, "cody-x"]);
    let (mut tcp, _) = h.tcp(vec![]).await;

    let mut frames = vec![];
    for tag in ["fred", W, "cody-x"] {
        frames.extend(attack(&mut tcp, ClientMsg::ActivitySnapshotRequest { tag: tag.into() }).await);
    }
    assert_eq!(
        scoped(&frames),
        expected_scoped(&["activity_snapshot"], &["cody-x"]),
        "only the ordinary focus's snapshot may be answered: {frames:?}"
    );
}

// ── H3: Mother jobs a work item started ──────────────────────────────────────

fn mother_job(id: &str) -> nostromo::mother::MotherJob {
    serde_json::from_value(json!({"id": id, "state": "running", "title": format!("title of {id}")}))
        .expect("mother job")
}

fn mother_frames(job_ids: &[&str]) -> Vec<ServerMsg> {
    let mut frames = vec![ServerMsg::MotherJobs { jobs: job_ids.iter().map(|i| mother_job(i)).collect() }];
    for id in job_ids {
        frames.push(ServerMsg::MotherPeek {
            job_id: (*id).into(),
            todos: vec![],
            tool_trail: vec![],
            last_text: format!("peek of {id}"),
        });
        frames.push(ServerMsg::MotherAwaitDetected(Box::new(mother_job(id))));
    }
    frames
}

/// `(listed job ids, peeked job ids, await-detected job ids)` among `frames`.
fn mother_ids(frames: &[ServerMsg]) -> (Vec<String>, Vec<String>, Vec<String>) {
    let mut listed = vec![];
    let mut peeked = vec![];
    let mut awaiting = vec![];
    for m in frames {
        match m {
            ServerMsg::MotherJobs { jobs } => listed.extend(jobs.iter().map(|j| j.id.clone())),
            ServerMsg::MotherPeek { job_id, .. } => peeked.push(job_id.clone()),
            ServerMsg::MotherAwaitDetected(j) => awaiting.push(j.id.clone()),
            _ => {}
        }
    }
    (listed, peeked, awaiting)
}

#[tokio::test]
async fn a_tcp_client_is_not_told_about_a_mother_job_that_a_work_item_started() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, mut useen) = h.unix(vec![]).await;
    let outcome = SendOutcome { kind: "mother_job".into(), focus_tag: None, job_id: Some("job-work".into()) };
    work_send_via(&mut unix, ScriptedWorkService { outcome, spawn: None }, "mother_job").await;
    let (mut tcp, mut tseen) = h.tcp(vec![]).await;

    for msg in mother_frames(&["job-work", "job-plain"]) {
        h.broadcast(msg);
    }
    h.broadcast(ServerMsg::Pong);
    tseen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);
    useen.extend(recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await);

    let both = vec!["job-work".to_string(), "job-plain".to_string()];
    assert_eq!(
        mother_ids(&useen),
        (both.clone(), both.clone(), both),
        "control: a Unix peer sees every job"
    );
    let plain = vec!["job-plain".to_string()];
    assert_eq!(
        mother_ids(&tseen),
        (plain.clone(), plain.clone(), plain),
        "a TCP peer must see the ordinary job and nothing of the work-derived one"
    );
}

#[tokio::test]
async fn a_tcp_client_cannot_cancel_or_answer_a_mother_job_that_a_work_item_started() {
    use nostromo::ipc::protocol::MotherActionKind;
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    let outcome = SendOutcome { kind: "mother_job".into(), focus_tag: None, job_id: Some("job-work".into()) };
    work_send_via(&mut unix, ScriptedWorkService { outcome, spawn: None }, "mother_job").await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    let cancel = attack(&mut tcp, ClientMsg::MotherAction { job_id: "job-work".into(), action: MotherActionKind::Cancel }).await;
    assert_refused(&cancel, "mother_action on a work-derived job");
    let resume = attack(&mut tcp, ClientMsg::MotherResume { job_id: "job-work".into(), answer: "do it".into() }).await;
    assert_refused(&resume, "mother_resume on a work-derived job");
}

#[tokio::test]
async fn a_tcp_client_cannot_answer_a_decision_request_of_a_sensitive_focus_even_with_its_id() {
    use nostromo::ipc::protocol::DecisionChoice;
    let h = spawn_server().await;
    let (request_id, _rx, _msg) = h.decisions.lock().unwrap().submit(
        "fred".into(),
        "Forward the 20 newest mails?".into(),
        None,
        vec![DecisionChoice { id: "yes".into(), label: "Yes".into(), detail: None }],
        None,
    );
    let (mut tcp, _) = h.tcp(vec![]).await;

    let frames = attack(
        &mut tcp,
        ClientMsg::DecisionAnswer { request_id: request_id.clone(), choice_id: Some("yes".into()) },
    )
    .await;
    assert_refused(&frames, "decision_answer for a sensitive focus");
    assert_eq!(
        h.decisions.lock().unwrap().active_request_id("fred"),
        Some(request_id),
        "the request must still be waiting for its real operator"
    );
}

// ── review round 2: per-focus Perri state, agent aliases, creators ────────────

fn perri_state(tag: &str) -> ServerMsg {
    ServerMsg::PerriState { tag: tag.into(), queue: vec![], current: None }
}

fn perri_tags(frames: &[ServerMsg]) -> Vec<String> {
    frames
        .iter()
        .filter_map(|m| if let ServerMsg::PerriState { tag, .. } = m { Some(tag.clone()) } else { None })
        .collect()
}

struct FixedPerriProvider(Vec<String>);

impl nostromo::ipc::pane_registry::PerriStateProvider for FixedPerriProvider {
    fn perri_states(&self, _focus_tags: &[String]) -> Vec<ServerMsg> {
        self.0.iter().map(|t| perri_state(t)).collect()
    }
}

#[tokio::test]
async fn a_tcp_client_is_neither_broadcast_nor_replayed_the_perri_state_of_a_sensitive_focus() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![Topic::Focuses]).await;
    derive_focus(&mut unix, W).await;
    h.session_mgr
        .lock()
        .unwrap()
        .configure_perri_state_provider(Arc::new(FixedPerriProvider(vec!["fred".into(), W.into(), "cody-x".into()])));

    // Replay at connect.
    let (mut tcp, replay) = h.tcp(vec![]).await;
    assert_eq!(perri_tags(&replay), vec!["cody-x".to_string()], "replay: {replay:?}");
    let (_unix2, unix_replay) = h.unix(vec![]).await;
    assert_eq!(perri_tags(&unix_replay).len(), 3, "control: a Unix peer is replayed every focus");

    // Live broadcast.
    for tag in ["fred", "teri", W, "cody-x"] {
        h.broadcast(perri_state(tag));
    }
    h.broadcast(ServerMsg::Pong);
    let live = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    assert_eq!(perri_tags(&live), vec!["cody-x".to_string()], "broadcast: {live:?}");
}

#[tokio::test]
async fn a_tcp_client_cannot_reach_a_fred_session_spawned_under_a_plugin_qualified_agent_name() {
    let h = spawn_server().await;
    let (mut tcp, _) = h.tcp(vec![]).await;
    for agent in ["teri:teri", " Fred ", "FRED:fred"] {
        let frames = attack(
            &mut tcp,
            ClientMsg::SessionSpawn {
                tag: "t1".into(),
                agent_name: agent.into(),
                view_name: "v".into(),
                cwd: None,
                session_id: None,
                remote_control: false,
            },
        )
        .await;
        assert_refused(&frames, &format!("session_spawn for agent {agent:?}"));
    }
}

#[tokio::test]
async fn a_focus_created_by_a_fred_session_is_sensitive_even_without_initial_context() {
    let h = spawn_server().await;
    let state = mcp_state(&h);
    let created = create_focus(&state, &json!({"agent": "cody", "title": "Mail from SECRET-SENDER"}), Some("fred")).await;
    let tag = created["focus_id"].as_str().expect("focus_id").to_string();
    let (mut tcp, _) = h.tcp(vec![]).await;

    assert_refused(&attack(&mut tcp, ClientMsg::SessionAttach { tag: tag.clone() }).await, "attach to a Fred-created focus");
    h.broadcast(ServerMsg::FocusCreated { meta: meta(&tag, "Mail from SECRET-SENDER", "cody", false) });
    h.broadcast(ServerMsg::Pong);
    let seen = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    assert!(!json_of(&seen).to_lowercase().contains("secret"), "{seen:?}");
}

#[tokio::test]
async fn a_focus_pushed_with_the_fred_agent_under_a_custom_tag_is_sensitive_before_any_session_exists() {
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    send(&mut unix, &ClientMsg::FocusRegistryPush { focuses: vec![meta("my-mail", "My Mail", "fred", false)] }).await;
    let _ = sync(&mut unix).await;
    let (mut tcp, _) = h.tcp(vec![]).await;

    assert_refused(&attack(&mut tcp, ClientMsg::SessionAttach { tag: "my-mail".into() }).await, "attach to a custom-tag Fred focus");
    h.broadcast(pane_content("my-mail"));
    h.broadcast(ServerMsg::Pong);
    let seen = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    assert!(!seen.iter().any(|m| matches!(m, ServerMsg::PaneContent { .. })), "{seen:?}");
}

#[tokio::test]
async fn a_tcp_client_cannot_grow_the_sensitive_registry_by_pushing_fred_focuses() {
    let h = spawn_server().await;
    let (mut tcp, _) = h.tcp(vec![]).await;
    send(&mut tcp, &ClientMsg::FocusRegistryPush { focuses: vec![meta("tcp-pushed", "X", "fred", false)] }).await;
    let _ = sync(&mut tcp).await;
    let tags = h.session_mgr.lock().unwrap().sensitive_tags();
    assert!(!tags.tag_is_sensitive("tcp-pushed"), "a network peer must not register permanent entries");
}

#[tokio::test]
async fn a_unix_client_that_subscribed_to_everything_is_not_replayed_retained_frames_again_by_a_second_subscribe() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;
    let (mut unix, first) = h.unix(vec![]).await;
    assert!(count(&first, |m| matches!(m, ServerMsg::FredState { .. })) == 1, "{first:?}");

    send(&mut unix, &ClientMsg::Subscribe { topics: vec![], renders_decisions: false }).await;
    let second = sync(&mut unix).await;
    assert!(second.is_empty(), "nothing was added, so nothing may be replayed again: {second:?}");
}

// ── H4: focus metadata a network peer may see ────────────────────────────────

fn meta(tag: &str, display_name: &str, agent: &str, built_in: bool) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: display_name.into(),
        agent_name: agent.into(),
        project_name: None,
        org: None,
        is_built_in: built_in,
        session_summary: Some(format!("SUMMARY-{tag}")),
        label: Some(format!("LABEL-{tag}")),
        project_path: Some(format!("/Users/x/{tag}")),
        select_for_client: None,
    }
}

fn h4_metas() -> Vec<FocusMeta> {
    vec![
        meta("cody-x", "Cody in Admin Portal", "cody", false),
        meta("fred", "Fred SECRET-DISPLAY", "fred", true),
        meta("teri", "Teri SECRET-DISPLAY", "teri", true),
        meta(W, "Cody on SECRET-JIRA-TITLE", "cody", false),
    ]
}

/// What a network peer may see of `orig`, by focus class.
fn assert_network_view(out: &FocusMeta, orig: &FocusMeta, via: &str) {
    assert!(out.session_summary.is_none(), "{via}: session_summary reached a network peer: {out:?}");
    assert!(out.label.is_none(), "{via}: label reached a network peer: {out:?}");
    assert!(out.project_path.is_none(), "{via}: project_path reached a network peer: {out:?}");
    match orig.tag.as_str() {
        "cody-x" => {
            assert_eq!(out.tag, orig.tag, "{via}");
            assert_eq!(out.display_name, orig.display_name, "{via}: an ordinary focus keeps its name");
        }
        "fred" | "teri" => {
            assert_eq!(out.tag, orig.tag, "{via}: built-in tags are public");
            assert_eq!(out.display_name, orig.agent_name, "{via}: a sensitive focus shows only its agent");
        }
        _ => {
            assert_eq!(out.display_name, orig.agent_name, "{via}: a work-derived focus shows only its agent");
            assert!(!out.tag.is_empty(), "{via}");
            assert_ne!(out.tag, orig.tag, "{via}: the work-derived tag must be replaced");
            assert!(
                !out.tag.to_lowercase().contains("secret"),
                "{via}: the replacement tag must not contain the original text: {}",
                out.tag
            );
        }
    }
}

fn metas_of(frame: &ServerMsg) -> Option<Vec<FocusMeta>> {
    match frame {
        ServerMsg::FocusRegistryUpdated { focuses } | ServerMsg::FocusListResp { focuses } => {
            Some(focuses.clone())
        }
        ServerMsg::FocusCreated { meta } => Some(vec![meta.clone()]),
        _ => None,
    }
}

#[tokio::test]
async fn a_tcp_client_sees_redacted_focus_metadata_while_a_unix_client_sees_it_unredacted() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    derive_focus(&mut unix, W).await;
    let (mut tcp, mut tseen) = h.tcp(vec![]).await;
    let metas = h4_metas();

    // focus_registry_updated (a Unix peer pushes; the daemon fans out), then
    // focus_created for each.
    send(&mut unix, &ClientMsg::FocusRegistryPush { focuses: metas.clone() }).await;
    for m in &metas {
        h.broadcast(ServerMsg::FocusCreated { meta: m.clone() });
    }
    h.broadcast(ServerMsg::Pong);
    tseen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);
    let mut useen = recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await;

    // focus_list_resp
    tseen.extend(attack(&mut tcp, ClientMsg::FocusList).await);
    useen.extend(attack(&mut unix, ClientMsg::FocusList).await);

    for (peer, frames) in [("unix", &useen), ("tcp", &tseen)] {
        let updated: Vec<_> = frames
            .iter()
            .filter(|m| matches!(m, ServerMsg::FocusRegistryUpdated { .. }))
            .filter_map(metas_of)
            .collect();
        let created: Vec<FocusMeta> = frames
            .iter()
            .filter(|m| matches!(m, ServerMsg::FocusCreated { .. }))
            .filter_map(metas_of)
            .flatten()
            .collect();
        let listed: Vec<_> = frames
            .iter()
            .filter(|m| matches!(m, ServerMsg::FocusListResp { .. }))
            .filter_map(metas_of)
            .collect();
        assert_eq!(updated.len(), 1, "{peer}: one focus_registry_updated");
        assert_eq!(listed.len(), 1, "{peer}: one focus_list_resp");
        assert_eq!(created.len(), metas.len(), "{peer}: one focus_created per focus");

        for (via, out) in [("registry_updated", &updated[0]), ("focus_list_resp", &listed[0]), ("focus_created", &created)] {
            assert_eq!(out.len(), metas.len(), "{peer} {via}");
            for (o, orig) in out.iter().zip(&metas) {
                if peer == "unix" {
                    assert_eq!(o, orig, "control: a Unix peer sees unredacted metadata ({via})");
                } else {
                    assert_network_view(o, orig, via);
                }
            }
        }
    }

    let lowered = json_of(&tseen).to_lowercase();
    for needle in ["secret", "summary-", "label-", "/users/x"] {
        assert!(!lowered.contains(needle), "`{needle}` reached the TCP peer: {lowered}");
    }
}

#[tokio::test]
async fn session_summary_updates_for_sensitive_and_work_derived_tags_are_not_delivered_to_a_tcp_client() {
    let _guard = RegistryGuard::acquire().await;
    let h = spawn_server().await;
    let (mut unix, _) = h.unix(vec![]).await;
    derive_focus(&mut unix, W).await;
    let (mut tcp, mut tseen) = h.tcp(vec![]).await;

    for tag in ["fred", "teri", W, "cody-x"] {
        h.broadcast(ServerMsg::SessionSummaryUpdate { tag: tag.into(), summary: format!("SUMMARY-OF-{tag}") });
    }
    h.broadcast(ServerMsg::Pong);
    tseen.extend(recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await);
    let useen = recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await;

    let tags = |frames: &[ServerMsg]| -> Vec<String> {
        frames
            .iter()
            .filter_map(|m| match m {
                ServerMsg::SessionSummaryUpdate { tag, .. } => Some(tag.clone()),
                _ => None,
            })
            .collect()
    };
    assert_eq!(tags(&useen).len(), 4, "control: a Unix peer receives every summary update");
    assert_eq!(tags(&tseen), vec!["cody-x".to_string()]);
}

#[tokio::test]
async fn focus_created_for_a_create_focus_with_initial_context_reaches_a_tcp_client_only_in_redacted_form() {
    let h = spawn_server().await;
    let state = mcp_state(&h);
    let (mut tcp, _) = h.tcp(vec![]).await;
    let (mut unix, _) = h.unix(vec![]).await;

    let created = create_focus(
        &state,
        &json!({"agent": "cody", "title": "SECRET-JIRA-TITLE-B", "initial_context": "SEED-CONTEXT-B"}),
        None,
    )
    .await;
    let tag = created["focus_id"].as_str().expect("focus_id").to_string();
    h.broadcast(ServerMsg::Pong);
    let tseen = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    let useen = recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await;

    // Control: the Unix peer sees the real tag, the title, and the layout.
    assert!(
        useen.iter().any(|m| matches!(m, ServerMsg::FocusCreated { meta } if meta.tag == tag && meta.display_name == "SECRET-JIRA-TITLE-B")),
        "control: {useen:?}"
    );
    assert!(useen.iter().any(|m| matches!(m, ServerMsg::FocusLayout { tag: t, .. } if *t == tag)));

    let lowered = json_of(&tseen).to_lowercase();
    assert!(!lowered.contains("secret"), "the title leaked to a TCP peer: {lowered}");
    assert!(
        !tseen.iter().any(|m| matches!(m, ServerMsg::FocusLayout { .. })),
        "the layout of a context-seeded focus leaked: {tseen:?}"
    );
    let created_meta: Vec<&FocusMeta> =
        tseen.iter().filter_map(|m| if let ServerMsg::FocusCreated { meta } = m { Some(meta) } else { None }).collect();
    assert_eq!(created_meta.len(), 1, "{tseen:?}");
    assert_eq!(created_meta[0].display_name, "cody");
}

// ── H5: version skew ─────────────────────────────────────────────────────────

async fn send_json<S: AsyncWrite + Unpin>(stream: &mut S, v: &Value) {
    write_frame(stream, &serde_json::to_vec(v).unwrap()).await.expect("write frame");
}

/// Next frame as raw JSON; `Err` says why there was none (closed / timed out).
async fn try_recv_json<S: AsyncRead + Unpin>(stream: &mut S) -> Result<Value, String> {
    match tokio::time::timeout(Duration::from_secs(5), read_frame(stream)).await {
        Err(_) => Err("timed out waiting for a frame".into()),
        Ok(Err(e)) => Err(format!("the daemon closed the connection: {e}")),
        Ok(Ok(bytes)) => Ok(serde_json::from_slice(&bytes).expect("daemon frames are JSON")),
    }
}

/// Ping and read raw frames until the Pong; returns those before it.
async fn raw_sync<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Result<Vec<Value>, String> {
    send_json(stream, &json!({"type": "ping"})).await;
    let mut frames = vec![];
    loop {
        let v = try_recv_json(stream).await?;
        if v["type"] == "pong" {
            return Ok(frames);
        }
        frames.push(v);
    }
}

/// Raw Hello -> Welcome -> `subscribe` -> sync. Returns the Welcome and the
/// frames before the Pong.
async fn raw_handshake<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    subscribe: Value,
) -> Result<(Value, Vec<Value>), String> {
    send_json(
        stream,
        &json!({"type": "hello", "client_id": "version-skew-it", "protocol_version": PROTOCOL_VERSION}),
    )
    .await;
    let welcome = try_recv_json(stream).await?;
    if welcome["type"] != "welcome" {
        return Err(format!("expected welcome, got {welcome}"));
    }
    send_json(stream, &subscribe).await;
    let replay = raw_sync(stream).await?;
    Ok((welcome, replay))
}

fn types(frames: &[Value]) -> Vec<String> {
    frames.iter().filter_map(|f| f["type"].as_str().map(String::from)).collect()
}

async fn raw_unix(h: &Harness) -> UnixStream {
    UnixStream::connect(&h.socket_path).await.expect("unix connect")
}

async fn raw_tcp(h: &Harness) -> TcpStream {
    TcpStream::connect(("127.0.0.1", h.tcp_port)).await.expect("tcp connect")
}

/// A subscribe naming a topic this daemon has never heard of is accepted, and
/// the topics it does know are served.
async fn unknown_topic_is_tolerated<S: AsyncRead + AsyncWrite + Unpin>(h: &Harness, mut s: S) -> Vec<Value> {
    let (_welcome, _replay) = raw_handshake(
        &mut s,
        json!({"type": "subscribe", "topics": ["activity", "some_future_topic"], "renders_decisions": false}),
    )
    .await
    .expect("a subscribe naming an unknown topic must be accepted, not end the connection");

    h.broadcast(health_probe());
    h.broadcast(fred_state(1));
    raw_sync_via_broadcast(h, &mut s).await
}

/// Broadcast a `Pong` and read raw frames until it arrives.
async fn raw_sync_via_broadcast<S: AsyncRead + Unpin>(h: &Harness, s: &mut S) -> Vec<Value> {
    h.broadcast(ServerMsg::Pong);
    let mut frames = vec![];
    loop {
        let v = try_recv_json(s).await.expect("connection must stay open");
        if v["type"] == "pong" {
            return frames;
        }
        frames.push(v);
    }
}

#[tokio::test]
async fn a_unix_client_subscribing_with_an_unknown_topic_alongside_a_known_one_stays_connected_and_is_served() {
    let h = spawn_server().await;
    let frames = unknown_topic_is_tolerated(&h, raw_unix(&h).await).await;
    assert!(
        frames.iter().any(|f| f["type"] == "activity_health" && f["reason"] == "health-probe"),
        "the known topic must still be delivered: {frames:?}"
    );
    assert!(!types(&frames).contains(&"fred_state".to_string()), "an unsubscribed topic leaked: {frames:?}");
}

#[tokio::test]
async fn a_tcp_client_subscribing_with_an_unknown_topic_alongside_a_known_one_stays_connected_and_is_served() {
    let h = spawn_server().await;
    let frames = unknown_topic_is_tolerated(&h, raw_tcp(&h).await).await;
    assert!(
        frames.iter().any(|f| f["type"] == "activity_health" && f["reason"] == "health-probe"),
        "the known topic must still be delivered: {frames:?}"
    );
    assert!(!types(&frames).contains(&"fred_state".to_string()), "{frames:?}");
}

#[tokio::test]
async fn a_client_whose_subscribe_topics_are_malformed_stays_connected_and_a_tcp_one_still_gets_nothing_sensitive() {
    let h = spawn_server().await;
    let malformed = json!({"type": "subscribe", "topics": [42, {"x": 1}], "renders_decisions": false});

    let mut unix = raw_unix(&h).await;
    raw_handshake(&mut unix, malformed.clone())
        .await
        .expect("a Unix client's malformed topic list must not end the connection");

    let mut tcp = raw_tcp(&h).await;
    raw_handshake(&mut tcp, malformed)
        .await
        .expect("a TCP client's malformed topic list must not end the connection");
    for msg in all_sensitive_broadcasts() {
        h.broadcast(msg);
    }
    let frames = raw_sync_via_broadcast(&h, &mut tcp).await;
    for t in types(&frames) {
        assert!(
            !["fred_state", "teri_state", "work_source_status", "work_snapshot", "teri_picks", "work_detail", "work_send_preview", "work_send_result"]
                .contains(&t.as_str()),
            "a sensitive frame ({t}) reached a TCP peer after a malformed subscribe: {frames:?}"
        );
    }
}

#[tokio::test]
async fn the_welcome_a_local_client_receives_advertises_the_work_feature_and_keeps_protocol_version_4() {
    let h = spawn_server().await;
    let mut s = raw_unix(&h).await;
    send_json(&mut s, &json!({"type": "hello", "client_id": "features-it", "protocol_version": PROTOCOL_VERSION}))
        .await;
    let welcome = try_recv_json(&mut s).await.expect("welcome");

    assert_eq!(welcome["type"], "welcome");
    assert_eq!(welcome["protocol_version"], 4, "{welcome}");
    let features = welcome["features"].as_array().unwrap_or_else(|| panic!("welcome carries no `features` array: {welcome}"));
    assert!(features.iter().any(|f| f == "work"), "`features` must contain \"work\": {welcome}");
}

async fn old_style_client_round_trip<S: AsyncRead + AsyncWrite + Unpin>(h: &Harness, mut s: S) {
    // An old client: knows no `features`, never mentions `work`, ignores
    // unknown Welcome fields.
    let (welcome, _) = raw_handshake(&mut s, json!({"type": "subscribe", "topics": ["activity"]}))
        .await
        .expect("an old-style client must complete the handshake");
    assert_eq!(welcome["protocol_version"], 4);

    h.broadcast(health_probe());
    let frames = raw_sync_via_broadcast(h, &mut s).await;
    assert!(
        frames.iter().any(|f| f["type"] == "activity_health" && f["reason"] == "health-probe"),
        "an old-style client must still receive broadcasts: {frames:?}"
    );
}

#[tokio::test]
async fn an_old_style_unix_client_that_never_mentions_work_still_works_end_to_end() {
    let h = spawn_server().await;
    old_style_client_round_trip(&h, raw_unix(&h).await).await;
}

#[tokio::test]
async fn an_old_style_tcp_client_that_never_mentions_work_still_works_end_to_end() {
    let h = spawn_server().await;
    old_style_client_round_trip(&h, raw_tcp(&h).await).await;
}

#[tokio::test]
async fn a_unix_client_that_adds_the_work_topic_with_a_second_subscribe_is_replayed_only_the_newly_added_topic_and_gets_later_work_broadcasts() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    // Base topics only, as a client does before it has seen the Welcome features.
    let (mut unix, first) = h.unix(vec![Topic::Activity]).await;
    assert_eq!(count(&first, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 0, "{first:?}");
    assert_eq!(count(&first, |m| matches!(m, ServerMsg::ActivityHealth { .. })), 1, "{first:?}");

    send(&mut unix, &ClientMsg::Subscribe { topics: vec![Topic::Activity, Topic::Work], renders_decisions: false })
        .await;
    let second = sync(&mut unix).await;

    assert_eq!(count(&second, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 1, "{second:?}");
    assert_eq!(count(&second, |m| matches!(m, ServerMsg::WorkSnapshot { .. })), 1, "{second:?}");
    assert_eq!(count(&second, |m| matches!(m, ServerMsg::TeriPicks { .. })), 1, "{second:?}");
    assert_eq!(
        count(&second, |m| matches!(m, ServerMsg::ActivityHealth { .. })),
        0,
        "already-subscribed topics must not be replayed again: {second:?}"
    );
    assert_eq!(count(&second, |m| matches!(m, ServerMsg::FredState { .. } | ServerMsg::TeriState { .. })), 0);

    // Subsequent work broadcasts are delivered; topics still not subscribed are not.
    h.broadcast(fred_state(8));
    h.broadcast(source_status(WorkSource::Sentry));
    h.broadcast(ServerMsg::Pong);
    let later = recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await;
    assert_eq!(count(&later, |m| matches!(m, ServerMsg::WorkSourceStatus { .. })), 1, "{later:?}");
    assert_eq!(count(&later, |m| matches!(m, ServerMsg::FredState { .. })), 0, "{later:?}");
}

#[tokio::test]
async fn a_tcp_client_that_adds_the_work_topic_with_a_second_subscribe_is_still_given_nothing_sensitive() {
    let h = spawn_server().await;
    broadcast_retained_set(&h).await;

    let (mut tcp, first) = h.tcp(vec![Topic::Activity]).await;
    assert_no_sensitive(&first);

    send(&mut tcp, &ClientMsg::Subscribe { topics: vec![Topic::Activity, Topic::Work], renders_decisions: false })
        .await;
    let second = sync(&mut tcp).await;
    assert_no_sensitive(&second);
    assert_eq!(count(&second, |m| matches!(m, ServerMsg::ActivityHealth { .. })), 0, "{second:?}");

    for msg in all_sensitive_broadcasts() {
        h.broadcast(msg);
    }
    h.broadcast(ServerMsg::Pong);
    let later = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    assert_no_sensitive(&later);
}

// ── H6: retained cache eviction ──────────────────────────────────────────────

fn replayed_snapshot_groups(replay: &[ServerMsg]) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = replay
        .iter()
        .filter_map(|m| match m {
            ServerMsg::WorkSnapshot { source, group, .. } => {
                Some((source.as_str().to_string(), group.clone().unwrap_or_default()))
            }
            _ => None,
        })
        .collect();
    v.sort();
    v
}

#[tokio::test]
async fn a_group_whose_snapshot_becomes_empty_is_no_longer_replayed_to_a_late_subscriber() {
    let h = spawn_server().await;
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:a.md"]));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-b"), &["doc:repo-b:b.md"]));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &[]));
    let_retention_settle().await;

    let (_unix, replay) = h.unix(vec![Topic::Work]).await;

    assert_eq!(
        replayed_snapshot_groups(&replay),
        vec![("repo_docs".to_string(), "repo-b".to_string())],
        "an emptied group must be evicted from the retained cache: {replay:?}"
    );
}

#[tokio::test]
async fn a_source_that_stops_being_configured_has_its_retained_snapshots_evicted() {
    let h = spawn_server().await;
    h.broadcast(work_snapshot(WorkSource::Jira, None, &["jira:A-1"]));
    h.broadcast(work_snapshot(WorkSource::RepoDocs, Some("repo-a"), &["doc:repo-a:a.md"]));
    h.broadcast(ServerMsg::WorkSourceStatus {
        status: SourceStatus {
            source: WorkSource::Jira,
            state: SourceState::NotConfigured,
            updated_at: None,
            reason: Some("disabled".into()),
            retry_at: None,
            count: 0,
            group_errors: vec![],
        },
    });
    let_retention_settle().await;

    let (_unix, replay) = h.unix(vec![Topic::Work]).await;

    assert_eq!(
        replayed_snapshot_groups(&replay),
        vec![("repo_docs".to_string(), "repo-a".to_string())],
        "the unconfigured source's stale items must not be replayed; other sources are unaffected: {replay:?}"
    );
}
