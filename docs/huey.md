# Huey

Huey is a built-in Nostromo agent, alongside Fred, Perri and Teri. Every morning it writes one short report for one reader, about that reader's own work. The report has:

- a few **picks**: news items that affect a project you have in flight. Each says how the project is affected and what Huey checked;
- one first-party **Also in the news** line, not tied to any project;
- up to five **Also noted** lines, tagged with an interest of yours;
- a **footer** that says what Huey read, what was quiet, what failed and what it dropped.

A quiet day says "Nothing that touches your work today." and stays short.

Huey is on by default. Each machine has its own Huey with its own state and its own interests. It currently runs on one machine, and nothing carries across to another.

## Setup (once per machine)

Until you set Huey up, the Huey focus shows **"Huey is not set up on this machine. It has read nothing."** and lists the context sources it *would* read. That list comes from configuration; nothing is read to build it. Press **Set up Huey on this machine** to continue.

1. **Scan.** Huey reads your context sources in memory (see [Privacy](#privacy)) and drafts an interests file. Nothing is written to disk until you act on the draft.
2. **Review.** The setup page shows the sources, the projects Huey found (git repositories under your code root, with worktrees of one repository collapsed into one project), a one-line "how it runs" for each, and an offer to import an interests file from `~/.claude/huey/interests.md` if one exists. `~/.claude` ideas, todos and notes are marked "may be synced from other machines".
3. **Edit** the draft with **Open interests file**.
4. **Confirm**, or **Confirm and run now**. Confirming writes `sources.toml` and `setup.json`. It can only be done with a click in the Mac app; there is no tool an agent could use to confirm for you.

The first report appears within about five minutes of **Confirm and run now**.

## Files

Everything lives under `~/.nostromo/huey/`, never under `~/.claude` (which can be synced between machines):

| Path | What |
|---|---|
| `setup.json` | setup state |
| `interests.md` | your preferences. The only store of them |
| `sources.toml` | news sources and context switches, re-read on every run |
| `reports/<date>/v<n>/` | each report version: `report.md`, `report.json`, `digest.md` (exactly what the model was sent, plus the checks it ran), `model-input.txt`, `checks.json`, `meta.json` |
| `reports/<date>/verdicts.json` | your verdicts |
| `state/`, `pool/` | per-source state, the 14-day ledger, the run log (`runs.jsonl`), frozen news pools |

Reports and verdicts are kept for 60 days.

## The interests file

`~/.nostromo/huey/interests.md`. Sections are found by heading text (case-insensitive). Anything else in the file is kept and shown, and is never fatal.

```markdown
# Huey interests (Sendai)
## What I care about, and why
- **Agent harnesses that put the human first** (...). Why: ...
## Want more of
- Concrete changelog items I could adopt or delete a workaround for.
## Want less of
- Model benchmark and leaderboard news.
## Ignore entirely
- PHP and Laravel news (`PHP`, `Laravel`)
## How it runs
- **mother**: workers run `claude -p` non-interactively and set CLAUDE_CODE_RETRY_WATCHDOG
```

- **What I care about** and **Want more of** are the interests an Also-noted line can cite.
- **Want less of** is never shown as a pick or an Also-noted line.
- **Ignore entirely**: backticked terms are hard filters. A news item whose title has one is dropped before the model sees it (the footer says `ignored: <term>`). Project names listed here are removed from the context, along with every context line that matches a term.
- **How it runs** replaces Huey's own deterministic line for a project (the digest marks it `(your correction)`). Use it when Huey's profile of a project is wrong.

Edits apply from the next report. You can also ask the Huey session to edit the file for you.

## Sources (`sources.toml`)

News sources and context switches are listed in `~/.nostromo/huey/sources.toml`. It is re-read on every run: add or remove a source with no code change and no restart. Defaults:

| id | what | class |
|---|---|---|
| `claude-code-changelog` | Claude Code changelog, one item per version, read in full, dated from npm publish times | first-party |
| `claude-docs-release-notes` | Claude docs release notes, one item per bullet | first-party |
| `anthropic-news` | Anthropic news index; new articles are fetched for title and description | first-party |
| `mcp-spec-releases` | Model Context Protocol spec releases | first-party |
| `agent-sdk-python`, `agent-sdk-typescript` | Claude Agent SDK releases | first-party |
| `simon-willison`, `latent-space` | feeds | curated |
| `hn-front-page` | Hacker News top 30 (`enabled = false` by default) | aggregator |

Fetching is plain code, with no model: GET only, 30 s and 8 MiB per source, a fixed User-Agent, conditional requests where the server supports them. A source that answered with nothing new is **quiet**. A timeout, a bad status or an unparseable body is **failed**, and is named in the footer. One failing source never sinks the report.

The `[context]` table switches each context source on or off: `code_root`, `tracker`, `prs`, `git`, `mother`, `bishop`, `ideas`, `todos`, `notes`, `interests`.

## Schedule and config

Huey starts `lead_minutes` before `report_time` (default 06:00 for a 06:30 report), every day, in the daemon's local time. A machine that was asleep catches up when it wakes, and the report says why it was late. A failed curated run is retried once, 10 minutes later. Only then does the focus show "model failed".

```toml
[agents.huey]
enabled = true            # false switches Huey off on this machine (restart nostromd)
report_time = "06:30"     # ready-by, local time
lead_minutes = 30
model = "sonnet"          # normal mode; "opus" is allowed
tight_model = "sonnet"
max_budget_usd = 3.0
tight_max_budget_usd = 1.0
```

Every key is optional. Unknown keys and bad values produce a warning in the daemon log that names the key, never the value.

## Budget modes

Huey follows Bishop's posture file, `~/.claude/budget-posture.json`, and maps it to three modes:

| Mode | When | What you get |
|---|---|---|
| **critical** | posture is `critical`, or the 7-day window is 98% used or more, or the model Huey would use is exhausted | no model runs: an uncurated list of up to 20 first-party headlines, plus the Also-in-the-news line chosen by rule |
| **tight** | `Pump the brakes`, `conservative` or `elevated`; or the 7-day window is 90% used or more; or the posture input is stale or the file is over 24 h old; **or billing is `metered`** | at most 3 picks, no Also noted, "Short report: budget is tight today.", Also in the news kept. `tight_model`, capped at `tight_max_budget_usd` |
| **normal** | everything else, including a missing file (the footer says "budget posture unavailable") | the full report. `model`, capped at `max_budget_usd` |

While billing is metered, Huey never runs in normal mode. An uncurated critical report does not advance the news window, so the next curated report covers everything since the last curated one.

## Privacy

- **Per machine.** Everything is rooted at the daemon's state root. Two machines never share Huey state. Before setup is confirmed, Huey fetches nothing and reads nothing.
- **Nothing raw leaves the machine.** The unattended model call (the scheduled run and a regeneration) receives only the instructions, the visible context digest, the fenced news candidates and the results of checks it ran. The digest shown next to each report (the Context tab) is byte for byte what was sent, and `model-input.txt` records every byte Huey supplied. The Claude Code harness adds its own system prompt and tool schemas; they carry none of your context, because the call runs in an empty temporary directory with your user settings, hooks, plugins and skills not loaded.
- **Boxed model session.** The unattended session may call exactly two Huey tools: `check_project` and `publish_report`, under a spend cap and a four-minute timeout. A check is a closed set of read-only probes (a dependency in a manifest, a text term with only a count and file names, the profile's facts). It never returns line contents. Every check is shown in the digest under "Checks Huey ran". The model never writes URLs, counts or the footer; the daemon does, and refuses a publish that breaks its rules.
- **News is untrusted text.** It reaches the model fenced as data. The worst a hostile item can do is put a misleading sentence in the report; it cannot cause an action.
- **The interactive Huey session is an ordinary Claude Code session.** The digest-only rule binds the unattended pipeline. The focus session acts only on what you type, and may read project files when you ask ("go and check that To-check for me").
- **`~/.claude` sync caution.** Ideas, todos and notes in `~/.claude` are context sources (titles only). If you sync `~/.claude` between machines, titles from another machine can reach this machine's digest. You can see exactly what was used in the Context tab, and "Ignore entirely" removes anything that slips through. Set up a per-machine rule for ideas before running Huey on a second machine.
- **Not for the phone yet.** Huey is withheld from iOS and network peers in this version.
- No resident or patient data and no work context are read.

## The trial and verdicts

Each pick has verdict links: **Useful**, **Interesting**, **Meh**, **Hype**, **Wrong project**. Verdicts are stored with the report. The trial bar over 14 days is: at least half of verdicts useful or interesting, and at most one in ten hype or wrong project. Ask the Huey session for `huey.trial_summary` to see the numbers (`days` defaults to 14).

## Checking the model's judgement: the eval

`cargo test` cannot call a model, so the criteria that depend on judgement (no hype, Checked lines that were checked, the Also-in-the-news choice, word caps) have an opt-in eval that runs the real pipeline with the real `claude`:

```sh
cargo build --bins
target/debug/nostromo-huey-eval --scenarios tests/fixtures/huey/eval            # all scenarios
target/debug/nostromo-huey-eval --scenarios tests/fixtures/huey/eval --only sdk-not-used
target/debug/nostromo-huey-eval --scenarios tests/fixtures/huey/eval --model opus
```

Run it by hand on a machine where `claude` is installed and logged in. **Never run it in CI.** Each scenario is one model run on your Claude subscription (`php-two-machines` is two), capped at `max_budget_usd` per run (if `ANTHROPIC_API_KEY` is set in your environment the eval warns and the runs bill the API instead); expect the full set of 14 runs to use a real share of a day's usage, so run one scenario while iterating. `HUEY_EVAL_SHOW=1` also prints each report.

Each scenario directory under `tests/fixtures/huey/eval/` holds a frozen news pool (`pool.json`), a context to build the digest from (`context/`), `interests.md`, `posture.json` and `expect.toml`, which lists the assertions over the produced report. Huey's own state, code root and scratch files live in a temporary directory, so the eval never reads your Huey state or your code, and the fixtures are synthetic and public-safe. The spawned `claude` is not isolated from your account: it runs with your real environment and HOME (it has to read your login) (the same restrictions as a real Huey run still apply: your user settings, hooks, plugins and skills are not loaded, and it gets only Huey's two tools). The eval also overwrites `~/.nostromo/mcp-bridge.json` (as `nostromd` does), which a running daemon's later sessions would pick up: run it with the daemon stopped, or restart the daemon afterwards. It prints PASS or FAIL for each assertion and exits non-zero if any failed. A FAIL is a prompt or rule regression to investigate, not necessarily a code bug: the model's output varies, so re-run before concluding.

## Turning it off

```toml
[agents.huey]
enabled = false
```

Then restart `nostromd`. A disabled Huey starts no scheduler, fetches nothing, registers no tools and touches nothing under `~/.nostromo/huey/`. The focus disappears from the app. Re-enable it and the history is intact.
