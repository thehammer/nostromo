# Mother focus: who queued a job

Every Mother job that is queued from a Nostromo session says which focus queued it, and the daemon
vouches for the answer. This page covers the origin foundation (slice MF1 of "Mother focus v2"):
how the daemon records and checks origins, where the files are, what goes over the wire, and what is
audited. Notices to the originating session and the Mac UI come in later slices, which extend this page.

## Kinds

A job's origin (`nostromo.origin.kind` on the job) is one of:

| Kind | Meaning |
|---|---|
| `focus` | A focus queued it and the daemon vouches for that: it stamped the enqueue itself (MCP), or a shell claim matched a session the daemon ran for that focus. |
| `unverified` | The job record claims a focus, but its session id is not one the daemon ran in that focus (or is missing). Nobody is notified for it. |
| `you` | Queued by the user in the app (Send to agent). |
| `unknown` | The record makes no claim (for example `mother add` from a terminal outside Nostromo). |

Whether a `focus` origin is still open is decided at display time: `closed: true` appears once the
daemon has received a non-empty focus registry from the app and the tag is not in it. Until then the
field is absent. `focus_name` is the focus's current name (from the registry); `name_snapshot` is its
name when the job was queued.

## How an origin is decided

1. **MCP.** `mother.enqueue_job` and `create_focus` (destination `mother_job`) are stamped from the
   MCP connection's own identity, never from arguments. The daemon passes `--origin-session <sid>` to
   `mother add` (the focus's current Claude session id) and, when the installed `mother` supports it,
   `--origin-focus <tag>` and `--origin-focus-name <name>`. Support is probed once by running
   `mother add --help` and looking for the literal `--origin-focus`; a yes is kept for the life of the
   daemon and a no is asked again at most once an hour. An older `mother` never sees the new flags.
2. **App.** The app's Send to agent records kind `you`. Its label stays `teri-send`, and those jobs
   are still withheld from network peers.
3. **Shell.** The daemon exports `MOTHER_ORIGIN_SESSION=<the Claude session id it spawned>` into every
   session it starts (next to `NOSTROMO_FOCUS_TAG`), so a `mother add` in that session's shell records
   the right `origin.session`. A record that claims focus F (`origin.focus`, from Mother) is checked
   against the daemon's session history for F: the claimed session id must be one the daemon spawned
   for F. Match: `focus` (via `shell`). Anything else: `unverified`.
4. A job the daemon has never seen is evaluated **once** when it first appears in the job feed, and the
   result is frozen. The only change allowed later is an **upgrade**: an MCP or app stamp for the same
   job replaces `unknown` or `unverified`. A `focus` or `you` entry is never changed.

Verification compares the claimed session id with the daemon's per-focus session history. It stops
accidental and casual mis-claims, not a determined process of the same user: the session ids are also
in files that user can read.

`mother.enqueue_job` also takes an optional `notify` (`wake`, `quiet` or `off`). It is stored with the
origin and shown as `nostromo.notify`; the notice slice acts on it.

## Where it lives

| File | What |
|---|---|
| `~/.nostromo/focus-session-history.json` | Per focus tag, the Claude session ids the daemon spawned for it: `{sid, first_seen_ms}`, newest 64 per tag, entries unseen for 90 days dropped. Departed tags are kept so old jobs can still be verified. Beside the session store (`daemon-sessions.json`). |
| `~/.nostromo/mother-origins.json` | The origin book: per job id, `{kind, focus_tag?, name_snapshot?, session_prefix?, via, notify?, evaluated_at_ms}`. Entries for jobs absent from the feed for more than 30 days are dropped. |
| `~/.nostromo/audit/mother.jsonl` | The content-free audit (below). Rotated at 10 MiB, twelve rotated files kept. |

Both JSON files are written atomically at mode `0600`; the audit directory is `0700` and its file `0600`.

## On the wire

Every job in `ServerMsg::MotherJobs`, and in `mother.list_jobs` / `mother.get_job`, carries an
optional `nostromo` object, added by the daemon on every publish of the job feed:

```json
"nostromo": {
  "origin": { "kind": "focus", "focus_tag": "claudia-C9D6B773", "name_snapshot": "Fix login",
              "focus_name": "Fix the login flow", "closed": false, "session_prefix": "5f3c9a10" },
  "notify": "quiet"
}
```

Mother's own fields are untouched. The raw claim (`origin.focus`, `origin.focus_name`) and the session
id (`origin.session`) are read from Mother's record but never serialised.

**Network peers** get the kind and the names but not `focus_tag` or `session_prefix`. When the origin
focus is sensitive, `focus_name` and `name_snapshot` become `a sensitive focus` and any `notice` is
removed. Work-send jobs and sensitive jobs are withheld from them entirely, as before.

**iOS and the shared Kit** decode `nostromo` tolerantly: an origin kind they do not know becomes
`.other`, and a malformed `nostromo` object reads as none, so one bad annotation never costs a job
(iOS decodes a whole `mother_jobs` message all-or-nothing). The golden frame is
`tests/fixtures/mother-v2/mother-jobs-annotated.json`, written by `tests/mother_origin.rs` with
`UPDATE_GOLDEN=1` and read by the Kit tests.

## Audit events

`~/.nostromo/audit/mother.jsonl`, one JSON object per line with `ts` and `event`. The events are a
closed enum with no free-text field: job ids, focus tags and a fixed word only. Never a title, a focus
name, a session id, a plan path, a reason or a URL.

| `event` | Fields |
|---|---|
| `job_origin_stamped` | `job`, `focus` (absent when the user queued it in the app), `via`: `mcp` or `app` |
| `job_origin_unverified` | `job`, `claimed_focus`: written once per job, the first time the daemon sees the claim |

Nothing in this path logs a job title, a focus name, a session id or a plan path either; a test drives it
at TRACE level with canary values to prove it.

## Where the code is

`src/mother/origin.rs` (session history, origin book, annotation, the `--origin-focus` probe),
`src/mother/audit.rs`, `src/mother/feed.rs` (annotates on every publish), `src/mcp/tools/mother_mutators.rs`
and `create_focus.rs` (stamping), `src/ipc/session_manager/mod.rs` (the session id in the environment, the
history), `src/ipc/peer.rs` (network redaction), Kit `Wire/MotherJobAnnotation.swift`.
