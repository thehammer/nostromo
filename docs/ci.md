# CI

## PR checks

"PR checks" are the GitHub jobs that run on every pull request against `main`
and on every push to `main`. They are defined in `.github/workflows/ci.yml`
(workflow name `CI`) plus the advisory launch smoke workflow below. None of
the jobs in `ci.yml` has a `paths:` filter, on purpose: a filtered job that is
skipped reports as "skipped", which a required check treats as passing.

| Check name | Runner | What it runs | Local equivalent | Typical runtime |
|---|---|---|---|---|
| `Build & Lint` | ubuntu-latest | `cargo build`, `cargo clippy -D warnings`, `cargo test` | `cargo test` | ~4.5 min |
| `Python tooling tests` | macos-latest | `make python-test` (fails on any skip) | `make python-test` | ~25 s |
| `Swift tests (Mac app)` | macos-26 | `make mac-test` — the `NostromoTests` scheme, ~1,230 tests | `make mac-test` | ~3.5 min |
| `Swift tests (NostromoKit)` | macos-26 | `make kit-test` — `swift test` over `Shared/NostromoKit`, ~570 tests | `make kit-test` | ~1.5 min |
| `iOS simulator build` | macos-26 | `xcodebuild -scheme Nostromo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` (compile only; no device, no tests) | `make ios-build` is the device build; the simulator command is in the workflow | ~1.5 min |
| `Launch smoke (advisory)` | macos-26 | see below (path-filtered, advisory) | `make mac-smoke` | ~5 min |

`make mac-test` and `make kit-test` remain the local commands; the Swift
jobs run exactly those Makefile targets, so a local failure and a PR-checks
failure are the same failure.

### The Swift jobs

- Same pins as the launch smoke: `macos-26` and
  `sudo xcode-select -s /Applications/Xcode_26.4.1.app`. A toolchain bump is a
  diff in `ci.yml`, not an unexplained change.
- `Swift tests (Mac app)` installs **Fira Code Nerd Font** (v3.4.0, verified
  against a pinned SHA-256) before testing. The app's mono font is that font
  (`Theme.firaCode`), a developer has it installed, a hosted runner does not,
  and without it AppKit falls back to SF Mono, whose line metrics differ —
  `ChatTurnViewLayoutTests`' rendered-height goldens (recorded with Fira Code)
  then come out several to ~120 pt short. If you regenerate those goldens or
  bump the font, update the version and checksum in `ci.yml` together.
- Concurrency is per job and ref; a newer push to a PR cancels the older run
  (pushes to `main` are never cancelled).
- Nothing is cached. NostromoKit is a local SwiftPM package and the Xcode
  projects have no remote package dependencies, so there is nothing safe to
  cache, and restoring stale DerivedData could let a stale build product
  mask a failure.
- On failure the jobs upload the `.xcresult` bundle (`swift-tests-mac-xcresult`),
  the NostromoKit log (`swift-tests-kit-log`) or the iOS build log
  (`ios-simulator-build-log`) for 14 days. The Makefile filters
  `xcodebuild` output down to a few lines, so the xcresult is where per-test
  detail lives.
- Reproduce a failure locally with `make mac-test` / `make kit-test`.
  Runner-only differences to keep in mind: one virtual display, a hosted
  (shared, sometimes loaded) machine, and no user-installed fonts. Tests must
  not depend on a particular display setup, on wall-clock run-loop pump
  durations, or on fonts that are not installed by the workflow.

### Making a check required

Required status checks are a repo setting (Settings → Branches → branch
protection rule for `main`, or a ruleset → "Require status checks to pass"),
not something the workflow file controls. The check names to add are the job
names above: `Swift tests (Mac app)`, `Swift tests (NostromoKit)` and
`iOS simulator build` (and `Build & Lint` / `Python tooling tests` if they
are not already required). Keep `Launch smoke (advisory)` out of the
required set; see its promotion criteria below.

## `macos-launch-smoke` (advisory)

`.github/workflows/macos-launch-smoke.yml` runs `bin/nostromo-launch-smoke`
— the L4 launch smoke check described in `docs/ios-verification.md` — on a
stock GitHub-hosted `macos-26` runner. It builds the macOS app and launches
it against an in-process fixture daemon in the same job the app was built
in, watches the running app for a real multi-pane AppKit layout, and reports
one of three verdicts. It exists to catch what `ci.yml`'s Rust and Python
jobs structurally cannot: a live-AppKit regression, like the 2026-09-03
`RatioSplitView.layout()` reentrancy crash
(`.claude/bugs/resolved/2026-09-03-ratiosplitview-layout-infinite-recursion-crash-on-launch.md`
in the primary repo checkout), that only shows up once `NSApplication` is
actually running.

