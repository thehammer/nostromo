"""What the iOS L5 change (docs/ios-verification.md, "L5 - iOS simulator") must keep true.

Five groups, each a plain check function over file text returning a list of violations (empty ==
pass), a real-tree test, and "bites" tests that mutate the real text (or feed nothing) to prove
the check can fail:

1. ci.yml job `ios-simulator-build` keeps its identity: the required-check name, `needs`, runner.
2. Its steps: the generic simulator build stays, `make ios-test` follows it, every make / Xcode
   command-line step is gated on the Swift path classifier (so PRs that touch no Swift run
   nothing on the ubuntu fallback), nothing is `continue-on-error`, the failure log is uploaded.
3. The Makefile `ios-test` target: pipefail, project, scheme, named destination, no signing,
   scratch-volume derived data, a no-tests guard, `.PHONY`, default simulator name.
4. The shared `Nostromo` scheme: well-formed, tests Testable, blueprint ids match the project,
   `ios-build` and the generic build do not build the tests for running.
5. The NostromoTests target is a hosted unit-test bundle (TEST_HOST + BUNDLE_LOADER), depending on
   the app.

Helpers are copied from test_ci_dispatch.py (each policy dir is run under `discover -s <dir>`, so
nothing is imported across files). Stdlib only; no skip mechanism (CI greps for skips).

Run with:
    python3 -I -m unittest discover -s tests/ci_policy -v
"""

import ast
import os
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CI_YML = os.path.join(ROOT, ".github", "workflows", "ci.yml")
MAKEFILE = os.path.join(ROOT, "Makefile")
PBXPROJ = os.path.join(ROOT, "iOS", "Nostromo.xcodeproj", "project.pbxproj")
SCHEME = os.path.join(ROOT, "iOS", "Nostromo.xcodeproj", "xcshareddata", "xcschemes", "Nostromo.xcscheme")

JOB = "ios-simulator-build"
REQUIRED_NAME = "iOS simulator build"
SWIFT_GATE = "needs.changes.outputs.swift == 'true'"
SWIFT_RUNS_ON = "${{ needs.changes.outputs.swift == 'true' && 'macos-26' || 'ubuntu-24.04' }}"
DISPATCH_NAME_RE = re.compile(
    r"^\s*\$\{\{\s*github\.event_name\s*==\s*'workflow_dispatch'\s*&&\s*'(?P<dispatch>[^']*)'"
    r"\s*\|\|\s*'(?P<plain>[^']*)'\s*\}\}\s*$"
)
# Commands that need the macOS runner (Xcode tooling or the make targets that wrap it).
XCODE_CMD_RE = re.compile(r"\b(make|xcode" + "build|xcode-select)\\b")
APP, TESTS = "Nostromo", "NostromoTests"


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


# --------------------------------------------------------------------------
# ci.yml helpers (copied from test_ci_dispatch.py, plus step splitting)
# --------------------------------------------------------------------------

def _strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def _indent(l):
    return len(l) - len(l.lstrip(" "))


def _top_level_block(text, key):
    lines = _strip_comments(text).splitlines()
    for i, l in enumerate(lines):
        if re.match(r"^%s:\s*$" % re.escape(key), l):
            body = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    continue
                if _indent(nxt) == 0:
                    break
                body.append(nxt)
            return body
    return None


def _job_blocks(text):
    body = _top_level_block(text, "jobs")
    if body is None:
        return {}
    blocks, current = {}, None
    for l in body:
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", l)
        if m:
            current = m.group(1)
            blocks[current] = []
        elif current is not None:
            blocks[current].append(l)
    return {k: "\n".join(v) for k, v in blocks.items()}


def _job_level(block, key):
    m = re.search(r"(?m)^    %s:[ \t]*(.*?)[ \t]*$" % re.escape(key), block)
    return None if m is None else m.group(1)


