# RWX test sandbox

Run Nostromo's Rust and Python checks in a cloud sandbox instead of on your Mac. Config: [`.rwx/sandbox.yml`](../.rwx/sandbox.yml).
Without it every worktree grows its own `target/` of 10-14 GB and `cargo` takes a large share of the CPU.

Linux only: nothing that needs AppKit, CryptoKit or Xcode runs here (see §5).

## 1. What it is

- One sandbox per **worktree + branch** (its identity is the branch plus the absolute config path). A detached HEAD counts as a different branch, so it gets its own sandbox.
- Ubuntu 24.04 with Rust **stable** (the same channel CI's `dtolnay/rust-toolchain@stable` installs, with `clippy` and `rustfmt`), Python 3.12 and shellcheck 0.9. The toolchain version is read from `static.rust-lang.org` each time a sandbox is created, so it moves with stable. `rust-toolchain.toml` (`channel = "stable"`) resolves to it.
- Cargo dependencies are compiled once in a cached `deps` layer (keyed on `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml` and the Rust version). A new or restarted sandbox compiles only the `nostromo` crate, not its dependencies.
- Before each exec, local changes (staged, unstaged, untracked) sync **up**; after it, the sandbox's changes sync **down**. Gitignored files (`target/`) never sync either way.
- The repo is public, so the sandbox clones `https://github.com/thehammer/nostromo.git` anonymously. No token, no secrets.
- Mother resets the sandbox at job start and stops it at job end. Humans can just exec. It idles out after 15 minutes without an exec; the next exec starts a new one automatically (about 75 s).

## 2. Commands

Run these from the worktree root. Give each tool call a 10-minute timeout.

| Goal | Command |
|---|---|
| One test (or module) | `rwx sandbox exec -- cargo test --lib <path::to::test>` |
| One integration test file | `rwx sandbox exec -- cargo test --test <name>` (a file in `tests/`) |
| Whole lib suite | `rwx sandbox exec -- cargo test --lib` |
| Full suite (lib, integration, doc tests) | `rwx sandbox exec -- cargo test` |
| Clippy, exactly as CI runs it | `rwx sandbox exec -- cargo clippy --all-targets -- -D warnings` |
| Python tooling | `rwx sandbox exec -- make python-test` (see §5 for how Linux differs from CI) |
| List sandboxes | `rwx sandbox list` |
| Rebuild from scratch | `rwx sandbox reset --wait` |
| Stop (frees the vCPUs) | `rwx sandbox stop` (check `rwx sandbox list` afterwards; if it still says `active`, run `stop` again) |
| Watch setup / open the run | `rwx sandbox exec --open -- true` |

## 3. Pre-PR check

```bash
rwx sandbox exec -- cargo clippy --all-targets -- -D warnings
rwx sandbox exec -- cargo test
rwx sandbox stop
```

GitHub's `Build & Lint` job is the required gate and stays the source of truth. There is no `.rwx/pr-checks.yml`: it would duplicate that job, which is free on this public repo.

## 4. Timings and cost

Measured 2026-10-16 on 4 vCPU / 16 GB (about $1.01 per awake hour: 4 × $0.00007/vCPU-s × 3600; 8 vCPU would be about $2.02). Wall times are the `time` of the whole `rwx sandbox exec`, so they include sync and connect overhead.

| Operation | Time |
|---|---|
| Cold start (new config: toolchain, deps layer and sandbox, system packages cached) | 3 min 20 s, then 4 min 54 s with a changed `deps` definition |
| Restart after stop / idle timeout, plus incremental `nostromo` build and `cargo test --lib mother::broker_client` | 73 s |
| Warm single test, nothing changed | 7.5-8 s |
| Warm edit loop (one-line edit in `src/lib.rs`, then the single test) | 62 s |
| `cargo test --lib` (1740 tests) | 36 s |
| `cargo clippy --all-targets -- -D warnings`, after the tests built | 29-32 s |
| Full `cargo test` from a fresh sandbox (86 test binaries, 3405 passed, 0 failed, 6 ignored) | 3 min 18 s |
| Full `cargo test` again with everything built | 2 min 16 s |
| `make python-test` | 43 s |
| `target/` after the full run | 35 GB (2.3 GB in the `deps` layer, 3.2 GB after only lib tests) |

The disk is 50 GB, so a full `cargo test` leaves about 19 GB free. `target/` is not synced and is discarded when the sandbox is reset or restarted from the layer.

The edit loop is dominated by recompiling the single large `nostromo` lib crate. 8 vCPU was not tried: the first full build took under the 8-minute threshold for it.

## 5. What cannot run here

RWX runs Linux only. These need macOS, Xcode or CryptoKit and run elsewhere:

- the Mac app tests (`make mac-test`)
- NostromoKit (`make kit-test`, uses CryptoKit)
- iOS builds
- the launch smoke
- `make mac-load-test`

See [`docs/ci.md`](ci.md) for how they run (a remote dispatch section is being added there; until then, the PR's CI).

**`make python-test` on Linux.** The suite passed in the sandbox on 2026-10-16: 1098 tests in 9 suites, 0 failures, 0 skips. CI still runs it on macOS on purpose (BSD `ps`, shellcheck and Swift-source policy tests; see the `python-tooling` comment in `.github/workflows/ci.yml`), and that job is authoritative. A green run here does not replace it.

## 6. `cargo fmt`

`cargo fmt --check` fails on `main` today (137 files differ) and CI doesn't check formatting. Don't run a whole-tree `cargo fmt` in a feature PR. `rustfmt` is installed in the sandbox so it's there if a formatting gate is added later.

## 7. TMPDIR

The sandbox sets `TMPDIR=/tmp`. Unix-socket tests (for example `mother::broker_client`) fail with a long `TMPDIR` because a socket path must fit `SUN_LEN`. Don't override it.

## 8. Sync rules

- Gitignored files don't sync. Don't expect `target/` to reach the sandbox, or its files to come back.
- **One exec at a time per worktree, and don't edit files while one runs.**
- If the sandbox writes a file you edited locally during an exec, your local version wins. The sandbox's change lands in a `*.rej` file plus `.rwx/sandboxes/patch-rejected.diff`, and the exec reports an error. Read the `.rej`, re-apply by hand if you want it, delete the `.rej` files, and re-run. **Never commit a `.rej`.**
- **Committed but unpushed work is visible.** The sandbox clones the pushed base commit and the CLI sends a patch for everything after it; in testing, a local commit that was never pushed showed up in the sandbox's `git log` and file contents. Mother workers can commit before they push.
- **Detached HEAD works** (Perri reviews from one). It starts its own sandbox (about 43 s with the layers cached), so stop it separately.
- A bare `touch` is not a change and is not synced; edit the content to see a rebuild.
- `.rwx/downloads/` (from `rwx logs`) and `.rwx/sandboxes/` are local and gitignored.

## 9. Egress policy

Stated, not enforced: RWX has no egress control. Commands run in the sandbox may reach only crates.io and static.rust-lang.org (and `sh.rustup.rs`), GitHub, and the Ubuntu apt mirrors. Tests must not call real Jira, GitHub, Anthropic or Mother endpoints; they use local mocks such as `wiremock`. Never send code or secrets anywhere else.

## 10. Troubleshooting

- **Not authenticated:** `rwx whoami` should show the `carefeed` organization.
- **Setup failed:** look at the run with `rwx sandbox exec --open -- true`, or pull a task's log with `rwx logs <task-id>`.
- **Wedged sandbox, or `connection refused` after a stop:** `rwx sandbox reset --wait`. A `stop` can report "timed out waiting for sandbox to fully stop" and leave it `active`; run `rwx sandbox stop` again.
- **RWX unreachable:** say so. Don't silently fall back to local `cargo`.
