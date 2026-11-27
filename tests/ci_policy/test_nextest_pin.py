"""cargo-nextest is pinned, and runs without retries.

  * `taiki-e/install-action` is pinned to a full commit SHA (a tag can move).
  * `tool:` names `cargo-nextest@X.Y.Z`, an exact version (no `latest`, no range).
  * `.config/nextest.toml` sets `retries = 0` and nothing that could hide a failure: no retries
    anywhere (a profile or an override), no `fail-fast = true` (it would stop at the first failure
    and report one test of many), no `flaky-result` (it turns a retried pass into a pass), no
    `[test-groups]`, no `[[profile.*.overrides]]` and no `default-filter` (each can drop, serialise
    or retry tests selectively), and the CI command passes no `--retries`, `--profile`, `-E`,
    `--filterset`, `--skip` or `--partition` of its own and sets no `NEXTEST_*` override.

Run with:
    python3 -m unittest discover -s tests/ci_policy -p 'test_nextest_pin.py' -v
"""

import re
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
# Keys that may appear nowhere in the file (any profile, any override).
FORBIDDEN_KEYS = ("flaky-result", "default-filter", "test-groups", "overrides", "filter", "threads-required", "test-group")
# Flags the CI command must not carry: each changes what runs or how a failure is counted.
FORBIDDEN_FLAGS = re.compile(r"(?<![\w-])(--retries|--profile|-P|-E|--filterset|--filter-expr|--skip|--partition|--fail-fast|--max-fail|--flaky-result)(?![\w-])")


