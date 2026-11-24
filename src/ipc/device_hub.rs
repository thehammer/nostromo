//! The primary daemon's device hub: the registry, the open pairings and which
//! devices are connected, behind the verbs the WebSocket listener and the local
//! admin clients use.
//!
//! Nothing here logs a code, a proof or a token.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, mpsc};
use tracing::{info, warn};

use super::devices::{
    DeviceKind, DeviceRegistry, PairRefusedReason, RevokeError, RevokedBy, SatelliteAdmin, Secret,
};
use super::pairing::{CheckAnswer, PairingTable};
use super::peer::PeerTrust;
use super::protocol::{ClientMsg, ServerMsg};
use super::router::Router;

/// How the hub reaches the rest of the daemon: set once, when the daemon wires
/// the listeners. Empty on a daemon with no device registry.
pub type HubSlot = Arc<OnceLock<Arc<DeviceHub>>>;

pub struct DeviceHub {
    registry: Arc<DeviceRegistry>,
    pairing: Mutex<PairingTable>,
    /// Live connections per device id.
    conns: Mutex<HashMap<String, usize>>,
    pair_host: String,
    ws_port: u16,
    broadcast: OnceLock<broadcast::Sender<ServerMsg>>,
    socket_ids: AtomicU64,
    /// Which satellites are connected, and the reads routed to them.
    router: Router,
}

/// Holds a device's connection open in the hub's table; dropping it records
/// the disconnect.
pub struct ConnGuard {
    hub: Arc<DeviceHub>,
    device_id: String,
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        {
            let mut conns = self.hub.conns.lock().unwrap();
            if let Some(n) = conns.get_mut(&self.device_id) {
                *n = n.saturating_sub(1);
                if *n == 0 {
                    conns.remove(&self.device_id);
                }
            }
        }
        self.hub.registry.touch(&self.device_id);
        self.hub.broadcast_devices();
    }
}

/// What the dispatcher did with a verb.
#[derive(Debug, PartialEq, Eq)]
pub enum Dispatched {
    /// Not a device verb for this peer: carry on to the normal path.
    NotHandled,
    /// Answered (or refused) here.
    Handled,
    /// The device removed its own pairing: tell it, then close.
    Unpaired,
}

impl DeviceHub {
    pub fn new(
        registry: Arc<DeviceRegistry>,
        pairing_ttl: Duration,
        pair_host: String,
        ws_port: u16,
    ) -> Arc<Self> {
        Arc::new(Self {
            registry,
            pairing: Mutex::new(PairingTable::new(pairing_ttl)),
            conns: Mutex::new(HashMap::new()),
            pair_host,
            ws_port,
            broadcast: OnceLock::new(),
            socket_ids: AtomicU64::new(1),
            router: Router::new(),
        })
    }

    pub fn registry(&self) -> &Arc<DeviceRegistry> {
        &self.registry
    }

    /// The host table and routed-request table for satellite uplinks.
    pub fn router(&self) -> &Router {
        &self.router
    }

