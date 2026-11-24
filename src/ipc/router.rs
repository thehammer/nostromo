//! The primary's side of satellite mode: which satellites are connected, what
//! the primary accepts from them, and the reads it routes down to them.
//!
//! The primary treats a satellite as possibly compromised. Everything here is
//! enforced on the primary and does not rely on the satellite's own filters:
//!
//! * [`ingest_from_satellite`] is the only path from a satellite's `publish`
//!   frame to the primary's broadcast channel. A frame is admitted only when
//!   it is one of the host-carrying variants, its `host` is exactly the
//!   record's name, it is never one of the administrative or local-only
//!   variants, and it has the shape its egress profile allows.
//! * [`Router::route`] forwards only the six read verbs, only to a `personal`
//!   satellite, under an opaque request id the satellite cannot choose.
//! * [`Router::accept_routed_reply`] takes a satellite's answer only for an
//!   outstanding id issued to that same host, with a variant the verb allows,
//!   and delivers it to the requesting connection alone.
//!
//! Nothing here logs frame content.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use tokio::sync::{broadcast, mpsc::UnboundedSender};
use tracing::{debug, warn};

use super::devices::Egress;
use super::peer::{
    classify_server_msg, is_uplink_metadata_shape, outbound, PeerTrust, SensitiveTags, ServerClass,
};
use super::protocol::{ClientMsg, HostInfo, HostUnavailableReason, ServerMsg};
use super::uplink_wire::UplinkFrame;

/// Outstanding routed requests one requesting connection may hold. Smaller than
/// the per-host cap so one connection cannot take all of a host's slots.
pub const MAX_OUTSTANDING_PER_REQUESTER: usize = 8;
/// Outstanding routed requests one host may hold, across requesters.
pub const MAX_OUTSTANDING_PER_HOST: usize = 32;
/// How long a single-answer request waits for its reply.
const SINGLE_ANSWER_TTL: Duration = Duration::from_secs(10);

// ── what a satellite is, as the primary knows it ──────────────────────────────

/// The registry record behind an uplink: the primary's own view, never what
/// the `Hello` claimed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SatelliteRecord {
    pub name: String,
    pub egress: Egress,
}

// ── the six routable read verbs ───────────────────────────────────────────────

/// A read the primary may route to a satellite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    SessionList,
    FocusList,
    SessionModelGet,
    ActivitySnapshot,
    SessionAttach,
    SessionDetach,
}

fn verb_of(msg: &ClientMsg) -> Option<Verb> {
    Some(match msg {
        ClientMsg::SessionList { .. } => Verb::SessionList,
        ClientMsg::FocusList { .. } => Verb::FocusList,
        ClientMsg::SessionModelGet { .. } => Verb::SessionModelGet,
        ClientMsg::ActivitySnapshotRequest { .. } => Verb::ActivitySnapshot,
        ClientMsg::SessionAttach { .. } => Verb::SessionAttach,
        ClientMsg::SessionDetach { .. } => Verb::SessionDetach,
        _ => return None,
    })
}

/// The host a routable read names, or `None` for this daemon (and for every
/// other message).
pub fn client_host(msg: &ClientMsg) -> Option<&str> {
    match msg {
        ClientMsg::SessionList { host }
        | ClientMsg::FocusList { host }
        | ClientMsg::SessionModelGet { host, .. }
        | ClientMsg::ActivitySnapshotRequest { host, .. }
        | ClientMsg::SessionAttach { host, .. }
        | ClientMsg::SessionDetach { host, .. } => host.as_deref(),
        _ => None,
    }
}

fn without_host(msg: ClientMsg) -> ClientMsg {
    match msg {
        ClientMsg::SessionList { .. } => ClientMsg::SessionList { host: None },
        ClientMsg::FocusList { .. } => ClientMsg::FocusList { host: None },
        ClientMsg::SessionModelGet { tag, .. } => ClientMsg::SessionModelGet { tag, host: None },
        ClientMsg::ActivitySnapshotRequest { tag, .. } => {
            ClientMsg::ActivitySnapshotRequest { tag, host: None }
        }
        ClientMsg::SessionAttach { tag, .. } => ClientMsg::SessionAttach { tag, host: None },
        ClientMsg::SessionDetach { tag, .. } => ClientMsg::SessionDetach { tag, host: None },
        other => other,
    }
}

fn tag_of(msg: &ClientMsg) -> Option<&str> {
    match msg {
        ClientMsg::SessionModelGet { tag, .. }
        | ClientMsg::ActivitySnapshotRequest { tag, .. }
        | ClientMsg::SessionAttach { tag, .. }
        | ClientMsg::SessionDetach { tag, .. } => Some(tag),
        _ => None,
    }
}

