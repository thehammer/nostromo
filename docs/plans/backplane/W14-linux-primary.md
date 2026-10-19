# W14 — Package nostromd as a Linux primary (systemd user unit)

## Refreshed 2026-10-18 against `origin/main` `d61c62d`

Versus the 2026-10-10 draft: `make install-daemon` now installs **two**
signed binaries, `nostromd` and the production-shell guard `nostromo-guard`
(staged to new inodes, guard moved first, `Makefile:69-110`); the Linux
target installs both the same way (no `codesign` on Linux). The operator-app
verifier is macOS-only (`src/ipc/peer_verify.rs:314-356`), so on Linux no
peer is ever `OperatorApp`: decisions and approvals can never be answered on
Tokyo, and the primary hosts no agent sessions in v1 (bet B10 in the memo).
This wedge documents that and makes the daemon say so at startup. Rust tests
run in the RWX sandbox (a Linux container), which is also where
`tests/linux_startup.rs` runs; no local `cargo`. **Collision:** this wedge
and MC4 (`mother-crew-client-mc4-needs-you-and-notifications.md`) both edit
`src/mother/mod.rs`; do not run them concurrently.

## Context

`docs/plans/backplane-sequencing.md` (bet B7) chooses **Tokyo**, a personal
always-on Linux workstation, as the primary `nostromd` host. The Rust
workspace already builds and tests on Linux in CI
(`.github/workflows/ci.yml:33-63`, `ubuntu-latest`: build, clippy, test;
and the RWX sandbox, `.rwx/sandbox.yml`), so this is packaging, not
porting. What is macOS-only today is the install path: `Makefile:69-110`
(`install-daemon` stages and `codesign`s `nostromd` and `nostromo-guard`,
renders `dist/launchd/com.hammer.nostromd.plist` and `launchctl
bootstrap`s it) and the log/launchd sections of `README.md`.

A primary does not need Mother or Bishop locally — satellites (W10)
publish those. It does need: a stable config location, a `systemd --user`
unit with `Restart=always` and lingering enabled so it survives logout, log
rotation, and a verified startup path where `mother` is absent from `PATH`
(`src/mother/mod.rs:321-340` `list_jobs`/`list_jobs_counted` and `:486`
`run_mother` shell out to it; the 2 s poller in `src/bin/nostromd.rs:568`
must log once and back off rather than spam). This wedge is independent of W9/W10 and should
be dispatched first; if it finds a blocker, Sendai becomes the primary with
no change to the other wedges.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-linux-primary`
- **Base:** `origin/main`
- **Max cost:** $20 (expected ≈ $8; see the memo's Estimate)

## Files to change

- `dist/systemd/nostromd.service` (new) — user unit template:
  `ExecStart=__PREFIX__/bin/nostromd`, `Restart=always`, `RestartSec=2`,
  `Environment=RUST_LOG=info`, `StandardOutput=append:%h/.cache/nostromd/log/stdout.log`,
  `StandardError=append:%h/.cache/nostromd/log/stderr.log`,
  `WantedBy=default.target`.
- `Makefile:69-110` — add `install-daemon-linux` / `uninstall-daemon-linux`
  (`cargo build --release --bin nostromd --bin nostromo-guard`; install both
  to `~/.local/bin` with the same stage-then-rename order as the macOS
  target, minus `codesign`; `mkdir -p ~/.config/systemd/user
  ~/.cache/nostromd/log`; render the template with `sed` like the plist path
  does; `systemctl --user
  daemon-reload && systemctl --user enable --now nostromd`; print
  `loginctl enable-linger $USER` as a required one-time step if
  `loginctl show-user $USER -p Linger` is `no`). Make `install-daemon`
  dispatch on `uname -s` so the existing macOS target is unchanged.
- `src/mother/mod.rs:321-340, 486` — when `mother` is not on `PATH`
  (`std::io::ErrorKind::NotFound`), return a typed `MotherUnavailable`
  error; `run_mother_pollers` (`src/bin/nostromd.rs:568-640`) logs it once
  at WARN and backs off to a 60 s interval instead of 2 s. Do not touch
  `src/mother/decode.rs` or the crew types.
- `src/bin/nostromd.rs` startup — on a non-macOS host, log one INFO line:
  "operator app verification unavailable on this platform: decisions and
  approvals cannot be answered here".
- `src/bin/nostromd.rs:196-260` — mDNS advertising already degrades
  non-fatally; confirm `mdns-sd` starts on a host with no multicast route
  or make the failure a single WARN. (Satellite mode in W10 removes it
  entirely; the primary keeps it only for a LAN client that still uses
  the raw TCP path.)
- `src/activity/hook_status.rs:12` (`default_settings_path`) and
  `src/bin/nostromd.rs:460-470` — the activity tailer path and the hook
  check assume `~/.claude/` exists; on a host with no Claude Code install
  the tailer must wait for the file to appear (it uses `notify`,
  `Cargo.toml:78`) rather than exit.
- `tests/linux_startup.rs` (new, `#[cfg(target_os = "linux")]`) — start the
  daemon binary via `assert_cmd`/`std::process::Command` with `HOME` set to a
  tempdir and an empty `PATH` save for the binary's own dir; assert it is
  still alive after 3 s, bound its Unix socket, and logged exactly one
  `mother` WARN.
