# Always allow… (AP6): persisted Nostromo rules

The third scope of an Allow. "This exact `rm` under `~/Library/Caches/` never asks again in Nostromo." It is the
longest-lived place Nostromo ever writes `"behavior":"allow"` without a click on that very request, so it inherits
every limit of the session rules (`docs/approvals-session-rules.md`) and adds a few of its own.

## Where rules live (decision U2)

`~/.nostromo/approvals/rules.json` (`NOSTROMO_APPROVALS_DIR` in tests), written only by the daemon. They apply only to
Nostromo-hosted sessions. **Nothing is ever written to `~/.claude/settings.json`, a project `settings.json` /
`settings.local.json`, or any file Git would commit** (a test hashes all three before and after). The card's
`Copy rule` puts `Bash(…)` on the pasteboard so the user can add it to their own settings; Nostromo writes nothing there.

As with session rules, Nostromo matches the rule itself (the CLI does not let an allow rule outrank an ask rule), and
never sends `updatedPermissions`.

## How a rule is created: two human gestures

1. `This session ▾` → `Always allow…` opens an inline confirmation panel in the card. Nothing is sent. It preselects the
   **exact** candidate and **This repository (<root>)** (`This folder (…)` outside git); the path-prefix candidate and
   `All repositories` are deliberate changes inside the panel. It shows the destination path, who it affects and
   `Your ~/.claude/settings.json is not changed`. Changing either pop-up restarts the confirm arming.
2. `Write rule` (a distinct event, at least 0.3 s later, the button the event hit) sends one
   `approval_answer {kind: allow_always, candidate_id, rule_text, scope: repo|all_repos}`. The app sends no root: the
   daemon uses `find_repo_root(session cwd).dir`.

The daemon accepts it only from the verified app with its nonce, only for a held request that listed `allow_always`, only
with one of **that request's own AP4 candidates** (byte for byte) and refuses, leaving the request held and writing
nothing: the guard blocks the rule's command (`rule_refused`), a too-broad or protected prefix (`rule_refused`), a missing
scope (`rule_refused`), unknown id or edited text (`invalid_rule`), a quarantined file (`rules_quarantined`), 200 rules
(`rule_limit`), a failed write (`rule_write_failed`). Order: write the file, `rule_written` audit entry, end the request
`allowed_always` (this one call), broadcast `approval_rules`. If the allow cannot be written the rule is taken back out.

## How a rule is used

In `process`, after the guard and the session rules, before a card, and only while a verified app that can show and
remove rules is connected: the first active rule whose scope covers the session's working directory (`Repo{root}`: cwd is
root or below, compared after resolving symlinks; `AllRepos`: always) and that matches through the same matcher as a
session rule (`rules::spec_covers`: eligibility again, pinned operands re-resolved, prefix re-resolved), all on one bounded
helper. The outcome is `allowed_by_your_rule`; the row reads `allowed by your rule`. It applies to any agent or sub-agent of
a guarded, approval-capable session. Restricted and remote-control sessions never reach a prompt.

## The file is never trusted

- Each record stores `source_command`. At load every rule is re-derived with `rules::revalidate`: AP4's `candidates()` is
  run for that command and the rule stays active only if a candidate has the same kind and byte-identical text **and** the
  same pinned / resolved paths. Anything else is listed **inactive** (`no_longer_offered` or `path_changed`) and never
  matches. A hand-edited `Bash(rm:*)` stays inactive, even after Keep.
- The file's SHA-256 is kept in memory and in `rules.json.sha256` (0600). A hash mismatch, parse error, bad mode, symlink,
  more than 200 rules or more than 1 MiB at load, or a change made while the daemon runs (a `notify` watcher; the daemon's own
  writes are recognised by their hash), **quarantines** the file: no rule matches and no new one is written. The audit log
  gets `rules_quarantined` and the app gets `approval_rules` with `quarantined`.
- Rules window (Window → Approval Rules): the banner `Rules file changed outside Nostromo; rules are off until you review
  them`; `Review…` then `Turn these rules on` (two gestures; sends the hash that was reviewed, refused if the file changed
  again) or `Discard` (one gesture; the file becomes an empty rule set). Remove is one gesture.
- Writes: tmp file in the same directory (`O_EXCL`, `O_NOFOLLOW`, 0600), `fsync`, `rename`, `fsync` of the directory. Use
  counts are written at most every 10 s and at shutdown.

## Audit

`rule_written`, `rule_removed` (`reason: user | allow_not_written | request_ended`), `rules_loaded`, `rules_quarantined`,
`rules_kept`, `rules_discarded`, an `outcome` of `allowed_always` / `allowed_by_your_rule`, and `refusal` entries (`control:
remove_rule | keep_rules | discard_rules`) for every refused change.

## Residual risk

A same-user process that rewrites `rules.json` **and** its sidecar consistently while the daemon is stopped is not detected as
tampering. Its rules still have to pass `revalidate` (and the confirmation-time too-broad / protected check) to be active, so
the most it can add is a rule AP4 itself could have offered, never touching `~/.claude` or `~/.nostromo`, with no guard
marker. It appears in the Rules list and the `rules_loaded` entry. Binding the file with an HMAC key in the macOS Keychain
would close that; it costs a Keychain prompt on every daemon rebuild and a fake key source in the Linux tests (owner decision,
follow-up). A same-user symlink swap of a `Repo` scope root can only change which of the user's own sessions a rule covers;
what a rule may run is pinned separately.
