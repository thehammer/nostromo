# Mother quality gates and lens review (`.mother/crew.yml`)

Mother reads `.mother/crew.yml` from a job's **base ref** when the job is added, so a worker can't weaken its own gates. It then runs the declared gates on the job's pushed head commit and a lens review wave (adherence plus Perri lenses) on the same commit.

## What runs for nostromo

| Gate | Where | Runs when changed | Approx. cost | Blocking |
|---|---|---|---|---|
| `rust-clippy` | sandbox | `src/**`, Rust tests, `Cargo.*`, toolchain, `.rwx/**` | ~30 s (+ ~75 s sandbox start) | yes |
| `rust-test` | sandbox | same as clippy | ~3 min 18 s from a fresh sandbox | yes |
| `python-test` | sandbox | `tests/**`, `scripts/**`, `bin/**`, `Makefile`, `*.py` | ~45 s | yes |
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
- `python-test` runs in the Linux sandbox and its `when` paths cover the trees the Python policy suites scan (`macOS/`, `iOS/`, `Shared/`, `.github/`, `src/mother/`). CI's Python job runs on macOS on purpose (BSD `ps`); if the first observe results show a sandbox-only failure for `python-test`, set `blocking: false` for it before judging agreement with CI.
- `shellcheck-changed.sh` cannot check a changed file whose name git prints quoted (non-ASCII, quotes, tabs): it says so on stderr and fails rather than passing silently.
