//! The device registry: which phones, iPads and satellite Macs may connect over
//! the WebSocket listener, kept in `~/.nostromo/devices.json`.
//!
//! A device's bearer token exists in plaintext only in the `Paired` reply that
//! hands it over. The registry keeps its SHA-256 hash, never the token. Revoked
//! records are kept (the list shows them), and every revoke or admin change
//! bumps a watch **epoch** so live connections re-read their own record.
//!
//! The registry is one small JSON file written atomically (a `.tmp` beside it,
//! then a rename) with mode 0600.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;

/// Environment variable that overrides the registry's path (tests).
pub const DEVICES_PATH_ENV: &str = "NOSTROMO_DEVICES_PATH";

// ── wire types ────────────────────────────────────────────────────────────────

/// What kind of client a device is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceKind {
    Iphone,
    Ipad,
    /// A managed Mac that dials out to this daemon (W10).
    Satellite,
}

impl DeviceKind {
    pub fn is_satellite(self) -> bool {
        self == DeviceKind::Satellite
    }
}

/// How much device administration a satellite may relay to the primary (Q1).
/// Stored and printed here; enforced by W10.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SatelliteAdmin {
    Full,
    #[default]
    RevokeOnly,
    ReadOnly,
    Off,
}

impl SatelliteAdmin {
    pub fn as_str(self) -> &'static str {
        match self {
            SatelliteAdmin::Full => "full",
            SatelliteAdmin::RevokeOnly => "revoke_only",
            SatelliteAdmin::ReadOnly => "read_only",
            SatelliteAdmin::Off => "off",
        }
    }

    /// Parse either spelling (`revoke-only` on the command line).
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().replace('-', "_").as_str() {
            "full" => Some(Self::Full),
            "revoke_only" => Some(Self::RevokeOnly),
            "read_only" => Some(Self::ReadOnly),
            "off" => Some(Self::Off),
            _ => None,
        }
    }
}

/// Who revoked a record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RevokedBy {
    Operator,
    Device,
    /// The same phone paired again (D6).
    Replaced,
}

/// One device as listed to an admin client. Never a token or a hash.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceSummary {
    pub id: String,
    pub name: String,
    pub kind: DeviceKind,
    pub paired_at: DateTime<Utc>,
    #[serde(default)]
    pub last_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub connected: bool,
    #[serde(default)]
    pub revoked_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub revoked_by: Option<RevokedBy>,
    /// Satellites only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin: Option<SatelliteAdmin>,
}

/// Why a pairing code was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairRefusedReason {
    Expired,
    Invalid,
}

/// How a pairing the admin client started ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairOutcomeKind {
    Paired,
    Expired,
    Cancelled,
    LockedOut,
    ConnectionLost,
}

// ── records ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeviceRecord {
    id: String,
    name: String,
    kind: DeviceKind,
    /// base64url of SHA-256(token).
    token_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    admin: Option<SatelliteAdmin>,
    paired_at: DateTime<Utc>,
    #[serde(default)]
    last_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    revoked_at: Option<DateTime<Utc>>,
    #[serde(default)]
    revoked_by: Option<RevokedBy>,
}

impl DeviceRecord {
    fn active(&self) -> bool {
        self.revoked_at.is_none()
    }

    fn summary(&self, connected: bool) -> DeviceSummary {
        DeviceSummary {
            id: self.id.clone(),
            name: self.name.clone(),
            kind: self.kind,
            paired_at: self.paired_at,
            last_seen_at: self.last_seen_at,
            connected,
            revoked_at: self.revoked_at,
            revoked_by: self.revoked_by,
            admin: self.admin,
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct RegistryFile {
    #[serde(default)]
    server_id: String,
    #[serde(default)]
    devices: Vec<DeviceRecord>,
}

/// What a bearer token resolves to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenCheck {
    Active { id: String },
    Revoked,
    Unknown,
}

/// A device's current standing, by id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceStanding {
    Active,
    Revoked(RevokedBy),
}

/// The result of redeeming a pairing.
#[derive(Debug, Clone)]
pub struct Redeemed {
    pub device_id: String,
    /// The token's only plaintext. Goes into the `Paired` reply and nowhere else.
    pub token: String,
    pub name: String,
    pub replaced: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevokeError {
    Unknown,
    Ambiguous,
}

/// The device a revoke hit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Revoked {
    pub id: String,
    pub name: String,
}

// ── registry ──────────────────────────────────────────────────────────────────

pub struct DeviceRegistry {
    path: PathBuf,
    state: Mutex<RegistryFile>,
    epoch: watch::Sender<u64>,
}

/// `~/.nostromo/devices.json`, or `NOSTROMO_DEVICES_PATH`.
pub fn default_devices_path() -> PathBuf {
    if let Some(p) = std::env::var_os(DEVICES_PATH_ENV) {
        return PathBuf::from(p);
    }
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".nostromo")
        .join("devices.json")
}

