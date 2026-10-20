#!/usr/bin/env python3
"""Isolated QA instance: a worktree `nostromd` plus a cloned `com.hammer.nostromo.qa` app.

    scripts/qa/qa-instance.sh [start [--no-synthetic]] | env | status | focus | stop   (see that script)

Never touches the user's running Nostromo, `nostromd`, sockets or `~/.nostromo`. Everything the
instance owns lives under a fresh temp directory (QA_ROOT) with its own HOME. Before `start` and
after `stop` an isolation guard snapshots the user's state and fails loudly if any of it changed.
Stdlib only; run with `python3 -I`.
"""
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
QA_BUNDLE_ID = "com.hammer.nostromo.qa"
USER_BUNDLE_ID = "com.hammer.nostromo"
SYNTHETIC_ENV = "NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT"
ROOT_MARKER = ".nostromo-qa-root"

# The user's files the guard hashes, relative to the user's ~/.nostromo.
WATCHED_FILES = ("focuses.json", "daemon-panes.json", "daemon-sessions.json", "daemon-terminals.json")
APPROVALS_DIR = "approvals"
CONTROL_SOCKET = "app-control.sock"
# The user's daemon appends to its own `audit-YYYY-MM-DD.jsonl` whenever real agent traffic asks for
# an approval. That is not the QA run's doing: append-only growth is allowed (see `audit_problems`).
AUDIT_FILE = re.compile(r"^audit-\d{4}-\d{2}-\d{2}\.jsonl$")
MCP_SOCKET = "mcp.sock"
# The session the harness drives: a daemon-created focus running the fake CLI, shown in the sidebar by its label.
QA_FOCUS_LABEL = "QA approvals"
QA_FOCUS_TITLE = "qa-approvals"
QA_FOCUS_AGENT = "cody"
# Process names that must not be started by a QA run (the user's own stay as they were).
MONITORED = ("nostromd", "claude")


# ── pure helpers (unit-tested) ───────────────────────────────────────────────


def rewrite_clone_plist(info):
    """Info.plist dict of the app -> the same with the QA bundle id."""
    out = dict(info)
    out["CFBundleIdentifier"] = QA_BUNDLE_ID
    return out


