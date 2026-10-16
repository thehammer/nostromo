"""Behavioral tests for the operator-app signing and pinning scripts (AP1b).

    scripts/sign-operator-app.sh <app>
    scripts/write-operator-pin.sh <app> <pin-file>

The daemon lets exactly one Nostromo.app answer an agent's decision: the one
whose running code matches a cdhash in the pin file (src/ipc/peer_verify.rs,
docs/operator-app-trust.md). That only means something if the pinned app can't
be made to run someone else's code, so the scripts guarantee:

  * sign-operator-app.sh signs ad-hoc with the hardened runtime and no
    entitlements, so DYLD_INSERT_LIBRARIES is ignored and nothing can attach;
  * write-operator-pin.sh pins one cdhash per architecture slice plus the
    identifier, mode 0600, atomically;
  * both refuse an app without the runtime, with an entitlement that reopens
    it (get-task-allow, allow-dyld-environment-variables,
    disable-library-validation), or with a foreign identifier.

The DYLD test depends on the host. The hardened runtime only blocks an
inserted library where the kernel enforces it (SIP enabled: CS_HARD, CS_KILL
and CS_ENFORCEMENT set on the process). GitHub's macOS runners run with SIP
disabled, so there the test instead proves the host is non-enforcing (the
kernel flags, and `csrutil status` independently) and that the injection did
happen, and prints that blocking is proven only on enforcing hosts. It is
never a skip, and an injection on an enforcing host always fails
(`dyld_verdict`, `DyldVerdictTests`).

Every test builds a scratch .app in a temp dir from a tiny C program; nothing
touches /Applications, ~/.nostromo or a running app. CI runs this on
macos-latest via `make python-test` and fails on any skip, so a missing tool
is a failure with a clear message, never a skip.

Run with:
    python3 -m unittest discover -s tests/operator_pin -v
"""

import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SIGN = os.path.join(REPO_ROOT, "scripts", "sign-operator-app.sh")
PIN = os.path.join(REPO_ROOT, "scripts", "write-operator-pin.sh")
CHECKS = os.path.join(REPO_ROOT, "scripts", "lib", "operator-app-checks.sh")

IDENTIFIER = "com.hammer.nostromo"
QA_IDENTIFIER = "com.hammer.nostromo.qa"
EXECUTABLE = "Nostromo"
MARKER_ENV = "OPERATOR_PIN_TEST_MARKER"

FORBIDDEN_ENTITLEMENTS = (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
)

CSFLAGS_ENV = "OPERATOR_PIN_TEST_CSFLAGS"

# Kernel code-signing status bits (<kern/cs_blobs.h>).
CS_HARD = 0x100
CS_KILL = 0x200
CS_ENFORCEMENT = 0x1000
CS_RUNTIME = 0x10000
# All three are set when the host enforces the hardened runtime (macOS with
# SIP enabled gives 0x22011311 for the signed app); none is set on a host
# with SIP disabled, such as GitHub's macOS runners (0x22010001).
CS_ENFORCING = CS_HARD | CS_KILL | CS_ENFORCEMENT

NON_ENFORCING_HOST_NOTE = (
    "host does not enforce the hardened runtime (SIP disabled): "
    "injection-blocking proven only on enforcing hosts"
)

# The scratch executable. When $OPERATOR_PIN_TEST_CSFLAGS names a file, it
# writes the kernel's code-signing status flags for itself there (csops
# CS_OPS_STATUS), so the DYLD test knows whether the host enforced the
# hardened runtime on it.
MAIN_C = r"""
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int main(void) {
    const char *path = getenv("OPERATOR_PIN_TEST_CSFLAGS");
    if (!path) return 0;
    uint32_t flags = 0;
    if (csops(getpid(), 0, &flags, sizeof flags) != 0) return 3;
    FILE *f = fopen(path, "w");
    if (!f) return 4;
    fprintf(f, "0x%08x\n", flags);
    fclose(f);
    return 0;
}
"""

