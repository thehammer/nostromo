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
