"""Terminal QA helpers that talk to the QA daemon's MCP socket (never the user's).

    terminal_qa.py open-terminal QA_ROOT FOCUS_TAG
    terminal_qa.py request-remote-shell QA_ROOT FOCUS_TAG PROJECT ENVIRONMENT SERVICE SHELL_TYPE REASON [WAIT_SECS]
    terminal_qa.py list-terminals QA_ROOT FOCUS_TAG
    terminal_qa.py request-follow QA_ROOT FOCUS_TAG TERMINAL_ID REASON [WAIT_SECS]

Acts as an agent in the focus FOCUS_TAG (the Hello `pty_id`, a built-in focus tag such as `mother`).
`open-terminal` calls `nostromo.open_terminal`: the daemon opens a terminal pane in that focus, which must
NOT take keyboard focus in the app. Prints the tool's outcome ({ok, terminal_id, pane_id}). Exit 0 on `ok`.
`request-remote-shell` calls `nostromo.request_remote_shell` and blocks until the person at the app answers
the "Connect to ..." sheet (or the daemon's wait ends, 10 s in a QA daemon given
NOSTROMO_QA_REMOTE_SHELL_TIMEOUT_SECS=10). Prints the outcome ({ok, outcome, ...} or {error, ...}); exit 0
on `ok`. WAIT_SECS (default 330) is how long this client waits for the reply.
`list-terminals` calls `nostromo.list_terminals` (the terminals of FOCUS_TAG's own focus, ids included).
`request-follow` calls `nostromo.request_follow`: the person at the app answers a decision sheet; the outcome
is {ok, outcome: "following"} or {error: denied | dismissed | timeout | no_operator | ...}.

The socket path is checked with `qa_instance.guard_socket_path`: anything outside the QA root, or under
the user's `~/.nostromo`, is refused.
"""
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qa_instance  # noqa: E402  (same directory)

TOOL = "nostromo.open_terminal"
REMOTE_TOOL = "nostromo.request_remote_shell"


def open_terminal(qa_root, focus_tag, timeout=30):
    return call_tool(qa_root, focus_tag, TOOL, {}, timeout)


def request_remote_shell(qa_root, focus_tag, project, environment, service, shell_type, reason, timeout=330):
    arguments = {"project": project, "environment": environment, "service": service,
                 "shell_type": shell_type, "reason": reason}
    return call_tool(qa_root, focus_tag, REMOTE_TOOL, arguments, timeout)


def list_terminals(qa_root, focus_tag, timeout=30):
    return call_tool(qa_root, focus_tag, "nostromo.list_terminals", {}, timeout)


def request_follow(qa_root, focus_tag, terminal_id, reason, timeout=330):
    return call_tool(qa_root, focus_tag, "nostromo.request_follow",
                     {"terminal_id": terminal_id, "reason": reason}, timeout)


def set_pane_layout(qa_root, focus_tag, ratios, timeout=30):
    return call_tool(qa_root, focus_tag, "nostromo.set_pane_layout", {"view_id": focus_tag, "ratios": ratios}, timeout)


def call_tool(qa_root, focus_tag, tool, arguments, timeout):
    path = qa_instance.guard_socket_path(qa_root, os.path.join(qa_root, qa_instance.MCP_SOCKET))
    frames = [
        {"type": "hello", "pty_id": focus_tag},
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "qa-terminal", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": arguments}},
    ]
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(path)
        reader = sock.makefile("rb")
        responses = {}
        for frame in frames:
            sock.sendall(json.dumps(frame).encode() + b"\n")
            if "id" in frame:
                line = reader.readline()
                if not line:
                    raise RuntimeError("the QA daemon's MCP socket closed without answering")
                responses[frame["id"]] = json.loads(line)
    reply = responses[2]
    if "error" in reply:
        raise RuntimeError(f"{tool}: JSON-RPC error {reply['error']}")
    try:
        outcome = json.loads(reply["result"]["content"][0]["text"])
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise RuntimeError(f"{tool}: unreadable reply {reply!r}: {e}")
    return outcome


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    try:
        if command == "open-terminal" and len(argv) == 4:
            outcome = open_terminal(argv[2], argv[3])
        elif command == "request-remote-shell" and len(argv) in (9, 10):
            wait = float(argv[9]) if len(argv) == 10 else 330
            outcome = request_remote_shell(argv[2], argv[3], *argv[4:9], timeout=wait)
        elif command == "list-terminals" and len(argv) == 4:
            outcome = list_terminals(argv[2], argv[3])
        elif command == "request-follow" and len(argv) in (6, 7):
            wait = float(argv[6]) if len(argv) == 7 else 330
            outcome = request_follow(argv[2], argv[3], argv[4], argv[5], timeout=wait)
        elif command == "set-pane-layout" and len(argv) == 5:
            outcome = set_pane_layout(argv[2], argv[3], json.loads(argv[4]))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except (ValueError, RuntimeError, OSError) as e:
        print(f"{command} failed: {e}", file=sys.stderr)
        return 1
    print(json.dumps(outcome, sort_keys=True))
    return 0 if outcome.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