def _steps(block):
    """Each step of the job as a dict: text, name, if, run (the run body, empty if `uses:`)."""
    lines = block.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"^    steps:\s*$", l)), None)
    if start is None:
        return []
    chunks, cur = [], None
    for l in lines[start + 1:]:
        if re.match(r"^      - ", l):
            cur = [l]
            chunks.append(cur)
        elif cur is not None:
            cur.append(l)
    steps = []
    for c in chunks:
        text = "\n".join(c)
        name = re.search(r"(?m)^\s+(?:- )?name:[ \t]*(.*?)[ \t]*$", text)
        cond = re.search(r"(?m)^\s+(?:- )?if:[ \t]*(.*?)[ \t]*$", text)
        run = re.search(r"(?m)^\s+(?:- )?run:(.*)\Z", text, re.S)
        steps.append({
            "text": text,
            "name": name.group(1) if name else "",
            "if": cond.group(1) if cond else None,
            "run": run.group(1) if run else "",
        })
    return steps


def _job(text):
    return _job_blocks(text).get(JOB)


# --------------------------------------------------------------------------
# Group 1: job identity
# --------------------------------------------------------------------------

def check_job_identity(text):
    block = _job(text)
    if block is None:
        return ["job `%s` is missing" % JOB]
    out = []
    raw = _job_level(block, "name")
    m = DISPATCH_NAME_RE.match(raw or "")
    if m is None:
        out.append("job name %r is not the dispatch-suffix expression" % raw)
    elif m.group("plain") != REQUIRED_NAME:
        out.append("non-dispatch name is %r, the required check is %r" % (m.group("plain"), REQUIRED_NAME))
    needs = re.findall(r"[A-Za-z0-9_-]+", _job_level(block, "needs") or "")
    if "swift-tests-kit" not in needs:
        out.append("job no longer `needs` swift-tests-kit (got %r)" % needs)
    if _job_level(block, "runs-on") != SWIFT_RUNS_ON:
        out.append("runs-on is %r, expected the ubuntu-fallback expression %r"
                   % (_job_level(block, "runs-on"), SWIFT_RUNS_ON))
    return out


# --------------------------------------------------------------------------
# Group 2: steps
# --------------------------------------------------------------------------

def check_job_steps(text):
    block = _job(text)
    if block is None:
        return ["job `%s` is missing" % JOB]
    out = []
    steps = _steps(block)
    if "continue-on-error" in block:
        out.append("job or a step uses continue-on-error; a failing iOS build or test must fail the check")

    build = [i for i, s in enumerate(steps) if "Build for iOS Simulator" in s["name"]]
    if not build:
        out.append("no step named like 'Build for iOS Simulator'")
    else:
        run = steps[build[0]]["run"]
        for needle in ("generic/platform=iOS Simulator", "CODE_SIGNING_ALLOWED=NO"):
            if needle not in run:
                out.append("build step no longer contains %r" % needle)

    tests = [i for i, s in enumerate(steps) if re.search(r"\bmake\s+ios-test\b", s["run"])]
    if not tests:
        out.append("no step runs `make ios-test`")
    else:
        if build and tests[0] <= build[0]:
            out.append("`make ios-test` must come after the build step")
        if steps[tests[0]]["if"] != SWIFT_GATE:
            out.append("`make ios-test` step `if:` is %r, expected %r" % (steps[tests[0]]["if"], SWIFT_GATE))

    for s in steps:
        if XCODE_CMD_RE.search(s["run"]) and SWIFT_GATE not in (s["if"] or ""):
            out.append("step %r runs make/Xcode tooling without the Swift gate (`if:` is %r)"
                       % (s["name"], s["if"]))

    uploads = [s for s in steps if "actions/upload-artifact" in s["text"]]
    if not uploads:
        out.append("no upload-artifact step for the failure logs")
    else:
        u = uploads[0]
        if "iOS/build/ios-test-full.log" not in u["text"]:
            out.append("log upload no longer includes iOS/build/ios-test-full.log")
        if "failure()" not in (u["if"] or ""):
            out.append("log upload is not gated on failure()")
    return out


