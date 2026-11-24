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

impl SatelliteAdmin {
    /// How much a level allows: `Off` 0, `ReadOnly` 1, `RevokeOnly` 2, `Full` 3.
    /// Not a derived `Ord`: the declaration order is the reverse.
    pub fn rank(self) -> u8 {
        match self {
            SatelliteAdmin::Off => 0,
            SatelliteAdmin::ReadOnly => 1,
            SatelliteAdmin::RevokeOnly => 2,
            SatelliteAdmin::Full => 3,
        }
    }

    /// The lower of two levels (a local narrowing never widens a grant).
    pub fn min_with(self, other: Self) -> Self {
        if other.rank() < self.rank() {
            other
        } else {
            self
        }
    }
}

/// What a satellite may publish upstream. `Work` (the default, and what a
/// record without one reads as) sends fixed-vocabulary metadata only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Egress {
    #[default]
    Work,
    Personal,
}

impl Egress {
    pub fn as_str(self) -> &'static str {
        match self {
            Egress::Work => "work",
            Egress::Personal => "personal",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "work" => Some(Egress::Work),
            "personal" => Some(Egress::Personal),
            _ => None,
        }
    }
}

/// An active satellite record as the uplink admission needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SatelliteInfo {
    pub name: String,
    pub admin: SatelliteAdmin,
    pub egress: Egress,
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
    /// Satellites only; absent on the wire means `work`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub egress: Option<Egress>,
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
    /// The code was redeemed but the device could not be saved.
    Failed,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    egress: Option<Egress>,
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
            egress: self
                .kind
                .is_satellite()
                .then(|| self.egress.unwrap_or_default()),
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

/// A secret that never prints: its `Debug` is redacted, so a stray `{:?}` of a
/// message or struct holding a token cannot leak it. Serialises as the bare string.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Secret(pub String);

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

/// The result of redeeming a pairing.
#[derive(Clone)]
pub struct Redeemed {
    pub device_id: String,
    /// The token's only plaintext. Goes into the `Paired` reply and nowhere else.
    pub token: String,
    pub name: String,
    pub replaced: bool,
}

impl std::fmt::Debug for Redeemed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Redeemed")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("name", &self.name)
            .field("replaced", &self.replaced)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevokeError {
    Unknown,
    Ambiguous,
    /// The change is in effect in memory (live sockets are closed) but could
    /// not be written to disk, so it would be undone by a restart.
    NotSaved,
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
    /// When `last_seen_at` was last written to disk, and how often it may be.
    touch_saved: Mutex<Option<std::time::Instant>>,
    touch_save_every: std::time::Duration,
}

