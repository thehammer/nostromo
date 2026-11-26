//! Per-device push registration, kept on the primary (W13): the phone's APNs
//! token, the anonymous reference the relay knows it by, and its settings.
//!
//! `~/.nostromo/push/devices.json`, keyed by the W9 device id, written
//! atomically (tmp + rename) with mode 0600: an APNs token is a credential.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::push::schedule::{parse_hhmm, parse_tz};
use crate::push::wire::{PushCapabilities, PushEnvironment, PushPrefs};

/// An APNs token is at most 100 bytes: 200 hex characters.
const MAX_TOKEN_LEN: usize = 200;

#[derive(Clone, Serialize, Deserialize)]
pub struct PushDevice {
    pub device_id: String,
    pub apns_token: String,
    pub environment: PushEnvironment,
    /// Random 128-bit hex: the relay's anonymous device reference.
    pub push_id: String,
    #[serde(default)]
    pub capabilities: PushCapabilities,
    #[serde(default)]
    pub prefs: PushPrefs,
}

// A token never prints.
impl std::fmt::Debug for PushDevice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushDevice")
            .field("device_id", &self.device_id)
            .field("environment", &self.environment)
            .field("capabilities", &self.capabilities)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct File {
    #[serde(default)]
    devices: BTreeMap<String, PushDevice>,
}

#[derive(Debug)]
pub struct DeviceStore {
    path: PathBuf,
    devices: BTreeMap<String, PushDevice>,
}

/// An APNs token as the phone sends it: non-empty hex, bounded.
pub fn valid_apns_token(token: &str) -> bool {
    !token.is_empty() && token.len() <= MAX_TOKEN_LEN && token.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Settings as the daemon will keep them, or `None` when any part is not valid:
/// an IANA zone name this build knows, `HH:MM` times.
pub fn sanitize_prefs(prefs: PushPrefs) -> Option<PushPrefs> {
    let tz_ok = prefs.tz.parse::<chrono_tz::Tz>().is_ok();
    let times_ok = parse_hhmm(&prefs.quiet.start).is_some()
        && parse_hhmm(&prefs.quiet.end).is_some()
        && prefs.evening_summary.as_deref().is_none_or(|t| parse_hhmm(t).is_some());
    (tz_ok && times_ok).then_some(prefs)
}

impl DeviceStore {
    /// The records at `path`; none if the file is missing or unreadable.
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let devices = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<File>(&bytes).ok())
            .map(|f| f.devices)
            .unwrap_or_default();
        Self { path, devices }
    }

    pub fn get(&self, device_id: &str) -> Option<&PushDevice> {
        self.devices.get(device_id)
    }

    pub fn iter(&self) -> impl Iterator<Item = &PushDevice> {
        self.devices.values()
    }

    pub fn ids(&self) -> Vec<String> {
        self.devices.keys().cloned().collect()
    }

    /// Record a phone's token. A first registration mints its `push_id`; a later
    /// one keeps `push_id` and the settings, and updates the token, environment,
    /// capabilities and time zone. Returns whether anything changed (and was saved).
    pub fn register(
        &mut self,
        device_id: &str,
        apns_token: &str,
        environment: PushEnvironment,
        tz: &str,
        capabilities: PushCapabilities,
    ) -> Result<bool> {
        let tz = if tz.parse::<chrono_tz::Tz>().is_ok() {
            tz
        } else {
            "UTC"
        };
        let before = self.devices.get(device_id).cloned();
        let record = self
            .devices
            .entry(device_id.to_string())
            .or_insert_with(|| PushDevice {
                device_id: device_id.to_string(),
                apns_token: String::new(),
                environment,
                push_id: new_push_id(),
                capabilities,
                prefs: PushPrefs::default(),
            });
        record.apns_token = apns_token.to_string();
        record.environment = environment;
        record.capabilities = capabilities;
        record.prefs.tz = tz.to_string();
        let changed = before.is_none_or(|b| {
            b.apns_token != record.apns_token
                || b.environment != record.environment
                || b.capabilities != record.capabilities
                || b.prefs.tz != record.prefs.tz
        });
        if changed {
            self.save()?;
        }
        Ok(changed)
    }

    /// Replace a registered device's settings (already [`sanitize_prefs`]ed).
    /// `false` for an unknown device or unchanged settings.
    pub fn set_prefs(&mut self, device_id: &str, prefs: PushPrefs) -> Result<bool> {
        let Some(record) = self.devices.get_mut(device_id) else {
            return Ok(false);
        };
        if record.prefs == prefs {
            return Ok(false);
        }
        record.prefs = prefs;
        self.save()?;
        Ok(true)
    }

    /// Delete a device's record (it was revoked or unpaired).
    pub fn remove(&mut self, device_id: &str) -> Result<Option<PushDevice>> {
        let removed = self.devices.remove(device_id);
        if removed.is_some() {
            self.save()?;
        }
        Ok(removed)
    }

    fn save(&self) -> Result<()> {
        write_private_atomic(
            &self.path,
            &serde_json::to_vec_pretty(&File {
                devices: self.devices.clone(),
            })?,
        )
    }
}

fn new_push_id() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Write `bytes` to `path` through a temporary file and a rename, readable by
/// the owner only.
pub(crate) fn write_private_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&tmp)
        .with_context(|| format!("writing {}", tmp.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// The zone a device's settings name (UTC when unknown).
pub fn device_tz(prefs: &PushPrefs) -> chrono_tz::Tz {
    parse_tz(&prefs.tz)
}