# --------------------------------------------------------------------------
# Group 3: Makefile ios-test
# --------------------------------------------------------------------------

def _recipe(make_text, target):
    lines = make_text.splitlines()
    for i, l in enumerate(lines):
        if re.match(r"^%s:" % re.escape(target), l):
            body = []
            for nxt in lines[i + 1:]:
                if nxt.startswith("\t") or not nxt.strip():
                    body.append(nxt)
                else:
                    break
            return "\n".join(body)
    return None


def check_makefile_ios_test(text):
    recipe = _recipe(text, "ios-test")
    if recipe is None:
        return ["Makefile has no `ios-test` target"]
    out = []
    for needle in ("set -o pipefail", "iOS/Nostromo.xcodeproj", "-scheme Nostromo",
                   "platform=iOS Simulator,name=$(IOS_SIM_NAME)", "CODE_SIGN_IDENTITY=-",
                   "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=YES"):
        if needle not in recipe:
            out.append("ios-test recipe lacks %r" % needle)
    # Ad hoc signing gives the hosted app entitlements (Keychain) with no Apple team; a team would
    # make the run depend on a provisioning profile the runner does not have.
    if "CODE_SIGNING_ALLOWED=NO" in recipe:
        out.append("ios-test must sign ad hoc: an unsigned host has no entitlements (Keychain -34018)")
    if "DEVELOPMENT_TEAM" in recipe:
        out.append("ios-test must not name a DEVELOPMENT_TEAM (ad hoc signing, no team)")
    if '-derivedDataPath "$(IOS_TEST_DERIVED)"' not in recipe:
        out.append("ios-test must use -derivedDataPath \"$(IOS_TEST_DERIVED)\" (never a fixed in-repo path)")
    guard = [l for l in recipe.splitlines() if "Executed [1-9]" in l and "grep" in l]
    if not guard or not any("exit 1" in l for l in guard):
        out.append("ios-test lacks a no-tests guard: a grep for `Executed [1-9]` that exits 1")
    if not any(re.match(r"^\.PHONY:.*(?<![\w-])ios-test(?![\w-])", l) for l in text.splitlines()):
        out.append("ios-test is not in .PHONY")
    if not re.search(r"(?m)^IOS_SIM_NAME \?= iPhone 17$", text):
        out.append("IOS_SIM_NAME default is not `iPhone 17`")
    m = re.search(
        r"ifneq \(\$\(wildcard /Volumes/Scratch/\.\),\)\nIOS_TEST_DERIVED \?= (.+)\nelse\n"
        r"IOS_TEST_DERIVED \?= (.+)\nendif", text)
    if m is None:
        out.append("no `ifneq ($(wildcard /Volumes/Scratch/.),)` branch defining IOS_TEST_DERIVED")
    else:
        if not m.group(1).startswith("/Volumes/Scratch/"):
            out.append("with the scratch volume mounted IOS_TEST_DERIVED is %r, not under /Volumes/Scratch" % m.group(1))
        if m.group(2).startswith("/Volumes/"):
            out.append("without the scratch volume IOS_TEST_DERIVED still points at /Volumes: %r" % m.group(2))
    return out


# --------------------------------------------------------------------------
# pbxproj helpers (block parser copied from test_mac_test_target_membership.py)
# --------------------------------------------------------------------------

def _block(text, start):
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
    raise ValueError("unbalanced braces")


def _obj(text, ident):
    m = re.search(r"\n\t\t%s /\* [^\n]*? \*/ = \{" % re.escape(ident), text)
    return None if m is None else _block(text, m.start())


def _native_targets(pbx):
    """{blueprint id: name} for every PBXNativeTarget."""
    out = {}
    for m in re.finditer(r"\n\t\t(\w+) /\* [^\n]*? \*/ = \{\s*isa = PBXNativeTarget;", pbx):
        body = _block(pbx, m.start())
        n = re.search(r"\bname = ([^;]+);", body)
        out[m.group(1)] = n.group(1).strip().strip('"') if n else None
    return out


