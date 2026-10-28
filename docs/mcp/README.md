# Nostromo MCP Server — Phase 1

Nostromo exposes an in-process MCP server so agents running inside its PTY
views can query nostromd's state.

## Architecture

```
claude (inside a PTY pane)
  │
  │  stdio (MCP JSON-RPC 2.0)
  ▼
nostromo-mcp-bridge
  │
  │  Unix domain socket  (~/.nostromo/mcp-daemon.sock)
  ▼
nostromd (McpServer / McpSharedState)
```

The bridge binary connects to the socket and pipes stdin/stdout bidirectionally.
Before forwarding MCP frames it sends a one-line JSON `Hello` so the server
can identify which PTY view the caller belongs to.

## Env vars injected into every PTY

| Variable              | Description                                  |
|-----------------------|----------------------------------------------|
| `NOSTROMO_VIEW_ID`    | Which view spawned this PTY (e.g. `"perri"`) |
| `NOSTROMO_PTY_ID`     | UUID for this PTY invocation                 |
| `NOSTROMO_SESSION_ID` | UUID for this session                        |
| `NOSTROMO_MCP_SOCKET` | Path to the Unix socket                      |

## Registering with Claude Code

Copy `example-claude-mcp.json` into your project's `.claude/settings.json`
`mcpServers` key (or merge the `nostromo` entry into an existing config):

```json
{
  "mcpServers": {
    "nostromo": {
      "type": "stdio",
      "command": "nostromo-mcp-bridge"
    }
  }
}
```

`NOSTROMO_MCP_SOCKET` and `NOSTROMO_PTY_ID` are inherited automatically from
the PTY environment — no explicit `env` configuration needed when the agent is
running inside Nostromo.

## Installing the bridge

```sh
cargo build --release --bin nostromo-mcp-bridge
cp target/release/nostromo-mcp-bridge /usr/local/bin/
```

## Phase 1 tool surface

### `nostromo.get_self`

Returns identity information about the calling PTY session.

**Input:** `{}` (no arguments)

**Output (success):**
```json
{
  "view_id":        "perri",
  "view_title":     "Perri",
  "pty_id":         "<uuid>",
  "session_id":     "<uuid>",
  "pane_ids":       ["pr_queue", "diff", "repl"],
  "nostromo_version": "0.1.0"
}
```

**Output (caller not identified):**
```json
{ "error": "unidentified_caller", "reason": "..." }
```

## Manual smoke test

```sh
# In one terminal — start Nostromo and open Perri.
# The MCP socket is created at ~/.nostromo/mcp-daemon.sock.

# In another terminal — send a raw Hello + initialize + tools/call:
(
  printf '{"type":"hello","pty_id":""}\n'
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}\n'
  printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nostromo.get_self","arguments":{}}}\n'
  sleep 1
) | socat - UNIX-CONNECT:$HOME/.nostromo/mcp-daemon.sock
```

## Bridge reconnect and the "tools offline" signal

`nostromo-mcp-bridge` is a long-lived proxy: when its daemon connection drops it answers in-flight
requests with JSON-RPC `-32000` ("nostromo daemon connection lost; the outcome of this call is unknown; check state before retrying" — the
bridge cannot tell a call that never arrived from one that ran with its response lost, so do not blindly retry), reconnects with jittered
exponential backoff (100 ms doubling to 5 s, never giving up while stdin is open), re-sends the same
Hello frame, replays `initialize` / `notifications/initialized`, and sends the client
`notifications/tools/list_changed`. Frames sent while disconnected are queued (256 frames / 1 MiB).
It exits (code 0) only when stdin closes. Events are logged, without frame contents, to
`~/.nostromo/logs/mcp-bridge-<pid>.log` (0600, newest 20 files, 256 KiB each; logs of still-running bridges are never pruned; the directory is 0700
and the log is opened with `O_NOFOLLOW`).

The daemon never closes a connection for a bad frame: non-UTF-8 or malformed frames get `-32700`,
non-object or over-2-MiB frames `-32600` (id `null`), and the connection carries on. Every accept and
close is logged (`reason`: `peer_eof`, `peer_gone`, `read_error`).

The daemon counts live bridge connections per pty id. `nostromo_get_self` reports
`mcp_bridge_connected`, `mcp_bridge_connections` and `mcp_bridge_reconnects`. The app is told through
`SessionInfo.mcp_bridge_connected` (optional, omitted when unknown) and a `session_bridge` message;
the Mac app shows "Tools offline" for a running session whose bridge has been gone for more than 10 s.
