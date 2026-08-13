# transcript-load tooling tests

Run with:

```
/usr/bin/python3 -m unittest discover -s tests/transcript_load
```

These tests cover the measurement harness for the bounded-transcript-memory
fix, not the app itself:

- `macOS/scripts/ps-time-seconds.awk` — the `ps -o time=` parser, invoked as
  a real subprocess.
- `macOS/scripts/transcript-load-report.py`'s `evaluate()` function — the
  pure criteria logic, called directly with fixture diagnostics rows, plus
  `main()`'s exit-code aggregation via a real temp diagnostics file.

  **The fixed-row-set invariant.** `evaluate()` returns exactly one row per
  entry in the module's `CRITERIA` tuple — the same set of criteria, and the
  same row count, for *every* input: a run that reached turn 5, a run with no
  panes, a run whose `sample` failed. `EvaluateRowSetIsFixedTests` asserts
  this across eight degenerate fixtures.

  This is the invariant, not a stylistic preference. This PR failed review
  twice on the same defect class — a criterion that silently vanishes when its
  input is missing, or that compares a measurement to itself, reads as "not a
  problem" in a table where every other line says PASS. A criterion nobody
  measured has not passed. Adding a row to `evaluate()` means adding its
  substring to `CRITERIA`; making one conditional means failing that test.
- `macOS/scripts/transcript-load-test.sh` — syntax (`bash -n`, and
  `shellcheck` if installed), static structural assertions on the script
  text, and one live exercise of the CPU-measurement dead-pid guard (via a
  spawned-and-waited `sleep`, never the real app).

None of these tests launch Nostromo.app. The numeric criteria that require a
real build, a real window, and a real steady-state footprint are verified
manually by actually running `macOS/scripts/transcript-load-test.sh` — this
suite only guarantees that the harness's own arithmetic and pass/fail logic
can't lie about what it measured.
