# PRD: Mac-Native Shell (Window Frame + Embedded Claude)

**Status:** Stub (Archie-authored placeholder; Ada to write).
**Unblocks wedge:** W4 (`mac-native-shell` in
`docs/plans/platform-evolution-sequencing.md`).

## What this PRD needs to cover

The window frame and PTY/transcript embedding model for the Mac-native
app. Vision decisions are locked in (free-floating Mail-style windows;
hybrid PTY-pane + native-transcript-pane via the Ctrl+T pattern); this
PRD pins down the v1 *behaviour*:

- **Which views ship in v1.** All of Fred / Perri / Mother / Claudia
  windows, or a subset (e.g. Mother + Claudia first, others later)?
- **PTY-pane + transcript-pane layout.** Side-by-side vs tabbed; which
  is the default; how does the operator toggle / resize / hide one
  pane.
- **Input/focus contract.** Is the transcript strictly read-only with
  copy support, or does selection flow back into the PTY as a quoted
  reply? (Archie recommends read-only-with-copy for v1; see memo Q7.)
- **State restoration.** Which windows reopen at launch, in which
  positions, on which Spaces. The autosave-frame contract.
- **Window menu and keyboard navigation.** How the operator switches
  between windows (system `Window` menu, Cmd-` cycling, global
  hotkeys).
- **Behavioural acceptance criteria** for each of the above.