// ── the `host` field on a ServerMsg ───────────────────────────────────────────

/// `Some(host)` when the variant carries a `host` field (the inner `Option` is
/// that field's value), `None` when it has none. The variants that have one
/// are exactly the ones a satellite may publish.
pub fn server_msg_host(msg: &ServerMsg) -> Option<Option<&str>> {
    Some(match msg {
        ServerMsg::MotherJobs { host, .. }
        | ServerMsg::PerriState { host, .. }
        | ServerMsg::SessionState { host, .. }
        | ServerMsg::SessionBridge { host, .. }
        | ServerMsg::SessionListResp { host, .. }
        | ServerMsg::FocusListResp { host, .. }
        | ServerMsg::FocusRegistryUpdated { host, .. }
        | ServerMsg::FocusCreated { host, .. }
        | ServerMsg::DecisionRequest { host, .. }
        | ServerMsg::DecisionResolved { host, .. }
        | ServerMsg::ApprovalPending { host, .. }
        | ServerMsg::TrackerSummary { host, .. } => host.as_deref(),
        ServerMsg::MotherStatusline(status) => status.host.as_deref(),
        ServerMsg::Activity(event) => event.host.as_deref(),
        _ => return None,
    })
}

fn msg_type(msg: &ServerMsg) -> String {
    serde_json::to_value(msg)
        .ok()
        .and_then(|v| v.get("type").and_then(|t| t.as_str().map(String::from)))
        .unwrap_or_else(|| "unknown".to_string())
}

/// Variants that never come from a satellite, whatever its egress, named so a
/// later `host` field on one of them cannot open it.
const NEVER_FROM_SATELLITE: &[&str] = &[
    "hosts",
    "host_unavailable",
    "welcome",
    "pong",
    "error",
    "mother_peek",
    "mother_await_detected",
    "pair_offer",
    "paired",
    "pair_refused",
    "unauthorized",
    "device_unpaired",
];

/// The administrative classes and the named list. `allow_refusals` lets the
/// two refusal frames through (a routed read refused on the satellite).
fn never_from_satellite(msg: &ServerMsg, allow_refusals: bool) -> bool {
    if matches!(
        classify_server_msg(msg),
        ServerClass::LocalOnly | ServerClass::Admin | ServerClass::SatelliteControl
    ) {
        return true;
    }
    if allow_refusals && matches!(msg, ServerMsg::Error { .. } | ServerMsg::Withheld { .. }) {
        return false;
    }
    NEVER_FROM_SATELLITE.contains(&msg_type(msg).as_str())
}

fn unchanged_by_tcp_outbound(msg: &ServerMsg, tags: &SensitiveTags) -> bool {
    let Some(after) = outbound(PeerTrust::Tcp, msg.clone(), tags) else {
        return false;
    };
    match (serde_json::to_value(msg), serde_json::to_value(&after)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

// ── ingest ────────────────────────────────────────────────────────────────────

/// Why a published frame was not admitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IngestDrop {
    /// Not one of the host-carrying variants.
    NotHostCarrying,
    /// An administrative, local-only or bookkeeping variant.
    NeverFromSatellite,
    /// The `host` is not exactly the record's name (absent included).
    WrongHost,
    /// A `work` satellite's frame is not in the metadata shape.
    Shape,
    /// A `personal` satellite's frame would be changed by the network filter.
    Egress,
}

/// The one path from a satellite's `publish` frame to the primary's broadcast
/// channel. `Ok` is the frame to broadcast; it is the frame the satellite sent
/// (the primary never rewrites it, so what it forwards is what it checked).
pub fn ingest_from_satellite(
    record: &SatelliteRecord,
    msg: ServerMsg,
    tags: &SensitiveTags,
) -> Result<ServerMsg, IngestDrop> {
    // Step 2 first: a named administrative frame is reported as that, even if
    // a later `host` field opens it.
    if never_from_satellite(&msg, false) {
        return Err(IngestDrop::NeverFromSatellite);
    }
    // Step 1: only the host-carrying variants, and the host is the record's.
    match server_msg_host(&msg) {
        None => return Err(IngestDrop::NotHostCarrying),
        Some(Some(h)) if h == record.name => {}
        Some(_) => return Err(IngestDrop::WrongHost),
    }
    // Step 3: the shape the record's egress allows.
    match record.egress {
        Egress::Work => {
            if !is_uplink_metadata_shape(&msg) {
                return Err(IngestDrop::Shape);
            }
        }
        Egress::Personal => {
            if !unchanged_by_tcp_outbound(&msg, tags) {
                return Err(IngestDrop::Egress);
            }
        }
    }
    Ok(msg)
}

// ── replies ───────────────────────────────────────────────────────────────────

/// May `msg` answer a routed `verb`? What `handle_client_msg` sends for the
/// verb, plus the two refusals (so a refused read reaches the requester).
pub fn reply_allowed(verb: Verb, msg: &ServerMsg) -> bool {
    if matches!(msg, ServerMsg::Error { .. } | ServerMsg::Withheld { .. }) {
        return true;
    }
    match verb {
        Verb::SessionList => matches!(msg, ServerMsg::SessionListResp { .. }),
        Verb::FocusList => matches!(msg, ServerMsg::FocusListResp { .. }),
        Verb::SessionModelGet => matches!(msg, ServerMsg::SessionModelState(_)),
        Verb::ActivitySnapshot => matches!(msg, ServerMsg::ActivitySnapshot { .. }),
        Verb::SessionAttach => matches!(
            msg,
            ServerMsg::SessionTurns { .. }
                | ServerMsg::SessionTurnDelta { .. }
                | ServerMsg::SessionTurnOrigin { .. }
                | ServerMsg::SessionState { .. }
                | ServerMsg::SessionBridge { .. }
                | ServerMsg::PaneContent { .. }
        ),
        Verb::SessionDetach => false,
    }
}

/// Why a routed reply was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyDrop {
    UnknownId,
    Expired,
    /// The id was issued for a request routed to another host.
    ForeignHost,
    /// A `work` satellite never holds an id.
    WorkHost,
    WrongVariant,
    WrongHostField,
    Egress,
}