def _target_body(pbx, name):
    for ident, n in _native_targets(pbx).items():
        if n == name:
            return ident, _obj(pbx, ident)
    return None, None


def _setting(settings_body, key):
    m = re.search(r"\b%s = ([^;]+);" % re.escape(key), settings_body)
    return None if m is None else m.group(1).strip().strip('"')


# --------------------------------------------------------------------------
# Group 4: shared scheme
# --------------------------------------------------------------------------

def check_scheme(scheme_text, pbx):
    if scheme_text is None:
        return ["shared scheme Nostromo.xcscheme is missing"]
    try:
        root = ET.fromstring(scheme_text)
    except ET.ParseError as e:
        return ["scheme is not well-formed XML: %s" % e]
    out = []
    targets = _native_targets(pbx)
    for ref in root.iter("BuildableReference"):
        ident, name = ref.get("BlueprintIdentifier"), ref.get("BlueprintName")
        if targets.get(ident) != name:
            out.append("BuildableReference %s/%s matches no PBXNativeTarget of that id and name" % (ident, name))

    def entry(name):
        for e in root.iter("BuildActionEntry"):
            r = e.find("BuildableReference")
            if r is not None and r.get("BlueprintName") == name:
                return e
        return None

    app = entry(APP)
    if app is None:
        out.append("no build entry for the app target")
    else:
        for k in ("buildForTesting", "buildForRunning", "buildForArchiving"):
            if app.get(k) != "YES":
                out.append("app build entry has %s=%r, must stay YES" % (k, app.get(k)))
    tests = entry(TESTS)
    if tests is None:
        out.append("no build entry for NostromoTests")
    else:
        if tests.get("buildForTesting") != "YES":
            out.append("tests build entry must have buildForTesting=YES")
        for k in ("buildForRunning", "buildForProfiling", "buildForArchiving", "buildForAnalyzing"):
            if tests.get(k) != "NO":
                out.append("tests build entry has %s=%r, must be NO (tests only build for testing)" % (k, tests.get(k)))
    testables = list(root.iter("TestableReference"))
    names = []
    for t in testables:
        for r in t.iter("BuildableReference"):
            ident, name = r.get("BlueprintIdentifier"), r.get("BlueprintName")
            names.append(name)
            if targets.get(ident) != name:
                out.append("Testable %s/%s matches no PBXNativeTarget of that id and name" % (ident, name))
            if t.get("skipped") == "YES":
                out.append("Testable %s is marked skipped" % name)
    if TESTS not in names:
        out.append("TestAction has no Testable for NostromoTests")
    test_action = root.find("TestAction")
    if test_action is None:
        out.append("scheme has no TestAction")
    elif test_action.get("buildConfiguration") != "Debug":
        out.append("TestAction buildConfiguration is %r, must be Debug (ENABLE_TESTABILITY is Debug-only, "
                   "so `@testable import Nostromo` would break)" % test_action.get("buildConfiguration"))
    tests_id = next((i for i, n in targets.items() if n == TESTS), None)
    app_id = next((i for i, n in targets.items() if n == APP), None)
    attrs = re.search(r"TargetAttributes = \{", pbx)
    attr_body = _block(pbx, attrs.start()) if attrs else ""
    m = re.search(r"\b%s = \{(.*?)\};" % re.escape(tests_id or "?"), attr_body, re.S)
    if m is None or _setting(m.group(1), "TestTargetID") != app_id:
        out.append("PBXProject TargetAttributes for NostromoTests lacks TestTargetID = the app target id (%s)" % app_id)
    return out


# --------------------------------------------------------------------------
# Group 5: hosted unit-test target
# --------------------------------------------------------------------------

