# Mother quality gates and lens review (`.mother/crew.yml`)

Mother reads `.mother/crew.yml` from a job's **base ref** when the job is added, so a worker can't weaken its own gates. It then runs the declared gates on the job's pushed head commit and a lens review wave (adherence plus Perri lenses) on the same commit.

## What runs for nostromo

| Gate | Where | Runs when changed | Approx. cost | Blocking |
|---|---|---|---|---|
| `rust-clippy` | sandbox | `src/**`, Rust tests, `Cargo.*`, toolchain, `.rwx/**` | ~30 s (+ ~75 s sandbox start) | yes |
| `rust-test` | sandbox | same as clippy | ~3 min 18 s from a fresh sandbox | yes |
| `python-test` | any (host Mac) | `tests/**`, `scripts/**`, `bin/**`, `Makefile`, `*.py` | ~45 s | yes |
| `swift-ci` | host (`make ci-remote ONLY=swift`) | `macOS/**`, `iOS/**`, `Shared/**` | ~7.5 min | yes |
| `shellcheck` | host | `*.sh`, `bin/**`, `scripts/**` | seconds | yes |
| `actionlint` | host | `.github/workflows/**` | seconds | advisory |
| `mother-contract` | host | contract fixtures and Mother client code | seconds | advisory |

A Swift + Rust job costs about 14 minutes of gates before any retry, hence `gates.budget_minutes: 45`.

Lenses (`correctness`, `tests`, `ops-infra`, `phi-security`) run on every job; `ops-infra` and `phi-security` are scoped to the paths in the file. Lens names are a closed set in Mother: an unknown name makes `mother add` fail for every nostromo job. Lens spend is capped by `lenses.budget_usd` ($3 per job).

`run` never contains `rwx sandbox exec --`: Mother resets the sandbox, wraps `run` in `rwx sandbox exec -- bash -c`, and stops it.

## Observe vs enforce

Both `gates.mode` and `lenses.mode` are `observe`: results are recorded and shown in `mother status`/`list`, but never hold a job or mark a PR draft. Switch to `enforce` with a one-line PR once observe-mode gates agree with CI on at least 90% of at least 20 PRs over 2 weeks and the median gate run fits within `budget_minutes`.

## Running a gate yourself

```
mother gates run
```

Run it from the job worktree with HEAD pushed. Sandbox gates also need a clean tree and a pushed HEAD (built-in blocking pre-checks); a missing CLI or a timeout reports `unavailable`, never `passed`.

`swift-ci` needs a **pushed** branch because `make ci-remote` dispatches the GitHub workflow on the remote ref.

## Host prerequisites for `where: any` gates

- `gh` authenticated (`gh auth status`) for `make ci-remote`.
- `shellcheck` and `actionlint` installed (`brew install shellcheck actionlint`). `scripts/gates/*.sh` look on `PATH`, then `/opt/homebrew/bin`, then `/usr/local/bin`; if the tool is missing they print `... not installed` and exit 2.

## Coexistence with manual review (D8)

- **During observe** (first 2 weeks / 20 PRs): keep the manual `mother adherence-review` + Perri routine.
- **After that**: drop the manual adherence review; the wave's `archie:adherence` covers it.
- **Keep a manual Perri pass** for PRs touching `ReplView`, `ReplInputBar` or other transcript/scroll code (scroll-safety), and for target/disk/perf-sensitive changes. Phase 1 has no lenses for those.

## Per-job tuning

In the plan's yaml block next to `suggested_config`:

```yaml
gates: {max_attempts: 3}
lenses: {add: [tests], remove: [ops-infra]}
```

## Costs and limits to know

- `swift-ci` dispatches the whole macOS GitHub workflow for each gate attempt (up to two attempts), so it duplicates the PR's own CI run and uses Actions minutes. Its `timeout_s` is 1800, below the 45-minute `budget_minutes`, so a hung dispatch fails on its own instead of marking every gate `unavailable` through the total watchdog.
- `python-test` runs on the HOST Mac (`where: any`), not in the Linux sandbox: `tests/operator_pin` needs `codesign`/`lipo` and refuses to skip without them, so a sandbox gate fails every time (seen in the first live gate run on 2026-10-21, exit 2 after 81 s). Its `when` paths cover the trees the Python policy suites scan (`macOS/`, `iOS/`, `Shared/`, `.github/`, `src/mother/`). CI's Python job runs on macOS for the same reason.
- `shellcheck-changed.sh` cannot check a changed file whose name git prints quoted (non-ASCII, quotes, tabs): it says so on stderr and fails rather than passing silently.

## Vendored contract fixtures

The contract recordings in `tests/fixtures/mother-contract/` are pinned to Mother `6712f38ecb28` (see `MANIFEST.json`; refresh with `scripts/mother-contract.py vendor`). Mother #98 added `base_sha` (string or null) to the job record. It is an additive key: clients must ignore it if unknown, and Nostromo's Rust, Kit and Mac decoders do.