// ── flood control ─────────────────────────────────────────────────────────────

/// What the rate limit says about one frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Drop,
    /// Over the limit for the whole sustain window: close the connection.
    Close,
}

/// A token bucket that also notices a sender that stays over its limit.
#[derive(Debug)]
pub struct Bucket {
    rate: f64,
    burst: f64,
    tokens: f64,
    last: Instant,
    over_since: Option<Instant>,
    sustain: Duration,
}

impl Bucket {
    pub fn new(rate: f64, burst: f64, sustain: Duration, now: Instant) -> Self {
        Self {
            rate,
            burst,
            tokens: burst,
            last: now,
            over_since: None,
            sustain,
        }
    }

    pub fn take(&mut self, now: Instant) -> Verdict {
        let elapsed = now.saturating_duration_since(self.last).as_secs_f64();
        self.last = now;
        self.tokens = (self.tokens + elapsed * self.rate).min(self.burst);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            if self.tokens > self.burst / 2.0 {
                self.over_since = None;
            }
            return Verdict::Allow;
        }
        let since = *self.over_since.get_or_insert(now);
        if now.saturating_duration_since(since) >= self.sustain {
            Verdict::Close
        } else {
            Verdict::Drop
        }
    }
}

/// The limits on one uplink connection.
#[derive(Debug, Clone)]
pub struct UplinkLimits {
    /// `publish` frames per second, and the burst.
    pub publish_rate: f64,
    pub publish_burst: f64,
    /// A `publish` frame over this many bytes is dropped.
    pub max_publish_bytes: usize,
    /// `reply` frames per second, and the burst.
    pub reply_rate: f64,
    pub reply_burst: f64,
    /// How long over the limit, in a row, closes the uplink with 1008.
    pub sustain: Duration,
}

impl Default for UplinkLimits {
    fn default() -> Self {
        Self {
            publish_rate: 50.0,
            publish_burst: 200.0,
            max_publish_bytes: 256 * 1024,
            reply_rate: 200.0,
            reply_burst: 400.0,
            sustain: Duration::from_secs(30),
        }
    }
}

// ── the host table and the outstanding-request table ─────────────────────────

struct Uplink {
    conn_id: u64,
    egress: Egress,
    connected_since: DateTime<Utc>,
    last_seen: DateTime<Utc>,
    tx: UnboundedSender<UplinkFrame>,
}

struct Outstanding {
    requester: UnboundedSender<ServerMsg>,
    conn_key: String,
    host: String,
    verb: Verb,
    tag: Option<String>,
    /// `None` for a `SessionAttach`, which lives until it is detached.
    expires: Option<Instant>,
}

#[derive(Default)]
struct Inner {
    hosts: HashMap<String, Uplink>,
    out: HashMap<String, Outstanding>,
}

/// What the router did with a read that names a host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Routed {
    Sent,
    Unavailable(HostUnavailableReason),
    /// Not one of the six verbs: not the router's to handle.
    NotRoutable,
}

/// Counts of what the primary refused from satellites (never content).
#[derive(Default)]
pub struct DropCounts {
    pub publish: AtomicU64,
    pub reply: AtomicU64,
    pub junk: AtomicU64,
    pub oversize: AtomicU64,
}

