"""Terminal QA helpers that talk to the QA daemon's MCP socket (never the user's).

    terminal_qa.py open-terminal QA_ROOT FOCUS_TAG

Acts as an agent in the focus FOCUS_TAG (the Hello `pty_id`, a built-in focus tag such as `mother`)
and calls `nostromo.open_terminal`: the daemon opens a terminal pane in that focus, which must NOT take
keyboard focus in the app. Prints the tool's outcome ({ok, terminal_id, pane_id}). Exit 0 on `ok`.

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


def open_terminal(qa_root, focus_tag, timeout=30):
    path = qa_instance.guard_socket_path(qa_root, os.path.join(qa_root, qa_instance.MCP_SOCKET))
    frames = [
        {"type": "hello", "pty_id": focus_tag},
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "qa-terminal", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": TOOL, "arguments": {}}},
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
        raise RuntimeError(f"{TOOL}: JSON-RPC error {reply['error']}")
    try:
        outcome = json.loads(reply["result"]["content"][0]["text"])
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise RuntimeError(f"{TOOL}: unreadable reply {reply!r}: {e}")
    return outcome


def main(argv):
    if len(argv) != 4 or argv[1] != "open-terminal":
        print(__doc__, file=sys.stderr)
        return 2
    try:
        outcome = open_terminal(argv[2], argv[3])
    except (ValueError, RuntimeError, OSError) as e:
        print(f"could not open a terminal: {e}", file=sys.stderr)
        return 1
    print(json.dumps(outcome, sort_keys=True))
    return 0 if outcome.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
