#!/usr/bin/env python3
"""Hermetic fake `claude` CLI for the permission-approval tests.

Launched by a /bin/sh wrapper the Rust test writes:

    FAKE_CLAUDE_LOG_DIR=<dir> exec python3 -I <abs>/fake_claude_perm.py "$@"

Stdlib only. Never touches the network, `~`, or anything outside
`$FAKE_CLAUDE_LOG_DIR` (plus read-only reads of its own fixtures under
`../fixtures/approvals/`).

It speaks the stream-json protocol the daemon expects (frames copied from the
real CLI 2.1.296 spike captures) and models the permission-prompt flow:

  * on start: argv -> `<logdir>/argv.json`, a `system`/`init` line on stdout;
  * every stdin line is appended verbatim to `<logdir>/stdin.jsonl`;
  * a `user` message is echoed back (`isReplay: true`), then its text is
    scanned for a cue:
        FIXTURE:<name>   emit the fixture's tool_use line and (only when argv
                         has `--permission-prompt-tool stdio`) its
                         control_request lines, then wait for answers;
        CANCEL:<name>    like FIXTURE, but withdraw each request at once;
        runs_freely      an unprompted Bash `git status`;
        (no cue)         a short "ok" turn;
  * `control_response` answers are logged to `<logdir>/responses.jsonl`;
  * a daemon `control_request` with subtype `interrupt` is answered the way
    the real CLI does (captures/run-interrupt.jsonl);
  * EOF on stdin -> exit 0.

The main loop is purely event driven (one stdin line in, zero or more frames
out), so any number of cues can be in flight at once and answers can arrive
in any order.
"""
import json
import os
import re
import sys
import time
import uuid

FIXTURE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "approvals"
)
MODEL = "claude-haiku-4-5"
CUE_RE = re.compile(r"\b(FIXTURE|CANCEL):([A-Za-z0-9_]+)")
NO_GRANT = "Claude requested permissions to use {tool}, but you haven't granted it yet."
USER_REJECTED = (
    "The user doesn't want to proceed with this tool use. The tool use was rejected "
    "(eg. if it was a file edit, the new_string was NOT written to the file). STOP "
    "what you are doing and wait for the user to tell you how to proceed."
)
INTERRUPTED_TEXT = "[Request interrupted by user for tool use]"


def now_iso():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def arg_value(argv, flag):
    """Value following a standalone `flag` in argv, or None."""
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None