#[derive(Default)]
pub struct Router {
    inner: Mutex<Inner>,
    tx: OnceLock<broadcast::Sender<ServerMsg>>,
    next_conn: AtomicU64,
    pub drops: DropCounts,
    /// One WARN per (host, variant) per hour.
    warned: Mutex<HashMap<(String, String), Instant>>,
}

impl Router {
    pub fn new() -> Self {
        Self::default()
    }

    /// Where `Hosts` frames are broadcast. The first call wins.
    pub fn set_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        let _ = self.tx.set(tx);
    }

    /// Record an admitted uplink under the record's `name`. A second uplink
    /// for the same host replaces the first (whose request channel closes).
    /// Returns the connection id to hand back to [`Router::unregister`].
    pub fn register(
        &self,
        name: &str,
        egress: Egress,
        tx: UnboundedSender<UplinkFrame>,
    ) -> u64 {
        let conn_id = self.next_conn.fetch_add(1, Ordering::Relaxed) + 1;
        let now = Utc::now();
        {
            let mut inner = self.inner.lock().unwrap();
            inner.out.retain(|_, o| o.host != name);
            inner.hosts.insert(
                name.to_string(),
                Uplink {
                    conn_id,
                    egress,
                    connected_since: now,
                    last_seen: now,
                    tx,
                },
            );
        }
        self.broadcast_hosts();
        conn_id
    }

    /// The uplink `conn_id` of `name` ended. A newer uplink for the same host
    /// is left alone.
    pub fn unregister(&self, name: &str, conn_id: u64) {
        let removed = {
            let mut inner = self.inner.lock().unwrap();
            if inner.hosts.get(name).is_some_and(|u| u.conn_id == conn_id) {
                inner.hosts.remove(name);
                inner.out.retain(|_, o| o.host != name);
                true
            } else {
                false
            }
        };
        if removed {
            self.broadcast_hosts();
        }
    }

    /// Note a frame from `name` (for `Hosts.last_seen`).
    pub fn touch(&self, name: &str) {
        if let Some(u) = self.inner.lock().unwrap().hosts.get_mut(name) {
            u.last_seen = Utc::now();
        }
    }

    pub fn hosts_msg(&self) -> ServerMsg {
        let inner = self.inner.lock().unwrap();
        let mut hosts: Vec<HostInfo> = inner
            .hosts
            .iter()
            .map(|(name, u)| HostInfo {
                name: name.clone(),
                egress: u.egress,
                connected_since: u.connected_since,
                last_seen: u.last_seen,
            })
            .collect();
        hosts.sort_by(|a, b| a.name.cmp(&b.name));
        ServerMsg::Hosts { hosts }
    }

    fn broadcast_hosts(&self) {
        if let Some(tx) = self.tx.get() {
            let _ = tx.send(self.hosts_msg());
        }
    }

    pub fn is_connected(&self, name: &str) -> bool {
        self.inner.lock().unwrap().hosts.contains_key(name)
    }

    /// Routed requests currently outstanding (all hosts).
    pub fn outstanding(&self) -> usize {
        self.inner.lock().unwrap().out.len()
    }

    /// Route a read that names `host`. `requester` is the targeted sender of
    /// the connection that asked; the answer goes there and nowhere else.
    pub fn route(
        &self,
        host: &str,
        msg: ClientMsg,
        requester: &UnboundedSender<ServerMsg>,
        conn_key: &str,
        now: Instant,
    ) -> Routed {
        let Some(verb) = verb_of(&msg) else {
            return Routed::NotRoutable;
        };
        let tag = tag_of(&msg).map(String::from);
        let mut inner = self.inner.lock().unwrap();
        // Forget what has waited too long before counting.
        inner
            .out
            .retain(|_, o| o.expires.is_none_or(|due| due > now));
        let Some(uplink) = inner.hosts.get(host) else {
            return Routed::Unavailable(HostUnavailableReason::NotConnected);
        };
        // A `work` satellite publishes metadata only: nothing is routed to it.
        if uplink.egress == Egress::Work {
            return Routed::Unavailable(HostUnavailableReason::EgressMetadata);
        }
        let host_tx = uplink.tx.clone();
        let find_attach = |inner: &Inner| {
            inner
                .out
                .iter()
                .find(|(_, o)| {
                    o.verb == Verb::SessionAttach
                        && o.conn_key == conn_key
                        && o.host == host
                        && o.tag == tag
                })
                .map(|(id, _)| id.clone())
        };

        if verb == Verb::SessionDetach {
            if let Some(id) = find_attach(&inner) {
                inner.out.remove(&id);
                let _ = host_tx.send(UplinkFrame::Request {
                    id,
                    msg: without_host(msg),
                });
            }
            return Routed::Sent;
        }

        // Re-attaching the same tag reuses the id (and its slot).
        let id = match (verb, find_attach(&inner)) {
            (Verb::SessionAttach, Some(existing)) => existing,
            _ => {
                let by_requester = inner
                    .out
                    .values()
                    .filter(|o| o.conn_key == conn_key)
                    .count();
                let by_host = inner.out.values().filter(|o| o.host == host).count();
                if by_requester >= MAX_OUTSTANDING_PER_REQUESTER
                    || by_host >= MAX_OUTSTANDING_PER_HOST
                {
                    return Routed::Unavailable(HostUnavailableReason::Busy);
                }
                let id = new_request_id();
                inner.out.insert(
                    id.clone(),
                    Outstanding {
                        requester: requester.clone(),
                        conn_key: conn_key.to_string(),
                        host: host.to_string(),
                        verb,
                        tag,
                        expires: (verb != Verb::SessionAttach).then(|| now + SINGLE_ANSWER_TTL),
                    },
                );
                id
            }
        };
        if host_tx
            .send(UplinkFrame::Request {
                id: id.clone(),
                msg: without_host(msg),
            })
            .is_err()
        {
            inner.out.remove(&id);
            return Routed::Unavailable(HostUnavailableReason::NotConnected);
        }
        Routed::Sent
    }

    /// The connection `conn_key` is gone: drop what it was waiting for and tell
    /// each satellite it held an attach on to detach.
    pub fn drop_requester(&self, conn_key: &str) {
        let mut inner = self.inner.lock().unwrap();
        let ids: Vec<String> = inner
            .out
            .iter()
            .filter(|(_, o)| o.conn_key == conn_key)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let Some(o) = inner.out.remove(&id) else {
                continue;
            };
            if o.verb == Verb::SessionAttach {
                if let (Some(tag), Some(up)) = (o.tag, inner.hosts.get(&o.host)) {
                    let _ = up.tx.send(UplinkFrame::Request {
                        id,
                        msg: ClientMsg::SessionDetach { tag, host: None },
                    });
                }
            }
        }
    }

    /// A `reply` frame from `record`'s uplink. `Ok` means it was delivered to
    /// the requesting connection; anything else is dropped.
    pub fn accept_routed_reply(
        &self,
        record: &SatelliteRecord,
        id: &str,
        msg: ServerMsg,
        tags: &SensitiveTags,
        now: Instant,
    ) -> Result<(), ReplyDrop> {
        let (requester, retire) = {
            let mut inner = self.inner.lock().unwrap();
            let Some(entry) = inner.out.get(id) else {
                return Err(ReplyDrop::UnknownId);
            };
            if entry.host != record.name {
                return Err(ReplyDrop::ForeignHost);
            }
            if entry.expires.is_some_and(|due| due <= now) {
                inner.out.remove(id);
                return Err(ReplyDrop::Expired);
            }
            if record.egress != Egress::Personal {
                return Err(ReplyDrop::WorkHost);
            }
            if !reply_allowed(entry.verb, &msg) || never_from_satellite(&msg, true) {
                return Err(ReplyDrop::WrongVariant);
            }
            if let Some(h) = server_msg_host(&msg) {
                if h != Some(record.name.as_str()) {
                    return Err(ReplyDrop::WrongHostField);
                }
            }
            if !unchanged_by_tcp_outbound(&msg, tags) {
                return Err(ReplyDrop::Egress);
            }
            let refusal = matches!(msg, ServerMsg::Error { .. } | ServerMsg::Withheld { .. });
            let single = entry.verb != Verb::SessionAttach;
            (entry.requester.clone(), refusal || single)
        };
        let delivered = requester.send(msg).is_ok();
        if retire || !delivered {
            self.inner.lock().unwrap().out.remove(id);
        }
        Ok(())
    }

    /// Count a drop and warn once per (host, variant) per hour.
    pub fn note_drop(&self, host: &str, variant: &str, why: &str) {
        debug!(host, variant, why, "uplink frame dropped");
        let key = (host.to_string(), variant.to_string());
        let mut warned = self.warned.lock().unwrap();
        let due = warned
            .get(&key)
            .is_none_or(|at| at.elapsed() >= Duration::from_secs(3600));
        if due {
            warned.insert(key, Instant::now());
            warn!(host, variant, why, "a satellite sent a frame the primary does not accept");
        }
    }

    /// The `type` tag of a frame, for [`Router::note_drop`].
    pub fn variant_of(msg: &ServerMsg) -> String {
        msg_type(msg)
    }
}

