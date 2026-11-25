//! The WebSocket transport.
//!
//! One JSON message per text frame, the same `ClientMsg`/`ServerMsg` as the
//! Unix and TCP transports. A connection is admitted at the HTTP upgrade by its
//! `Authorization: Bearer <token>` header (never a query string):
//!
//! * **Paired** (a valid, unrevoked token): served by the ordinary
//!   `handle_client` loop under `PeerTrust::Paired`. The socket is bridged to
//!   it through an in-memory byte stream carrying the length-prefixed framing,
//!   so the Unix and TCP paths are untouched.
//! * **Pairing-only** (no header): may send `Hello`, any number of `PairCheck`
//!   and one `Pair`, for at most 60 seconds. Anything else is `Unauthorized`.
//! * **Rejected** (a header with an unknown or revoked token): the upgrade
//!   completes, the peer is sent `Unauthorized` and the socket is closed with
//!   code 4001, so a device can tell "this server refuses me" from "I can't
//!   reach the server".

use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, Ipv6Addr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, OwnedSemaphorePermit, Semaphore};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, WebSocketConfig};
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{accept_hdr_async_with_config, WebSocketStream};
use tracing::{debug, info, warn};

use super::codec::read_frame;
use super::decisions::DecisionRegistry;
use super::device_hub::{DeviceHub, HubSlot};
use super::devices::{DeviceStanding, RevokedBy, SatelliteAdmin, TokenCheck};
use super::peer::SensitiveTags;
use super::protocol::{ClientMsg, ServerMsg, MAX_FRAME_LEN, MIN_CLIENT_VERSION, PROTOCOL_VERSION};
use super::router::{
    ingest_from_satellite, Bucket, Router, SatelliteRecord, UplinkLimits, Verdict,
};
use super::server::{handle_client, HeldMotherJobs, PeerOrigin, RetainedCache, SatelliteLink};
use super::session_manager::SessionManager;
use super::uplink_wire::{wrap_server_bytes, UplinkFrame};
use crate::terminal::TerminalManager;

/// Advertised in `Welcome.features` on every transport.
pub const FEATURE_WS: &str = "ws";
pub const FEATURE_PAIR: &str = "pair";
pub const FEATURE_DEVICES: &str = "devices";
/// A primary that lists connected satellites and routes reads to them.
pub const FEATURE_HOSTS: &str = "hosts";
/// A primary that accepts a satellite's uplink.
pub const FEATURE_UPLINK: &str = "uplink";

/// Close code for "this server refuses you" (revoked, unknown, not paired).
pub const CLOSE_UNAUTHORIZED: u16 = 4001;

/// How long a pairing-only socket may stay open.
const PAIRING_SOCKET_LIFETIME: Duration = Duration::from_secs(60);

/// Unauthenticated upgrades allowed per source IP per window.
const UPGRADE_LIMIT: usize = 20;
const UPGRADE_WINDOW: Duration = Duration::from_secs(60);

/// How often a connected device's `last_seen_at` is persisted.
const TOUCH_EVERY: Duration = Duration::from_secs(60);

/// A pairing frame (`Hello`, `PairCheck`, `Pair`) is well under 1 KiB; a
/// pairing-only socket closes with 1009 on anything beyond a few KiB. (The
/// library's own limit is chosen at accept time, before the peer's trust is
/// known, so a message is buffered up to that limit before this check runs;
/// the unauthenticated-slot cap and the upgrade limiter bound how many
/// sockets can do so at once.)
pub const PAIRING_MAX_MESSAGE: usize = 4 * 1024;

/// Limits on connections that have not authenticated yet, and on devices.
#[derive(Debug, Clone)]
pub struct WsLimits {
    /// How long the HTTP upgrade may take, from accept to a complete handshake.
    pub handshake_timeout: Duration,
    /// Connections in the unauthenticated stage (handshake, or a pairing-only
    /// socket), all addresses together.
    pub max_unauthenticated: usize,
    /// The same, per source address (IPv6: per /64). Eight: a household has a
    /// handful of devices, so no honest address needs more at once, and a few
    /// addresses cannot hold the whole listener full (the upgrade limiter counts
    /// only completed handshakes, so a trickler reconnecting every
    /// `handshake_timeout` is bounded by this alone). A full cap refuses the
    /// newcomer; it does not evict the oldest unauthenticated socket.
    pub max_unauthenticated_per_ip: usize,
    /// Concurrent authenticated sockets of one device.
    pub max_sockets_per_device: usize,
    /// What the primary accepts from a satellite's uplink.
    pub uplink: UplinkLimits,
}

