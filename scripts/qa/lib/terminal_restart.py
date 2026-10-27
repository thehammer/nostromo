"""Restart ONLY the QA instance's own app or daemon, for terminal-mirror-relaunch.sh.

    terminal_restart.py kill-app QA_ROOT        SIGTERM the clone app recorded in QA_ROOT/state.json
    terminal_restart.py start-app QA_ROOT       start the clone again, same environment as `start`
    terminal_restart.py kill-daemon QA_ROOT     SIGTERM the QA nostromd recorded in state.json
    terminal_restart.py start-daemon QA_ROOT    start the QA nostromd again, same HOME and environment

Each process is touched only when its pid in state.json is still the very process the instance started
(its recorded start time matches), never by name or pattern, and QA_ROOT must carry the QA root marker.
The user's own app and daemon are never named, signalled or started here. The new pids are written back
to state.json so `qa-instance.sh stop` still stops exactly what this instance owns.
"""
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qa_instance as qi  # noqa: E402  (same directory)


def _recorded_pid(state, key):
    """The pid of the process the instance recorded under `key` ("app" or "daemon") if it is still it."""
    pid = state.get(f"{key}_pid")
    if pid and qi.is_recorded_process(pid, state.get(f"{key}_start")):
        return pid
    return None


def kill(qa_root, key):
    state = qi.load_state(qa_root)
    pid = _recorded_pid(state, key)
    if pid is None:
        print(f"the QA {key} is not running (pid in state.json is gone or reused); nothing to kill")
        return 0
    qi.kill_pid(pid)
    return 0


def _socket_accepts(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        try:
            s.connect(path)
            return True
        except OSError:
            return False


def start_daemon(qa_root):
    state = qi.load_state(qa_root)
    if _recorded_pid(state, "daemon") is not None:
        print("the QA daemon is still running; kill-daemon first", file=sys.stderr)
        return 1
    fake_claude = os.path.join(qi.REPO, "scripts", "qa", "fake-claude")
    guard_bin = os.path.join(qi.REPO, "target", "debug", "nostromo-guard")
    sock = os.path.join(qa_root, "nostromd.sock")
    d = qi.spawn([os.path.join(qi.REPO, "target", "debug", "nostromd")],
                 qi.daemon_env(qa_root, os.environ, fake_claude, guard_bin),
                 os.path.join(qa_root, "nostromd.log"))
    state["daemon_pid"] = d.pid
    state["daemon_start"] = qi.proc_start(d.pid)
    qi.save_state(qa_root, state)
    qi.wait_for(lambda: d.poll() is None and _socket_accepts(sock), 30, "the QA daemon socket")
    return 0


def start_app(qa_root):
    state = qi.load_state(qa_root)
    if _recorded_pid(state, "app") is not None:
        print("the QA app is still running; kill-app first", file=sys.stderr)
        return 1
    clone = os.path.join(qa_root, "Nostromo.app")
    a = qi.spawn([os.path.join(clone, "Contents", "MacOS", "Nostromo")],
                 qi.app_env(qa_root, os.environ, state.get("synthetic", True)),
                 os.path.join(qa_root, "app.log"))
    state["app_pid"] = a.pid
    state["app_start"] = qi.proc_start(a.pid)
    qi.save_state(qa_root, state)
    ctl = os.path.join(qa_root, "app-control.sock")
    qi.wait_for(lambda: a.poll() is None
                and qi.run([os.path.join(qi.REPO, "bin", "nostromo-app"), "--socket", ctl, "ping"]).returncode == 0,
                60, "the QA app's control socket")
    return 0


ACTIONS = {
    "kill-app": lambda root: kill(root, "app"),
    "start-app": start_app,
    "kill-daemon": lambda root: kill(root, "daemon"),
    "start-daemon": start_daemon,
}


def main(argv):
    if len(argv) != 3 or argv[1] not in ACTIONS:
        print(__doc__, file=sys.stderr)
        return 2
    root = qi.resolve_root(argv[2])
    try:
        return ACTIONS[argv[1]](root)
    except RuntimeError as e:
        print(f"{argv[1]} failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
