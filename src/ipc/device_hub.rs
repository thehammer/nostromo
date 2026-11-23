//! The primary daemon's device hub: the registry, the open pairings and which
//! devices are connected, behind the verbs the WebSocket listener and the local
//! admin clients use.
//!
//! Nothing here logs a code, a proof or a token.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, mpsc};
use tracing::{info, warn};

use super::devices::{
    DeviceKind, DeviceRegistry, PairRefusedReason, RevokeError, RevokedBy, SatelliteAdmin,
};
use super::pairing::{CheckAnswer, PairingTable};
use super::peer::PeerTrust;
use super::protocol::{ClientMsg, ServerMsg};

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
        })
    }

    pub fn registry(&self) -> &Arc<DeviceRegistry> {
        &self.registry
    }

    /// Where `Devices` frames are broadcast. The first call wins.
    pub fn set_broadcast(&self, tx: broadcast::Sender<ServerMsg>) {
        let _ = self.broadcast.set(tx);
    }

    pub fn is_connected(&self, device_id: &str) -> bool {
        self.conns.lock().unwrap().contains_key(device_id)
    }

    /// Record an authenticated connection of `device_id`.
    pub fn connected(self: &Arc<Self>, device_id: &str) -> ConnGuard {
        *self
            .conns
            .lock()
            .unwrap()
            .entry(device_id.to_string())
            .or_insert(0) += 1;
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
    pub fn pair_check(&self, code: &str, proof: Option<&str>) -> ServerMsg {
        let answer = self.pairing.lock().unwrap().check(
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
    pub fn pair(&self, code: &str, name: &str, kind: DeviceKind, replace: bool) -> ServerMsg {
        let taken = self
            .pairing
            .lock()
            .unwrap()
            .take(code, kind, replace, Instant::now());
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
        let redeemed = match self.registry.redeem(
            proposed,
            kind,
            taken.admin,
            taken.matched_device.as_deref(),
        ) {
            Ok(r) => r,
            Err(e) => {
                warn!("could not save a new device: {e:#}");
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
            token: redeemed.token,
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
            } => {
                if self.pairing.lock().unwrap().cancel(pairing_id, conn_key) {
                    // The outcome (`cancelled`) already went to this connection.
                    return Dispatched::Handled;
                }
                admin_error(request_id, "unknown_pairing")
            }
            ClientMsg::DeviceList { .. } => self.devices_msg(),
            ClientMsg::DeviceRevoke { request_id, device } => {
                match self.registry.resolve(device) {
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
                }
            }
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
    }
}

fn admin_error(request_id: &str, reason: &str) -> ServerMsg {
    ServerMsg::DeviceAdminError {
        request_id: request_id.to_string(),
        reason: reason.to_string(),
    }
}
