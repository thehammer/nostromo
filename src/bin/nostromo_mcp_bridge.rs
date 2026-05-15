//! `nostromo-mcp-bridge` — stdio ↔ Unix socket bridge for the Nostromo MCP server.
//!
//! Claude Code's MCP integration expects a `stdio` server: a child process
//! whose stdin/stdout carry JSON-RPC 2.0 frames.  This binary bridges that
//! expectation to Nostromo's Unix domain socket.
//!
//! ## Identification
//!
//! Before forwarding stdin/stdout the bridge sends a single-line JSON `Hello`
//! frame so the MCP server can associate this connection with the Nostromo PTY
//! that spawned it:
//!
//! ```json
//! {"type":"hello","pty_id":"<NOSTROMO_PTY_ID>"}
//! ```
//!
//! Both env vars are injected by Nostromo when it spawns the agent process.
//! If they are absent the bridge still connects; the server will return
//! `{"error":"unidentified_caller"}` when `get_self` is called.
//!
//! ## Usage (in `.claude/settings.json`)
//!
//! ```json
//! {
//!   "mcpServers": {
//!     "nostromo": {
//!       "type": "stdio",
//!       "command": "nostromo-mcp-bridge"
//!     }
//!   }
//! }
//! ```
//!
//! `NOSTROMO_MCP_SOCKET` and `NOSTROMO_PTY_ID` are inherited automatically
//! from the PTY environment.

use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process;

fn main() {
    if let Err(e) = run() {
        eprintln!("nostromo-mcp-bridge: {e:#}");
        process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let socket_path = std::env::var("NOSTROMO_MCP_SOCKET").unwrap_or_else(|_| {
        dirs_next::home_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
            .join(".nostromo")
            .join("mcp.sock")
            .to_string_lossy()
            .into_owned()
    });

    let pty_id = std::env::var("NOSTROMO_PTY_ID").unwrap_or_default();

    // Connect to the MCP socket.
    let stream = UnixStream::connect(&socket_path)
        .map_err(|e| anyhow::anyhow!("cannot connect to MCP socket {socket_path:?}: {e}"))?;

    // Send Hello frame so the server can correlate us with a PTY identity.
    let hello = format!("{{\"type\":\"hello\",\"pty_id\":\"{pty_id}\"}}\n");
    {
        let mut w = stream.try_clone()?;
        w.write_all(hello.as_bytes())?;
    }

    // Thread 1: stdin → socket
    let mut write_half = stream.try_clone()?;
    let to_server = std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match std::io::stdin().read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if write_half.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        // Signal the other half to stop.
        let _ = write_half.shutdown(Shutdown::Both);
    });

    // Thread 2: socket → stdout (main thread)
    let mut buf = [0u8; 4096];
    loop {
        match stream.try_clone()?.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if std::io::stdout().write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }

    let _ = to_server.join();
    Ok(())
}