impl Default for WsLimits {
    fn default() -> Self {
        Self {
            handshake_timeout: Duration::from_secs(10),
            max_unauthenticated: 64,
            max_unauthenticated_per_ip: 8,
            max_sockets_per_device: 8,
            uplink: UplinkLimits::default(),
        }
    }
}

/// Counts connections in the unauthenticated stage, globally and per address.
struct UnauthSlots {
    global: Arc<Semaphore>,
    per_ip: Mutex<HashMap<IpAddr, usize>>,
    max_per_ip: usize,
}

/// A held slot; dropping it releases both counts.
pub(super) struct UnauthSlot {
    slots: Arc<UnauthSlots>,
    key: IpAddr,
    _permit: OwnedSemaphorePermit,
}

impl UnauthSlots {
    fn new(limits: &WsLimits) -> Arc<Self> {
        Arc::new(Self {
            global: Arc::new(Semaphore::new(limits.max_unauthenticated)),
            per_ip: Mutex::new(HashMap::new()),
            max_per_ip: limits.max_unauthenticated_per_ip,
        })
    }

    fn try_acquire(self: &Arc<Self>, ip: IpAddr) -> Option<UnauthSlot> {
        let key = ip_key(ip);
        let permit = Arc::clone(&self.global).try_acquire_owned().ok()?;
        let mut per_ip = self.per_ip.lock().unwrap();
        let n = per_ip.entry(key).or_insert(0);
        if *n >= self.max_per_ip {
            return None;
        }
        *n += 1;
        Some(UnauthSlot {
            slots: Arc::clone(self),
            key,
            _permit: permit,
        })
    }
}

impl Drop for UnauthSlot {
    fn drop(&mut self) {
        let mut per_ip = self.slots.per_ip.lock().unwrap();
        if let Some(n) = per_ip.get_mut(&self.key) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                per_ip.remove(&self.key);
            }
        }
    }
}

/// The key an address is limited under: IPv6 by its /64 (one subscriber or
/// host owns a whole /64, so per-address limits would be free to dodge).
fn ip_key(ip: IpAddr) -> IpAddr {
    match ip {
        // `::ffff:a.b.c.d` is the IPv4 peer `a.b.c.d` on a dual-stack socket.
        IpAddr::V6(v6) if v6.to_ipv4_mapped().is_some() => {
            IpAddr::V4(v6.to_ipv4_mapped().expect("checked"))
        }
        IpAddr::V6(v6) => {
            let mut o = v6.octets();
            o[8..].fill(0);
            IpAddr::V6(Ipv6Addr::from(o))
        }
        v4 => v4,
    }
}

/// Everything `handle_client` needs, bundled for the accept loop.
pub(super) struct WsShared {
    pub tx: broadcast::Sender<ServerMsg>,
    pub session_mgr: Arc<Mutex<SessionManager>>,
    pub perri_state_dir: std::path::PathBuf,
    pub decisions: Arc<Mutex<DecisionRegistry>>,
    pub retained: RetainedCache,
    pub held_mother_jobs: HeldMotherJobs,
    pub terminals: Arc<Mutex<TerminalManager>>,
    pub hub_slot: HubSlot,
}

/// Per-source-IP limit on upgrades that were not authenticated.
pub struct UpgradeLimiter {
    hits: Mutex<HashMap<IpAddr, VecDeque<Instant>>>,
    limit: usize,
    window: Duration,
}

impl Default for UpgradeLimiter {
    fn default() -> Self {
        Self::new(UPGRADE_LIMIT, UPGRADE_WINDOW)
    }
}

impl UpgradeLimiter {
    pub fn new(limit: usize, window: Duration) -> Self {
        Self {
            hits: Mutex::new(HashMap::new()),
            limit,
            window,
        }
    }

    /// Record an unauthenticated upgrade from `ip`; false once over the limit.
    pub fn allow(&self, ip: IpAddr, now: Instant) -> bool {
        let ip = ip_key(ip);
        let mut hits = self.hits.lock().unwrap();
        hits.retain(|_, q| {
            while q
                .front()
                .is_some_and(|t| now.duration_since(*t) >= self.window)
            {
                q.pop_front();
            }
            !q.is_empty()
        });
        let q = hits.entry(ip).or_default();
        if q.len() >= self.limit {
            return false;
        }
        q.push_back(now);
        true
    }
}

