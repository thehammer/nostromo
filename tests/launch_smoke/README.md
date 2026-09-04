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
  all), no registered detector may produce a passing verdict. Parameterised
  over the live `CRITERIA` registry rather than today's list of seven keys,
  so a detector added tomorrow with no barren-input defence is still caught.
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
rather than the stated-but-unsatisfiable requirement (`INCONCLUSIVE`); the
design tension itself needs a decision from Ada/Archie before it can be
re-tested the other way.
