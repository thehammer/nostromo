//! `nostromo device ...`: pair, list and revoke phones, iPads and satellite Macs
//! through the local daemon. The binary (`src/bin/nostromo_cli.rs`) is thin;
//! the output formats and exit codes live here so they can be tested with the
//! daemon's replies stubbed.
//!
//! Nothing printed here is a token or a hash: the daemon never sends either to
//! an admin client.

use std::io::Write;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use tokio::sync::broadcast;

use crate::ipc::client::{ConnectionState, DaemonClient};
use crate::ipc::devices::{DeviceSummary, PairOutcomeKind, RevokedBy, SatelliteAdmin};
use crate::ipc::protocol::{default_socket_path, ClientMsg, ServerMsg};

/// Ada's copy: mail, calendar and todos are not shared in this version.
pub const MAIL_LINE: &str =
    "Mail, calendar and todos aren't shared from your Macs in this version.";
pub const EXPIRED_LINE: &str = "Code expired. Run the command again for a new one.";
pub const LOCKED_OUT_LINE: &str =
    "Too many wrong attempts. This code is no longer valid. Run the command again for a new one.";
pub const CANCELLED_LINE: &str = "Cancelled. The code no longer works.";
pub const FAILED_LINE: &str = "The device presented the code but the server could not save it. This code no longer works. Check the server log and run the command again.";
pub const LOST_CONNECTION_LINE: &str = "Lost the connection to the server. This code no longer works. Run the command again when you're connected.";

/// Exit codes.
pub const EXIT_OK: i32 = 0;
pub const EXIT_FAILED: i32 = 1;
pub const EXIT_CANCELLED: i32 = 130;

/// What a pairing's end prints and exits with. `None` for an outcome that is
/// not final.
pub fn outcome_report(outcome: PairOutcomeKind, name: Option<&str>) -> (String, i32) {
    match outcome {
        PairOutcomeKind::Paired => (format!("Paired: {}.", name.unwrap_or("device")), EXIT_OK),
        PairOutcomeKind::Expired => (EXPIRED_LINE.to_string(), EXIT_FAILED),
        PairOutcomeKind::LockedOut => (LOCKED_OUT_LINE.to_string(), EXIT_FAILED),
        PairOutcomeKind::Cancelled => (CANCELLED_LINE.to_string(), EXIT_CANCELLED),
        PairOutcomeKind::ConnectionLost => (LOST_CONNECTION_LINE.to_string(), EXIT_FAILED),
        PairOutcomeKind::Failed => (FAILED_LINE.to_string(), EXIT_FAILED),
    }
}

/// `123456` as `123 456`.
pub fn spaced_code(code: &str) -> String {
    if code.len() == 6 {
        format!("{} {}", &code[..3], &code[3..])
    } else {
        code.to_string()
    }
}

/// `m:ss` left until `expires_at`.
pub fn countdown(expires_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let left = (expires_at - now).num_seconds().max(0);
    format!("{}:{:02}", left / 60, left % 60)
}

/// A terminal QR for `data`, two modules per character row.
pub fn render_qr(data: &str) -> String {
    use qrcode::{Color, QrCode};
    let Ok(code) = QrCode::new(data.as_bytes()) else {
        return String::new();
    };
    let width = code.width();
    let dark = |x: usize, y: usize| x < width && y < width && code[(x, y)] == Color::Dark;
    let quiet = 2usize;
    let mut out = String::new();
    let mut y = 0;
    while y < width + 2 * quiet {
        for x in 0..width + 2 * quiet {
            let at = |dy: usize| {
                let (px, py) = (
                    x as isize - quiet as isize,
                    (y + dy) as isize - quiet as isize,
                );
                px >= 0 && py >= 0 && dark(px as usize, py as usize)
            };
            out.push(match (at(0), at(1)) {
                (true, true) => '█',
                (true, false) => '▀',
                (false, true) => '▄',
                (false, false) => ' ',
            });
        }
        out.push('\n');
        y += 2;
    }
    out
}