enum Admission {
    Paired(String),
    PairingOnly,
    Rejected(&'static str),
}

/// The bearer token in an upgrade request, if any.
fn bearer(req: &Request) -> Option<&str> {
    let value = req.headers().get("authorization")?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    scheme
        .eq_ignore_ascii_case("bearer")
        .then_some(token.trim())
        .filter(|t| !t.is_empty())
}

fn forbidden() -> ErrorResponse {
    tokio_tungstenite::tungstenite::http::Response::builder()
        .status(403)
        .body(None)
        .expect("a static response")
}

fn too_many_requests() -> ErrorResponse {
    tokio_tungstenite::tungstenite::http::Response::builder()
        .status(429)
        .body(None)
        .expect("a static response")
}

/// A bound WebSocket listener and the device hub behind it.
pub struct WsSetup {
    pub listener: TcpListener,
    pub hub: Arc<DeviceHub>,
    pub bound: std::net::SocketAddr,
    pub pair_host: String,
}

/// Bind the WebSocket listener and load the device registry. An error here
/// (a busy port, an unreadable `devices.json`) is for the daemon to log and
/// carry on without device features, never to die of.
pub async fn setup_listener(
    config: &crate::config::Config,
    addr: std::net::SocketAddr,
    devices_path: std::path::PathBuf,
) -> Result<WsSetup> {
    use anyhow::Context;
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding WebSocket listener at {addr}"))?;
    let bound = listener.local_addr()?;
    let pair_host = config.resolve_pair_host(bound);
    let registry = super::devices::DeviceRegistry::load(devices_path)
        .context("loading the device registry")?;
    let hub = DeviceHub::new(
        Arc::new(registry),
        super::pairing::PAIRING_TTL,
        pair_host.clone(),
        bound.port(),
    );
    Ok(WsSetup {
        listener,
        hub,
        bound,
        pair_host,
    })
}

pub(super) async fn accept_loop_ws(
    listener: TcpListener,
    hub: Arc<DeviceHub>,
    shared: WsShared,
    limits: WsLimits,
) -> Result<()> {
    let shared = Arc::new(shared);
    let limiter = Arc::new(UpgradeLimiter::default());
    let slots = UnauthSlots::new(&limits);
    let limits = Arc::new(limits);
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                // Over the cap: drop the socket without reading a byte.
                let Some(slot) = slots.try_acquire(addr.ip()) else {
                    debug!(%addr, "WebSocket connection refused: too many unauthenticated connections");
                    continue;
                };
                let (hub, shared, limiter, limits) = (
                    Arc::clone(&hub),
                    Arc::clone(&shared),
                    Arc::clone(&limiter),
                    Arc::clone(&limits),
                );
                tokio::spawn(async move {
                    if let Err(e) =
                        serve(stream, addr.ip(), slot, hub, shared, limiter, limits).await
                    {
                        debug!(%addr, "WebSocket client ended: {e:#}");
                    }
                });
            }
            Err(e) => warn!("WebSocket accept error: {e}"),
        }
    }
}

fn ws_config() -> WebSocketConfig {
    // Roomy enough that an oversize message reaches us (and is closed with
    // 1009 by our own check) rather than failing inside the library.
    WebSocketConfig {
        max_message_size: Some(MAX_FRAME_LEN * 2),
        max_frame_size: Some(MAX_FRAME_LEN * 2),
        ..WebSocketConfig::default()
    }
}

async fn serve(
    stream: TcpStream,
    ip: IpAddr,
    slot: UnauthSlot,
    hub: Arc<DeviceHub>,
    shared: Arc<WsShared>,
    limiter: Arc<UpgradeLimiter>,
    limits: Arc<WsLimits>,
) -> Result<()> {
    let admission: Arc<Mutex<Option<Admission>>> = Arc::new(Mutex::new(None));
    let decided_slot = Arc::clone(&admission);
    let registry = Arc::clone(hub.registry());
    #[allow(clippy::result_large_err)] // the callback's `ErrorResponse` is fixed by tungstenite
    let callback = move |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
        // Browsers always send `Origin` on a WebSocket upgrade and native apps
        // never do: refuse a page that tries to reach this port.
        if req.headers().contains_key("origin") {
            return Err(forbidden());
        }
        let decided = match bearer(req).map(|t| registry.validate(t)) {
            Some(TokenCheck::Active { id }) => Admission::Paired(id),
            Some(TokenCheck::Revoked) => Admission::Rejected("revoked"),
            Some(TokenCheck::Unknown) => Admission::Rejected("unknown"),
            None => Admission::PairingOnly,
        };
        // Only a connection that is not authenticated counts against the limit.
        if !matches!(decided, Admission::Paired(_)) && !limiter.allow(ip, Instant::now()) {
            return Err(too_many_requests());
        }
        *decided_slot.lock().unwrap() = Some(decided);
        Ok(resp)
    };
    // A client that opens the socket and says nothing (or trickles bytes) must
    // not hold a task and a descriptor for ever.
    let ws = tokio::time::timeout(
        limits.handshake_timeout,
        accept_hdr_async_with_config(stream, callback, Some(ws_config())),
    )
    .await
    .map_err(|_| anyhow::anyhow!("the WebSocket handshake timed out"))??;
    let admitted = admission.lock().unwrap().take();
    match admitted {
        Some(Admission::Paired(id)) => {
            // Authenticated: no longer counted against the unauthenticated caps.
            drop(slot);
            run_paired(
                ws,
                id,
                hub,
                shared,
                limits.max_sockets_per_device,
                limits.uplink.clone(),
                limits.handshake_timeout,
            )
            .await
        }
        Some(Admission::PairingOnly) => run_pairing_only(ws, hub, slot).await,
        Some(Admission::Rejected(reason)) => {
            reject(ws, reason).await;
            Ok(())
        }
        None => Ok(()),
    }
}

