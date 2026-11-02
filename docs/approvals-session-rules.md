# Allow for this session (AP4)

The approval card can offer "This session ▾" next to Allow once. It creates a **session rule**: later calls
that match it are allowed by the daemon itself, with no card, until the session ends. It is the second place
Nostromo ever writes `"behavior":"allow"` without a click on that very request, so it is narrow on purpose.

Why Nostromo matches the rule itself: the Claude CLI does not stop asking for a call an `ask` rule matched, even
if it is sent an allow rule (`updatedPermissions`), and it sends no suggestion for an ask-rule prompt. So the daemon
keeps the rules in memory and answers matching requests. It never sends `updatedPermissions` (a test scans `src/`).

## What is offered

A candidate exists only for a **plain Bash command**:

- `tool_name` is `Bash` and the input has only `command`, `description` and `timeout` (so no `run_in_background`,
  no `dangerouslyDisableSandbox`); the CLI did not set `suppress_always_allow_rule` or `requires_user_interaction`;
  the reason is not a safety check or a settings write; and the guard let it through.
- The command is at most 300 bytes of ASCII words joined by **single spaces**, each byte in
  `[A-Za-z0-9_./~+=,:@%-]`. No quote, `$`, backtick, `; & | < > ( ) { } [ ] * ? ! # \`, tab, newline or non-ASCII
  byte, so compound commands, substitutions, redirections, globs and here-docs never get a rule.
- The command word is a bare name (any word containing `/` gets nothing) **on the allowlist**. Everything else gets
  **Allow once only**, with no session candidate: test and task runners, package managers, interpreters, exec wrappers
  and anything that loads project files (`pytest jest make npm cargo git docker just xcodebuild sed awk find tar curl
  ln …`), shells, `sudo env xargs exec`, `ssh aws kubectl`, `tmux`, Nostromo's own binaries, and so on. The allowlist is
  `rm rmdir mkdir touch ls du stat file cat head tail wc` (also prefix-capable) plus `cp mv diff cmp grep rg sort uniq
  cut tr basename dirname realpath readlink pwd which whoami id date uname sw_vers echo printf sleep jq shasum md5 xxd
  od strings tree lsof ps pgrep df`. Not `ln` (it makes the symlinks the prefix check depends on). The old denylists
  (`NEVER_COMMANDS`, interpreters, `NEVER_SUBSTRINGS`, `remote_shell_marker`) still apply on top, as defence in depth.
- A word starting `--pre`, `--compress-program`, `--output`, `--exec` or `-o` (they run a program or write a file: `rg --pre`,
  `sort -o`) gets nothing, and `uniq`/`xxd` take one operand at most (the second is an output file).
- `rm rmdir mv cp chmod touch mkdir` with any **relative** (and `sort uniq tree xxd`, which can write a file) path argument get nothing: the rule ignores the directory it
  was granted in. No word may start with `=` (zsh `=cmd`) or `%`, or with `/.vol` (APFS volume paths name any file by
  number and bypass the path checks).
- No word contains `ecs`, `ssm`, `execute-command`, `start-session`, `run-task`, `session-manager`, `send-keys`,
  `send-prefix`, `paste-buffer`, `pipe-pane`, `respawn-pane` or `tmux`, and `remote_shell_marker` finds nothing. Production-shell
  and ECS commands never get a rule, even ones the guard allows.
- No word is, or points inside, a protected place: `/`, `~`, `~/`, `~user`, `/etc`, `/private/etc`, `/System`, `/usr`,
  `/bin`, `/sbin`, `/Library`, `/Applications`, `/var`, `/dev`, `~/.ssh`, `~/.aws`, `~/.kube`, `~/.gnupg`, `~/.config` (all of it),
  `~/.docker`, `~/.npmrc`, `~/.netrc`, `~/.zshrc`, `~/.zprofile`, `~/.bashrc`, `~/.gitconfig`, `~/.claude`, `~/.nostromo`,
  `~/Library/Keychains`, `~/Library/LaunchAgents`, or any `.git` component. A bare relative `.ssh` counts like `.ssh/x`, checked against the session's directory. (Allow once still works for all of them.)

The candidates, in order:

1. **Exact**: `Bash(<command>)`, matched byte for byte. The card says "Allows exactly this command text again, in whatever directory the session is in".
2. **Path prefix**, only for `rm rmdir mkdir touch ls du stat file cat head tail wc` with `<command> <flags…> <path…>`
   (flags are `-[A-Za-z]+`, at least one path, every path absolute or `~/`, no `.` or `..` component, no `//`): the
   deepest common parent of the paths. Paths under your home are first rewritten to `~/…` (so `/Users/you/Code/x` is
   exactly as shallow as `~/Code/x`, whatever the case or a symlinked home), and then the parent needs at least two
   components below `~/`; elsewhere at least three below `/`, and never inside `/Volumes /Users /opt /usr /etc /var
   /private /Library /System /Applications` (and similar roots). It must not be protected (`Bash(rm -rf
   ~/Library/Caches/:*)` yes; `~/Code/`, `/tmp/x/`, `/Volumes/Backup/` no). Relative paths never get a prefix.
   **The prefix must resolve to itself:** it is resolved when offered and refused if any component is a symlink (a
   symlinked home is the one exception, and the rule is then tied to where it pointed). Depth, broad roots and
   protected places are checked again on the resolved form, which is stored in the rule.