fn new_request_id() -> String {
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc::unbounded_channel;

    fn rec(name: &str, egress: Egress) -> SatelliteRecord {
        SatelliteRecord {
            name: name.into(),
            egress,
        }
    }

    fn attach(tag: &str, host: &str) -> ClientMsg {
        ClientMsg::SessionAttach {
            tag: tag.into(),
            host: Some(host.into()),
        }
    }

    #[test]
    fn a_bucket_allows_a_burst_then_drops_then_closes_a_sustained_flood() {
        let t0 = Instant::now();
        let mut b = Bucket::new(50.0, 200.0, Duration::from_secs(30), t0);
        let allowed = (0..1000).filter(|_| b.take(t0) == Verdict::Allow).count();
        assert_eq!(allowed, 200);
        assert_eq!(b.take(t0), Verdict::Drop);
        // Still flooding 31 s later: closed.
        let mut now = t0;
        let mut last = Verdict::Drop;
        for _ in 0..31 * 100 {
            now += Duration::from_millis(10);
            last = b.take(now);
            if last == Verdict::Close {
                break;
            }
        }
        // 100 frames a second is over the 50/s rate, so it never recovers.
        assert_eq!(last, Verdict::Close);
    }

    #[test]
    fn a_bucket_forgets_a_burst_after_a_calm_spell() {
        let t0 = Instant::now();
        let mut b = Bucket::new(50.0, 200.0, Duration::from_secs(30), t0);
        for _ in 0..300 {
            b.take(t0);
        }
        let later = t0 + Duration::from_secs(10);
        assert_eq!(b.take(later), Verdict::Allow);
        assert_eq!(b.take(later + Duration::from_secs(1)), Verdict::Allow);
    }

    #[test]
    fn route_refuses_unknown_and_work_hosts_and_sends_to_a_personal_one() {
        let router = Router::new();
        let (req_tx, _req_rx) = unbounded_channel();
        let now = Instant::now();
        assert_eq!(
            router.route("nope", attach("t", "nope"), &req_tx, "c1", now),
            Routed::Unavailable(HostUnavailableReason::NotConnected)
        );
        let (work_tx, mut work_rx) = unbounded_channel();
        let (pers_tx, mut pers_rx) = unbounded_channel();
        router.register("kobe", Egress::Work, work_tx);
        router.register("sendai", Egress::Personal, pers_tx);
        assert_eq!(
            router.route("kobe", attach("t", "kobe"), &req_tx, "c1", now),
            Routed::Unavailable(HostUnavailableReason::EgressMetadata)
        );
        assert!(work_rx.try_recv().is_err(), "nothing reached a work host");
        assert_eq!(
            router.route("sendai", attach("t", "sendai"), &req_tx, "c1", now),
            Routed::Sent
        );
        match pers_rx.try_recv().unwrap() {
            UplinkFrame::Request { id, msg } => {
                assert!(!id.is_empty());
                assert_eq!(client_host(&msg), None, "the host is stripped");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn caps_are_eight_per_requester_and_thirty_two_per_host() {
        let router = Router::new();
        let (host_tx, mut host_rx) = unbounded_channel();
        router.register("sendai", Egress::Personal, host_tx);
        let now = Instant::now();
        let (r1, _r1rx) = unbounded_channel();
        for i in 0..MAX_OUTSTANDING_PER_REQUESTER {
            assert_eq!(
                router.route("sendai", attach(&format!("t{i}"), "sendai"), &r1, "c1", now),
                Routed::Sent
            );
        }
        assert_eq!(
            router.route("sendai", attach("one-more", "sendai"), &r1, "c1", now),
            Routed::Unavailable(HostUnavailableReason::Busy)
        );
        // Other requesters still have room, until the host's 32 are used.
        let mut sent = MAX_OUTSTANDING_PER_REQUESTER;
        let mut n = 0;
        while sent < MAX_OUTSTANDING_PER_HOST {
            let (r, _rx) = unbounded_channel();
            for i in 0..MAX_OUTSTANDING_PER_REQUESTER {
                if sent >= MAX_OUTSTANDING_PER_HOST {
                    break;
                }
                assert_eq!(
                    router.route(
                        "sendai",
                        attach(&format!("u{i}"), "sendai"),
                        &r,
                        &format!("c-other-{n}"),
                        now
                    ),
                    Routed::Sent
                );
                sent += 1;
            }
            n += 1;
        }
        let (r, _rx) = unbounded_channel();
        assert_eq!(
            router.route("sendai", attach("late", "sendai"), &r, "c-late", now),
            Routed::Unavailable(HostUnavailableReason::Busy),
            "the 33rd outstanding id for the host"
        );
        let mut requests = 0;
        while host_rx.try_recv().is_ok() {
            requests += 1;
        }
        assert_eq!(requests, MAX_OUTSTANDING_PER_HOST, "no 33rd request went down");
    }

    #[test]
    fn one_requester_cannot_take_all_of_a_hosts_slots() {
        const { assert!(MAX_OUTSTANDING_PER_REQUESTER < MAX_OUTSTANDING_PER_HOST) };
    }

    fn issue(router: &Router, verb_msg: ClientMsg, host: &str) -> (String, UnboundedSender<ServerMsg>, tokio::sync::mpsc::UnboundedReceiver<ServerMsg>) {
        let (tx, rx) = unbounded_channel();
        assert_eq!(
            router.route(host, verb_msg, &tx, "c1", Instant::now()),
            Routed::Sent
        );
        let id = router.inner.lock().unwrap().out.keys().next().unwrap().clone();
        (id, tx, rx)
    }

    #[test]
    fn a_reply_is_accepted_only_for_the_issued_id_host_and_variant() {
        let router = Router::new();
        let (host_tx, _host_rx) = unbounded_channel();
        router.register("sendai", Egress::Personal, host_tx);
        let tags = SensitiveTags::default();
        let (id, _tx, mut rx) = issue(
            &router,
            ClientMsg::SessionList {
                host: Some("sendai".into()),
            },
            "sendai",
        );
        let list = |host: Option<&str>| ServerMsg::SessionListResp {
            sessions: vec![],
            host: host.map(String::from),
        };
        let now = Instant::now();
        let sendai = rec("sendai", Egress::Personal);
        // Unknown id.
        assert_eq!(
            router.accept_routed_reply(&sendai, "nope", list(Some("sendai")), &tags, now),
            Err(ReplyDrop::UnknownId)
        );
        // Another host's uplink.
        assert_eq!(
            router.accept_routed_reply(&rec("kobe", Egress::Personal), &id, list(Some("kobe")), &tags, now),
            Err(ReplyDrop::ForeignHost)
        );
        // Wrong variant for the verb.
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, ServerMsg::Pong, &tags, now),
            Err(ReplyDrop::WrongVariant)
        );
        assert_eq!(
            router.accept_routed_reply(
                &sendai,
                &id,
                ServerMsg::Devices { devices: vec![], hosts: vec![] },
                &tags,
                now
            ),
            Err(ReplyDrop::WrongVariant)
        );
        // A host field that is not the record's.
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, list(Some("kobe")), &tags, now),
            Err(ReplyDrop::WrongHostField)
        );
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, list(None), &tags, now),
            Err(ReplyDrop::WrongHostField)
        );
        assert!(rx.try_recv().is_err(), "nothing was delivered so far");
        // The honest reply reaches the requester, and retires the id.
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, list(Some("sendai")), &tags, now),
            Ok(())
        );
        assert!(matches!(rx.try_recv(), Ok(ServerMsg::SessionListResp { .. })));
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, list(Some("sendai")), &tags, now),
            Err(ReplyDrop::UnknownId),
            "a single-answer id is spent"
        );
    }

    #[test]
    fn an_expired_id_is_refused() {
        let router = Router::new();
        let (host_tx, _host_rx) = unbounded_channel();
        router.register("sendai", Egress::Personal, host_tx);
        let tags = SensitiveTags::default();
        let (id, _tx, _rx) = issue(
            &router,
            ClientMsg::SessionList {
                host: Some("sendai".into()),
            },
            "sendai",
        );
        let later = Instant::now() + Duration::from_secs(11);
        assert_eq!(
            router.accept_routed_reply(
                &rec("sendai", Egress::Personal),
                &id,
                ServerMsg::SessionListResp { sessions: vec![], host: Some("sendai".into()) },
                &tags,
                later
            ),
            Err(ReplyDrop::Expired)
        );
    }

    #[test]
    fn a_work_record_never_has_a_reply_accepted() {
        let router = Router::new();
        let (host_tx, _host_rx) = unbounded_channel();
        router.register("sendai", Egress::Personal, host_tx);
        let tags = SensitiveTags::default();
        let (id, _tx, _rx) = issue(
            &router,
            ClientMsg::SessionList {
                host: Some("sendai".into()),
            },
            "sendai",
        );
        assert_eq!(
            router.accept_routed_reply(
                &rec("sendai", Egress::Work),
                &id,
                ServerMsg::SessionListResp { sessions: vec![], host: Some("sendai".into()) },
                &tags,
                Instant::now()
            ),
            Err(ReplyDrop::WorkHost)
        );
    }

    #[test]
    fn an_attach_id_stays_live_for_deltas_until_detached() {
        let router = Router::new();
        let (host_tx, mut host_rx) = unbounded_channel();
        router.register("sendai", Egress::Personal, host_tx);
        let tags = SensitiveTags::default();
        let (id, tx, mut rx) = issue(&router, attach("cody-1", "sendai"), "sendai");
        let sendai = rec("sendai", Egress::Personal);
        let state = |s: &str| ServerMsg::SessionState {
            tag: "cody-1".into(),
            state: if s == "idle" {
                crate::ipc::stream_json::SessionState::Idle
            } else {
                crate::ipc::stream_json::SessionState::MidTurn
            },
            host: Some("sendai".into()),
        };
        for _ in 0..3 {
            assert_eq!(
                router.accept_routed_reply(&sendai, &id, state("idle"), &tags, Instant::now()),
                Ok(())
            );
        }
        assert_eq!(rx.try_recv().is_ok(), true);
        // A refusal retires it.
        assert_eq!(
            router.accept_routed_reply(
                &sendai,
                &id,
                ServerMsg::Error { message: "no".into() },
                &tags,
                Instant::now()
            ),
            Ok(())
        );
        assert_eq!(
            router.accept_routed_reply(&sendai, &id, state("idle"), &tags, Instant::now()),
            Err(ReplyDrop::UnknownId)
        );
        // Re-attach, then the requester going away detaches on the host.
        while host_rx.try_recv().is_ok() {}
        assert_eq!(
            router.route("sendai", attach("cody-1", "sendai"), &tx, "c1", Instant::now()),
            Routed::Sent
        );
        while host_rx.try_recv().is_ok() {}
        router.drop_requester("c1");
        match host_rx.try_recv().unwrap() {
            UplinkFrame::Request { msg: ClientMsg::SessionDetach { tag, .. }, .. } => {
                assert_eq!(tag, "cody-1")
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(router.outstanding(), 0);
    }

    #[test]
    fn an_uplink_ending_drops_its_ids_and_a_newer_uplink_survives() {
        let router = Router::new();
        let (a_tx, _a) = unbounded_channel();
        let first = router.register("sendai", Egress::Personal, a_tx);
        let (b_tx, _b) = unbounded_channel();
        let second = router.register("sendai", Egress::Personal, b_tx);
        router.unregister("sendai", first);
        assert!(router.is_connected("sendai"), "the newer uplink stays");
        router.unregister("sendai", second);
        assert!(!router.is_connected("sendai"));
        match router.hosts_msg() {
            ServerMsg::Hosts { hosts } => assert!(hosts.is_empty()),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_satellite_can_name_nothing_but_the_records_host() {
        let tags = SensitiveTags::default();
        let kobe = rec("kobe", Egress::Personal);
        let jobs = |host: Option<&str>| ServerMsg::MotherJobs {
            jobs: vec![],
            host: host.map(String::from),
        };
        assert!(ingest_from_satellite(&kobe, jobs(Some("kobe")), &tags).is_ok());
        for host in [Some("sendai"), None, Some("KOBE")] {
            assert_eq!(
                ingest_from_satellite(&kobe, jobs(host), &tags).unwrap_err(),
                IngestDrop::WrongHost,
                "{host:?}"
            );
        }
    }

    #[test]
    fn administrative_and_host_less_frames_are_never_ingested() {
        let tags = SensitiveTags::default();
        for egress in [Egress::Work, Egress::Personal] {
            let kobe = rec("kobe", egress);
            for msg in [
                ServerMsg::Devices { devices: vec![], hosts: vec![] },
                ServerMsg::Hosts { hosts: vec![] },
                ServerMsg::Pong,
                ServerMsg::Error { message: "x".into() },
                ServerMsg::DeviceUnpaired,
            ] {
                assert_eq!(
                    ingest_from_satellite(&kobe, msg, &tags).unwrap_err(),
                    IngestDrop::NeverFromSatellite
                );
            }
            for msg in [ServerMsg::DaemonReconnected, ServerMsg::Withheld { topics: vec![], reason: String::new() }] {
                assert!(ingest_from_satellite(&kobe, msg, &tags).is_err());
            }
        }
    }

    #[test]
    fn no_verb_table_admits_an_administrative_or_bookkeeping_frame() {
        let frames = [
            ServerMsg::Devices { devices: vec![], hosts: vec![] },
            ServerMsg::Hosts { hosts: vec![] },
            ServerMsg::Welcome {
                protocol_version: 1,
                daemon_pid: 1,
                features: vec![],
                operator_nonce: None,
                enabled_agents: None,
                disabled_agents: None,
            },
            ServerMsg::Pong,
            ServerMsg::DeviceUnpaired,
            ServerMsg::Unauthorized { reason: "x".into() },
            ServerMsg::DeviceAdminError { request_id: "r".into(), reason: "x".into() },
        ];
        for verb in [
            Verb::SessionList,
            Verb::FocusList,
            Verb::SessionModelGet,
            Verb::ActivitySnapshot,
            Verb::SessionAttach,
            Verb::SessionDetach,
        ] {
            for f in &frames {
                assert!(!reply_allowed(verb, f), "{verb:?} admits {f:?}");
            }
        }
    }
}
