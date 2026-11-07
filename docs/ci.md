# CI

## PR checks

"PR checks" are the GitHub jobs that run on every pull request against `main`
and on every push to `main`. They are defined in `.github/workflows/ci.yml`
(workflow name `CI`) plus the advisory launch smoke workflow below. `ci.yml`
has no workflow-level `paths:` filter, on purpose: a workflow that a path filter
stops from starting never reports its checks, so a required check from it stays
"Expected" and blocks the PR. The Swift jobs are skipped by a *step-level* gate
instead; see "Skipping the Swift jobs" below.

| Check name | Runner | What it runs | Local equivalent | Typical runtime |
|---|---|---|---|---|
| `Build & Lint` | ubuntu-latest | **the aggregate of the three Rust jobs below**: succeeds only if all three did. This is the required status check. | fmt, clippy and test together | the slowest of the three |
| `Rust format` | ubuntu-latest | `cargo fmt --check` | same | ~15 s |
| `Rust clippy` | ubuntu-latest | `cargo clippy --all-targets -- -D warnings` | same | ~2.5 min |
| `Rust tests` | ubuntu-latest | `cargo test` (compiles and links the lib, the bins and every test binary) | same | see "Where the time goes" |
| `Detect changed paths` | ubuntu-latest | `scripts/ci_changes.py` over the PR's changed paths | n/a | ~10 s |
| `Python tooling tests` | macos-latest | `make python-test` (fails on any skip) | `make python-test` | ~4 min |
| `Mac tests shard 1/3`, `2/3`, `3/3` | macos-26 (x3, parallel) | `make mac-test SHARD=<n>`: one third of the `NostromoTests` classes (~7,700 tests in all, serial inside a shard); shard 1 also runs the compile gate | `make mac-test` (all classes) or `make mac-test SHARD=<n>` | see "Where the time goes" |
| `Swift tests (Mac app)` | ubuntu-latest | **the aggregate of the three Mac shards** (`scripts/ci_mac_aggregate.py`): green only if every shard ran, passed and reported tests, and the total reaches the floor in `macOS/ci/mac-shards.json`. Takes no macOS slot. | n/a | seconds after the last shard |
| `Swift tests (NostromoKit)` | macos-26 | `make kit-test` — `swift test` over `Shared/NostromoKit`, ~570 tests | `make kit-test` | ~2.5 min |
| `iOS simulator build` | macos-26 | `xcodebuild -scheme Nostromo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` (compile only; no device, no tests) | `make ios-build` is the device build; the simulator command is in the workflow | ~1.7 min |
| `Launch smoke (advisory)` | macos-26 | see below (path-filtered, advisory) | `make mac-smoke` | ~5 min |

Every job except the advisory launch smoke can also be dispatched by hand on a
branch, alone or in groups; see "Running CI on a branch (dispatch)" below.

`make mac-test` and `make kit-test` remain the local commands; the Swift jobs
run exactly those Makefile targets (the shards add `SHARD=<n>`), so a local
failure and a PR-checks failure are the same failure.

### How the Mac tests are sharded

`Swift tests (Mac app)` is an aggregate (the same pattern as `Build & Lint`) over
three parallel jobs, `Mac tests shard N/3`, each on its own `macos-26` runner
(each builds the bundle itself, ~200 s). The assignment is
`macOS/ci/mac-shards.json`:

- Shards 1 and 2 list classes and run exactly those (`-only-testing:NostromoTests/<Class>`).
- Shard 3 is the **catch-all**: it runs everything *not* listed in 1 and 2
  (`-skip-testing:NostromoTests/<Class>` for each of their classes). A new test
  class therefore always runs, in shard 3, with no config change.
- Classes are never split, so any ordering or shared-state assumption inside a
  class (`MouseQueueTestCase` subclasses, the defaults guard, display tests) is
  unchanged. A cross-class assumption (state one class leaves for another) would
  show as a failure once shard membership changes; fix the test, do not pin it.

Guards (each is a failing check, not a log line):

