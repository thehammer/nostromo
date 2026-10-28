#!/usr/bin/env python3
"""Decide whether a pull request's changed paths can affect the Swift CI jobs.

    git diff -z --name-only --no-renames HEAD^1 HEAD | python3 scripts/ci_changes.py
    # prints exactly one line: swift=true  or  swift=false

Used by the `changes` job in `.github/workflows/ci.yml`. The Swift jobs (Mac app
tests + compile gate, NostromoKit tests, iOS simulator build) are skipped only
when this prints `swift=false`.

Default-run by construction: a path is skippable only if it matches the short
allow-list below, and the Swift jobs run when ANY changed path is not
skippable. An unknown path, a malformed path or an empty list all mean "run".
Any internal error also prints `swift=true`. Adding a new top-level directory
therefore never silently skips the Mac compile gate.

Skippable paths (none can be read by a Swift build or test):
  * `docs/**` and `.claude/**`
  * `src/**` (the Rust daemon), except `src/activity/store.rs`, which a Mac test
    reads (ActivityStreamModelTests)
  * `tests/**/*.rs` outside `tests/fixtures/` (Swift tests read the fixtures)
  * `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`

`tests/ci_policy/test_ci_changes.py` scans the Swift sources and fails if one
starts reading a repo-relative path this allow-list would skip, so the list
cannot drift out from under the Swift tests.

Pass `--no-renames` to git: a rename is then two paths (old and new), so moving a
file out of `macOS/` into `docs/` still counts the deleted `macOS/` path.

Standard library only; Python 3.9+.
"""

import sys

_SKIPPABLE_PREFIXES = ("docs/", ".claude/")
_SKIPPABLE_FILES = frozenset(("Cargo.toml", "Cargo.lock", "rust-toolchain.toml"))
# Files under a skippable prefix that Swift tests nevertheless read.
_READ_BY_SWIFT = frozenset(("src/activity/store.rs",))
_FIXTURES_PREFIX = "tests/fixtures/"


def parse_nul_separated(data):
    """Split `git diff -z --name-only` output into paths."""
    text = data.decode("utf-8", errors="surrogateescape")
    return [p for p in text.split("\0") if p != ""]


def swift_jobs_needed(paths):
    """True unless every path is provably irrelevant to the Swift jobs."""
    if not paths:
        return True
    return not all(_is_skippable(p) for p in paths)


def _is_skippable(path):
    if not path or path.startswith("/") or "\\" in path:
        return False
    segments = path.split("/")
    # `.` and `..` segments, and empty ones (`docs//x`, leading `./`), mean the
    # path is not a plain repo-relative name: do not reason about it.
    if any(s in ("", ".", "..") for s in segments):
        return False
    if path in _SKIPPABLE_FILES:
        return True
    if path.startswith(_SKIPPABLE_PREFIXES):
        return True
    if path.startswith("src/"):
        return path not in _READ_BY_SWIFT
    if path.startswith("tests/"):
        return path.endswith(".rs") and not path.startswith(_FIXTURES_PREFIX)
    return False


def main():
    try:
        needed = swift_jobs_needed(parse_nul_separated(sys.stdin.buffer.read()))
    except Exception:  # fail safe: run everything
        needed = True
    print("swift=%s" % ("true" if needed else "false"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