## Job detail: Overview · Plan · Log

The job detail in the Mother focus has a three-way switch under the title and state line.

- **Overview** is everything that used to sit above the log: the phase ribbon, crew panel, actions (with the reply box), todos, meta and the plan checklist. It scrolls on its own.
- **Plan** renders the job's plan in place. It is read-only and never widens the pane: prose wraps, and a wide table or code block scrolls sideways inside its own block.
- **Log** is the log tail, filling the area under the switch. A dot appears on its segment when new lines arrive while another segment is showing.

Which segment is showing is per detail, so per open job tab. A new job (and a job that needs you) opens on Overview; job updates never change it. The Plan segment exists only while the job has a plan path; if the path goes away while Plan is showing, the detail goes back to Overview.

### What the Plan view reads

The plan path is Mother's own copy of the plan. The loader follows links, then shows the file only if the resolved path is a regular file ending in `.md`, `.markdown` or `.mdown`, is at most 1 MiB (checked with `stat` before any byte is read) and is valid UTF-8. Anything else is one calm message in place of the body (not found, can't read, can't be shown here, not UTF-8) with a **Copy path** button, and never an alert. A link named `.md` that points at some other kind of file is "not a markdown file", and its bytes are never read; that message offers **Show in Finder** and **Copy path** only, because a path that is not markdown is never handed to the system to open. A file with no bytes, only white space, or only characters the sanitiser removes shows "Empty plan" with **Copy path**.

The view watches the file while it is showing and reloads when it changes (events coalesced over 300 ms, so an editor's save-by-rename is one reload). The reader's place holds across a reload: the topmost visible heading stays where it was, or the nearest heading before it if that one is gone. While the file is not there (it does not exist yet, or was deleted and has not come back) there is nothing to watch, so the loader looks again after 0.5 s, 1 s, 2 s, ... never more than 30 s apart, until it appears. Watchers and timers stop when the view leaves its window, is hidden behind another segment, or the job changes.

The Overview's plan checklist reads the same file the same way (same loader, same size and type rules, same `PlanChecklist` parser as the Plan header's `n/m criteria`) and watches it while the Overview is showing, so after an edit on disk the two agree as soon as the segment is shown (and within a debounce while it is). It does not reload when a job update arrives with the same path.

**Display limits.** A plan is shown in full up to 2,500 rows and 200,000 characters (a row is at most 60,000 characters; a code block or table at most 1,500 lines). Past that the plan ends in a "Plan truncated for display" row with **Copy path**; the header's Open and Finder still reach the whole file. Only the first 256 KiB of markdown (cut at a line break when that keeps at least half of it) is parsed, because Foundation's parser takes seconds on a table of 100,000 rows; the Overview checklist still counts the whole file. The limits exist because every row's height is worked out on the main thread at every width and rows are scanned on every scroll tick: they bound that work by the limits, not by the file (a 1 MiB file of one-line paragraphs would be hundreds of thousands of rows). The outline lists the headings that are shown.

### Safety

A plan's text is untrusted. Every span, the header's file name and the Overview checklist's text go through `FoldTextSanitizer`'s document rules: escape sequences, controls, bidi controls, zero-width space, word joiner and other invisible operators, the BOM, blank-looking filler characters, the soft hyphen (U+00AD), U+180E, variation selectors (U+FE00–FE0D and U+E0100–E01EF) and tag characters are all removed. Three characters are kept only where they do work: U+FE0E/FE0F straight after an emoji (or a keycap base), and ZWJ/ZWNJ (U+200D, U+200C) only between two characters that are both outside ASCII and are not joiners, which keeps emoji sequences and the scripts that need them (Persian, Indic) intact. A joiner next to ASCII, at either end, or beside another joiner is dropped, so it cannot hide inside a word, a path or a command. Code blocks keep `\n` and `\t`. Nesting deeper than 32 levels is flattened (never dropped text), so a file of a million `>` costs a bounded amount of stack. Images render as `[image: alt]`: the image URL is not kept anywhere in the model and nothing is fetched. Links open only on click: `http` and `https` in the browser, `file:` links for this machine (no host, or `localhost`) and relative paths are revealed in Finder (never opened), every other scheme, and a `file:` link for another host, is plain text. Nothing here logs plan text, a heading or a path. `MotherFocusFitnessTests` scans the plan files for logging calls, `tag` properties and network or process APIs.

The header's **Open ↗**, **Finder** and **⧉** (copy the path) are view actions, like the old "View Plan" button. The text of the plan is on screen and in the accessibility tree: it is also on disk, readable by the same user. Keeping plan text out of the accessibility tree is out of scope for this slice.

### Find

⌘F with the keyboard in the plan opens a find field in its header; Return or ⌘G finds the next match (case-insensitive) across the whole document and brings it into view; Escape closes the field. The Edit menu items are the same ones the terminal pane uses: the app delegate forwards them to whichever of the two holds the keyboard. No key equivalent was added.
