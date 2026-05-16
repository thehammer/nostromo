# PRD: Push Relay (APNs Delivery for Tailscale-to-Mac)

**Status:** Stub (Archie-authored placeholder; Ada to write).
**Unblocks wedge:** W5 (`mobile-foundations` in
`docs/plans/platform-evolution-sequencing.md`).

## What this PRD needs to cover

A minimal hosted component that bridges the operator's daemon to
Apple Push Notification service. Required even in the Tailscale-to-Mac
transport because APNs cannot be terminated on the operator's Mac
(Apple won't deliver from arbitrary endpoints; APNs requires a
registered provider with a valid push cert / token).

- **What sends a push.** The daemon publishes a push intent (e.g.
  `MotherAwaitDetected`, `PerriReviewRequested`, calendar event) to
  the relay over an authenticated outbound HTTPS POST. No inbound
  hole through the operator's network.
- **What the relay does.** Forwards to APNs with the registered
  device token; logs delivery state; rate-limits per device; does
  *not* see payload contents beyond what the daemon chooses to
  include in the alert.
- **Payload contents.** Minimum useful surface in the notification
  body (title + a one-line subtitle) without leaking sensitive
  data; full detail fetched by the phone over Tailscale after
  tap-through.
- **Hosting / ownership.** Where the relay runs (small VPS owned
  by the operator? Lambda? Cloudflare Worker?). Cost envelope.
- **Token registration.** How the phone registers its APNs device
  token with the relay, and how the relay maps it to the operator's
  daemon (likely via the same device-token from the pairing PRD).
- **Failure modes.** Relay down (push silently drops; phone catches
  up next time it polls); APNs rejected (operator sees a Mac-side
  warning).
- **Privacy contract.** What the relay sees, retains, and logs;
  retention policy. This is the first piece of infrastructure that
  the operator's data passes through outside their own machines —
  worth being explicit even for personal-leverage v1.
