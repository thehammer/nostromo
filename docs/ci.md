# CI

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
