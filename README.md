# nostromo

The Nostromo macOS/iOS app and its companion daemon, `nostromd`, for working
with AI agents (fred, perri, claudia, cody, mother). The app is built with
`make mac` and installed with `make mac-install`; the daemon, MCP bridge and
hooks are the Rust crate in this repo.

The Rust TUI was removed in October 2026; see git history before this commit.

See [`docs/PLAN.md`](docs/PLAN.md) for the original design and phased build plan.

## Design philosophy

Nostromo is built around the idea that good tooling should embody discipline structurally — that staying aware of what your AI agents are doing, reviewing their output, and maintaining sustained focus shouldn't depend on individual willpower. The cockpit should make the right practice the easy practice.

This is one concrete expression of **[The AIghtfold Path](https://github.com/thehammer/aightfold-path)** — a framework for skillful AI-assisted development. Nostromo addresses the orchestration and awareness layer: Right Mindfulness (all agent state visible in one place), Right Action (review built into the workflow via approval modals and PR queue), and Right Concentration (persistent sessions, layout memory, low context-switching cost).

The knowledge layer — pre-indexed understanding of your corpora — is handled by **[Callimachus](https://github.com/thehammer/callimachus)**, a companion project from the same work.

## Build

```bash
cargo build --release
# or
make install   # installs nostromd, nostromo-mcp-bridge, nostromo-activity-hook, nostromo-guard
```

## Configuration

### Code root

Nostromo looks for your repos (Repo docs, the new-Focus project picker, the
Send to agent sheet) in the folder whose children are the repos. It defaults to
`~/Code`. To change it, set `code_root` in `config.toml`:

```toml
code_root = "~/Software Development"
```

On macOS that file is `~/Library/Application Support/nostromo/config.toml`
(the path the daemon actually reads, via the `directories` crate). The
`NOSTROMO_CODE_ROOT` environment variable overrides it for the daemon. The app
reads the same env var and file, so launch it from a shell with the variable
set, or use `config.toml`. Restart `nostromd` and relaunch the app after
changing it.

### Agents

Every built-in agent (Fred, Perri, Teri) is on by default, and Mother cannot be
turned off. To switch one off, give it a table in `config.toml`:

```toml
[agents.fred]
enabled = false

[agents.perri]
enabled = false
```

A disabled agent uses no resources and takes no space: `nostromd` does not
start its pollers, the MCP server does not register its tools, views or pane
sources, and the macOS app hides its sidebar entry. With Perri off,
`nostromo.show` cannot show PR views (`review_queue`, `pr_diff`,
`pr_conversation`); files and tickets still work.

Unknown agent names, and `mother`, are ignored with a warning in the daemon log.
Extra keys inside an agent's table are ignored too. That table is where each
agent's future per-agent settings will go.

The file is `~/Library/Application Support/nostromo/config.toml` on macOS and
`~/.config/nostromo/config.toml` elsewhere. Restart `nostromd` after changing
it; the app picks the change up on its next connection.

## Daemon

`nostromd` is a daemon that runs in the background and serves the macOS and iOS
apps over a Unix socket at `~/.nostromo/nostromd.sock`. It provides shared live
state (agent activity events, the Mother job queue) and owns the PTY child
processes, so sessions survive the app closing and reopening. Stopping
`nostromd` (SIGTERM) cleanly kills all child processes.

### Scrollback ring

`nostromd` keeps up to **2 MiB** of raw terminal output per PTY (or 10 000
newline boundaries, whichever is reached first).  On reattach the ring is
replayed in full before live output begins.

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

## PR checks

Every pull request against `main` runs the Rust build/lint/test, the Python
tooling tests, the Swift tests for the Mac app (`make mac-test`) and for
NostromoKit (`make kit-test`), and an iOS simulator build on GitHub. Those
two Make targets remain the local commands. See [`docs/ci.md`](docs/ci.md)
for the job list, runtimes and how to make a check required.

## Health check

```bash
bin/nostromo-doctor
```

A one-shot, no-build health check across the daemon, GUI, IPC channel, and
known agent sessions — one OK/WARN/FAIL/INCONCLUSIVE line per check, a
next-step for anything not OK, and a non-zero exit iff something FAILed.
See [`docs/nostromo-doctor.md`](docs/nostromo-doctor.md) for what it checks
and how to add a check.

## Phases

- **Phase 1**: Fred + Perri parity via bash `--json` mode
- **Phase 2**: Embedded PTY + syntax-highlighted diffs
- **Phase 3**: Mother queue + inline `await` approval modals
- **Phase 4**: Native Microsoft Graph + GitHub clients
- **Phase 5a**: `nostromd` daemon + Unix socket IPC
- **Phase 5b**: Daemon-owned PTYs with detach/attach + scrollback
- **Phase 5c** *(current)*: Split panes, command palette, sweater status colours
