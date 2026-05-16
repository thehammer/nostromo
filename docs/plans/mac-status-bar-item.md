# Mac Status-Bar Item (Mother Queue Glance)

## Context

The Mac-native vision (`docs/visions/mac-native.md` §"Capabilities")
describes a persistent macOS menu-bar item that surfaces Mother queue
state, budget posture, and the next calendar event without requiring a
foreground window. Of those three feeds, only Mother queue state is
already published by the daemon today (`ServerMsg::MotherJobs` /
`MotherStatusline` broadcasts on the `nostromd` IPC socket). Budget
posture and calendar live in TUI-only state — surfacing them from the
status-bar item is out of scope for v1 (see sequencing memo Q4; calendar
in particular is better fetched directly via macOS EventKit from the
status-bar process itself, which is on-platform).

This wedge ships the **first non-TUI surface** for Nostromo:

- A standalone macOS `.app` bundle living at `apps/mac/StatusBarItem/`
  (decision B6 in the sequencing memo defaults the Mac app to a
  monorepo subdirectory).
- AppKit `NSStatusItem` rendered in the menu bar.
- Connects to the daemon over the existing Unix IPC socket (no TCP yet
  — wedge W2's network transport is **not** a prerequisite for v1
  because this client runs on the same host).
- Reads `ServerMsg::MotherJobs` and `ServerMsg::MotherStatusline`
  broadcasts (depends on wedge W1's snapshot-on-connect addition so a
  newly-launched status-bar process shows correct state immediately).
- Renders:
  - Menu-bar icon: a Nostromo glyph plus a small badge with the count
    of awaiting jobs, if any.
  - Click-through popover: a short list of running/awaiting/failed
    counts and the first three job titles, with a "Open in TUI"
    placeholder action (no-op for v1, ships as a disabled item).

This is the smallest piece of native macOS surface that's *useful*
on its own. It establishes the Swift toolchain in the repo, validates
the daemon-as-dual-client architecture, and gives the operator a
working ambient surface they can pin to the menu bar.

## Target
- **Repo:** nostromo
- **Branch:** `feat/mac-status-bar-item`
- **Base:** `origin/main`
- **Depends on:** `feat/daemon-mother-readapi` (wedge W1) merged
  first; v1 of this wedge needs `ClientMsg::Snapshot` to render
  state on launch without waiting for the next poll.

## Files to change

- `apps/mac/StatusBarItem/StatusBarItem.xcodeproj/` (new) — Xcode
  project. macOS 14+ target, Swift 5.9+, no entitlements other than
  network client (for the Unix socket) and `LSUIElement = YES` (no
  Dock icon, no main menu).
- `apps/mac/StatusBarItem/Sources/StatusBarItem/App.swift` (new) —
  `@main` SwiftUI `App` with a `MenuBarExtra` (macOS 13+ API) or
  AppKit `NSApplication` with `NSStatusItem` (more control; preferred
  for v1). Use AppKit — `MenuBarExtra` has rough edges with custom
  badge rendering.
- `apps/mac/StatusBarItem/Sources/StatusBarItem/DaemonClient.swift`
  (new) — Swift implementation of the daemon IPC client protocol:
  - Opens a `Network.framework` `NWConnection` to the Unix socket
    path at `~/.nostromo/nostromd.sock` (override via env
    `NOSTROMOD_SOCKET`, matching the existing convention in
    `src/ipc/protocol.rs:17`).
  - Performs the length-prefixed JSON framing: read big-endian u32,
    read that many bytes, decode JSON.
  - Sends `ClientMsg::Hello { client_id: "mac-statusbar-<uuid>",
    protocol_version: 2 }`, then `ClientMsg::Subscribe { topics:
    [MotherJobs, MotherStatusline] }`, then `ClientMsg::Snapshot {
    topics: [MotherJobs, MotherStatusline] }`.
  - Surfaces `ServerMsg` as a Swift `AsyncStream<DaemonEvent>`.
  - Reconnects with exponential backoff (250ms → 4s) on socket
    close.
