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
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, WebSocketConfig};
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{accept_hdr_async_with_config, WebSocketStream};
use tracing::{debug, info, warn};

use super::codec::read_frame;
use super::decisions::DecisionRegistry;
use super::device_hub::{ConnGuard, DeviceHub, HubSlot};
use super::devices::{DeviceStanding, RevokedBy, TokenCheck};
use super::protocol::{ClientMsg, ServerMsg, MAX_FRAME_LEN, MIN_CLIENT_VERSION, PROTOCOL_VERSION};
use super::server::{handle_client, HeldMotherJobs, PeerOrigin, RetainedCache};
use super::session_manager::SessionManager;
use crate::terminal::TerminalManager;

/// Advertised in `Welcome.features` on every transport.
pub const FEATURE_WS: &str = "ws";
pub const FEATURE_PAIR: &str = "pair";
pub const FEATURE_DEVICES: &str = "devices";

/// Close code for "this server refuses you" (revoked, unknown, not paired).
pub const CLOSE_UNAUTHORIZED: u16 = 4001;

/// How long a pairing-only socket may stay open.
const PAIRING_SOCKET_LIFETIME: Duration = Duration::from_secs(60);

/// Unauthenticated upgrades allowed per source IP per window.
const UPGRADE_LIMIT: usize = 20;
const UPGRADE_WINDOW: Duration = Duration::from_secs(60);

/// How often a connected device's `last_seen_at` is persisted.
const TOUCH_EVERY: Duration = Duration::from_secs(60);

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

fn too_many_requests() -> ErrorResponse {
    tokio_tungstenite::tungstenite::http::Response::builder()
        .status(429)
        .body(None)
        .expect("a static response")
}

pub(super) async fn accept_loop_ws(
    listener: TcpListener,
    hub: Arc<DeviceHub>,
    shared: WsShared,
) -> Result<()> {
    let shared = Arc::new(shared);
    let limiter = Arc::new(UpgradeLimiter::default());
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let (hub, shared, limiter) =
                    (Arc::clone(&hub), Arc::clone(&shared), Arc::clone(&limiter));
                tokio::spawn(async move {
                    if let Err(e) = serve(stream, addr.ip(), hub, shared, limiter).await {
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
    hub: Arc<DeviceHub>,
    shared: Arc<WsShared>,
    limiter: Arc<UpgradeLimiter>,
) -> Result<()> {
    let admission: Arc<Mutex<Option<Admission>>> = Arc::new(Mutex::new(None));
    let slot = Arc::clone(&admission);
    let registry = Arc::clone(hub.registry());
    #[allow(clippy::result_large_err)] // the callback's `ErrorResponse` is fixed by tungstenite
    let callback = move |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
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
        *slot.lock().unwrap() = Some(decided);
        Ok(resp)
    };
    let ws = accept_hdr_async_with_config(stream, callback, Some(ws_config())).await?;
    let admitted = admission.lock().unwrap().take();
    match admitted {
        Some(Admission::Paired(id)) => run_paired(ws, id, hub, shared).await,
        Some(Admission::PairingOnly) => run_pairing_only(ws, hub).await,
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

async fn run_pairing_only(mut ws: WebSocketStream<TcpStream>, hub: Arc<DeviceHub>) -> Result<()> {
    let deadline = tokio::time::Instant::now() + PAIRING_SOCKET_LIFETIME;
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next()).await;
        let frame = match next {
            Err(_) => {
                let _ = ws.send(close_msg(1000, "pairing window over")).await;
                return Ok(());
            }
            Ok(None) | Ok(Some(Err(_))) => return Ok(()),
            Ok(Some(Ok(frame))) => frame,
        };
        if let Some(close) = close_for_bad_frame(&frame) {
            let _ = ws.send(close).await;
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
            Ok(ClientMsg::PairCheck { code, proof }) => hub.pair_check(&code, proof.as_deref()),
            Ok(ClientMsg::Pair {
                code,
                name,
                kind,
                replace,
            }) => {
                let reply = hub.pair(&code, &name, kind, replace);
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

/// Serve an authenticated device: bridge the socket to `handle_client` through
/// an in-memory stream that carries the codec's length-prefixed frames, and
/// watch the registry so a revoke closes this socket at once.
async fn run_paired(
    ws: WebSocketStream<TcpStream>,
    device_id: String,
    hub: Arc<DeviceHub>,
    shared: Arc<WsShared>,
) -> Result<()> {
    let _conn: ConnGuard = hub.connected(&device_id);
    info!(device = %device_id, "device connected");
    let registry = Arc::clone(hub.registry());
    let mut epoch = registry.subscribe_epoch();
    epoch.borrow_and_update();
    // Revoked between the upgrade and now.
    if !matches!(registry.standing(&device_id), Some(DeviceStanding::Active)) {
        reject(ws, "revoked").await;
        return Ok(());
    }

    let (server_side, bridge_side) = tokio::io::duplex(256 * 1024);
    let (mut bridge_rd, mut bridge_wr) = tokio::io::split(bridge_side);
    let (mut sink, mut stream) = ws.split();

    let handler = tokio::spawn(handle_client(
        server_side,
        PeerOrigin::Ws {
            device_id: device_id.clone(),
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
                    // The handler is done (a clean exit, or the device removed itself).
                    closing = Some(match registry.standing(&device_id) {
                        Some(DeviceStanding::Revoked(_)) | None => {
                            close_msg(CLOSE_UNAUTHORIZED, "unauthorized")
                        }
                        Some(DeviceStanding::Active) => close_msg(1000, "bye"),
                    });
                    break;
                };
                let body = String::from_utf8_lossy(&bytes).into_owned();
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
                        let _ = sink.send(text(&ServerMsg::Unauthorized {
                            reason: "revoked".to_string(),
                        })).await;
                        closing = Some(close_msg(CLOSE_UNAUTHORIZED, "unauthorized"));
                        break;
                    }
                }
            }
            _ = touch.tick() => registry.touch(&device_id),
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