# A library that proves it was loaded: its constructor writes the file named
# by $OPERATOR_PIN_TEST_MARKER.
INJECT_C = r"""
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void injected(void) {
    const char *path = getenv("OPERATOR_PIN_TEST_MARKER");
    if (!path) return;
    FILE *f = fopen(path, "w");
    if (f) { fputs("injected\n", f); fclose(f); }
}
"""

# Homebrew's bin dirs, so a shellcheck installed there is found even when the
# test runner's PATH is minimal.
_EXTRA_PATH = ["/opt/homebrew/bin", "/usr/local/bin"]


def _env():
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([env.get("PATH", "")] + _EXTRA_PATH)
    # Never let the scratch processes inherit an injection from the runner.
    for key in list(env):
        if key.startswith("DYLD_"):
            del env[key]
    return env


def _require(tool):
    path = shutil.which(tool, path=_env()["PATH"])
    if path is None:
        raise AssertionError(
            f"`{tool}` is not on PATH. These tests need cc, codesign, lipo and "
            f"shellcheck (CI: Xcode command-line tools + `brew install shellcheck`). "
            f"They must not be skipped."
        )
    return path


def _run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, env=kw.pop("env", _env()), **kw)


def _check(args, **kw):
    r = _run(args, **kw)
    if r.returncode != 0:
        raise AssertionError(f"{args} failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def signature_flag_names(code_directory_line):
    """The names in `codesign -dv`'s `flags=0x10002(adhoc,runtime)`."""
    m = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", code_directory_line)
    return m.group(1).split(",") if m else []


def dyld_verdict(injected, kernel_flags, signature_flags, csrutil_status):
    """Judge one DYLD_INSERT_LIBRARIES run of the runtime-signed operator app.

    Returns None when the result is the one the host should produce, or a
    message saying what is wrong. Never a pass for a real failure:

    * The host enforces the hardened runtime (CS_HARD, CS_KILL and
      CS_ENFORCEMENT all set on the process): the library must not have run.
    * The host enforces none of them: the runtime cannot block anything, so
      the test instead proves it is looking at exactly that host. The
      signature carries `runtime`, the kernel set CS_RUNTIME, `csrutil status`
      independently reports SIP disabled, and the library did run. Any other
      combination (no runtime, SIP reported enabled, no injection) fails.
    * Some but not all of the three bits: unexplained, so it fails.
    """
    enforced = kernel_flags & CS_ENFORCING
    facts = (f"kernel CS flags 0x{kernel_flags:08x}, signature flags {signature_flags}, "
             f"csrutil: {csrutil_status.strip()!r}, injected: {injected}")
    if enforced == CS_ENFORCING:
        return f"an inserted library ran inside the operator app on an enforcing host ({facts})" if injected else None
    if enforced:
        return f"the host enforces only part of the hardened runtime; cannot judge the run ({facts})"
    problems = []
    if "runtime" not in signature_flags:
        problems.append("the signature does not carry the hardened runtime")
    if not kernel_flags & CS_RUNTIME:
        problems.append("the kernel did not set CS_RUNTIME on the process")
    if not re.search(r"\bstatus:\s*disabled\.?\s*$", csrutil_status.strip()):
        problems.append("csrutil does not report SIP disabled, so the host is not shown to be non-enforcing")
    if not injected:
        problems.append("the library did not run, which a non-enforcing host should allow")
    if problems:
        return "non-enforcing host, but " + "; ".join(problems) + f" ({facts})"
    return None


class _Scratch(unittest.TestCase):
    """Builds scratch bundles. The C programs are compiled once per class."""

    @classmethod
    def setUpClass(cls):
        for tool in ("cc", "codesign", "lipo"):
            _require(tool)
        cls._build_dir = tempfile.mkdtemp(prefix="operator-pin-build-")
        src = os.path.join(cls._build_dir, "main.c")
        with open(src, "w") as f:
            f.write(MAIN_C)
        cls.universal_exe = os.path.join(cls._build_dir, "main-universal")
        _check(["cc", "-arch", "arm64", "-arch", "x86_64", "-o", cls.universal_exe, src])
        cls.thin_exe = os.path.join(cls._build_dir, "main-thin")
        _check(["cc", "-o", cls.thin_exe, src])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._build_dir, ignore_errors=True)

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="operator-pin-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self._n = 0

    # -- bundles --

    def make_app(self, identifier=IDENTIFIER, universal=True, name=None):
        self._n += 1
        app = os.path.join(self.tmp, name or f"App{self._n}", "Nostromo.app")
        macos = os.path.join(app, "Contents", "MacOS")
        os.makedirs(macos)
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump({
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": EXECUTABLE,
                "CFBundlePackageType": "APPL",
                "CFBundleName": "Nostromo",
            }, f)
        shutil.copy2(self.universal_exe if universal else self.thin_exe, os.path.join(macos, EXECUTABLE))
        return app

    @staticmethod
    def exe(app):
        return os.path.join(app, "Contents", "MacOS", EXECUTABLE)

    @staticmethod
    def archs(app):
        out = _check(["lipo", "-archs", _Scratch.exe(app)]).stdout.split()
        assert out, "lipo reported no architectures"
        return out

    def entitlements_plist(self, keys):
        path = os.path.join(self.tmp, f"ents-{self._n}-{len(keys)}.plist")
        with open(path, "wb") as f:
            plistlib.dump({k: True for k in keys}, f)
        return path

    def codesign(self, app, runtime, entitlements=None):
        args = ["codesign", "--force", "--sign", "-"]
        if runtime:
            args += ["--options", "runtime"]
        if entitlements:
            args += ["--entitlements", entitlements]
        _check(args + [app])

    # -- scripts --

    def sign(self, app):
        return _run(["bash", SIGN, app], cwd=REPO_ROOT)

    def pin(self, app, pin_path):
        return _run(["bash", PIN, app, pin_path], cwd=REPO_ROOT)

    def signed_app(self, **kw):
        app = self.make_app(**kw)
        r = self.sign(app)
        self.assertEqual(r.returncode, 0, f"sign-operator-app.sh failed:\n{r.stdout}\n{r.stderr}")
        return app

    # -- codesign facts --

    @staticmethod
    def code_directory(app, arch=None):
        args = ["codesign", "-dv"] + (["--arch", arch] if arch else []) + [app]
        info = _check(args).stderr
        line = next((l for l in info.splitlines() if l.startswith("CodeDirectory ")), None)
        assert line, f"no CodeDirectory line in:\n{info}"
        return line

    @staticmethod
    def entitlements_xml(app, arch):
        return _run(["codesign", "-d", "--entitlements", "-", "--xml", "--arch", arch, app]).stdout

    @staticmethod
    def cdhash(app, arch):
        info = _check(["codesign", "-dvvv", "--arch", arch, app]).stderr
        m = re.search(r"^CDHash=([0-9a-f]{40})$", info, re.M)
        assert m, f"no CDHash for {arch}:\n{info}"
        return m.group(1)

    def assertRefused(self, result, what):
        self.assertNotEqual(result.returncode, 0,
                            f"{what} must be refused, but the script succeeded:\n{result.stdout}")