    /// Where `Devices` and `Hosts` frames are broadcast. The first call wins.
    pub fn set_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        self.router.set_broadcast(tx.clone());
        let _ = self.broadcast.set(tx);
    }

    pub fn is_connected(&self, device_id: &str) -> bool {
        self.conns.lock().unwrap().contains_key(device_id)
    }

    /// A fresh id for a pairing-only socket (see `PairingTable::check_from`).
    pub fn next_socket_id(&self) -> u64 {
        self.socket_ids.fetch_add(1, Ordering::Relaxed)
    }

    /// Record an authenticated connection of `device_id`, unless it already
    /// has `max` sockets open.
    pub fn try_connected(self: &Arc<Self>, device_id: &str, max: usize) -> Option<ConnGuard> {
        {
            let mut conns = self.conns.lock().unwrap();
            let n = conns.entry(device_id.to_string()).or_insert(0);
            if *n >= max {
                return None;
            }
            *n += 1;
        }
        Some(self.connected_guard(device_id))
    }

    /// Record an authenticated connection of `device_id` (no limit).
    pub fn connected(self: &Arc<Self>, device_id: &str) -> ConnGuard {
        *self
            .conns
            .lock()
            .unwrap()
            .entry(device_id.to_string())
            .or_insert(0) += 1;
        self.connected_guard(device_id)
    }

    fn connected_guard(self: &Arc<Self>, device_id: &str) -> ConnGuard {
        self.registry.touch(device_id);
        self.broadcast_devices();
        ConnGuard {
            hub: Arc::clone(self),
            device_id: device_id.to_string(),
        }
    }

    fn devices_msg(&self) -> ServerMsg {
        let conns = self.conns.lock().unwrap();
        let (devices, hosts) = self.registry.summaries(|id| conns.contains_key(id));
        ServerMsg::Devices { devices, hosts }
    }

    pub fn broadcast_devices(&self) {
        if let Some(tx) = self.broadcast.get() {
            let _ = tx.send(self.devices_msg());
        }
    }

    // ── device side ───────────────────────────────────────────────────────────

    /// Answer a `PairCheck`. Never uses the code up.
    pub fn pair_check(&self, socket: u64, code: &str, proof: Option<&str>) -> ServerMsg {
        let answer = self.pairing.lock().unwrap().check_from(
            socket,
            code,
            proof,
            |challenge, code, proof| self.registry.match_proof(challenge, code, proof),
            Instant::now(),
        );
        match answer {
            CheckAnswer::Offer {
                name_hint,
                challenge,
                knows_device,
            } => ServerMsg::PairOffer {
                name_hint,
                server_id: self.registry.server_id(),
                challenge,
                knows_device,
            },
            CheckAnswer::Refused(reason) => ServerMsg::PairRefused { reason },
        }
    }

    /// Redeem a code: the one thing that uses it up.
    pub fn pair(
        &self,
        socket: u64,
        code: &str,
        name: &str,
        kind: DeviceKind,
        replace: bool,
    ) -> ServerMsg {
        let taken =
            self.pairing
                .lock()
                .unwrap()
                .take_from(socket, code, kind, replace, Instant::now());
        let taken = match taken {
            Ok(t) => t,
            Err(reason) => return ServerMsg::PairRefused { reason },
        };
        // A satellite is named for its host; a phone proposes its own name.
        let proposed = if kind.is_satellite() {
            taken.name_hint.as_deref().unwrap_or(name)
        } else {
            name
        };
        let redeemed = match self.registry.redeem_with_egress(
            proposed,
            kind,
            taken.admin,
            taken.egress,
            taken.matched_device.as_deref(),
        ) {
            Ok(r) => r,
            Err(e) => {
                warn!("could not save a new device: {e:#}");
                // The issuer must not wait for ever on a code that is gone.
                taken.notify_failed();
                return ServerMsg::PairRefused {
                    reason: PairRefusedReason::Invalid,
                };
            }
        };
        taken.notify_paired(&redeemed.name, redeemed.replaced);
        info!(device = %redeemed.device_id, kind = ?kind, replaced = redeemed.replaced, "device paired");
        self.broadcast_devices();
        ServerMsg::Paired {
            device_id: redeemed.device_id,
            token: Secret(redeemed.token),
            name: redeemed.name,
            server_id: self.registry.server_id(),
            replaced: redeemed.replaced,
        }
    }

    /// An authenticated device removes its own record.
    pub fn unpair_self(&self, device_id: &str) {
        match self.registry.revoke(device_id, RevokedBy::Device) {
            Ok(_) => {
                info!(device = %device_id, "device unpaired itself");
                self.broadcast_devices();
            }
            Err(e) => warn!(device = %device_id, "device unpair failed: {e:?}"),
        }
    }

    // ── admin side ────────────────────────────────────────────────────────────

    /// Cancel every pairing a connection owns. Called when it goes away.
    pub fn drop_connection(&self, conn_key: &str) {
        self.pairing.lock().unwrap().drop_connection(conn_key);
    }

    /// Run a device-admin or `DeviceUnpairSelf` verb for this connection.
    /// Admin verbs are for local peers only; a network peer's is left for the
    /// normal refusal path.
    pub fn dispatch(
        self: &Arc<Self>,
        msg: &ClientMsg,
        trust: PeerTrust,
        ws_device: Option<&str>,
        conn_key: &str,
        reply: &mpsc::UnboundedSender<ServerMsg>,
    ) -> Dispatched {
        if matches!(msg, ClientMsg::DeviceUnpairSelf) {
            return match (trust, ws_device) {
                (PeerTrust::Paired, Some(id)) => {
                    self.unpair_self(id);
                    Dispatched::Unpaired
                }
                _ => Dispatched::NotHandled,
            };
        }
        if let PeerTrust::Satellite { admin } = trust {
            return self.dispatch_satellite(msg, admin, ws_device, conn_key, reply);
        }
        if trust.is_network() {
            return Dispatched::NotHandled;
        }
        // The verb and the peer's trust, never a code or a token.
        let verb = match msg {
            ClientMsg::DevicePairStart { .. } => "device_pair_start",
            ClientMsg::DevicePairCancel { .. } => "device_pair_cancel",
            ClientMsg::DeviceList { .. } => "device_list",
            ClientMsg::DeviceRevoke { .. } => "device_revoke",
            ClientMsg::DeviceSetAdmin { .. } => "device_set_admin",
            _ => return Dispatched::NotHandled,
        };
        info!(?trust, verb, "device admin verb");
        let out = match msg {
            ClientMsg::DevicePairStart {
                request_id,
                name_hint,
                satellite,
                admin,
                egress,
                origin: _,
            } => {
                let (kind, hint) = match satellite {
                    Some(host) => (DeviceKind::Satellite, Some(host.clone())),
                    None => (DeviceKind::Iphone, name_hint.clone()),
                };
                let started = self.pairing.lock().unwrap().start(
                    conn_key,
                    None,
                    reply.clone(),
                    hint,
                    kind,
                    admin.filter(|_| satellite.is_some()),
                    (*egress).filter(|_| satellite.is_some()),
                    Instant::now(),
                );
                self.schedule_expiry();
                ServerMsg::DevicePairing {
                    request_id: request_id.clone(),
                    pairing_id: started.pairing_id,
                    server_url: format!(
                        "nostromo://pair?v=1&host={}&port={}&code={}",
                        self.pair_host, self.ws_port, started.code
                    ),
                    code: started.code,
                    expires_at: started.expires_at,
                }
            }
            ClientMsg::DevicePairCancel {
                request_id,
                pairing_id,
                origin: _,
            } => {
                if self.pairing.lock().unwrap().cancel(pairing_id, conn_key, None) {
                    // The outcome (`cancelled`) already went to this connection.
                    return Dispatched::Handled;
                }
                admin_error(request_id, "unknown_pairing")
            }
            ClientMsg::DeviceList { .. } => self.devices_msg(),
            ClientMsg::DeviceRevoke { request_id, device } => match self.registry.resolve(device) {
                Err(e) => admin_error(request_id, revoke_reason(e)),
                Ok(target) => {
                    let was_connected = self.is_connected(&target.id);
                    match self.registry.revoke(&target.id, RevokedBy::Operator) {
                        Ok(_) => {
                            self.broadcast_devices();
                            ServerMsg::DeviceRevoked {
                                request_id: request_id.clone(),
                                device_id: target.id,
                                was_connected,
                            }
                        }
                        Err(e) => admin_error(request_id, revoke_reason(e)),
                    }
                }
            },
            ClientMsg::DeviceSetAdmin {
                request_id,
                host,
                admin,
            } => match self.registry.set_admin(host, *admin) {
                Ok(_) => {
                    self.broadcast_devices();
                    self.devices_msg()
                }
                Err(e) => admin_error(request_id, revoke_reason(e)),
            },
            _ => return Dispatched::NotHandled,
        };
        let _ = reply.send(out);
        Dispatched::Handled
    }

    /// A device-admin verb from a satellite's uplink, judged per level (see
    /// the table in the W10 plan). The level used is the lower of the
    /// connection's snapshot and the record's level now, so a verb already
    /// buffered when a level was lowered is judged at the lower one; a record
    /// that is no longer an active satellite gets nothing.
    ///
    /// Satellite records are changed only from the primary's own CLI:
    /// `DeviceSetAdmin`, an enrolment code, and the revoke of any satellite
    /// record are refused at every level.
    fn dispatch_satellite(
        self: &Arc<Self>,
        msg: &ClientMsg,
        snapshot: SatelliteAdmin,
        ws_device: Option<&str>,
        conn_key: &str,
        reply: &mpsc::UnboundedSender<ServerMsg>,
    ) -> Dispatched {
        let Some(request_id) = satellite_verb_request_id(msg) else {
            return Dispatched::NotHandled;
        };
        let level = ws_device
            .and_then(|id| self.registry.satellite_info(id))
            .map(|rec| snapshot.min_with(rec.admin))
            .unwrap_or(SatelliteAdmin::Off);
        info!(level = level.as_str(), "satellite device admin verb");
        let refuse = || admin_error(request_id, NOT_PERMITTED);
        let can_revoke = level.rank() >= SatelliteAdmin::RevokeOnly.rank();
        let out = match msg {
            ClientMsg::DeviceList { .. } if level != SatelliteAdmin::Off => self.devices_msg(),
            ClientMsg::DeviceRevoke { device, .. } if can_revoke => {
                match self.registry.resolve(device) {
                    Err(e) => admin_error(request_id, revoke_reason(e)),
                    // A satellite record is never revoked from an uplink, itself included.
                    Ok(target)
                        if self
                            .registry
                            .kind_of(&target.id)
                            .is_none_or(|k| k.is_satellite()) =>
                    {
                        refuse()
                    }
                    Ok(target) => {
                        let was_connected = self.is_connected(&target.id);
                        match self.registry.revoke(&target.id, RevokedBy::Operator) {
                            Ok(_) => {
                                self.broadcast_devices();
                                ServerMsg::DeviceRevoked {
                                    request_id: request_id.to_string(),
                                    device_id: target.id,
                                    was_connected,
                                }
                            }
                            Err(e) => admin_error(request_id, revoke_reason(e)),
                        }
                    }
                }
            }
            ClientMsg::DevicePairStart {
                satellite: None,
                name_hint,
                origin,
                ..
            } if level == SatelliteAdmin::Full => {
                let started = self.pairing.lock().unwrap().start(
                    conn_key,
                    origin.clone(),
                    reply.clone(),
                    name_hint.clone(),
                    DeviceKind::Iphone,
                    None,
                    None,
                    Instant::now(),
                );
                self.schedule_expiry();
                ServerMsg::DevicePairing {
                    request_id: request_id.to_string(),
                    pairing_id: started.pairing_id,
                    server_url: format!(
                        "nostromo://pair?v=1&host={}&port={}&code={}",
                        self.pair_host, self.ws_port, started.code
                    ),
                    code: started.code,
                    expires_at: started.expires_at,
                }
            }
            ClientMsg::DevicePairCancel {
                pairing_id, origin, ..
            } if can_revoke => {
                if self.pairing.lock().unwrap().cancel(
                    pairing_id,
                    conn_key,
                    origin.as_deref(),
                ) {
                    // The outcome (`cancelled`) already went to this connection.
                    return Dispatched::Handled;
                }
                admin_error(request_id, "unknown_pairing")
            }
            _ => refuse(),
        };
        let _ = reply.send(out);
        Dispatched::Handled
    }

    /// Sweep the table when the newest pairing is due, so an expiry reaches its
    /// issuer on time rather than on the next attempt.
    fn schedule_expiry(self: &Arc<Self>) {
        let hub = Arc::clone(self);
        let ttl = self.pairing.lock().unwrap().ttl();
        tokio::spawn(async move {
            tokio::time::sleep(ttl + Duration::from_millis(5)).await;
            hub.pairing.lock().unwrap().sweep(Instant::now());
        });
    }

    /// Set a satellite's admin level (the CLI's `device admin`).
    pub fn set_admin(&self, host: &str, level: SatelliteAdmin) -> Result<(), RevokeError> {
        self.registry.set_admin(host, level).map(|_| ())
    }
}