def check_hosted_target(pbx):
    _tid, body = _target_body(pbx, TESTS)
    if body is None:
        return ["no NostromoTests native target"]
    out = []
    if not re.search(r'productType = "com\.apple\.product-type\.bundle\.unit-test";', body):
        out.append("NostromoTests is not a com.apple.product-type.bundle.unit-test")
    app_id, _ = _target_body(pbx, APP)
    deps = re.search(r"dependencies = \((.*?)\);", body, re.S)
    dep_ids = re.findall(r"(\w+) /\*", deps.group(1)) if deps else []
    has_dep = False
    for d in dep_ids:
        db = _obj(pbx, d) or ""
        if "isa = PBXTargetDependency" in db and re.search(r"\btarget = %s\b" % re.escape(app_id or "?"), db):
            has_dep = True
    if not has_dep:
        out.append("NostromoTests has no PBXTargetDependency on the app target")
    cl = re.search(r"buildConfigurationList = (\w+)", body)
    cl_body = _obj(pbx, cl.group(1)) if cl else None
    configs = []
    if cl_body:
        bc = re.search(r"buildConfigurations = \((.*?)\);", cl_body, re.S)
        configs = re.findall(r"(\w+) /\*", bc.group(1)) if bc else []
    if not configs:
        out.append("NostromoTests has no build configurations")
    for c in configs:
        cb = _obj(pbx, c) or ""
        if _setting(cb, "TEST_HOST") != "$(BUILT_PRODUCTS_DIR)/Nostromo.app/Nostromo":
            out.append("config %s: TEST_HOST is %r (host-less bundle: L5 would be vacuous)" % (c, _setting(cb, "TEST_HOST")))
        if _setting(cb, "BUNDLE_LOADER") != "$(TEST_HOST)":
            out.append("config %s: BUNDLE_LOADER is %r, expected $(TEST_HOST)" % (c, _setting(cb, "BUNDLE_LOADER")))
    return out


# --------------------------------------------------------------------------
# Real-tree tests
# --------------------------------------------------------------------------

class RealTreeTests(unittest.TestCase):
    def test_ios_job_keeps_its_required_name_needs_and_runner(self):
        self.assertEqual(check_job_identity(_read(CI_YML)), [])

    def test_ios_job_builds_then_runs_gated_hosted_tests_and_uploads_failure_logs(self):
        self.assertEqual(check_job_steps(_read(CI_YML)), [])

    def test_makefile_ios_test_target_is_hermetic_scratch_aware_and_guards_against_zero_tests(self):
        self.assertEqual(check_makefile_ios_test(_read(MAKEFILE)), [])

    def test_scheme_tests_in_debug_and_project_links_the_test_target_to_the_app(self):
        scheme, pbx = _read(SCHEME), _read(PBXPROJ)
        self.assertEqual(ET.fromstring(scheme).find("TestAction").get("buildConfiguration"), "Debug")
        self.assertEqual(check_scheme(scheme, pbx), [])

    def test_shared_scheme_tests_the_bundle_and_builds_it_for_testing_only(self):
        self.assertTrue(os.path.exists(SCHEME), "shared scheme file is missing")
        self.assertEqual(check_scheme(_read(SCHEME), _read(PBXPROJ)), [])

    def test_nostromo_tests_is_a_hosted_unit_test_bundle_depending_on_the_app(self):
        self.assertEqual(check_hosted_target(_read(PBXPROJ)), [])


# --------------------------------------------------------------------------
# Bites tests
# --------------------------------------------------------------------------

def _mutate(text, old, new, after=None):
    """Replace the first `old` (after the first `after` anchor, if given), asserting it applied."""
    i = text.index(after) if after else 0
    out = text[:i] + text[i:].replace(old, new, 1)
    assert out != text, "mutation did not apply: %r" % old
    return out