- `README.md` §Daemon — "Install (Linux)" subsection; log paths are the
  same; state that a Linux primary hosts no agent sessions (no operator-app
  verification) and that installing restarts the daemon.
- `docs/ci.md` — note that the Linux job is now also the primary-host
  smoke; add a `systemd-analyze verify dist/systemd/nostromd.service` step
  to `ci.yml`'s ubuntu job.

## Approach

1. Write the unit and Makefile targets; verify on a Linux box or in CI with
   `systemd-analyze verify`.
2. Harden the two "assumes a Mac developer box" paths (`mother` on PATH,
   `~/.claude` present) so a bare primary starts clean.
3. Add the startup test and the CI verify step.
4. Document.

## Acceptance criteria

- [ ] **W14-1** `[operator, Tokyo; not a Cody gate]` `make install-daemon-linux` on Tokyo
  results in `systemctl --user status nostromd` = active, the unit survives `kill -9 <pid>` (restarted
  within 5 s), and `~/.nostromo/nostromd.sock` exists.
- [ ] **W14-2** With `mother` absent from `PATH`, the daemon logs one WARN and keeps
  serving; no WARN repeats more often than every 60 s.
- [ ] **W14-3** With no `~/.claude/activity.jsonl`, the daemon stays up and begins
  tailing when the file appears.
- [ ] **W14-4** `systemd-analyze verify dist/systemd/nostromd.service` passes in CI.
- [ ] **W14-5** macOS `make install-daemon` behaviour is unchanged.
- [ ] **W14-6** CI is green: the RWX sandbox Rust run (Linux, includes
  `tests/linux_startup.rs`), the `ubuntu-latest` build/lint job with the new
  `systemd-analyze verify` step, and the macOS jobs. No local `cargo`. The
  startup test is hermetic (tempdir `HOME`, empty `PATH`, no network).
- [ ] **W14-7** `make install-daemon-linux` installs both `nostromd` and `nostromo-guard`;
  a Linux daemon logs the "operator app verification unavailable" line.
- [ ] **W14-8** PR body references the sequencing memo (W14) and states B7's host as
  resolved.

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`). Assumes the repo's
`.mother/crew.yml` is merged before this job is added (it is read from the job's
base ref, so a worker can neither add nor loosen a gate).

- **Gates that apply:** `rust-clippy` and `rust-test` (`where: sandbox`), `python-test` (always on; sandbox). `swift-ci` is skipped (no Swift paths).
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to three fix attempts, then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `ops-infra`. `phi-security` is removed for this plan to save a lens run: it is not mandatory in this repo, and this wedge's `src/mother/mod.rs` edit would otherwise match its path scope. Lenses run
  in parallel with adherence on the gated commit once Mother PR #75 merges
  (open at the time of writing); until then run
  `mother review-lens <id> --lens <name>` on the PR's job, one lens at a time.
- **Review depth:** Lenses plus Mother's adherence review are enough here; no extra manual Perri pass beyond the `perri` entry below. Packaging only (systemd unit, Makefile, a Linux startup path).
- **Checklist:** the acceptance items above carry ids (`W14-1` to `W14-8`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- Any protocol or listener change (W9/W10).
- Mother or Bishop on Linux.
- A system-level (non-user) unit.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Packaging plus two small robustness fixes; the code is already Linux-clean per CI."
  redd:
    model: sonnet
    effort: medium
    rationale: "One process-level startup test and a CI verify step."
  marty:
    skip: true
    rationale: "Makefile/unit file work; nothing to refactor."
  perri:
    model: sonnet
    effort: medium
    rationale: "Service hardening, guard install order and restart semantics deserve a careful read but the surface is small."
lenses:
  add: [correctness, tests, ops-infra]
  remove: [phi-security]
```