fn close_msg(code: u16, reason: &'static str) -> Message {
    Message::Close(Some(CloseFrame {
        code: CloseCode::from(code),
        reason: reason.into(),
    }))
}

fn text(msg: &ServerMsg) -> Message {
    Message::Text(serde_json::to_string(msg).unwrap_or_default())
}

/// `Unauthorized { reason }`, then close 4001.
async fn reject(mut ws: WebSocketStream<TcpStream>, reason: &str) {
    let _ = ws
        .send(text(&ServerMsg::Unauthorized {
            reason: reason.to_string(),
        }))
        .await;
    let _ = ws.send(close_msg(CLOSE_UNAUTHORIZED, "unauthorized")).await;
    let _ = ws.flush().await;
}

/// The close for a message that is not a clean text frame, if it is not one.
fn close_for_bad_frame(msg: &Message) -> Option<Message> {
    match msg {
        Message::Binary(_) => Some(close_msg(1003, "binary frames are not supported")),
        Message::Text(t) if t.len() > MAX_FRAME_LEN => Some(close_msg(1009, "frame too large")),
        _ => None,
    }
}

// ── pairing-only socket ───────────────────────────────────────────────────────

fn pairing_welcome() -> ServerMsg {
    ServerMsg::Welcome {
        protocol_version: PROTOCOL_VERSION,
        daemon_pid: std::process::id(),
        features: [FEATURE_WS, FEATURE_PAIR, FEATURE_DEVICES]
            .map(String::from)
            .to_vec(),
        operator_nonce: None,
        enabled_agents: None,
        disabled_agents: None,
    }
}

async fn run_pairing_only(
    mut ws: WebSocketStream<TcpStream>,
    hub: Arc<DeviceHub>,
    _slot: UnauthSlot,
) -> Result<()> {
    let socket_id = hub.next_socket_id();
    let deadline = tokio::time::Instant::now() + PAIRING_SOCKET_LIFETIME;
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next()).await;
        let frame = match next {
            Err(_) => {
                let _ = ws.send(close_msg(1000, "pairing window over")).await;
                return Ok(());
            }
            Ok(Some(Err(WsError::Capacity(_)))) => {
                let _ = ws.send(close_msg(1009, "frame too large")).await;
                return Ok(());
            }
            Ok(None) | Ok(Some(Err(_))) => return Ok(()),
            Ok(Some(Ok(frame))) => frame,
        };
        if let Some(close) = close_for_bad_frame(&frame) {
            let _ = ws.send(close).await;
            return Ok(());
        }
        if matches!(&frame, Message::Text(t) if t.len() > PAIRING_MAX_MESSAGE) {
            let _ = ws.send(close_msg(1009, "frame too large")).await;
            return Ok(());
        }
        let body = match frame {
            Message::Text(body) => body,
            Message::Close(_) => return Ok(()),
            _ => continue, // ping, pong
        };
        let reply = match serde_json::from_str::<ClientMsg>(&body) {
            Ok(ClientMsg::Hello {
                protocol_version, ..
            }) => {
                if protocol_version < MIN_CLIENT_VERSION {
                    let _ = ws
                        .send(text(&ServerMsg::Error {
                            message: format!(
                                "protocol version {protocol_version} < required {MIN_CLIENT_VERSION}"
                            ),
                        }))
                        .await;
                    return Ok(());
                }
                pairing_welcome()
            }
            Ok(ClientMsg::PairCheck { code, proof }) => {
                hub.pair_check(socket_id, &code, proof.as_deref())
            }
            Ok(ClientMsg::Pair {
                code,
                name,
                kind,
                replace,
            }) => {
                let reply = hub.pair(socket_id, &code, &name, kind, replace);
                // One `Pair` per socket: reply, then close.
                let _ = ws.send(text(&reply)).await;
                let _ = ws.send(close_msg(1000, "done")).await;
                let _ = ws.flush().await;
                return Ok(());
            }
            _ => {
                let _ = ws
                    .send(text(&ServerMsg::Unauthorized {
                        reason: "not_paired".to_string(),
                    }))
                    .await;
                let _ = ws.send(close_msg(CLOSE_UNAUTHORIZED, "not paired")).await;
                let _ = ws.flush().await;
                return Ok(());
            }
        };
        if ws.send(text(&reply)).await.is_err() {
            return Ok(());
        }
    }
}

