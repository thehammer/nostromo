//! `nostromd remote-shells`: what the controlled-restart guard asks the
//! running daemon before anything restarts it. A plain client of the daemon's
//! socket: it needs no operator trust because the answer is metadata only
//! (which remote shells are open, and since when) and nothing changes.

use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use tokio::net::UnixStream;

use crate::ipc::codec::{read_frame, write_frame};
use crate::ipc::protocol::{
    ClientMsg, RemoteShellSummary, ServerMsg, Topic, MIN_CLIENT_VERSION, PROTOCOL_VERSION,
};

/// No remote shell is open.
pub const EXIT_NONE_OPEN: i32 = 0;
/// No daemon answered.
pub const EXIT_NO_DAEMON: i32 = 2;
/// At least one remote shell is open.
pub const EXIT_SHELLS_OPEN: i32 = 3;

const ANSWER_TIMEOUT: Duration = Duration::from_secs(5);

/// Ask the daemon on `socket` for its open remote shells.
pub async fn fetch(socket: &Path) -> Result<Vec<RemoteShellSummary>> {
    tokio::time::timeout(ANSWER_TIMEOUT, ask(socket))
        .await
        .context("the daemon did not answer in time")?
}

async fn ask(socket: &Path) -> Result<Vec<RemoteShellSummary>> {
    let stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connecting to {}", socket.display()))?;
    let (mut reader, mut writer) = tokio::io::split(stream);
    let hello = ClientMsg::Hello {
        client_id: format!("remote-shells-{}", std::process::id()),
        protocol_version: PROTOCOL_VERSION.max(MIN_CLIENT_VERSION),
        client_kind: None,
    };
    write_frame(&mut writer, &serde_json::to_vec(&hello)?).await?;
    let welcome: ServerMsg = serde_json::from_slice(&read_frame(&mut reader).await?)?;
    if !matches!(welcome, ServerMsg::Welcome { .. }) {
        bail!("the daemon did not welcome the client");
    }
    // The handshake wants a `Subscribe` next; the narrowest topic will do (the
    // frames it brings are skipped below). Nothing here claims operator status.
    let subscribe = ClientMsg::Subscribe {
        topics: vec![Topic::Terminal],
        renders_decisions: false,
        renders_approvals: false,
        capabilities: Vec::new(),
        operator_nonce: None,
    };
    write_frame(&mut writer, &serde_json::to_vec(&subscribe)?).await?;
    write_frame(
        &mut writer,
        &serde_json::to_vec(&ClientMsg::TerminalRemoteSummaryRequest)?,
    )
    .await?;
    loop {
        let msg: ServerMsg = serde_json::from_slice(&read_frame(&mut reader).await?)?;
        if let ServerMsg::TerminalRemoteSummary { shells } = msg {
            return Ok(shells);
        }
    }
}

/// The exit code for what was found.
pub fn exit_code(shells: &[RemoteShellSummary]) -> i32 {
    if shells.is_empty() {
        EXIT_NONE_OPEN
    } else {
        EXIT_SHELLS_OPEN
    }
}

/// One line per open shell: project, environment, service and age.
pub fn render_text(shells: &[RemoteShellSummary], now: DateTime<Utc>) -> String {
    shells
        .iter()
        .map(|s| {
            format!(
                "{} {} {} (open {})\n",
                s.target.project,
                s.target.environment,
                s.target.service,
                age(now - s.opened_at)
            )
        })
        .collect()
}

/// `{"shells": [{project, environment, service, label, opened_at, age_secs}]}`.
pub fn render_json(shells: &[RemoteShellSummary], now: DateTime<Utc>) -> String {
    let shells: Vec<_> = shells
        .iter()
        .map(|s| {
            serde_json::json!({
                "project": s.target.project,
                "environment": s.target.environment,
                "service": s.target.service,
                "label": s.label,
                "opened_at": s.opened_at,
                "age_secs": (now - s.opened_at).num_seconds().max(0),
            })
        })
        .collect();
    serde_json::json!({ "shells": shells }).to_string()
}

fn age(d: chrono::Duration) -> String {
    let secs = d.num_seconds().max(0);
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m", secs / 60),
        _ => format!("{}h{}m", secs / 3600, secs % 3600 / 60),
    }
}

/// Run `nostromd remote-shells [--json]`; the process exit code.
pub async fn run(args: &[String], socket: &Path) -> i32 {
    let json = args.iter().any(|a| a == "--json");
    match fetch(socket).await {
        Ok(shells) => {
            let now = Utc::now();
            if json {
                println!("{}", render_json(&shells, now));
            } else {
                print!("{}", render_text(&shells, now));
            }
            exit_code(&shells)
        }
        Err(e) => {
            eprintln!("no daemon answered: {e:#}");
            EXIT_NO_DAEMON
        }
    }
}