class JobIdentityBites(unittest.TestCase):
    def setUp(self):
        self.ci = _read(CI_YML)

    def test_missing_job(self):
        self.assertTrue(check_job_identity(""))

    def test_renamed_required_check(self):
        m = _mutate(self.ci, "|| 'iOS simulator build' }}", "|| 'iOS build' }}")
        self.assertTrue(check_job_identity(m))

    def test_dropped_kit_dependency(self):
        m = _mutate(self.ci, "needs: [changes, swift-tests-kit]\n    if: ${{ !cancelled() && (github.event_name != 'workflow_dispatch' || contains(fromJSON('[\"all\",\"swift\",\"ios\"]')",
                    "needs: [changes]\n    if: ${{ !cancelled() && (github.event_name != 'workflow_dispatch' || contains(fromJSON('[\"all\",\"swift\",\"ios\"]')")
        self.assertTrue(check_job_identity(m))

    def test_runner_fixed_to_macos(self):
        j = self.ci.index("  ios-simulator-build:")
        tail = _mutate(self.ci[j:], SWIFT_RUNS_ON, "macos-26")
        self.assertTrue(check_job_identity(self.ci[:j] + tail))


class JobStepsBites(unittest.TestCase):
    def setUp(self):
        self.ci = _read(CI_YML)

    def test_missing_job(self):
        self.assertTrue(check_job_steps(""))

    def test_make_step_without_the_swift_gate(self):
        m = _mutate(self.ci, "iOS hosted tests (make ios-test)\n        if: needs.changes.outputs.swift == 'true'\n",
                    "iOS hosted tests (make ios-test)\n")
        self.assertTrue(check_job_steps(m))

    def test_make_step_removed(self):
        m = _mutate(self.ci, "run: make ios-test", "run: echo nothing")
        self.assertTrue(check_job_steps(m))

    def test_build_step_missing_so_ordering_cannot_hold(self):
        m = _mutate(self.ci, "name: Build for iOS Simulator", "name: Compile later")
        self.assertTrue(check_job_steps(m))

    def test_make_step_before_the_build_step(self):
        a = self.ci.index("      - name: iOS hosted tests (make ios-test)")
        b = self.ci.index("      - name: Upload build and test logs")
        make_step = self.ci[a:b]
        without = self.ci[:a] + self.ci[b:]
        c = without.index("      - name: Build for iOS Simulator")
        self.assertTrue(check_job_steps(without[:c] + make_step + without[c:]))

    def test_continue_on_error(self):
        m = _mutate(self.ci, "run: make ios-test", "continue-on-error: true\n        run: make ios-test")
        self.assertTrue(check_job_steps(m))

    def test_build_step_loses_generic_destination_or_signing_flag(self):
        self.assertTrue(check_job_steps(_mutate(self.ci, "generic/platform=iOS Simulator", "platform=iOS Simulator,name=X")))
        self.assertTrue(check_job_steps(_mutate(self.ci, "CODE_SIGNING_ALLOWED=NO build", "build")))

    def test_ungated_toolchain_step(self):
        m = _mutate(self.ci, "      - name: Log toolchain and OS versions\n        if: needs.changes.outputs.swift == 'true'\n",
                    "      - name: Log toolchain and OS versions\n", after="  ios-simulator-build:")
        self.assertTrue(check_job_steps(m))

    def test_upload_loses_the_test_log_or_the_failure_gate(self):
        self.assertTrue(check_job_steps(_mutate(self.ci, "iOS/build/ios-test-full.log", "iOS/build/other.log", after="  ios-simulator-build:")))
        self.assertTrue(check_job_steps(_mutate(self.ci, "swift == 'true' && failure()", "swift == 'true' && always()", after="  ios-simulator-build:")))


