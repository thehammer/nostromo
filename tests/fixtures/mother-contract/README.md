# Mother headless-crew contract fixtures (vendored)

Byte-exact copies of Mother's contract fixtures, `plugins/mother/tests/fixtures/contract/*.ndjson`
in `thehammer/mother`, at the commit recorded in `MANIFEST.json`. They are the single copy that the
Rust tests (`tests/mother_contract_fixtures.rs`), the Kit tests (`MotherCrewWireTests`) and the fake
broker read. The contract itself is Mother's `docs/design.md`, "Headless crew contract (Phase 1)".

**Recordings.** Since Mother's HC-16 (#76) these are recordings of real runs
(`scripts/record-contract-fixtures.sh`: timestamps monotonic, `updated_at` increasing, real `crew` shape),
not hand-written. Pinned to Mother `15513946b0e5` (see `MANIFEST.json`). What changed from `0ca8b700`:

- each recording opens with an empty `snapshot`; the job arrives as a `queued` event carrying the full job
  (with the `crew` blob), and later `snapshot`s show it at later stages (so a fixture has several snapshot jobs
  with the same id);
- `progress.signals.cost` is an object `{usd, of_usd, basis, fraction}` (was a number); `signals` also gains
  `stage_share`, `stage_frac`, `checklist`, `pct_moved_at_active_s`, and `gates` gains `attempt`/`max_attempts`;
- `progress.eta` gains `n`; basis is `none` with label `?` until there is history;
- `gates` gains `effective_mode`, `posture`, `started_at`, `finished_at`; results gain `skip_reason`; the
  `override` key is absent unless overridden; an exhausted run keeps `status: "failed"`;
- `review_wave` lenses no longer list `archie:adherence` (it is under `adherence`); lens gains `refuted`,
  `examined_files`, `budget_usd`; the wave gains `cycles`, `decision`, `over_budget`, `pending_reviewers`;
- decision options of a `review_hold` are `resume_with_guidance`, `override_open`, `cancel` (no `escalate`);
  a resolution carries `session` and `agent` (empty strings) and no `at`;
- `hello` lists `subscribe`, `unsubscribe`, `query.list`, `query.get`, `answer`, `cancel`, `retry`,
  `force-start`, `output`, `ack`, `answer.option` and `progress`.

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