class FakeClaude:
    def __init__(self, argv, log_dir):
        self.argv = argv
        self.log_dir = log_dir
        self.session_id = (
            arg_value(argv, "--session-id") or arg_value(argv, "--resume") or str(uuid.uuid4())
        )
        # Only a standalone `--permission-prompt-tool` followed by `stdio` counts.
        self.prompts_enabled = arg_value(argv, "--permission-prompt-tool") == "stdio"
        self.out = sys.stdout.buffer
        self.stdin_log = open(os.path.join(log_dir, "stdin.jsonl"), "ab")
        self.responses_log = open(os.path.join(log_dir, "responses.jsonl"), "ab")
        self.msg_counter = 0
        self.groups = []  # cue groups (turns), in creation order
        self.requests = {}  # cli request_id -> dict(tool_use_id, tool_name, input, group, state)

    # ---- output ----------------------------------------------------------

    def emit(self, obj):
        data = json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode("ascii")
        self.out.write(data + b"\n")
        self.out.flush()

    def envelope(self, **extra):
        base = {
            "parent_tool_use_id": None,
            "session_id": self.session_id,
            "uuid": str(uuid.uuid4()),
            "timestamp": now_iso(),
        }
        base.update(extra)
        return base

    def emit_init(self):
        self.emit(
            {
                "type": "system",
                "subtype": "init",
                "cwd": os.getcwd(),
                "session_id": self.session_id,
                "tools": ["Bash", "Edit", "NotebookEdit", "Read", "Write"],
                "mcp_servers": [],
                "model": MODEL,
                "permissionMode": (
                    "bypassPermissions"
                    if "--dangerously-skip-permissions" in self.argv
                    else "default"
                ),
                "apiKeySource": "ANTHROPIC_API_KEY",
                "claude_code_version": "fake-perm",
                "output_style": "default",
                "uuid": str(uuid.uuid4()),
            }
        )

    def emit_assistant(self, content):
        self.msg_counter += 1
        self.emit(
            {
                "type": "assistant",
                "message": {
                    "id": "msg_%d" % (self.msg_counter - 1),
                    "type": "message",
                    "role": "assistant",
                    "model": MODEL,
                    "content": content,
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 5},
                    "context_management": None,
                },
                "parent_tool_use_id": None,
                "session_id": self.session_id,
                "uuid": str(uuid.uuid4()),
                "timestamp": now_iso(),
            }
        )

    def emit_text(self, text):
        self.emit_assistant([{"type": "text", "text": text}])

    def emit_tool_result_ok(self, tool_use_id, content="ok", source="user_temporary"):
        meta = {"id": tool_use_id, "permission_decision": {"decision": "accept", "source": source}}
        if source == "config":
            meta["permission_decision"]["reason_type"] = "mode"
        self.emit(
            self.envelope(
                type="user",
                message={
                    "role": "user",
                    "content": [
                        {
                            "tool_use_id": tool_use_id,
                            "type": "tool_result",
                            "content": content,
                            "is_error": False,
                        }
                    ],
                },
                tool_use_result={
                    "stdout": content,
                    "stderr": "",
                    "interrupted": False,
                    "isImage": False,
                    "noOutputExpected": False,
                },
                tool_result_meta=[meta],
            )
        )

    def emit_tool_result_error(self, tool_use_id, content, kind, decision_source=None):
        meta = {"id": tool_use_id, "non_execution_kind": kind}
        if decision_source is not None:
            meta["permission_decision"] = {"decision": "reject", "source": decision_source}
        self.emit(
            self.envelope(
                type="user",
                message={
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "content": content,
                            "is_error": True,
                            "tool_use_id": tool_use_id,
                        }
                    ],
                },
                tool_use_result=(
                    "User rejected tool use"
                    if kind == "user-rejected" and decision_source is None
                    else "Error: " + content
                ),
                tool_result_meta=[meta],
            )
        )

    def emit_interrupted_line(self):
        self.emit(
            self.envelope(
                type="user",
                message={
                    "role": "user",
                    "content": [{"type": "text", "text": INTERRUPTED_TEXT}],
                },
            )
        )

    def emit_result(self, denials=(), interrupted=False, error_text=None):
        if error_text is not None:
            subtype, is_error, stop, terminal, text = "error_during_execution", True, "end_turn", "error", error_text
        elif interrupted:
            subtype, is_error, stop, terminal, text = "error_during_execution", True, "tool_use", "aborted_tools", None
        else:
            subtype, is_error, stop, terminal, text = "success", False, "end_turn", "completed", "done"
        frame = {
            "duration_api_ms": 1,
            "stop_reason": stop,
            "session_id": self.session_id,
            "total_cost_usd": 0.0001,
            "usage": {
                "input_tokens": 10,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 5,
            },
            "permission_denials": list(denials),
            "terminal_reason": terminal,
            "is_error": is_error,
            "num_turns": 1,
            "subtype": subtype,
            "type": "result",
            "duration_ms": 5,
            "uuid": str(uuid.uuid4()),
            "queued_turn_count": 0,
            "result_index": 0,
        }
        if text is not None:
            frame["result"] = text
        if interrupted and error_text is None:
            frame["errors"] = ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"]
        self.emit(frame)

    # ---- stdin -----------------------------------------------------------

    def record_stdin(self, raw):
        self.stdin_log.write(raw if raw.endswith(b"\n") else raw + b"\n")
        self.stdin_log.flush()

    def record_response(self, request_id, tool_use_id, frame):
        line = {"request_id": request_id, "tool_use_id": tool_use_id, "response": frame}
        self.responses_log.write(json.dumps(line, ensure_ascii=True).encode("ascii") + b"\n")
        self.responses_log.flush()

    def run(self):
        with open(os.path.join(self.log_dir, "argv.json"), "w", encoding="utf-8") as f:
            json.dump(self.argv, f, ensure_ascii=True)
        self.emit_init()
        for raw in sys.stdin.buffer:
            self.record_stdin(raw)
            try:
                frame = json.loads(raw.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            if not isinstance(frame, dict):
                continue
            kind = frame.get("type")
            if kind == "user":
                self.on_user(frame)
            elif kind == "control_request":
                self.on_daemon_control_request(frame)
            elif kind == "control_response":
                self.on_control_response(frame)
        return 0

    # ---- user messages / cues -------------------------------------------

    @staticmethod
    def message_text(frame):
        content = (frame.get("message") or {}).get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(
                b.get("text", "")
                for b in content
                if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
            )
        return ""

    def on_user(self, frame):
        message = frame.get("message") or {}
        echo = self.envelope(
            type="user",
            message={"role": "user", "content": message.get("content")},
            isReplay=True,
        )
        if isinstance(frame.get("uuid"), str):
            echo["uuid"] = frame["uuid"]
        self.emit(echo)

        text = self.message_text(frame)
        cue = CUE_RE.search(text)
        if cue:
            self.run_fixture(cue.group(2), cancel=(cue.group(1) == "CANCEL"))
        elif "runs_freely" in text:
            self.run_freely()
        else:
            self.emit_text("ok")
            self.emit_result()

    def load_fixture(self, name):
        path = os.path.join(FIXTURE_DIR, name + ".json")
        try:
            with open(path, "r", encoding="utf-8") as f:
                fixture = json.load(f)
        except (OSError, ValueError) as e:
            sys.stderr.write("fake_claude_perm: cannot load fixture %r: %s\n" % (name, e))
            return None
        return fixture if isinstance(fixture, dict) else None

    def run_freely(self):
        tool_use_id = "toolu_free_0"
        self.emit_assistant(
            [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": "Bash",
                    "input": {"command": "git status", "description": "show status"},
                }
            ]
        )
        self.emit_tool_result_ok(tool_use_id, "On branch main", source="config")
        self.emit_text("done")
        self.emit_result()

    def run_fixture(self, name, cancel):
        fixture = self.load_fixture(name)
        if fixture is None:
            self.emit_text("fake_claude_perm: unknown fixture %s" % name)
            self.emit_result(error_text="unknown fixture %s" % name)
            return
        tool_uses = [
            {"type": "tool_use", "id": t["id"], "name": t["name"], "input": t["input"]}
            for t in fixture.get("tool_uses", [])
        ]
        self.emit_assistant(tool_uses)

        group = {"tool_uses": tool_uses, "denials": [], "emitted_results": set(), "done": False}
        self.groups.append(group)

        if not self.prompts_enabled:
            # Restricted session: the CLI never asks, it just refuses.
            for tu in tool_uses:
                self.finish_tool_use(
                    group,
                    tu["id"],
                    lambda tu=tu: self.emit_tool_result_error(
                        tu["id"], NO_GRANT.format(tool=tu["name"]), "user-rejected", "config"
                    ),
                    denied=True,
                )
            self.finish_group(group, say_done=False)
            return

        entries = fixture.get("requests", [])
        waiting = []
        for i, entry in enumerate(entries):
            request = entry["request"]
            request_id = str(uuid.uuid4())
            tool_use_id = request.get("tool_use_id")
            if not isinstance(tool_use_id, str) and i < len(tool_uses):
                tool_use_id = tool_uses[i]["id"]
            self.emit({"type": "control_request", "request_id": request_id, "request": request})
            waits = request.get("subtype") == "can_use_tool"
            self.requests[request_id] = {
                "tool_use_id": tool_use_id,
                "tool_name": request.get("tool_name"),
                "input": request.get("input"),
                "group": group,
                "state": "pending" if waits and not cancel else ("cancelled" if cancel else "answered"),
                "waits": waits,
            }
            if waits:
                waiting.append(request_id)

        if cancel:
            for request_id in waiting:
                self.emit({"type": "control_cancel_request", "request_id": request_id})
            self.reject_unfinished(group, kind="user-rejected")
            self.emit_interrupted_line()
            self.finish_group(group, interrupted=True)
            return

        group["waiting"] = set(waiting)
        # Tool uses that nobody is asking about run straight away.
        asked = {self.requests[r]["tool_use_id"] for r in waiting}
        for tu in tool_uses:
            if tu["id"] not in asked:
                self.finish_tool_use(group, tu["id"], lambda tu=tu: self.emit_tool_result_ok(tu["id"], "ok"))
        if not waiting:
            self.finish_group(group)

    # ---- group bookkeeping ---------------------------------------------------

    @staticmethod
    def finish_tool_use(group, tool_use_id, emit_fn, denied=False):
        if tool_use_id in group["emitted_results"]:
            return
        group["emitted_results"].add(tool_use_id)
        emit_fn()
        if denied:
            tu = next((t for t in group["tool_uses"] if t["id"] == tool_use_id), None)
            if tu is not None:
                group["denials"].append(
                    {"tool_name": tu["name"], "tool_use_id": tool_use_id, "tool_input": tu["input"]}
                )

    def reject_unfinished(self, group, kind):
        for tu in group["tool_uses"]:
            self.finish_tool_use(
                group,
                tu["id"],
                lambda tu=tu: self.emit_tool_result_error(tu["id"], USER_REJECTED, kind),
                denied=True,
            )

    def finish_group(self, group, interrupted=False, say_done=True):
        if group["done"]:
            return
        group["done"] = True
        if say_done and not interrupted:
            self.emit_text("done")
        self.emit_result(denials=group["denials"], interrupted=interrupted)

    # ---- control traffic from the daemon --------------------------------------

    def on_daemon_control_request(self, frame):
        request_id = frame.get("request_id")
        request = frame.get("request") if isinstance(frame.get("request"), dict) else {}
        if request.get("subtype") != "interrupt":
            self.emit(
                {
                    "type": "control_response",
                    "response": {"subtype": "success", "request_id": request_id, "response": {}},
                }
            )
            return
        pending = [(rid, r) for rid, r in self.requests.items() if r["state"] == "pending"]
        for rid, r in pending:
            self.emit({"type": "control_cancel_request", "request_id": rid})
            r["state"] = "cancelled"
        self.emit(
            {
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": request_id,
                    "response": {"still_queued": []},
                },
            }
        )
        affected = []
        for _, r in pending:
            if r["group"] not in affected:
                affected.append(r["group"])
        for group in affected:
            self.reject_unfinished(group, kind="user-rejected")
            self.emit_interrupted_line()
            self.finish_group(group, interrupted=True)

    def on_control_response(self, frame):
        response = frame.get("response") if isinstance(frame.get("response"), dict) else {}
        request_id = response.get("request_id")
        known = self.requests.get(request_id) if isinstance(request_id, str) else None
        self.record_response(request_id, known["tool_use_id"] if known else None, frame)
        if known is None or known["state"] != "pending":
            return  # late (after cancel/interrupt), duplicate, or never asked
        known["state"] = "answered"
        group = known["group"]
        tool_use_id = known["tool_use_id"]

        body = response.get("response") if isinstance(response.get("response"), dict) else {}
        allowed = response.get("subtype") == "success" and body.get("behavior") == "allow"
        if allowed:
            self.finish_tool_use(group, tool_use_id, lambda: self.emit_tool_result_ok(tool_use_id, "ok"))
        else:
            message = body.get("message")
            if not isinstance(message, str):
                message = response.get("error") if isinstance(response.get("error"), str) else "Permission denied"
            self.finish_tool_use(
                group,
                tool_use_id,
                lambda: self.emit_tool_result_error(tool_use_id, message, "permission-rule", "user_reject"),
                denied=True,
            )
        group["waiting"].discard(request_id)
        if not group["waiting"]:
            self.finish_group(group)


def main():
    log_dir = os.environ.get("FAKE_CLAUDE_LOG_DIR")
    if not log_dir:
        sys.stderr.write("fake_claude_perm: FAKE_CLAUDE_LOG_DIR is not set\n")
        return 2
    os.makedirs(log_dir, exist_ok=True)
    try:
        return FakeClaude(sys.argv[1:], log_dir).run()
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
