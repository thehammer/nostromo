"""terminal-staging.sh promises no tokens, so it refuses to run when a real model binary is configured."""
import os
import unittest

from qa_harness import QA_DIR, QATestCase

SCRIPT = os.path.join(QA_DIR, "terminal-staging.sh")


class TerminalStagingGuardTest(QATestCase):
    def test_refuses_when_a_real_model_binary_is_configured(self):
        run = self.run_script(SCRIPT, env={"NOSTROMO_QA_CLAUDE_BIN": "/usr/local/bin/claude"})
        self.assertEqual(run.returncode, 2)
        self.assertIn("NOSTROMO_QA_CLAUDE_BIN", run.stderr)
        self.assertIn("spend tokens", run.stderr)
        self.assertNotIn("evidence directory", run.stdout)


if __name__ == "__main__":
    unittest.main()
