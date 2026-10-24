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
        RAW:<kind>[:<arg>]
                         emit one hand-built (possibly broken) line, see RAW
                         CUES below; the turn waits for an answer only for the
                         kinds that expect one;
        runs_freely      an unprompted Bash `git status`;
        (no cue)         a short "ok" turn;
  * `control_response` answers are logged to `<logdir>/responses.jsonl`;
  * a daemon `control_request` with subtype `interrupt` is answered the way
    the real CLI does (captures/run-interrupt.jsonl);
  * EOF on stdin -> exit 0.

AUTH MODE (an expired Claude login, for the daemon's sign-in handling):

  `FAKE_CLAUDE_AUTH_FILE=<path>` names a file holding `ok` or `expired` (a
  missing, empty or unknown value means `ok`). It is read on EACH user message,
  so a test flips the login by rewriting the file; with `FAKE_CLAUDE_AUTH_STICKY=1`
  it is read once at startup only, like a live CLI that cached a bad credential
  (a restart picks the new value up). While `expired`, every user message is
  echoed as usual and then fails the way the real CLI 2.1.301 does: one synthetic
  assistant line (`error: authentication_failed`, `model: <synthetic>`, zero
  tokens) and an `is_error` result carrying the same text. The cue AUTH_MIDTURN
  in the message makes the fake run a real `Bash` tool call (and its result)
  before failing: a turn that did real work. With the login `ok`, AUTH_MIDTURN
  is ignored. Nothing is ever read from `~` and no network is touched.

  Two more cues act only while the login is `ok` (while `expired` they are ignored
  and the turn fails as above), for a message that was written again after a failure:
    DIE_MIDTURN   echo the message, then die abruptly: SIGKILL to itself, so no
                  `result` frame, no exit code, nothing flushed after the echo;
    HANG_MIDTURN  echo the message, then never end the turn (no further frame for
                  it), while staying alive and answering later control traffic.

RAW CUES (hand-built lines, concatenated as text so nothing here recurses or
overflows the way a naive json.dumps of a deeply nested value would):

  Answered (the turn waits for the daemon's control_response; `<N>` is the
  nesting depth of an array placed in `input.n`):
    deep:<N>             can_use_tool, uuid request_id, input nested N deep
    deep_id_last:<N>     same, `request_id` is the last top-level key
    deep_type_last:<N>   same, `type` is the last top-level key
    deep_subtype_last:<N> same, `request.subtype` comes after `input`
    deep_decoys:<N>      same, `input` carries decoy request_id/subtype/tool_name
    numid                small, readable can_use_tool whose request_id is the number 7
    numid_deep:<N>       numeric request_id 7, input nested N deep
    oversize             valid can_use_tool line longer than 4 MiB
    truncated            can_use_tool cut off in the middle of `input`
    malformed            can_use_tool with a syntax error after the id/subtype/tool_name
    escaped_id           request_id full of JSON escapes, then a syntax error
    id_only              cut off before `request.subtype`
    other:<subtype>      a readable control_request of another subtype
    other_deep:<subtype> unreadable (deep) control_request of another subtype
  Not answered (the daemon must not write anything; the fake ends the turn):
    no_id                control_request cut off before request_id
    object_id            readable control_request whose request_id is an object
    garbage              not JSON at all
    bad_assistant        an `assistant` line cut off in the middle
    unknown_type         valid JSON, `type` is not one we know
    deep_assistant:<N>   an `assistant` line nested N deep
    nested_type:<N>      `assistant` whose nested object looks like a control_request

The main loop is purely event driven (one stdin line in, zero or more frames
out), so any number of cues can be in flight at once and answers can arrive
in any order.
"""
import json
import os
import re
import signal
import sys
import time
import uuid

FIXTURE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "approvals"
)
MODEL = "claude-haiku-4-5"
CUE_RE = re.compile(r"\b(FIXTURE|CANCEL):([A-Za-z0-9_]+)")
RAW_RE = re.compile(r"\bRAW:([a-z_]+)(?::([A-Za-z0-9_]+))?")
OVERSIZE_BYTES = 4 * 1024 * 1024 + 64 * 1024
RAW_MARK = "ZZ-GARBAGE-MARK-ZZ"
NO_GRANT = "Claude requested permissions to use {tool}, but you haven't granted it yet."
USER_REJECTED = (
    "The user doesn't want to proceed with this tool use. The tool use was rejected "
    "(eg. if it was a file edit, the new_string was NOT written to the file). STOP "
    "what you are doing and wait for the user to tell you how to proceed."
)
INTERRUPTED_TEXT = "[Request interrupted by user for tool use]"
AUTH_FAILURE_TEXT = "Failed to authenticate: OAuth session expired and could not be refreshed"
AUTH_MIDTURN_CUE = "AUTH_MIDTURN"
DIE_MIDTURN_CUE = "DIE_MIDTURN"
HANG_MIDTURN_CUE = "HANG_MIDTURN"


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
        self.auth_file = os.environ.get("FAKE_CLAUDE_AUTH_FILE") or None
        self.auth_sticky = os.environ.get("FAKE_CLAUDE_AUTH_STICKY") == "1"
        self.auth_at_start = self.read_auth() if self.auth_sticky else None
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

    # ---- auth mode ---------------------------------------------------------

    def read_auth(self):
        """`expired` or `ok`, from FAKE_CLAUDE_AUTH_FILE (anything else is `ok`)."""
        if not self.auth_file:
            return "ok"
        try:
            with open(self.auth_file, "r", encoding="utf-8") as f:
                value = f.read().strip()
        except OSError:
            return "ok"
        return "expired" if value == "expired" else "ok"

    def login_expired(self):
        state = self.auth_at_start if self.auth_sticky else self.read_auth()
        return state == "expired"

    def emit_auth_failure(self, midturn):
        if midturn:
            tool_use_id = "toolu_auth_0"
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
        self.emit(
            {
                "type": "assistant",
                "error": "authentication_failed",
                "isApiErrorMessage": True,
                "message": {
                    "id": "msg_synthetic",
                    "type": "message",
                    "model": "<synthetic>",
                    "role": "assistant",
                    "stop_reason": "stop_sequence",
                    "stop_sequence": "",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                    "content": [{"type": "text", "text": AUTH_FAILURE_TEXT}],
                },
                "parent_tool_use_id": None,
                "session_id": self.session_id,
                "uuid": str(uuid.uuid4()),
                "timestamp": now_iso(),
                "entrypoint": "sdk-cli",
            }
        )
        self.emit_result(error_text=AUTH_FAILURE_TEXT)

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
        if self.login_expired():
            self.emit_auth_failure(AUTH_MIDTURN_CUE in text)
            return
        if DIE_MIDTURN_CUE in text:
            # Abrupt death mid-turn: the echo is out, the turn never ends.
            self.out.flush()
            os.kill(os.getpid(), signal.SIGKILL)
        if HANG_MIDTURN_CUE in text:
            return
        cue = CUE_RE.search(text)
        raw = RAW_RE.search(text)
        if raw and not cue:
            self.run_raw(raw.group(1), raw.group(2))
        elif cue:
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

    # ---- hand-built lines (RAW cues) -----------------------------------------

    @staticmethod
    def request_key(request_id):
        """Key of a request in `self.requests`: the id itself for a string, a
        `json:` prefixed rendering for anything else (a number, say)."""
        if isinstance(request_id, str):
            return request_id
        try:
            return "json:" + json.dumps(request_id, sort_keys=True)
        except (TypeError, ValueError):
            return None

    def write_raw(self, text):
        """One stdout line, exactly as given (no JSON encoding)."""
        assert "\n" not in text
        self.out.write(text.encode("utf-8") + b"\n")
        self.out.flush()

    @staticmethod
    def nested(depth):
        """`[[[...]]]`, `depth` levels, built by repetition (no recursion)."""
        return "[" * depth + "]" * depth

    def raw_spec(self, kind, arg):
        """(lines, key, tool_use_id): the lines to write, the key of the request
        the daemon is expected to answer (None: no answer expected), and the tool
        use the turn is about. `None` for an unknown kind."""
        uid = str(uuid.uuid4())
        id_json = json.dumps(uid)
        depth = int(arg) if arg is not None and arg.isdigit() else 0
        tool_use_id = "toolu_%s_%s" % (kind, arg if arg is not None else 0)
        small = '{"command":"rm -rf /tmp/x"}'
        deep_input = '{"command":"rm -rf /tmp/x","n":' + self.nested(depth) + "}"

        def request(subtype_json, input_json, subtype_last=False):
            tool = '"tool_name":"Bash","display_name":"Bash"'
            tail = '"description":"d","tool_use_id":"%s"' % tool_use_id
            if subtype_last:
                return '{%s,"input":%s,%s,"subtype":%s}' % (tool, input_json, tail, subtype_json)
            return '{"subtype":%s,%s,"input":%s,%s}' % (subtype_json, tool, input_json, tail)

        can = '"can_use_tool"'
        envelope = '{"type":"control_request","request_id":%s,"request":%s}'

        def answered(line, key=uid):
            return [line], key, tool_use_id

        def ignored(line):
            return [line], None, tool_use_id

        if kind == "deep":
            return answered(envelope % (id_json, request(can, deep_input)))
        if kind == "deep_id_last":
            return answered('{"type":"control_request","request":%s,"request_id":%s}' % (request(can, deep_input), id_json))
        if kind == "deep_type_last":
            return answered('{"request_id":%s,"request":%s,"type":"control_request"}' % (id_json, request(can, deep_input)))
        if kind == "deep_subtype_last":
            return answered(envelope % (id_json, request(can, deep_input, subtype_last=True)))
        if kind == "deep_decoys":
            decoy = ('{"request_id":"evil-id","subtype":"elicitation","tool_name":"Evil",'
                     '"type":"assistant","request":{"subtype":"elicitation"},"n":%s}' % self.nested(depth))
            return answered(envelope % (id_json, request(can, decoy)))
        if kind == "numid":
            return answered(envelope % ("7", request(can, small)), key=self.request_key(7))
        if kind == "numid_deep":
            return answered(envelope % ("7", request(can, deep_input)), key=self.request_key(7))
        if kind == "oversize":
            big = '{"command":"%s"}' % ("x" * OVERSIZE_BYTES)
            return answered(envelope % (id_json, request(can, big)))
        if kind == "truncated":
            line = envelope % (id_json, request(can, small))
            return answered(line[: line.index("rm -rf") + 6])
        if kind == "malformed":
            return answered('{"type":"control_request","request_id":%s,"request":{"subtype":"can_use_tool","tool_name":"Bash","input":}}' % id_json)
        if kind == "escaped_id":
            decoded = 'ab"c\\d\u00e9 \U0001F600\n'
            return answered(
                '{"type":"control_request","request_id":%s,"request":{"subtype":"can_use_tool","tool_name":"Bash","input":}}'
                % json.dumps(decoded, ensure_ascii=True),
                key=decoded,
            )
        if kind == "id_only":
            return answered('{"type":"control_request","request_id":%s,"request":{"input":{"command":"rm' % id_json)
        if kind == "other" and arg:
            return answered(envelope % (id_json, '{"subtype":%s,"note":"x","tool_use_id":"%s"}' % (json.dumps(arg), tool_use_id)))
        if kind == "other_deep" and arg:
            return answered(envelope % (id_json, '{"subtype":%s,"input":{"n":%s}}' % (json.dumps(arg), self.nested(500))))
        if kind == "no_id":
            return ignored('{"type":"control_request","request":{"subtype":"can_use_tool"')
        if kind == "object_id":
            return ignored('{"type":"control_request","request_id":{"a":1},"request":{"subtype":"can_use_tool","tool_name":"Bash","input":%s}}' % small)
        if kind == "garbage":
            return ignored("this is not json at all %s {{{" % RAW_MARK)
        if kind == "bad_assistant":
            return ignored('{"type":"assistant","message":{"content":[{"type":"text","text":"%s' % RAW_MARK)
        if kind == "unknown_type":
            return ignored('{"type":"frobnicate","request_id":"x1","request":{"subtype":"can_use_tool","tool_name":"Bash","note":"%s"}}' % RAW_MARK)
        if kind == "deep_assistant":
            return ignored('{"type":"assistant","message":{"content":[],"n":%s,"note":"%s"}}' % (self.nested(depth), RAW_MARK))
        if kind == "nested_type":
            return ignored(
                '{"type":"assistant","message":{"type":"control_request","request_id":"evil-id",'
                '"request":{"subtype":"can_use_tool","tool_name":"Bash"},"n":%s,"note":"%s"}}' % (self.nested(depth), RAW_MARK)
            )
        return None

    def run_raw(self, kind, arg):
        spec = self.raw_spec(kind, arg)
        if spec is None:
            self.emit_text("fake_claude_perm: unknown raw cue %s" % kind)
            self.emit_result(error_text="unknown raw cue %s" % kind)
            return
        lines, key, tool_use_id = spec
        if key is None:
            for line in lines:
                self.write_raw(line)
            self.emit_text("ok")
            self.emit_result()
            return
        tool_uses = [{"type": "tool_use", "id": tool_use_id, "name": "Bash", "input": {"command": "rm -rf /tmp/x"}}]
        self.emit_assistant(tool_uses)
        group = {"tool_uses": tool_uses, "denials": [], "emitted_results": set(), "done": False, "waiting": {key}}
        self.groups.append(group)
        self.requests[key] = {
            "tool_use_id": tool_use_id,
            "tool_name": "Bash",
            "input": None,
            "group": group,
            "state": "pending",
            "waits": True,
        }
        for line in lines:
            self.write_raw(line)

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
        key = self.request_key(request_id)
        known = self.requests.get(key)
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
        group["waiting"].discard(key)
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
