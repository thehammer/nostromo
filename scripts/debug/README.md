# scripts/debug

## space-watch.sh

External logger for a surprise Space switch. Once a second it records the on-screen app windows (owner
name and bounds only — no window titles or contents) and the frontmost app, and writes a line only when
something changed. Compare it with Nostromo's own `ActivationAudit` lines (`docs/activation-audit.md`).

```
scripts/debug/space-watch.sh [--hours N] [--log PATH]
```

- Default log: `~/.nostromo-debug/space-watch.log`; default duration 24 hours (`--hours`); `--log` overrides the path.
- Stop it with Ctrl-C, or from another shell: `pkill -f space-watch.sh`.
- No special permission needed (owner names and bounds do not require Screen Recording).
- `space-watch.js` is the JXA snapshot helper the script calls; keep it next to the script.
