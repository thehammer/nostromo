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

## Phases

- **Phase 1** *(current)*: Fred + Perri parity via bash `--json` mode
- **Phase 2**: Embedded PTY + syntax-highlighted diffs
- **Phase 3**: Mother queue + inline `await` approval modals
- **Phase 4**: Native Microsoft Graph + GitHub clients
- **Phase 5**: Multi-monitor IPC daemon — drop tmux entirely
