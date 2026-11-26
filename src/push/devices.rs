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
    /// Set when the file existed but could not be read or parsed: the registrations
    /// in it are unknown, so nothing is written over it until the operator has
    /// moved or fixed it. (A copy is kept beside it.)
    unreadable: Option<String>,
}

/// An APNs token as the phone sends it: non-empty hex, bounded.
pub fn valid_apns_token(token: &str) -> bool {
    !token.is_empty()
        && token.len() <= MAX_TOKEN_LEN
        && token.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Settings as the daemon will keep them, or `None` when any part is not valid:
/// an IANA zone name this build knows, `HH:MM` times.
pub fn sanitize_prefs(prefs: PushPrefs) -> Option<PushPrefs> {
    let tz_ok = prefs.tz.parse::<chrono_tz::Tz>().is_ok();
    let times_ok = parse_hhmm(&prefs.quiet.start).is_some()
        && parse_hhmm(&prefs.quiet.end).is_some()
        && prefs
            .evening_summary
            .as_deref()
            .is_none_or(|t| parse_hhmm(t).is_some());
    (tz_ok && times_ok).then_some(prefs)
}

impl DeviceStore {
    /// The records at `path`; none if the file is missing. A file that exists but
    /// cannot be read or parsed is NOT treated as empty: it is logged at error,
    /// copied to `devices.json.corrupt-<unix seconds>`, and every save is refused
    /// until the operator moves or removes it (the next save would otherwise wipe
    /// every phone's registration).
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Self {
                    path,
                    devices: BTreeMap::new(),
                    unreadable: None,
                };
            }
            Err(e) => return Self::unreadable(path, None, format!("{e}")),
        };
        match serde_json::from_slice::<File>(&bytes) {
            Ok(file) => Self {
                path,
                devices: file.devices,
                unreadable: None,
            },
            Err(e) => Self::unreadable(path, Some(bytes), format!("{e}")),
        }
    }

    fn unreadable(path: PathBuf, bytes: Option<Vec<u8>>, why: String) -> Self {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let aside = PathBuf::from(format!("{}.corrupt-{stamp}", path.display()));
        let kept = bytes
            .as_deref()
            .is_some_and(|b| write_private_atomic(&aside, b).is_ok());
        tracing::error!(
            path = %path.display(),
            "push registrations are unreadable ({why}); not starting from an empty store. {} \
             Registrations are not saved until this file is moved or removed.",
            if kept {
                format!("A copy is at {}.", aside.display())
            } else {
                "No copy could be made.".to_string()
            }
        );
        Self {
            path,
            devices: BTreeMap::new(),
            unreadable: Some(why),
        }
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
        let changed = before.as_ref().is_none_or(|b| {
            b.apns_token != record.apns_token
                || b.environment != record.environment
                || b.capabilities != record.capabilities
                || b.prefs.tz != record.prefs.tz
        });
        if changed {
            if let Err(e) = self.save() {
                // Not saved means not registered: the next identical register must try again.
                match before {
                    Some(b) => self.devices.insert(device_id.to_string(), b),
                    None => self.devices.remove(device_id),
                };
                return Err(e);
            }
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
        let before = std::mem::replace(&mut record.prefs, prefs);
        if let Err(e) = self.save() {
            if let Some(record) = self.devices.get_mut(device_id) {
                record.prefs = before;
            }
            return Err(e);
        }
        Ok(true)
    }

    /// Apple said this token is dead (`410 Unregistered`, `400 BadDeviceToken`):
    /// forget the token but keep the device's settings and reference. The phone's
    /// next `register_push` with a fresh token makes it deliverable again. `token`
    /// is the one that was refused: a device that has re-registered since keeps
    /// its new one. Returns the device id when a token was cleared.
    pub fn forget_dead_token(&mut self, push_id: &str, token: &str) -> Result<Option<String>> {
        let Some(record) = self
            .devices
            .values_mut()
            .find(|d| d.push_id == push_id && d.apns_token == token)
        else {
            return Ok(None);
        };
        record.apns_token.clear();
        let id = record.device_id.clone();
        if let Err(e) = self.save() {
            if let Some(record) = self.devices.get_mut(&id) {
                record.apns_token = token.to_string();
            }
            return Err(e);
        }
        Ok(Some(id))
    }

    /// Delete a device's record (it was revoked or unpaired).
    pub fn remove(&mut self, device_id: &str) -> Result<Option<PushDevice>> {
        let removed = self.devices.remove(device_id);
        if removed.is_some() {
            self.save()?;
        }
        Ok(removed)
    }

    fn save(&mut self) -> Result<()> {
        if let Some(why) = &self.unreadable {
            // Handled once the operator has moved or removed the unreadable file.
            if self.path.exists() {
                anyhow::bail!(
                    "{} is unreadable ({why}); move or remove it, then register again",
                    self.path.display()
                );
            }
            self.unreadable = None;
        }
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
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::wire::{PushKinds, QuietHours};

    fn store() -> (tempfile::TempDir, DeviceStore) {
        let dir = tempfile::tempdir().unwrap();
        let store = DeviceStore::load(dir.path().join("push").join("devices.json"));
        (dir, store)
    }

    fn token() -> String {
        "ab".repeat(32)
    }

    fn register(s: &mut DeviceStore, id: &str, tok: &str, tz: &str) -> bool {
        s.register(
            id,
            tok,
            PushEnvironment::Sandbox,
            tz,
            PushCapabilities::default(),
        )
        .unwrap()
    }

    // ── an unreadable file ───────────────────────────────────────────────────

    #[test]
    fn a_corrupt_devices_file_is_kept_aside_and_never_overwritten_until_handled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        std::fs::write(&path, b"{ not json, but somebody's registrations").unwrap();

        let mut s = DeviceStore::load(&path);
        assert!(s.ids().is_empty());
        let aside: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.to_string_lossy().contains(".corrupt-"))
            .collect();
        assert_eq!(aside.len(), 1, "a copy is kept beside it");
        assert_eq!(
            std::fs::read(&aside[0]).unwrap(),
            b"{ not json, but somebody's registrations"
        );

        // A registration is refused rather than wiping what the file held.
        let err = s
            .register(
                "dev-1",
                &token(),
                PushEnvironment::Sandbox,
                "UTC",
                PushCapabilities::default(),
            )
            .unwrap_err();
        assert!(format!("{err:#}").contains("unreadable"), "{err:#}");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            b"{ not json, but somebody's registrations",
            "the file is untouched"
        );

        assert!(s.get("dev-1").is_none(), "not saved means not registered");

        // Handled: the operator moves it away, and saving works again.
        std::fs::remove_file(&path).unwrap();
        assert!(register(&mut s, "dev-1", &token(), "UTC"));
        assert!(DeviceStore::load(&path).get("dev-1").is_some());
    }

    #[test]
    fn a_missing_devices_file_is_simply_empty_and_saves() {
        let (_dir, mut s) = store();
        assert!(s.ids().is_empty());
        assert!(register(&mut s, "dev-1", &token(), "UTC"));
    }

    // ── tokens ───────────────────────────────────────────────────────────────

    #[test]
    fn an_apns_token_is_non_empty_hex_of_at_most_200_characters() {
        assert!(valid_apns_token("a"));
        assert!(valid_apns_token(&token()));
        assert!(
            valid_apns_token(&"AB".repeat(100)),
            "uppercase hex, 200 characters"
        );
        assert!(
            valid_apns_token(&"ab".repeat(100)),
            "200 characters is the longest"
        );
        assert!(
            !valid_apns_token(&format!("{}a", "ab".repeat(100))),
            "201 characters"
        );
        assert!(!valid_apns_token(&"ab".repeat(101)), "202 characters");
        assert!(!valid_apns_token(&"a".repeat(1000)));
        for bad in ["", " ", "g", "zz", "ab cd", "ab\n", "0x12", "ab-cd", "日本"] {
            assert!(!valid_apns_token(bad), "{bad:?}");
        }
    }

    // ── settings ─────────────────────────────────────────────────────────────

    #[test]
    fn the_default_settings_are_valid_and_come_back_unchanged() {
        let prefs = PushPrefs::default();
        assert_eq!(sanitize_prefs(prefs.clone()), Some(prefs));
    }

    #[test]
    fn settings_with_a_zone_or_time_that_is_not_valid_are_refused() {
        let ok = |f: &dyn Fn(&mut PushPrefs)| {
            let mut p = PushPrefs::default();
            f(&mut p);
            sanitize_prefs(p).is_some()
        };
        assert!(ok(&|p| p.tz = "America/Chicago".into()));
        assert!(ok(&|p| p.tz = "Asia/Tokyo".into()));
        assert!(ok(&|p| p.tz = "UTC".into()));
        assert!(!ok(&|p| p.tz = "Mars/Olympus_Mons".into()));
        assert!(!ok(&|p| p.tz = String::new()));
        assert!(!ok(&|p| p.tz = "America/".into()));

        assert!(ok(&|p| p.quiet.start = "00:00".into()));
        assert!(ok(&|p| p.quiet.end = "23:59".into()));
        assert!(!ok(&|p| p.quiet.start = "24:00".into()));
        assert!(!ok(&|p| p.quiet.start = "25:00".into()));
        assert!(!ok(&|p| p.quiet.end = "07:60".into()));
        assert!(!ok(&|p| p.quiet.end = "7am".into()));
        assert!(!ok(&|p| p.quiet.start = String::new()));
        assert!(!ok(&|p| p.quiet.start = "ab:cd".into()));

        assert!(ok(&|p| p.evening_summary = None));
        assert!(ok(&|p| p.evening_summary = Some("18:45".into())));
        assert!(!ok(&|p| p.evening_summary = Some("half past five".into())));
        assert!(!ok(&|p| p.evening_summary = Some("17:61".into())));
        assert!(!ok(&|p| p.evening_summary = Some(String::new())));
    }

    #[test]
    fn quiet_hours_that_are_switched_off_still_have_to_hold_valid_times() {
        let p = PushPrefs {
            quiet: QuietHours {
                start: "99:99".into(),
                end: "07:00".into(),
                enabled: false,
            },
            ..PushPrefs::default()
        };
        assert!(
            sanitize_prefs(p).is_none(),
            "the morning digest still fires at `end`"
        );
    }

    // ── registering ──────────────────────────────────────────────────────────

    #[test]
    fn a_first_registration_mints_a_random_128_bit_device_reference() {
        let (_dir, mut s) = store();
        assert!(register(&mut s, "dev-1", &token(), "UTC"));
        assert!(register(&mut s, "dev-2", &token(), "UTC"));
        let a = s.get("dev-1").unwrap().push_id.clone();
        let b = s.get("dev-2").unwrap().push_id.clone();
        for id in [&a, &b] {
            assert_eq!(id.len(), 32, "128 bits as hex: {id}");
            assert!(
                id.bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
                "{id}"
            );
        }
        assert_ne!(a, b, "random per device");
    }

    #[test]
    fn registering_again_keeps_the_reference_and_the_settings_and_updates_the_rest() {
        let (_dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "UTC");
        let push_id = s.get("dev-1").unwrap().push_id.clone();
        let prefs = PushPrefs {
            kinds: PushKinds {
                mother: false,
                decision: true,
                review: false,
            },
            quiet: QuietHours {
                start: "21:30".into(),
                ..QuietHours::default()
            },
            evening_summary: None,
            ..PushPrefs::default()
        };
        assert!(s.set_prefs("dev-1", prefs.clone()).unwrap());

        let changed = s
            .register(
                "dev-1",
                &"cd".repeat(32),
                PushEnvironment::Production,
                "Asia/Tokyo",
                PushCapabilities { nse_withdraw: true },
            )
            .unwrap();
        assert!(changed);
        let d = s.get("dev-1").unwrap();
        assert_eq!(d.push_id, push_id);
        assert_eq!(d.apns_token, "cd".repeat(32));
        assert_eq!(d.environment, PushEnvironment::Production);
        assert!(d.capabilities.nse_withdraw);
        assert_eq!(d.prefs.tz, "Asia/Tokyo");
        assert_eq!(d.prefs.kinds, prefs.kinds, "the settings are kept");
        assert_eq!(d.prefs.quiet.start, "21:30");
        assert_eq!(d.prefs.evening_summary, None);
    }

    #[test]
    fn registering_the_same_thing_again_changes_nothing_and_a_capability_change_alone_counts() {
        let (_dir, mut s) = store();
        assert!(register(&mut s, "dev-1", &token(), "UTC"));
        assert!(!register(&mut s, "dev-1", &token(), "UTC"), "identical");
        assert!(
            s.register(
                "dev-1",
                &token(),
                PushEnvironment::Sandbox,
                "UTC",
                PushCapabilities { nse_withdraw: true }
            )
            .unwrap(),
            "only the capabilities changed"
        );
        assert!(s.get("dev-1").unwrap().capabilities.nse_withdraw);
        assert!(s
            .register(
                "dev-1",
                &token(),
                PushEnvironment::Sandbox,
                "UTC",
                PushCapabilities::default()
            )
            .unwrap());
        assert!(
            !s.get("dev-1").unwrap().capabilities.nse_withdraw,
            "the latest wins"
        );
    }

    #[test]
    fn a_zone_this_build_does_not_know_is_stored_as_utc() {
        let (_dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "Not/AZone");
        assert_eq!(s.get("dev-1").unwrap().prefs.tz, "UTC");
        register(&mut s, "dev-1", &token(), "Europe/London");
        assert_eq!(s.get("dev-1").unwrap().prefs.tz, "Europe/London");
    }

    #[test]
    fn set_prefs_is_false_for_an_unknown_device_and_for_unchanged_settings() {
        let (_dir, mut s) = store();
        assert!(!s.set_prefs("ghost", PushPrefs::default()).unwrap());
        register(&mut s, "dev-1", &token(), "UTC");
        assert!(
            !s.set_prefs("dev-1", PushPrefs::default()).unwrap(),
            "unchanged"
        );
        let p = PushPrefs {
            kinds: PushKinds {
                review: false,
                ..PushKinds::default()
            },
            ..PushPrefs::default()
        };
        assert!(s.set_prefs("dev-1", p).unwrap());
        assert!(s.get("ghost").is_none());
    }

    #[test]
    fn removing_a_device_deletes_its_record_from_disk() {
        let (dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "UTC");
        register(&mut s, "dev-2", &"cd".repeat(32), "UTC");
        let gone = s.remove("dev-1").unwrap().expect("it existed");
        assert_eq!(gone.device_id, "dev-1");
        assert!(s.remove("dev-1").unwrap().is_none(), "already gone");
        let text = std::fs::read_to_string(dir.path().join("push/devices.json")).unwrap();
        assert!(
            !text.contains("dev-1") && !text.contains(&token()),
            "{text}"
        );
        assert!(text.contains("dev-2"));
        assert_eq!(s.ids(), vec!["dev-2".to_string()]);
    }

    // ── on disk ──────────────────────────────────────────────────────────────

    #[test]
    fn what_is_saved_reloads_whole() {
        let (dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "America/Chicago");
        let mut p = s.get("dev-1").unwrap().prefs.clone();
        p.kinds.decision = false;
        s.set_prefs("dev-1", p.clone()).unwrap();
        let before = s.get("dev-1").unwrap().clone();

        let again = DeviceStore::load(dir.path().join("push/devices.json"));
        let after = again.get("dev-1").expect("reloaded");
        assert_eq!(after.apns_token, before.apns_token);
        assert_eq!(after.push_id, before.push_id);
        assert_eq!(after.environment, before.environment);
        assert_eq!(after.prefs, p);
    }

    #[test]
    fn a_missing_or_unreadable_file_is_an_empty_store() {
        let dir = tempfile::tempdir().unwrap();
        assert!(DeviceStore::load(dir.path().join("nope.json"))
            .ids()
            .is_empty());
        let bad = dir.path().join("bad.json");
        std::fs::write(&bad, "{ this is not json").unwrap();
        assert!(DeviceStore::load(&bad).ids().is_empty());
    }

    #[test]
    fn a_record_written_before_capabilities_or_prefs_existed_still_loads_with_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        std::fs::write(
            &path,
            r#"{"devices":{"dev-1":{"device_id":"dev-1","apns_token":"abab","environment":"sandbox","push_id":"00112233445566778899aabbccddeeff"}}}"#,
        )
        .unwrap();
        let s = DeviceStore::load(&path);
        let d = s.get("dev-1").expect("loaded");
        assert_eq!(d.capabilities, PushCapabilities::default());
        assert_eq!(d.prefs, PushPrefs::default());
    }

    #[cfg(unix)]
    #[test]
    fn the_device_file_is_private_and_written_through_a_rename() {
        use std::os::unix::fs::PermissionsExt;
        let (dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "UTC");
        let path = dir.path().join("push/devices.json");
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&path), 0o600, "an APNs token is a credential");
        // A second write replaces it whole, still private, with no temporary left.
        register(&mut s, "dev-2", &"cd".repeat(32), "UTC");
        assert_eq!(mode(&path), 0o600);
        let names: Vec<String> = std::fs::read_dir(dir.path().join("push"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["devices.json".to_string()], "{names:?}");
        serde_json::from_str::<serde_json::Value>(&std::fs::read_to_string(&path).unwrap())
            .expect("always whole JSON");
    }

    #[test]
    fn a_device_record_never_prints_its_token() {
        let (_dir, mut s) = store();
        register(&mut s, "dev-1", &token(), "UTC");
        let printed = format!("{:?} {:?}", s.get("dev-1").unwrap(), s);
        assert!(!printed.contains(&token()), "{printed}");
    }
}
