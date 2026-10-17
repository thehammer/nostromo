"""Tests for the vendored Mother headless-crew contract and its drift guard.

    python3 -m unittest discover -s tests/mother_contract -v

(a) Hermetic: the manifest's sha256s match the vendored files, and the check
    notices a single flipped byte.
(b) Drift: `scripts/mother-contract.py check` against Mother's origin/main
    (skipped, with a reason, when there is no Mother checkout and online mode is
    off), plus hermetic proofs against a throwaway git repo that `check` exits 1
    naming the drifted file, 0 when in sync, 3 when upstream is unavailable, and
    that `vendor` writes byte-exact files and a correct manifest.
(c) When a Mother checkout and `jq` exist, Mother's own contract-check.sh accepts
    the vendored NDJSON.

Every hermetic test works on a COPY of the script + vendored dir in a temp tree
(the script resolves its paths from its own location), so none of them can touch
the real fixtures.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "mother-contract.py")
VENDOR_DIR = os.path.join(REPO_ROOT, "tests", "fixtures", "mother-contract")
MANIFEST = os.path.join(VENDOR_DIR, "MANIFEST.json")

FILES = ["gates_fix_pass.ndjson", "lens_wave.ndjson", "gate_hold_answered.ndjson"]
UPSTREAM_SUBDIR = os.path.join("plugins", "mother", "tests", "fixtures", "contract")

EXIT_OK, EXIT_DRIFT, EXIT_UNAVAILABLE = 0, 1, 3


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def mother_repo() -> str:
    return os.path.expanduser(os.environ.get("NOSTROMO_MOTHER_REPO", "~/Code/mother"))


class TempTree:
    """A temp dir mirroring `scripts/` + `tests/fixtures/mother-contract/`."""

    def __init__(self, test: unittest.TestCase):
        self.root = tempfile.mkdtemp(prefix="mother-contract-test-")
        test.addCleanup(shutil.rmtree, self.root, True)
        os.makedirs(os.path.join(self.root, "scripts"))
        shutil.copy(SCRIPT, os.path.join(self.root, "scripts", "mother-contract.py"))
        self.vendor = os.path.join(self.root, "tests", "fixtures", "mother-contract")
        shutil.copytree(VENDOR_DIR, self.vendor)
        self.script = os.path.join(self.root, "scripts", "mother-contract.py")

    def run(self, *args, mother=None, extra_env=None):
        env = dict(os.environ)
        env.pop("NOSTROMO_CONTRACT_DRIFT_ONLINE", None)  # never touch the network
        if mother is not None:
            env["NOSTROMO_MOTHER_REPO"] = mother
        env.update(extra_env or {})
        return subprocess.run(
            [sys.executable, self.script, *args], capture_output=True, text=True, env=env, timeout=60
        )


def git(repo, *args):
    env = dict(os.environ)
    env.update(
        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
    )
    return subprocess.run(
        ["git", "-C", repo, "-c", "commit.gpgsign=false", *args],
        check=True, capture_output=True, env=env,
    ).stdout


def make_upstream(test: unittest.TestCase, contents: dict, with_origin_main=True) -> str:
    """A temp git repo laid out like Mother, with `contents` committed as the contract fixtures."""
    repo = tempfile.mkdtemp(prefix="fake-mother-")
    test.addCleanup(shutil.rmtree, repo, True)
    git(repo, "init", "-q")
    fixtures = os.path.join(repo, UPSTREAM_SUBDIR)
    os.makedirs(fixtures)
    for name, data in contents.items():
        with open(os.path.join(fixtures, name), "wb") as f:
            f.write(data)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "contract fixtures")
    if with_origin_main:
        git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo


def vendored_contents() -> dict:
    return {name: read(os.path.join(VENDOR_DIR, name)) for name in FILES}


# ── (a) manifest, hermetic ────────────────────────────────────────────────────


class ManifestTests(unittest.TestCase):
    def test_manifest_names_exactly_the_three_contract_fixtures_with_provenance(self):
        manifest = json.loads(read(MANIFEST))
        self.assertEqual(sorted(manifest["files"]), sorted(FILES))
        self.assertEqual(manifest["mother_repo"], "thehammer/mother")
        self.assertEqual(manifest["mother_path"], "plugins/mother/tests/fixtures/contract")
        self.assertRegex(manifest["mother_commit"], r"^[0-9a-f]{40}$")

    def test_manifest_sha256s_match_the_vendored_files(self):
        manifest = json.loads(read(MANIFEST))
        for name, want in manifest["files"].items():
            self.assertEqual(sha256(read(os.path.join(VENDOR_DIR, name))), want, f"{name} differs from MANIFEST.json")

    def test_check_script_agrees_the_vendored_copy_matches_its_manifest(self):
        # Upstream is made unavailable on purpose: only the manifest leg can speak.
        tree = TempTree(self)
        r = tree.run("check", mother=os.path.join(tree.root, "no-such-mother"))
        self.assertEqual(r.returncode, EXIT_UNAVAILABLE, r.stdout + r.stderr)
        self.assertNotIn("drifted", r.stdout)

    def test_flipping_one_byte_of_a_vendored_fixture_fails_the_manifest_check(self):
        tree = TempTree(self)
        victim = os.path.join(tree.vendor, "lens_wave.ndjson")
        data = bytearray(read(victim))
        data[len(data) // 2] ^= 0x01
        with open(victim, "wb") as f:
            f.write(bytes(data))

        r = tree.run("check", mother=os.path.join(tree.root, "no-such-mother"))
        self.assertEqual(r.returncode, EXIT_DRIFT, r.stdout + r.stderr)
        self.assertIn("drifted: lens_wave.ndjson", r.stdout)
        for other in ("gates_fix_pass.ndjson", "gate_hold_answered.ndjson"):
            self.assertNotIn(f"drifted: {other}", r.stdout)

    def test_a_missing_vendored_fixture_fails_the_manifest_check(self):
        tree = TempTree(self)
        os.remove(os.path.join(tree.vendor, "gate_hold_answered.ndjson"))
        r = tree.run("check", mother=os.path.join(tree.root, "no-such-mother"))
        self.assertEqual(r.returncode, EXIT_DRIFT, r.stdout + r.stderr)
        self.assertIn("drifted: gate_hold_answered.ndjson", r.stdout)


# ── (b) upstream drift ────────────────────────────────────────────────────────


class UpstreamDriftTests(unittest.TestCase):
    def test_vendored_copy_matches_mothers_origin_main(self):
        r = subprocess.run(
            [sys.executable, SCRIPT, "check"], capture_output=True, text=True, timeout=120,
        )
        if r.returncode == EXIT_UNAVAILABLE:
            self.skipTest(f"upstream unavailable (no local Mother repo / origin/main, online mode off): {r.stdout.strip()}")
        self.assertEqual(
            r.returncode, EXIT_OK,
            "vendored contract has drifted from Mother; run `python3 scripts/mother-contract.py vendor` after `git -C ~/Code/mother fetch`\n"
            + r.stdout + r.stderr,
        )

    def test_check_exits_1_and_names_the_one_file_that_differs_upstream(self):
        upstream = vendored_contents()
        upstream["lens_wave.ndjson"] = upstream["lens_wave.ndjson"].replace(b"perri:ops-infra", b"perri:ops-INFRA", 1)
        self.assertNotEqual(upstream["lens_wave.ndjson"], vendored_contents()["lens_wave.ndjson"])
        repo = make_upstream(self, upstream)

        r = TempTree(self).run("check", mother=repo)
        self.assertEqual(r.returncode, EXIT_DRIFT, r.stdout + r.stderr)
        self.assertIn("drifted: lens_wave.ndjson", r.stdout)
        self.assertNotIn("drifted: gates_fix_pass.ndjson", r.stdout)
        self.assertNotIn("drifted: gate_hold_answered.ndjson", r.stdout)

    def test_check_names_every_file_that_differs_upstream(self):
        upstream = {name: data + b"\n" for name, data in vendored_contents().items()}
        repo = make_upstream(self, upstream)
        r = TempTree(self).run("check", mother=repo)
        self.assertEqual(r.returncode, EXIT_DRIFT, r.stdout + r.stderr)
        for name in FILES:
            self.assertIn(f"drifted: {name}", r.stdout)

    def test_check_exits_0_when_upstream_is_identical(self):
        repo = make_upstream(self, vendored_contents())
        r = TempTree(self).run("check", mother=repo)
        self.assertEqual(r.returncode, EXIT_OK, r.stdout + r.stderr)
        self.assertNotIn("drifted", r.stdout)

    def test_check_exits_3_and_says_skipped_when_the_mother_repo_does_not_exist(self):
        tree = TempTree(self)
        r = tree.run("check", mother=os.path.join(tree.root, "definitely-not-here"))
        self.assertEqual(r.returncode, EXIT_UNAVAILABLE, r.stdout + r.stderr)
        self.assertIn("skipped:", r.stdout + r.stderr)

    def test_check_exits_3_when_the_repo_has_no_origin_main_to_compare_with(self):
        repo = make_upstream(self, vendored_contents(), with_origin_main=False)
        r = TempTree(self).run("check", mother=repo)
        self.assertEqual(r.returncode, EXIT_UNAVAILABLE, r.stdout + r.stderr)
        self.assertIn("skipped:", r.stdout + r.stderr)
        self.assertNotIn("drifted", r.stdout)

    def test_a_manifest_mismatch_is_reported_as_drift_even_when_upstream_is_unavailable(self):
        tree = TempTree(self)
        with open(os.path.join(tree.vendor, "gates_fix_pass.ndjson"), "ab") as f:
            f.write(b" ")
        r = tree.run("check", mother=os.path.join(tree.root, "no-such-mother"))
        self.assertEqual(r.returncode, EXIT_DRIFT, r.stdout + r.stderr)
        self.assertIn("drifted: gates_fix_pass.ndjson", r.stdout)


class VendorTests(unittest.TestCase):
    # Bytes git must hand back untouched: CRLF, NUL, high bytes, no trailing newline.
    NASTY = b'{"a":1}\r\n{"b":"\xc3\xa9"}\n\x00\xff'

    def upstream_contents(self):
        return {
            "gates_fix_pass.ndjson": b'{"v":1}\n{"v":2}\n',
            "lens_wave.ndjson": self.NASTY,
            "gate_hold_answered.ndjson": b"",
        }

    def test_vendor_writes_byte_exact_files_and_a_correct_manifest(self):
        contents = self.upstream_contents()
        repo = make_upstream(self, contents)
        commit = git(repo, "rev-parse", "origin/main").decode().strip()
        tree = TempTree(self)
        # Start from different bytes so a no-op vendor cannot pass.
        for name in FILES:
            with open(os.path.join(tree.vendor, name), "wb") as f:
                f.write(b"stale\n")

        r = tree.run("vendor", mother=repo)
        self.assertEqual(r.returncode, EXIT_OK, r.stdout + r.stderr)

        for name, data in contents.items():
            self.assertEqual(read(os.path.join(tree.vendor, name)), data, f"{name} is not byte-exact")
        manifest = json.loads(read(os.path.join(tree.vendor, "MANIFEST.json")))
        self.assertEqual(manifest["mother_repo"], "thehammer/mother")
        self.assertEqual(manifest["mother_path"], "plugins/mother/tests/fixtures/contract")
        self.assertEqual(manifest["mother_commit"], commit)
        self.assertEqual(manifest["files"], {name: sha256(data) for name, data in contents.items()})

    def test_vendored_output_then_checks_clean_against_the_same_upstream(self):
        repo = make_upstream(self, self.upstream_contents())
        tree = TempTree(self)
        self.assertEqual(tree.run("vendor", mother=repo).returncode, EXIT_OK)
        r = tree.run("check", mother=repo)
        self.assertEqual(r.returncode, EXIT_OK, r.stdout + r.stderr)

    def test_vendor_reads_the_requested_ref_not_the_working_tree(self):
        contents = self.upstream_contents()
        repo = make_upstream(self, contents)
        # An uncommitted edit that origin/main does not include.
        edited = os.path.join(repo, UPSTREAM_SUBDIR, "gates_fix_pass.ndjson")
        with open(edited, "wb") as f:
            f.write(b"working tree edit\n")
        tree = TempTree(self)

        r = tree.run("vendor", mother=repo)
        self.assertEqual(r.returncode, EXIT_OK, r.stdout + r.stderr)
        self.assertEqual(read(os.path.join(tree.vendor, "gates_fix_pass.ndjson")), contents["gates_fix_pass.ndjson"])

    def test_vendor_honours_an_explicit_ref(self):
        contents = self.upstream_contents()
        repo = make_upstream(self, contents)
        first = git(repo, "rev-parse", "HEAD").decode().strip()
        changed = os.path.join(repo, UPSTREAM_SUBDIR, "lens_wave.ndjson")
        with open(changed, "wb") as f:
            f.write(b"second version\n")
        git(repo, "commit", "-q", "-am", "second")
        git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        tree = TempTree(self)

        r = tree.run("vendor", "--ref", first, mother=repo)
        self.assertEqual(r.returncode, EXIT_OK, r.stdout + r.stderr)
        self.assertEqual(read(os.path.join(tree.vendor, "lens_wave.ndjson")), self.NASTY)
        manifest = json.loads(read(os.path.join(tree.vendor, "MANIFEST.json")))
        self.assertEqual(manifest["mother_commit"], first)

    def test_vendor_exits_3_and_changes_nothing_when_the_mother_repo_is_missing(self):
        tree = TempTree(self)
        before = {name: read(os.path.join(tree.vendor, name)) for name in FILES + ["MANIFEST.json"]}
        r = tree.run("vendor", mother=os.path.join(tree.root, "nope"))
        self.assertEqual(r.returncode, EXIT_UNAVAILABLE, r.stdout + r.stderr)
        self.assertIn("skipped:", r.stdout + r.stderr)
        after = {name: read(os.path.join(tree.vendor, name)) for name in FILES + ["MANIFEST.json"]}
        self.assertEqual(before, after)


# ── (c) Mother's own checker accepts the vendored files ──────────────────────


class MothersOwnCheckerTests(unittest.TestCase):
    def test_mothers_contract_check_script_accepts_every_vendored_fixture(self):
        checker = os.path.join(mother_repo(), "plugins", "mother", "scripts", "contract-check.sh")
        if not os.path.isfile(checker):
            self.skipTest(f"no Mother checkout with contract-check.sh at {checker} (set NOSTROMO_MOTHER_REPO)")
        if shutil.which("jq") is None:
            self.skipTest("jq is not installed (contract-check.sh needs it)")
        files = [os.path.join(VENDOR_DIR, name) for name in FILES]
        r = subprocess.run(["bash", checker, *files], capture_output=True, text=True, cwd=REPO_ROOT, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