| Guard | Where |
|---|---|
| a class listed in the config that does not exist (a typo would run zero tests) | `scripts/mac_shards.py` (`make mac-test SHARD=n` and the report step fail) |
| a shard that executed no tests | `scripts/ci_mac_aggregate.py` |
| total executed across shards < `expected_min_executed` | aggregate |
| a skipped, cancelled, failed or missing shard job | aggregate (`needs.<shard>.result` must be `success`; "skipped" fails when Swift paths changed, because a skipped required check counts as passing on GitHub) |
| no shard reported a passing `MotherDetailWidthConstraintTests` case | aggregate (the per-shard step rejects skips) |

`swift == 'false'` (the path classifier) makes the aggregate green without any
shard, exactly as the single job behaved with its steps skipped.

**Rebalancing.** Each shard uploads `shard-<n>.json` (report) for 14 days, and on
`main` pushes also `mac-test-log-shard-<n>` (the full log). To rebalance after
many new tests (shards more than ~15% apart in the job times): download the three
logs, concatenate them and run

```
cat shard-*-logs/mac-test-full.log > /tmp/all.log
python3 scripts/mac_shards.py regenerate --log /tmp/all.log --balanced-from <run id> --write
```

`regenerate` balances by per-class duration (greedy, deterministic) and refreshes
`expected_min_executed` to 97% of that run's total. `--from-source` estimates from
test-method counts (how the first assignment was made, before any timing log
existed). The floor only guards against an accidental large drop; raise it when
you add many tests.

**macOS slots.** GitHub Free allows 5 concurrent macOS jobs for the account. One
run now uses 3 shards + one Kit-then-iOS chain (`iOS simulator build` `needs`
`Swift tests (NostromoKit)`, so they share a slot) + `Python tooling tests`
(`macos-latest`, ~4.5 min) = 5, plus `Launch smoke (advisory)` on the PRs it
runs for, which queues briefly. A second overlapping run (or a `make ci-remote`
dispatch) queues behind. Five shards are deliberately not used: they would starve
everything else for ~2 min of gain.

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
- Concurrency is per job, event and ref; a newer push to a PR cancels the older
  run (pushes to `main` and dispatches are never cancelled).
