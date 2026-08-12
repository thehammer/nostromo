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
- `macOS/scripts/transcript-load-test.sh` — syntax (`bash -n`, and
  `shellcheck` if installed), static structural assertions on the script
  text, and one live exercise of the CPU-measurement dead-pid guard (via a
  spawned-and-waited `sleep`, never the real app).

None of these tests launch Nostromo.app. The numeric criteria that require a
real build, a real window, and a real steady-state footprint are verified
manually by actually running `macOS/scripts/transcript-load-test.sh` — this
suite only guarantees that the harness's own arithmetic and pass/fail logic
can't lie about what it measured.