- `apps/mac/StatusBarItem/Sources/StatusBarItem/MotherState.swift`
  (new) — `@MainActor`-isolated observable model holding the latest
  `MotherJobs` (counts by state) and `MotherStatusline`. Updated from
  the `DaemonClient` stream.
- `apps/mac/StatusBarItem/Sources/StatusBarItem/StatusItemController.swift`
  (new) — owns the `NSStatusItem`, builds the badge image (icon +
  count), and presents the popover on click.
- `apps/mac/StatusBarItem/Sources/StatusBarItem/PopoverView.swift`
  (new) — SwiftUI `View` embedded in the `NSPopover` (`NSHostingView`).
  Shows counts and the first three job titles. Sized ~280×220 pt.
- `apps/mac/StatusBarItem/Sources/StatusBarItem/Resources/Assets.xcassets/`
  (new) — Nostromo menu-bar icon as a Template Image (so macOS
  tints it light/dark automatically). 16×16 and 32×32 PDF or PNG.
  Placeholder geometric mark for v1 — final art TBD.
- `apps/mac/StatusBarItem/README.md` (new) — build, run, and install
  instructions; explicit note that this depends on `nostromd`
  running. Pointer back to the platform-evolution sequencing memo.
- `apps/mac/.gitignore` (new) — Xcode build products, derived data,
  user-state files.
- `Makefile:1-end` — add `mac-statusbar-build` and
  `mac-statusbar-run` targets that shell into `xcodebuild` /
  `open`. Wrap in a `command -v xcodebuild` guard so the target
  no-ops on non-mac CI / non-developer machines.
- `docs/plans/mac-status-bar-item.md` — this file.
- `README.md` (if it currently has a "Components" or similar section)
  — add a one-line pointer to `apps/mac/StatusBarItem/`.

## Approach

1. **Project scaffold.** Create the Xcode project by hand-editing
   `project.pbxproj` is painful — instead, scaffold via
   `xcrun xcodebuild -create-xcframework` is wrong, use
   `swift package init --type executable` then add an Xcode wrapper
   *or* simply commit a minimal `project.pbxproj` generated locally.
   Prefer the SwiftPM-driven approach: a `Package.swift` in
   `apps/mac/StatusBarItem/` with one executable product targeting
   macOS 14+, and an `Info.plist` with `LSUIElement = YES`. Build
   via `swift build -c release` and bundle via an `Info.plist` + a
   small shell script that wraps the binary into a `.app`. This
   avoids checking in Xcode's noisy project file.
2. **Daemon IPC implementation in Swift.** Match
   `src/ipc/protocol.rs` exactly:
   - Length prefix: big-endian `UInt32`, body limit 4 MiB
     (`MAX_FRAME_LEN`).
   - JSON shapes from the Rust types (`#[serde(tag = "type",
     rename_all = "snake_case")]` produces `{"type":"hello", ...}`).
     Swift `Codable` types with `enum` discriminants via a custom
     `init(from:)`.
   - Initial handshake: write `Hello`, read `Welcome`, write
     `Subscribe`, write `Snapshot`. Read loop on a background
     queue, deliver decoded `ServerMsg` to `@MainActor` state via
     an `AsyncStream`.
3. **Status-item rendering.** AppKit `NSStatusItem` with a
   `variableLength` length, button image set to the Template
   asset. The badge (awaiting-count) is composited at render time:
   either a separate `NSImage` with the digit drawn over the icon,
   or two `NSTextField`s stacked in the status-item button's
   subviews. Pick the image-composite approach — it survives
   tint changes for free.
4. **Popover content.** SwiftUI `View` showing:
   - "N awaiting · N running · N failed" header line.
   - List of up to three job titles, each with state badge.
   - Footer with "View all in TUI" (disabled placeholder; ships
     in a follow-up wedge that wires a deep-link).
