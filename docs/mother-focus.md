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
daemon has received a non-empty focus registry from the app and the tag is gone. "Gone" follows the
session manager's departure debounce: a tag missing from a single push is not closed yet (an empty
or partial push is normal on reconnect), only one missing from two consecutive pushes is, and a focus
the daemon created stays open until the app has acknowledged it. Until a registry has been pushed the
field is absent. `focus_name` is the focus's current name (from the registry, for a `focus` origin only); `name_snapshot`
is its name when the job was queued. An `unverified` origin shows only what the record claimed: the
claimed tag and the claimed name as `name_snapshot`, never the registry's name for that tag, so a
forged claim cannot borrow a real focus's face.

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
   for F. Match: `focus` (via `shell`). Anything else: `unverified`. A record with a session id but no
   focus claim (an older `mother` that took only `--origin-session`, or MF1 running without MF0) is
   verified by **session match**: when exactly one focus's history holds that session id, the job is
   `focus` for that tag; otherwise it is `unknown`.
4. A job the daemon has never seen is evaluated **once** when it first appears in the job feed, and the
   result is frozen. The exception is the daemon's own enqueue: Mother lists a new job before the daemon
   has stamped it, so while an enqueue is in flight a job not yet in the book is shown without an origin
   and neither recorded nor audited; the next poll decides it (from the stamp). The only change allowed later is an **upgrade**: an MCP or app stamp for the same
   job replaces `unknown` or `unverified`. A `focus` or `you` entry is never changed.

Verification compares the claimed session id with the daemon's per-focus session history. It stops
accidental and casual mis-claims, not a determined process of the same user. What can still be beaten
(plan index Q4), stated plainly:

- **Replaying a session id forges a verified job.** The id is the credential, and it is readable by the
  user's other processes: from Mother's own job records (`origin.session` is stored there), from `ps eww`
  (the environment of a running session, and `--origin-session` on a `mother add` command line), from
  `~/.nostromo/daemon-sessions.json` and from `~/.nostromo/focus-session-history.json`. Any process of
  the user that reads one and runs `mother add --origin-focus <tag> --origin-session <sid>` gets a
  `focus` job. The daemon never logs the id (a test drives a real spawn to prove it), but that does not
  hide it from the user's own processes.
- **The MCP stamp trusts the hello's `pty_id`.** An MCP call is attributed to the focus its connection
  says it is, the same trust every per-focus tool already places in it. The `pty_id` is not checked
  against the session history.
- **A recreated focus tag gets its old jobs back (Q7).** Origins are keyed on the focus tag. If a
  focus is closed and a new one is created under the same tag, the old jobs read as that focus's
  again (`closed: false`), and the history for the tag still verifies the old sessions.

`mother.enqueue_job` also takes an optional `notify` (`wake`, `quiet` or `off`). It is stored with the
origin and shown as `nostromo.notify`; the notice slice acts on it.

## Where it lives

| File | What |
|---|---|
| `~/.nostromo/focus-session-history.json` | Per focus tag, the Claude session ids the daemon spawned for it: `{sid, first_seen_ms, last_seen_ms}`, newest 64 per tag. `last_seen_ms` is refreshed each time the daemon spawns that session again (a resume), and entries are aged out by it: not seen for 90 days is dropped, so a long-lived focus's current session is never aged out by its first spawn. A file written before `last_seen_ms` existed ages by `first_seen_ms`. Departed tags are kept so old jobs can still be verified. Beside the session store (`daemon-sessions.json`). |
| `~/.nostromo/mother-origins.json` | The origin book: per job id, `{kind, focus_tag?, name_snapshot?, session_prefix?, via, notify?, evaluated_at_ms}`. Entries for jobs absent from the feed for more than 30 days are dropped. |
| `~/.nostromo/audit/mother.jsonl` | The content-free audit (below). Rotated at 10 MiB, twelve rotated files kept. |

Both JSON files are written atomically at mode `0600`; the audit directory is `0700` and its file `0600`.

A history or book file that exists but cannot be read or parsed is never silently overwritten. The daemon
starts with an empty one, copies the bad file to `<file>.bak` (`<file>.bak.<ms>` when a `.bak` is already
there) before any write can replace it, and logs one warning with the path and the byte count only, never
any of the content. Jobs whose sessions were in a lost history read as `unverified` or `unknown` until
the file is restored from the `.bak`.

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
removed. Sensitivity is asked of the tag, and a tag registered as sensitive stays so after its focus is
closed (registration is permanent), so a closed sensitive focus's name snapshot is still withheld. A
sensitive focus's display name is also not written into Mother's record or argv
(`--origin-focus-name` is omitted); the daemon's own book keeps the snapshot, which only the local
Mac sees. Work-send jobs and sensitive jobs are withheld from them entirely, as before.

**iOS and the shared Kit** decode `nostromo` tolerantly: an origin kind they do not know becomes
`.other`, a malformed `nostromo` object (including a malformed `origin`) reads as none, a wrong-typed `notify` costs only the notify and never a valid `origin`, so one bad annotation never costs a job
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

## How the Mac shows it

The Mac reads jobs from Mother's broker, not the daemon. From the daemon's `mother_jobs` frame it reads only
`jobs[].id` and `jobs[].nostromo` (never a date, so the fractional-seconds trap cannot reach it) and joins them
to the broker's jobs by id (`AppStore.motherAnnotations`, published only on change, kept through a disconnect).
A job with no annotation reads `origin unknown`.

| Kind | Row text | Notes |
|---|---|---|
| `focus`, open | current name | Clickable: switches the key window to that focus. A rename shows in every row in the same run-loop turn. |
| `focus`, closed | `<name> (closed)` | Muted, plain text. |
| `unverified` | `<claimed name>?` and an `unverified` badge | Muted, plain text. Never notified. |
| `you` | `You` | Plain text. |
| `unknown` or none | `origin unknown` | Muted, italic. |

Tooltips carry the tag, `queued as <snapshot>` when the name changed, and the session prefix. Every name is
sanitised (`FoldTextSanitizer`) and capped at 40 characters in a row, 120 in a tooltip. The detail has a
`From <origin> ↗ · <repo>` line under the title.

**`From:` filter.** A pop-up above the list: All, each focus with jobs (A-Z; closed ones last, with
"(closed)"), unverified claims, You, Unknown origin. Picking one shows `· N of M` and a clear button. The
filter belongs to the window's Mother view and is not persisted. **Show My Jobs** in a focus's context menu
opens the Mother focus in that window with the filter set to that focus. These are view actions, so none is
gesture-gated.

Code: Kit `Mother/MotherOriginDisplay.swift`, Mac `UI/Mother/MotherJobFilter.swift`, `UI/Views/MotherView.swift`.

## Where the code is

`src/mother/origin.rs` (session history, origin book, annotation, the `--origin-focus` probe),
`src/mother/audit.rs`, `src/mother/feed.rs` (annotates on every publish), `src/mcp/tools/mother_mutators.rs`
and `create_focus.rs` (stamping), `src/ipc/session_manager/mod.rs` (the session id in the environment, the
history), `src/ipc/peer.rs` (network redaction), Kit `Wire/MotherJobAnnotation.swift`.