/// `last_seen_at` is kept in memory on every connect and disconnect but written
/// to disk at most this often, so a client cannot make the daemon hammer the disk.
const TOUCH_SAVE_EVERY: std::time::Duration = std::time::Duration::from_secs(60);

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
            touch_saved: Mutex::new(None),
            touch_save_every: TOUCH_SAVE_EVERY,
        };
        if minted {
            registry.save(&registry.state.lock().unwrap())?;
        }
        Ok(registry)
    }

    /// How often `last_seen_at` may be written to disk (tests shorten it).
    pub fn with_touch_save_every(mut self, every: std::time::Duration) -> Self {
        self.touch_save_every = every;
        self
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
        self.redeem_with_egress(name, kind, admin, None, replace_device)
    }

    /// [`Self::redeem`] with the egress a satellite is enrolled with (`None`
    /// reads as `work`). Ignored for a phone or iPad.
    pub fn redeem_with_egress(
        &self,
        name: &str,
        kind: DeviceKind,
        admin: Option<SatelliteAdmin>,
        egress: Option<Egress>,
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
                egress: kind.is_satellite().then(|| egress.unwrap_or_default()),
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

    /// Admit a socket in one look at the registry: `None` when the device is
    /// unknown or no longer active, `Some(None)` for an active phone or iPad,
    /// `Some(Some(info))` for an active satellite. One lock, so a revoke
    /// cannot land between "active" and "which kind" and turn a satellite
    /// into a phone.
    pub fn admit(&self, device_id: &str) -> Option<Option<SatelliteInfo>> {
        let state = self.state.lock().unwrap();
        let d = state
            .devices
            .iter()
            .find(|d| d.id == device_id && d.active())?;
        Some(d.kind.is_satellite().then(|| SatelliteInfo {
            name: d.name.clone(),
            admin: d.admin.unwrap_or_default(),
            egress: d.egress.unwrap_or_default(),
        }))
    }

    /// The record behind `device_id` when it is an active satellite.
    pub fn satellite_info(&self, device_id: &str) -> Option<SatelliteInfo> {
        let state = self.state.lock().unwrap();
        state
            .devices
            .iter()
            .find(|d| d.id == device_id && d.active() && d.kind.is_satellite())
            .map(|d| SatelliteInfo {
                name: d.name.clone(),
                admin: d.admin.unwrap_or_default(),
                egress: d.egress.unwrap_or_default(),
            })
    }

    /// The kind of any record (active or not), for the admin arm that must
    /// tell a phone from a satellite before it revokes.
    pub fn kind_of(&self, device_id: &str) -> Option<DeviceKind> {
        let state = self.state.lock().unwrap();
        state
            .devices
            .iter()
            .find(|d| d.id == device_id)
            .map(|d| d.kind)
    }

    /// Names of the active satellites whose level is `full`.
    pub fn full_hosts(&self) -> Vec<String> {
        let state = self.state.lock().unwrap();
        let mut v: Vec<String> = state
            .devices
            .iter()
            .filter(|d| {
                d.active()
                    && d.kind.is_satellite()
                    && d.admin.unwrap_or_default() == SatelliteAdmin::Full
            })
            .map(|d| d.name.clone())
            .collect();
        v.sort();
        v
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
            let saved = self.save(&state);
            (revoked, saved)
        };
        // The revoke is in effect either way: live sockets close now.
        self.bump();
        match revoked {
            (revoked, Ok(())) => Ok(revoked),
            (_, Err(e)) => {
                tracing::error!(
                    "could not save the device registry; a revoke is not durable: {e:#}"
                );
                Err(RevokeError::NotSaved)
            }
        }
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
            let saved = self.save(&state);
            (done, saved)
        };
        self.bump();
        match done {
            (done, Ok(())) => Ok(done),
            (_, Err(e)) => {
                tracing::error!(
                    "could not save the device registry; a change is not durable: {e:#}"
                );
                Err(RevokeError::NotSaved)
            }
        }
    }

    /// Record that a device was just seen. The time is kept in memory at once
    /// and written to disk at most once per `touch_save_every`.
    pub fn touch(&self, id: &str) {
        let mut state = self.state.lock().unwrap();
        let Some(rec) = state.devices.iter_mut().find(|d| d.id == id) else {
            return;
        };
        rec.last_seen_at = Some(Utc::now());
        let mut saved = self.touch_saved.lock().unwrap();
        let now = std::time::Instant::now();
        if saved.is_some_and(|t| now.duration_since(t) < self.touch_save_every) {
            return;
        }
        *saved = Some(now);
        if let Err(e) = self.save(&state) {
            tracing::warn!("could not save the device registry: {e:#}");
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
    pub fn summaries(
        &self,
        connected: impl Fn(&str) -> bool,
    ) -> (Vec<DeviceSummary>, Vec<DeviceSummary>) {
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

/// Invisible format characters that can hide or reorder text in a terminal:
/// soft hyphen, Arabic letter mark, Mongolian vowel separator, zero-width and
/// directional marks and overrides, word joiner and invisible operators, the
/// BOM, interlinear annotation, and the tag characters.
fn is_invisible_format(c: char) -> bool {
    matches!(c,
        '\u{00ad}' | '\u{061c}' | '\u{180e}' | '\u{200b}'..='\u{200f}'
        | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}'
        | '\u{fff9}'..='\u{fffb}' | '\u{e0000}'..='\u{e007f}')
}

/// `name`, or `name 2`, `name 3`, … the first free among active devices.
fn unique_name(devices: &[DeviceRecord], name: &str) -> String {
    // Device-supplied: drop control characters (ESC, bidi overrides) and cap
    // the length so the name is safe to print in a terminal.
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control() && !is_invisible_format(*c))
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
    #[test]
    fn rank_orders_most_power_last_and_min_with_never_widens() {
        use SatelliteAdmin::*;
        assert!(Off.rank() < ReadOnly.rank());
        assert!(ReadOnly.rank() < RevokeOnly.rank());
        assert!(RevokeOnly.rank() < Full.rank());
        assert_eq!(Full.min_with(ReadOnly), ReadOnly);
        assert_eq!(ReadOnly.min_with(Full), ReadOnly);
        assert_eq!(RevokeOnly.min_with(Off), Off);
        assert_eq!(Full.min_with(Full), Full);
    }

    #[test]
    fn a_satellite_enrolled_without_egress_reads_as_work_and_personal_sticks() {
        let dir = tempfile::tempdir().unwrap();
        let reg = DeviceRegistry::load(dir.path().join("devices.json")).unwrap();
        let a = reg
            .redeem("kobe", DeviceKind::Satellite, None, None)
            .unwrap();
        let b = reg
            .redeem_with_egress(
                "sendai",
                DeviceKind::Satellite,
                Some(SatelliteAdmin::Full),
                Some(Egress::Personal),
                None,
            )
            .unwrap();
        let ka = reg.satellite_info(&a.device_id).unwrap();
        assert_eq!(ka.egress, Egress::Work);
        assert_eq!(ka.admin, SatelliteAdmin::RevokeOnly);
        let kb = reg.satellite_info(&b.device_id).unwrap();
        assert_eq!(
            (kb.egress, kb.admin),
            (Egress::Personal, SatelliteAdmin::Full)
        );
        assert_eq!(reg.full_hosts(), vec!["sendai".to_string()]);
        let phone = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        assert!(reg.satellite_info(&phone.device_id).is_none());
        assert_eq!(reg.kind_of(&phone.device_id), Some(DeviceKind::Iphone));
    }

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
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
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
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        let text = std::fs::read_to_string(d.path().join("devices.json")).unwrap();
        assert!(!text.contains(&r.token));
        assert!(text.contains(&hash_token(&r.token)));
    }

    #[test]
    fn names_are_unique_among_active_devices_only() {
        let (_d, reg) = registry();
        let a = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        let b = reg
            .redeem("iphone", DeviceKind::Iphone, None, None)
            .unwrap();
        let c = reg
            .redeem("IPHONE", DeviceKind::Iphone, None, None)
            .unwrap();
        assert_eq!((b.name.as_str(), c.name.as_str()), ("iphone 2", "IPHONE 3"));
        reg.revoke(&a.device_id, RevokedBy::Operator).unwrap();
        let d = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
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
        let old = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
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
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
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

    #[test]
    fn the_proof_encoding_is_pinned_by_a_fixed_vector() {
        // Copy this vector into the Kit side (W11); see docs/plans/backplane/W9-ws-transport.md.
        let token = "dG9rZW4tZm9yLXRoZS1maXhlZC12ZWN0b3ItMDAwMDAwMDA";
        let challenge = "Y2hhbGxlbmdlLWZvci10aGUtZml4ZWQtdmVjdG9yLTAwMDA";
        // The key is the raw SHA-256 of the token's base64url text.
        let key = Sha256::digest(token.as_bytes());
        assert_eq!(
            key.iter().map(|b| format!("{b:02x}")).collect::<String>(),
            "6ea97a4459aa83bb2f9776d280a02605de0d9614bb35991db08c6173e40fc47c"
        );
        // The message is the challenge's base64url text, then the code as digits.
        // base64url, no padding.
        assert_eq!(
            proof_for_token(token, challenge, "123456"),
            "ONMjmbNsnby-4Laxp33owC99gferbRJQsDdW6Ofz4cA"
        );
        assert_eq!(
            pairing_proof(&key, challenge, "123456"),
            "ONMjmbNsnby-4Laxp33owC99gferbRJQsDdW6Ofz4cA"
        );
    }

    #[test]
    fn the_proof_uses_the_code_as_digits_whatever_its_spacing() {
        let (_d, reg) = registry();
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        let proof = proof_for_token(&r.token, "chal", "123456");
        assert_eq!(
            reg.match_proof("chal", "123456", &proof).as_deref(),
            Some(r.device_id.as_str())
        );
    }

    #[test]
    fn last_seen_is_written_to_disk_at_most_once_per_interval() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        let reg = DeviceRegistry::load(&path)
            .unwrap()
            .with_touch_save_every(std::time::Duration::from_secs(3600));
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        reg.touch(&r.device_id);
        let after_first = std::fs::read(&path).unwrap();
        reg.touch(&r.device_id);
        reg.touch(&r.device_id);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            after_first,
            "a later touch rewrote the file"
        );
        // The listing still sees the newest time.
        let (devices, _) = reg.summaries(|_| false);
        assert!(devices[0].last_seen_at.is_some());

        // With no interval every touch is written.
        let eager = DeviceRegistry::load(dir.path().join("eager.json"))
            .unwrap()
            .with_touch_save_every(std::time::Duration::ZERO);
        let e = eager.redeem("iPad", DeviceKind::Ipad, None, None).unwrap();
        eager.touch(&e.device_id);
        let first = std::fs::read(dir.path().join("eager.json")).unwrap();
        eager.touch(&e.device_id);
        assert_ne!(std::fs::read(dir.path().join("eager.json")).unwrap(), first);
    }

    #[test]
    fn invisible_format_characters_are_dropped_from_names() {
        let (_d, reg) = registry();
        let evil =
            "A\u{200b}B\u{200f}C\u{061c}D\u{feff}E\u{202e}F\u{2060}G\u{e0041}H\u{00ad}I\u{1b}J";
        let r = reg.redeem(evil, DeviceKind::Iphone, None, None).unwrap();
        assert_eq!(r.name, "ABCDEFGHIJ");
    }

    #[test]
    fn a_token_never_prints_in_debug_output() {
        let (_d, reg) = registry();
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        assert!(!format!("{r:?}").contains(&r.token));
        let msg = crate::ipc::protocol::ServerMsg::Paired {
            device_id: r.device_id.clone(),
            token: Secret(r.token.clone()),
            name: r.name.clone(),
            server_id: "s".into(),
            replaced: false,
        };
        assert!(!format!("{msg:?}").contains(&r.token));
        // The wire form still carries it.
        assert!(serde_json::to_string(&msg).unwrap().contains(&r.token));
    }

    #[test]
    fn a_revoke_that_cannot_be_saved_is_reported_but_stays_in_effect() {
        let (dir, reg) = registry();
        let r = reg
            .redeem("iPhone", DeviceKind::Iphone, None, None)
            .unwrap();
        std::fs::create_dir(dir.path().join("devices.json.tmp")).unwrap();
        assert_eq!(
            reg.revoke(&r.device_id, RevokedBy::Operator),
            Err(RevokeError::NotSaved)
        );
        assert_eq!(reg.validate(&r.token), TokenCheck::Revoked);
    }
}
