"""Behavioral tests for the controlled-restart guard (terminal pane slice 2e).

`make install`, `make install-daemon` and `make uninstall-daemon` restart the
daemon, and a restart ends every open remote (ECS) shell. `bin/nostromo-restart-guard`
asks the running daemon (`nostromd remote-shells`: exit 0 none open, 2 no daemon
running, 3 some open, 4 a daemon that gave no usable answer) and refuses to go ahead while shells are open, unless the
operator forces it with FORCE=1 or NOSTROMO_FORCE_DAEMON_RESTART=1.

Every test points the guard at a fake `nostromd` script in a temp dir
(NOSTROMO_RESTART_GUARD_NOSTROMD) and sets HOME to a temp dir, so the guard
never sees the real ~/.local/bin/nostromd or a real daemon. Stdlib only.

Run with:
    python3 -m unittest discover -s tests/restart_guard -v
"""

import os
import re
import stat
import subprocess
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GUARD = os.path.join(REPO, "bin", "nostromo-restart-guard")
MAKEFILE = os.path.join(REPO, "Makefile")

OPEN_LIST = "admin-portal production scheduler (open 12m)"
FORCE_MESSAGE = "Re-run with FORCE=1"


class GuardCase(unittest.TestCase):
    """A temp dir holding a fake nostromd, a private HOME and a private cwd."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = os.path.realpath(self._tmp.name)
        self.home = os.path.join(self.tmp, "home")
        self.cwd = os.path.join(self.tmp, "cwd")
        os.makedirs(self.home)
        os.makedirs(self.cwd)
        self.argv_log = os.path.join(self.tmp, "nostromd-argv.log")

    # ── fakes ────────────────────────────────────────────────────────────────

    def fake_nostromd(self, exit_code, stdout="", path=None):
        """An executable `nostromd` that logs its argv, prints `stdout`, exits."""
        path = path or os.path.join(self.tmp, "fake-nostromd")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n")
            f.write('echo "$*" >> "%s"\n' % self.argv_log)
            if stdout:
                f.write("cat <<'LIST_EOF'\n%s\nLIST_EOF\n" % stdout)
            f.write("exit %d\n" % exit_code)
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return path

    def run_guard(self, nostromd=None, force=None, env_force=None):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
        }
        if nostromd is not None:
            env["NOSTROMO_RESTART_GUARD_NOSTROMD"] = nostromd
        if force is not None:
            env["FORCE"] = force
        if env_force is not None:
            env["NOSTROMO_FORCE_DAEMON_RESTART"] = env_force
        return subprocess.run(
            [GUARD],
            env=env,
            cwd=self.cwd,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def asked_for(self):
        """The argument lists the fake nostromd was started with."""
        if not os.path.exists(self.argv_log):
            return []
        with open(self.argv_log) as f:
            return [line.rstrip("\n") for line in f]

    @staticmethod
    def output(result):
        return result.stdout + result.stderr


class ShellsOpenTests(GuardCase):
    def test_open_remote_shells_refuse_the_restart_and_say_how_to_force_it(self):
        result = self.run_guard(self.fake_nostromd(3, OPEN_LIST))

        self.assertEqual(result.returncode, 1, self.output(result))
        self.assertIn(OPEN_LIST, self.output(result))
        self.assertIn(FORCE_MESSAGE, self.output(result))
        self.assertIn("closed", self.output(result))

    def test_the_guard_asks_the_daemon_for_remote_shells(self):
        self.run_guard(self.fake_nostromd(3, OPEN_LIST))

        self.assertEqual(self.asked_for(), ["remote-shells"])

    def test_every_open_shell_is_listed(self):
        listing = "admin-portal production scheduler (open 12m)\nadmin-portal staging web (open 3m)"

        result = self.run_guard(self.fake_nostromd(3, listing))

        self.assertEqual(result.returncode, 1)
        for line in listing.splitlines():
            self.assertIn(line, self.output(result))

    def test_force_env_lets_the_restart_proceed_and_still_lists_the_shells(self):
        result = self.run_guard(self.fake_nostromd(3, OPEN_LIST), force="1")

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn(OPEN_LIST, self.output(result))
        self.assertNotIn(FORCE_MESSAGE, self.output(result))

    def test_nostromo_force_daemon_restart_lets_the_restart_proceed(self):
        result = self.run_guard(self.fake_nostromd(3, OPEN_LIST), env_force="1")

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn(OPEN_LIST, self.output(result))

    def test_only_the_value_one_forces(self):
        for var in ("force", "env_force"):
            for value in ("", "0", "yes", "true"):
                with self.subTest(var=var, value=value):
                    result = self.run_guard(
                        self.fake_nostromd(3, OPEN_LIST), **{var: value}
                    )
                    self.assertEqual(result.returncode, 1, self.output(result))
                    self.assertIn(FORCE_MESSAGE, self.output(result))


class NothingToProtectTests(GuardCase):
    def test_no_open_shells_lets_the_restart_proceed(self):
        result = self.run_guard(self.fake_nostromd(0))

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertNotIn(FORCE_MESSAGE, self.output(result))
        self.assertEqual(self.asked_for(), ["remote-shells"])

    def test_no_daemon_running_lets_the_restart_proceed(self):
        # Nothing runs, so there is nothing to close.
        result = self.run_guard(self.fake_nostromd(2))

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertNotIn(FORCE_MESSAGE, self.output(result))


class UnexpectedAnswerTests(GuardCase):
    def test_every_exit_code_has_the_documented_outcome(self):
        # code -> (proceeds unforced, proceeds forced)
        table = {
            0: (True, True),
            1: (False, True),
            2: (True, True),
            3: (False, True),
            4: (False, True),
            99: (False, True),
            127: (False, True),
        }
        for code, (plain, forced) in table.items():
            with self.subTest(code=code, forced=False):
                result = self.run_guard(self.fake_nostromd(code))
                self.assertEqual(result.returncode, 0 if plain else 1, self.output(result))
            with self.subTest(code=code, forced=True):
                result = self.run_guard(self.fake_nostromd(code), force="1")
                self.assertEqual(result.returncode, 0 if forced else 1, self.output(result))

    def test_an_unexpected_exit_code_refuses_and_says_how_to_force(self):
        for code in (1, 99, 127):
            with self.subTest(code=code):
                result = self.run_guard(self.fake_nostromd(code))
                self.assertEqual(result.returncode, 1, self.output(result))
                self.assertIn("FORCE=1", self.output(result))
                self.assertIn("exit %d" % code, self.output(result))

    def test_an_unexpected_exit_code_proceeds_when_forced(self):
        for kwargs in ({"force": "1"}, {"env_force": "1"}):
            with self.subTest(**kwargs):
                result = self.run_guard(self.fake_nostromd(1), **kwargs)
                self.assertEqual(result.returncode, 0, self.output(result))


class NoUsableAnswerTests(GuardCase):
    """Exit 4: a daemon is there but could not say. Fail closed."""

    def test_code_4_refuses_and_says_why_and_how_to_force(self):
        result = self.run_guard(self.fake_nostromd(4))

        self.assertEqual(result.returncode, 1, self.output(result))
        out = self.output(result)
        self.assertIn("could not say whether remote shells are open", out)
        self.assertIn("FORCE=1", out)
        self.assertIn("NOSTROMO_FORCE_DAEMON_RESTART=1", out)

    def test_code_4_says_the_first_guarded_install_is_expected_to_need_forcing(self):
        out = self.output(self.run_guard(self.fake_nostromd(4)))

        self.assertIn("first guarded install", out)
        self.assertIn("predates the summary request", out)
        self.assertIn("once", out)

    def test_code_4_proceeds_when_forced_either_way(self):
        for kwargs in ({"force": "1"}, {"env_force": "1"}):
            with self.subTest(**kwargs):
                result = self.run_guard(self.fake_nostromd(4), **kwargs)
                self.assertEqual(result.returncode, 0, self.output(result))
                self.assertIn("forced", self.output(result))

    def test_code_2_is_not_treated_like_code_4(self):
        result = self.run_guard(self.fake_nostromd(2))

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertNotIn("FORCE=1", self.output(result))


class WhichNostromdIsAskedTests(GuardCase):
    def installed_nostromd(self, exit_code, stdout="", supports_remote_shells=True):
        path = os.path.join(self.home, ".local", "bin", "nostromd")
        self.fake_nostromd(exit_code, stdout, path=path)
        if supports_remote_shells:
            # A real nostromd that knows the subcommand carries the word in
            # its binary; the stand-in carries it in a comment.
            with open(path, "a") as f:
                f.write("# remote-shells\n")
        return path

    def test_with_no_override_the_installed_nostromd_is_asked(self):
        self.installed_nostromd(3, OPEN_LIST)

        result = self.run_guard()

        self.assertEqual(result.returncode, 1, self.output(result))
        self.assertIn(OPEN_LIST, self.output(result))

    def test_an_installed_nostromd_that_predates_the_subcommand_is_never_started(self):
        # Such a binary ignores its arguments and would start a second daemon.
        self.installed_nostromd(3, OPEN_LIST, supports_remote_shells=False)

        result = self.run_guard()

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertEqual(self.asked_for(), [], "an old nostromd must not be run")

    def test_with_no_nostromd_at_all_the_restart_proceeds(self):
        result = self.run_guard()

        self.assertEqual(result.returncode, 0, self.output(result))

    def test_the_fail_open_case_says_so(self):
        result = self.run_guard()

        self.assertIn("not checking for open remote shells", self.output(result))


def read_makefile():
    with open(MAKEFILE) as f:
        return f.read()


def prerequisites(target):
    """The prerequisites of `target`, in the order the Makefile lists them."""
    match = re.search(r"^%s:(?!=)([^\n]*)$" % re.escape(target), read_makefile(), re.M)
    if match is None:
        raise AssertionError("the Makefile has no target %r" % target)
    return match.group(1).split("#")[0].split()


def recipe(target):
    """The recipe lines of `target`."""
    lines = read_makefile().splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^%s:(?!=)" % re.escape(target), line):
            body = []
            for follow in lines[i + 1:]:
                if follow.startswith("\t"):
                    body.append(follow)
                elif follow.strip() == "" or follow.startswith("#"):
                    continue
                else:
                    break
            return body
    raise AssertionError("the Makefile has no target %r" % target)


class MakefileWiringTests(unittest.TestCase):
    def test_every_target_that_restarts_the_daemon_runs_the_guard_first(self):
        for target in ("install", "install-daemon", "uninstall-daemon"):
            with self.subTest(target=target):
                prereqs = prerequisites(target)
                self.assertTrue(prereqs, "%s has no prerequisites" % target)
                self.assertEqual(
                    prereqs[0],
                    "daemon-restart-guard",
                    "%s must run the guard before anything else; it runs %s"
                    % (target, prereqs),
                )

    def test_the_guard_target_runs_the_script_and_passes_force_through(self):
        body = "\n".join(recipe("daemon-restart-guard"))

        self.assertIn("bin/nostromo-restart-guard", body)
        self.assertIn("$(FORCE)", body)

    def test_the_guard_target_is_phony(self):
        phony = re.search(r"^\.PHONY:([^\n]*)$", read_makefile(), re.M)
        self.assertIsNotNone(phony)
        self.assertIn("daemon-restart-guard", phony.group(1).split())

    def test_the_guard_script_exists_and_is_executable(self):
        self.assertTrue(os.path.isfile(GUARD))
        self.assertTrue(os.access(GUARD, os.X_OK))

    def test_the_guard_runs_with_the_python_tests(self):
        self.assertIn(
            "python3 -m unittest discover -s tests/restart_guard -v",
            "\n".join(recipe("python-test")),
        )


if __name__ == "__main__":
    unittest.main()
