# Break-Glass Convention

nostromo implements a **nostromo-local** break-glass sentinel convention.
Mother itself has no break-glass primitive; the sentinel is written and consumed
entirely by nostromo.

## Sentinel paths

| File | Purpose |
|------|---------|
| `$HOME/.nostromo/break-glass.json` | Written by any process (agent, script) to request break-glass approval. |
| `$HOME/.nostromo/break-glass.response` | Written by nostromo on operator decision. Contains the word `approved` or `denied`. |

## Sentinel JSON shape

```json
{
  "action":       "string — short identifier for the action being requested",
  "summary":      "string — human-readable description of what will happen",
  "requested_at": "ISO 8601 UTC timestamp, e.g. 2026-05-08T14:30:00Z"
}
```

Example:

```json
{
  "action": "force-push-main",
  "summary": "Force-push admin-portal main to fix a botched merge commit. SHA: abc1234.",
  "requested_at": "2026-05-08T14:30:00Z"
}
```

## Workflow

1. A process writes `break-glass.json` to `$HOME/.nostromo/`.
2. nostromo's break-glass watcher (`src/data/break_glass.rs`) detects the file
   and fires an `AppEvent::BreakGlassDetected(BreakGlassRequest)`.
3. A **red banner** appears in the chrome status bar regardless of which view is
   active. The banner text: `⚠ BREAK-GLASS: <action> — press Ctrl-B to review`.
4. The operator presses **`Ctrl-B`** to open the break-glass modal.
5. Inside the modal:
   - `[y]` — confirms the action. nostromo writes `approved` to the response
     file and removes the sentinel.
   - `[n]` — denies the action. nostromo writes `denied` and removes the
     sentinel.
   - `[Esc]` — dismisses the modal without deciding. The banner stays until a
     decision is made or the sentinel is manually removed.
6. The requesting process polls for `break-glass.response` and acts on
   `approved` or `denied`.

## Clearing a stale sentinel

If the sentinel file exists but nostromo is not running (or the operator wants
to skip the UI), remove it manually:

```bash
rm -f ~/.nostromo/break-glass.json
```

nostromo will clear the banner on the next poll cycle (within ~2 s).

## Security note

The sentinel and response files are plain text in `$HOME/.nostromo/`, owned by
the current user. No cryptographic signing is performed. This convention is
intended for single-operator workstations where the user controls both the
requesting process and nostromo.