class MakefileBites(unittest.TestCase):
    def setUp(self):
        self.mk = _read(MAKEFILE)

    def test_missing_target(self):
        self.assertTrue(check_makefile_ios_test(""))

    def test_each_required_recipe_element_is_enforced(self):
        for old, new in (
            ("set -o pipefail; mkdir -p iOS/build", "mkdir -p iOS/build"),
            ("-project iOS/Nostromo.xcodeproj", "-project iOS/Other.xcodeproj"),
            ("-scheme Nostromo \\\n\t  -destination 'platform=iOS Simulator", "-scheme Other \\\n\t  -destination 'platform=iOS Simulator"),
            ("name=$(IOS_SIM_NAME)'", "name=iPhone 17'"),
            ("  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1 | tee iOS/build/ios-test-full.log", "  2>&1 | tee iOS/build/ios-test-full.log"),
            ("CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1", "CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1"),
            ("CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1", "CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1"),
            ("CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1", "CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=ABCDE12345 2>&1"),
            ('-derivedDataPath "$(IOS_TEST_DERIVED)"', "-derivedDataPath iOS/build/derived"),
        ):
            self.assertTrue(check_makefile_ios_test(_mutate(self.mk, old, new)), old)

    def test_no_tests_guard_removed_or_defanged(self):
        self.assertTrue(check_makefile_ios_test(_mutate(self.mk, "Executed [1-9][0-9]* tests?", "Executed [0-9]+ tests?")))
        self.assertTrue(check_makefile_ios_test(_mutate(self.mk, '{ echo "ios-test: no tests executed (see iOS/build/ios-test-full.log)"; exit 1; }', "true")))

    def test_not_phony(self):
        m = _mutate(self.mk, "kit-test ios-build ios-test ios-install", "kit-test ios-build ios-install")
        self.assertTrue(check_makefile_ios_test(m))

    def test_default_simulator_name_changed(self):
        self.assertTrue(check_makefile_ios_test(_mutate(self.mk, "IOS_SIM_NAME ?= iPhone 17", "IOS_SIM_NAME ?= iPhone 16")))

    def test_scratch_branch_removed_or_pointed_elsewhere(self):
        self.assertTrue(check_makefile_ios_test(_mutate(self.mk, "IOS_TEST_DERIVED ?= /Volumes/Scratch/", "IOS_TEST_DERIVED ?= iOS/build/x/")))
        self.assertTrue(check_makefile_ios_test(_mutate(self.mk, "ifneq ($(wildcard /Volumes/Scratch/.),)\nIOS_TEST_DERIVED", "ifneq ($(wildcard /Volumes/Nope/.),)\nIOS_TEST_DERIVED")))


