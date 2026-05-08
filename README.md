# nostromo

A Ratatui-based AI agent IDE — unified TUI dashboard for fred, perri, claudia,
cody, and mother. Replaces the tmux fred/perri bash dashboards in phase 1, then
grows into a full workspace.

See [`docs/PLAN.md`](docs/PLAN.md) for the full design and phased build plan.

## Usage

```bash
nostromo              # opens all-views layout (default)
nostromo --view fred  # Fred: mailbox + calendar
nostromo --view perri # Perri: PR queue + diff
```

## Keys

| Key             | Action                         |
|-----------------|--------------------------------|
| `Tab`           | Next view                      |
| `Shift-Tab`     | Previous view                  |
| `q` / `Ctrl-C`  | Quit                           |
| `Enter`         | Open REPL for active view      |
| Mouse click tab | Switch view                    |

## Build

```bash
cargo build --release
# or
make install
```

## Daemon

Phase 5a introduces `nostromd`, a companion daemon that runs in the background
and shares live state (agent activity events, Mother job queue) across all TUI
instances over a Unix socket at `~/.nostromo/nostromd.sock`.

The TUI works perfectly without the daemon — it falls back to in-process mode
automatically.

### Install

```bash
make install-daemon
```

This builds `nostromd` in release mode, copies it to `~/.local/bin/nostromd`,
writes a launchd plist to `~/Library/LaunchAgents/com.hammer.nostromd.plist`,
and bootstraps it so it starts at login.

### Inspect logs

```bash
# Structured JSON log (rotated daily)
tail -f ~/.cache/nostromd/log/nostromd.log*

# launchd stdout / stderr
tail -f ~/.cache/nostromd/log/stdout.log
tail -f ~/.cache/nostromd/log/stderr.log

# launchctl status
launchctl print gui/$(id -u)/com.hammer.nostromd
```

### Uninstall

```bash
make uninstall-daemon
```

This unloads the agent, removes the plist, and deletes the binary.

### Flags

| Flag          | Effect                                         |
|---------------|------------------------------------------------|
| `--no-daemon` | Skip daemon connection and run in-process mode |

## Phases

- **Phase 1**: Fred + Perri parity via bash `--json` mode
- **Phase 2**: Embedded PTY + syntax-highlighted diffs
- **Phase 3**: Mother queue + inline `await` approval modals
- **Phase 4**: Native Microsoft Graph + GitHub clients
- **Phase 5a** *(current)*: `nostromd` daemon + Unix socket IPC
- **Phase 5b**: PTY ownership moves to daemon (detach/attach)
- **Phase 5c**: Split panes, layout changes, command palette
