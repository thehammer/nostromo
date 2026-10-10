# Brief for Ada — Q1: pairing a phone or iPad with the Nostromo daemon

**From:** Archie (`docs/plans/backplane-sequencing.md`, question Q1)
**Unblocks:** W11 `ios-ws-client` (`docs/plans/backplane/W11-ios-ws-client.md`)
**Existing stub to replace:** `docs/prds/daemon-pairing-flow.md` (Archie-authored placeholder)

## Why now

The operator's phone and iPad will stop finding the daemon on the local
network (Bonjour is blocked on the managed laptop, and the daemon is moving
to an always-on Linux box at home reached over WireGuard). Instead, each
device will hold a long-lived **device token** that identifies it to the
daemon. Somebody has to get that token onto the device the first time, and
that first-time moment is the whole product question: it is the only setup
step a mobile user ever does, and if it feels fiddly or untrustworthy the
mobile surface is dead on arrival.

## Who and when

One operator, two devices (iPhone, iPad), pairing each once — plus re-pairing
after a revoke, a lost device, or a daemon move. Rare, so it must be
*obvious* rather than *fast*; nobody will remember how it worked last time.

## What is already decided (not for re-litigation)

- A device proves itself with a bearer token; the daemon can **revoke** a
  device and its open connections drop within a second.
- Pairing begins with a short-lived **one-time code** the daemon issues; the
  device trades it for a token. The code expires after a few minutes and
  works once.
- The daemon can print the code as text and as a text-rendered QR encoding
  `host`, `port` and the code (`nostromo device pair --label <name>`).
- The device must be on the home network or WireGuard to reach the daemon;
  the app cannot tell whether the VPN is on, only whether it reached the host.

## What Ada decides

1. **Where pairing starts on the daemon side.** The daemon's host is a
   headless Linux box. Options the operator actually has in front of them:
   a terminal (`nostromo device pair`), the Mac app on a satellite, or the
   TUI. Pick the primary path and say what the operator sees (the code? a
   QR? both? for how long?).
2. **The phone-side flow.** Scan vs type vs both; what the first-launch
   screen says; what success looks like; what the device is *called*
   afterwards and who names it.
3. **Re-pair and revoke experience.** What a revoked device shows; what the
   operator sees on the daemon side when listing devices; how a lost phone is
   handled from the Mac in under a minute.
4. **The "sensitive data" choice.** Each device is either allowed to receive
   Teri/Fred mail-and-todo content or not. Is that a pairing-time question,
   a later toggle, or always-on for the operator's own devices? This is a
   trust question, so it is yours.
5. **Failure copy.** Code expired, code wrong, host unreachable (VPN off),
   device revoked. Four states, four sentences.

## Constraints from the sequencing memo

- Typed-code must work with no camera (iPad on a desk).
- Nothing in the flow may require the managed laptop to be *reachable*; it
  may only ever dial out.
- The token is never shown to the user after creation and never typed.

## Out of Ada's lane

Token format, hashing, file locations, WebSocket details, revocation
mechanics — all W9/W11 internals.