# ---------------------------------------------------------------------------

class SignOperatorAppTests(_Scratch):

    def test_signs_every_slice_with_the_hardened_runtime(self):
        app = self.signed_app()
        for arch in self.archs(app):
            line = self.code_directory(app, arch)
            flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", line)
            self.assertIsNotNone(flags, line)
            self.assertIn("runtime", flags.group(1).split(","), f"{arch}: {line}")

    def test_signed_app_carries_no_forbidden_entitlement(self):
        app = self.signed_app()
        for arch in self.archs(app):
            ents = self.entitlements_xml(app, arch)
            for ent in FORBIDDEN_ENTITLEMENTS:
                self.assertNotIn(ent, ents, f"{arch} carries {ent}")

    def test_signed_app_passes_strict_verification(self):
        app = self.signed_app()
        r = _run(["codesign", "--verify", "--strict", app])
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_signed_app_keeps_its_identifier(self):
        app = self.signed_app()
        info = _check(["codesign", "-dv", app]).stderr
        self.assertIn(f"Identifier={IDENTIFIER}\n", info)

    def test_accepts_the_qa_identifier(self):
        app = self.signed_app(identifier=QA_IDENTIFIER)
        info = _check(["codesign", "-dv", app]).stderr
        self.assertIn(f"Identifier={QA_IDENTIFIER}\n", info)

    def test_refuses_a_foreign_identifier(self):
        app = self.make_app(identifier="com.example.other")
        r = self.sign(app)
        self.assertRefused(r, "a bundle with identifier com.example.other")
        self.assertIn("com.example.other", r.stderr, "the refusal should name the identifier")

    def test_refuses_an_identifier_that_only_starts_like_nostromo(self):
        for ident in ("com.hammer.nostromo.evil", "com.hammer.nostromoqa", "com.hammer"):
            with self.subTest(ident=ident):
                r = self.sign(self.make_app(identifier=ident))
                self.assertRefused(r, f"identifier {ident}")

    def test_refuses_a_path_that_is_not_a_bundle(self):
        r = self.sign(os.path.join(self.tmp, "missing.app"))
        self.assertRefused(r, "a missing bundle")


