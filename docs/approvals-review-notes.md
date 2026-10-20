# Approvals: review notes (AP0b follow-up)

Wire behaviour fixed after the AP0b review:

- A held request whose `approval_request` frame would exceed `MAX_FRAME_LEN` minus 64 KiB is
  denied at hold with outcome `too_large` (content-free). `approvals_snapshot` is trimmed the
  same way: oldest first, and each request that does not fit is denied `too_large`.
- Only a connection that subscribed with `renders_approvals` may answer. Resubscribing with
  `renders_approvals: false` revokes that status (the last revoke starts the presenter grace).
- The client's `window_id` is sanitized and bounded before it is logged or broadcast.
- One constant for the 15-minute deadline: `APPROVAL_TIMEOUT` (`REQUEST_TIMEOUT` is gone).

Known and deferred (AP7 backlog):

- Audit fsync flooding: a TCP peer can make the daemon write (and fsync) refusal entries at
  will. Needs rate limiting in AP7.
- `bash_rule_matches` ignores `unparsed`; it only affects display.

## AP2a: the approval card (review fix-ups)

- **Allow once needs every line shown.** The input view records which text has been on screen
  (every wrapped line fragment, whole, possibly across two scroll positions) on every layout pass,
  clip move and window-visibility change. Jumping to the end (End, Cmd-Down, a scroller drag)
  shows the end only; the lines skipped must be scrolled through before Allow enables. A fast
  fling that skips lines leaves Allow disabled until they are scrolled back over. Coverage only
  grows, and only counts while the card is in a visible, non-occluded window and laid out at a
  non-zero size. A scroll made through app-control never counts.
- **Hidden characters anywhere flip the Deny default.** The headline, `Why:`, `In:` and `Agent
  says:` show hidden or direction-changing characters as visible tokens (a line feed stays a
  line break), and they count in `invisible_count` with the input's and the Bash extra fields'.
  Any of them gives the banner and makes Deny the initial keyboard focus.
- **A refused answer never strands Deny.** After the daemon refuses an answer (`not_operator_app`,
  `requires_secure_connection`, or an unknown code) the card says why and keeps Deny enabled: a
  person's press sends a Deny again (one attempt at a time, same human-gesture check). Allow,
  Deny & stop and the note are never re-sent.
- **A click on the card's own padding enters the card.** The card accepts first responder, so a
  click on its background (not a button or the input) makes it first responder, and it hands
  focus to its initial key view (Deny, or the input). The AP2a plan says "Tab into it, or click",
  so this is kept as is; it sends nothing and never happens on arrival.
