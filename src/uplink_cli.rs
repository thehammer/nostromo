//! `nostromo uplink pair`: enrol this Mac as a satellite of a primary.
//!
//! The code is issued on the primary by `nostromo device pair --satellite
//! <host>`. This dials the primary's pairing socket without a token, sends one
//! `Pair`, and writes the returned token to the token file (mode 0600). The
//! token is never printed, logged or put in an error.

use std::io::Write;
use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::ipc::devices::{DeviceKind, PairRefusedReason};
use crate::ipc::protocol::{ClientMsg, ServerMsg, PROTOCOL_VERSION};

pub const EXIT_OK: i32 = 0;
pub const EXIT_FAILED: i32 = 1;

/// How long to wait for the primary's answer.
const REPLY_TIMEOUT: Duration = Duration::from_secs(15);

/// Write `token` to `path`, mode 0600, creating the parent directory. An
/// existing file is replaced (a re-enrolment).
pub fn write_token(path: &Path, token: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    // Remove first so the new file is created with the right mode even over
    // an old, looser one.
    let _ = std::fs::remove_file(path);
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts
        .open(path)
        .with_context(|| format!("writing the token to {}", path.display()))?;
    f.write_all(token.as_bytes())?;
    f.write_all(b"\n")?;
    Ok(())
}

/// Redeem `code` against `url` as `host_name`, save the token at `token_path`,
/// and print one line. Returns the exit code.
pub async fn pair(
    url: &str,
    code: &str,
    host_name: &str,
    token_path: &Path,
    out: &mut impl Write,
) -> Result<i32> {
    let (mut ws, _) = tokio::time::timeout(REPLY_TIMEOUT, tokio_tungstenite::connect_async(url))
        .await
        .context("timed out connecting to the primary")?
        .with_context(|| format!("connecting to {url}"))?;
    let pair = ClientMsg::Pair {
        code: code.trim().replace(' ', ""),
        name: host_name.to_string(),
        kind: DeviceKind::Satellite,
        replace: false,
    };
    // A `Hello` first is optional on a pairing socket; the version check is.
    let hello = ClientMsg::Hello {
        client_id: "nostromo-uplink-pair".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: None,
        capabilities: vec![],
        role: None,
    };
    ws.send(Message::Text(serde_json::to_string(&hello)?))
        .await?;
    ws.send(Message::Text(serde_json::to_string(&pair)?))
        .await?;
    let reply = tokio::time::timeout(REPLY_TIMEOUT, async {
        while let Some(frame) = ws.next().await {
            if let Message::Text(t) = frame? {
                match serde_json::from_str::<ServerMsg>(&t) {
                    Ok(m @ (ServerMsg::Paired { .. } | ServerMsg::PairRefused { .. })) => {
                        return Ok::<_, anyhow::Error>(Some(m))
                    }
                    Ok(ServerMsg::Error { message }) => bail!("the primary refused: {message}"),
                    _ => {}
                }
            }
        }
        Ok(None)
    })
    .await
    .context("timed out waiting for the primary")??;
    let _ = ws.close(None).await;

    match reply {
        Some(ServerMsg::Paired { token, name, .. }) => {
            write_token(token_path, &token.0)?;
            if name != host_name {
                writeln!(
                    out,
                    "Enrolled as {name}, but host_name is {host_name}: set host_name to match or re-enrol."
                )?;
            }
            writeln!(out, "Enrolled {host_name} with {}", server_of(url))?;
            Ok(EXIT_OK)
        }
        Some(ServerMsg::PairRefused { reason }) => {
            let line = match reason {
                PairRefusedReason::Expired => {
                    "That code has expired. Run `nostromo device pair --satellite <host>` on the primary for a new one."
                }
                PairRefusedReason::Invalid => "That code is not valid.",
            };
            writeln!(out, "{line}")?;
            Ok(EXIT_FAILED)
        }
        _ => bail!("the primary closed the connection without answering"),
    }
}

/// The `host:port` of a WebSocket URL, for the confirmation line.
fn server_of(url: &str) -> String {
    url.split_once("://")
        .map_or(url, |(_, rest)| rest)
        .trim_end_matches('/')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_token_file_is_0600_even_over_a_looser_old_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a").join("uplink-token");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "old").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        write_token(&path, "secret-token").unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap().trim(),
            "secret-token"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn the_server_is_shown_without_the_scheme() {
        assert_eq!(server_of("ws://10.0.0.5:47101/"), "10.0.0.5:47101");
    }
}
