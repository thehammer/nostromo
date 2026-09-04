# launch-smoke tests

Run with:

```
/usr/bin/python3 -m unittest discover -s tests/launch_smoke
```

These tests cover the pure-function contract of `bin/nostromo-launch-smoke`
only: the verdict model (`reach_verdict` / `gate_verdict` / `aggregate` /
`exit_code_for`), the detector registry (`CRITERIA` / `@detector` /
`registration`), `.ips` crash-report parsing (`parse_ips_report` /
`crash_report_matches`), diagnostics-row attribution helpers (`rows_for_pid`
/ `distinct_pids` / `distinct_multipane_count` / `max_splits_ratios_applied`
/ `notdrawable_violations_from_rows`), CPU-percentage arithmetic
(`cpu_percent_from_times`), and the fixture daemon's IPC handshake
(`FixtureDaemon`, exercised over a real `AF_UNIX` socket in a
`tempfile.TemporaryDirectory()`).

The load-bearing tests in this file are the registry-parameterised ones,
mirroring the discipline in `tests/transcript_load/test_transcript_load_tooling.py`:

- **`UniversalVacuityTests`** — on `Evidence.empty()` (nothing observed at
  all), no registered detector may produce a passing verdict, with exactly
  one pinned exception (`no-zero-size-laid-out-pane` — see below).
  Parameterised over the live `CRITERIA` registry rather than today's list
  of seven keys, so a detector added tomorrow with no barren-input defence
  is still caught.
- **`DetectorKindInvariantTests`** — the kind partition (a `REACH` detector
  can only be `PASS`/`INCONCLUSIVE`; a `GATE` detector can only be
  `PASS`/`FAIL`) is asserted across many fixtures by looking up each
  verdict's kind via `registration(key).kind`, not by hardcoding which of
  today's seven keys is which.
- **`CriterionSensitivityTests`** — every registered detector is proven able
  to produce its own non-passing state at least once, via one keyed mutation
  per detector.
- **`AggregateTests`** — the precedence `FAIL > INCONCLUSIVE > PASS`,
  including the single most important case: a `FAIL`ing `GATE` detector
  combined with an `INCONCLUSIVE` `REACH` detector must aggregate to `FAIL`.
  This is what keeps a build with the reentrancy guard removed (which dies
  mid-layout, so the reach proofs read `INCONCLUSIVE`) from reporting
  `INCONCLUSIVE` instead of `FAIL`.

## What is NOT covered here

This suite does not launch `Nostromo.app`, does not build anything, and does
not exercise `main()`, argument parsing, process isolation (the cloned
bundle, environment scrubbing, Mother-broker neutralization), or the
known-bad-build validation ritual. Those are verified by actually running
`bin/nostromo-launch-smoke` and `macOS/scripts/launch-smoke-validate.sh`
against a real build — see the PR body's twenty-run log and known-bad
validation output for that evidence.

## The one pinned vacuous-pass exemption, and why

`no-zero-size-laid-out-pane` (`GATE`) may `PASS` on `Evidence.empty()` and on
any evidence where `panes_scanned == 0` — `PaneScanNeverHappenedStillPassesTests`
asserts this directly, and `UniversalVacuityTests.VACUOUS_PASS_EXEMPT` pins
it as the sole exception to the universal-vacuity rule, in the same spirit
as `transcript-load-report.py`'s own two-row-wide `STREAM`/`PROCESS`
exemption from its universal vacuity test.

This is not a loophole; it is required for the check's own load-bearing
acceptance criterion — the fixture-rot demonstration — to work at all. A
tree with only a `repl` leaf (the daemon-driven fallback when nothing has
told the app about a split) has zero `PaneContentNSView`-backed panes by
construction (`repl` is a `ReplView`, never registered in the pane registry
`panesMeasured` reads from) — a perfectly ordinary, healthy shape, not a
sign that this run's own plumbing failed to measure anything. An earlier
revision gated this detector on `panes_scanned > 0`, which made it `FAIL` on
exactly that tree; because a `GATE` `FAIL` always dominates `aggregate()`,
running `bin/nostromo-launch-smoke` against the fixture daemon serving a
single-leaf tree (instead of the real split tree) reported the whole run
`FAIL` instead of the required `INCONCLUSIVE "multi-pane layout not
reached"` — verified empirically, not just reasoned about, by actually
running that exact scenario. The fix mirrors `PaneFirstPaintAudit.verdict`
itself (`macOS/Nostromo/UI/PaneFirstPaintAudit.swift`), which reports
`.healthy` whenever there is nothing to judge: "nothing to violate" and
"something was measured and it's wrong" are different states, and only the
second is what this detector exists to catch.

## A known, documented contract tension

While validating this suite against a reference implementation of the
module's literal contract, two `GATE` detectors — `alive-at-window-end` and
`cpu-settled` — were found to correctly `FAIL` (not `PASS`) on
`Evidence.empty()`, per their own explicitly documented behavior
(`alive_at_window_end is None` reads as not-alive; `cpu_percent is None` is
explicitly specified as `FAIL "could not measure CPU"`). Because `GATE`
detectors have no `INCONCLUSIVE` state to fall back to, and because
`aggregate()`'s precedence is unconditionally `FAIL > INCONCLUSIVE`, this
means `aggregate(evaluate_evidence(Evidence.empty()))` is provably `FAIL`,
not `INCONCLUSIVE` — see the comments on
`UniversalVacuityTests.test_no_registered_detector_is_inconclusive_since_gate_never_is_and_reach_never_fails`
and `AggregateTests.test_real_registered_verdicts_on_evidence_empty_aggregate_to_fail_not_inconclusive`
for the full derivation. This suite asserts the provable reality (`FAIL`)
rather than the stated-but-unsatisfiable requirement (`INCONCLUSIVE`).

This is judged acceptable, not left as an open question, for one concrete
reason: `Evidence.empty()` is a synthetic fixture that cannot arise from a
real `main()` run. By the time `main()` ever constructs a real `Evidence`,
it has already either short-circuited to `INCONCLUSIVE` ("build failed" /
"prerequisite missing") before an `Evidence` exists at all, or it has a real
`launched_pid` from a successful `subprocess.Popen` — never the fully-`None`
shape `Evidence.empty()` represents. The scenario that matters in practice —
a healthy process that simply never reached multi-pane layout — is exactly
the fixture-rot demonstration covered above, and that one correctly reports
`INCONCLUSIVE`.
