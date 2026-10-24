"""Self-test of the hermetic fake `claude` CLI (tests/support/fake_claude_perm.py)
and its fixtures (tests/fixtures/approvals/*.json).

The Rust approval tests are written against this fake, so its frames are pinned
here: shapes copied from the real CLI 2.1.296 spike captures.

Run with:  python3 -m unittest discover -s tests/fake_claude_perm
"""
import glob
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "..", "support", "fake_claude_perm.py")
FIXTURES = os.path.join(HERE, "..", "fixtures", "approvals")
TIMEOUT = 10

REQUIRED_FIXTURES = {
    "simple_rm", "compound", "heredoc_300", "bidi", "zero_width", "tags", "cyrillic",
    "edit", "write", "notebook_edit", "mcp", "subagent",
    "flag_default_to_no", "flag_suppress_always_allow_rule", "flag_requires_user_interaction",
    "flag_matched_ask_rule", "ask_user_question", "safety_check", "settings_write", "ansi_reason", "all_fields",
    "parallel_3", "cancel", "guard_send_keys", "guard_ecs_connect", "malformed", "non_can_use_tool",
}
# Fixtures whose request deliberately lacks `tool_use_id`.
NO_TOOL_USE_ID = {"malformed"}
PERM_ARGV = ["--dangerously-skip-permissions", "--permission-prompt-tool", "stdio",
             "--session-id", "sid-1", "--output-format", "stream-json"]