def _walk(node, path=""):
    """Every (dotted path, key, value) in a parsed TOML document."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield path, key, value
            yield from _walk(value, f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item, path)


def _is_zero(value):
    """The integer 0 (Python's `False == 0` must not pass for it)."""
    return type(value) is int and value == 0


def toml_violations(nextest_toml):
    try:
        doc = tomllib.loads(nextest_toml)
    except tomllib.TOMLDecodeError as e:
        return [f".config/nextest.toml is not valid TOML: {e}"]
    out = []
    default = doc.get("profile", {}).get("default", {})
    if not _is_zero(default.get("retries")):
        out.append(f".config/nextest.toml [profile.default] must set retries = 0, found {default.get('retries')!r}")
    for path, key, value in _walk(doc):
        where = f"{path}.{key}" if path else key
        if key == "retries" and not _is_zero(value):
            out.append(f"{where} = {value!r}: retries must be 0 everywhere (a retried pass hides a flake)")
        if key == "fail-fast" and value is not False:
            out.append(f"{where} = {value!r}: fail-fast must not be enabled (the run must report every failing test)")
        if key in FORBIDDEN_KEYS:
            out.append(f"{where}: `{key}` can hide, drop or retry tests; the policy is no such setting")
    return out


def violations(ci_yml, nextest_toml):
    out = []
    refs = re.findall(r"uses:\s*taiki-e/install-action@(\S+)", ci_yml)
    if not refs:
        out.append("ci.yml has no taiki-e/install-action step")
    out += [f"taiki-e/install-action@{r} is not a full commit SHA" for r in refs if not SHA.match(r)]
    tools = re.findall(r"^\s*tool:\s*(\S+)", ci_yml, re.M)
    nextest = [t for t in tools if t.startswith("cargo-nextest")]
    if len(nextest) != 1:
        out.append(f"ci.yml must install cargo-nextest exactly once, found {nextest}")
    for t in nextest:
        m = re.fullmatch(r"cargo-nextest@(\S+)", t)
        if not m or not VERSION.match(m.group(1)):
            out.append(f"cargo-nextest must be pinned to an exact X.Y.Z, found {t!r}")
    if not re.search(r"cargo nextest run\b", ci_yml):
        out.append("ci.yml does not run `cargo nextest run`")
    out += toml_violations(nextest_toml)
    commands = re.findall(r"cargo nextest run\b[^\n]*", ci_yml)
    for command in commands:
        for flag in FORBIDDEN_FLAGS.findall(command):
            out.append(f"the nextest command passes {flag}: {command.strip()!r}")
    if re.search(r"(?m)^\s*NEXTEST_[A-Z_]+\s*:", ci_yml) or re.search(r"\bNEXTEST_[A-Z_]+=", ci_yml):
        out.append("ci.yml sets a NEXTEST_* variable, which overrides .config/nextest.toml")
    return out


class NextestPinTests(unittest.TestCase):
    def test_real_tree_is_pinned(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        toml = (ROOT / ".config/nextest.toml").read_text()
        self.assertEqual(violations(ci, toml), [])


class NextestPinBitesTests(unittest.TestCase):
    CI = (
        "uses: taiki-e/install-action@fe3acb53a98b62c772db35de75ce0e4595e7ca8c # v2.90.8\n"
        "with:\n  tool: cargo-nextest@0.9.152\n"
        "run: cargo nextest run --no-fail-fast\n"
    )
    TOML = "[profile.default]\nretries = 0\n"

    def test_consistent_passes(self):
        self.assertEqual(violations(self.CI, self.TOML), [])

    def test_tag_instead_of_sha_fails(self):
        self.assertTrue(violations(self.CI.replace("fe3acb53a98b62c772db35de75ce0e4595e7ca8c", "v2"), self.TOML))

    def test_floating_version_fails(self):
        self.assertTrue(violations(self.CI.replace("@0.9.152", ""), self.TOML))
        self.assertTrue(violations(self.CI.replace("@0.9.152", "@latest"), self.TOML))
        self.assertTrue(violations(self.CI.replace("@0.9.152", "@0.9"), self.TOML))

    def test_retries_fail(self):
        self.assertTrue(violations(self.CI, "[profile.default]\nretries = 2\n"))
        self.assertTrue(violations(self.CI, "[profile.default]\n"))

    def test_retries_in_any_other_form_fail(self):
        for body in (
            "[profile.default]\nretries = { backoff = \"fixed\", count = 3, delay = \"1s\" }\n",
            "[profile.default]\nretries = 0\n[profile.ci]\nretries = 1\n",
            "[profile.default]\nretries = 0\n[[profile.default.overrides]]\nfilter = 'test(x)'\nretries = 2\n",
        ):
            with self.subTest(body=body):
                self.assertTrue(violations(self.CI, body))
        self.assertTrue(violations(self.CI, "[profile.default]\nretries = false\n"))

    def test_fail_fast_true_fails_in_any_profile(self):
        self.assertTrue(violations(self.CI, self.TOML + "fail-fast = true\n"))
        self.assertTrue(violations(self.CI, self.TOML + "[profile.ci]\nfail-fast = true\n"))
        self.assertTrue(violations(self.CI, self.TOML + "fail-fast = { max-fail = 1 }\n"))
        self.assertEqual(violations(self.CI, self.TOML + "fail-fast = false\n"), [])

    def test_flaky_result_filters_groups_and_overrides_fail(self):
        for extra in (
            'flaky-result = "pass"\n',
            'default-filter = "not test(slow)"\n',
            "[test-groups]\nserial = { max-threads = 1 }\n",
            "[[profile.default.overrides]]\nfilter = 'test(x)'\nthreads-required = 4\n",
        ):
            with self.subTest(extra=extra):
                self.assertTrue(violations(self.CI, self.TOML + extra))

    def test_toml_that_does_not_parse_fails(self):
        self.assertTrue(violations(self.CI, "[profile.default\nretries = 0\n"))

    def test_a_retries_value_hidden_from_a_line_regex_is_still_seen(self):
        # Indented, inline-table and quoted-key spellings that `^\s*retries\s*=` misses or misreads.
        self.assertTrue(violations(self.CI, '[profile.default]\nretries = 0\n[profile.x]\n"retries" = 2\n'))
        self.assertTrue(violations(self.CI, "[profile]\ndefault = { retries = 1 }\n"))

    def test_command_line_overrides_fail(self):
        for flag in ("--retries 2", "--profile ci", "-E 'not test(x)'", "--filterset 'not test(x)'", "--skip x", "--partition count:1/2", "--fail-fast", "-P ci"):
            with self.subTest(flag=flag):
                self.assertTrue(violations(self.CI.replace("--no-fail-fast", f"--no-fail-fast {flag}"), self.TOML))

    def test_a_nextest_environment_override_fails(self):
        self.assertTrue(violations(self.CI + "env:\n  NEXTEST_RETRIES: 2\n", self.TOML))
        self.assertTrue(violations(self.CI.replace("run: cargo", "run: NEXTEST_PROFILE=ci cargo"), self.TOML))

    def test_not_running_nextest_fails(self):
        self.assertTrue(violations(self.CI.replace("cargo nextest run", "cargo test"), self.TOML))


if __name__ == "__main__":
    unittest.main()