- A request with `default_to_no`, `classifier_approvable: false` or `decision_reason_type: safetyCheck` (read from the
  raw field, not from the displayed reason) gets no candidate and never matches a rule.

For a request raised by the user's own ask rule the card says `Overrides your rule <rule> for matching commands, this
session only`.

## How a rule is created: two human gestures

1. Choosing an item of the `This session ▾` menu **only selects** it. Nothing is sent. The card then shows the exact
   rule text, what it covers, who it is for and the overrides line, with an `Allow for this session` button.
2. Pressing that button sends `approval_answer` with `allow_session`, the candidate's `id` and its `rule_text`.

Both steps go through `HumanGesture.permit` (the pick as a menu selection, which is allowed only because it cannot
confirm; the confirm with the strict defaults). The confirm also refuses, changing nothing: the same event as the pick;
less than 0.3 s after it on **either clock** (the smaller of the events' own timestamp gap and the handlers' clock gap); a key repeat; a double click; a mouse event outside the button; a key
while the button is not first responder or is not Space/Return. The pick reverts after 15 s, when the request changes
and when the card leaves its window. No app-control command and no Accessibility press (VoiceOver off) completes
either step. The button has no key equivalent and is never the default.

The daemon accepts `allow_session` only from the verified app with its nonce, only for a held request that listed it,
only with one of **that request's own** candidates and the identical text; anything else is `invalid_rule`, logged, the
request stays held and no rule exists. It never parses the text: the rule is built from the stored candidate. At most
32 rules per session.

## How a rule is used

In `process`, **after the guard and before a card**: only if the session carries the guard hook **and** a verified app
that renders approvals is connected (nothing is allowed host-side while nobody can show and revoke rules); only a rule
of exactly this session process (`tag` + generation) and the same requester (the session's agent, or the same
sub-agent); and the request passes every eligibility check again. A prefix match first requires the prefix directory to
still resolve to the value stored when the rule was created (a directory that later became a symlink ends the rule's
reach), then resolves each path: one that leaves the prefix, lands in a protected place, or is a dangling or looping
symlink does not match. Each match runs on a helper thread with a 500 ms limit; a file system that does not answer
is no match. A rule also belongs to the session id it was granted under: a request carrying a different session id,
or a rule from another one, never matches. A match is logged `allowed_by_session_rule` and the row reads `allowed by session rule`.

## How it ends

Rules are memory only. They go, each with a `session_rule_revoked` entry (`reason: session_ended`), when the session
process goes for any reason (stop, restart, Clear Context, exit, crash, model switch), when a new process registers for
the focus, and at daemon shutdown. A daemon restart starts with none. Revoke (the chip's popover) removes one at once
(`reason: user`).

## Seeing and revoking

The input bar's `N session rules` chip (its own fixed-width slot, so it never moves the composer or the transcript;
narrow bars show `N`, then nothing) opens a popover: each rule's exact text, summary, `granted 2:47 pm`, `used N
times`, the sub-agent if bound, and Revoke (one human gesture). A new daemon connection clears every rule before the
daemon replays its own. `nostromo-app approvals session-rules [--focus TAG]` is read-only; nothing in app-control
presses, selects or revokes.

## Audit

`session_rule_granted` (with the request, window, session and generation), a `request` and `outcome:
allowed_by_session_rule` per use (the outcome's `rule` names the rule and its grant), `session_rule_revoked`, and
`refusal` entries for every refused create or revoke.

## Limits (decision D-1)

- Bash only, plain commands only; widening (quoted commands, MCP, Edit/Write, relative prefixes) is a follow-up.
- **A rule ignores the working directory.** The working directory is not part of a rule, and the broker's `cwd` is the
  directory the session started in, not the Bash tool's current directory: after a `cd`, the same text acts somewhere
  else and still matches. The file-changing commands (`rm rmdir mv cp chmod touch mkdir`) get no exact rule with a
  relative path for that reason; read-only ones (`ls build`, `grep x out`) still do. The card says so.
- Exact rules cover the same **text**, not the same **effect**; that is why exact candidates come only from the
  allowlist above, not from a denylist.
- The grant audit does not yet record gesture provenance: `approval_answer` has no field for it and widening the wire
  is a follow-up. The Mac logs the source pid and state of the pick and of the confirm (as Allow once does).
- Prefix rules are never offered under `/Volumes`. Grant-time resolution (not the match) is not time-bounded.
- The CLI's permission request carries no session id of its own, so the broker compares the id it registered the
  session with (and the request's `session_id`, when one is present). A typed `/clear` that keeps the same process does
  not change the registered id: the rules still end when the process does, as documented.
- Persisted rules ("Always allow…") are AP6.