5. **State on launch.** On `applicationDidFinishLaunching`, the
   `DaemonClient` connects and issues `Snapshot` (W1's addition).
   If the daemon isn't running, the status-item shows a dimmed
   "?" badge and the popover reads "Daemon not running"; the
   client reconnects on a 4-second cadence until success.
6. **Quit / lifecycle.** Right-click on the status item shows a
   menu with "Quit". On quit, the client closes its socket
   cleanly. The process is otherwise a daemon-style background app.
7. **No automated test in the Swift target for v1.** Building and
   running the bundle from the `Makefile` target is the smoke
   test. Add a `nostromctl` (or `mother`) shim invocation in a
   manual test plan in the README that exercises three Mother
   state transitions and checks the badge updates.

## Acceptance criteria

Behavioural (from Ada's `mac-native.md` §"Capabilities" — the
status-bar item entry):

- The status-bar icon is visible in the macOS menu bar after the
  `.app` is launched and persists across login sessions (no further
  AC for autostart in v1 — the operator launches it manually).
- The icon shows a badge with the count of `awaiting` Mother jobs
  when that count is > 0, and no badge when zero.
- Clicking the icon opens a popover showing counts and the first
  three job titles.
- Counts update within **one daemon poll interval (≤ 2 s)** of a
  Mother state change observed by the daemon.
- The app does not appear in the Dock and has no main-menu bar
  beyond the status-item menu.

Technical / non-functional (Archie):

- The app does not require `nostromd` to be running to launch — if
  the socket is unreachable it shows a "disconnected" state and
  reconnects automatically on a 4-second backoff.
- Idle CPU usage **< 1%** on an M-series Mac while the daemon is
  publishing the typical poll cadence.
- Resident memory **< 50 MB** RSS once steady-state.
- Clean shutdown: on quit, the IPC socket is closed before exit and
  the daemon logs no `client closed unexpectedly` warning.
- Wire protocol parity: the Swift `DaemonClient` correctly handles
  `MotherJobs`, `MotherStatusline`, and `Welcome` and silently
  ignores variants it doesn't know about (`Activity`, `Pty*`,
  `MotherAwaitDetected` for v1).
- No regression in the existing TUI: with both the TUI and the
  status-bar item running, both see the same Mother data within one
  poll interval. (Manual test: open TUI, launch status-bar item,
  trigger a Mother state change, observe both surfaces.)
- The `.app` bundle launches on a clean macOS 14+ system with no
  developer tools installed (only the daemon needs to be running).
- PR body references this plan and the sequencing memo and notes
  the W1 dependency.

## Out of scope

- Budget posture or calendar surfacing (sequencing memo Q4 defers;
  calendar will be a separate wedge via EventKit).
- TCP / TLS / remote-host operation — this wedge talks to the local
  daemon over Unix. The same Swift client code can be extended to
  TLS+token later when wedge W2 lands and a mobile or sidecar use
  case appears.
- Deep-link to the TUI from the popover footer.
- Click-through to a Mac-native Mother-queue window (that ships in
  wedge W4 `mac-native-shell`).
- Notifications via NSUserNotificationCenter / UserNotifications —
  Ada lists native notifications under "Capabilities" for the Mac
  app generally; deferring to a wedge that owns that surface
  end-to-end.
- App Store packaging, notarisation, or DMG distribution. v1 ships
  as an unsigned `.app` the operator runs locally.
- Multi-window or popover persistence across spaces. Standard
  AppKit defaults only.
- A SwiftUI component library shared with the future iOS/iPad app.
  This `.app` is intentionally self-contained.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "First Swift code in the repo; first native macOS surface. Project scaffolding, wire-format reimplementation, and lifecycle wiring all need to be right the first time."
  redd:
    model: haiku
    effort: low
    rationale: "downgrade: no automated test surface for the Swift target in v1 — smoke test is manual via Makefile. Redd's contribution is minimal; if extended, will be a Rust-side daemon test asserting multi-client behaviour (already covered by W1)."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass on the Swift sources once Cody lands. Module boundaries between DaemonClient/MotherState/StatusItemController will benefit from a tidy."
  perri:
    model: sonnet
    effort: high
    rationale: "First non-TUI surface; first Swift in the codebase. Reviewer needs to validate project layout choices, wire-format parity, and lifecycle handling. Future surfaces will inherit patterns set here."
```
