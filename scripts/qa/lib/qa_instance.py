#!/usr/bin/env python3
"""Isolated QA instance: a worktree `nostromd` plus a cloned `com.hammer.nostromo.qa` app.

    scripts/qa/qa-instance.sh [start [--no-synthetic]] | env | status | stop   (see that script)

Never touches the user's running Nostromo, `nostromd`, sockets or `~/.nostromo`. Everything the
instance owns lives under a fresh temp directory (QA_ROOT) with its own HOME. Before `start` and
after `stop` an isolation guard snapshots the user's state and fails loudly if any of it changed.
Stdlib only; run with `python3 -I`.
"""
import hashlib
import json
import os
import plistlib
import shutil
import signal
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


def compare_snapshots(before, after):
    """Problems between two guard snapshots (see `take_snapshot`); empty means isolated.

    Files, the approvals listing, the control-socket inode and `defaults` must be identical.
    The user's own nostromd/Nostromo pids must survive; no new `claude` (or other monitored)
    process may appear."""
    problems = []
    for name, b in before["files"].items():
        if b != after["files"].get(name):
            problems.append(f"~/.nostromo/{name} changed")
    if before["approvals"] != after["approvals"]:
        problems.append("~/.nostromo/approvals/ changed (file list or sizes)")
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
    return {
        "files": {n: file_sha256(os.path.join(nostromo, n)) for n in WATCHED_FILES},
        "approvals": dir_listing(os.path.join(nostromo, APPROVALS_DIR)),
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
        problems = compare_snapshots(before, user_snapshot(qa_root))
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


def cmd_stop(args):
    qa_root = resolve_root(args[0] if args else None)
    state = load_state(qa_root)
    teardown(qa_root, state)
    problems = compare_snapshots(state["before"], user_snapshot(qa_root))
    if os.environ.get("KEEP") != "1":
        shutil.rmtree(qa_root, ignore_errors=True)
    if problems:
        for p in problems:
            print(f"ISOLATION FAILURE: {p}", file=sys.stderr)
        sys.exit(1)
    print("isolation guard: PASS (user's files, approvals dir, control socket, defaults and processes unchanged)")


def main(argv):
    cmd = argv[0] if argv else "start"
    rest = argv[1:]
    handlers = {"start": cmd_start, "env": cmd_env, "status": cmd_status, "stop": cmd_stop}
    if cmd not in handlers:
        die(f"usage: qa-instance.sh [start [--no-synthetic]] | env | status | stop [ROOT]", 2)
    handlers[cmd](rest)


if __name__ == "__main__":
    main(sys.argv[1:])