class DyldInjectionTests(_Scratch):
    """The point of the hardened runtime: a library forced in through
    DYLD_INSERT_LIBRARIES never runs inside the signed operator app."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        src = os.path.join(cls._build_dir, "inject.c")
        with open(src, "w") as f:
            f.write(INJECT_C)
        cls.dylib = os.path.join(cls._build_dir, "inject.dylib")
        _check(["cc", "-dynamiclib", "-o", cls.dylib, src])

    def run_injected(self, app):
        """Run `app` with the scratch library inserted. Returns whether the
        library ran, and the kernel's CS status flags for the process."""
        marker = os.path.join(self.tmp, f"injected-{self._n}")
        csflags = os.path.join(self.tmp, f"csflags-{self._n}")
        env = _env()
        env["DYLD_INSERT_LIBRARIES"] = self.dylib
        env[MARKER_ENV] = marker
        env[CSFLAGS_ENV] = csflags
        r = subprocess.run([self.exe(app)], capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(r.returncode, 0, f"the scratch executable did not run:\n{r.stderr}")
        with open(csflags) as f:
            flags = int(f.read().strip(), 16)
        return os.path.exists(marker), flags

    def assertInjectionBlocked(self, app):
        injected, kernel_flags = self.run_injected(app)
        signature = signature_flag_names(self.code_directory(app))
        csrutil = _run(["csrutil", "status"])
        problem = dyld_verdict(injected, kernel_flags, signature, csrutil.stdout + csrutil.stderr)
        if problem:
            self.fail(problem)
        if not kernel_flags & CS_ENFORCING:
            print(f"\n  {self.id()}: {NON_ENFORCING_HOST_NOTE}", file=sys.stderr)

    def test_control_a_plain_ad_hoc_app_is_injectable(self):
        # Proves the harness can see an injection at all; without it the next
        # tests would pass for any reason. Strict on every host.
        app = self.make_app(universal=False)
        self.codesign(app, runtime=False)
        injected, _ = self.run_injected(app)
        self.assertTrue(injected,
                        "control failed: DYLD_INSERT_LIBRARIES did not load into a plain ad-hoc app, "
                        "so this harness cannot detect injection")

    def test_the_signed_operator_app_does_not_load_an_inserted_library(self):
        self.assertInjectionBlocked(self.signed_app(universal=False))

    def test_the_signed_universal_operator_app_does_not_load_an_inserted_library(self):
        self.assertInjectionBlocked(self.signed_app(universal=True))


class DyldVerdictTests(unittest.TestCase):
    """The host-conditional DYLD judgement must never turn a real failure into
    a pass. Pure: no processes run."""

    ENFORCING = 0x22011311       # signed app, SIP enabled (macOS 26.5.1)
    NON_ENFORCING = 0x22010001   # signed app, SIP disabled (GitHub macos-26 runner)
    RUNTIME_SIG = ["adhoc", "runtime"]
    SIP_ON = "System Integrity Protection status: enabled.\n"
    SIP_OFF = "System Integrity Protection status: disabled.\n"

    def test_an_injection_on_an_enforcing_host_fails(self):
        for csrutil in (self.SIP_ON, self.SIP_OFF, ""):
            with self.subTest(csrutil=csrutil):
                problem = dyld_verdict(True, self.ENFORCING, self.RUNTIME_SIG, csrutil)
                self.assertIsNotNone(problem)
                self.assertIn("enforcing host", problem)

    def test_each_enforcement_bit_alone_cannot_excuse_an_injection(self):
        for missing in (CS_HARD, CS_KILL, CS_ENFORCEMENT):
            with self.subTest(missing=hex(missing)):
                self.assertIsNotNone(dyld_verdict(True, self.ENFORCING & ~missing, self.RUNTIME_SIG, self.SIP_OFF))
                self.assertIsNotNone(dyld_verdict(False, self.ENFORCING & ~missing, self.RUNTIME_SIG, self.SIP_OFF))

    def test_no_injection_on_an_enforcing_host_passes(self):
        self.assertIsNone(dyld_verdict(False, self.ENFORCING, self.RUNTIME_SIG, self.SIP_ON))

    def test_an_injection_on_a_host_shown_to_be_non_enforcing_passes(self):
        self.assertIsNone(dyld_verdict(True, self.NON_ENFORCING, self.RUNTIME_SIG, self.SIP_OFF))

    def test_a_non_enforcing_host_needs_csrutil_to_report_sip_disabled(self):
        for csrutil in (self.SIP_ON, "", "csrutil: command not found",
                        "System Integrity Protection status: unknown (Custom Configuration)."):
            with self.subTest(csrutil=csrutil):
                problem = dyld_verdict(True, self.NON_ENFORCING, self.RUNTIME_SIG, csrutil)
                self.assertIsNotNone(problem)
                self.assertIn("csrutil", problem)

    def test_a_non_enforcing_host_needs_the_runtime_in_the_signature_and_the_kernel(self):
        self.assertIsNotNone(dyld_verdict(True, self.NON_ENFORCING, ["adhoc"], self.SIP_OFF))
        self.assertIsNotNone(dyld_verdict(True, self.NON_ENFORCING & ~CS_RUNTIME, self.RUNTIME_SIG, self.SIP_OFF))

    def test_a_non_enforcing_host_must_show_the_injection(self):
        problem = dyld_verdict(False, self.NON_ENFORCING, self.RUNTIME_SIG, self.SIP_OFF)
        self.assertIsNotNone(problem)
        self.assertIn("did not run", problem)

    def test_signature_flag_names_parses_codesign_output(self):
        line = "CodeDirectory v=20500 size=242 flags=0x10002(adhoc,runtime) hashes=1+7 location=embedded"
        self.assertEqual(signature_flag_names(line), ["adhoc", "runtime"])
        self.assertEqual(signature_flag_names("CodeDirectory v=20400 flags=0x2(adhoc)"), ["adhoc"])
        self.assertEqual(signature_flag_names("garbage"), [])


class WriteOperatorPinTests(_Scratch):

    def setUp(self):
        super().setUp()
        self.pin_dir = os.path.join(self.tmp, "pin-dir")
        self.pin_path = os.path.join(self.pin_dir, "operator-app.pin")

    def parse(self):
        with open(self.pin_path) as f:
            lines = f.read().splitlines()
        comments = [l for l in lines if l.startswith("#")]
        body = [l for l in lines if l.strip() and not l.startswith("#")]
        return lines, comments, body

    def assert_pins(self, app, identifier=IDENTIFIER):
        r = self.pin(app, self.pin_path)
        self.assertEqual(r.returncode, 0, f"write-operator-pin.sh failed:\n{r.stdout}\n{r.stderr}")
        lines, comments, body = self.parse()
        archs = self.archs(app)
        expected_hashes = [self.cdhash(app, a) for a in archs]

        self.assertTrue(lines and lines[0].startswith("#"), f"the pin starts with header comments: {lines}")
        self.assertTrue(comments, "the pin has header comments")
        self.assertEqual([l for l in body if l.startswith("identifier ")], [f"identifier {identifier}"])
        pinned = [l.split(" ", 1)[1] for l in body if l.startswith("cdhash ")]
        self.assertEqual(len(pinned), len(archs), f"one cdhash per slice {archs}: {body}")
        self.assertEqual(sorted(pinned), sorted(expected_hashes))
        for h in pinned:
            self.assertRegex(h, r"^[0-9a-f]{40}$")
        self.assertEqual(sorted(body), sorted([f"identifier {identifier}"] + [f"cdhash {h}" for h in expected_hashes]),
                         f"no other content lines: {body}")
        return pinned

    def test_pins_one_cdhash_per_slice_of_a_universal_app(self):
        app = self.signed_app(universal=True)
        self.assertEqual(sorted(self.archs(app)), ["arm64", "x86_64"], "harness: expected a two-slice binary")
        pinned = self.assert_pins(app)
        self.assertEqual(len(set(pinned)), 2, "the two slices have distinct cdhashes")

    def test_pins_one_cdhash_for_a_single_slice_app(self):
        app = self.signed_app(universal=False)
        self.assertEqual(len(self.archs(app)), 1, "harness: expected a thin binary")
        self.assert_pins(app)

    def test_pins_the_qa_identifier(self):
        self.assert_pins(self.signed_app(identifier=QA_IDENTIFIER), identifier=QA_IDENTIFIER)

    def test_pin_file_is_private(self):
        self.assert_pins(self.signed_app())
        self.assertEqual(stat.S_IMODE(os.stat(self.pin_path).st_mode), 0o600)

    def test_pin_file_is_private_even_under_a_permissive_umask(self):
        app = self.signed_app()
        old = os.umask(0)
        try:
            r = self.pin(app, self.pin_path)
        finally:
            os.umask(old)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(stat.S_IMODE(os.stat(self.pin_path).st_mode), 0o600)

    def test_rewriting_replaces_the_previous_pin_and_leaves_no_temp_file(self):
        first = self.signed_app(universal=False)
        self.assert_pins(first)
        second = self.signed_app(universal=True)
        self.assert_pins(second)
        self.assertEqual(os.listdir(self.pin_dir), ["operator-app.pin"])

    # -- refusals: the pin is not written, and an existing one is untouched --

    PREVIOUS = b"# previous pin\nidentifier com.hammer.nostromo\ncdhash " + b"0" * 40 + b"\n"

    def seed_previous_pin(self):
        os.makedirs(self.pin_dir, exist_ok=True)
        with open(self.pin_path, "wb") as f:
            f.write(self.PREVIOUS)
        os.chmod(self.pin_path, 0o600)

    def assert_refused_and_untouched(self, app, what, because=None):
        """`because`: text the error must contain, so the refusal is for this cause."""
        self.seed_previous_pin()
        r = self.pin(app, self.pin_path)
        self.assertRefused(r, what)
        if because:
            self.assertIn(because, r.stderr, f"{what}: refused for another reason")
        self.assertEqual(_read_bytes(self.pin_path), self.PREVIOUS, f"{what}: the existing pin was changed")
        self.assertEqual(os.listdir(self.pin_dir), ["operator-app.pin"],
                         f"{what}: a temp file was left in the pin dir")

    def assert_refused_and_not_written(self, app, what):
        r = self.pin(app, self.pin_path)
        self.assertRefused(r, what)
        self.assertFalse(os.path.exists(self.pin_path), f"{what}: a pin was written")
        if os.path.isdir(self.pin_dir):
            self.assertEqual(os.listdir(self.pin_dir), [], f"{what}: a temp file was left in the pin dir")

    def plain_ad_hoc_app(self):
        app = self.make_app()
        self.codesign(app, runtime=False)
        return app

    def test_refuses_an_app_without_the_hardened_runtime(self):
        self.assert_refused_and_untouched(self.plain_ad_hoc_app(), "an ad-hoc app without the runtime",
                                          because="hardened runtime")

    def test_refuses_an_app_without_the_runtime_and_writes_no_pin(self):
        self.assert_refused_and_not_written(self.plain_ad_hoc_app(), "an ad-hoc app without the runtime")

    def test_refuses_an_app_with_one_slice_lacking_the_runtime(self):
        # A universal bundle that passes `codesign --verify --strict`, whose
        # native slice has the runtime but whose other slice does not. A check
        # of only the default architecture would pin it.
        with_rt = self.make_app(universal=True)
        self.codesign(with_rt, runtime=True)
        without_rt = self.make_app(universal=True)
        self.codesign(without_rt, runtime=False)
        host = _check(["uname", "-m"]).stdout.strip()
        other = "x86_64" if host == "arm64" else "arm64"
        host_slice = os.path.join(self.tmp, "host.bin")
        other_slice = os.path.join(self.tmp, "other.bin")
        _check(["lipo", "-thin", host, self.exe(with_rt), "-output", host_slice])
        _check(["lipo", "-thin", other, self.exe(without_rt), "-output", other_slice])
        _check(["lipo", "-create", host_slice, other_slice, "-output", self.exe(with_rt)])

        self.assertEqual(_run(["codesign", "--verify", "--strict", with_rt]).returncode, 0,
                         "harness: the mixed bundle should still verify")
        self.assertIn("runtime", self.code_directory(with_rt, host), "harness: host slice has the runtime")
        self.assertNotIn("runtime", self.code_directory(with_rt, other), "harness: other slice lacks it")

        self.assert_refused_and_untouched(with_rt, f"an app whose {other} slice lacks the runtime",
                                          because=f"({other}) is not signed with the hardened runtime")

    def test_refuses_an_app_with_a_reopening_entitlement(self):
        for ent in FORBIDDEN_ENTITLEMENTS:
            with self.subTest(entitlement=ent):
                app = self.make_app()
                self.codesign(app, runtime=True, entitlements=self.entitlements_plist([ent]))
                self.assertIn(ent, self.entitlements_xml(app, self.archs(app)[0]), "harness: entitlement applied")
                self.assert_refused_and_untouched(app, f"an app with {ent}", because=ent)

    def test_refuses_get_task_allow_and_writes_no_pin(self):
        app = self.make_app()
        self.codesign(app, runtime=True,
                      entitlements=self.entitlements_plist(["com.apple.security.get-task-allow"]))
        self.assert_refused_and_not_written(app, "an app with get-task-allow")

    def test_refuses_a_foreign_identifier(self):
        app = self.make_app(identifier="com.example.other")
        self.codesign(app, runtime=True)
        self.assert_refused_and_untouched(app, "an app with identifier com.example.other",
                                          because="com.example.other")

    def test_refuses_an_unsigned_app(self):
        self.assert_refused_and_untouched(self.make_app(), "an unsigned app")

    def test_refuses_an_app_whose_signature_no_longer_verifies(self):
        app = self.signed_app()
        with open(os.path.join(app, "Contents", "Info.plist"), "ab") as f:
            f.write(b"\n<!-- tampered -->\n")
        self.assert_refused_and_untouched(app, "a tampered app")

    def test_refuses_a_missing_bundle(self):
        self.assert_refused_and_untouched(os.path.join(self.tmp, "missing.app"), "a missing bundle")


class ShellcheckTests(unittest.TestCase):

    def test_the_scripts_are_shellcheck_clean(self):
        _require("shellcheck")
        r = _run(["shellcheck", "-x", "scripts/sign-operator-app.sh", "scripts/write-operator-pin.sh",
                  "scripts/lib/operator-app-checks.sh"], cwd=REPO_ROOT)
        self.assertEqual(r.returncode, 0, f"shellcheck findings:\n{r.stdout}\n{r.stderr}")


if __name__ == "__main__":
    unittest.main()
