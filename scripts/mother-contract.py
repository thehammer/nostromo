#!/usr/bin/env python3
"""Vendor and drift-check Mother's headless-crew contract fixtures.

Nostromo keeps ONE copy of Mother's contract NDJSON fixtures in
tests/fixtures/mother-contract/ (Rust tests, Kit tests and the fake broker all
read it). This script refreshes that copy and checks it for drift.

    mother-contract.py vendor [--ref REF]
    mother-contract.py check  [--online]

`vendor` reads from the local Mother checkout ($NOSTROMO_MOTHER_REPO, default
~/Code/mother) with `git show REF:<path>` (REF defaults to origin/main). It never
fetches: fetch first. It writes the fixtures and MANIFEST.json.

`check` always verifies the manifest's sha256 per file. When the local Mother repo
has REF it also compares each vendored file with `git show REF:<path>`; with
--online (or NOSTROMO_CONTRACT_DRIFT_ONLINE=1) it compares with
raw.githubusercontent.com instead.

Exit codes: 0 in sync, 1 drift (`drifted: <name>` per file), 3 upstream
unavailable (`skipped: <reason>`).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VENDOR_DIR = os.path.join(REPO_ROOT, "tests", "fixtures", "mother-contract")
MANIFEST = os.path.join(VENDOR_DIR, "MANIFEST.json")

MOTHER_REPO = "thehammer/mother"
MOTHER_PATH = "plugins/mother/tests/fixtures/contract"
FILES = ["gates_fix_pass.ndjson", "lens_wave.ndjson", "gate_hold_answered.ndjson"]
DEFAULT_REF = "origin/main"
ONLINE_BASE = "https://raw.githubusercontent.com/thehammer/mother/main"

EXIT_OK, EXIT_DRIFT, EXIT_UNAVAILABLE = 0, 1, 3


class Unavailable(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def mother_repo_dir() -> str:
    return os.path.expanduser(os.environ.get("NOSTROMO_MOTHER_REPO", "~/Code/mother"))


def git(repo: str, *args: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", repo, *args], check=True, capture_output=True
        ).stdout
    except FileNotFoundError:
        raise Unavailable("git is not installed")
    except subprocess.CalledProcessError as e:
        raise Unavailable(e.stderr.decode(errors="replace").strip() or f"git {args[0]} failed")


def local_show(repo: str, ref: str, name: str) -> bytes:
    return git(repo, "show", f"{ref}:{MOTHER_PATH}/{name}")


def online_fetch(name: str) -> bytes:
    url = f"{ONLINE_BASE}/{MOTHER_PATH}/{name}"
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            return r.read()
    except Exception as e:  # network errors are "unavailable", never drift
        raise Unavailable(f"cannot fetch {url}: {e.__class__.__name__}")


def cmd_vendor(ref: str) -> int:
    repo = mother_repo_dir()
    if not os.path.isdir(repo):
        print(f"skipped: no Mother repo at {repo} (set NOSTROMO_MOTHER_REPO)", file=sys.stderr)
        return EXIT_UNAVAILABLE
    try:
        commit = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}").decode().strip()
        blobs = {name: local_show(repo, ref, name) for name in FILES}
    except Unavailable as e:
        print(f"skipped: {e}", file=sys.stderr)
        return EXIT_UNAVAILABLE
    os.makedirs(VENDOR_DIR, exist_ok=True)
    for name, data in blobs.items():
        with open(os.path.join(VENDOR_DIR, name), "wb") as f:
            f.write(data)
    manifest = {
        "mother_repo": MOTHER_REPO,
        "mother_path": MOTHER_PATH,
        "mother_commit": commit,
        "files": {name: sha256(data) for name, data in blobs.items()},
    }
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"vendored {len(blobs)} files from {MOTHER_REPO}@{commit[:12]}")
    return EXIT_OK


def read_vendored(name: str):
    try:
        with open(os.path.join(VENDOR_DIR, name), "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def check_manifest() -> list:
    """Names whose vendored bytes don't match the manifest."""
    with open(MANIFEST) as f:
        manifest = json.load(f)
    bad = []
    for name, want in manifest["files"].items():
        data = read_vendored(name)
        if data is None or sha256(data) != want:
            bad.append(name)
    return bad


def cmd_check(online: bool, ref: str) -> int:
    bad = check_manifest()
    for name in bad:
        print(f"drifted: {name} (does not match MANIFEST.json)")
    if bad:
        return EXIT_DRIFT

    online = online or os.environ.get("NOSTROMO_CONTRACT_DRIFT_ONLINE") == "1"
    if online:
        source, fetch = "raw.githubusercontent.com", online_fetch
    else:
        repo = mother_repo_dir()
        if not os.path.isdir(repo):
            print(f"skipped: no Mother repo at {repo} and online mode is off")
            return EXIT_UNAVAILABLE
        source = f"{repo}@{ref}"
        fetch = lambda name: local_show(repo, ref, name)  # noqa: E731

    drifted = []
    try:
        for name in FILES:
            if fetch(name) != read_vendored(name):
                drifted.append(name)
    except Unavailable as e:
        print(f"skipped: {e}")
        return EXIT_UNAVAILABLE
    for name in drifted:
        print(f"drifted: {name} (differs from {source})")
    return EXIT_DRIFT if drifted else EXIT_OK


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("vendor")
    v.add_argument("--ref", default=DEFAULT_REF)
    c = sub.add_parser("check")
    c.add_argument("--online", action="store_true")
    c.add_argument("--ref", default=DEFAULT_REF)
    args = p.parse_args(argv)
    if args.cmd == "vendor":
        return cmd_vendor(args.ref)
    return cmd_check(args.online, args.ref)


if __name__ == "__main__":
    sys.exit(main())
