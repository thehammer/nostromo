# MCP Network Transport (TLS + Bearer Token)

## Context

Nostromo's MCP server (`src/mcp/server.rs`) listens only on a Unix domain
socket today (`~/.nostromo/mcp.sock`). That is correct for in-host clients
— the existing `nostromo-mcp-bridge` and any same-machine consumer talks
to it over the socket. It is **not** sufficient for any client running
off-host: the eventual Mac-native app *can* use Unix (same machine), but
the iPhone and iPad surfaces cannot. They need a network endpoint with
authentication.

This wedge adds a TLS-terminated TCP listener that speaks the **identical**
MCP JSON-RPC framing the Unix socket already uses, gated by a bearer
token, alongside the Unix socket. It is the smallest piece of network
infrastructure that unblocks mobile work, and it deliberately defers the
*transport-shape* decision (Tailscale-to-Mac vs cloud backplane; see
B2 in `docs/plans/platform-evolution-sequencing.md`). Either bet works
on top of a TLS+token endpoint.

A minimal device-token file format is included so the listener has a
source of truth for accepted tokens. The full QR-code pairing flow is
**not** part of this wedge — that is wedge W5 (`mobile-foundations`).
This wedge ships a CLI command (`nostromo device add`) that generates
and registers a token; the operator copies it manually to the client
device. Crude but sufficient for an integration test with `curl`.

## Target
- **Repo:** nostromo
- **Branch:** `feat/mcp-network-transport`
- **Base:** `origin/main`

## Files to change

- `Cargo.toml:25-90` — add `tokio-rustls = "0.26"`, `rustls = "0.23"`,
  `rustls-pemfile = "2"`, `rcgen = "0.13"` (self-signed cert generation
  for the local case). Keep features minimal.
- `src/mcp/socket.rs:1-22` — rename to `src/mcp/transport.rs` (the
  module is no longer socket-specific). Re-export the existing
  `default_socket_path()` for backward compatibility. Add
  `default_tcp_addr()` returning `Option<SocketAddr>` from
  `NOSTROMO_MCP_TCP_ADDR` env var, default `None` (no TCP listener
  unless explicitly enabled).
- `src/mcp/server.rs:46-93` — extend `McpServer` to optionally also
  bind a TCP listener. Refactor `serve_connection` to accept any
  `AsyncRead + AsyncWrite + Unpin + Send + 'static` so it can serve
  both `UnixStream` and `tokio_rustls::server::TlsStream<TcpStream>`.
- `src/mcp/server.rs:117-183` — extend the Hello-frame phase to read
  an optional `auth_token` field. For Unix-socket connections, the
  token is optional (Unix file permissions remain the access gate).
  For TCP connections, the token is **required** and validated
  against the device-token registry. Reject with a typed
  `Error::Unauthorized` JSON-RPC frame and close the connection if
  absent or invalid.
- `src/mcp/devices.rs` (new) — small module managing
  `~/.nostromo/devices.json` with structure
  `{"devices": [{"id": "...", "label": "...", "token_hash": "...",
  "created_at": "...", "last_seen_at": "..."}]}`. Tokens hashed with
  SHA-256 at rest; the plaintext is shown only at creation.
  Functions: `load()`, `save()`, `add(label) -> (Device, plain_token)`,
  `validate(plain_token) -> Option<Device>`, `update_last_seen(id)`.
- `src/bin/nostromo_device.rs` (new binary) or `src/main.rs` (new
  subcommand) — `nostromo device add --label <name>` prints the
  plaintext token once, then exits. `nostromo device list` shows
  registered devices (no tokens). `nostromo device revoke <id>`
  removes one.
- `src/mcp/tls.rs` (new) — TLS bring-up. Loads a cert+key pair from
  `~/.nostromo/tls/{cert.pem,key.pem}`. If missing, generates a
  self-signed cert with `rcgen` valid for 10 years, CN =
  `nostromo.local`. Logs the SHA-256 fingerprint at bind time so the
  operator can pin it on the client. Returns a
  `tokio_rustls::TlsAcceptor`.
- `src/app.rs:332-345` — extend the `McpServer::bind` call site to
  pass the optional TCP addr from `default_tcp_addr()`.
- `tests/mcp_network_transport.rs` (new) — integration test: spin up
  the MCP server with a TCP listener on `127.0.0.1:0` (ephemeral
  port), register a device token, connect with `tokio-rustls`,
  perform a `tools/list` round-trip, verify a request without a valid
  token is rejected.

## Approach

1. **Generalise the connection-serving fn.** `serve_connection` in
   `src/mcp/server.rs` currently takes `UnixStream`. Make it generic:
   `async fn serve_connection<S>(stream: S, state: McpSharedState,
   require_auth: bool)` where `S: AsyncRead + AsyncWrite + Unpin +
   Send + 'static`. The split happens via `tokio::io::split`, which
   works on any `AsyncRead + AsyncWrite`.
