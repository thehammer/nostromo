# PRD: Daemon Pairing Flow (QR + Device Token)

**Status:** Stub (Archie-authored placeholder; Ada to write).
**Unblocks wedge:** W5 (`mobile-foundations` in
`docs/plans/platform-evolution-sequencing.md`).

## What this PRD needs to cover

The first-pair flow between the operator's mobile device and the
daemon, plus device-token lifecycle. Transport is Tailscale-to-Mac
(vision decision, 2026-05-16); auth is bearer-token (W2 introduces
the token format and registry).

- **Pairing UX on the Mac.** Where the QR appears (TUI command? Mac
  status-bar item action? `nostromo device pair` CLI?), what's
  encoded in it (host + port + short-lived pair code), and how the
  operator triggers it.
- **Pairing UX on the phone.** Camera-scan flow, what the phone shows
  on success, fallback typed-code path for when the camera isn't
  available (or for iPad without rear camera convenience).
- **Token lifecycle.** Long-lived after pair, stored in Keychain.
  Revocation from the Mac side (`nostromo device revoke`). What
  happens on the phone when its token is revoked (next request
  fails, app shows a "re-pair" CTA).
- **Multi-device support.** Phone + iPad simultaneously paired to the
  same daemon. Naming devices so revocation is unambiguous.
- **Failure modes.** Lost phone (revoke from Mac), Mac offline
  (phone shows disconnected), pair-code expired (typed flow
  surfaces the error clearly).
- **Behavioural acceptance criteria** including timing (pair flow
  completes in < 30 s wall-clock from QR display to first
  successful authenticated request).