def file_sha256(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def dir_listing(path):
    """{relative file path: size} for every file under `path`; None if it does not exist."""
    if not os.path.isdir(path):
        return None
    out = {}
    for base, _dirs, files in os.walk(path):
        for name in files:
            full = os.path.join(base, name)
            try:
                out[os.path.relpath(full, path)] = os.stat(full).st_size
            except OSError:
                out[os.path.relpath(full, path)] = None
    return out


def socket_inode(path):
    try:
        return os.stat(path).st_ino
    except OSError:
        return None


def parse_processes(ps_output, exclude_marker=None):
    """`ps -axo pid,command` text -> [{pid, name, command}] for monitored processes and the
    Nostromo app. Lines containing `exclude_marker` (the QA root) are the instance's own."""
    found = []
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid, command = int(parts[0]), parts[1]
        if exclude_marker and exclude_marker in command:
            continue
        exe = command.split(None, 1)[0]
        base = os.path.basename(exe)
        if "/Nostromo.app/Contents/MacOS/" in exe:
            name = "Nostromo"
        elif base in MONITORED:
            name = base
        else:
            continue
        found.append({"pid": pid, "name": name, "command": command})
    return found


def process_view(procs):
    """{name: sorted pids}."""
    view = {}
    for p in procs:
        view.setdefault(p["name"], []).append(p["pid"])
    return {k: sorted(v) for k, v in view.items()}


def audit_files(approvals_path):
    """{name: {"len": n, "sha256": hash of those n bytes}} for the top-level `audit-*.jsonl` files.

    Lengths and hashes only: the user's audit content never enters a snapshot or any output."""
    out = {}
    if not os.path.isdir(approvals_path):
        return out
    for name in sorted(os.listdir(approvals_path)):
        if not AUDIT_FILE.match(name):
            continue
        try:
            with open(os.path.join(approvals_path, name), "rb") as f:
                data = f.read()
        except OSError:
            continue
        out[name] = {"len": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return out


def qa_markers(qa_root=None):
    """Byte strings that no line of the user's own audit log may carry: only a QA run writes them."""
    markers = {"`FIXTURE:`": b"FIXTURE:", "the QA bundle id": QA_BUNDLE_ID.encode()}
    if qa_root:
        markers["the QA root path"] = qa_root.encode()
    return markers


def audit_problems(name, old, approvals_dir, qa_root=None):
    """Problems with one audit file between its snapshot (`old` is None for a file that is new) and now.

    Allowed: append-only growth (the old bytes are an unchanged prefix) and a new dated file, as long
    as no new bytes mention a QA marker. Reads the file; reports names and marker kinds, never content."""
    label = f"~/.nostromo/approvals/{name}"
    try:
        with open(os.path.join(approvals_dir, name), "rb") as f:
            data = f.read()
    except OSError:
        return [f"{label} was deleted or became unreadable"]
    start = 0
    if old is not None:
        if len(data) < old["len"]:
            return [f"{label} shrank"]
        if hashlib.sha256(data[:old["len"]]).hexdigest() != old["sha256"]:
            return [f"{label} changed (the bytes already in it are not an unchanged prefix)"]
        start = old["len"]
        if start and data[start - 1:start] != b"\n":  # the snapshot cut a line in half: scan that line whole
            start = data.rfind(b"\n", 0, start) + 1
    appended = data[start:]
    return [f"{label}: an appended line mentions {kind} (the QA run wrote into the user's audit log)"
            for kind, marker in qa_markers(qa_root).items() if marker in appended]


def compare_snapshots(before, after, approvals_dir=None, qa_root=None):
    """Problems between two guard snapshots (see `take_snapshot`); empty means isolated.

    Files, the control-socket inode and `defaults` must be identical, and so must the approvals
    listing apart from the daemon's audit logs: the user's real daemon appends to its dated
    `audit-*.jsonl` during a run, which is allowed when it is append-only and carries no QA marker
    (needs `approvals_dir`, the user's real approvals directory, to inspect; without it any audit
    growth is reported). The user's own nostromd/Nostromo pids must survive; no new `claude` (or
    other monitored) process may appear."""
    problems = []
    for name, b in before["files"].items():
        if b != after["files"].get(name):
            problems.append(f"~/.nostromo/{name} changed")
    if before["approvals"] != after["approvals"]:
        problems.append("~/.nostromo/approvals/ changed (file list or sizes)")
    b_audit, a_audit = before.get("approvals_audit", {}), after.get("approvals_audit", {})
    for name in sorted(set(b_audit) | set(a_audit)):
        if name in b_audit and name not in a_audit:
            problems.append(f"~/.nostromo/approvals/{name} was deleted")
        elif b_audit.get(name) == a_audit.get(name):
            continue
        elif approvals_dir is None:
            problems.append(f"~/.nostromo/approvals/{name} changed (not inspected: no approvals dir given)")
        else:
            problems.extend(audit_problems(name, b_audit.get(name), approvals_dir, qa_root))
    if before["control_socket_inode"] != after["control_socket_inode"]:
        problems.append("~/.nostromo/app-control.sock inode changed (the user's socket was replaced)")
    if before["defaults"] != after["defaults"]:
        problems.append(f"`defaults export {USER_BUNDLE_ID}` changed")
    bp, ap = before["processes"], after["processes"]
    for name in ("nostromd", "Nostromo"):
        for pid in bp.get(name, []):
            if pid not in ap.get(name, []):
                problems.append(f"the user's {name} (pid {pid}) is gone")
    for name in MONITORED:
        for pid in ap.get(name, []):
            if pid not in bp.get(name, []):
                problems.append(f"a new '{name}' process (pid {pid}) started during the run")
    return problems


def take_snapshot(user_home, ps_text, defaults_text, qa_root=None):
    nostromo = os.path.join(user_home, ".nostromo")
    approvals = os.path.join(nostromo, APPROVALS_DIR)
    listing = dir_listing(approvals)
    if listing is not None:  # the audit logs are tracked by `approvals_audit`, not by size
        listing = {k: v for k, v in listing.items() if not AUDIT_FILE.match(k)}
    return {
        "files": {n: file_sha256(os.path.join(nostromo, n)) for n in WATCHED_FILES},
        "approvals": listing,
        "approvals_audit": audit_files(approvals),
        "control_socket_inode": socket_inode(os.path.join(nostromo, CONTROL_SOCKET)),
        "defaults": hashlib.sha256(defaults_text.encode()).hexdigest() if defaults_text else None,
        "processes": process_view(parse_processes(ps_text, qa_root)),
    }


def daemon_env(qa_root, base_env, fake_claude, guard_bin):
    """Environment for the QA nostromd. Nothing of the user's HOME leaks in."""
    home = os.path.join(qa_root, "home")
    env = {k: v for k, v in base_env.items() if k in ("PATH", "TMPDIR", "LANG", "NOSTROMO_AWS_CLI")}
    env.update({
        "HOME": home,
        "NOSTROMOD_SOCKET": os.path.join(qa_root, "nostromd.sock"),
        "NOSTROMD_SOCKET": os.path.join(qa_root, "nostromd.sock"),
        "NOSTROMO_MCP_SOCKET": os.path.join(qa_root, "mcp.sock"),
        "NOSTROMD_TCP_ADDR": "127.0.0.1:0",
        "NOSTROMO_CLAUDE_BIN": fake_claude,
        "NOSTROMO_GUARD_BIN": guard_bin,
        "NOSTROMO_APPROVALS_DIR": os.path.join(home, ".nostromo", "approvals"),
        "NOSTROMO_QA_DAEMON": "1",
        # The clone runs from QA_ROOT, not /Applications; MacPeerVerifier needs the path override.
        "NOSTROMO_OPERATOR_APP_PATH": os.path.join(qa_root, "Nostromo.app", "Contents", "MacOS", "Nostromo"),
    })
    return env


def app_env(qa_root, base_env, synthetic=True):
    """Environment for the cloned app. `synthetic=False` omits the synthetic-input switch."""
    home = os.path.join(qa_root, "home")
    env = {k: v for k, v in base_env.items() if k in ("PATH", "TMPDIR", "LANG")}
    env.update({
        "HOME": home,
        "NOSTROMOD_SOCKET": os.path.join(qa_root, "nostromd.sock"),
        "NOSTROMD_SOCKET": os.path.join(qa_root, "nostromd.sock"),
        "MOTHER_BROKER_SOCK": os.path.join(qa_root, "no-broker.sock"),
        "NOSTROMO_APP_CONTROL": "1",
        "NOSTROMO_APP_CONTROL_SOCKET": os.path.join(qa_root, "app-control.sock"),
    })
    if synthetic:
        env[SYNTHETIC_ENV] = "1"
    return env


def guard_socket_path(qa_root, path):
    """The real path of `path`, only if it lies inside the QA instance root.

    The harness talks to the QA daemon and nobody else: a path outside `qa_root` (also through `..`
    or a symlink), a root without the QA marker, or anything under the user's own `~/.nostromo`
    raises ValueError."""
    root = os.path.realpath(qa_root)
    if not os.path.exists(os.path.join(root, ROOT_MARKER)):
        raise ValueError(f"{root} is not a QA instance root (no {ROOT_MARKER})")
    real = os.path.realpath(path)
    if os.path.commonpath([root, real]) != root:
        raise ValueError(f"refusing socket {real}: not under the QA root {root}")
    users = os.path.realpath(os.path.expanduser("~/.nostromo"))
    if os.path.commonpath([users, real]) == users:
        raise ValueError(f"refusing socket {real}: it is under the user's ~/.nostromo")
    return real


def mcp_create_focus(qa_root, cwd, label=QA_FOCUS_LABEL, title=QA_FOCUS_TITLE, agent=QA_FOCUS_AGENT, timeout=30):
    """Ask the QA daemon (its MCP socket, `<qa_root>/mcp.sock`) to create a focus running the fake CLI.

    `nostromo.create_focus` spawns the session (NOSTROMO_CLAUDE_BIN, set in the daemon's env, is the fake
    claude) and broadcasts `FocusCreated`, which is how the app adds the sidebar row. A plain
    `SessionSpawn` on the main socket makes a session but registers no focus, so the app never shows it.
    The session is owned by the daemon and outlives this connection. Returns the tool's outcome dict."""
    path = guard_socket_path(qa_root, os.path.join(qa_root, MCP_SOCKET))
    args = {"agent": agent, "title": title, "label": label, "org": "Carefeed", "working_directory": cwd}
    frames = [
        {"type": "hello"},
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "qa-harness", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "nostromo.create_focus", "arguments": args}},
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
        raise RuntimeError(f"create_focus: JSON-RPC error {reply['error']}")
    try:
        outcome = json.loads(reply["result"]["content"][0]["text"])
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise RuntimeError(f"create_focus: unreadable reply {reply!r}: {e}")
    if "error" in outcome:
        raise RuntimeError(f"create_focus: {outcome['error']}: {outcome.get('detail', '')}")
    return outcome


# ── side-effecting parts ─────────────────────────────────────────────────────


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def user_snapshot(qa_root=None):
    ps = run(["/bin/ps", "-axo", "pid,command"]).stdout
    d = run(["/usr/bin/defaults", "export", USER_BUNDLE_ID, "-"])
    return take_snapshot(os.path.expanduser("~"), ps, d.stdout if d.returncode == 0 else "", qa_root)


def user_approvals_dir():
    return os.path.join(os.path.expanduser("~"), ".nostromo", APPROVALS_DIR)


def state_path(qa_root):
    return os.path.join(qa_root, "state.json")


def load_state(qa_root):
    try:
        with open(state_path(qa_root)) as f:
            return json.load(f)
    except (OSError, ValueError):
        die(f"no instance state in {qa_root}")


def save_state(qa_root, state):
    tmp = state_path(qa_root) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, state_path(qa_root))


