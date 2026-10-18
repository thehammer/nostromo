# Mother headless-crew contract fixtures (vendored)

Byte-exact copies of Mother's contract fixtures, `plugins/mother/tests/fixtures/contract/*.ndjson`
in `thehammer/mother`, at the commit recorded in `MANIFEST.json`. They are the single copy that the
Rust tests (`tests/mother_contract_fixtures.rs`), the Kit tests (`MotherCrewWireTests`) and the fake
broker read. The contract itself is Mother's `docs/design.md`, "Headless crew contract (Phase 1)".

**Provisional.** The fixtures are hand-written today. Mother's HC-16 re-records them from real runs at
the same paths; re-vendor then and the tests show what changed.

| File | Shows |
|---|---|
| `gates_fix_pass.ndjson` | gates fail, a fix attempt, gates pass; progress events |
| `lens_wave.ndjson` | the lens review wave, including a skipped lens |
| `gate_hold_answered.ndjson` | an exhausted-gates hold with an open decision, then its answer |

`ipc_mother_jobs.golden.json` and `ipc_mother_jobs_plain.golden.json` are not Mother's: they are the
daemon's own `ServerMsg::MotherJobs` bytes for the fixture jobs (and for jobs with no crew data),
written by the Rust tests (`UPDATE_GOLDEN=1`) and read by the Kit tests.

## Re-vendor

```bash
git -C ~/Code/mother fetch                 # the script never fetches
python3 scripts/mother-contract.py vendor  # from $NOSTROMO_MOTHER_REPO (default ~/Code/mother), --ref origin/main
# then, in the RWX sandbox, refresh the IPC golden:
#   rwx sandbox exec -- env UPDATE_GOLDEN=1 cargo test --test mother_contract_fixtures
git diff tests/fixtures/mother-contract
```

## Check for drift

```bash
python3 scripts/mother-contract.py check           # manifest sha256s, then the local Mother repo at origin/main
python3 scripts/mother-contract.py check --online  # or raw.githubusercontent.com (also NOSTROMO_CONTRACT_DRIFT_ONLINE=1)
```

Exit 0 in sync, 1 on drift (`drifted: <file>`), 3 when the upstream is unavailable (`skipped: <reason>`).
The manifest check always runs, so editing a vendored file by hand fails `make python-test`.