- **There is no dependency cache.** The Mac app has one remote package, SwiftTerm,
  pinned exactly to 1.18.0 in the project and in
  `macOS/Nostromo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  (plus swift-argument-parser); NostromoKit is a local package with nothing to
  fetch. A cache of the SwiftPM source checkouts was built and measured and did
  not help (33 s with a hit, 19-45 s without: the time is `xcodebuild` resolving
  the package graph, not the download), so it was removed. See "Measured and not
  shipped" below.
- **There is deliberately no DerivedData cache.** Restoring stale DerivedData
  could let a stale build product mask a failure, which is the failure class
  that let #345 through.
  SwiftTerm 1.19+ has a build-tool plugin that command-line
  `xcodebuild` rejects without `-skipPackagePluginValidation`: do not upgrade
  it without deciding that flag's place in `make mac`, CI and the smoke.
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

### Where the time goes (measured 2026-10-28)

From main run 40720495299 (`40f95ba4`) and the same source after the Rust split
(dispatch run 40741191261):

| Job | Before | After | What dominates |
|---|---|---|---|
| `Build & Lint` | 848 s | ~650 s (aggregate) | Before: cargo cache restore 59-295 s of a 7.6 GB target dir, build 218 s, clippy 76 s, tests 483 s. After: `Rust format` 14 s, clippy 112 s and tests 643 s run as parallel jobs; `Build & Lint` is now an aggregate job that depends on them. |
| `Swift tests (Mac app)` | 1,322 s | 1,322 s (unchanged) | `make mac-test` 1,245 s = about 197 s build + 1,048 s executing 5,836 tests; the compile gate is 59 s. |

**Mac tests, sharded.** Baseline before sharding (green PR run 41621628581):
`Swift tests (Mac app)` 1,710 s, `Swift tests (NostromoKit)` 149 s, `iOS simulator
build` 122 s, `Rust tests` 666 s, `Python tooling tests` 273 s, `Rust clippy` 130 s;
`make mac-test` executed 7,704 tests (the unsharded count the sharded total must
match). With three shards the expected Mac wall-clock is setup ~90 s + build ~200 s +
execution / 3 + the compile gate (about 11-13 min). The first assignment is balanced
by test-method count, not time (no per-class timing log existed); re-run
`scripts/mac_shards.py regenerate` from the first `main` push's uploaded logs. Measured
per-shard times and the 5-slot cap result are recorded in the sharding PR description.

The required check name `Build & Lint` is unchanged (it is the aggregate job), so
branch protection needs no change.

### Measured and not shipped

- **SwiftPM source cache:** no faster (33 s hit, 19-45 s miss), removed.
- **Parallel Mac testing** (3 workers, layout goldens kept serial) cut the Mac job
  to 675-1,014 s but failed the five-consecutive-green bar: 8 of 10 runs green,
  both reds were `MotherDetailScrollTests.testDataBelowTheReaderOrInsideTheLogLeavesTheScrollPositionAlone`
  (once in the parallel phase, once in the serial phase). Not shipped; the
  implementation is in branch history at `c44722a1` (`macOS/scripts/mac-test-ci.sh`).
  Revisit after that test is made deterministic. The race behind it is fixed in the
  test harness (a late peek delivery for the previous job, and the 5 s startup action
  error clearing mid-test; PR #425). `.github/workflows/mac-scroll-loop.yml`
  (`workflow_dispatch`) loops a test class N times, plain and CPU-loaded, to prove it.
  Two corrections to what #425 shipped, found by the first 50-iteration run (41967116944,
  plain: 800 test cases started, 799 passed, 0 failed):
  - **#425's fix for the sideways-scrolling Overview introduced a constraint conflict.**
    The production bug was real (a legacy scroller took its width out of the clip and the
    document kept the old width), but the width constraint it added
    (`DetailDocumentView.width == <clip width>`) was **required priority** and was created
    before the first layout, with the clip's width of 0. It conflicted with the content's own
    required constraints (`H:|-16-[section]`, `section.trailing == document.trailing - 16`,
    the stacks and `WrapLabel.width == NSStackView.width`): 10,800 "Unable to simultaneously
    satisfy constraints" reports, from the first iteration, and AppKit "recovering by
    breaking" a required constraint every time a job detail was built. It is now priority
    999 (above the content's 750 compression resistance, below required), and
    `syncContentWidth` asks the clip for layout at most 3 times per mismatch. Note that
    AppKit keeps a constraint it breaks `isActive`: the conflict is visible only in its
    report, which `MotherDetailWidthConstraintTests` reads from stderr (xcodebuild sets
    `OS_ACTIVITY_DT_MODE`). Under CI (`CI` or `GITHUB_ACTIONS` set) an unreadable report is
    a test failure, not a skip; locally the test skips with a reason, after its other
    assertions have run; and a `ci.yml` step fails the Mac job on any skipped
    `MotherDetailWidthConstraintTests` case.
  - **Narrow widths are a known, pre-existing gap.** The "no conflict" assertions run at 320 pt
    and wider. 320 pt is the divider's clamp (`MotherListWidth.maximum = max(220, viewWidth - 320)`),
    not a floor on the pane: with a Mother view narrower than 540 pt the detail can be narrower than
    320 pt, and there the detail's own required constraints (the 16 + 16 insets around the log scroll
    view, whose legacy scroller is 17 pt) conflict on `main` too (seen at 40 pt). Below 320 pt the
    tests only check that layout terminates and that the Overview width constraint is not the one
    AppKit reports. Fixing the narrow case is a follow-up.
  - **The iteration-50 "hang" is not explained.** On main the job was cancelled at its 110
    minute limit with the last test case of iteration 50 running (that test takes about 9 s;
    an iteration takes about 2.9 minutes, so 50 take about 2.4 hours, longer than 110
    minutes). After this fix a single 50-iteration job (run 42068608537) ran past its 240 minute
    limit and was cancelled with no log and no artifact (the runner never ran its later steps),
    so that run shows nothing about the code. The same 50 iterations split into five parallel
    10-iteration jobs (run 42108808133, `-f iterations=10 -f 'chunks=[1,2,3,4,5]'`) all finished
    in about 28-29 minutes: 230 test cases per chunk, 0 failures, 0 "Unable to simultaneously
    satisfy". What was **not** shown is why one long job outlived its limit: a slow or lost
    runner, or something that degrades only after ~40+ iterations in one process, are both
    possible. No test reproduced an infinite layout loop in `syncContentWidth` (an unbounded
    `clip.needsLayout = true` was possible when the document cannot be as narrow as the clip,
    and is now bounded). Prefer chunks of about 10 iterations; the workflow's `chunks` input
    does this.
- **DerivedData cache:** deliberately not done. A restored DerivedData can let a
  stale build product pass a test the current source would fail, which is how
  #345 got through. (Test sharding was first deferred for the same parallel-safety
  reasons; it shipped as separate jobs, one process each, so none of the
  in-process parallel-testing risk applies: see "How the Mac tests are sharded".)
- **Rust tests are now the longest remaining job** (~11 min): the next candidate
  for the same treatment (`cargo test` partitioning or nextest).
- **Path gate:** docs, `.claude`, `tests/*.rs` and Cargo-file-only changes skip the
  Swift jobs. `src/` is **not** skippable because `StatusBarPostureWindowsTests`
  scans `src/**/*.rs`. Verified on throwaway PRs #370-#372 (closed).
- **Compile-gate proof:** a throwaway commit that breaks an app-only file
  (`TerminalPaneHostView.swift`) made the compile gate fail while all 5,836
  `NostromoTests` passed (run 40745683225). The revert is in the history; the
  final head compiles.

### The app-build compile gate

`Swift tests (Mac app)` also runs a `Build Mac app (compile gate)` step:
`xcodebuild -scheme Nostromo -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build`,
failing on a non-zero exit or any `error:` line. `make mac-test` builds only the
`NostromoTests` bundle, which excludes app-only sources (e.g.
`TerminalPaneHostView`, which links SwiftTerm), so without this step a
non-compiling app passed every required check (PR #345). It shares the test
step's DerivedData (`macOS/build`), so it only compiles what the tests did not.
It lives inside the already-required job, so no branch-protection change is
needed. **`Launch smoke (advisory)` green does not mean the app built**: the
smoke is path-filtered and advisory, and its INCONCLUSIVE verdict (including a
failed build) stays green. The app-build step is the compile gate.

### Making a check required

Required status checks are a repo setting (Settings → Branches → branch
protection rule for `main`, or a ruleset → "Require status checks to pass"),
not something the workflow file controls. The check names to add are the job
names above: `Swift tests (Mac app)` (the aggregate; do **not** add the
`Mac tests shard N/3` names, a rename of a shard would then block every PR), `Swift tests (NostromoKit)` and
`iOS simulator build` (and `Build & Lint` / `Python tooling tests` if they
are not already required). Keep `Launch smoke (advisory)` out of the
required set; see its promotion criteria below.

**The required check did not change.** Today the only required context on
`main` is `Build & Lint`. After the Rust job was split into `Rust format`,
`Rust clippy` and `Rust tests`, `Build & Lint` is an aggregate job with the
same name that depends on all three and succeeds only if each result is
`success` (a failed, cancelled or skipped part fails it). So branch protection
needs **no change** and there is nothing for the owner to update. Do not add the
three part names as required: they add nothing the aggregate does not already
enforce, and a rename of a part would then block every PR. If the owner later
makes the Swift checks required, nothing changes for them either: the gated
Swift jobs always start and report success under their real names (next section).

### Skipping the Swift jobs

A `changes` job (`Detect changed paths`) runs `scripts/ci_changes.py` on the
paths a pull request changes (`git diff -z --no-renames --name-only HEAD^1 HEAD`
on the merge commit; both sides of a rename are listed). Every step of the three
Swift jobs after checkout is gated on its `swift` output, so a PR that cannot
affect Swift does none of their work: the jobs start, report **success** in
seconds under their real names, and skip the rest.

It is default-run, not default-skip. The Swift jobs are skipped **only if every
changed path** is on a short allow-list:

- `docs/**` and `.claude/**`
- `tests/**/*.rs` outside `tests/fixtures/` (Swift tests read the fixtures)
- `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`

**`src/**` (the Rust daemon) is deliberately not on the list.** Two Mac tests
read the Rust sources: `ActivityStreamModelTests` reads
`src/activity/store.rs`, and `StatusBarPostureWindowsTests`
(`testNoSourceReferencesTheTmuxRateLimitsFile`) walks every `.rs` file under
`src/` looking for a forbidden string, so any Rust source change can change a
Swift test's verdict. A Rust PR that touches `src/` therefore still runs the
Swift jobs. Moving that one scan into a Rust test would let `src/**` join the
allow-list; that is a follow-up, not part of this change.

Everything else runs the Swift jobs: anything under `macOS/`, `iOS/`,
`Shared/` (including `NostromoKit`), `project.pbxproj`, the `Makefile`,
`.github/` (so any change to this workflow), `scripts/`, `bin/`, every unknown
or new path, an empty or unreadable diff, a path with `..`, a leading `/` or
`./`, or a backslash, and any non-PR event (pushes to `main`, dispatches). The
Mac compile gate therefore runs whenever the app could have changed. Any
classifier error prints `swift=true`.

Why steps and not the job: a job skipped by a job-level `if:` posts its check
under the unevaluated `name:` expression text (measured on a throwaway PR), so
a required `Swift tests (Mac app)` would stay "Expected" and block the PR.
Merge tooling (`merge-when-green.sh`) treats SUCCESS, SKIPPED and NEUTRAL as
green, so either would pass it; the step gate is the one that is also correct
for branch protection. The cost is a macOS runner started for a few seconds.
If `Detect changed paths` itself fails, the three Swift jobs are skipped at job
level (they `need` it) and `Detect changed paths` is red: if the Swift checks
are ever required, they stay "Expected" and block the PR, which is the safe
direction.

Drift guard: `tests/ci_policy/test_ci_changes.py` scans every Swift source for
repo-relative reads (`appendingPathComponent("src/...")`, `tests/...`, `docs/...`)
and fails if one falls under the skip list. If a Swift test starts reading a
new Rust or docs file, that test fails until the file is added to the
exclusions in `scripts/ci_changes.py`.

## Running CI on a branch (dispatch)

`ci.yml` has a `workflow_dispatch` trigger, so CI can run on any **pushed**
branch without a PR, and `make ci-remote` wraps it. Use it instead of running
`xcodebuild` locally (gigabytes of DerivedData, and the Mac suite changes the
display state of the machine you are working on).

```
make ci-remote                          # current branch, every job
make ci-remote ONLY=kit                 # only Swift tests (NostromoKit)
make ci-remote BRANCH=feature/x ONLY=mac
make ci-remote RUN=<run id>             # attach to an existing run (e.g. a PR's CI run); no dispatch
```

It dispatches the run, waits (default timeout 50 min), prints one line per job
state change, and on failure prints `FAILED <job>: <test or error>` lines parsed
from the failed-step logs (XCTest, Swift Testing, cargo test, rustc/clippy,
Swift compiler, Python unittest; a failed job with no recognised line gets its
last 30 log lines tagged `[unparsed]`). Exit codes: 0 green, 1 a job failed,
2 could not start, 3 timed out or run not found. It never cancels a run; on a
timeout or Ctrl-C it prints `make ci-remote RUN=<id>` to reattach. The Mac tests run
as three shard jobs; their failures are attributed as
`FAILED Swift tests (Mac app) / shard 2: <test>` (`... (dispatch) / shard 2` on a dispatch).
The aggregate `Swift tests (Mac app)` job may add an `[unparsed]` line saying which
shard guard tripped.

`scripts/ci_remote.py` needs `gh` logged in with the `repo` and `workflow`
scopes (those include `actions: write`, which dispatching needs; the workflow's
own `permissions:` stay `contents: read`).

### The `only` selector

| `ONLY` | Jobs that run |
|---|---|
| `all` (default) | every job |
| `rust` | `Build & Lint` and its three parts (`Rust format`, `Rust clippy`, `Rust tests`) |
| `python` | `Python tooling tests` |
| `swift` | `Swift tests (Mac app)` (and its three shards), `Swift tests (NostromoKit)`, `iOS simulator build` |
| `mac` | `Swift tests (Mac app)` (and its three shards) |
| `kit` | `Swift tests (NostromoKit)` |
| `ios` | `iOS simulator build` |

Push and pull-request events always run every job (on a pull request the Swift jobs still start but skip their work when `Detect changed paths` says so; a dispatch never skips them).

### Check names carry a `(dispatch)` suffix

On a dispatch every job's name is its normal name plus ` (dispatch)`, for
example `Build & Lint (dispatch)`; on push and PR the names are unchanged.
Why: a skipped job still posts a check run under its name on the head commit,
and a skipped required check counts as passing. If the names were identical, a
dispatch with `ONLY=swift` on a PR's head commit would post a *skipped*
`Build & Lint` and silently satisfy the required check. With the suffix,
dispatch results never count as PR checks. (A PR still needs its own PR-event
run to merge; a green dispatch is feedback, not a merge gate.)

### Concurrency

The event name is part of each Swift job's concurrency group, and
`cancel-in-progress` stays true only for `pull_request`. GitHub keeps at most
one *pending* run per group and drops the older pending one regardless of
`cancel-in-progress`; without the event name a dispatch on `main` would share a
group with `main` pushes and could displace a pending push run, leaving a merge
commit without a verdict. A dispatch on a feature branch (`refs/heads/x`) never
shares a group with that branch's PR runs (`refs/pull/N/merge`). Two dispatches
on one branch queue; a third replaces the pending second.

### Requirements and limits

- The branch must be **pushed**: CI only sees what is on `origin`.
  `make ci-remote` refuses (exit 2, "push first") when local `HEAD` differs from
  the remote branch, and never dispatches then.
- The branch must contain this change. An older branch has no dispatch trigger
  and GitHub rejects the dispatch; `make ci-remote` says so ("rebase onto
  main").
- GitHub only offers `workflow_dispatch` once the trigger exists on the default
  branch, so dispatch works after this change is on `main`.
- `push` stays `main`-only, so pushing a feature branch triggers nothing until a
  PR is opened or someone dispatches.

### Cost

The repo is public, so standard GitHub-hosted runners (including `macos-26`)
cost **$0**. The real limit is concurrency: a personal Free account runs at most
5 macOS jobs at once (an assumption from GitHub's published limits; check
Settings > Billing). A full dispatch uses up to 5 macOS slots at once (python-tooling, 3 Mac shards, and
the Kit-then-iOS chain one at a time), so two simultaneous full dispatches or a
dispatch plus a PR run will queue. Prefer
`ONLY=swift`, `mac` or `kit`. Typical wall time: about 14 min for everything
(`Build & Lint` dominates), about 7.5 min without it, about 2 min for `kit`.

If the repo ever goes private (rates assumed; check current pricing): a full
run bills about 14 macOS minutes (8 + 2 + 2 + 2, rounded up per job) at about
$0.06-0.08/min plus about 15 Linux minutes at about $0.006-0.008/min, so about
$1.0-1.25 per full run, and about $0.5-0.65 for `ONLY=mac`.

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

The check is **advisory**: it is not in branch protection. A FAIL verdict
(exit 1) makes the check's conclusion `failure` so merge tooling that reads
check conclusions sees it; INCONCLUSIVE stays green with a warning. Branch
protection itself is unchanged (it does not require this check). See "Promotion to required" below.

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