def resolve_root(arg):
    root = arg or os.environ.get("NOSTROMO_QA_ROOT")
    if not root:
        die("no QA root: pass it as an argument or set NOSTROMO_QA_ROOT (printed by `start`)", 2)
    root = os.path.realpath(root)
    if not os.path.exists(os.path.join(root, ROOT_MARKER)):
        die(f"{root} is not a QA instance root (no {ROOT_MARKER}); refusing to touch it", 2)
    return root


def wait_for(predicate, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {what}")


def clone_app(source, dest):
    shutil.copytree(source, dest, symlinks=True)
    plist = os.path.join(dest, "Contents", "Info.plist")
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    with open(plist, "wb") as f:
        plistlib.dump(rewrite_clone_plist(info), f)
    run(["/usr/bin/xattr", "-cr", dest])
    sign = run([os.path.join(REPO, "scripts", "sign-operator-app.sh"), dest])
    if sign.returncode != 0:
        raise RuntimeError(f"sign-operator-app.sh failed: {sign.stderr.strip()}")


def build():
    # Release, not Debug: a Debug build splits the code into `Nostromo.debug.dylib` (and
    # `__preview.dylib`) beside the executable. The clone is re-signed ad-hoc with the hardened
    # runtime, which makes dyld refuse those dylibs ("different Team IDs") and the app dies at launch
    # (found live 2026-10-20). The Release app is one executable, the same shape `make mac-install` signs.
    for cmd in (
        ["cargo", "build", "--bin", "nostromd", "--bin", "nostromo-mcp-bridge", "--bin", "nostromo-guard"],
        ["make", "mac-release"],
    ):
        r = run(cmd, cwd=REPO)
        if r.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd)} failed:\n{(r.stdout + r.stderr)[-2000:]}")