fn revoke_reason(e: RevokeError) -> &'static str {
    match e {
        RevokeError::Unknown => "unknown_device",
        RevokeError::Ambiguous => "ambiguous_name",
        RevokeError::NotSaved => "not_saved",
    }
}

/// The refusal a satellite gets for a verb its level does not allow.
const NOT_PERMITTED: &str = "not_permitted_on_this_mac";

fn satellite_verb_request_id(msg: &ClientMsg) -> Option<&str> {
    match msg {
        ClientMsg::DevicePairStart { request_id, .. }
        | ClientMsg::DevicePairCancel { request_id, .. }
        | ClientMsg::DeviceList { request_id }
        | ClientMsg::DeviceRevoke { request_id, .. }
        | ClientMsg::DeviceSetAdmin { request_id, .. } => Some(request_id),
        _ => None,
    }
}

fn admin_error(request_id: &str, reason: &str) -> ServerMsg {
    ServerMsg::DeviceAdminError {
        request_id: request_id.to_string(),
        reason: reason.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::devices::RevokeError;

    fn hub() -> (tempfile::TempDir, Arc<DeviceHub>) {
        let dir = tempfile::tempdir().unwrap();
        let registry = Arc::new(DeviceRegistry::load(dir.path().join("devices.json")).unwrap());
        let hub = DeviceHub::new(registry, Duration::from_secs(300), "127.0.0.1".into(), 1);
        (dir, hub)
    }

    #[test]
    fn a_device_connection_cap_counts_and_releases() {
        let (_d, hub) = hub();
        let first = hub.try_connected("dev_a", 1).expect("the first");
        assert!(hub.try_connected("dev_a", 1).is_none(), "over the cap");
        assert!(hub.try_connected("dev_b", 1).is_some(), "another device");
        drop(first);
        assert!(hub.try_connected("dev_a", 1).is_some(), "a freed place");
    }

    #[tokio::test]
    async fn a_revoke_that_cannot_be_saved_tells_the_operator() {
        let (dir, hub) = hub();
        let phone = hub
            .registry()
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        // Saving needs `devices.json.tmp`; a directory there makes every save fail.
        std::fs::create_dir(dir.path().join("devices.json.tmp")).unwrap();

        let (tx, mut rx) = mpsc::unbounded_channel();
        let handled = hub.dispatch(
            &ClientMsg::DeviceRevoke {
                request_id: "r1".into(),
                device: phone.device_id.clone(),
            },
            PeerTrust::LocalOther,
            None,
            "admin",
            &tx,
        );
        assert_eq!(handled, Dispatched::Handled);
        match rx.recv().await.unwrap() {
            ServerMsg::DeviceAdminError { request_id, reason } => {
                assert_eq!(request_id, "r1");
                assert_eq!(reason, "not_saved");
            }
            other => panic!("the operator was told {other:?}, not that the revoke is not durable"),
        }
        // The revoke is still in effect for this run.
        assert_eq!(
            hub.registry().validate(&phone.token),
            crate::ipc::devices::TokenCheck::Revoked
        );
        assert_eq!(
            hub.registry().revoke("ghost", RevokedBy::Operator),
            Err(RevokeError::Unknown)
        );
    }

    #[tokio::test]
    async fn a_redeem_that_cannot_be_saved_reports_failure_to_the_issuer() {
        let (dir, hub) = hub();
        let (tx, mut rx) = mpsc::unbounded_channel();
        hub.dispatch(
            &ClientMsg::DevicePairStart {
                request_id: "p1".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
                origin: None,
            },
            PeerTrust::LocalOther,
            None,
            "admin",
            &tx,
        );
        let started = match rx.recv().await.unwrap() {
            ServerMsg::DevicePairing { code, .. } => code,
            other => panic!("expected a code, got {other:?}"),
        };
        std::fs::create_dir(dir.path().join("devices.json.tmp")).unwrap();

        let reply = hub.pair(7, &started, "Phone", DeviceKind::Iphone, false);
        assert!(matches!(reply, ServerMsg::PairRefused { .. }), "{reply:?}");
        let heard = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("the issuer was told nothing and would wait for ever");
        match heard.unwrap() {
            ServerMsg::DevicePairOutcome { outcome, .. } => {
                assert_eq!(outcome, crate::ipc::devices::PairOutcomeKind::Failed);
            }
            other => panic!("the issuer heard {other:?}"),
        }
    }
}
