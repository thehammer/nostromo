# nostromo

A Ratatui-based AI agent IDE — unified TUI dashboard for fred, perri, claudia,
cody, and mother. Replaces the tmux fred/perri bash dashboards in phase 1, then
grows into a full workspace.

See [`docs/PLAN.md`](docs/PLAN.md) for the full design and phased build plan.

## Design philosophy

Nostromo is built around the idea that good tooling should embody discipline structurally — that staying aware of what your AI agents are doing, reviewing their output, and maintaining sustained focus shouldn't depend on individual willpower. The cockpit should make the right practice the easy practice.

This is one concrete expression of **[The AIghtfold Path](https://github.com/thehammer/aightfold-path)** — a framework for skillful AI-assisted development. Nostromo addresses the orchestration and awareness layer: Right Mindfulness (all agent state visible in one place), Right Action (review built into the workflow via approval modals and PR queue), and Right Concentration (persistent sessions, layout memory, low context-switching cost).

The knowledge layer — pre-indexed understanding of your corpora — is handled by **[Callimachus](https://github.com/thehammer/callimachus)**, a companion project from the same work.

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
| `Ctrl-P`        | Open command palette           |
| `Ctrl-R`        | Toggle right context panel     |
| `Ctrl-B`        | Open break-glass modal         |
| `Ctrl-\`        | Toggle PTY input capture       |

## Layout chords (`Ctrl-W` + …)

`Ctrl-W` opens a one-shot chord mode.  Press the second key immediately after:

| Second key | Action                                        |
|------------|-----------------------------------------------|
| `t`        | Toggle split mode on/off                      |
| `s`        | Split current pane **side-by-side** (vertical split) |
| `v`        | Split current pane **top/bottom** (horizontal split) |
| `q`        | Close the focused pane                        |
| `h` / `k`  | Move focus to the left/upper pane             |
| `l` / `j`  | Move focus to the right/lower pane            |

Layout is persisted to `~/.nostromo/layout.toml` after every change and
restored on the next launch.  If the file is absent or unreadable, nostromo
starts in single-pane mode (identical to pre-5c behaviour).

## Command palette (`Ctrl-P`)

The palette overlays the current layout and provides fuzzy-search over all
available actions:

- **Navigation** — switch to any view (Fred, Perri, Claudia, Cody, Kennedy, Mother)
- **Agent REPLs** — spawn a REPL for any agent
- **Layout** — split panes, close pane, toggle split/right-panel mode
- **Mother** — approve or cancel running jobs
- **PR** — jump to an open PR diff in Perri

Type to filter (subsequence fuzzy match), `↑`/`↓` to navigate, `Enter` to
execute, `Esc` to dismiss.

## Status-bar tab colours

The tab bar uses sweater colours to signal load:

| Tab     | Amber                              | Red                               |
|---------|------------------------------------|-----------------------------------|
| Perri   | > 5 open PRs awaiting review       | > 10 open PRs awaiting review     |
| Cody    | Any Mother job running > 15 min    | —                                 |
| Mother  | Any Mother job running > 15 min    | —                                 |

## Build

```bash
cargo build --release
# or
make install
```

## Daemon

`nostromd` is a companion daemon that runs in the background and provides two
services to all TUI instances over a Unix socket at `~/.nostromo/nostromd.sock`:

1. **Shared live state** — agent activity events, Mother job queue (Phase 5a).
2. **PTY ownership** — PTY child processes live *inside the daemon*, so they
   survive TUI close and reopen (Phase 5b).

The TUI works perfectly without the daemon — it falls back to in-process mode
automatically.

### Reattach behaviour (Phase 5b)

When `nostromd` is running:

- Opening a REPL view (e.g. Fred, Cody) spawns a PTY child inside the daemon.
- **Quitting nostromo** (Ctrl-C) sends `PtyDetach` — the PTY child keeps
  running under `nostromd`; you can verify with `ps` or in the daemon log.
- **Reopening nostromo** auto-reattaches: the view calls `PtyList`, finds the
  live PTY, sends `PtyAttach`, and receives a `PtyScrollback` frame containing
  the full terminal history before live output resumes.  Your session state is
  preserved as if you never closed the TUI.
- **Stopping `nostromd`** (SIGTERM) cleanly kills all child processes — no
  zombies.

When the daemon is **not** running the TUI falls back to in-process PTYs with
no behaviour change.

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

### Flags

| Flag          | Effect                                         |
|---------------|------------------------------------------------|
| `--no-daemon` | Skip daemon connection and run in-process mode |

## Phases

- **Phase 1**: Fred + Perri parity via bash `--json` mode
- **Phase 2**: Embedded PTY + syntax-highlighted diffs
- **Phase 3**: Mother queue + inline `await` approval modals
- **Phase 4**: Native Microsoft Graph + GitHub clients
- **Phase 5a**: `nostromd` daemon + Unix socket IPC
- **Phase 5b**: Daemon-owned PTYs with detach/attach + scrollback
- **Phase 5c** *(current)*: Split panes, command palette, sweater status colours