def spawn(cmd, env, log_path):
    log = open(log_path, "ab")
    return subprocess.Popen(cmd, env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)


def kill_pid(pid):
    """Stop one pid we started (SIGTERM, then SIGKILL). Never by pattern."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def proc_start(pid):
    """The process start time string for pid, or None when it is not running."""
    r = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True)
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def is_recorded_process(pid, recorded_start, start_of=proc_start):
    """True only when pid is still the very process we spawned (guards against pid reuse)."""
    return bool(recorded_start) and start_of(pid) == recorded_start


def teardown(qa_root, state, start_of=proc_start, kill=kill_pid):
    for key in ("app", "daemon"):
        pid = state.get(f"{key}_pid")
        if pid and is_recorded_process(pid, state.get(f"{key}_start"), start_of):
            kill(pid)


def cmd_start(args):
    synthetic = "--no-synthetic" not in args
    before = user_snapshot()
    qa_root = os.path.realpath(tempfile.mkdtemp(prefix="nostromo-qa-"))
    open(os.path.join(qa_root, ROOT_MARKER), "w").close()
    os.makedirs(os.path.join(qa_root, "home", ".nostromo"))
    state = {"root": qa_root, "synthetic": synthetic, "before": before}
    save_state(qa_root, state)
    try:
        build()
        fake_claude = os.path.join(REPO, "scripts", "qa", "fake-claude")
        guard_bin = os.path.join(REPO, "target", "debug", "nostromo-guard")
        sock = os.path.join(qa_root, "nostromd.sock")
        d = spawn([os.path.join(REPO, "target", "debug", "nostromd")],
                  daemon_env(qa_root, os.environ, fake_claude, guard_bin),
                  os.path.join(qa_root, "nostromd.log"))
        state["daemon_pid"] = d.pid
        state["daemon_start"] = proc_start(d.pid)
        save_state(qa_root, state)
        wait_for(lambda: os.path.exists(sock) and d.poll() is None, 30, "the QA daemon socket")

        source = os.path.join(REPO, "macOS", "build", "Build", "Products", "Release", "Nostromo.app")
        clone = os.path.join(qa_root, "Nostromo.app")
        clone_app(source, clone)
        pin = run([os.path.join(REPO, "scripts", "write-operator-pin.sh"), clone, os.path.join(qa_root, "operator-app.pin")])
        if pin.returncode != 0:
            raise RuntimeError(f"write-operator-pin.sh failed: {pin.stderr.strip()}")

        a = spawn([os.path.join(clone, "Contents", "MacOS", "Nostromo")],
                  app_env(qa_root, os.environ, synthetic), os.path.join(qa_root, "app.log"))
        state["app_pid"] = a.pid
        state["app_start"] = proc_start(a.pid)
        save_state(qa_root, state)
        ctl = os.path.join(qa_root, "app-control.sock")
        wait_for(lambda: a.poll() is None and run([os.path.join(REPO, "bin", "nostromo-app"), "--socket", ctl, "ping"]).returncode == 0,
                 60, "the QA app's control socket")
    except BaseException as e:
        teardown(qa_root, state)
        problems = compare_snapshots(before, user_snapshot(qa_root), user_approvals_dir(), qa_root)
        print(f"start failed: {e}", file=sys.stderr)
        for p in problems:
            print(f"ISOLATION FAILURE: {p}", file=sys.stderr)
        shutil.rmtree(qa_root, ignore_errors=True)
        sys.exit(1)
    print(f"QA_ROOT={qa_root}")
    print(f"synthetic input: {'on' if synthetic else 'OFF (--no-synthetic)'}")
    print(f"export NOSTROMO_APP_CONTROL_SOCKET={os.path.join(qa_root, 'app-control.sock')}")


def cmd_env(args):
    qa_root = resolve_root(args[0] if args else None)
    print(f"export NOSTROMO_APP_CONTROL_SOCKET={os.path.join(qa_root, 'app-control.sock')}")


def cmd_status(args):
    qa_root = resolve_root(args[0] if args else None)
    state = load_state(qa_root)
    for key in ("daemon_pid", "app_pid"):
        pid = state.get(key)
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                alive = True
            except ProcessLookupError:
                pass
        print(f"{key}={pid} {'alive' if alive else 'dead'}")
    print(f"synthetic={state.get('synthetic')}")


def cmd_focus(args):
    """Create the QA agent session (a focus on the fake CLI) in the QA daemon; print its sidebar label."""
    qa_root = resolve_root(args[0] if args else None)
    cwd = os.path.join(qa_root, "session-cwd")
    os.makedirs(cwd, exist_ok=True)
    try:
        outcome = mcp_create_focus(qa_root, cwd)
    except (ValueError, RuntimeError, OSError) as e:
        die(f"could not create the QA session: {e}")
    print(f"QA_FOCUS_TAG={outcome.get('focus_id', '')}")
    print(f"QA_FOCUS_LABEL={QA_FOCUS_LABEL}")


def cmd_stop(args):
    qa_root = resolve_root(args[0] if args else None)
    state = load_state(qa_root)
    teardown(qa_root, state)
    problems = compare_snapshots(state["before"], user_snapshot(qa_root), user_approvals_dir(), qa_root)
    # An isolation failure keeps the root: its logs are the evidence (the caller prints them).
    keep = os.environ.get("KEEP") == "1" or bool(problems)
    if not keep:
        shutil.rmtree(qa_root, ignore_errors=True)
    if problems:
        for p in problems:
            print(f"ISOLATION FAILURE: {p}", file=sys.stderr)
        print(f"QA root kept for debugging: {qa_root} (delete it when done)", file=sys.stderr)
        sys.exit(1)
    print("isolation guard: PASS (user's files, approvals dir, control socket, defaults and processes unchanged)")


def main(argv):
    cmd = argv[0] if argv else "start"
    rest = argv[1:]
    handlers = {"start": cmd_start, "env": cmd_env, "status": cmd_status, "focus": cmd_focus, "stop": cmd_stop}
    if cmd not in handlers:
        die(f"usage: qa-instance.sh [start [--no-synthetic]] | env | status | focus | stop [ROOT]", 2)
    handlers[cmd](rest)


if __name__ == "__main__":
    main(sys.argv[1:])