impl DeviceRegistry {
    /// Load the registry at `path`, minting its `server_id` on first load.
    pub fn load(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        let mut file: RegistryFile = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| format!("parse {}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => RegistryFile::default(),
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
        };
        let minted = file.server_id.is_empty();
        if minted {
            file.server_id = random_token();
        }
        let (epoch, _) = watch::channel(0);
        let registry = Self {
            path,
            state: Mutex::new(file),
            epoch,
        };
        if minted {
            registry.save(&registry.state.lock().unwrap())?;
        }
        Ok(registry)
    }

    pub fn server_id(&self) -> String {
        self.state.lock().unwrap().server_id.clone()
    }

    /// A receiver that changes on every revoke and admin change.
    pub fn subscribe_epoch(&self) -> watch::Receiver<u64> {
        self.epoch.subscribe()
    }

    /// Resolve a bearer token. Compares against every record's hash.
    pub fn validate(&self, token: &str) -> TokenCheck {
        let hash = hash_token(token);
        let state = self.state.lock().unwrap();
        let mut found: Option<&DeviceRecord> = None;
        for rec in &state.devices {
            if ct_eq(rec.token_hash.as_bytes(), hash.as_bytes()) {
                found = Some(rec);
            }
        }
        match found {
            Some(rec) if rec.active() => TokenCheck::Active { id: rec.id.clone() },
            Some(_) => TokenCheck::Revoked,
            None => TokenCheck::Unknown,
        }
    }

    pub fn standing(&self, id: &str) -> Option<DeviceStanding> {
        let state = self.state.lock().unwrap();
        state.devices.iter().find(|d| d.id == id).map(|d| {
            if d.active() {
                DeviceStanding::Active
            } else {
                DeviceStanding::Revoked(d.revoked_by.unwrap_or(RevokedBy::Operator))
            }
        })
    }

    /// Redeem a pairing: mint a token and record the device. When
    /// `replace_device` names an active record it is revoked first
    /// (`revoked_by: replaced`) so the new record can keep its name, all in one
    /// save. Names are de-duplicated case-insensitively among *active* devices.
    pub fn redeem(
        &self,
        name: &str,
        kind: DeviceKind,
        admin: Option<SatelliteAdmin>,
        replace_device: Option<&str>,
    ) -> Result<Redeemed> {
        let token = random_token();
        let now = Utc::now();
        let (device_id, final_name, replaced) = {
            let mut state = self.state.lock().unwrap();
            let mut replaced = false;
            if let Some(old) = replace_device {
                if let Some(rec) = state
                    .devices
                    .iter_mut()
                    .find(|d| d.id == old && d.active() && !d.kind.is_satellite())
                {
                    rec.revoked_at = Some(now);
                    rec.revoked_by = Some(RevokedBy::Replaced);
                    replaced = true;
                }
            }
            let final_name = unique_name(&state.devices, name);
            let device_id = format!("dev_{}", &random_token()[..12]);
            state.devices.push(DeviceRecord {
                id: device_id.clone(),
                name: final_name.clone(),
                kind,
                token_hash: hash_token(&token),
                admin: kind
                    .is_satellite()
                    .then(|| admin.unwrap_or(SatelliteAdmin::RevokeOnly)),
                paired_at: now,
                last_seen_at: None,
                revoked_at: None,
                revoked_by: None,
            });
            self.save(&state)?;
            (device_id, final_name, replaced)
        };
        if replaced {
            self.bump();
        }
        Ok(Redeemed {
            device_id,
            token,
            name: final_name,
            replaced,
        })
    }

