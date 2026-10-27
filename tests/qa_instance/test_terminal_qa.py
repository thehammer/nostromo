"""scripts/qa/lib/terminal_qa.py: opens a terminal as an agent through the QA daemon's MCP socket only.

Run with:  python3 -m unittest discover -s tests/qa_instance -v
Hermetic: a fake MCP server on a socket inside a temp QA root; never a real daemon or app.
"""
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "qa", "lib"))
import qa_instance as qa  # noqa: E402
import terminal_qa  # noqa: E402


class FakeMcp(threading.Thread):
    """Answers initialize and tools/call on `path`, remembering what it was sent."""

    def __init__(self, path, outcome):
        super().__init__(daemon=True)
        self.path = path
        self.outcome = outcome
        self.frames = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(1)

    def run(self):
        conn, _ = self.server.accept()
        with conn, conn.makefile("rwb") as f:
            for line in f:
                frame = json.loads(line)
                self.frames.append(frame)
                if frame.get("method") == "initialize":
                    f.write(json.dumps({"jsonrpc": "2.0", "id": frame["id"], "result": {}}).encode() + b"\n")
                elif frame.get("method") == "tools/call":
                    text = json.dumps(self.outcome)
                    reply = {"jsonrpc": "2.0", "id": frame["id"], "result": {"content": [{"type": "text", "text": text}]}}
                    f.write(json.dumps(reply).encode() + b"\n")
                    f.flush()
                    return
                f.flush()


class OpenTerminalTests(unittest.TestCase):
    def setUp(self):
        # Short path: unix socket paths are limited to ~104 bytes on macOS.
        self.root = tempfile.mkdtemp(prefix="qa-", dir="/tmp")
        open(os.path.join(self.root, qa.ROOT_MARKER), "w").close()
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_calls_open_terminal_as_the_named_focus_and_returns_the_outcome(self):
        outcome = {"ok": True, "terminal_id": "t-1", "pane_id": "terminal-0a1b2c3d"}
        fake = FakeMcp(os.path.join(self.root, qa.MCP_SOCKET), outcome)
        fake.start()
        self.assertEqual(terminal_qa.open_terminal(self.root, "mother", timeout=10), outcome)
        fake.join(5)
        self.assertEqual(fake.frames[0], {"type": "hello", "pty_id": "mother"})
        call = [f for f in fake.frames if f.get("method") == "tools/call"][0]
        self.assertEqual(call["params"], {"name": "nostromo.open_terminal", "arguments": {}})

    def test_refuses_a_root_without_the_qa_marker(self):
        bare = tempfile.mkdtemp(prefix="qa-", dir="/tmp")
        self.addCleanup(shutil.rmtree, bare, True)
        with self.assertRaises(ValueError):
            terminal_qa.open_terminal(bare, "mother", timeout=1)

    def test_request_remote_shell_sends_the_closed_vocabulary_and_the_reason_as_the_named_focus(self):
        outcome = {"error": "cancelled"}
        fake = FakeMcp(os.path.join(self.root, qa.MCP_SOCKET), outcome)
        fake.start()
        got = terminal_qa.request_remote_shell(self.root, "fred", "admin-portal", "production", "scheduler",
                                               "shell", "Check stuck jobs", timeout=10)
        fake.join(5)
        self.assertEqual(got, outcome)
        self.assertEqual(fake.frames[0], {"type": "hello", "pty_id": "fred"})
        call = [f for f in fake.frames if f.get("method") == "tools/call"][0]
        self.assertEqual(call["params"], {"name": "nostromo.request_remote_shell", "arguments": {
            "project": "admin-portal", "environment": "production", "service": "scheduler",
            "shell_type": "shell", "reason": "Check stuck jobs"}})

    def test_main_prints_the_outcome_and_exits_nonzero_unless_ok(self):
        fake = FakeMcp(os.path.join(self.root, qa.MCP_SOCKET), {"error": "timeout"})
        fake.start()
        args = ["terminal_qa.py", "request-remote-shell", self.root, "teri", "admin-portal", "production",
                "scheduler", "shell", "why", "10"]
        self.assertEqual(terminal_qa.main(args), 1)
        fake.join(5)

    def test_request_remote_shell_needs_all_its_words(self):
        self.assertEqual(terminal_qa.main(["terminal_qa.py", "request-remote-shell", self.root, "teri"]), 2)

    def test_main_rejects_other_commands(self):
        self.assertEqual(terminal_qa.main(["terminal_qa.py", "write", self.root, "mother"]), 2)


if __name__ == "__main__":
    unittest.main()