class SchemeBites(unittest.TestCase):
    def setUp(self):
        self.scheme, self.pbx = _read(SCHEME), _read(PBXPROJ)

    def test_missing_scheme(self):
        self.assertTrue(check_scheme(None, self.pbx))

    def test_malformed_xml(self):
        self.assertTrue(check_scheme(self.scheme.replace("</Scheme>", ""), self.pbx))

    def test_testable_removed(self):
        a = self.scheme.index("<Testables>")
        b = self.scheme.index("</Testables>") + len("</Testables>")
        self.assertTrue(check_scheme(self.scheme[:a] + "<Testables></Testables>" + self.scheme[b:], self.pbx))

    def test_testable_skipped(self):
        self.assertTrue(check_scheme(_mutate(self.scheme, 'skipped = "NO"', 'skipped = "YES"'), self.pbx))

    def test_blueprint_id_not_in_project(self):
        self.assertTrue(check_scheme(self.scheme.replace("AC000001000000000000000A", "AC00000100000000DEADBEEF"), self.pbx))

    def test_blueprint_name_mismatch(self):
        self.assertTrue(check_scheme(self.scheme.replace('BlueprintName = "NostromoTests"', 'BlueprintName = "Other"'), self.pbx))

    def test_app_no_longer_built_for_running(self):
        self.assertTrue(check_scheme(_mutate(self.scheme, 'buildForRunning = "YES"', 'buildForRunning = "NO"'), self.pbx))

    def test_app_not_built_for_testing(self):
        self.assertTrue(check_scheme(_mutate(self.scheme, 'buildForTesting = "YES"', 'buildForTesting = "NO"'), self.pbx))

    def test_test_action_uses_release(self):
        m = _mutate(self.scheme, 'buildConfiguration = "Debug"', 'buildConfiguration = "Release"', after="<TestAction")
        self.assertTrue(check_scheme(m, self.pbx))

    def test_scheme_without_test_action(self):
        a = self.scheme.index("<TestAction")
        b = self.scheme.index("</TestAction>") + len("</TestAction>")
        self.assertTrue(check_scheme(self.scheme[:a] + self.scheme[b:], self.pbx))

    def test_test_target_id_removed_or_wrong(self):
        self.assertTrue(check_scheme(self.scheme, _mutate(self.pbx, "\t\t\t\t\t\tTestTargetID = AA000001000000000000003A;\n", "")))
        self.assertTrue(check_scheme(self.scheme, _mutate(self.pbx, "TestTargetID = AA000001000000000000003A;", "TestTargetID = AC000001000000000000000A;")))

    def test_a_second_testable_with_a_dangling_reference_is_caught(self):
        extra = ('<TestableReference skipped = "NO"><BuildableReference BuildableIdentifier = "primary" '
                 'BlueprintIdentifier = "DEAD" BuildableName = "X.xctest" BlueprintName = "Ghost" '
                 'ReferencedContainer = "container:Nostromo.xcodeproj"></BuildableReference></TestableReference>')
        self.assertTrue(check_scheme(_mutate(self.scheme, "</Testables>", extra + "</Testables>"), self.pbx))

    def test_a_second_skipped_testable_is_caught(self):
        extra = ('<TestableReference skipped = "YES"><BuildableReference BuildableIdentifier = "primary" '
                 'BlueprintIdentifier = "AA000001000000000000003A" BuildableName = "Nostromo.app" BlueprintName = "Nostromo" '
                 'ReferencedContainer = "container:Nostromo.xcodeproj"></BuildableReference></TestableReference>')
        self.assertTrue(check_scheme(_mutate(self.scheme, "</Testables>", extra + "</Testables>"), self.pbx))

    def test_tests_entry_built_for_running(self):
        old = 'buildForRunning = "NO"'
        a = self.scheme.index(old)
        m = self.scheme[:a] + 'buildForRunning = "YES"' + self.scheme[a + len(old):]
        self.assertTrue(check_scheme(m, self.pbx))


class HostedTargetBites(unittest.TestCase):
    def setUp(self):
        self.pbx = _read(PBXPROJ)

    def test_missing_target(self):
        self.assertTrue(check_hosted_target(""))

    def test_not_a_unit_test_bundle(self):
        self.assertTrue(check_hosted_target(_mutate(self.pbx, "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle")))

    def test_dependency_on_app_removed(self):
        m = _mutate(self.pbx, "target = AA000001000000000000003A /* Nostromo */;\n\t\t\ttargetProxy",
                    "target = AC000001000000000000000A /* NostromoTests */;\n\t\t\ttargetProxy")
        self.assertTrue(check_hosted_target(m))

    def test_test_host_removed_from_one_configuration(self):
        m = _mutate(self.pbx, '\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Nostromo.app/Nostromo";\n', "")
        self.assertTrue(check_hosted_target(m))

    def test_test_host_pointing_elsewhere(self):
        m = _mutate(self.pbx, 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Nostromo.app/Nostromo";', 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Other.app/Other";')
        self.assertTrue(check_hosted_target(m))

    def test_bundle_loader_removed(self):
        self.assertTrue(check_hosted_target(_mutate(self.pbx, '\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";\n', "", after="AC000001000000000000000B /* Debug */ = {")))


class SuiteNeverSkipsTests(unittest.TestCase):
    """ast-based guard: no skip decorator and no skipTest call in this module."""

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        tree = ast.parse(_read(__file__))
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                for dec in node.decorator_list:
                    self.assertNotIn("skip", ast.dump(dec).lower(), f"{node.name} has a skip decorator")
            if isinstance(node, ast.Call):
                name = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
                self.assertNotEqual(name, "skipTest")


if __name__ == "__main__":
    unittest.main()