// ── paired socket ─────────────────────────────────────────────────────────────

/// What `run_paired` holds for a satellite's uplink: the record behind the
/// token, the rate limits, and the counters the router keeps.
struct UplinkSession {
    record: SatelliteRecord,
    snapshot: SatelliteAdmin,
    tags: SensitiveTags,
    limits: UplinkLimits,
    publish: Bucket,
    reply: Bucket,
    client: Bucket,
    /// Set by the handler once the `Hello` was accepted and the satellite is
    /// registered. Nothing it publishes or answers counts before that.
    admitted: Arc<AtomicBool>,
}

/// What reading one uplink frame decided.
enum Inbound {
    /// Hand this to `handle_client` (the satellite's own verb).
    Client(ClientMsg),
    /// Dealt with (admitted, or dropped and counted).
    Done,
    /// A `client` frame over the rate limit: tell the satellite, do not run it.
    Refused,
    /// Over the limit for the whole sustain window.
    Close,
}

impl UplinkSession {
    fn read(&mut self, body: &str, shared: &WsShared, router: &Router, now: Instant) -> Inbound {
        let name = self.record.name.clone();
        let junk = |s: &mut Self, router: &Router| {
            router.drops.junk.fetch_add(1, Ordering::Relaxed);
            router.note_drop(&name, "envelope", "malformed or wrong direction");
            match s.publish.take(now) {
                Verdict::Close => Inbound::Close,
                _ => Inbound::Done,
            }
        };
        let frame = match serde_json::from_str::<UplinkFrame>(body) {
            Ok(f) if f.is_from_satellite() => f,
            _ => return junk(self, router),
        };
        router.touch(&name);
        match frame {
            UplinkFrame::Client { msg } => match self.client.take(now) {
                Verdict::Allow => Inbound::Client(msg),
                Verdict::Drop => Inbound::Refused,
                Verdict::Close => Inbound::Close,
            },
            UplinkFrame::Publish { msg } => {
                let oversize = body.len() > self.limits.max_publish_bytes;
                match self.publish.take(now) {
                    Verdict::Close => return Inbound::Close,
                    Verdict::Drop => {
                        router.drops.publish.fetch_add(1, Ordering::Relaxed);
                        return Inbound::Done;
                    }
                    Verdict::Allow => {}
                }
                if !self.admitted.load(Ordering::SeqCst) {
                    router.drops.unadmitted.fetch_add(1, Ordering::Relaxed);
                    return Inbound::Done;
                }
                if oversize {
                    router.drops.oversize.fetch_add(1, Ordering::Relaxed);
                    router.note_drop(&name, &Router::variant_of(&msg), "over the size cap");
                    return Inbound::Done;
                }
                match ingest_from_satellite(&self.record, msg, &self.tags) {
                    Ok(admitted) => {
                        let _ = shared.tx.send(admitted);
                    }
                    Err(why) => {
                        router.drops.publish.fetch_add(1, Ordering::Relaxed);
                        router.note_drop(&name, "publish", &format!("{why:?}"));
                    }
                }
                Inbound::Done
            }
            UplinkFrame::Reply { id, msg } => {
                match self.reply.take(now) {
                    Verdict::Close => return Inbound::Close,
                    Verdict::Drop => {
                        router.drops.reply.fetch_add(1, Ordering::Relaxed);
                        return Inbound::Done;
                    }
                    Verdict::Allow => {}
                }
                if !self.admitted.load(Ordering::SeqCst) {
                    router.drops.unadmitted.fetch_add(1, Ordering::Relaxed);
                    return Inbound::Done;
                }
                if let Err(why) =
                    router.accept_routed_reply(&self.record, &id, msg, &self.tags, now)
                {
                    router.drops.reply.fetch_add(1, Ordering::Relaxed);
                    router.note_drop(&name, "reply", &format!("{why:?}"));
                }
                Inbound::Done
            }
            // `is_from_satellite` filtered these above.
            UplinkFrame::Server { .. } | UplinkFrame::Request { .. } => Inbound::Done,
        }
    }
}

/// Wait for the next routed request, or for ever when this is not an uplink.
async fn next_request(
    rx: &mut Option<mpsc::UnboundedReceiver<UplinkFrame>>,
) -> Option<UplinkFrame> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