def fixture(name):
    with open(os.path.join(FIXTURES, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def user(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def control_response(request_id, **body):
    return {"type": "control_response",
            "response": {"subtype": "success", "request_id": request_id, "response": body}}


def deny(request_id, message="The user denied this in Nostromo.", **extra):
    return control_response(request_id, behavior="deny", message=message, **extra)


def allow(request_id, updated_input=None):
    return control_response(request_id, behavior="allow", updatedInput=updated_input or {})


class Fake:
    """Drive the fake over pipes. Frames it emits are queued by a reader thread."""

    def __init__(self, test, argv=None, env=None):
        self.log_dir = tempfile.mkdtemp(prefix="fcp")
        base_env = {"PATH": os.environ.get("PATH", ""), "FAKE_CLAUDE_LOG_DIR": self.log_dir}
        base_env.update(env or {})
        env = base_env
        self.argv = PERM_ARGV if argv is None else argv
        self.proc = subprocess.Popen(
            [sys.executable, "-I", os.path.abspath(FAKE)] + self.argv,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        self.frames = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        test.addCleanup(self.close)

    def _pump(self):
        for line in self.proc.stdout:
            self.frames.put(json.loads(line))
        self.frames.put(None)  # EOF marker

    def send(self, frame):
        self.proc.stdin.write((json.dumps(frame) + "\n").encode())
        self.proc.stdin.flush()

    def send_raw(self, line):
        self.proc.stdin.write(line.encode() + b"\n")
        self.proc.stdin.flush()

    def next(self):
        frame = self.frames.get(timeout=TIMEOUT)
        assert frame is not None, "fake exited; stderr=%r" % self.proc.stderr.read()
        return frame

    def take(self, n):
        return [self.next() for _ in range(n)]

    def until_result(self):
        out = []
        while True:
            frame = self.next()
            out.append(frame)
            if frame["type"] == "result":
                return out

    def no_more_frames(self, grace=0.3):
        try:
            self.frames.get(timeout=grace)
        except queue.Empty:
            return True
        return False

    def read_log(self, name):
        path = os.path.join(self.log_dir, name)
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def jsonl(self, name):
        return [json.loads(l) for l in self.read_log(name).splitlines() if l]

    def close_stdin_and_wait(self):
        self.proc.stdin.close()
        return self.proc.wait(timeout=TIMEOUT)

    def close(self):
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=TIMEOUT)
        except Exception:
            self.proc.kill()
        for stream in (self.proc.stdout, self.proc.stderr):
            if stream:
                stream.close()
        shutil.rmtree(self.log_dir, ignore_errors=True)

    def start(self):
        """Consume the init line and return it."""
        return self.next()

    def cue(self, text):
        """Send a user message and consume its replay echo."""
        self.send(user(text))
        echo = self.next()
        assert echo["type"] == "user" and echo.get("isReplay") is True, echo
        return echo


class FixtureFilesTest(unittest.TestCase):
    def fixture_paths(self):
        # top level only: approvals/guard/ belongs to the production-shell guard tests
        return sorted(glob.glob(os.path.join(FIXTURES, "*.json")))

    def test_every_required_fixture_exists(self):
        names = {os.path.basename(p)[:-5] for p in self.fixture_paths()}
        self.assertEqual(REQUIRED_FIXTURES - names, set())

    def test_every_fixture_is_valid_and_ties_requests_to_tool_uses(self):
        for path in self.fixture_paths():
            name = os.path.basename(path)[:-5]
            with self.subTest(fixture=name):
                with open(path, encoding="utf-8") as f:
                    doc = json.load(f)
                self.assertIsInstance(doc.get("description"), str)
                tool_uses = doc["tool_uses"]
                self.assertTrue(tool_uses)
                ids = [t["id"] for t in tool_uses]
                self.assertEqual(len(ids), len(set(ids)), "tool_use ids are unique")
                for t in tool_uses:
                    self.assertEqual(set(t), {"id", "name", "input"})
                self.assertTrue(doc["requests"])
                for entry in doc["requests"]:
                    request = entry["request"]
                    self.assertIn("subtype", request)
                    if name in NO_TOOL_USE_ID:
                        self.assertNotIn("tool_use_id", request)
                    else:
                        self.assertIn(request["tool_use_id"], ids)

    def test_tool_use_ids_are_unique_across_fixtures(self):
        seen = {}
        for path in self.fixture_paths():
            for t in fixture(os.path.basename(path)[:-5])["tool_uses"]:
                self.assertNotIn(t["id"], seen, "%s reuses %s" % (path, seen.get(t["id"])))
                seen[t["id"]] = path

    def test_heredoc_300_is_one_300_line_command_without_trailing_newline(self):
        command = fixture("heredoc_300")["tool_uses"][0]["input"]["command"]
        lines = command.split("\n")
        self.assertEqual(len(lines), 300)
        self.assertFalse(command.endswith("\n"))
        self.assertEqual(lines[0], "cat > /tmp/notes.txt <<'EOF'")
        self.assertEqual(lines[285], "EOF")
        self.assertEqual(lines[286], "rm -rf /tmp/notes.txt")
        self.assertEqual(lines[287], "echo done 1")
        self.assertEqual(lines[299], "echo done 13")
        for line in lines[:286]:
            for sep in (";", "&", "|", "`", "$("):
                self.assertNotIn(sep, line)

    def test_invisible_character_fixtures_carry_the_characters(self):
        def cmd(name):
            return fixture(name)["tool_uses"][0]["input"]["command"]
        for ch in "‮⁦⁧⁨⁩":
            self.assertIn(ch, cmd("bidi"))
        for ch in "​‌‍⁠﻿":
            self.assertIn(ch, cmd("zero_width"))
        self.assertTrue(any(0xE0000 <= ord(c) <= 0xE007F for c in cmd("tags")))
        self.assertIn("м", cmd("cyrillic"))
        self.assertNotIn("m", cmd("cyrillic").split()[0])

    def test_flag_fixtures_set_exactly_their_field(self):
        def request(name):
            return fixture(name)["requests"][0]["request"]
        self.assertIs(request("flag_default_to_no")["default_to_no"], True)
        self.assertIs(request("flag_suppress_always_allow_rule")["suppress_always_allow_rule"], True)
        self.assertIs(request("flag_requires_user_interaction")["requires_user_interaction"], True)
        self.assertEqual(request("flag_matched_ask_rule")["matched_ask_rule"],
                         {"source": "userSettings", "tool_name": "Bash", "rule_content": "rm:*"})
        safety = request("safety_check")
        self.assertEqual(safety["decision_reason_type"], "safetyCheck")
        self.assertEqual(safety["blocked_path"], "/etc/hosts")
        self.assertIs(safety["classifier_approvable"], False)
        self.assertEqual(safety["permission_suggestions"], [])
        settings = fixture("settings_write")
        self.assertEqual(settings["requests"][0]["request"]["decision_reason_type"], "other")
        self.assertEqual(settings["tool_uses"][0]["input"]["file_path"], "/Users/test/.claude/settings.json")
        ansi = request("ansi_reason")
        for needle in ("\u001b[31m", "\u001b[0m", "\u001b[2K", "\u001b]0;evil\u0007"):
            self.assertIn(needle, ansi["decision_reason"])
        self.assertIn("\u001b[", ansi["description"])
        self.assertEqual(request("mcp")["mcp_server"], "slack")
        self.assertEqual(request("mcp")["tool_name"], "mcp__slack__send_message")
        self.assertEqual(request("subagent")["agent_id"], "agent_abc123")

    def test_all_fields_sets_every_optional_field(self):
        request = fixture("all_fields")["requests"][0]["request"]
        for key in ("agent_id", "title", "mcp_server", "permission_suggestions", "blocked_path",
                    "decision_reason", "classifier_approvable", "suppress_always_allow_rule",
                    "default_to_no", "matched_ask_rule", "requires_user_interaction",
                    "display_name", "description", "decision_reason_type"):
            self.assertIn(key, request)
        self.assertEqual(set(request["matched_ask_rule"]), {"source", "tool_name", "rule_content"})

    def test_parallel_3_is_three_bash_tool_uses_and_three_requests(self):
        doc = fixture("parallel_3")
        self.assertEqual([t["input"]["command"] for t in doc["tool_uses"]],
                         ["rm -rf /tmp/p1", "rm -rf /tmp/p2", "rmdir /tmp/p3"])
        self.assertEqual(len(doc["requests"]), 3)

    def test_edit_fixture_has_unchanged_and_changed_lines(self):
        inp = fixture("edit")["tool_uses"][0]["input"]
        old, new = inp["old_string"].splitlines(), inp["new_string"].splitlines()
        self.assertGreater(len(old), 2)
        self.assertTrue(set(old) & set(new), "some lines unchanged")
        self.assertTrue(set(old) ^ set(new), "some lines changed")
        self.assertEqual(set(fixture("notebook_edit")["tool_uses"][0]["input"]),
                         {"notebook_path", "new_source", "cell_id", "edit_mode"})


class StartupTest(unittest.TestCase):
    def test_argv_is_logged_verbatim_and_init_uses_session_id(self):
        argv = PERM_ARGV + ["--model", "x y", "--flag=with space"]
        fake = Fake(self, argv)
        init = fake.start()
        self.assertEqual(init["type"], "system")
        self.assertEqual(init["subtype"], "init")
        self.assertEqual(init["session_id"], "sid-1")
        self.assertEqual(json.loads(fake.read_log("argv.json")), argv)

    def test_resume_id_names_the_session_when_there_is_no_session_id(self):
        fake = Fake(self, ["--resume", "sid-resumed", "--permission-prompt-tool", "stdio"])
        self.assertEqual(fake.start()["session_id"], "sid-resumed")

    def test_exits_zero_on_stdin_eof(self):
        fake = Fake(self)
        fake.start()
        self.assertEqual(fake.close_stdin_and_wait(), 0)

    def test_exits_zero_on_eof_even_with_a_request_pending(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        fake.take(2)  # assistant + control_request
        self.assertEqual(fake.close_stdin_and_wait(), 0)

    def test_every_stdin_line_is_recorded_verbatim_in_order(self):
        fake = Fake(self)
        fake.start()
        lines = [
            json.dumps(user("hello")),
            "this is not json",
            json.dumps({"type": "control_request", "request_id": "r1", "request": {"subtype": "set_model"}}),
            json.dumps(user("again"), indent=None, separators=(",", ":")),
        ]
        for line in lines:
            fake.send_raw(line)
        fake.close_stdin_and_wait()
        self.assertEqual(fake.read_log("stdin.jsonl").splitlines(), lines)


class UserMessageTest(unittest.TestCase):
    def test_string_user_message_is_echoed_as_a_replay_then_the_turn_ends(self):
        fake = Fake(self)
        fake.start()
        fake.send(user("hello there"))
        echo, assistant, result = fake.take(3)
        self.assertEqual(echo["type"], "user")
        self.assertIs(echo["isReplay"], True)
        self.assertEqual(echo["message"], {"role": "user", "content": "hello there"})
        self.assertEqual(echo["session_id"], "sid-1")
        self.assertEqual(assistant["message"]["content"], [{"type": "text", "text": "ok"}])
        self.assertEqual(result["type"], "result")
        self.assertEqual(result["subtype"], "success")
        self.assertIs(result["is_error"], False)

    def test_text_block_content_is_echoed_and_cues_are_read_from_blocks(self):
        fake = Fake(self)
        fake.start()
        blocks = [{"type": "text", "text": "please"}, {"type": "text", "text": "FIXTURE:simple_rm"}]
        fake.send({"type": "user", "message": {"role": "user", "content": blocks}})
        echo = fake.next()
        self.assertEqual(echo["message"]["content"], blocks)
        self.assertIs(echo["isReplay"], True)
        assistant, request = fake.take(2)
        self.assertEqual(assistant["message"]["content"][0]["id"], "toolu_simple_rm_0")
        self.assertEqual(request["type"], "control_request")

    def test_runs_freely_emits_a_bash_tool_use_and_no_control_request(self):
        fake = Fake(self)
        fake.start()
        fake.cue("runs_freely")
        frames = fake.until_result()
        self.assertEqual([f["type"] for f in frames], ["assistant", "user", "assistant", "result"])
        tool_use = frames[0]["message"]["content"][0]
        self.assertEqual(tool_use, {"type": "tool_use", "id": "toolu_free_0", "name": "Bash",
                                    "input": {"command": "git status", "description": "show status"}})
        block = frames[1]["message"]["content"][0]
        self.assertEqual((block["type"], block["tool_use_id"], block["is_error"]),
                         ("tool_result", "toolu_free_0", False))
        self.assertEqual(frames[-1]["subtype"], "success")


class PermissionFlowTest(unittest.TestCase):
    def test_simple_rm_deny_emits_exact_frames(self):
        fake = Fake(self)
        init = fake.start()
        self.assertEqual(init["type"], "system")
        fake.cue("FIXTURE:simple_rm")

        assistant = fake.next()
        self.assertEqual(assistant["type"], "assistant")
        self.assertEqual(assistant["message"]["role"], "assistant")
        self.assertEqual(assistant["message"]["content"], [{
            "type": "tool_use", "id": "toolu_simple_rm_0", "name": "Bash",
            "input": {"command": "rm -rf /tmp/x/a", "description": "remove a"}}])
        self.assertIsNone(assistant["parent_tool_use_id"])
        self.assertEqual(assistant["session_id"], "sid-1")

        control = fake.next()
        self.assertEqual(set(control), {"type", "request_id", "request"})
        self.assertEqual(control["type"], "control_request")
        self.assertRegex(control["request_id"], r"^[0-9a-f-]{36}$")
        self.assertEqual(control["request"], {
            "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash",
            "input": {"command": "rm -rf /tmp/x/a", "description": "remove a"},
            "description": "remove a", "decision_reason_type": "rule",
            "tool_use_id": "toolu_simple_rm_0"})

        # The turn is held until Nostromo answers.
        self.assertTrue(fake.no_more_frames())

        message = "The user denied this in Nostromo.\n\nUser's note: not now"
        answer = deny(control["request_id"], message)
        fake.send(answer)

        tool_result = fake.next()
        self.assertEqual(tool_result["type"], "user")
        self.assertEqual(tool_result["message"], {"role": "user", "content": [
            {"type": "tool_result", "content": message, "is_error": True,
             "tool_use_id": "toolu_simple_rm_0"}]})
        self.assertEqual(tool_result["tool_use_result"], "Error: " + message)
        self.assertEqual(tool_result["tool_result_meta"][0]["id"], "toolu_simple_rm_0")

        done = fake.next()
        self.assertEqual(done["type"], "assistant")
        self.assertEqual(done["message"]["content"], [{"type": "text", "text": "done"}])

        result = fake.next()
        self.assertEqual(result["type"], "result")
        self.assertEqual(result["subtype"], "success")
        self.assertEqual(result["stop_reason"], "end_turn")
        self.assertIs(result["is_error"], False)
        self.assertEqual(result["permission_denials"][0]["tool_use_id"], "toolu_simple_rm_0")

        # the answer is logged
        self.assertEqual(fake.jsonl("responses.jsonl"), [{
            "request_id": control["request_id"], "tool_use_id": "toolu_simple_rm_0",
            "response": answer}])
        # and also present verbatim in the stdin log
        self.assertIn(answer, fake.jsonl("stdin.jsonl"))

    def test_allow_emits_an_ok_tool_result(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        _, control = fake.take(2)
        fake.send(allow(control["request_id"], control["request"]["input"]))
        frames = fake.until_result()
        block = frames[0]["message"]["content"][0]
        self.assertEqual(block["type"], "tool_result")
        self.assertEqual(block["content"], "ok")
        self.assertIs(block["is_error"], False)
        self.assertEqual(block["tool_use_id"], "toolu_simple_rm_0")
        self.assertEqual(frames[-1]["subtype"], "success")
        self.assertEqual(frames[-1]["permission_denials"], [])

    def test_deny_with_interrupt_flag_is_recorded_verbatim(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        _, control = fake.take(2)
        answer = deny(control["request_id"], "stop", interrupt=True)
        fake.send(answer)
        fake.until_result()
        self.assertEqual(fake.jsonl("responses.jsonl")[0]["response"], answer)
        self.assertIs(fake.jsonl("responses.jsonl")[0]["response"]["response"]["response"]["interrupt"], True)

    def test_parallel_3_is_one_assistant_line_and_three_requests_answered_out_of_order(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:parallel_3")
        assistant = fake.next()
        self.assertEqual([b["id"] for b in assistant["message"]["content"]],
                         ["toolu_parallel_3_0", "toolu_parallel_3_1", "toolu_parallel_3_2"])
        self.assertEqual([b["input"]["command"] for b in assistant["message"]["content"]],
                         ["rm -rf /tmp/p1", "rm -rf /tmp/p2", "rmdir /tmp/p3"])
        controls = fake.take(3)
        self.assertEqual([c["type"] for c in controls], ["control_request"] * 3)
        self.assertEqual([c["request"]["tool_use_id"] for c in controls],
                         ["toolu_parallel_3_0", "toolu_parallel_3_1", "toolu_parallel_3_2"])
        ids = [c["request_id"] for c in controls]
        self.assertEqual(len(set(ids)), 3, "fresh request id per request")

        # answer 2, then 0, then 1
        fake.send(deny(ids[2], "no 3"))
        r = fake.next()
        self.assertEqual((r["message"]["content"][0]["tool_use_id"], r["message"]["content"][0]["content"]),
                         ("toolu_parallel_3_2", "no 3"))
        self.assertTrue(fake.no_more_frames(), "turn not finished with two requests pending")
        fake.send(allow(ids[0]))
        r = fake.next()
        self.assertEqual(r["message"]["content"][0]["tool_use_id"], "toolu_parallel_3_0")
        self.assertIs(r["message"]["content"][0]["is_error"], False)
        self.assertTrue(fake.no_more_frames())
        fake.send(deny(ids[1], "no 2"))
        rest = fake.until_result()
        self.assertEqual(rest[0]["message"]["content"][0]["tool_use_id"], "toolu_parallel_3_1")
        self.assertEqual(rest[-2]["message"]["content"], [{"type": "text", "text": "done"}])
        self.assertEqual(rest[-1]["type"], "result")

        logged = fake.jsonl("responses.jsonl")
        self.assertEqual([(l["request_id"], l["tool_use_id"]) for l in logged],
                         [(ids[2], "toolu_parallel_3_2"), (ids[0], "toolu_parallel_3_0"),
                          (ids[1], "toolu_parallel_3_1")])

    def test_two_cues_in_flight_are_both_served(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        _, first = fake.take(2)
        fake.cue("FIXTURE:compound")  # arrives while the first is pending
        _, second = fake.take(2)
        self.assertNotEqual(first["request_id"], second["request_id"])
        fake.send(deny(second["request_id"], "no"))
        frames = fake.until_result()
        self.assertEqual(frames[0]["message"]["content"][0]["tool_use_id"], "toolu_compound_0")
        # the first cue is still waiting
        self.assertTrue(fake.no_more_frames())
        fake.send(allow(first["request_id"]))
        frames = fake.until_result()
        self.assertEqual(frames[0]["message"]["content"][0]["tool_use_id"], "toolu_simple_rm_0")

    def test_other_stdin_lines_while_pending_do_not_release_the_request(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        _, control = fake.take(2)
        fake.send(user("a follow-up with no cue"))
        echo, assistant, result = fake.take(3)  # handled normally
        self.assertIs(echo["isReplay"], True)
        self.assertEqual(result["type"], "result")
        self.assertTrue(fake.no_more_frames())
        fake.send(deny(control["request_id"], "no"))
        self.assertEqual(fake.until_result()[0]["message"]["content"][0]["content"], "no")

    def test_unknown_request_id_response_is_logged_and_ignored(self):
        fake = Fake(self)
        fake.start()
        stray = deny("no-such-request")
        fake.send(stray)
        fake.send(user("ping"))
        fake.take(3)
        self.assertEqual(fake.jsonl("responses.jsonl"), [{
            "request_id": "no-such-request", "tool_use_id": None, "response": stray}])

    def test_unknown_fixture_ends_the_turn_with_an_error_result(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:does_not_exist")
        frames = fake.until_result()
        self.assertIs(frames[-1]["is_error"], True)
        self.assertTrue(all(f["type"] != "control_request" for f in frames))

    def test_every_fixture_emits_its_requests_verbatim(self):
        fake = Fake(self)  # one process serves every fixture in turn
        fake.start()
        for path in sorted(glob.glob(os.path.join(FIXTURES, "*.json"))):
            name = os.path.basename(path)[:-5]
            with self.subTest(fixture=name):
                doc = fixture(name)
                fake.cue("FIXTURE:" + name)
                assistant = fake.next()
                self.assertEqual(
                    assistant["message"]["content"],
                    [{"type": "tool_use", "id": t["id"], "name": t["name"], "input": t["input"]}
                     for t in doc["tool_uses"]])
                emitted = fake.take(len(doc["requests"]))
                for frame, entry in zip(emitted, doc["requests"]):
                    self.assertEqual(frame["type"], "control_request")
                    self.assertEqual(frame["request"], entry["request"])
                for frame in emitted:
                    if frame["request"]["subtype"] == "can_use_tool":
                        fake.send(deny(frame["request_id"], "no"))
                self.assertEqual(fake.until_result()[-1]["type"], "result")

    def test_non_can_use_tool_request_is_emitted_and_never_waited_on(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:non_can_use_tool")
        frames = fake.until_result()
        kinds = [f["type"] for f in frames]
        self.assertEqual(kinds[:2], ["assistant", "control_request"])
        self.assertEqual(frames[1]["request"]["subtype"], "hook_callback")
        self.assertEqual(frames[-1]["type"], "result")
        self.assertEqual(fake.jsonl("responses.jsonl"), [])

    def test_malformed_request_is_emitted_as_is_and_waits_for_an_answer(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:malformed")
        _, control = fake.take(2)
        self.assertNotIn("tool_use_id", control["request"])
        self.assertEqual(control["request"]["input"], "oops")
        self.assertTrue(fake.no_more_frames())
        fake.send(deny(control["request_id"], "bad frame"))
        frames = fake.until_result()
        self.assertEqual(frames[0]["message"]["content"][0]["tool_use_id"], "toolu_malformed_0")
        self.assertEqual(fake.jsonl("responses.jsonl")[0]["request_id"], control["request_id"])


class NoPromptToolTest(unittest.TestCase):
    ARGV = ["--dangerously-skip-permissions", "--session-id", "sid-1"]

    def test_without_permission_prompt_tool_no_control_request_is_emitted(self):
        fake = Fake(self, self.ARGV)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        frames = fake.until_result()
        self.assertEqual([f["type"] for f in frames], ["assistant", "user", "result"])
        self.assertEqual(frames[0]["message"]["content"][0]["id"], "toolu_simple_rm_0")
        block = frames[1]["message"]["content"][0]
        self.assertEqual(block, {
            "type": "tool_result", "is_error": True, "tool_use_id": "toolu_simple_rm_0",
            "content": "Claude requested permissions to use Bash, but you haven't granted it yet."})
        self.assertEqual(frames[-1]["subtype"], "success")
        self.assertTrue(fake.no_more_frames())

    def test_each_parallel_tool_use_is_refused_without_any_request(self):
        fake = Fake(self, self.ARGV)
        fake.start()
        fake.cue("FIXTURE:parallel_3")
        frames = fake.until_result()
        self.assertEqual([f["type"] for f in frames], ["assistant", "user", "user", "user", "result"])
        self.assertEqual([f["message"]["content"][0]["tool_use_id"] for f in frames[1:4]],
                         ["toolu_parallel_3_0", "toolu_parallel_3_1", "toolu_parallel_3_2"])

    def test_cancel_cue_also_emits_no_request_without_the_flag(self):
        fake = Fake(self, self.ARGV)
        fake.start()
        fake.cue("CANCEL:cancel")
        kinds = [f["type"] for f in fake.until_result()]
        self.assertNotIn("control_request", kinds)
        self.assertNotIn("control_cancel_request", kinds)

    def test_flag_without_stdio_value_does_not_count(self):
        fake = Fake(self, ["--permission-prompt-tool", "mcp__x__y"])
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        self.assertNotIn("control_request", [f["type"] for f in fake.until_result()])

    def test_unflagged_runs_freely_is_unaffected(self):
        fake = Fake(self, self.ARGV)
        fake.start()
        fake.cue("runs_freely")
        self.assertEqual(fake.until_result()[-1]["subtype"], "success")


class CancelTest(unittest.TestCase):
    def test_cancel_emits_request_then_cancel_then_rejection_then_result(self):
        fake = Fake(self)
        fake.start()
        fake.cue("CANCEL:cancel")
        assistant, control, cancel, tool_result, interrupted, result = fake.take(6)
        self.assertEqual(assistant["type"], "assistant")
        self.assertEqual(control["type"], "control_request")
        self.assertEqual(control["request"]["tool_use_id"], "toolu_cancel_0")
        self.assertEqual(cancel, {"type": "control_cancel_request", "request_id": control["request_id"]})
        block = tool_result["message"]["content"][0]
        self.assertEqual(block["type"], "tool_result")
        self.assertIs(block["is_error"], True)
        self.assertEqual(block["tool_use_id"], "toolu_cancel_0")
        self.assertTrue(block["content"].startswith("The user doesn't want to proceed with this tool use."))
        self.assertEqual(interrupted["message"]["content"],
                         [{"type": "text", "text": "[Request interrupted by user for tool use]"}])
        self.assertEqual(result["type"], "result")
        self.assertEqual(result["subtype"], "error_during_execution")
        self.assertEqual(result["stop_reason"], "tool_use")
        self.assertEqual(result["terminal_reason"], "aborted_tools")

    def test_cancel_does_not_wait_and_a_late_response_is_still_recorded(self):
        fake = Fake(self)
        fake.start()
        fake.cue("CANCEL:cancel")
        frames = fake.take(6)
        control = frames[1]
        late = deny(control["request_id"], "too late")
        fake.send(late)
        fake.send(user("sync"))
        fake.take(3)  # echo + ok + result: nothing extra came from the late response
        self.assertEqual(fake.jsonl("responses.jsonl"), [{
            "request_id": control["request_id"], "tool_use_id": "toolu_cancel_0", "response": late}])

    def test_cancel_of_parallel_fixture_cancels_every_request_before_any_tool_result(self):
        fake = Fake(self)
        fake.start()
        fake.cue("CANCEL:parallel_3")
        frames = fake.until_result()
        kinds = [f["type"] for f in frames]
        self.assertEqual(kinds[:7], ["assistant"] + ["control_request"] * 3 + ["control_cancel_request"] * 3)
        requests = [f["request_id"] for f in frames[1:4]]
        self.assertEqual([f["request_id"] for f in frames[4:7]], requests)
        self.assertEqual(sum(1 for f in frames[7:] if f["type"] == "user"
                             and f["message"]["content"][0]["type"] == "tool_result"), 3)


class InterruptTest(unittest.TestCase):
    def interrupt(self, request_id="int-1"):
        return {"type": "control_request", "request_id": request_id,
                "request": {"subtype": "interrupt"}}

    def test_interrupt_while_pending_cancels_then_answers_then_ends_the_turn(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        _, control = fake.take(2)
        fake.send(self.interrupt("spike-int-1"))
        cancel, response, tool_result, interrupted, result = fake.take(5)
        self.assertEqual(cancel, {"type": "control_cancel_request", "request_id": control["request_id"]})
        self.assertEqual(response, {"type": "control_response", "response": {
            "subtype": "success", "request_id": "spike-int-1", "response": {"still_queued": []}}})
        block = tool_result["message"]["content"][0]
        self.assertEqual((block["type"], block["tool_use_id"], block["is_error"]),
                         ("tool_result", "toolu_simple_rm_0", True))
        self.assertTrue(block["content"].startswith("The user doesn't want to proceed with this tool use."))
        self.assertEqual(interrupted["message"]["content"][0]["text"],
                         "[Request interrupted by user for tool use]")
        self.assertEqual(result["type"], "result")
        self.assertEqual(result["terminal_reason"], "aborted_tools")

    def test_interrupt_with_several_pending_cancels_all_of_them_first(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:parallel_3")
        frames = fake.take(4)
        ids = [f["request_id"] for f in frames[1:]]
        fake.send(self.interrupt())
        out = fake.take(4)
        self.assertEqual([f["type"] for f in out],
                         ["control_cancel_request"] * 3 + ["control_response"])
        self.assertEqual([f["request_id"] for f in out[:3]], ids)
        rest = fake.until_result()
        results = [f["message"]["content"][0]["tool_use_id"] for f in rest
                   if f["type"] == "user" and f["message"]["content"][0]["type"] == "tool_result"]
        self.assertEqual(results, ["toolu_parallel_3_0", "toolu_parallel_3_1", "toolu_parallel_3_2"])

    def test_interrupt_after_a_partial_answer_only_cancels_what_is_still_pending(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:parallel_3")
        frames = fake.take(4)
        ids = [f["request_id"] for f in frames[1:]]
        fake.send(deny(ids[0], "no 1"))
        fake.next()  # tool_result for 0
        fake.send(self.interrupt())
        cancels = fake.take(2)
        self.assertEqual([c["request_id"] for c in cancels], ids[1:])
        self.assertEqual(fake.next()["type"], "control_response")

    def test_interrupt_with_nothing_pending_only_gets_the_success_response(self):
        fake = Fake(self)
        fake.start()
        fake.send(self.interrupt("int-9"))
        self.assertEqual(fake.next(), {"type": "control_response", "response": {
            "subtype": "success", "request_id": "int-9", "response": {"still_queued": []}}})
        self.assertTrue(fake.no_more_frames())

    def test_other_control_requests_get_a_success_response(self):
        fake = Fake(self)
        fake.start()
        fake.send({"type": "control_request", "request_id": "m-1", "request": {"subtype": "set_model", "model": "x"}})
        response = fake.next()
        self.assertEqual(response["type"], "control_response")
        self.assertEqual(response["response"]["subtype"], "success")
        self.assertEqual(response["response"]["request_id"], "m-1")


class RawCueTest(unittest.TestCase):
    """RAW:<kind> cues emit hand-built (possibly broken) lines for the daemon's
    unreadable-request tests; they are read here as raw bytes."""

    def run_cue(self, cue, answer=None):
        log_dir = tempfile.mkdtemp(prefix="fcp")
        self.addCleanup(shutil.rmtree, log_dir, ignore_errors=True)
        stdin = json.dumps(user(cue)) + "\n"
        if answer is not None:
            stdin += json.dumps(answer) + "\n"
        proc = subprocess.run(
            [sys.executable, "-I", os.path.abspath(FAKE)] + PERM_ARGV,
            input=stdin.encode(), capture_output=True, timeout=TIMEOUT,
            env={"PATH": os.environ.get("PATH", ""), "FAKE_CLAUDE_LOG_DIR": log_dir},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.split(b"\n")

    def test_deep_cue_nests_the_input_by_the_requested_depth_with_a_uuid_id(self):
        lines = self.run_cue("RAW:deep:1000")
        raw = next(l for l in lines if l.startswith(b'{"type":"control_request"'))
        self.assertIn(b'"n":' + b"[" * 1000 + b"]" * 1000, raw)
        self.assertIn(b'"subtype":"can_use_tool"', raw)

    def test_numid_cue_uses_the_number_7_as_request_id(self):
        lines = self.run_cue("RAW:numid")
        raw = next(l for l in lines if l.startswith(b'{"type":"control_request"'))
        self.assertEqual(json.loads(raw)["request_id"], 7)

    def test_a_numeric_answer_ends_the_turn(self):
        lines = self.run_cue("RAW:numid", answer=deny(7))
        self.assertTrue(any(l.startswith(b'{"duration_api_ms"') for l in lines), lines)

    def test_unanswered_kinds_end_the_turn_at_once_and_the_garbage_line_is_not_json(self):
        lines = self.run_cue("RAW:garbage")
        self.assertTrue(any(b"ZZ-GARBAGE-MARK-ZZ" in l for l in lines))
        self.assertTrue(any(l.startswith(b'{"duration_api_ms"') for l in lines), lines)
        with self.assertRaises(ValueError):
            json.loads(next(l for l in lines if b"ZZ-GARBAGE-MARK-ZZ" in l))

    def test_oversize_cue_is_a_valid_line_over_four_mib(self):
        lines = self.run_cue("RAW:oversize")
        raw = next(l for l in lines if l.startswith(b'{"type":"control_request"'))
        self.assertGreater(len(raw), 4 * 1024 * 1024)
        self.assertEqual(json.loads(raw)["request"]["subtype"], "can_use_tool")

    def test_unknown_raw_kind_ends_the_turn_with_an_error_result(self):
        lines = self.run_cue("RAW:nonsense")
        self.assertTrue(any(b"unknown raw cue" in l for l in lines))


AUTH_TEXT = "Failed to authenticate: OAuth session expired and could not be refreshed"


class AuthModeTest(unittest.TestCase):
    """FAKE_CLAUDE_AUTH_FILE / FAKE_CLAUDE_AUTH_STICKY: an expired Claude login."""

    def auth_file(self, value=None):
        d = tempfile.mkdtemp(prefix="fcpauth")
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        path = os.path.join(d, "auth")
        if value is not None:
            self.set_auth(path, value)
        return path

    @staticmethod
    def set_auth(path, value):
        with open(path, "w", encoding="utf-8") as f:
            f.write(value)

    def fake(self, path, sticky=False):
        env = {} if path is None else {"FAKE_CLAUDE_AUTH_FILE": path}
        if sticky:
            env["FAKE_CLAUDE_AUTH_STICKY"] = "1"
        fake = Fake(self, env=env)
        fake.start()
        return fake

    def turn(self, fake, text="hello"):
        fake.send(user(text))
        return fake.until_result()

    def assert_failed_turn(self, frames):
        self.assertEqual(frames[0]["type"], "user")
        self.assertIs(frames[0]["isReplay"], True)
        failing = [f for f in frames if f.get("error") == "authentication_failed"]
        self.assertEqual(len(failing), 1, frames)
        line = failing[0]
        self.assertEqual(line["type"], "assistant")
        self.assertIs(line["isApiErrorMessage"], True)
        self.assertEqual(line["message"]["model"], "<synthetic>")
        self.assertEqual(line["message"]["role"], "assistant")
        self.assertEqual(line["message"]["usage"]["input_tokens"], 0)
        self.assertEqual(line["message"]["usage"]["output_tokens"], 0)
        self.assertEqual(line["message"]["content"], [{"type": "text", "text": AUTH_TEXT}])
        result = frames[-1]
        self.assertEqual(result["type"], "result")
        self.assertIs(result["is_error"], True)
        self.assertEqual(result["result"], AUTH_TEXT)
        # The failing assistant line comes right before the result.
        self.assertIs(frames[-2], line)

    def assert_normal_turn(self, frames):
        kinds = [f["type"] for f in frames]
        self.assertEqual(kinds, ["user", "assistant", "result"])
        self.assertEqual(frames[1]["message"]["content"], [{"type": "text", "text": "ok"}])
        self.assertNotIn("error", frames[1])
        self.assertIs(frames[2]["is_error"], False)
        self.assertEqual(frames[2]["result"], "done")

    def test_expired_login_echoes_the_message_then_fails_with_the_synthetic_auth_line(self):
        fake = self.fake(self.auth_file("expired"))
        frames = self.turn(fake)
        self.assertEqual(len(frames), 3)
        self.assert_failed_turn(frames)

    def test_the_echo_of_a_failed_turn_carries_the_sent_message(self):
        fake = self.fake(self.auth_file("expired"))
        frames = self.turn(fake, "hello there")
        self.assertEqual(frames[0]["message"]["content"], "hello there")

    def test_an_ok_file_gives_a_normal_turn(self):
        fake = self.fake(self.auth_file("ok"))
        self.assert_normal_turn(self.turn(fake))

    def test_a_missing_file_gives_a_normal_turn(self):
        path = self.auth_file()
        self.assertFalse(os.path.exists(path))
        fake = self.fake(path)
        self.assert_normal_turn(self.turn(fake))

    def test_no_auth_env_var_gives_a_normal_turn(self):
        fake = self.fake(None)
        self.assert_normal_turn(self.turn(fake))

    def test_an_empty_or_unknown_value_means_ok(self):
        for value in ("", "banana", "EXPIRED-ish"):
            with self.subTest(value=value):
                fake = self.fake(self.auth_file(value))
                self.assert_normal_turn(self.turn(fake))

    def test_the_file_is_read_on_each_message_so_the_login_can_flip_mid_session(self):
        path = self.auth_file("ok")
        fake = self.fake(path)
        self.assert_normal_turn(self.turn(fake))
        self.set_auth(path, "expired")
        self.assert_failed_turn(self.turn(fake))
        self.assert_failed_turn(self.turn(fake))
        self.set_auth(path, "ok")
        self.assert_normal_turn(self.turn(fake))

    def test_sticky_mode_reads_the_file_once_at_startup(self):
        path = self.auth_file("expired")
        fake = self.fake(path, sticky=True)
        self.assert_failed_turn(self.turn(fake))
        self.set_auth(path, "ok")
        self.assert_failed_turn(self.turn(fake))

    def test_sticky_mode_started_ok_stays_ok_after_the_file_flips(self):
        path = self.auth_file("ok")
        fake = self.fake(path, sticky=True)
        self.assert_normal_turn(self.turn(fake))
        self.set_auth(path, "expired")
        self.assert_normal_turn(self.turn(fake))

    def test_sticky_mode_rereads_the_file_in_each_new_process(self):
        path = self.auth_file("expired")
        first = self.fake(path, sticky=True)
        self.assert_failed_turn(self.turn(first))
        self.set_auth(path, "ok")
        second = self.fake(path, sticky=True)
        self.assert_normal_turn(self.turn(second))

    def test_midturn_cue_while_expired_runs_a_bash_tool_call_before_failing(self):
        fake = self.fake(self.auth_file("expired"))
        frames = self.turn(fake, "please AUTH_MIDTURN now")
        self.assertEqual([f["type"] for f in frames], ["user", "assistant", "user", "assistant", "result"])
        tool_use = frames[1]["message"]["content"][0]
        self.assertEqual(tool_use["type"], "tool_use")
        self.assertEqual(tool_use["name"], "Bash")
        tool_result = frames[2]["message"]["content"][0]
        self.assertEqual(tool_result["type"], "tool_result")
        self.assertEqual(tool_result["tool_use_id"], tool_use["id"])
        self.assertIs(tool_result["is_error"], False)
        self.assertEqual(frames[3]["error"], "authentication_failed")
        self.assertIs(frames[4]["is_error"], True)
        self.assertEqual(frames[4]["result"], AUTH_TEXT)

    def test_midturn_cue_while_ok_is_ignored(self):
        fake = self.fake(self.auth_file("ok"))
        self.assert_normal_turn(self.turn(fake, "please AUTH_MIDTURN now"))

    def test_midturn_cue_turn_after_the_login_recovers_is_normal(self):
        path = self.auth_file("expired")
        fake = self.fake(path)
        self.turn(fake, "AUTH_MIDTURN")
        self.set_auth(path, "ok")
        self.assert_normal_turn(self.turn(fake, "AUTH_MIDTURN"))

    def test_stdin_log_records_every_message_verbatim_failed_or_not(self):
        path = self.auth_file("expired")
        fake = self.fake(path)
        sent = [user("first AUTH_MIDTURN"), user("second")]
        for frame in sent:
            fake.send(frame)
            fake.until_result()
        self.set_auth(path, "ok")
        sent.append(user("third"))
        fake.send(sent[-1])
        fake.until_result()
        self.assertEqual(fake.jsonl("stdin.jsonl"), sent)

    def test_die_cue_while_ok_echoes_the_message_then_the_process_dies_without_a_result(self):
        fake = self.fake(self.auth_file("ok"))
        echo = fake.cue("please DIE_MIDTURN now")
        self.assertEqual(echo["message"]["content"], "please DIE_MIDTURN now")
        self.assertIsNone(fake.frames.get(timeout=TIMEOUT), "nothing after the echo, then EOF")
        self.assertEqual(fake.proc.wait(timeout=TIMEOUT), -signal.SIGKILL)

    def test_die_cue_while_expired_is_an_ordinary_auth_failure_and_the_process_lives(self):
        fake = self.fake(self.auth_file("expired"))
        self.assert_failed_turn(self.turn(fake, "please DIE_MIDTURN now"))
        self.assertIsNone(fake.proc.poll())

    def test_hang_cue_while_ok_echoes_the_message_and_never_ends_the_turn(self):
        fake = self.fake(self.auth_file("ok"))
        fake.cue("please HANG_MIDTURN now")
        self.assertTrue(fake.no_more_frames(grace=0.5))
        self.assertIsNone(fake.proc.poll(), "still alive")

    def test_hang_cue_while_expired_is_an_ordinary_auth_failure(self):
        fake = self.fake(self.auth_file("expired"))
        self.assert_failed_turn(self.turn(fake, "please HANG_MIDTURN now"))

    def test_a_process_that_hung_still_answers_the_next_message(self):
        fake = self.fake(self.auth_file("ok"))
        fake.cue("HANG_MIDTURN")
        self.assert_normal_turn(self.turn(fake, "next"))

    def test_the_auth_file_is_never_written_by_the_fake(self):
        path = self.auth_file("expired")
        fake = self.fake(path)
        self.turn(fake)
        with open(path, encoding="utf-8") as f:
            self.assertEqual(f.read(), "expired")


class HygieneTest(unittest.TestCase):
    def test_fake_requires_the_log_dir_env_var(self):
        proc = subprocess.run([sys.executable, "-I", os.path.abspath(FAKE)], input=b"",
                              capture_output=True, env={"PATH": os.environ.get("PATH", "")},
                              timeout=TIMEOUT)
        self.assertNotEqual(proc.returncode, 0)

    def test_fake_writes_only_inside_the_log_dir(self):
        fake = Fake(self)
        fake.start()
        fake.cue("FIXTURE:simple_rm")
        fake.take(2)
        fake.close_stdin_and_wait()
        self.assertEqual(sorted(os.listdir(fake.log_dir)),
                         ["argv.json", "responses.jsonl", "stdin.jsonl"])


if __name__ == "__main__":
    unittest.main()
