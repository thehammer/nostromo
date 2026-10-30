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

The plan path is Mother's own copy of the plan. The loader follows links, then shows the file only if the resolved path is a regular file ending in `.md`, `.markdown` or `.mdown`, is at most 1 MiB (checked with `stat` before any byte is read) and is valid UTF-8. Anything else is one calm message in place of the body (not found, can't read, can't be shown here, not UTF-8) with a **Copy path** button, and never an alert. A link named `.md` that points at some other kind of file is "can't be shown here", and its bytes are never read.

The view watches the file while it is showing and reloads when it changes (events coalesced over 300 ms, so an editor's save-by-rename is one reload). The reader's place holds across a reload: the topmost visible heading stays where it was, or the nearest heading before it if that one is gone. Watchers and timers stop when the view leaves its window, is hidden behind another segment, or the job changes.

### Safety

A plan's text is untrusted. Every span goes through `FoldTextSanitizer` (escape sequences, controls, bidi, zero-width and invisible filler characters; code blocks keep `\n` and `\t`). Images render as `[image: alt]`: the image URL is not kept anywhere in the model and nothing is fetched. Links open only on click: `http` and `https` in the browser, `file:` links and relative paths are revealed in Finder (never opened), every other scheme is plain text. Nothing here logs plan text, a heading or a path. `MotherFocusFitnessTests` scans the plan files for logging calls, `tag` properties and network or process APIs.

The header's **Open ↗**, **Finder** and **⧉** (copy the path) are view actions, like the old "View Plan" button. The text of the plan is on screen and in the accessibility tree: it is also on disk, readable by the same user.

### Find

⌘F with the keyboard in the plan opens a find field in its header; Return or ⌘G finds the next match (case-insensitive) across the whole document and brings it into view; Escape closes the field. The Edit menu items are the same ones the terminal pane uses: the app delegate forwards them to whichever of the two holds the keyboard. No key equivalent was added.
