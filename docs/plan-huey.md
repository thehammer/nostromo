# Build Huey, the morning-report agent (sequenced plan, jobs H1 to H8)

**Author:** Archie, 2026-10-25.
**Status:** Approved by Hammer on 2026-10-25, with decisions D1 to D9 resolved (below). Split into eight Mother jobs (H1 to H8); see "Job order and dependencies".
**Pairs with:** `docs/prd-huey.md` (Ada, 45 acceptance criteria; the accepted deviations V1 to V6 are folded into it). The PRD defines what Huey does as the user sees it. This plan defines how it is built, and maps every criterion to a job and a test.
**Inputs read:** the PRD; a hand-run proof of concept of the report (two sample reports, kept in local notes); a draft interests file (shape only); the repo at `origin/main` `94617f7`; `docs/plans/backplane-sequencing.md`; live probes of the real sources on 2026-10-25 (results under "A8").

## Notation

- **H*n*** is a **job**: one Mother job, one branch, one PR. Each job was given its own self-contained plan file when it was enqueued.
- **D*n*** is a **decision**, resolved by the user on 2026-10-25. Each names the job(s) it affects.
- **V*n*** is a **deviation** from PRD revision 3, accepted by the user and since folded into the PRD.
- **T*n*** is a **technical acceptance criterion** (Archie's). These add to Ada's criteria; they do not replace any.
- **AC*n*** is one of Ada's 45 PRD acceptance criteria.
- **`[H3-4]`**-style ids are the per-job checklist items Mother counts (`mother check H3-4`).

## Job order and dependencies

The plan was split into eight per-job plan files for Mother (one branch and one PR each). Each file repeated the shared sections (Context through Risks) plus its own job section, so a fresh worker needed nothing else. Those per-job files were local working copies and are not committed; this document is the source of truth. Mother holds a dependent job until each dependency has succeeded and its PR has merged, and branches are cut from `origin/main`, which by then contains the dependencies.

| Job | Branch | Depends on | Cost cap (guidance) |
|---|---|---|---|
| H1 | `feat/huey-h1-switch` | none | 15 |
| H2 | `feat/huey-h2-fetch` | H1 | 30 |
| H3 | `feat/huey-h3-context` | H1 | 35 |
| H4 | `feat/huey-h4-run` | H2, H3 | 35 |
| H5 | `feat/huey-h5-curate` | H4 | 40 |
| H6 | `feat/huey-h6-surface` | H4 | 30 |
| H7 | `feat/huey-h7-mac` | H6 | 30 |
| H8 | `feat/huey-h8-eval` | H5, H7 | 15 |

```
H1 ──┬── H2 ──┐
     └── H3 ──┴── H4 ──┬── H5 ─────────┐
                       └── H6 ── H7 ───┴── H8
```

H2 and H3 run in parallel. So do H5 and H6. Nothing reaches the user until H7 merges: before that, Huey runs in the daemon but has no focus in the app, and it does nothing until setup is confirmed, which needs H6 and H7.

---

## Context

Huey is a new **built-in Nostromo agent**, alongside Fred, Perri and Teri. Every morning it writes one short report for one reader (Hammer) about his own work. The report is a few "picks": news items that affect a project he has in flight, each saying how that project is affected and what Huey checked. After the picks come one first-party "Also in the news" line, up to five interest-tagged "Also noted" lines, and a footer that says what Huey read, what was quiet, what failed and what it dropped. The PRD (`docs/prd-huey.md`) is the authority on behaviour and has 45 acceptance criteria. This plan builds it.

Decisions already made (do not reopen them):

- v1 runs on Sendai (the personal Mac Mini) only. A later Kobe (work laptop) instance must not be painted into a corner. So all context is per machine, and a one-time setup step comes before anything is read, fetched or sent.
- iPhone reading is out of scope. It waits for the WebSocket backplane. Nothing here may make it harder; panes and wire types are chosen so that iOS can render them later.
- Fetching is plain code, with no model. Curating and writing are model calls through **Claude Code sessions on the user's subscription** (see A3 for why).
- Budget behaviour follows Bishop's posture file `~/.claude/budget-posture.json`, mapped to the PRD's normal / tight / critical (see D1).
- Huey is on by default and switchable with `[agents.huey] enabled = false`. Restart and malformed-config behaviour are the same as for Fred, Perri and Teri (`src/agents.rs`).
- Nothing raw leaves the machine. Only the visible context digest and public news go to the model, and the digest shown is byte-for-byte what was sent.
- There is no resident or patient data and no work (Carefeed) context anywhere in v1. The repo is public: fixtures, prompts and docs must contain nothing private.

The hand-run simulation (two reports on 2026-10-25) set the quality reference:

- The best picks were single "Added" lines deep in the Claude Code changelog, so first-party sources must be read in full.
- The week's loudest news (API version 2026-10-21 and the 2.0 SDKs) correctly mattered to nothing, because no Sendai project uses an Anthropic SDK. That is a fact the repos can answer.
- The picks ended in "check whether..." wherever the digest did not know how a project is wired.

The design below answers all three: full reads of first-party sources, a deterministic "how it runs" profiler, and a daemon-side check tool.

There is no ticket. Commit prefix: `feat(huey): ...`.

## Decisions (resolved by Hammer, 2026-10-25)

**D1. How Bishop's posture maps to normal / tight / critical** (H4, H5). The PRD's three words do not exist in Bishop's vocabulary. `src/data/rate_limits.rs:59-151` parses a legacy scale (`flush`, `normal`, `elevated`, `conservative`, `critical`) and the current one (`Put the hammer down`, `Push`, `Cruise`, `Ease up`, `Pump the brakes`). Today's file says `"posture": "Pump the brakes"`, with the 7-day window 72% used at pace 1.9 and `"billing_mode": "metered"`. **Resolved:**
- **critical:** `posture` is `critical`, or `seven_day.used_pct >= 98`, or `exhausted_models` contains the family of the model Huey would use.
- **tight:** `Pump the brakes`, `conservative` or `elevated`; or `seven_day.used_pct >= 90`; or `stale_input: true`; or the file is older than 24 h; **or `billing_mode` is `"metered"`**. While metered, Huey never runs in normal (full) mode; critical still wins when its own conditions hold.
- **normal:** everything else, including a **missing** file (another Nostromo user may not run Bishop). The footer then says "budget posture unavailable".

Under this mapping Huey runs tight today (both the posture and metered billing say so).

**D2. What counts toward the word caps** (H5). **Resolved:** the 600-word cap (AC8) counts the whole rendered report, footer included. The quiet-day 150-word cap (AC9) counts the body only: opener, the "nothing today" line, Also in the news, Also noted. The footer is always held to 100 words or fewer. Reason: a footer that meets AC12 is 60 to 100 words by itself.

**D3. The Also-in-the-news line when every eligible item is minor** (H4, H5). **Resolved:** with a model, the model may return no line, but only when every eligible item is a fix or minor change, and it must say why in `ain_skip_reason`; the validator accepts that, and the footer shows the reason (AC45). Under critical (rule-based), the rule picks the newest eligible item as AC44 says, even if it is minor.

**D4. What a critical-mode (uncurated) report does to the window and to the 14-day memory** (H4). **Resolved:** an uncurated report **does not advance the window**: the next curated report covers everything since the last curated one. Its items go into the 14-day ledger as `section: uncurated`, which blocks them from the Also-in-the-news line (AC43) but **not** from picks or Also noted. Reason: the uncurated list shows version-level headlines ("Claude Code 2.1.304"). Treating that as "featured" would hide the valuable "Added" line inside the version (AC11), and advancing the window would skip that day's blog items (AC4).

**D5. Huey's files live in `~/.nostromo/huey/`, never under `~/.claude`** (H1, H3, H6). `~/.claude` is a git repo pushed to `github.com/thehammer/claude_code`, so anything under it can cross machines: `~/.claude/ideas/` is tracked, and `~/.claude/huey/` (where the sample interests file sits) is neither tracked nor ignored. **Resolved:**
- All Huey state, **including the interests file**, lives under the daemon's per-machine state root (`~/.nostromo/huey/`), beside the socket, as the tracker's does. Setup offers to copy an existing `~/.claude/huey/interests.md` once.
- `~/.claude` ideas, todos and notes stay context sources (titles only). **v1 mitigation for the sync risk** (the PRD's): the setup step marks each of them as "may be synced from other machines"; the digest shown next to each report is exactly what was used, so anything from another machine is visible; and "Ignore entirely" removes anything that slips through. Nothing beyond that in v1 (the user is deciding whether more is needed).
- **Prerequisite before any Kobe instance:** a per-machine rule for ideas, so that Kobe's work ideas never reach Sendai's digest and Sendai's never reach Kobe's. It is part of Kobe's privacy review and out of scope for v1.

**D6. Lazy setup** (H3, H6). **Resolved:** before any scan, the Huey focus shows "Huey is not set up on this machine. It has read nothing." with the list of context sources it *would* read (from config, with no reads) and one button, **Set up Huey on this machine**. The scan runs in memory when that button is pressed, and nothing is written to disk until the user acts on the draft. On Kobe nobody presses it, so Kobe reads literally nothing (V2).

**D7. The interactive Huey session is a normal session** (H6). **Resolved:** the digest-only rule (AC22, AC24) binds the **unattended** pipeline, meaning the scheduled run and regeneration. The Huey focus session is an ordinary interactive Claude Code session that acts only on what the user types, and may read project files when asked ("go and check that To-check for me"). Its persona says so.

**D8. Model and per-run caps** (H1, H5). **Resolved:** the default model is **`sonnet` for both normal and tight modes**, with `--max-budget-usd` caps of 3.00 (normal) and 1.00 (tight). Both models are configurable in `[agents.huey]` (`model`, `tight_model`), so Opus can be chosen. Reason: the weekly limit is already high, and Sonnet produced the sample reports.

**D9. Huey is hidden from network (iOS/LAN) peers in v1** (H5, H6). **Resolved:** withhold it, as Fred, Teri and Mother are withheld today:
- add `huey.` to `is_network_withheld_tool` and `huey` to `SENSITIVE_VIEW_IDS` (`src/mcp/tools/mod.rs:565-576`);
- mark the `huey` and `huey-run` session tags sensitive.

The digest holds personal notes and idea titles. The backplane follow-up that brings Huey to iPhone flips this deliberately.

## Deviations from PRD revision 3 (accepted; Ada is updating the PRD)

- **V1. Interests file path.** The interests file is `~/.nostromo/huey/interests.md`, not `~/.claude/huey/interests.md` (D5).
- **V2. One click before the setup step** (D6): "Set up Huey on this machine" comes before the scan and the draft.
- **V3. Word-cap measurement** (D2): the quiet-day 150-word cap excludes the footer, and the footer is capped at 100 words.
- **V4. The critical-mode list is capped** at 20 headlines plus "and N more (first-party)", so that a backlog after several missed or critical days stays readable. Everything beyond 20 is still counted in the footer.
- **V5. One automatic retry.** A failed curated run (model error or timeout) is retried once, 10 minutes later. Only then does the focus show "model failed".
- **V6. No "skipped for budget" reason.** Critical mode still produces a (headline) report, so a report is never skipped for budget. AC31's reasons are: machine asleep, fetch failed, model failed.

Feasibility objections: **none.** Every criterion is buildable. The ones that depend on model judgement (13 to 18, 39, 44's "most significant", 11's "says what is new") get deterministic guard rails enforced by the daemon (A4), plus an eval harness (H8) that runs the real model on the PRD's fixture scenarios. CI cannot call a model.

---

## Architecture

### A1. Module map (new code lives in `src/huey/`)

| Module | Owns | Job |
|---|---|---|
| `src/huey/mod.rs` | `HueyEngine` (daemon task), `HueyHandle` (cheap clone for MCP and IPC), `HueyView` watch channel (bumped on every state change) | H1 (skeleton), H4 |
| `src/huey/paths.rs` | `HueyPaths` for every on-disk location, rooted at `<state root>/huey` | H1 |
| `src/huey/config.rs` | `HueyConfig` from the extra keys in `[agents.huey]` (report time, lead, models, caps); warnings name keys only | H1 |
| `src/huey/setup.rs` | setup state (`setup.json`), lazy scan, draft writer, confirm | H1 (state), H3 (scan/draft), H6 (actions) |
| `src/huey/sources/` | `sources.toml` model and defaults, one adapter per source kind, per-source state (first-seen, baseline), the pool | H2 |
| `src/huey/items.rs` | `NewsItem`, stable item ids, canonical URLs, source classes, clustering | H2 |
| `src/huey/interests.rs` | interests-file parser (four sections, "How it runs" corrections, backticked hard-ignore terms), interest ids | H3 |
| `src/huey/context/` | project discovery, the `profile` ("how it runs" facts), collectors (tracker, PRs, git, Mother, Bishop, ideas, todos, notes), the digest renderer | H3 |
| `src/huey/checks.rs` | the read-only probe engine behind `huey.check_project` | H3 |
| `src/huey/budget.rs` | posture to `Mode { Normal, Tight, Critical }` (D1) | H4 |
| `src/huey/schedule.rs` | the next run, lateness, retry; takes `crate::tracker::clock::Clock` | H4 |
| `src/huey/store.rs` | reports by date and version, ledger, run log, verdicts, retention | H4 |
| `src/huey/run.rs` | the pipeline: fetch, filter, digest, mode, curate or uncurated, render, persist | H4 |
| `src/huey/render.rs` | report model to markdown and `MdBlock`s; footer; uncurated list; setup and missing-report documents | H4, H6 |
| `src/huey/curate.rs` | the hidden restricted session, prompt assembly, model-input capture, the publish loop | H5 |
| `src/huey/validate.rs` | every deterministic rule a publish must pass (A4) | H5 |
| `src/huey/prompts/curate.md`, `src/huey/prompts/persona.md` | compiled in with `include_str!` | H5, H6 |
| `src/mcp/tools/huey.rs` | the `huey.*` MCP tools | H1 (`get_state`), H5 (`check_project`, `publish_report`), H6 (the rest) |
| `src/bin/nostromo_huey_eval.rs` | the opt-in real-model eval runner | H8 |

### A2. The daily pipeline

```
scheduler tick (every 60 s, wall clock)
  └─ setup confirmed? enabled? due (now >= run_at) and no successful report today?
       └─ run(trigger = scheduled | catch_up | retry | regenerate | run_now)
            1. window_start = generated_at of the last *curated* report (D4); first run: now - 7 days
            2. fetch all enabled sources concurrently  → items + per-source status (ok n / quiet / failed reason)
               (regenerate reuses today's frozen pool unless today's fetch failed)
            3. eligibility: in window (published, or first seen for undated) · not baseline · not in 14-day ledger
               (unless a new item id) · hard-ignore terms · cluster (canonical URL / outbound links)
            4. context: projects in flight, profiles, collectors → digest.md (deterministic, ids on every line)
            5. mode from posture
            6a. Critical → render uncurated first-party headline list + Also-in-the-news by rule (no model)
            6b. Normal/Tight → hidden session `huey-run`:
                   model-input = curate.md instructions + digest.md + fenced candidates + Also-in-the-news candidates
                   model may call huey.check_project (results appended to the "Checks Huey ran" section of the shown digest)
                   model calls huey.publish_report → validate (A4) → refuse with reasons (≤ 3 attempts) or accept
            7. render report (daemon owns links, footer, labels, order) → persist v<n> → update ledger and run log
            8. bump HueyView → bound panes repaint; attach replay serves the cached document (AC3)
```

### A3. Why the model pass is a hidden Claude Code session, not an API integration

Huey uses the same mechanism as Teri's picks (`src/data/work/picks.rs`). That is a hidden, restricted daemon session:

- it is spawned through `PicksSessionHost` / `SessionManagerHost` (`picks.rs:572-640`) and seeded with one message;
- it uses an allow-list of tools and `--max-budget-usd`;
- it runs with `--setting-sources project --disable-slash-commands` in an empty temp directory;
- it has a timeout, its process group is killed when it ends, and its transcript is deleted afterwards.

Reasons:

1. **It runs on the subscription.** There is no API key to provision, store or rotate, and no billing integration. Huey's spend lands in the same usage Bishop already measures, which is what the budget rule is based on.
2. **No new client surface.** Nostromo has no Anthropic SDK dependency (the simulation's check found none, and none is in `Cargo.toml`). Adding an HTTP client, key management, retries and a model catalogue for one daily call is new attack surface in a public repo.
3. **The safety boxing already exists and is reviewed.**
   - The allow-list is applied twice: by `claude` flags, and by daemon dispatch (`is_picks_session` at `src/mcp/tools/mod.rs:558-563`).
   - The user's hooks, CLAUDE.md, plugins and skills do not load. That matters on any machine whose `~/.claude` carries work hooks.
   - Third-party text is fenced (`src/data/work/untrusted.rs`).
4. **Structured output through a tool call gives a refusal loop.** When the daemon refuses a publish ("pick 2 cites project `photos`, which is not in the digest"), the model fixes it inside the same session. A raw API call would need a hand-built retry protocol.
5. **It is testable without a model.** A fake `PicksSessionHost` captures exactly what was sent and scripts the publish calls (that is how AC22 is proven).

Costs accepted: a few seconds of CLI start-up, and the Claude Code harness's own system prompt and tool schemas travel with the call. Those carry no user context: the working directory is an empty temp dir, user settings are not loaded, and the MCP instructions for `huey-run` are replaced with a one-line Huey note (H5). `model-input.txt` therefore records **every byte Huey supplies**, and the docs state what the harness adds.

### A4. The publish contract: what the model may say, and what the daemon owns

The model never writes URLs, footers, dates, counts or labels. It returns structured content that refers to **ids the daemon issued**, and the daemon renders the report. `huey.publish_report` takes:

```json
{
  "opener_gist": "≤ 25 words, after the daemon's date prefix",
  "picks": [{
    "item_ids": ["<story id>", "<other coverage ids>"],
    "headline": "≤ 12 words, Huey's own words",
    "what_happened": "1–2 sentences",
    "project": "<project id from the digest>",
    "for_line": "1–2 sentences",
    "anchors": ["<digest anchor id>", "..."],
    "check": {"kind": "checked", "text": "...", "check_ids": ["c3"], "facts": ["mother:how"]}
           | {"kind": "to_check", "text": "one specific thing"},
    "follow_up_of": "<item id from the recent-reports list>, optional",
    "whats_new": "required with follow_up_of"
  }],
  "also_in_the_news": {"item_id": "...", "headline": "...", "what_happened": "..."} | null,
  "ain_skip_reason": "required when null and candidates existed (D3)",
  "also_noted": [{"item_ids": ["..."], "line": "≤ 20 words", "interest": "<interest id>"}],
  "dropped": [{"item_id": "...", "reason": "≤ 8 words"}],
  "ignored": ["<item ids judged under an Ignore entirely entry>"]
}
```

`validate.rs` refuses a publish, naming every problem, when any of the following holds:

| Rule | Criteria |
|---|---|
| More than 5 picks (3 in tight), more than 5 Also-noted items (0 in tight), or more than one Also-in-the-news line | AC6, AC32 |
| A pick missing a headline, what-happened, for-line or check; or an empty `item_ids` | AC7 |
| Any item id not among this run's candidates; an item id used in more than one place (picks, Also in the news, Also noted, dropped); an id in `ignored` used anywhere except as dropped | AC10, AC12, AC26 |
| `project` not a project id in this digest; `anchors` empty, or naming an anchor not in this digest, or naming another project's anchor | AC13, AC17 |
| `check.kind == checked` without at least one `check_ids` entry from this run or a `facts` id (a `<project>:how` line), or citing a check whose result is `not_found` for a `dependency` probe while claiming the project is affected | AC14, AC15 |
| More than one `to_check` pick | AC16 |
| Also-noted `interest` not the id of a "What I care about" or "Want more of" bullet | AC18 |
| The Also-in-the-news item not in the daemon's eligible set (A7); also a pick; mentions any project name from the digest (case-insensitive whole word); more than 40 words | AC40–AC43, AC8 |
| An item also in Also noted is chosen as the Also-in-the-news line: **accepted**, and the daemon removes it from Also noted ("moves up") | AC43 |
| Null Also-in-the-news line while candidates exist, without `ain_skip_reason` (D3) | AC44, AC45 |
| Rendered report over 600 words (footer included); quiet report body (zero picks) at 150 words or more (D2) | AC8, AC9 |
| `follow_up_of` names an item that is not in the 14-day ledger, or `whats_new` is empty | AC11 |

Daemon-owned rendering:

- **Primary link** = the cluster member with the best source class: an original or first-party URL beats a curated blog, which beats an aggregator page. An aggregator item whose URL is the story's own page counts as the original. "Also covered by" lists the rest in the same order (AC7, AC10).
- **Opener** = `"<Weekday>, <Mon> <d>. "` + gist.
- **Tight line:** "Short report: budget is tight today."
- **Quiet line:** "Nothing that touches your work today."
- **The Also-in-the-news label:** "Also in the news (not tied to your work)".
- **The footer** (A7).
- **The not-today banner** (AC31).

### A5. Checks: how "Checked:" stays honest without sending raw files

`huey.check_project` is available to the hidden session (and to the focus session). It answers a closed set of probes against a project's main worktree, read-only:

| Probe | Answers with | How |
|---|---|---|
| `dependency {project, name}` | found / not found, plus manifest file names | parses `Cargo.toml`, `Cargo.lock`, `package.json`, `pyproject.toml`, `requirements*.txt`, `composer.json`, `Package.swift`, `go.mod`; exact or scoped-name match |
| `text {project, term}` | found / not found, count of tracked files, up to 5 repo-relative paths | `git grep -F -l -I -- <term>` at HEAD (argv only, no shell); term 3–80 printable chars, no newline |
| `claude_feature {project, feature}` | the profiler's facts for hooks, MCP, skills, plugins, agents, settings | from `profile` (A9) |
| `invocation {project}` | how the project starts Claude | from `profile` |

Never returned: line contents, matching text, diffs or file bodies. Every call gets an id (`c1`, `c2`, ...), and its one-line result is appended to the run's digest under "Checks Huey ran". So the shown digest includes exactly what the model learned (AC22). A `Checked:` line must cite a check or a "how it runs" fact (A4), so a wrong check is visible and correctable (the PRD's "confidently wrong checks" risk).

### A6. Budget modes

`budget.rs` reads the posture through `PostureSnapshot` (`src/data/rate_limits.rs:278+`; extend it with `exhausted_models`, `stale_input` and `billing_mode` if they are not parsed yet) and maps it per D1.

| Mode | Model | Caps | Report |
|---|---|---|---|
| Normal | `[agents.huey] model` (default `sonnet`, D8; `opus` allowed) | `--max-budget-usd 3.0`, 4 min | full |
| Tight | `tight_model` (default `sonnet`) | `--max-budget-usd 1.0`, 4 min; candidate bundle trimmed to first-party plus the top 40 others | at most 3 picks, no Also noted, "Short report: budget is tight today.", Also in the news kept |
| Critical | none | none | uncurated first-party headline list (at most 20, V4) plus the Also-in-the-news line by rule, labelled "Uncurated: budget is critical, so no model ran today." |

The mode and the raw posture are written into the digest's first lines and into `meta.json`.

### A7. Schedule, window, ledger, footer, Also-in-the-news eligibility

- **Schedule.** `report_time` (default `"06:30"`, local time of the daemon process) is the ready-by time, and the run starts at `report_time - lead_minutes` (default 30). The scheduler checks the wall clock every 60 s rather than sleeping until a deadline, because a sleep drifts across system sleep. Cases:
  - Late by more than 10 minutes with no attempt today: run now and record `late_reason: machine asleep or daemon not running at 06:00`.
  - A failed curated attempt: retried once after 10 minutes (V5).
  - Every day, weekends included.
- **Window.** Starts at `generated_at` of the last curated (normal or tight) report (D4). On the first run ever it starts 7 days back, and undated sources are still baseline.
- **Ledger** (`state/ledger.json`, 30 days): `{item_id, canonical_url, date, version, section}` for every item shown anywhere, sections being `pick | ain | also_noted | uncurated`. Rules:
  - An item in the ledger within 14 days is not a candidate for picks or Also noted. Exception: `section: uncurated` items remain candidates (D4).
  - A follow-up (a new version, a new release) is a different item id, so it stays eligible (AC11).
  - Regenerating replaces that date's ledger entries with the new version's.
- **Also-in-the-news eligible set** (computed by the daemon; AC41–AC45): first-party items (Anthropic news, docs release notes, Claude Code changelog) published or first seen in the **past 7 days**, regardless of the report window. Excluded:
  - picks of this report;
  - anything in the ledger (any section) within 14 days;
  - hard-ignored items, and items the model listed as `ignored`.

  Under critical, the rule takes the newest eligible item from Anthropic news, else the docs release notes, else the changelog. It is omitted if that item already appears in the uncurated list.
- **Footer** (daemon-rendered, at most 100 words; AC12, AC20, AC21):
  - "Looked at N items from M sources.";
  - "Read in full: <first-party sources that returned ok or quiet>.";
  - "No new items: <quiet sources>.";
  - "Failed: <source (reason)>." or "Failed: none.";
  - "In flight: <projects>.";
  - "Dropped: <up to 5 'title (reason)'>". Hard-ignore drops get "ignored: <term>". Anything shown anywhere is removed first, and the model's drops come first;
  - when the model skipped the Also-in-the-news line (D3): "No Also-in-the-news line: <ain_skip_reason>" (AC45).

  Run 2 of the simulation is the model to follow.

### A8. Sources and fetching (verified against the real sources, 2026-10-25)

Adding or removing a source is an edit to `~/.nostromo/huey/sources.toml`, which is re-read on every run. No code change and no restart. Defaults (written at setup confirm):

| id | kind | URL(s) | dated? | class | what one item is |
|---|---|---|---|---|---|
| `claude-code-changelog` | `npm_changelog` | `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md` + `https://registry.npmjs.org/@anthropic-ai/claude-code` | **yes**: `CHANGELOG.md` has `## 2.1.310` headings with no dates (verified: 430 versions, none dated), but npm's `time` map dates every version (verified: `2.1.310` → `2026-10-23T21:20:46Z`). A version npm lacks falls back to first-seen. | first-party | one version: full entry text; link `…/CHANGELOG.md#<anchor>` (Cody verifies GitHub's anchor form, e.g. `#21310`) |
| `claude-docs-release-notes` | `md_dated_sections` | `https://docs.claude.com/en/release-notes/overview.md` (verified: markdown with `### October 22, 2026` headings; follow redirects) | yes | first-party | one bullet, dated by its section; link = the bullet's first link, else the page |
| `anthropic-news` | `html_link_index` | `https://www.anthropic.com/news` (verified: about 26 `href="/news/<slug>"` links, no dates) | **no**: first-seen | first-party | one article; for **new** slugs only (at most 10 per run), fetch the article and read `og:title` / `og:description` |
| `mcp-spec-releases` | `github_releases` | `modelcontextprotocol/modelcontextprotocol` | yes | first-party | one release |
| `agent-sdk-python`, `agent-sdk-typescript` | `github_releases` | `anthropics/claude-agent-sdk-python`, `anthropics/claude-agent-sdk-typescript` | yes | first-party | one release (body full text) |
| `simon-willison` | `feed` | `https://simonwillison.net/atom/everything/` (verified Atom) | yes | curated | one entry; summary text at most 1,200 chars plus outbound links |
| `latent-space` | `feed` | `https://www.latent.space/feed` (verified RSS 2.0) | yes | curated | one entry |
| `hn-front-page` | `hn_front_page` | `https://hacker-news.firebaseio.com/v0/topstories.json` + item API, top 30 | yes | aggregator | one story; **`enabled = false`** |

Rules (T1, T2):
- GET only. Each source has a 30 s timeout and an 8 MiB body cap (npm's full document is about 1.5 MB). User-Agent `Nostromo-Huey/<version> (+https://github.com/thehammer/nostromo)`.
- `ETag` / `If-Modified-Since` are used where the server sends them. GitHub calls use the token from the existing `github_client` when one resolves (`src/data/github_client.rs:39`), and go unauthenticated otherwise.
- Sources run concurrently, and one failure never affects another.
- **Quiet vs failed:** a source that answered and parsed but had nothing new in the window is `quiet`. Timeouts, non-2xx responses and unparseable bodies are `failed`.
- **Undated sources:** each item id gets `first_seen_at` the first time it is fetched. The first successful fetch of an undated source marks every item present as `baseline`, never eligible. Items first seen after the window start are eligible, including items first seen during a failed run (AC5).
- **Item ids** are stable: `<source id>:<native key>` (version, release tag, slug, entry id, or the bullet's hash within its date).
- **Clustering:** canonical URL (lower-cased host, no fragment, no `utm_*`, no trailing slash) plus each item's outbound links. Items sharing a canonical URL, or one linking to the other's canonical URL, form one cluster.
- **New crate:** `feed-rs` (Atom/RSS). No HTML crate: the link index and `og:` meta are read with anchored regexes, and HTML-to-text reuses the reducer in `src/data/google_detail.rs` (made `pub(crate)`).

### A9. Context, projects, "how it runs", digest

Context sources (each can be switched off in `sources.toml [context]`; the setup step lists them with paths):

- the code root from `Config::code_root_dir()`;
- tracker boards from `<state root>/trackers/state.json` and the board files it lists, item titles and states only;
- open and merged PRs by the user, through one GitHub search call;
- recent git commits per project (subjects of the last 7 days, at most 5);
- Mother jobs from the in-daemon `JobsFeed` (`src/mother/feed.rs:153`);
- Bishop's posture (`~/.claude/budget-posture.json`);
- `~/.claude/ideas` (titles and dates), open todos (titles, through the Teri todos parser, whether or not Teri is enabled), `~/.claude/notes` (titles of the last 14 days);
- the interests file.

**Projects** are git repos under the code root, deduplicated by `git rev-parse --git-common-dir`, so the many `maisie-feat-*` worktrees under Sendai's root collapse into `maisie`. A project is **in flight** if it has any of:
- an open PR by the user;
- a commit in the last 14 days;
- a Mother job for it in the last 7 days;
- a tracker board rooted in it.

In-flight projects are sorted by most recent activity and capped at 8. Projects under "Ignore entirely" (by name, case-insensitive) are removed, together with every context line that matches a hard-ignore term (AC26).

**"How it runs" profile** (deterministic, cached by HEAD sha; T12):
- languages, from manifests;
- whether an Anthropic SDK is used (`anthropic`, `@anthropic-ai/sdk`, `@anthropic-ai/claude-agent-sdk`, `claude-agent-sdk`, `claude_agent_sdk`): "uses" or "does not use an Anthropic SDK";
- how Claude is started, from `git grep` counts of `claude -p`, `--print`, `--output-format stream-json`, `--agent`, `--resume`;
- the Claude Code features it relies on (`.claude/settings*.json` hooks, `.mcp.json`, `.claude/skills/`, `.claude-plugin/plugin.json`, `.claude/agents/`, MCP server crates or packages);
- the distinct `CLAUDE_CODE_*` environment variable **names** it references (at most 5).

The profile renders to one line of at most 300 chars. Example: `Rust daemon + Swift apps; starts claude with --output-format stream-json and --agent; relies on hooks, an MCP server; does not use an Anthropic SDK; env: CLAUDE_CODE_…`. A `## How it runs` correction in the interests file replaces the line, and the digest says `(your correction)` (AC25). Posture lines: Bishop's posture attaches to a project named `bishop` (else a machine line), and Mother's queue state (counts by state from `JobsFeed`) to `mother`.

**Digest** (`digest.md`; deterministic, stable ordering, at most 16 KiB with "+N more" truncation; T9). Every line carries an id the model can cite:

```
# Context for Huey: Sendai, 2026-10-25 (v1)
Mode: tight (Bishop: "Pump the brakes"; 7-day 72% used, pace 1.9; billing metered)
## Interests
- [i1] (care) Agent harnesses that put the human first …
- [i8] (want more) Concrete changelog items I could adopt or delete a workaround for.
- [i10] (want less) Model benchmark and leaderboard news …
- [i12] (ignore) PHP and Laravel news (`PHP`, `Laravel`)
## Projects in flight
### Nostromo [nostromo]
- [nostromo:how] How it runs: … (Huey's line)
- [nostromo:pr#326] Open PR #326: Terminal pane 3a, text engine for agent follow
- [nostromo:merged#324] Merged Oct 24: Fred Google accounts (Swift/iOS)
- [tracker:gmail-setup] Board gmail-setup: 7 open (Google Cloud project; consent screen; …)
### Mother [mother]
- [mother:how] How it runs: …
- [mother:posture] Queue: idle; 1 stalled teardown
- [job:abc123] Job "archie lenses doc": awaiting review
## Ideas, todos, notes (titles only)
- [idea:huey-focus] Huey focus (2026-10-24)
## Checks Huey ran
- [c1] mother: text `CLAUDE_CODE_RETRY_WATCHDOG`: not found (214 tracked files searched)
```

### A10. The focus, panes, wire and actions

- **Focus.** A built-in `huey` focus (H7: `Focus.builtIns`, org "Personal"). Its daemon default tree (H6: `default_huey_tree` in `src/mcp/views/tree.rs`) is a `tabs` region `huey` holding **Report** (`report`) and **Context** (`context`), above the REPL at 0.62 / 0.38.
- **Pane sources.** The daemon binds `report` → `huey.report` and `context` → `huey.context` when it seeds the tree, so the panes paint with no agent turn. Both sources take optional `params {date, version}`; with no params a pane shows "current", meaning one of:
  - today's latest version;
  - the setup document;
  - the latest report with a not-today banner.

  They are added to `KNOWN_SOURCES` (`src/mcp/tools/apply_layout.rs:186-198`) with content kind `document`, so persisted bindings survive a disabled restart (AC38). `EnabledAgents::allows_source` refuses them while Huey is off (AC36).
- **New pane content kind** `PaneContentWire::Document` (additive; `PROTOCOL_VERSION` stays 4; old clients decode it as `unknown`):
  ```rust
  Document {
      title: String,                       // always carries the report date (AC31)
      #[serde(default, skip_serializing_if = "Option::is_none")] banner: Option<DocBanner>, // {level: info|warning, text}
      blocks: Vec<MdBlock>,                // existing block model (src/ipc/protocol.rs), built with src/markdown_blocks.rs
      #[serde(default, skip_serializing_if = "Vec::is_empty")] actions: Vec<DocAction>,   // {id, label, primary: bool}
  }
  ```
  Inline links with the scheme `nostromo-action:<id>` are actions too (used for per-pick verdicts). A client opens only `https:` links and `nostromo-action:` links, and ignores everything else.
- **New client message** `ClientMsg::PaneAction { tag, pane_id, action_id, operator_nonce }`. It follows `ClaudeLoginAction`: operator-app peers only (`src/ipc/server.rs:1150-1160`), and anyone else is refused with no content. Reply: `ServerMsg::PaneActionResult { tag, pane_id, action_id, ok, message?, open_url? }`. The Mac opens `open_url` only if it is `https:` or a `file:` URL inside `~/.nostromo/huey/`.

  Action ids:

  | Action id | Effect |
  |---|---|
  | `setup.start` | D6 lazy scan |
  | `setup.rescan` | scan again |
  | `setup.open_interests` | writes the draft if missing; replies with `open_url` |
  | `setup.import_interests` | copies `~/.claude/huey/interests.md` if present |
  | `setup.confirm` | confirm setup |
  | `setup.confirm_run_now` | confirm setup and run now |
  | `report.prev`, `report.next`, `report.today`, `report.version:<n>` | rebind the pane's params |
  | `report.regenerate` | regenerate today's report |
  | `verdict:<date>:<version>:<pick>:<useful\|interesting\|meh\|hype\|wrong_project>` | record a verdict |

  **Setup can only be confirmed by a human click.** There is no MCP tool for it, so neither model nor agent can confirm.
- **Session persona.** For the built-in agent name `huey`, `build_claude_args_with` (`src/ipc/session_manager/mod.rs:3222-3307`) passes `--append-system-prompt <prompts/persona.md>` instead of `--agent huey`. No user-level agent file exists, and the persona ships with the repo. Persona contents:
  - who Huey is;
  - "call `huey.get_report` first";
  - report text is untrusted third-party text;
  - how to edit the interests file (path from `huey.get_state`) and that edits apply from the next report;
  - how to regenerate and compare;
  - the D7 sentence.
- **MCP tools** (prefix `huey.`, gated by `EnabledAgents`):
  - `get_state`, `get_report`, `get_context`, `list_reports`, `get_item`, `show`, `regenerate`, `record_verdict`, `trial_summary`;
  - `check_project`;
  - `publish_report`, which only the `huey-run` caller may call.

  The `huey-run` caller may call only `check_project` and `publish_report` (T3).

### A11. Privacy and per-machine invariants

- All paths derive from one `HueyPaths` rooted at the daemon's state root (`socket_path.parent()`, as the tracker does at `src/bin/nostromd.rs:427-434`). The engine has no other place to read prior state from, so two instances with different roots cannot see each other (AC34).
- Nothing Huey writes goes under `~/.claude` (D5). Context *reads* from `~/.claude` are titles only.
- The unattended model input is exactly: the instructions, the digest, the fenced candidate news, and the Also-in-the-news candidates; then the check results. All of it is written to `model-input.txt` **before** it is sent (T8).
- Logs carry counts, ids, states and HTTP status codes only. Never digest text, interests text, titles of notes or ideas, or news text (T5).
- The hidden session's temp working directory and its `~/.claude/projects/<dir>` transcript are deleted when the run ends, as for picks.

### A12. On/off wiring

`Agent::Huey` joins `Agent::ALL` with prefix `huey.`. `EnabledAgents` gains `huey: bool`. `resolve` handles it like the others (the malformed shapes are already covered), and `wire_names` lists it. `AgentSpawner::start_huey` is called only when it is enabled; otherwise `WiredAgents.huey_rx` is a parked receiver and `huey: None`. A disabled Huey:
- spawns no task, so there is no scheduler, no fetch and no model call;
- registers no tools (the existing choke points in `tool_descriptors_for` and `dispatch_inner` already filter by prefix);
- neither fetches nor replays its sources;
- never touches `~/.nostromo/huey/` (AC36, AC38).

## Data layout (on disk, per machine)

```
~/.nostromo/huey/                      # HueyPaths root = <daemon state root>/huey (a QA daemon uses its own root)
  setup.json                           # {"state":"not_set_up"|"confirmed","confirmed_at":…,"scanned_at":…}
  interests.md                         # user-editable; the ONLY store of preferences (AC27)
  sources.toml                         # news sources + [context] switches; written at confirm, re-read every run
  state/
    sources/<source-id>.json           # {last_attempt_at, last_ok_at, etag, last_modified, baseline_done,
                                       #  items: {item_id: {first_seen_at, published_at?, baseline: bool}}} (90-day prune)
    profiles/<project>.json            # how-it-runs facts, keyed by HEAD sha
    ledger.json                        # shown items, 30 days
    runs.jsonl                         # one line per attempt: at, trigger, mode, outcome, reason, version, durations
  pool/<YYYY-MM-DD>.json               # frozen fetched items for that date (regenerate, audit, 7-day Also-in-the-news pool); 30-day prune
  reports/<YYYY-MM-DD>/
    v1/
      meta.json                        # generated_at, trigger, mode, posture, model, window_start, outcome, late_reason
      report.json                      # structured report (picks with item ids, links, project, check), the render input
      report.md                        # rendered markdown (what the pane shows)
      digest.md                        # the digest exactly as sent, "Checks Huey ran" included
      model-input.txt                  # every byte Huey supplied to the model (absent in critical mode)
      checks.json                      # each check: id, probe, args, result
    v2/ …                              # regenerations
    verdicts.json                      # [{version, pick, item_id, verdict, note?, at}]
  (reports and their verdicts are pruned after 60 days; AC29 needs 30)
```

Config (`~/Library/Application Support/nostromo/config.toml`). Every key is optional. Unknown keys and bad values produce a warning naming the key, never the value:

```toml
[agents.huey]
enabled = true            # false switches Huey off on this machine (restart nostromd)
report_time = "06:30"     # ready-by, local time
lead_minutes = 30
model = "sonnet"          # normal mode (D8); "opus" allowed
tight_model = "sonnet"
max_budget_usd = 3.0
tight_max_budget_usd = 1.0
```

Interests file format (parsed by heading text, case-insensitive; anything else is kept and shown, never fatal):

```markdown
# Huey interests (Sendai)
## What I care about, and why
- **Agent harnesses that put the human first** (…). Why: …
## Want more of
- …
## Want less of
- …
## Ignore entirely
- PHP and Laravel news (`PHP`, `Laravel`)      ← backticked terms are hard filters
## How it runs
- **mother**: workers run `claude -p` non-interactively and set CLAUDE_CODE_RETRY_WATCHDOG   ← replaces Huey's line
```

## Conventions for every job

- **Repo:** nostromo (`github.com/thehammer/nostromo`). **Base:** `origin/main` (the default branch is `main`). Each job has its own branch and PR.
- **Rust gates run in the RWX sandbox only, never local `cargo` in a worktree** (`docs/rwx-sandbox.md`):
  - `rwx sandbox exec -- cargo test --test <name>` and `--lib <path>` while iterating;
  - before the PR: `rwx sandbox exec -- cargo fmt --check`, `rwx sandbox exec -- cargo clippy --all-targets -- -D warnings` and `rwx sandbox exec -- cargo test`;
  - then `rwx sandbox stop`.
  - The six `mother::broker_client` SUN_LEN failures are pre-existing; ignore them if they appear.
- **Swift:** `make kit-test`, `make mac`, `make mac-test`, or `make ci-remote ONLY=swift` after pushing.
  - `macOS/Nostromo.xcodeproj` does not use synchronised groups. **Add Swift tests to existing test files.** A new app source file needs its PBXFileReference, PBXBuildFile, group and Sources entries copied from a sibling.
  - New NostromoKit files are picked up by SwiftPM automatically.
- **Tests with no network and no model.** Use `wiremock` for HTTP. Inject a fake clock (`crate::tracker::clock::FakeClock`), a posture-file path, temp state and context roots, and a fake `PicksSessionHost` that records spawn/send/stop and scripts `publish_report` calls. Fixtures go under `tests/fixtures/huey/`. They must be **public-safe** (no private names, no work context), and fixture context files carry canary strings such as `CANARY-RAW-TRACKER-7f3a` so raw-content leaks are detectable.
- **Logging (T5):** counts, ids, states and HTTP status only.
- **Do not edit** `docs/plan-huey.md` or `docs/prd-huey.md`; they are the spec. Do not commit per-job plan files under `docs/plans/huey/`; those are local working copies.
- Commit messages are `feat(huey): … (H<n>)`. The PR body lists the `[H<n>-k]` checklist with evidence (test names).

---

## Job H1: Switch, skeleton and state root

**Goal:** Huey exists as a switchable built-in agent: it is listed in the welcome, has an engine task that does nothing until set up, owns a state root, and has one MCP tool. Nothing is visible in the app yet.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h1-switch`
- **Base:** `origin/main`
- **Depends on:** none. This is the first job.

### Files to change
- `src/agents.rs`:
  - `Agent` (`:4-35`) gains `Huey`: `name` → `"huey"`, `tool_prefix` → `"huey."`, and `ALL` becomes `[Fred, Huey, Perri, Teri]`.
  - `EnabledAgents` (`:37-111`) gains `pub huey: bool`, with `all()` setting it to true, plus `is_enabled` / `set` arms.
  - `resolve` (`:166-216`): the unknown-agent warning says `(known: fred, huey, perri, teri)`.
  - `AgentSpawner` (`:253-260`) gains `fn start_huey(&mut self) -> HueySources`.
  - `WiredAgents` (`:265-276`) gains `pub huey: Option<crate::huey::HueyHandle>` and `pub huey_rx: watch::Receiver<crate::huey::HueyView>`.
  - `wire_agents` (`:282-341`) calls `start_huey` only when enabled, and parks `huey_rx` otherwise.
  - Update every `EnabledAgents { fred, perri, teri }` literal in tests (`grep -rn "EnabledAgents {" src tests`).
- `src/lib.rs`: add `pub mod huey;`.
- `src/huey/mod.rs` (new): declares **all** submodules from A1, with empty stub files carrying a `//! Filled by H<n>` doc line, so that H2 and H3 touch disjoint files. Also:
  - `HueyEngine::spawn(deps) -> HueySources`;
  - `HueyHandle` (setup state, paths, config);
  - `HueyView { version: u64 }`;
  - a scheduler loop that, in H1, only logs `huey: not set up` once per day and returns. No reads and no network.
- `src/huey/paths.rs`, `src/huey/config.rs`, `src/huey/setup.rs` (state load/save only): as in A1 and the data layout. `config::resolve(agents: Option<&toml::Value>) -> (HueyConfig, Vec<String>)` reads the extra keys of the `huey` table. Defaults are in the data layout. Bad values produce a warning naming the key and fall back to the default.
- `src/bin/nostromd.rs`:
  - `RealAgentSpawner` (`:866-1000`) implements `start_huey`, passing the state root (`socket_path.parent()`, as at `:427-431`), `Config`, `session_mgr` and `broadcast_tx`;
  - log the Huey config warnings next to the agent warnings (`:79-83`);
  - destructure the new `WiredAgents` fields (`:401-414`);
  - pass the handle into `DaemonSources`.
- `src/mcp/state.rs` (`DaemonSources` `:420-433`, `McpSharedState`, `for_test`): add `huey: Option<HueyHandle>` and `huey_rx`.
- `src/mcp/tools/huey.rs` (new) and `src/mcp/tools/mod.rs`: register `huey.get_state` → `{enabled, setup_state, report_time, paths:{interests, sources, reports}, last_run: null}`. Gating comes free from the existing prefix filters.
- `tests/agent_wiring.rs`: extend the recorder spawner with `start_huey`.

### Approach
1. Add the agent and the switch; fix the literals; run the `agents` unit tests.
2. Add the `huey` module skeleton and `HueyPaths`. **The engine must not create `~/.nostromo/huey/` until something needs writing.** In H1 nothing does, so a disabled Huey, or an unset-up Huey, leaves no trace (T6).
3. Wire the daemon and the MCP state. Add `huey.get_state`.
4. Tests (see the acceptance criteria).

### Acceptance criteria
- [ ] **H1-1** With no `[agents.huey]`, `resolve` enables Huey, `wire_names()` is `["fred","huey","mother","perri","teri"]`, and the welcome frame carries it (extend the existing server welcome test; the pinned wire-form test with `enabled_agents: None` stays byte-identical). (AC35)
- [ ] **H1-2** `[agents.huey] enabled = false`: in `tests/agent_wiring.rs`, `start_huey` is never called, `huey` is `None`, and `huey_rx` is parked. `huey.get_state` is absent from `tool_descriptors_for` and dispatches to `UnknownTool`. (AC36)
- [ ] **H1-3** The malformed shapes `[agents] huey = false`, `[agents.huey] enabled = "no"` and `[agents.huey] enabled = 0` leave Huey on with exactly one warning each, naming keys only. Extend the existing table in `malformed_shapes_warn_and_disable_nothing`. (AC37)
- [ ] **H1-4** `[agents.huey] report_time = "25:99"` warns (naming `report_time`, never the value) and uses `06:30`. Extra Huey keys never produce the unknown-agent warning.
- [ ] **H1-5** An engine with a temp state root, never set up, run past its default run time with a `FakeClock`, creates no files under the root and makes no HTTP request (wiremock with `expect(0)`). (AC1 groundwork, T6)
- [ ] **H1-6** Fmt, clippy and the full `cargo test` pass in the sandbox.

### Must not touch
Swift, the protocol, pane sources, layouts, `src/ipc/session_manager`. Fetching and context code, apart from stub files. `README.md` (H8 documents Huey once it is visible).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Additive extension of a known pattern (agent switch + spawner trait) plus an inert module skeleton."
  redd:
    model: sonnet
    effort: medium
    rationale: "Extend existing switch/wiring tests; one no-activity test with fake clock and wiremock."
  marty:
    model: sonnet
    effort: low
    rationale: "downgrade: small additive diff; only check the skeleton's module boundaries are clean."
  perri:
    model: sonnet
    effort: medium
    rationale: "Watch for an engine that writes or reads before setup, and for struct-literal churn."
```

---

## Job H2: Fetching (plain code, no model)

**Goal:** given `sources.toml`, per-source state and a window, return eligible news items and a per-source status. Every default source works against wiremock fixtures recorded from the real formats.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h2-fetch`
- **Base:** `origin/main`
- **Depends on:** H1. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts.

### Files to change
- `Cargo.toml`: add `feed-rs` (latest 2.x).
- `src/huey/items.rs`: `NewsItem { id, source_id, class: FirstParty|Curated|Aggregator, title, url, canonical_url, published_at: Option<DateTime<Utc>>, first_seen_at, text (full for first-party, ≤1,200 chars otherwise), outbound_links }`; `canonicalize(url)`; `cluster(items) -> Vec<Cluster>`.
- `src/huey/sources/config.rs`: the `sources.toml` model (`[[source]] id, name, kind, url(s), class, enabled, …` and `[context] …` switches), `default_toml()` with the A8 table (HN `enabled = false`), and a loader that warns and skips bad entries (never fatal).
- `src/huey/sources/{feed.rs, npm_changelog.rs, md_dated_sections.rs, html_link_index.rs, github_releases.rs, hn.rs}`: one adapter per kind, as in A8.
- `src/huey/sources/state.rs`: per-source state (first-seen, baseline, conditional-GET headers), atomic writes (temp file plus rename).
- `src/huey/sources/fetch.rs`: `fetch_all(cfg, state_dir, window_start, now, http) -> FetchOutcome { items, statuses: Vec<SourceStatus{id, name, class, outcome: Ok{new}|Quiet|Failed{reason}}> }`, plus pool save/load (`pool/<date>.json`).
- `src/data/google_detail.rs`: make the HTML-to-text reducer `pub(crate)`, with no behaviour change.
- `tests/huey_fetch.rs` and `tests/fixtures/huey/sources/`: trimmed real-format samples (a CHANGELOG with 10 versions, an npm `time` map, the release-notes `.md`, a news index HTML plus two article pages, a GitHub releases JSON, an Atom feed, an RSS feed, HN JSON). Public text only.

### Approach
1. Items, canonical URLs and clustering first, as pure functions with unit tests.
2. Adapters, each tested against its fixture. A parse failure is `Failed{reason}` with a plain reason ("could not parse feed"); never a panic, never a silent empty.
3. `fetch_all`: concurrent, per-source timeout and body cap (T1), only GET, conditional headers stored.
4. Window and baseline logic in one function, `eligible(item, state, window_start) -> Eligibility { Eligible | Baseline | BeforeWindow }`.
5. Source guard unit test (T2): the `src/huey/sources/` tree contains no `.post(`, `.put(`, `.patch(`, `.delete(` or `.request(`.

### Acceptance criteria
- [ ] **H2-1** Undated source: the first successful fetch marks all present items baseline and returns none as eligible. A fixture adding one item makes exactly that item eligible on the next fetch, even if the run in between failed. (AC5)
- [ ] **H2-2** The changelog fixture with 8 versions newer than the window, dated through the npm `time` map, yields 8 items, each carrying its full entry text. The oldest one's "Added" line is in its item text. A version missing from npm falls back to first-seen. (AC19)
- [ ] **H2-3** A window covering three days of fixture items returns items from all three days. (AC4, fetch side)
- [ ] **H2-4** A source with no items after the window is `Quiet`, and never `Failed`. (AC20)
- [ ] **H2-5** One source timing out (wiremock delay beyond the timeout) and one returning garbage are each `Failed` with a reason, while every other source's items are still returned. (AC21)
- [ ] **H2-6** One release present as a GitHub release, a Simon Willison entry linking to it and an HN story pointing at it form one cluster. (AC10, deterministic part)
- [ ] **H2-7** `default_toml()` round-trips through the loader, contains every PRD starting source, and has HN with `enabled = false`. An entry with an unknown `kind` is skipped with a warning, and the others still load.
- [ ] **H2-8** The source guard test passes (T2). Fmt, clippy and test pass in the sandbox.

### Must not touch
`src/huey/context/`, `interests.rs`, `checks.rs` (H3), the engine loop, MCP, protocol, Swift. No real network in tests.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Six parsers over untrusted third-party formats, window/baseline state and concurrency limits; many edge cases."
  redd:
    model: sonnet
    effort: high
    rationale: "Fixture-driven wiremock tests per adapter plus window/baseline/failure isolation; these pin AC4/5/19/20/21."
  marty:
    model: sonnet
    effort: medium
    rationale: "Keep adapters small behind one trait; share HTTP limits and HTML reduction."
  perri:
    model: sonnet
    effort: high
    rationale: "Untrusted input parsing, body caps, timeouts and GET-only guard; misses become hangs or crashes."
```

---

## Job H3: Context, profiles, digest, checks and the setup scan

**Goal:** build the per-machine digest deterministically from local context, write "how it runs" lines from facts, answer read-only check probes, and produce the setup scan and draft interests file. Everything here is plain code.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h3-context`
- **Base:** `origin/main`
- **Depends on:** H1. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts. Runs in parallel with H2.

### Files to change
- `src/huey/interests.rs`: parser for the format in "Data layout" → `Interests { bullets: Vec<{id, section, text, lead, hard_terms}>, how_it_runs: BTreeMap<project, String>, warnings }`. Ids `i1…` are by order. Section names match case-insensitively by prefix. A missing section is a warning, not an error.
- `src/huey/context/projects.rs`: discovery under `Config::code_root_dir()`, worktree dedupe, the in-flight rule and cap (A9). Uses `git` with fixed argv only (`rev-parse`, `log`, `grep`), each call with a 5 s timeout.
- `src/huey/context/profile.rs`: the A9 profile and its one-line render. Cached in `state/profiles/` by HEAD sha.
- `src/huey/context/collectors.rs`: tracker boards (read `<state root>/trackers/state.json` and the board files through `crate::tracker` parsing; titles and states only), PRs (one GitHub search for the user's open and recently merged PRs through `src/data/github_client.rs`; an unavailable token degrades to a "PRs unavailable" note), git subjects, Mother jobs (a `Vec<MotherJob>` snapshot passed in from `JobsFeed`), Bishop posture, ideas, todos and notes titles. Each collector takes explicit roots and paths, which is how tests inject fixtures (AC34).
- `src/huey/context/digest.rs`: `build_digest(inputs) -> Digest { text, projects: Vec<ProjectId>, anchors: BTreeSet<String>, interests }`, in the A9 format: stable ordering, the 16 KiB cap, ignore filtering (projects by name, lines by hard term). `append_checks(&mut Digest, &[CheckResult])` adds the "Checks Huey ran" section.
- `src/huey/checks.rs`: the A5 probes. `check(project_root, probe) -> CheckResult { id, project, probe, found, detail }`. Validates terms, never returns line contents, uses argv only, 5 s timeout.
- `src/huey/setup.rs` (extend): `scan(config, paths) -> SetupScan { context_sources: Vec<{name, path, note}>, projects: Vec<{id, how_it_runs}>, interests: Existing|Missing|ImportableFrom(path) }` (in memory, D6), and `write_draft(paths, scan)`. The draft has the four sections; under "What I care about" one bullet per in-flight project with its manifest description (Cargo `description`, package.json `description`, or the README's first sentence, at most 160 chars); empty "Want more of", "Want less of" and "Ignore entirely" sections with one-line hints; no "How it runs" section. Context-source notes mark `~/.claude/ideas`, the todos source and `~/.claude/notes` each as "may be synced from other machines" (D5's v1 mitigation; the setup document shows the note next to each source).
- `tests/huey_context.rs` and `tests/fixtures/huey/context/`: two disjoint fixture machines (`machine-a` with Rust + shell repos, `machine-b` with a PHP repo), tracker `state.json` and boards, ideas, notes, a posture file, and an interests file. Canary strings go in raw files.

### Approach
1. Interests parser, then projects and profile (pure, fixture-driven), then collectors, then digest, then checks, then setup scan and draft.
2. The digest is the privacy boundary. It may contain only titles, states, ids, counts, profile facts, interests bullets and posture numbers. Write a unit test that builds a digest from fixtures whose raw files contain canaries, and asserts no canary appears.

### Acceptance criteria
- [ ] **H3-1** The fixture digest has, per in-flight project, its open items (PR, board, job), a "how it runs" line, and, for `bishop` and `mother`, a posture line. The Bishop posture numbers appear. (AC23)
- [ ] **H3-2** No canary string from raw tracker files, notes bodies, idea bodies, source files or manifests appears in the digest. (AC24, digest side)
- [ ] **H3-3** A `## How it runs` correction for `mother` replaces Huey's line in the next digest and is marked `(your correction)`. (AC25)
- [ ] **H3-4** A project named under "Ignore entirely" is absent from the in-flight list. A context line containing a backticked hard term is absent from the digest. (AC26, digest side)
- [ ] **H3-5** Two instances (machine-a and machine-b roots) produce digests with no project, repo, PR, board or idea from the other. Machine-b's PHP repo profiles as PHP; machine-a has no PHP project. (AC34, digest side)
- [ ] **H3-6** The profile reports "does not use an Anthropic SDK" for a fixture repo without one, and names the SDK for one that has it. The `dependency` probe agrees with the profile. (AC14, AC15 groundwork)
- [ ] **H3-7** The `text` probe returns found or not found, a file count and at most 5 paths, never line contents. Terms with newlines or under 3 chars are refused. The argv-only rule is pinned by a unit test that the module never calls `sh`/`bash`. (T12)
- [ ] **H3-8** `scan` lists the context sources with paths, the in-flight projects with their "how it runs" lines, and the interests status; it writes nothing. `write_draft` creates a file with the four section headings and one bullet per in-flight project. The ideas, todos and notes sources each carry the "may be synced from other machines" note. With a fixture `HOME`, neither `scan` nor `write_draft` writes anything under `$HOME/.claude`. (AC1 and AC2, content side; D5 mitigation)
- [ ] **H3-9** Identical inputs give a byte-identical digest (T9). The digest cap truncates with "+N more".
- [ ] **H3-10** Fmt, clippy and test pass in the sandbox.

### Must not touch
`src/huey/sources/`, `items.rs` (H2), the engine loop, the session manager, MCP tools other than none, protocol, Swift. Never write under `~/.claude`.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "Privacy boundary of the whole feature: digest must be summaries only; plus repo profiling, worktree dedupe and read-only probes."
  redd:
    model: sonnet
    effort: high
    rationale: "Fixture machines with canaries pin AC23-26 and AC34; probe refusal cases matter."
  marty:
    model: sonnet
    effort: medium
    rationale: "Collectors behind one small input struct; no duplication with tracker/teri parsing."
  perri:
    model: opus
    effort: high
    rationale: "Reviews for raw-content leaks into the digest, git argv safety and anything synced via ~/.claude."
```

---

## Job H4: The run pipeline, schedule, budget modes, critical report and store

**Goal:** the engine runs the daily pipeline end to end, deterministically: schedule, window, eligibility, hard filters, digest, mode, the critical (uncurated) report, Also-in-the-news eligibility and its rule, ledger, footer, versions, retention, and failure labelling. The curated branch is a seam that H5 fills, and here it records "model unavailable".
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h4-run`
- **Base:** `origin/main`
- **Depends on:** H2, H3. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts.

### Files to change
- `src/huey/budget.rs`: posture snapshot → `Mode` per D1 (including: `billing_mode: "metered"` forces at least tight), plus a `PostureNote` for the digest and footer.
- `src/huey/schedule.rs`: `next_run_at`, `is_due`, lateness, retry (A7). Takes `&dyn crate::tracker::clock::Clock` and a timezone offset provider (the real one is `chrono::Local`).
- `src/huey/store.rs`: the data-layout tree: reports by date and version, `meta.json`, ledger, `runs.jsonl`, `verdicts.json` I/O, retention pruning (60 days for reports, 30 for the pool and ledger, 90 for source item state). Atomic writes.
- `src/huey/run.rs`: `run(trigger) -> RunOutcome { Produced{date, version, mode} | Failed{reason: Asleep|FetchFailed|ModelFailed|NotSetUp} }` (no budget-skip reason, V6). Steps 1 to 8 of A2:
  - fetch failed = **no first-party source** returned `Ok` or `Quiet`;
  - hard-term filtering moves items to the drop list as "ignored: <term>";
  - Also-in-the-news eligibility and the critical rule (A7);
  - the `Curator` trait seam: `async fn curate(input) -> Result<Publish, CurateError>`. H4 ships `NoCurator`, which returns `CurateError::Unavailable`, so non-critical runs end as `ModelFailed` until H5.
- `src/huey/render.rs`: report model → `report.md` and `Vec<MdBlock>` (through `src/markdown_blocks.rs`). The order is opener, picks, Also in the news, Also noted, footer. Plus the footer (A7), the uncurated list (V4), the quiet and tight lines, and a `banner_for(current, today)` that labels any non-today report with its date and the reason today's is missing (AC31).
- `src/huey/mod.rs`: the engine loop. The scheduler drives `run`. Every state change bumps `HueyView`. `HueyHandle::current_document()` and `document_for(date, version)` return render-ready data for H6.
- `tests/huey_run.rs` and `tests/fixtures/huey/runs/`: pipeline tests with wiremock sources, fixture context, a fake clock, posture files and a scripted test `Curator` (a closure returning a given `Publish`). H5's validator is not used here: H4 tests feed already-valid publishes to prove rendering and ledger behaviour.

### Approach
1. Store and render first (pure).
2. Budget and schedule (pure, clock-injected).
3. `run.rs` assembling H2 and H3. Critical mode completes without a curator.
4. Engine loop and failure labelling. A run is never started when setup is not confirmed, and at most one run executes at a time (a mutex; a second trigger returns "already running").

### Acceptance criteria
- [ ] **H4-1** Not set up: with the clock advanced past the run time, both before and after `setup.start` was pressed (scanned but not confirmed), there are no HTTP requests (wiremock `expect(0)`), no curator calls and no report files. (AC1)
- [ ] **H4-2** Confirmed setup, default schedule: the run starts at 06:00 local, and a report for today exists before 06:30 with the scripted curator. Started at 09:00 with no report today, it runs immediately with `late_reason` set. (AC3 schedule side)
- [ ] **H4-3** No report for two days, then a run: items from all three days are candidates. The window starts at the last *curated* report; a critical report in between does not move it (D4): fixture of a critical day followed by a normal day, where the normal day's report covers both days. (AC4)
- [ ] **H4-4** An item shown on day 1 is not a candidate on days 2 to 14 and is again on day 15. A new version of the same product (a new item id) is a candidate on day 2. Uncurated entries do not block pick candidacy (D4). (AC11, deterministic part)
- [ ] **H4-5** The footer lists the item count and sources, the first-party sources read in full, quiet sources as quiet, failed sources with a reason, the in-flight projects, and at most 5 drops with reasons. No item shown anywhere appears as dropped, and no item appears in two sections. The footer is at most 100 words. (AC12, AC20, AC21)
- [ ] **H4-6** Tight posture fixture: the curator input says `max_picks: 3, also_noted: false`. The rendered report carries "Short report: budget is tight today.", has no Also-noted section, and keeps the Also-in-the-news line when one is eligible. (AC32, render side)
- [ ] **H4-13** Posture mapping table test (D1): each Bishop posture word, the 90%/98% thresholds, `stale_input`, a file older than 24 h, a missing file, and `billing_mode: "metered"` with `posture: "Cruise"` (→ tight, never normal) map as D1 says.
- [ ] **H4-7** Critical posture fixture: no curator call. The report is labelled uncurated and lists first-party headlines with links only (no blog or aggregator items), capped at 20 plus "and N more" (V4; fixture: 35 first-party items give 20 lines and "and 15 more"). The Also-in-the-news line is chosen by rule (the newest eligible from Anthropic news, else docs, else changelog) and omitted when its item is in the list. (AC33, AC44 rule side)
- [ ] **H4-8** Also-in-the-news eligibility: an aggregator-only story is never eligible; a story shown in the last 14 days is not; a pick is not; a hard-ignored item is not; a quiet week gives an empty set and no line. (AC41, AC43, AC45, AC42 ignore side)
- [ ] **H4-14** A publish with no Also-in-the-news line and an `ain_skip_reason` renders "No Also-in-the-news line: <reason>" in the footer, and the footer still holds to 100 words. (AC45)
- [ ] **H4-9** Each missing-report reason (asleep, fetch failed, model failed) produces a current document showing the latest earlier report, whose title carries its date and whose banner gives the reason. A previous day's report is never rendered without its date. (AC31)
- [ ] **H4-10** Hard-ignore: a fixture item whose title contains the backticked term `PHP` never reaches the curator input and is listed as "ignored: PHP" in the drops. In the machine-b fixture (no ignore term, PHP project) it reaches the curator input. (AC26, AC34 deterministic part)
- [ ] **H4-11** Retention: a 31-day-old report is still listed, and a 61-day-old one is pruned along with its verdicts. Pool and ledger prune at 30 days. (AC29)
- [ ] **H4-12** Disabled or not-set-up engines never write under the root (T6). Fmt, clippy and test pass in the sandbox.

### Must not touch
The hidden session, the prompt and the validator (H5). MCP tools beyond H1's, panes, protocol, Swift.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "Core orchestration with time, window, ledger, budget and failure semantics that many criteria rest on."
  redd:
    model: sonnet
    effort: high
    rationale: "Clock-driven pipeline tests across modes and failure reasons; pins AC1/3/4/11/12/29/31-33/41-45."
  marty:
    model: sonnet
    effort: medium
    rationale: "Keep run.rs a readable sequence of pure steps; render and store stay pure."
  perri:
    model: opus
    effort: high
    rationale: "Window/ledger off-by-ones and mislabelled old reports are the user-visible failure modes."
```

---

## Job H5: The curated model pass: hidden session, prompt, check and publish tools, validator

**Goal:** normal and tight runs produce curated reports through a hidden, restricted Claude Code session. The daemon enforces every rule in A4, and the model input is captured byte for byte.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h5-curate`
- **Base:** `origin/main`
- **Depends on:** H4. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts.

### Files to change
- `src/ipc/session_manager/mod.rs`:
  - `SessionRestrictions` (`:262-269`) gains `pub model: Option<String>`. `picks_restrictions()` passes `None`, so picks are unchanged.
  - In `spawn_session` (`:961-973`), the restricted branch passes `model_args` for `restrictions.model` instead of `(None, None)`.
  - Register the `huey-run` restrictions the way the picks tag is registered (`:621`).
- `src/data/work/picks.rs`: no behaviour change. Reuse `PicksSessionHost` and `SessionManagerHost` as they are (H5 does not rename them).
- `src/huey/curate.rs`: `SessionCurator: Curator`. It:
  - creates an empty temp cwd;
  - builds the model input: `prompts/curate.md` + mode limits + the digest (verbatim) + candidates fenced with `src/data/work/untrusted.rs` helpers + the Also-in-the-news candidates + the recent-reports list (ids and headlines of the last 14 days, for `follow_up_of`);
  - **writes it to `model-input.txt` before sending (T8)**, then spawns `huey-run` with restrictions (tools: `mcp__nostromo__huey_check_project`, `mcp__nostromo__huey_publish_report`, `ToolSearch`; the D8 model and cap) and sends the input;
  - waits for an accepted publish or a 4-minute timeout. Refusals go back to the model through the tool result, at most 3 attempts. Each check-tool call and result is appended to `model-input.txt` and to the digest's "Checks Huey ran" section as it happens;
  - always stops the session, then deletes the temp cwd and its transcript dir, as picks does.
- `src/huey/validate.rs`: every rule in A4's table, returning `Vec<Problem>` with messages that name ids (escaped and length-capped like `picks.rs::shown_ids`).
- `src/huey/prompts/curate.md`: the instructions, written from the PRD:
  - the honest-pick rule;
  - Checked vs To-check (at most one);
  - "a pick names a concrete anchor id and a concrete effect; otherwise Also noted";
  - Also noted is tagged with an interest id, never want-less or ignore;
  - Also in the news: significance for Claude users broadly (new models, API versions, breaking changes, licensing, pricing and limits, major capabilities above fixes); no project names; at most 40 words; the D3 skip rule;
  - "say what is new" for follow-ups;
  - the 600-word budget;
  - the untrusted-data warning, worded as in `PICKS_PROMPT`;
  - "call `huey.check_project` whenever the project itself can answer whether it is affected";
  - publish once, exactly the schema.
- `src/mcp/tools/huey.rs` and `src/mcp/tools/mod.rs`:
  - `huey.check_project` (any Huey-enabled caller);
  - `huey.publish_report` (only the `huey-run` caller; anyone else gets `forbidden`);
  - an `is_huey_run_session` guard beside `is_picks_session` (`:558-563`) that limits `huey-run` to those two tools in **both** `tool_descriptors_for` and `dispatch_inner`.
- `src/mcp/instructions.rs`: for the `huey-run` caller, the MCP instructions are a one-line Huey note instead of the tracker paragraph (A3).
- `src/ipc/peer.rs` (`:78-81`) or the restriction path: the `huey-run` tag is sensitive (D9; restricted tags already are).
- `tests/huey_curate.rs`: a fake `PicksSessionHost` capturing the spawn args and sent text, and scripting tool calls (check, then publish attempts) through the MCP dispatch in-process.

### Approach
1. Validator first, as a pure table-driven unit test per rule.
2. Prompt assembly and capture. One test asserts that the digest section of the captured input is byte-identical to `digest.md` (before the checks are appended), and that `digest.md` after the run equals the digest plus exactly the check lines the fake model received.
3. Session lifecycle with the fake host (spawn, send, stop always; timeout).
4. MCP tools and caller guard.
5. Wire `SessionCurator` into the engine in place of `NoCurator`.

### Acceptance criteria
- [ ] **H5-1** The shown `digest.md` equals the digest section of the captured model input byte for byte, and its "Checks Huey ran" lines equal the check results returned to the session. `huey.get_context` (H6) will serve this same file. (AC22)
- [ ] **H5-2** The captured model input contains none of the fixture canaries and no raw file contents. (AC24)
- [ ] **H5-3** Validator, one test per A4 rule: 6 picks refused (4 in tight); 6 Also-noted items refused (any in tight); a pick missing any required field refused; an unknown item id or project or anchor refused; a duplicate item id across sections refused; a checked pick with no check or fact, or citing a `not_found` dependency check, refused; a second To-check pick refused; an Also-noted item with a want-less or ignore interest id refused; an Also-in-the-news line naming a digest project, or over 40 words, or not in the eligible set, or also a pick, refused; an Also-in-the-news item also in Also noted accepted and moved; over 600 words refused; a quiet body at or over 150 words refused (D2); `follow_up_of` without `whats_new` refused. (AC6–AC10, AC12–AC18, AC40, AC42, AC43)
- [ ] **H5-4** A fixture day with 200 candidates and a fake model that first publishes 7 picks: refused with a message naming the cap; the second publish with 5 is accepted and rendered. (AC6)
- [ ] **H5-5** The rendered pick's first link is the original (the GitHub release) when the cluster has the release, a blog and an aggregator; the others are listed under "also covered by". (AC7, AC10)
- [ ] **H5-6** Spawn args for `huey-run`: no `--dangerously-skip-permissions`, `--permission-mode dontAsk`, `--strict-mcp-config`, `--setting-sources project`, `--disable-slash-commands`, `--tools ToolSearch`, the allow-list of exactly the two Huey tools plus ToolSearch, `--max-budget-usd` per mode, the mode's `--model`, cwd an empty temp dir. Picks' args are unchanged (existing tests stay green). (T3)
- [ ] **H5-7** A `huey-run` caller listing tools sees only `huey.check_project` and `huey.publish_report`. Calling any other tool is refused. A non-`huey-run` caller calling `huey.publish_report` is refused. (T3)
- [ ] **H5-12** The model fails once, then the 10-minute retry succeeds: today's report exists and carries no missing-report banner. (AC31)
- [ ] **H5-8** Timeout: no publish within the limit → the session is stopped, the outcome is `ModelFailed`, one retry is scheduled 10 minutes later (V5), and after the retry also fails the focus shows yesterday's report with the "model failed" banner. (AC31, V5)
- [ ] **H5-9** Tight mode passes `max 3 picks, no Also noted` in the input and uses `tight_model` and the tight cap. (AC32)
- [ ] **H5-10** The temp cwd and transcript dir are deleted after success, refusal exhaustion and timeout alike.
- [ ] **H5-11** Fmt, clippy and test pass in the sandbox.

### Must not touch
Fetching, context (except calling them), panes, protocol, Swift. Picks behaviour, whose tests must stay green unchanged.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "Unattended model session reading third-party text: restriction flags, caller guards, capture-before-send and a strict validator."
  redd:
    model: sonnet
    effort: high
    rationale: "Table-driven validator tests for every A4 rule plus fake-host session lifecycle; these carry most honest-pick criteria."
  marty:
    model: sonnet
    effort: medium
    rationale: "Keep validator rules declarative and messages consistent; no duplication with picks helpers."
  perri:
    model: opus
    effort: high
    rationale: "Prompt-injection boundary and digest-equals-model-input guarantee; a miss here breaks the privacy promise."
```

---

## Job H6: Focus surface on the daemon side: panes, document kind, actions, MCP tools, persona

**Goal:** the Huey focus has a daemon-seeded layout whose Report and Context panes paint with no agent turn. The setup step, history, regeneration and verdicts work through operator-only document actions. The focus session has its persona and drill-in tools.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h6-surface`
- **Base:** `origin/main`
- **Depends on:** H4. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts. Runs in parallel with H5.

### Files to change
- `src/ipc/protocol.rs`:
  - `PaneContentWire::Document` plus `DocBanner` and `DocAction` (A10);
  - `ClientMsg::PaneAction` and `ServerMsg::PaneActionResult`;
  - serde tests: round trip; old JSON without the optional fields decodes; a pinned wire form for one document.
- `src/ipc/server.rs`: handle `PaneAction` like `ClaudeLoginAction` (operator nonce, `PeerTrust::OperatorApp` only, refusal with no content otherwise). Route to `HueyHandle::on_action` when the pane is bound to a `huey.*` source; reply `unknown_action` otherwise.
- `src/mcp/views/tree.rs`: `default_huey_tree()` (A10) and its arm in `default_native_tree` (`:288-295`). The panes are daemon-bound, not Mac-native, so `native_pane_for` is unchanged.
- `src/bin/nostromd.rs` / `src/huey/mod.rs`: when Huey is enabled, seed the `huey` focus tree and bind `report` → `huey.report`, `context` → `huey.context` if the persisted tree lacks them. Never override a user-modified tree that still contains both panes.
- `src/mcp/tools/apply_layout.rs`:
  - `SOURCE_HUEY_REPORT`, `SOURCE_HUEY_CONTEXT` in `KNOWN_SOURCES` (`:186-198`), and `source_content_kind` → `"document"` (`:218-228`);
  - fetch arms calling `HueyHandle` (current, or `params {date, version}`);
  - the `layout_schema` content-kind list accepts `document`.
- `src/mcp/pane_sources.rs`: a `select!` arm in `run_pane_source_broadcaster` (`:263+`) on `huey_rx.changed()` that pushes both Huey sources. It takes a parked receiver when disabled, so the task never exits early.
- `src/huey/render.rs` (extend):
  - setup documents: pre-scan (D6, the sources list plus a **Set up Huey on this machine** action); post-scan (sources, projects with "how it runs" lines, interests status, actions `setup.open_interests`, `setup.import_interests` when importable, `setup.rescan`, `setup.confirm`, `setup.confirm_run_now`);
  - report documents with `report.prev/next/today/version:<n>` and `report.regenerate` actions;
  - per-pick verdict links (`nostromo-action:verdict:…`), with the chosen verdict in bold;
  - the context document (the digest as blocks).
- `src/huey/setup.rs` (extend): `confirm` refuses (with a plain-English `PaneActionResult.message`) when the interests file is missing or has no "What I care about" bullet, and writes `sources.toml` defaults on first confirm (AC2).
- `src/mcp/tools/huey.rs` (extend):
  - `huey.get_report({date?, version?})`: structured picks with item ids, links, project, check text, and fenced untrusted text;
  - `huey.get_context({date?, version?})`: the `digest.md` bytes;
  - `huey.list_reports()`: dates, versions, outcomes, verdict counts;
  - `huey.get_item({item_id})`: the pool record, fenced;
  - `huey.show({date?, version?, pane?: "report"|"compare"})`: rebinds, or creates a `compare` pane beside `report` for side-by-side reading;
  - `huey.regenerate()`: starts a regenerate run; at most one at a time; 2-minute cooldown after the last run;
  - `huey.record_verdict({date?, version?, pick, verdict, note?})`;
  - `huey.trial_summary({days: 14})`: counts per verdict and the share "useful or interesting" vs "hype or wrong project".
- `src/huey/prompts/persona.md` and `src/ipc/session_manager/mod.rs` (`build_claude_args_with` `:3222-3307`): for the bare agent name `huey`, `--append-system-prompt <persona>` and no `--agent`. Unit test in the existing args tests (`:3560+`).
- `src/mcp/tools/mod.rs` (`:565-576`) and `src/ipc/peer.rs`: D9 network withholding (`huey.` prefix, `huey` view, `huey` tag sensitive).
- `docs/mcp/tools.md`, `docs/mcp/panes.md`: document the `huey.*` tools, the `document` kind, `PaneAction`, and the Huey view.
- `tests/huey_mcp.rs`: tools, sources, actions, replay.

### Approach
1. Protocol types, then the server action route (operator-only), then the tree seed and source binding, then the broadcaster arm, then the documents, then the MCP tools, then the persona, then network withholding.
2. Regeneration reuses today's pool (A2). It writes `v<n+1>`, replaces today's ledger entries, and keeps every version readable.

### Acceptance criteria
- [ ] **H6-1** Not set up, pre-scan: the `report` pane's document says Huey has read nothing, lists the context sources (from config, with no file reads, asserted with a read-counting fake root), and offers **Set up Huey on this machine**. After `setup.start`, it lists sources, projects with "how it runs" lines and the interests status. (AC1 surface, D6)
- [ ] **H6-2** `setup.confirm` without an interests file is refused with a reason and nothing is produced. `setup.open_interests` writes the draft (four sections) and replies with a `file:` `open_url` under the Huey root. After confirm, `sources.toml` exists with the defaults. `setup.confirm_run_now` starts a run. With a fixture `HOME`, nothing in the whole setup flow writes under `$HOME/.claude`. (AC2)
- [ ] **H6-3** A `PaneAction` from a non-operator peer is refused with no content and has no effect. There is no MCP tool that confirms setup (assert the tool list). (T11)
- [ ] **H6-4** On attach, the replay sends the cached report document for the `huey` focus with no run triggered and no `Loading` frame. (AC3 daemon side)
- [ ] **H6-5** `huey.regenerate` with the scripted curator produces `v2` within the test deadline; `v1` and `v2` are both readable through `get_report` and `report.version:<n>`, each labelled with its generation time. Regeneration timeouts are bounded so that a real run finishes within 5 minutes (fetch skipped, model at most 4 minutes; T13). (AC28)
- [ ] **H6-6** `report.prev`/`next` and `huey.show({date})` show a past report with its date in the title. `list_reports` lists 30 days of fixture reports. (AC29, AC31)
- [ ] **H6-7** `huey.get_report` returns pick N's item ids, links, project, anchors and check, and `huey.get_item` returns the stored item text, fenced, so the session can answer "tell me more about N" without the user pasting anything. (AC30 tool side)
- [ ] **H6-8** A verdict action and `huey.record_verdict` persist into `reports/<date>/verdicts.json`; the re-rendered document shows the chosen verdict; `trial_summary` counts them. (AC39 mechanism)
- [ ] **H6-9** With Huey disabled: `huey.*` tools are absent and refuse; `refresh_pane_content` and `apply_layout` with `huey.report` give `unknown_source`; persisted Huey bindings are neither repainted nor replayed. With Huey re-enabled on the same state root, the same reports, setup state and interests file are shown. (AC36, AC38)
- [ ] **H6-10** The spawn args for agent `huey` contain `--append-system-prompt` with the persona and no `--agent`. Other agents are unchanged. (A10)
- [ ] **H6-11** Network-peer withholding covers `huey.*` tools and the `huey` view (D9). The existing withholding tests stay green.
- [ ] **H6-12** Protocol: `Document` with optional fields omitted serialises without them; old clients' `unknown` path is unaffected; `PROTOCOL_VERSION` stays 4. Fmt, clippy and test pass in the sandbox.

### Must not touch
Swift (H7). The validator and prompt (H5). Fetch and context internals. `tool_policy.rs`.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Wire additions, operator-only action routing, daemon-seeded layout and nine MCP tools across known patterns."
  redd:
    model: sonnet
    effort: high
    rationale: "Action trust, replay without generation, regenerate versions and disabled/re-enabled behaviour need precise tests."
  marty:
    model: sonnet
    effort: medium
    rationale: "Keep huey.rs tools thin over HueyHandle; documents rendered in one place."
  perri:
    model: opus
    effort: high
    rationale: "New client->daemon action surface and wire compatibility; trust-tier mistakes are security bugs."
```

---

## Job H7: The Mac app: Huey focus, document renderer, actions

**Goal:** the Huey focus appears in the sidebar when the daemon runs Huey, renders the Report and Context documents instantly from replayed content, and sends actions and verdicts.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h7-mac`
- **Base:** `origin/main`
- **Depends on:** H6. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts.

### Files to change
- `Shared/NostromoKit/Sources/NostromoKit/Wire/EnabledAgents.swift:7`: `switchable` gains `"huey"`. A welcome from an older daemon, whose list lacks huey, then correctly reads Huey as disabled.
- `Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift:757+`: `PaneContentWire.document(title, banner, blocks, actions)` decode. iOS renders nothing new and decodes only, so it stays compiling.
- `macOS/Nostromo/Data/Models.swift`:
  - `:116-135`: **append** `Focus(id: "huey", agentTag: "huey", projectPath: nil, isBuiltIn: true, org: "Personal")` at the end of `builtIns`, so no index shifts;
  - `:1890+`: the `PaneContentWire.document` case and decode.
- `macOS/Nostromo/UI/SidenavGrouping.swift:183`: `builtInOrder` gains `"huey"`. Check `:103` and `NavTabItem.swift:231`: Huey has no badge in v1.
- `macOS/Nostromo/UI/DocumentBlockDocument.swift` (new; register it in `project.pbxproj` by copying `TicketBlockDocument.swift`'s entries): title plus blocks to an attributed string, reusing `MarkdownBlockDocument`'s block rendering with no threads. `nostromo-action:` link ranges are mapped to action ids.
- `macOS/Nostromo/UI/Views/DocumentContentView.swift` (new; register it the same way): the AppKit sibling layered like `TicketContentView`, with:
  - a banner strip (warning style for not-today reports);
  - the text view;
  - a button row for `actions`;
  - link clicks: `https:` opens in the browser, `nostromo-action:` sends the action, anything else is ignored.
- `macOS/Nostromo/UI/Views/PaneContentView.swift:91-128` and `DynamicFocusView.swift` (leaf mapping near `:419`): route `.document` to `DocumentContentView`, the same way `.ticket` is routed.
- `macOS/Nostromo/Data/NostromodClient.swift`: `sendPaneAction(tag:paneId:actionId:)` with the operator nonce, as `sendClaudeLoginAction` (`:982`) does. Decode `pane_action_result`: show `message` as a toast, and open `open_url` only if it is `https:` or a `file:` URL inside `~/.nostromo/huey/`.
- Tests, in existing files:
  - `Shared/NostromoKit/Tests/NostromoKitTests/EnabledAgentsTests.swift` (huey switchable);
  - `macOS/NostromoTests/NostromodClientHandshakeTests.swift` (welcome with and without `huey`);
  - `macOS/NostromoTests/PerFocusEvictionWiringTests.swift` (Huey present by default, hidden and evicted when disabled, restored at the end);
  - `macOS/NostromoTests/SidenavGroupingTests.swift` (a Huey row under Personal);
  - `macOS/NostromoTests/PaneContentWireEqualityTests.swift` (document decode and equality);
  - `macOS/NostromoTests/TicketBlockDocumentTests.swift` or `MarkdownBlockDocumentTests.swift` (document rendering, action link ranges, unknown schemes ignored);
  - `macOS/NostromoTests/PaneFirstPaintAuditTests.swift` (a replayed document paints with no loading state).

### Approach
1. Kit decode, then app models, then focus list and sidebar, then the renderer, then actions, then tests.
2. Do not add a native Huey surface. All Huey UI is the generic document kind, so iOS can render it later with no Huey-specific code.

### Acceptance criteria
- [ ] **H7-1** With a welcome that lists `huey`, the sidebar shows a Huey focus under Personal. With a welcome that omits it, the focus is hidden, an active Huey focus falls back to Mother, and its state is evicted through `focusRemovals`. (AC35, AC36 app side)
- [ ] **H7-2** A replayed `document` frame renders on first paint with no loading placeholder (AC3 app side). The title shows the date, and a banner renders when present (AC31).
- [ ] **H7-3** Clicking an action button or a `nostromo-action:` link sends `pane_action` with the right tag, pane and action id. `https:` links open in the browser. `javascript:`, `file:` and other link schemes do nothing.
- [ ] **H7-4** `pane_action_result.open_url` outside the allowed set is not opened.
- [ ] **H7-5** `make kit-test`, `make mac` and `make mac-test` pass (or `make ci-remote ONLY=swift`). The iOS target still compiles (`make ci-remote ONLY=ios` if available; say so in the PR if not).

### Must not touch
Rust. iOS UI beyond compiling. Badge providers. `NostromodClient.baseTopics`.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New AppKit renderer layered like the ticket view, wire decode in two enums, action sending with operator nonce."
  redd:
    model: sonnet
    effort: medium
    rationale: "Extend existing Swift test files for decode, focus filtering, link handling and first paint."
  marty:
    model: sonnet
    effort: medium
    rationale: "Share block rendering with MarkdownBlockDocument instead of copying it."
  perri:
    model: sonnet
    effort: high
    rationale: "Link-scheme and open_url allowlists are the client-side safety rails."
```

---

## Job H8: Real-model eval harness and docs

**Goal:** a repeatable, opt-in way to check the model-judgement criteria against the PRD's fixture scenarios using the real model on Sendai, plus the user docs.
### Target
- **Repo:** nostromo (`github.com/thehammer/nostromo`)
- **Branch:** `feat/huey-h8-eval`
- **Base:** `origin/main`
- **Depends on:** H5, H7. Mother holds this job (`--depends-on`) until the PR of each job listed has merged, so `origin/main` already contains their code when this job starts.

### Files to change
- `src/bin/nostromo_huey_eval.rs` (new `[[bin]]` in `Cargo.toml`): `nostromo-huey-eval --scenarios tests/fixtures/huey/eval [--only NAME] [--model M]`. It runs the real pipeline (`SessionCurator` through a real `SessionManager` and the real `claude`) on each scenario's frozen pool and context in a temp state root, and prints PASS or FAIL per assertion. **Never run in CI.** Each scenario costs one model run, so the README states the expected cost.
- `tests/fixtures/huey/eval/<scenario>/` (public-safe), each with a `pool.json`, a context fixture, `interests.md`, `posture.json` and `expect.toml` (assertions over `report.json`):
  - `sdk-not-used` (AC14);
  - `sdk-used` (AC15);
  - `three-unconfirmable` (AC16);
  - `general-essay` (AC17);
  - `want-less-and-ignore` (AC18, AC26);
  - `nothing-relates` (AC9, AC13);
  - `api-version-vs-bugfix` (AC44);
  - `breaking-sdk-no-interest` (AC42);
  - `follow-up-release` (AC11, "says what is new");
  - `php-two-machines` (AC34; runs twice with the machine-a and machine-b contexts);
  - `typical-day` (AC8, word counts and shape);
  - `minor-fixes-only-week` (AC45: only bug-fix changelog entries in the week; expect no Also-in-the-news line, a skip reason in the footer, and no minor fix shown in the line);
  - `simulation-2026-10-25` (a sanitised copy of run 2's pool: expect the `decider: "person"` and retry-watchdog items as picks and the 2026-10-21 API version not a pick).
- `docs/huey.md` (new): what Huey is; setup (D6 flow); the interests file format; `sources.toml`; budget modes (the D1 mapping); privacy (per-machine, digest-only for unattended runs, D7, `~/.claude` sync caution); the trial and verdicts; turning it off.
- `README.md`: one line for Huey in `### Agents`, linking to `docs/huey.md`.

### Acceptance criteria
- [ ] **H8-1** `nostromo-huey-eval --only sdk-not-used` runs end to end on a machine with `claude` installed and reports per-assertion results. `cargo test` never invokes it (a unit test asserts the bin is not referenced by tests).
- [ ] **H8-2** Every scenario listed exists with an `expect.toml`, and its fixtures contain no private or work data.
- [ ] **H8-3** `docs/huey.md` covers setup, interests, sources, budget mapping, privacy and switching off, and the README links to it.
- [ ] **H8-4** The PR body includes one real eval run's output from Sendai, if the worker can run `claude`. Otherwise it says the eval must be run by hand, with the exact command.

### Must not touch
Runtime behaviour. Any change the eval suggests to prompts or rules is a follow-up job.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "A thin runner over existing pipeline seams plus fixtures and docs."
  redd:
    model: sonnet
    effort: low
    rationale: "downgrade: one guard test; the scenarios themselves are the tests and need the real model."
  marty:
    skip: true
    rationale: "Small runner and docs; nothing to refactor."
  perri:
    model: sonnet
    effort: medium
    rationale: "Check fixtures are public-safe and the eval cannot run in CI."
```

---

## Traceability: every PRD criterion → job → test

Test types:
- **U**: Rust test in CI (sandbox).
- **S**: Swift test in CI.
- **E**: real-model eval scenario (H8; run by hand on Sendai).
- **T**: the two-week trial (human).
- **M**: manual check on Sendai after H7 merges (see "Verification on Sendai").

| AC | What | Job(s) | Test(s) |
|---|---|---|---|
| 1 | Not set up: focus shows "read nothing", the sources it would read and the **Set up Huey on this machine** button, with zero context reads or writes on open; only after the click: sources read, draft interests (four sections), "how it runs" lines; no fetch, model call or report before confirm (with and without the click) | H1, H3, H4, H6, H7 | U `H1-5`, `H4-1` (`tests/huey_run.rs::not_set_up_does_nothing_past_run_time`, before and after the click), `H6-1` (read-counting root), `H3-8`; S `H7-2`; M |
| 2 | Draft interests written when missing; no report until confirmed with the file; all Huey files in Nostromo's folder, never under `~/.claude` | H3, H6 | U `H3-8` (`tests/huey_context.rs::draft_has_four_sections`, no writes under `$HOME/.claude`), `H6-2` (`tests/huey_mcp.rs::confirm_refused_without_interests`, whole setup flow writes nothing under `$HOME/.claude`); T6 |
| 3 | Report by 06:30; opens in under 1 s with no generation visible | H4, H6, H7 | U `H4-2`, `H6-4` (replay with no run); S `H7-2`, `PaneFirstPaintAuditTests`; M (time the open) |
| 4 | Window since the previous successful curated report; 3-day catch-up; a no-model headline report does not move the window (critical day then normal day: the normal report covers both) | H2, H4 | U `H2-3`, `H4-3` |
| 5 | Undated first run is baseline; later additions eligible | H2 | U `H2-1` |
| 6 | At most 5 picks, 1 Also-in-the-news line, 5 Also noted, in order; 200 items still at most 5 picks | H4, H5 | U `H5-3`, `H5-4`; render order in `H4` render tests |
| 7 | Pick fields; first link is the original | H5 | U `H5-3`, `H5-5` |
| 8 | At most 600 words counting the whole report, footer included; Also-in-the-news line at most 40; footer at most 100 on every report | H4, H5 | U `H5-3` (word rules), `H4-5`, `H4-14` (footer cap); E `typical-day` |
| 9 | Nothing relates → "nothing touches", no picks; body (opener, nothing-today line, Also in the news, Also noted) under 150 words; footer not counted but held to 100 | H4, H5 | U `H5-3` (quiet body cap, D2), `H4-5` (footer cap); E `nothing-relates` |
| 10 | Same story, several sources → one item plus "also covered by" | H2, H5 | U `H2-6`, `H5-3` (duplicate ids), `H5-5` |
| 11 | No repeat within 14 days unless materially new, saying what is new; appearing only in a no-model headline report does not count as featured | H4, H5 | U `H4-4` (uncurated entries do not block picks), `H5-3` (`follow_up_of` needs `whats_new`); E `follow-up-release` |
| 12 | Footer contents; no shown item listed as dropped; no item in two sections | H4, H5 | U `H4-5`, `H5-3` |
| 13 | "For" project is in the digest with a concrete part; no invented project | H3, H5 | U `H5-3` (project and anchor rules); E `nothing-relates` |
| 14 | Unused SDK breaking release is not a pick (Also in the news, Also noted or dropped) | H3, H5 | U `H3-6`, `H5-3` (`not_found` dependency check refused); E `sdk-not-used` |
| 15 | Used SDK release is a pick with a "Checked:" line | H3, H5 | U `H3-6`, `H5-3` (checked needs a check or fact); E `sdk-used` |
| 16 | At most one "To check" pick | H5 | U `H5-3`; E `three-unconfirmable` |
| 17 | Non-specific item never a pick | H5 | U `H5-3` (anchor required); E `general-essay` |
| 18 | Also noted tagged with a stated interest; never want-less or ignore | H3, H5 | U `H5-3` (interest-id rule), `H4-10` (hard ignore); E `want-less-and-ignore` |
| 19 | Every first-party entry since the last report eligible (oldest of 8 versions) | H2, H5 | U `H2-2`; U `H5-4`-style test where the fake model picks the oldest version's item and is accepted |
| 20 | Quiet source labelled quiet, never failed | H2, H4 | U `H2-4`, `H4-5` |
| 21 | One failing source does not sink the others; named as failed | H2, H4 | U `H2-5`, `H4-5` |
| 22 | Shown digest is exactly the model input | H3, H5, H6 | U `H5-1` (byte equality against the captured send), `H6-7`/`get_context` serves the same file |
| 23 | Digest per project: open items, "how it runs", posture (Bishop) | H3 | U `H3-1` |
| 24 | No raw file contents in the model input | H3, H5 | U `H3-2`, `H5-2` (canaries) |
| 25 | "How it runs" correction replaces Huey's line next time | H3 | U `H3-3` |
| 26 | "Ignore entirely" never in the in-flight list, picks or Also noted | H3, H4, H5 | U `H3-4`, `H4-10`, `H5-3` (`ignored` ids); E `want-less-and-ignore` |
| 27 | Interests edits visible and change the next report; nothing stored out of sight | H3, H4, H6 | U `tests/huey_run.rs::interest_edit_changes_next_model_input`; U `tests/huey_run.rs::no_preference_state_outside_interests` (enumerates every file the engine writes; none but `interests.md` holds preferences); persona tells the session to edit the file (H6) |
| 28 | Regenerate gives a new version within 5 min; both readable and labelled | H4, H6 | U `H6-5`; T13 timeouts; M |
| 29 | Previous reports available by date for at least 30 days | H4, H6 | U `H4-11`, `H6-6` |
| 30 | "Tell me more about N" with no pasting | H6 | U `H6-7` (tool side); M (ask the session on Sendai) |
| 31 | A failed model run is retried once after 10 minutes (fail then succeed: report exists, not labelled missing); otherwise the latest report is shown with its date and a reason (asleep, fetch failed, model failed); budget is never a reason; never undated | H4, H5, H6, H7 | U `H4-9`, `H5-12` (fail then succeed), `H5-8` (retry fails), `H6-6`; S `H7-2` |
| 32 | Tight: at most 3 picks, no Also noted, says shortened; Also-in-the-news line kept | H4, H5 | U `H4-6`, `H4-13` (D1 mapping incl. metered), `H5-3`, `H5-9` |
| 33 | Critical: no model; uncurated first-party list of at most 20 lines plus "and N more" (35 items → 20 and "and 15 more"), plus the rule-based Also-in-the-news line unless already listed | H4 | U `H4-7` |
| 34 | Sendai and Kobe never cross-mention; PHP worked example | H3, H4 | U `H3-5`, `H4-10`; E `php-two-machines` |
| 35 | No table → Huey on, listed in the welcome, focus appears with the not-set-up state and the setup button; in v1 the focus and its panes are not offered to network clients | H1, H6, H7 | U `H1-1`, `H6-1`, `H6-11` (network withholding); S `H7-1` |
| 36 | Disabled → absent from the welcome; no focus; tools refused; sources neither fetched nor replayed; no run | H1, H4, H6, H7 | U `H1-2`, `H1-5`, `H4-12`, `H6-9`; S `H7-1` |
| 37 | Malformed table → daemon runs, warns with keys only, Huey stays on | H1 | U `H1-3` |
| 38 | Re-enable → same reports, setup state and interests | H1, H6 | U `H6-9` (re-enable half) |
| 39 | Two-week bar: at least half useful or interesting, at most one in ten hype or wrong project, judged by verdicts kept with reports | H6, H7, H8 | U `H6-8` (verdict storage and `trial_summary`); S `H7-3` (verdict links); **T** (Hammer's verdicts over 14 days); E scenarios as a regression floor |
| 40 | Also-in-the-news line labelled not tied to work; no For or Check lines; no digest project named | H4, H5 | U render test (the line's struct has no For or Check fields), `H5-3` (project-name rule) |
| 41 | Also-in-the-news line from first-party only; aggregator-only story never chosen | H4 | U `H4-8` |
| 42 | Shown even when it touches nothing and matches no interest; ignored items never | H4, H5 | U `H4-8` (ignore excluded), scripted-model test accepting an unrelated breaking-SDK item; E `breaking-sdk-no-interest` |
| 43 | Not a pick, not shown in any section of a report in 14 days (no-model headline reports included); never both the line and Also noted | H4, H5 | U `H4-8` (uncurated entries block the line), `H5-3` (move-up rule) |
| 44 | Most significant with a model; rule under critical | H4, H5 | U `H4-7` (rule order); E `api-version-vs-bugfix` |
| 45 | Nothing eligible → line omitted, nothing in its place; with a model, may also be omitted when every candidate is a minor fix, with the reason in the footer and no minor fix shown | H4, H5 | U `H4-8` (quiet week), `H4-14` (skip reason in footer), `H5-3` (skip needs `ain_skip_reason`); E `minor-fixes-only-week` |

## Technical acceptance criteria (Archie's)

- **T1. Fetch limits.** GET only. 30 s per source; 8 MiB body cap; 90 s for the whole fetch. Fixed User-Agent. Conditional GET where supported. At most 10 article fetches per run for the news index. (H2)
- **T2. Source guard.** A unit test asserts that the `src/huey/sources/` code has no non-GET HTTP verbs. (H2)
- **T3. Hidden-session boxing.** `huey-run` gets exactly `huey.check_project`, `huey.publish_report` and `ToolSearch`. This is enforced by both the `claude` flags and daemon dispatch. It runs:
  - with no permission bypass;
  - with `--setting-sources project --disable-slash-commands --strict-mcp-config`;
  - in an empty temp cwd;
  - with `--max-budget-usd` per mode and a 4-minute timeout;
  - with its process group killed at the end and its transcript deleted. (H5)
- **T4. Untrusted text.** News text reaches the model only inside the existing untrusted fences. Report links come only from item records; the model cannot supply a URL. Text the model writes is length-capped and stripped of control and bidi characters (reuse `one_line`). (H5)
- **T5. Logs.** Counts, ids, states and HTTP status codes only. Never digest text, interests, note or idea titles, or news text. Reviewers grep `src/huey` for `info!|warn!|debug!|error!` arguments. (all jobs)
- **T6. No trace when off or not set up.** A disabled Huey, or one never set up and never scanned, creates nothing under the state root. Huey never writes under `~/.claude`. (H1, H4)
- **T7. One run at a time.** A second trigger during a run returns "already running". Regenerate has a 2-minute cooldown after any run. (H4, H6)
- **T8. Capture before send.** `model-input.txt` is fsynced before the first byte goes to the session. Every check result is appended before it is returned to the model. (H5)
- **T9. Deterministic digest.** Identical inputs give byte-identical `digest.md`. Size cap 16 KiB with "+N more". (H3)
- **T10. Wire compatibility.** `Document`, `PaneAction` and `PaneActionResult` are additive. `PROTOCOL_VERSION` stays 4. Older clients decode `document` as unknown. A new app only sends `pane_action` for document panes, which only a new daemon creates. (H6, H7)
- **T11. Operator-only actions.** `PaneAction` is accepted only from `PeerTrust::OperatorApp` with a valid operator nonce. Setup confirmation has no MCP path. (H6)
- **T12. Read-only probes.** `git` runs with fixed argv (`rev-parse`, `log`, `grep -F -l -I`) and a 5 s timeout, never through a shell. Probes return no line contents. The profile cache is keyed by HEAD sha. (H3)
- **T13. Regeneration within the 5-minute promise.** Regeneration reuses today's pool (no fetch unless today's fetch failed). Model timeout 4 minutes, at most 3 publish attempts inside it. (H5, H6)

## Risks

- **Hype drift (the product-killing risk).** Mitigations:
  - the validator makes the cheap kinds of hype impossible: no anchor, no project, a "checked" with nothing checked, two To-checks;
  - the eval scenarios catch regressions;
  - the verdicts measure the rest.

  If the trial misses the bar, the first lever is the prompt plus the digest's "how it runs" facts, not more sources.
- **Digest too thin to check against.** The simulation's "check whether" picks came from not knowing how a project is wired. The profiler covers SDKs, `claude` invocation, Claude Code features and `CLAUDE_CODE_*` names. If To-check picks are common in week one, add probe kinds (an H3 follow-up), and keep checks in the daemon, not in raw files.
- **`~/.claude` sync crosses machines** (D5). Huey's own state is kept off it, but ideas, todos and notes in `~/.claude` can sync through a public GitHub repo, so a work idea written on the work laptop could reach Sendai's digest before any Kobe instance exists. v1 mitigation (PRD): setup marks those sources as synced from other machines, the digest shows exactly what was used, and "Ignore entirely" removes anything that slips through. The user is deciding whether more is needed; Kobe must not ship until a per-machine rule exists.
- **Source format drift.** Anthropic news is scraped HTML, and the changelog depends on npm publish times. Every adapter fails loudly (failed in the footer) rather than silently. One failing source never sinks the report, and every adapter has a fixture to update.
- **Budget competition.** Full first-party reads cost real usage even on Sonnet, and switching `model` to Opus raises it. Today's posture (and metered billing) already map to tight. D1 and D8 are the dials, and `runs.jsonl` records mode and duration, so the trial can show the cost.
- **CLI behaviour changes.** Huey depends on `claude` flags (`--append-system-prompt`, `--max-budget-usd`, `--tools`, `--allowedTools`, `--setting-sources`) that picks already relies on, so a breaking CLI change breaks picks too and is noticed. H5's spawn-args test pins them.
- **Prompt injection through news.** Mitigations:
  - the tool allow-list (two Huey tools);
  - daemon-owned links and rendering;
  - fenced text;
  - the validator.

  The worst case is a misleading sentence in the report, not an action.
- **Schedule edge cases** (DST, a sleeping Mac). The wall-clock tick plus the catch-up path cover them, and a late report says why.
- **Swift project file edits** (two new source files). Copy sibling entries exactly. `make mac` catches mistakes.

## Verification on Sendai (after H7 merges; manual, M in the table)

1. Restart `nostromd` and relaunch the app. A Huey focus appears under Personal, showing "not set up, has read nothing".
2. Click **Set up Huey on this machine**. Check the sources list, the projects (deduplicated; the `maisie-feat-*` worktrees collapse into one), the "how it runs" lines and the import offer for `~/.claude/huey/interests.md`. Import or edit it, then **Confirm and run now**. A report appears within about 5 minutes.
3. Open the Context tab: the digest and "Checks Huey ran" are there. Ask the session "tell me more about 1" and "regenerate today's report". Compare v1 and v2 with ◀ and ▶.
4. Leave verdicts on each pick for 14 days. `huey.trial_summary` gives the AC39 numbers.
5. Set `[agents.huey] enabled = false` and restart. The focus is gone and nothing runs at 06:00 (check `runs.jsonl`). Re-enable: the history is intact.