    /// Which record `selector` names: an id, or the exact (case-insensitive)
    /// name of an *active* device.
    pub fn resolve(&self, selector: &str) -> Result<Revoked, RevokeError> {
        let state = self.state.lock().unwrap();
        let idx = Self::index_of(&state, selector)?;
        Ok(Revoked {
            id: state.devices[idx].id.clone(),
            name: state.devices[idx].name.clone(),
        })
    }

    fn index_of(state: &RegistryFile, selector: &str) -> Result<usize, RevokeError> {
        if let Some(i) = state.devices.iter().position(|d| d.id == selector) {
            return Ok(i);
        }
        let named: Vec<usize> = state
            .devices
            .iter()
            .enumerate()
            .filter(|(_, d)| d.active() && d.name.eq_ignore_ascii_case(selector))
            .map(|(i, _)| i)
            .collect();
        match named.as_slice() {
            [] => Err(RevokeError::Unknown),
            [i] => Ok(*i),
            _ => Err(RevokeError::Ambiguous),
        }
    }

    /// Revoke by id, or by the exact (case-insensitive) name of an *active*
    /// device.
    pub fn revoke(&self, selector: &str, by: RevokedBy) -> Result<Revoked, RevokeError> {
        let revoked = {
            let mut state = self.state.lock().unwrap();
            let idx = Self::index_of(&state, selector)?;
            let rec = &mut state.devices[idx];
            if rec.active() {
                rec.revoked_at = Some(Utc::now());
                rec.revoked_by = Some(by);
            }
            let revoked = Revoked {
                id: rec.id.clone(),
                name: rec.name.clone(),
            };
            if let Err(e) = self.save(&state) {
                tracing::warn!("could not save the device registry: {e:#}");
            }
            revoked
        };
        self.bump();
        Ok(revoked)
    }

    /// Set a satellite's device-admin level, by id or active name.
    pub fn set_admin(&self, selector: &str, level: SatelliteAdmin) -> Result<Revoked, RevokeError> {
        let done = {
            let mut state = self.state.lock().unwrap();
            let matches: Vec<usize> = state
                .devices
                .iter()
                .enumerate()
                .filter(|(_, d)| {
                    d.active()
                        && d.kind.is_satellite()
                        && (d.id == selector || d.name.eq_ignore_ascii_case(selector))
                })
                .map(|(i, _)| i)
                .collect();
            let idx = match matches.as_slice() {
                [] => return Err(RevokeError::Unknown),
                [i] => *i,
                _ => return Err(RevokeError::Ambiguous),
            };
            let rec = &mut state.devices[idx];
            rec.admin = Some(level);
            let done = Revoked {
                id: rec.id.clone(),
                name: rec.name.clone(),
            };
            if let Err(e) = self.save(&state) {
                tracing::warn!("could not save the device registry: {e:#}");
            }
            done
        };
        self.bump();
        Ok(done)
    }

    /// Record that a device was just seen.
    pub fn touch(&self, id: &str) {
        let mut state = self.state.lock().unwrap();
        if let Some(rec) = state.devices.iter_mut().find(|d| d.id == id) {
            rec.last_seen_at = Some(Utc::now());
            if let Err(e) = self.save(&state) {
                tracing::warn!("could not save the device registry: {e:#}");
            }
        }
    }

    /// The id of the active phone or iPad whose stored hash proves knowledge of
    /// `challenge` and `code` (D6). Compares against every active record with
    /// no early exit.
    pub fn match_proof(&self, challenge: &str, code: &str, proof: &str) -> Option<String> {
        let state = self.state.lock().unwrap();
        let mut matched = None;
        for rec in state
            .devices
            .iter()
            .filter(|d| d.active() && !d.kind.is_satellite())
        {
            let Ok(key) = URL_SAFE_NO_PAD.decode(&rec.token_hash) else {
                continue;
            };
            let expected = pairing_proof(&key, challenge, code);
            if ct_eq(expected.as_bytes(), proof.as_bytes()) {
                matched = Some(rec.id.clone());
            }
        }
        matched
    }

    /// Phones and iPads, then satellites (`hosts`), each in pairing order.
    pub fn summaries(&self, connected: impl Fn(&str) -> bool) -> (Vec<DeviceSummary>, Vec<DeviceSummary>) {
        let state = self.state.lock().unwrap();
        let (hosts, devices): (Vec<_>, Vec<_>) = state
            .devices
            .iter()
            .map(|d| d.summary(connected(&d.id) && d.active()))
            .partition(|d| d.kind.is_satellite());
        (devices, hosts)
    }