2. **Hello-frame auth extension.** The current Hello shape is
   `{"type":"hello","pty_id":"<uuid>"}`. Extend to
   `{"type":"hello","pty_id":"<uuid>","auth_token":"<plain>"}`. If
   `require_auth` is true and the token is absent or
   `devices::validate` returns `None`, write a typed error frame
   `{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":
   "Unauthorized"}}` and close. The error code -32001 is a
   server-defined extension (the JSON-RPC reserved range is
   -32000..-32099) and should be documented in `protocol.rs`-style
   rustdoc.
3. **Device registry.** Keep it boring: a JSON file under
   `~/.nostromo/devices.json`, single-writer (the
   `nostromo device add` CLI), read-on-each-validate by the server
   (file is small; performance is not a concern). Tokens are 32
   random bytes, base64-encoded, hashed with SHA-256 at rest. The
   plaintext is *only* returned from `add()` and never persisted.
4. **TLS bring-up.** `src/mcp/tls.rs::ensure_cert()` reads
   `~/.nostromo/tls/cert.pem` and `key.pem` if present; otherwise
   generates a self-signed cert with `rcgen` (CN = `nostromo.local`,
   SANs = `nostromo.local`, `localhost`, `127.0.0.1`), persists
   them to disk with mode `0600`, and returns a `rustls::ServerConfig`.
   Log the cert fingerprint (`sha256:abcd…`) at bind time at INFO so
   the operator can paste it into the client's pin config.
5. **Bind both listeners.** `McpServer::bind` continues to bind the
   Unix socket. If `NOSTROMO_MCP_TCP_ADDR` is set, *also* bind the
   TCP listener and wrap each accepted connection in a `TlsAcceptor`.
   The two accept loops are independent tasks; one failing must not
   take down the other. `serve_connection` is called with
   `require_auth = true` for TCP, `require_auth = false` for Unix.
6. **CLI integration.** `nostromo device {add,list,revoke}` — wire as
   subcommands in `src/main.rs` using clap. Generate token, register,
   print plaintext exactly once, exit. Document in `README.md`
   §"Pairing a device" (or add the section if absent).
7. **Test.** New `tests/mcp_network_transport.rs`:
   - Bring up the MCP server bound to `127.0.0.1:0` plus an
     ephemeral Unix socket in a tempdir.
   - Resolve the actual ephemeral port from the listener.
   - Register a device token in a tempdir-scoped
     `NOSTROMO_DEVICES_PATH` (also a new env override, like the
     socket override).
   - Open a `TcpStream`, wrap with `tokio_rustls::TlsConnector`
     configured with a no-verify root store (acceptable in test only;
     leave a `TODO` comment noting production code on the client
     side must pin the fingerprint).
   - Send Hello with the valid token, then `tools/list`, expect a
     well-formed response.
   - Open a second connection without a token, expect the
     `Unauthorized` frame and EOF.

## Acceptance criteria

Behavioural (none from Ada — internal infrastructure):

Technical / non-functional (Archie):

- The Unix-socket MCP path behaves identically to before this change.
  All existing MCP integration tests pass without modification.
- When `NOSTROMO_MCP_TCP_ADDR` is **unset**, no TCP listener is bound.
  No new ports open by default after this change.
- When `NOSTROMO_MCP_TCP_ADDR` is set, the TCP listener binds, logs
  its address at INFO, logs the TLS cert fingerprint, and accepts
  TLS connections.
- TCP connections without a valid `auth_token` in the Hello frame are
  rejected with the typed `Unauthorized` error and the socket closes
  within one round-trip.
- TCP connections **with** a valid `auth_token` complete the MCP
  `initialize` / `tools/list` round-trip identically to a Unix
  connection.
- Device tokens are stored as SHA-256 hashes; plaintext appears only
  on the stdout of `nostromo device add` and is never logged.
- A `nostromo device add --label <name>` invocation followed by a
  `nostromo device list` shows the new device. `nostromo device
  revoke <id>` removes it and subsequent connections with that token
  fail authentication.
- Self-signed cert generation triggers exactly once per host; the
  cert is reused across daemon restarts.
- No regressions to TUI or daemon: existing tests pass.
- PR body references this plan and the sequencing memo.

## Out of scope

- Full QR-code pairing flow (wedge W5).
- Moving MCP hosting from the TUI into the daemon (decision B1; the
  sequencing memo defers this).
- Push notifications / APNs relay (wedge W5).
- Cloud-backplane vs Tailscale decision (decision B2). This wedge
  works under either bet.
- Per-tool authorization scopes. All authenticated TCP clients see
  the same tool set Unix clients see today.
- Rate limiting on the TCP listener. Defer to ops or to a follow-up
  if abuse becomes a concern.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "TLS, auth surface, and connection-handling generics. Errors here are security-relevant. New crates wired in; not just gluing existing code."
  redd:
    model: sonnet
    effort: high
    rationale: "Network + TLS + auth tests need careful setup; ephemeral ports, no-verify connector, both happy-path and rejection paths must be covered."
  marty:
    model: sonnet
    effort: medium
    rationale: "Module boundaries (transport/tls/devices) likely need a tidy-up pass once Cody lands. Refactor scope is bounded."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First network listener in the codebase. Auth + TLS + token handling. Reviewer needs to be paranoid; missed bugs are CVE-shaped."
```
