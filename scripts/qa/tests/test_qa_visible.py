"""lib/qa-visible.sh: a window that is hidden at first and then visible is waited for, not called locked."""
import os
import subprocess
import unittest

from qa_harness import QA_DIR

HELPER = os.path.join(QA_DIR, "lib", "qa-visible.sh")
HIDDEN = '[{"index": 0, "alpha": 0, "visible": false}]'
SHOWN = '[{"index": 0, "alpha": 1, "visible": true}]'


def bash(script, scale):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          env={**os.environ, "QA_SLEEP_SCALE": scale}, timeout=60).stdout.strip()


def wait(hidden_reads, scale="1"):
    """Run qa_wait_visible with a fake ctl that reports hidden for the first `hidden_reads` reads."""
    script = (
        ". '%s'\n"
        "f=$(mktemp); echo 0 > \"$f\"\n"
        "ctl() { n=$(( $(cat \"$f\") + 1 )); echo $n > \"$f\"; if [ \"$n\" -le %d ]; then echo '%s'; else echo '%s'; fi; }\n"
        "qa_wait_visible; echo \"rc=$? reads=$(cat \"$f\")\"; rm -f \"$f\"\n"
    ) % (HELPER, hidden_reads, HIDDEN, SHOWN)
    return bash(script, scale)


class WaitVisibleTest(unittest.TestCase):
    def test_hidden_then_visible_succeeds(self):
        self.assertEqual(wait(3), "rc=0 reads=4")

    def test_visible_at_once_reads_once(self):
        self.assertEqual(wait(0), "rc=0 reads=1")

    def test_never_visible_fails_after_the_bounded_wait(self):
        self.assertEqual(wait(100, scale="0"), "rc=1 reads=2")

    def test_empty_and_empty_list_count_as_not_visible(self):
        for reply in ("", "[]"):
            script = ". '%s'\nctl() { echo '%s'; }\nqa_wait_visible; echo rc=$?" % (HELPER, reply)
            self.assertEqual(bash(script, "0"), "rc=1")


class ScriptsUseTheWaitTest(unittest.TestCase):
    def test_every_terminal_script_with_a_visibility_check_waits_for_it(self):
        for name in ("terminal-staging.sh", "terminal-local.sh", "terminal-remote.sh", "terminal-hazard.sh",
                     "terminal-follow.sh", "terminal-mirror-relaunch.sh"):
            with open(os.path.join(QA_DIR, name)) as f:
                text = f.read()
            self.assertIn("qa-visible.sh", text, name)
            self.assertIn("qa_wait_visible", text, name)


if __name__ == "__main__":
    unittest.main()
