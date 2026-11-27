# CI policy tests

Source-scanning policy tests over `.github/workflows/macos-launch-smoke.yml`
(and a light non-regression check on `.github/workflows/ci.yml`) — not tests
of GitHub Actions' behaviour, tests of what the workflow file *says*, parsed
as text with regex/line-scanning the same way `tests/ios_policy` scans Swift
source, since stdlib `yaml` is not available in this repo and no test here
adds a new third-party dependency to get it. They exist because the launch
smoke CI wedge (`.claude/plans/launch-smoke-test-ci.md`) has several
properties — the runner pin, the path filter's inclusions and deliberate
exclusions, advisory-not-blocking, no retry-to-green, and the exit-code-to-
annotation mapping — that a code reviewer can silently regress by editing
YAML, with no compiler and no other test catching it; every check here has a
companion "bites" test proving it can actually fail, in the same spirit as
`tests/ios_policy` and `tests/transcript_load`'s vacuity-test pattern, and
this suite never skips (see `SuiteNeverSkipsTests` in
`test_macos_launch_smoke_workflow.py`) since the CI job that runs it
(`.github/workflows/ci.yml`, `python-tooling`) fails the build on any
reported skip. Run with:

```
python3 -m unittest discover -s tests/ci_policy -v
```

The same stdlib-only approach covers the rest of the workflow set: `test_linux_runner_pin.py`
(every runner image pinned, both `.yml` and `.yaml`), `test_action_pins.py` (every `uses:` a full
commit SHA with a version comment), `test_rust_toolchain_pin.py`, `test_nextest_pin.py`,
`test_push_relay_workflow.py` (always-reporting required check, with its path classifier run
against real merge commits in a throwaway repo) and `test_deep_fuzz_workflow.py`. `workflow_steps.py`
is the shared `uses:` step reader (not a test module). `test_nextest_pin.py` reads
`.config/nextest.toml` with `tomllib` (Python 3.11+).