    fn bump(&self) {
        self.epoch.send_modify(|e| *e += 1);
    }

    fn save(&self, state: &RegistryFile) -> Result<()> {
        write_atomic(&self.path, &serde_json::to_vec_pretty(state)?)
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    // A leftover `.tmp` from a crashed write is simply replaced.
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .with_context(|| format!("create {}", tmp.display()))?;
    f.write_all(bytes)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, path).with_context(|| format!("rename onto {}", path.display()))?;
    Ok(())
}

/// `name`, or `name 2`, `name 3`, … the first free among active devices.
fn unique_name(devices: &[DeviceRecord], name: &str) -> String {
    // Device-supplied: drop control characters (ESC, bidi overrides) and cap
    // the length so the name is safe to print in a terminal.
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control() && !matches!(*c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
        .take(64)
        .collect();
    let name = cleaned.trim();
    let name = if name.is_empty() { "Device" } else { name };
    let taken = |candidate: &str| {
        devices
            .iter()
            .any(|d| d.active() && d.name.eq_ignore_ascii_case(candidate))
    };
    if !taken(name) {
        return name.to_string();
    }
    (2..)
        .map(|n| format!("{name} {n}"))
        .find(|c| !taken(c))
        .expect("an unbounded range has a free name")
}

// ── token and proof primitives ────────────────────────────────────────────────

/// 32 random bytes from the OS CSPRNG, base64url. A `uuid` is not a token source.
pub fn random_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// base64url of SHA-256(token): what the registry stores.
pub fn hash_token(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

/// Constant-time equality.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// HMAC-SHA256 (RFC 2104).
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    inner.update(msg);
    let inner = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(inner);
    outer.finalize().into()
}

/// The D6 proof a device sends: base64url of
/// HMAC-SHA256(key = SHA-256(token), msg = challenge ‖ code). `key` is the raw
/// 32-byte SHA-256 of the token.
pub fn pairing_proof(key: &[u8], challenge: &str, code: &str) -> String {
    let mut msg = Vec::with_capacity(challenge.len() + code.len());
    msg.extend_from_slice(challenge.as_bytes());
    msg.extend_from_slice(code.as_bytes());
    URL_SAFE_NO_PAD.encode(hmac_sha256(key, &msg))
}

/// The proof for a device holding `token`; what a phone computes.
pub fn proof_for_token(token: &str, challenge: &str, code: &str) -> String {
    pairing_proof(&Sha256::digest(token.as_bytes()), challenge, code)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> (tempfile::TempDir, DeviceRegistry) {
        let dir = tempfile::tempdir().unwrap();
        let reg = DeviceRegistry::load(dir.path().join("devices.json")).unwrap();
        (dir, reg)
    }

    #[test]
    fn hmac_matches_the_rfc_4231_vector() {
        let key = [0x0bu8; 20];
        let mac = hmac_sha256(&key, b"Hi There");
        let hex: String = mac.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }

    #[test]
    fn redeem_then_validate_round_trips_and_revoke_fails_validation() {
        let (_d, reg) = registry();
        let r = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        assert_eq!(
            reg.validate(&r.token),
            TokenCheck::Active {
                id: r.device_id.clone()
            }
        );
        assert_eq!(reg.validate("nope"), TokenCheck::Unknown);
        reg.revoke(&r.device_id, RevokedBy::Operator).unwrap();
        assert_eq!(reg.validate(&r.token), TokenCheck::Revoked);
        assert_eq!(
            reg.standing(&r.device_id),
            Some(DeviceStanding::Revoked(RevokedBy::Operator))
        );
    }

    #[test]
    fn the_file_holds_a_hash_and_never_the_token() {
        let (d, reg) = registry();
        let r = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        let text = std::fs::read_to_string(d.path().join("devices.json")).unwrap();
        assert!(!text.contains(&r.token));
        assert!(text.contains(&hash_token(&r.token)));
    }

    #[test]
    fn names_are_unique_among_active_devices_only() {
        let (_d, reg) = registry();
        let a = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        let b = reg.redeem("iphone", DeviceKind::Iphone, None, None).unwrap();
        let c = reg.redeem("IPHONE", DeviceKind::Iphone, None, None).unwrap();
        assert_eq!((b.name.as_str(), c.name.as_str()), ("iphone 2", "IPHONE 3"));
        reg.revoke(&a.device_id, RevokedBy::Operator).unwrap();
        let d = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        assert_eq!(d.name, "iPhone");
    }

    #[test]
    fn revoked_records_are_kept_and_server_id_is_stable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        let first = DeviceRegistry::load(&path).unwrap();
        let id = first.server_id();
        let r = first.redeem("iPad", DeviceKind::Ipad, None, None).unwrap();
        first.revoke("iPad", RevokedBy::Operator).unwrap();
        let again = DeviceRegistry::load(&path).unwrap();
        assert_eq!(again.server_id(), id);
        let (devices, hosts) = again.summaries(|_| false);
        assert!(hosts.is_empty());
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].id, r.device_id);
        assert!(devices[0].revoked_at.is_some());
    }

    #[test]
    fn a_leftover_tmp_file_does_not_break_saving() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        std::fs::write(dir.path().join("devices.json.tmp"), b"garbage").unwrap();
        let reg = DeviceRegistry::load(&path).unwrap();
        reg.redeem("iPad", DeviceKind::Ipad, None, None).unwrap();
        assert!(DeviceRegistry::load(&path).is_ok());
    }

    #[test]
    fn the_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let (d, reg) = registry();
        reg.redeem("iPad", DeviceKind::Ipad, None, None).unwrap();
        let mode = std::fs::metadata(d.path().join("devices.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn revoking_by_an_ambiguous_or_unknown_name_fails() {
        let (_d, reg) = registry();
        reg.redeem("iPad", DeviceKind::Ipad, None, None).unwrap();
        assert_eq!(
            reg.revoke("ghost", RevokedBy::Operator),
            Err(RevokeError::Unknown)
        );
    }

    #[test]
    fn replacing_revokes_the_old_record_and_keeps_the_name() {
        let (_d, reg) = registry();
        let old = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        let epoch = reg.subscribe_epoch();
        let new = reg
            .redeem("iPhone", DeviceKind::Iphone, None, Some(&old.device_id))
            .unwrap();
        assert!(new.replaced);
        assert_eq!(new.name, "iPhone");
        assert_eq!(
            reg.standing(&old.device_id),
            Some(DeviceStanding::Revoked(RevokedBy::Replaced))
        );
        assert!(epoch.has_changed().unwrap());
    }

    #[test]
    fn proofs_match_only_the_right_token_challenge_and_code() {
        let (_d, reg) = registry();
        let r = reg.redeem("iPhone", DeviceKind::Iphone, None, None).unwrap();
        let proof = proof_for_token(&r.token, "chal", "123456");
        assert_eq!(
            reg.match_proof("chal", "123456", &proof),
            Some(r.device_id.clone())
        );
        assert_eq!(reg.match_proof("other", "123456", &proof), None);
        assert_eq!(reg.match_proof("chal", "654321", &proof), None);
        let wrong = proof_for_token("not-the-token", "chal", "123456");
        assert_eq!(reg.match_proof("chal", "123456", &wrong), None);
        reg.revoke(&r.device_id, RevokedBy::Operator).unwrap();
        assert_eq!(reg.match_proof("chal", "123456", &proof), None);
    }

    #[test]
    fn a_satellite_defaults_to_revoke_only_and_never_matches_a_proof() {
        let (_d, reg) = registry();
        let s = reg
            .redeem("Tokyo", DeviceKind::Satellite, None, None)
            .unwrap();
        let (_, hosts) = reg.summaries(|_| false);
        assert_eq!(hosts[0].admin, Some(SatelliteAdmin::RevokeOnly));
        let proof = proof_for_token(&s.token, "c", "1");
        assert_eq!(reg.match_proof("c", "1", &proof), None);
        reg.set_admin("Tokyo", SatelliteAdmin::Full).unwrap();
        let (_, hosts) = reg.summaries(|_| false);
        assert_eq!(hosts[0].admin, Some(SatelliteAdmin::Full));
    }

    #[test]
    fn admin_levels_parse_both_spellings() {
        assert_eq!(
            SatelliteAdmin::parse("revoke-only"),
            Some(SatelliteAdmin::RevokeOnly)
        );
        assert_eq!(
            SatelliteAdmin::parse("read_only"),
            Some(SatelliteAdmin::ReadOnly)
        );
        assert_eq!(SatelliteAdmin::parse("bogus"), None);
    }
}