/// "Connected now", "just now", "2 h ago".
pub fn ago(then: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let secs = (now - then).num_seconds().max(0);
    match secs {
        0..=59 => "just now".to_string(),
        60..=3599 => format!("{} min ago", secs / 60),
        3600..=86399 => format!("{} h ago", secs / 3600),
        _ => format!("{} d ago", secs / 86400),
    }
}

fn last_seen(d: &DeviceSummary, now: DateTime<Utc>) -> String {
    if d.connected {
        "Connected now".to_string()
    } else {
        d.last_seen_at
            .map(|t| ago(t, now))
            .unwrap_or_else(|| "never".to_string())
    }
}

fn kind_name(d: &DeviceSummary) -> &'static str {
    match d.kind {
        crate::ipc::devices::DeviceKind::Iphone => "iPhone",
        crate::ipc::devices::DeviceKind::Ipad => "iPad",
        crate::ipc::devices::DeviceKind::Satellite => "Mac",
    }
}

fn table(rows: &[Vec<String>]) -> String {
    let cols = rows.iter().map(Vec::len).max().unwrap_or(0);
    let widths: Vec<usize> = (0..cols)
        .map(|c| {
            rows.iter()
                .filter_map(|r| r.get(c))
                .map(|s| s.chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in rows {
        let line: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(i, cell)| format!("{cell:<width$}", width = widths[i]))
            .collect();
        out.push_str(line.join("  ").trim_end());
        out.push('\n');
    }
    out
}

/// The `device list` output. Revoked devices go in their own group; `all` adds
/// the satellite Macs with their device-admin level.
pub fn format_device_list(
    devices: &[DeviceSummary],
    hosts: &[DeviceSummary],
    all: bool,
    now: DateTime<Utc>,
) -> String {
    let mut out = String::new();
    let active: Vec<&DeviceSummary> = devices.iter().filter(|d| d.revoked_at.is_none()).collect();
    if active.is_empty() {
        out.push_str("No devices paired.\n");
    } else {
        let mut rows = vec![vec![
            "NAME".to_string(),
            "KIND".to_string(),
            "PAIRED".to_string(),
            "LAST SEEN".to_string(),
        ]];
        for d in active {
            rows.push(vec![
                d.name.clone(),
                kind_name(d).to_string(),
                ago(d.paired_at, now),
                last_seen(d, now),
            ]);
        }
        out.push_str(&table(&rows));
    }
    let revoked: Vec<&DeviceSummary> = devices.iter().filter(|d| d.revoked_at.is_some()).collect();
    if !revoked.is_empty() {
        out.push_str("\nRevoked\n");
        let rows: Vec<Vec<String>> = revoked
            .into_iter()
            .map(|d| {
                let when = d.revoked_at.map(|t| ago(t, now)).unwrap_or_default();
                let note = match d.revoked_by {
                    Some(RevokedBy::Replaced) => "Replaced by re-pairing".to_string(),
                    Some(RevokedBy::Device) => "Removed from the device".to_string(),
                    _ => String::new(),
                };
                vec![d.name.clone(), kind_name(d).to_string(), when, note]
            })
            .collect();
        out.push_str(&table(&rows));
    }
    if all && !hosts.is_empty() {
        out.push_str("\nMacs\n");
        let mut rows = vec![vec![
            "NAME".to_string(),
            "ADMIN".to_string(),
            "PAIRED".to_string(),
            "LAST SEEN".to_string(),
        ]];
        for h in hosts.iter().filter(|h| h.revoked_at.is_none()) {
            rows.push(vec![
                h.name.clone(),
                h.admin.unwrap_or_default().as_str().to_string(),
                ago(h.paired_at, now),
                last_seen(h, now),
            ]);
        }
        out.push_str(&table(&rows));
    }
    out
}

/// The `device revoke` output.
pub fn revoke_line(name: &str, was_connected: bool) -> String {
    if was_connected {
        format!("Revoked {name}. Disconnected just now.")
    } else {
        format!("Revoked {name}. Wasn't connected; it will be refused the next time it tries.")
    }
}

/// What the daemon said when a verb failed.
pub fn admin_error_text(reason: &str) -> String {
    match reason {
        "unknown_device" => "No such device.".to_string(),
        "ambiguous_name" => "More than one device has that name; use its id.".to_string(),
        "unknown_pairing" => "No such pairing.".to_string(),
        "not_saved" => "The change took effect now but could not be saved, so it will be undone when the daemon restarts. Check the disk and the daemon log, then repeat it.".to_string(),
        "devices_unavailable" => {
            "This daemon has no device listener. Set ws_addr (or unset NOSTROMD_WS_ADDR=off) and restart it.".to_string()
        }
        other => format!("The daemon refused: {other}."),
    }
}

// ── running the commands ──────────────────────────────────────────────────────

/// Wait for the daemon's reply to `request_id`: a frame `pick` accepts, or a
/// `DeviceAdminError`.
async fn await_reply<T>(
    rx: &mut broadcast::Receiver<ServerMsg>,
    request_id: &str,
    pick: impl Fn(ServerMsg) -> Option<T>,
) -> Result<T> {
    let wait = async {
        loop {
            match rx.recv().await {
                Ok(ServerMsg::DeviceAdminError {
                    request_id: id,
                    reason,
                }) if id == request_id => bail!("{}", admin_error_text(&reason)),
                Ok(msg) => {
                    if let Some(found) = pick(msg) {
                        return Ok(found);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => bail!("the daemon connection closed"),
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(10), wait)
        .await
        .context("the daemon did not answer")?
}

fn new_request_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub async fn connect() -> Result<DaemonClient> {
    let path = default_socket_path();
    DaemonClient::connect(&path)
        .await
        .with_context(|| format!("is nostromd running? (socket {})", path.display()))
}

pub async fn list(client: &DaemonClient, all: bool, out: &mut impl Write) -> Result<i32> {
    let mut rx = client.subscribe();
    let request_id = new_request_id();
    client.send(ClientMsg::DeviceList {
        request_id: request_id.clone(),
    })?;
    let (devices, hosts) = await_reply(&mut rx, &request_id, |m| match m {
        ServerMsg::Devices { devices, hosts } => Some((devices, hosts)),
        _ => None,
    })
    .await?;
    write!(
        out,
        "{}",
        format_device_list(&devices, &hosts, all, Utc::now())
    )?;
    Ok(EXIT_OK)
}

pub async fn revoke(client: &DaemonClient, who: &str, out: &mut impl Write) -> Result<i32> {
    let mut rx = client.subscribe();
    // The name to print: the list knows it whether `who` is an id or a name.
    let list_id = new_request_id();
    client.send(ClientMsg::DeviceList {
        request_id: list_id.clone(),
    })?;
    let (devices, hosts) = await_reply(&mut rx, &list_id, |m| match m {
        ServerMsg::Devices { devices, hosts } => Some((devices, hosts)),
        _ => None,
    })
    .await?;
    let request_id = new_request_id();
    client.send(ClientMsg::DeviceRevoke {
        request_id: request_id.clone(),
        device: who.to_string(),
    })?;
    let (device_id, was_connected) = await_reply(&mut rx, &request_id, |m| match m {
        ServerMsg::DeviceRevoked {
            request_id: id,
            device_id,
            was_connected,
        } if id == request_id => Some((device_id, was_connected)),
        _ => None,
    })
    .await?;
    let name = devices
        .iter()
        .chain(hosts.iter())
        .find(|d| d.id == device_id)
        .map(|d| d.name.clone())
        .unwrap_or_else(|| who.to_string());
    writeln!(out, "{}", revoke_line(&name, was_connected))?;
    Ok(EXIT_OK)
}

pub async fn set_admin(
    client: &DaemonClient,
    host: &str,
    level: SatelliteAdmin,
    out: &mut impl Write,
) -> Result<i32> {
    let mut rx = client.subscribe();
    let request_id = new_request_id();
    client.send(ClientMsg::DeviceSetAdmin {
        request_id: request_id.clone(),
        host: host.to_string(),
        admin: level,
    })?;
    await_reply(&mut rx, &request_id, |m| match m {
        ServerMsg::Devices { .. } => Some(()),
        _ => None,
    })
    .await?;
    writeln!(out, "{host}: device admin is now {}.", level.as_str())?;
    Ok(EXIT_OK)
}

/// `host` and `port` out of the pairing URL.
fn server_of(url: &str) -> String {
    let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
    let get = |key: &str| {
        query
            .split('&')
            .find_map(|kv| kv.strip_prefix(&format!("{key}=")))
            .unwrap_or("?")
            .to_string()
    };
    format!("{}:{}", get("host"), get("port"))
}

/// Run `device pair`: show the code, stay running until the outcome, and map it
/// to an exit code. `cancel` resolves when the operator interrupts (Ctrl-C).
pub async fn pair(
    client: &DaemonClient,
    name_hint: Option<String>,
    satellite: Option<String>,
    admin: Option<SatelliteAdmin>,
    out: &mut impl Write,
    cancel: impl std::future::Future<Output = ()>,
) -> Result<i32> {
    let mut rx = client.subscribe();
    let mut state = client.connection_state();
    let request_id = new_request_id();
    let is_satellite = satellite.is_some();
    client.send(ClientMsg::DevicePairStart {
        request_id: request_id.clone(),
        name_hint,
        satellite,
        admin,
    })?;
    let (pairing_id, code, url, expires_at) = await_reply(&mut rx, &request_id, |m| match m {
        ServerMsg::DevicePairing {
            request_id: id,
            pairing_id,
            code,
            server_url,
            expires_at,
        } if id == request_id => Some((pairing_id, code, server_url, expires_at)),
        _ => None,
    })
    .await?;

    writeln!(out, "Server: {}", server_of(&url))?;
    writeln!(out, "Code:   {}", spaced_code(&code))?;
    writeln!(out)?;
    write!(out, "{}", render_qr(&url))?;
    writeln!(out)?;
    if !is_satellite {
        writeln!(out, "{MAIL_LINE}")?;
    }
    out.flush()?;

    tokio::pin!(cancel);
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            msg = rx.recv() => match msg {
                Ok(ServerMsg::DevicePairOutcome { pairing_id: id, outcome, name, .. }) if id == pairing_id => {
                    let (line, exit) = outcome_report(outcome, name.as_deref());
                    writeln!(out, "\r{line}          ")?;
                    return Ok(exit);
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => {
                    let (line, exit) = outcome_report(PairOutcomeKind::ConnectionLost, None);
                    writeln!(out, "\r{line}          ")?;
                    return Ok(exit);
                }
            },
            changed = state.changed() => {
                if changed.is_err() || !matches!(*state.borrow(), ConnectionState::Connected { .. }) {
                    let (line, exit) = outcome_report(PairOutcomeKind::ConnectionLost, None);
                    writeln!(out, "\r{line}          ")?;
                    return Ok(exit);
                }
            }
            _ = &mut cancel => {
                let _ = client.send(ClientMsg::DevicePairCancel {
                    request_id: new_request_id(),
                    pairing_id: pairing_id.clone(),
                });
                let (line, exit) = outcome_report(PairOutcomeKind::Cancelled, None);
                writeln!(out, "\r{line}          ")?;
                return Ok(exit);
            }
            _ = tick.tick() => {
                write!(out, "\rExpires in {}  ", countdown(expires_at, Utc::now()))?;
                out.flush()?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::devices::DeviceKind;

    fn summary(name: &str, kind: DeviceKind) -> DeviceSummary {
        DeviceSummary {
            id: format!("id-{name}"),
            name: name.to_string(),
            kind,
            paired_at: Utc::now() - chrono::Duration::days(2),
            last_seen_at: Some(Utc::now() - chrono::Duration::hours(2)),
            connected: false,
            revoked_at: None,
            revoked_by: None,
            admin: None,
        }
    }

    #[test]
    fn only_a_paired_outcome_exits_zero() {
        assert_eq!(
            outcome_report(PairOutcomeKind::Paired, Some("Kitchen iPad")),
            ("Paired: Kitchen iPad.".to_string(), 0)
        );
        for (outcome, line, code) in [
            (PairOutcomeKind::Expired, EXPIRED_LINE, 1),
            (PairOutcomeKind::LockedOut, LOCKED_OUT_LINE, 1),
            (PairOutcomeKind::Cancelled, CANCELLED_LINE, 130),
            (PairOutcomeKind::ConnectionLost, LOST_CONNECTION_LINE, 1),
            (PairOutcomeKind::Failed, FAILED_LINE, 1),
        ] {
            assert_eq!(outcome_report(outcome, None), (line.to_string(), code));
        }
    }

    #[test]
    fn the_copy_is_ada_s_exactly() {
        assert_eq!(
            LOST_CONNECTION_LINE,
            "Lost the connection to the server. This code no longer works. Run the command again when you're connected."
        );
        assert_eq!(
            MAIL_LINE,
            "Mail, calendar and todos aren't shared from your Macs in this version."
        );
        assert_eq!(
            EXPIRED_LINE,
            "Code expired. Run the command again for a new one."
        );
    }

    #[test]
    fn a_code_prints_in_two_groups_and_the_countdown_is_minutes_and_seconds() {
        assert_eq!(spaced_code("123456"), "123 456");
        let now = Utc::now();
        assert_eq!(countdown(now + chrono::Duration::seconds(125), now), "2:05");
        assert_eq!(countdown(now - chrono::Duration::seconds(5), now), "0:00");
    }

    #[test]
    fn the_qr_is_drawn_in_block_characters() {
        let qr = render_qr("nostromo://pair?v=1&host=h&port=1&code=123456");
        assert!(qr.lines().count() > 10);
        assert!(qr.contains('█') || qr.contains('▀'));
    }

    #[test]
    fn the_list_groups_revoked_devices_and_names_a_replacement() {
        let now = Utc::now();
        let mut live = summary("iPhone", DeviceKind::Iphone);
        live.connected = true;
        let mut old = summary("Old iPhone", DeviceKind::Iphone);
        old.revoked_at = Some(now - chrono::Duration::hours(3));
        old.revoked_by = Some(RevokedBy::Replaced);
        let text = format_device_list(&[live, old], &[], false, now);
        assert!(text.contains("NAME"));
        assert!(text.contains("Connected now"));
        assert!(text.contains("Revoked"));
        assert!(text.contains("Replaced by re-pairing"));
        assert!(text.contains("3 h ago"));
        assert!(!text.contains("Macs"));
    }

    #[test]
    fn all_adds_the_satellites_with_their_admin_level() {
        let now = Utc::now();
        let mut tokyo = summary("Tokyo", DeviceKind::Satellite);
        tokyo.admin = Some(SatelliteAdmin::RevokeOnly);
        let plain = format_device_list(&[], &[tokyo.clone()], false, now);
        assert!(!plain.contains("Tokyo"));
        let all = format_device_list(&[], &[tokyo], true, now);
        assert!(all.contains("Tokyo"));
        assert!(all.contains("revoke_only"));
    }

    #[test]
    fn revoke_says_whether_the_device_was_connected() {
        assert_eq!(
            revoke_line("iPhone", true),
            "Revoked iPhone. Disconnected just now."
        );
        assert_eq!(
            revoke_line("iPhone", false),
            "Revoked iPhone. Wasn't connected; it will be refused the next time it tries."
        );
    }

    #[test]
    fn no_output_carries_a_token_field() {
        let text = format_device_list(
            &[summary("iPhone", DeviceKind::Iphone)],
            &[],
            true,
            Utc::now(),
        );
        assert!(!text.to_lowercase().contains("token"));
    }
}