### When it runs

- On every pull request against `main`, and on every push to `main`, whose
  diff touches a path the app's launch behavior could depend on:
  - `macOS/Nostromo/**`, `macOS/Nostromo.xcodeproj/**` — the app itself
  - `Shared/NostromoKit/**` — the app links it
  - `bin/nostromo-launch-smoke`, `tests/launch_smoke/**`,
    `tests/fixtures/focus_layout_split.json`,
    `macOS/scripts/ps-time-seconds.awk`,
    `macOS/scripts/launch-smoke-validate.sh` — the check itself
  - `src/ipc/protocol.rs` — the wire types the committed fixture frame must
    stay conformant with
  - `Makefile`, `.github/workflows/macos-launch-smoke.yml`
- It deliberately does **not** run on changes confined to `src/**` more
  broadly, `iOS/**`, `docs/**`, or `.claude/**` — a PR that cannot affect the
  macOS app's launch does not pay for this job. See the `paths:` list in the
  workflow file for the exact, current filter; keep this doc's copy above in
  sync if it changes.

### What a reader should do about each verdict

The verdict shows up as a job-summary block plus a `::error::`/`::warning::`
annotation, visible on the PR's Checks/Files tabs without opening the log.

| Verdict | Exit code | Annotation | What it means | What to do |
|---|---|---|---|---|
| PASS | 0 | none (summary only) | The app launched, reached a real multi-pane layout, and survived the observation window with no crash, no zero-size pane, and settled CPU. | Nothing — merge as usual. |
| FAIL | 1 | `::error::` | A live-AppKit defect was caught: process death, an attributed crash report, unsettled CPU, or a zero-size laid-out pane. | Read the job summary for which detector fired, reproduce locally with `make mac-smoke`, fix it. |
| INCONCLUSIVE | 2 | `::warning::` | The check could not reach a verdict — its own cause is named verbatim (build failed, a prerequisite was missing, multi-pane layout was never reached, another instance took the launch, or it timed out before the app came up). | Read the named cause. Usually an environment flake — re-run the job. If it recurs on the same PR, treat it as a real signal, not noise. |
| anything else | any other code | `::warning::`, "driver exited unexpectedly (code N)" | Never treated as success. | Investigate — this means the driver itself broke, not the app under test. |

The check is **advisory**: it is not in branch protection, and neither FAIL
nor INCONCLUSIVE blocks a merge. See "Promotion to required" below.

### Reproducing a CI failure locally

```
make mac-smoke
```

This is the identical command CI runs — same driver, same fixture, same
verdict logic. `make mac-smoke RELEASE=1` uses a Release build instead of
Debug.

### Artifacts

The job uploads `launch-smoke-diagnostics` on every run (`if: always()`),
containing whatever `bin/nostromo-launch-smoke --keep-artifacts` collected
before its unconditional cleanup:

- `report.txt` — the full verdict report
- `app.log` — the launched app's captured stdout/stderr
- `diagnostics.jsonl` — the diagnostics NDJSON stream the app itself emitted
- a `sample`(1) capture, present only on FAIL

`--keep-artifacts` (or its equivalent `NOSTROMO_SMOKE_ARTIFACT_DIR` env var)
is additive only: it does not change the verdict, and it does not affect the
driver's unconditional teardown of everything it launched.

### Promotion to required

The check stays advisory until it has demonstrated **twenty consecutive
clean runs on a known-good build** and **correctly failed the known-bad
build** (`make mac-smoke-validate`) — both already required as W1
acceptance criteria. Meeting that bar is necessary but not sufficient:
promoting this to a required status check in branch protection is a
separate, later decision for a human to make deliberately, weighing the
accumulated false-positive rate against the cost of the regressions it has
actually caught. Do not flip it on just because the streak is met.

### Limitations — a green here is not "the GUI is fine"

- A GitHub-hosted runner is **one virtual display of unstable, unguaranteed
  size**, while the operator develops with three real ones. A layout defect
  that only manifests at particular window geometries, or only with
  multiple windows open, is not caught here.
- The check verifies exactly four failure modes: process death, an
  attributed crash report, unsettled CPU, and a zero-size laid-out pane. It
  does not verify constraint conflicts, layout warnings, wrong-but-alive
  layouts, drawing artifacts, or anything requiring a human to look at the
  result. **A green run means "the app launched and exercised a live
  multi-pane split for the observation window," not "the GUI is correct."**
- No retry logic exists anywhere in the workflow. A flaky INCONCLUSIVE is
  re-run by a human, on purpose, one job at a time — never automatically.
