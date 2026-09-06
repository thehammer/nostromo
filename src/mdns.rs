//! mDNS / Bonjour service advertising for `nostromd`.
//!
//! Call [`advertise`] once after the TCP listener is bound.  Keep the returned
//! [`MdnsAdvertiser`] alive for the lifetime of the process — dropping it
//! deregisters the service and shuts down the mDNS daemon thread.
//!
//! # Example
//!
//! ```no_run
//! let _mdns_guard = nostromo::mdns::advertise(47100).expect("mDNS advertise");
//! // The service is announced for as long as `_mdns_guard` lives.
//! ```

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};

/// Service type advertised on the LAN.
pub const SERVICE_TYPE: &str = "_nostromo._tcp.local.";

// ── public API ────────────────────────────────────────────────────────────────

/// A guard that keeps the mDNS advertisement alive.
///
/// Dropping this value deregisters the service and shuts down the background
/// mDNS responder thread.  The daemon **must** keep this value alive until
/// shutdown — binding to `let _mdns_guard = advertise(port)?;` at the top of
/// `main` is the canonical pattern.
pub struct MdnsAdvertiser {
    daemon:    ServiceDaemon,
    fullname:  String,
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        // Best-effort — the OS reclaims the registration on process exit anyway.
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}

/// Advertise `nostromd` on the LAN as a `_nostromo._tcp.local.` Bonjour service.
///
/// - **Instance name** is the machine hostname (trailing `.local` stripped).
///   Falls back to `"nostromd"` if the hostname cannot be read.
/// - **Host** is `<hostname>.local.` — mdns-sd will announce the host's actual
///   LAN addresses via [`ServiceInfo::enable_addr_auto`].
/// - **TXT records:** `version` (crate version) and `platform=macos`.
///
/// Returns an [`MdnsAdvertiser`] guard.  The advertisement is retracted when
/// the guard is dropped.
pub fn advertise(port: u16) -> Result<MdnsAdvertiser> {
    let instance_name = machine_hostname();
    let host_name = format!("{}.local.", instance_name);

    let props = [
        ("version", env!("CARGO_PKG_VERSION")),
        ("platform", "macos"),
    ];

    // Build the ServiceInfo.  We pass an empty IP slice and call
    // `enable_addr_auto()` so mdns-sd discovers and announces the host's
    // actual LAN addresses (and keeps them current if interfaces change).
    let service_info = ServiceInfo::new(
        SERVICE_TYPE,
        &instance_name,
        &host_name,
        "",   // ip — left empty; enable_addr_auto() fills it in
        port,
        &props[..],
    )
    .context("building mDNS ServiceInfo")?
    .enable_addr_auto();

    let daemon = ServiceDaemon::new().context("creating mDNS ServiceDaemon")?;
    let fullname = service_info.get_fullname().to_owned();
    daemon.register(service_info).context("registering mDNS service")?;

    Ok(MdnsAdvertiser { daemon, fullname })
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Return the machine hostname, suitable for use as a Bonjour instance name.
///
/// Strips a trailing `.local` suffix if present (mdns-sd appends it).
/// Falls back to `"nostromd"` on error.
fn machine_hostname() -> String {
    hostname::get()
        .ok()
        .and_then(|s| s.into_string().ok())
        .map(|s| {
            if let Some(stripped) = s.strip_suffix(".local") {
                stripped.to_owned()
            } else {
                s
            }
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "nostromd".to_owned())
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_hostname_not_empty() {
        let name = machine_hostname();
        assert!(!name.is_empty(), "hostname should not be empty");
    }

    #[test]
    fn machine_hostname_strips_local_suffix() {
        // Test the strip logic directly by simulating a hostname that has .local
        let raw = "my-mac.local".to_owned();
        let result = if let Some(stripped) = raw.strip_suffix(".local") {
            stripped.to_owned()
        } else {
            raw
        };
        assert_eq!(result, "my-mac");
    }

    #[test]
    fn machine_hostname_preserves_plain_hostname() {
        let raw = "my-macbook-pro".to_owned();
        let result = if let Some(stripped) = raw.strip_suffix(".local") {
            stripped.to_owned()
        } else {
            raw
        };
        assert_eq!(result, "my-macbook-pro");
    }
}