/// Serve an authenticated device: bridge the socket to `handle_client` through
/// an in-memory stream that carries the codec's length-prefixed frames, and
/// watch the registry so a revoke closes this socket at once.
///
/// A satellite's token is served the same way, but its socket carries
/// `UplinkFrame` envelopes (see [`super::uplink_wire`]): its own verbs are
/// unwrapped into the bridge, what it publishes and the answers it gives to
/// routed reads go through the router's checks, and what the handler writes
/// is wrapped as `server`.
async fn run_paired(
    ws: WebSocketStream<TcpStream>,
    device_id: String,
    hub: Arc<DeviceHub>,
    shared: Arc<WsShared>,
    max_sockets: usize,
    uplink_limits: UplinkLimits,
    hello_timeout: Duration,
) -> Result<()> {
    let Some(_conn) = hub.try_connected(&device_id, max_sockets) else {
        let mut ws = ws;
        let _ = ws.send(close_msg(1008, "too many connections")).await;
        let _ = ws.flush().await;
        return Ok(());
    };
    info!(device = %device_id, "device connected");
    let registry = Arc::clone(hub.registry());
    let mut epoch = registry.subscribe_epoch();
    epoch.borrow_and_update();
    // Revoked between the upgrade and now. Standing and kind are read in one
    // look (after the subscription above, so a level change after it is not
    // missed): a revoke between two reads must not admit a satellite as a phone.
    let Some(satellite) = registry.admit(&device_id) else {
        reject(ws, "revoked").await;
        return Ok(());
    };

    let (server_side, bridge_side) = tokio::io::duplex(256 * 1024);
    let (mut bridge_rd, mut bridge_wr) = tokio::io::split(bridge_side);
    let (mut sink, mut stream) = ws.split();

    let role_refused = Arc::new(AtomicBool::new(false));
    let admitted = Arc::new(AtomicBool::new(false));
    let (req_tx, req_rx) = mpsc::unbounded_channel::<UplinkFrame>();
    let (link, mut req_rx, mut uplink) = match &satellite {
        Some(info) => {
            let now = Instant::now();
            let session = UplinkSession {
                record: SatelliteRecord {
                    name: info.name.clone(),
                    egress: info.egress,
                },
                snapshot: info.admin,
                tags: shared.session_mgr.lock().unwrap().sensitive_tags(),
                publish: Bucket::new(
                    uplink_limits.publish_rate,
                    uplink_limits.publish_burst,
                    uplink_limits.sustain,
                    now,
                ),
                reply: Bucket::new(
                    uplink_limits.reply_rate,
                    uplink_limits.reply_burst,
                    uplink_limits.sustain,
                    now,
                ),
                client: Bucket::new(
                    uplink_limits.client_rate,
                    uplink_limits.client_burst,
                    uplink_limits.sustain,
                    now,
                ),
                limits: uplink_limits,
                admitted: Arc::clone(&admitted),
            };
            (
                Some(SatelliteLink {
                    info: info.clone(),
                    req_tx: Some(req_tx),
                }),
                Some(req_rx),
                Some(session),
            )
        }
        None => (None, None, None),
    };

    let handler = tokio::spawn(handle_client(
        server_side,
        PeerOrigin::Ws {
            device_id: device_id.clone(),
            satellite: link,
            role_refused: Arc::clone(&role_refused),
            admitted: Arc::clone(&admitted),
        },
        shared.tx.subscribe(),
        shared.tx.clone(),
        Arc::clone(&shared.session_mgr),
        shared.perri_state_dir.clone(),
        Arc::clone(&shared.decisions),
        Arc::clone(&shared.retained),
        Arc::clone(&shared.held_mother_jobs),
        Arc::clone(&shared.terminals),
        Arc::clone(&shared.hub_slot),
    ));

    // `read_frame` is not cancel-safe: read whole frames in a task of their own.
    let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(16);
    let reader = tokio::spawn(async move {
        while let Ok(frame) = read_frame(&mut bridge_rd).await {
            if out_tx.send(frame).await.is_err() {
                break;
            }
        }
    });

    let mut touch = tokio::time::interval(TOUCH_EVERY);
    touch.tick().await;
    let mut closing: Option<Message> = None;
    // A satellite must get its `Hello` accepted in the time a WebSocket
    // handshake may take; a silent socket does not hold its slot for ever.
    let hello_deadline = tokio::time::sleep(hello_timeout);
    tokio::pin!(hello_deadline);
    // How the socket closes when the handler is done or the uplink was replaced.
    let ended = |registry: &super::devices::DeviceRegistry, refused: &AtomicBool| -> Message {
        if refused.load(Ordering::SeqCst) {
            return close_msg(CLOSE_UNAUTHORIZED, "unauthorized");
        }
        match registry.standing(&device_id) {
            Some(DeviceStanding::Revoked(_)) | None => {
                close_msg(CLOSE_UNAUTHORIZED, "unauthorized")
            }
            Some(DeviceStanding::Active) => close_msg(1000, "bye"),
        }
    };

    loop {
        tokio::select! {
            inbound = stream.next() => {
                let frame = match inbound {
                    None | Some(Ok(Message::Close(_))) => break,
                    Some(Err(WsError::Capacity(_))) => {
                        closing = Some(close_msg(1009, "frame too large"));
                        break;
                    }
                    Some(Err(_)) => break,
                    Some(Ok(frame)) => frame,
                };
                if let Some(close) = close_for_bad_frame(&frame) {
                    closing = Some(close);
                    break;
                }
                if let Message::Text(body) = frame {
                    // A satellite's frames are envelopes; a phone's are bare.
                    let body = match uplink.as_mut() {
                        None => body,
                        Some(session) => {
                            match session.read(&body, &shared, hub.router(), Instant::now()) {
                                Inbound::Done => continue,
                                Inbound::Refused => {
                                    let refusal = text(&ServerMsg::Error {
                                        message: "rate_limited".to_string(),
                                    });
                                    if let Message::Text(body) = refusal {
                                        let body = wrap_server_bytes(&body);
                                        if sink.send(Message::Text(body)).await.is_err() {
                                            break;
                                        }
                                    }
                                    continue;
                                }
                                Inbound::Close => {
                                    closing = Some(close_msg(1008, "over the rate limit"));
                                    break;
                                }
                                Inbound::Client(msg) => match serde_json::to_string(&msg) {
                                    Ok(b) => b,
                                    Err(_) => continue,
                                },
                            }
                        }
                    };
                    let mut framed = Vec::with_capacity(4 + body.len());
                    framed.extend_from_slice(&(body.len() as u32).to_be_bytes());
                    framed.extend_from_slice(body.as_bytes());
                    if bridge_wr.write_all(&framed).await.is_err() {
                        break;
                    }
                }
            }
            outbound = out_rx.recv() => {
                let Some(bytes) = outbound else {
                    // The handler is done (a clean exit, a refused role, or the device removed itself).
                    closing = Some(ended(&registry, &role_refused));
                    break;
                };
                let body = String::from_utf8_lossy(&bytes).into_owned();
                let body = if uplink.is_some() { wrap_server_bytes(&body) } else { body };
                if sink.send(Message::Text(body)).await.is_err() {
                    break;
                }
            }
            routed = next_request(&mut req_rx) => {
                let Some(frame) = routed else {
                    // The router let go of the channel: a newer uplink for the
                    // same host replaced this one, or this one is ending (the
                    // handler's last frames are still to be written).
                    req_rx = None;
                    let replaced = !role_refused.load(Ordering::SeqCst)
                        && satellite
                            .as_ref()
                            .is_some_and(|s| hub.router().is_connected(&s.name));
                    if replaced {
                        closing = Some(close_msg(1000, "replaced by a newer uplink"));
                        break;
                    }
                    continue;
                };
                let body = serde_json::to_string(&frame).unwrap_or_default();
                if sink.send(Message::Text(body)).await.is_err() {
                    break;
                }
            }
            changed = epoch.changed() => {
                if changed.is_err() {
                    break;
                }
                match registry.standing(&device_id) {
                    Some(DeviceStanding::Active) => {}
                    // The device removed itself: the handler says so, then closes.
                    Some(DeviceStanding::Revoked(RevokedBy::Device)) => {}
                    _ => {
                        let revoked = text(&ServerMsg::Unauthorized {
                            reason: "revoked".to_string(),
                        });
                        let revoked = match (&uplink, revoked) {
                            (Some(_), Message::Text(body)) => Message::Text(wrap_server_bytes(&body)),
                            (_, other) => other,
                        };
                        let _ = sink.send(revoked).await;
                        closing = Some(close_msg(CLOSE_UNAUTHORIZED, "unauthorized"));
                        break;
                    }
                }
                // `PeerTrust` is fixed after the `Hello`: a satellite whose level
                // changed reconnects and is admitted with the new one.
                if let Some(session) = &uplink {
                    let now = registry.satellite_info(&device_id).map(|r| r.admin);
                    if now.is_some_and(|level| level != session.snapshot) {
                        closing = Some(close_msg(1012, "level changed"));
                        break;
                    }
                }
            }
            _ = touch.tick() => registry.touch(&device_id),
            _ = &mut hello_deadline, if uplink.is_some() && !admitted.load(Ordering::SeqCst) => {
                closing = Some(close_msg(1008, "no hello"));
                break;
            }
        }
    }

    if let Some(close) = closing {
        let _ = sink.send(close).await;
    }
    let _ = sink.flush().await;
    let _ = sink.close().await;
    // End of the bridge: the handler reads EOF and cleans up.
    drop(bridge_wr);
    reader.abort();
    let _ = handler.await;
    info!(device = %device_id, "device disconnected");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limiter_allows_twenty_a_minute_per_ip_and_forgets() {
        let limiter = UpgradeLimiter::default();
        let a: IpAddr = "10.0.0.1".parse().unwrap();
        let b: IpAddr = "10.0.0.2".parse().unwrap();
        let t0 = Instant::now();
        for _ in 0..20 {
            assert!(limiter.allow(a, t0));
        }
        assert!(!limiter.allow(a, t0));
        assert!(limiter.allow(b, t0), "another address has its own budget");
        assert!(limiter.allow(a, t0 + Duration::from_secs(61)));
    }

    #[test]
    fn an_ipv6_address_is_limited_by_its_slash_64() {
        let limiter = UpgradeLimiter::new(2, Duration::from_secs(60));
        let a: IpAddr = "2001:db8:1:2::1".parse().unwrap();
        let same_64: IpAddr = "2001:db8:1:2:ffff::9".parse().unwrap();
        let other_64: IpAddr = "2001:db8:1:3::1".parse().unwrap();
        let t0 = Instant::now();
        assert!(limiter.allow(a, t0));
        assert!(limiter.allow(same_64, t0));
        assert!(!limiter.allow(a, t0), "the whole /64 shares one budget");
        assert!(limiter.allow(other_64, t0));
    }

    #[test]
    fn the_unauthenticated_slots_are_counted_per_slash_64_and_released() {
        let limits = WsLimits {
            max_unauthenticated: 10,
            max_unauthenticated_per_ip: 1,
            ..Default::default()
        };
        let slots = UnauthSlots::new(&limits);
        let a: IpAddr = "2001:db8:1:2::1".parse().unwrap();
        let same_64: IpAddr = "2001:db8:1:2::2".parse().unwrap();
        let held = slots.try_acquire(a).expect("the first");
        assert!(slots.try_acquire(same_64).is_none());
        drop(held);
        assert!(slots.try_acquire(same_64).is_some());
    }

    #[test]
    fn the_global_cap_alone_refuses_a_distinct_address_and_a_release_frees_it() {
        let limits = WsLimits {
            max_unauthenticated: 2,
            max_unauthenticated_per_ip: 2,
            ..Default::default()
        };
        let slots = UnauthSlots::new(&limits);
        let a: IpAddr = "10.0.0.1".parse().unwrap();
        let b: IpAddr = "10.0.0.2".parse().unwrap();
        let c: IpAddr = "10.0.0.3".parse().unwrap();
        let held_a = slots.try_acquire(a).expect("first");
        let _held_b = slots.try_acquire(b).expect("second");
        assert!(
            slots.try_acquire(c).is_none(),
            "no address is over its own cap"
        );
        drop(held_a);
        assert!(slots.try_acquire(c).is_some());
    }

    #[test]
    fn an_ipv4_mapped_ipv6_peer_is_limited_as_its_ipv4_address() {
        let limiter = UpgradeLimiter::new(1, Duration::from_secs(60));
        let v4: IpAddr = "10.0.0.7".parse().unwrap();
        let mapped: IpAddr = "::ffff:10.0.0.7".parse().unwrap();
        let other: IpAddr = "::ffff:10.0.0.8".parse().unwrap();
        let t0 = Instant::now();
        assert!(limiter.allow(v4, t0));
        assert!(
            !limiter.allow(mapped, t0),
            "the same peer under another spelling"
        );
        assert!(
            limiter.allow(other, t0),
            "mapped peers do not share one /64"
        );
    }

    #[test]
    fn the_bearer_header_is_read_and_a_query_string_is_ignored() {
        let req = |uri: &str, auth: Option<&str>| {
            let mut b = tokio_tungstenite::tungstenite::http::Request::builder().uri(uri);
            if let Some(a) = auth {
                b = b.header("Authorization", a);
            }
            b.body(()).unwrap()
        };
        assert_eq!(bearer(&req("/", Some("Bearer abc"))), Some("abc"));
        assert_eq!(bearer(&req("/", Some("bearer abc"))), Some("abc"));
        assert_eq!(bearer(&req("/", Some("Basic abc"))), None);
        assert_eq!(bearer(&req("/", Some("Bearer "))), None);
        assert_eq!(bearer(&req("/?token=abc", None)), None);
    }
}
