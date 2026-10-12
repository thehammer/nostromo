"""Read-only wrapper around bin/nostromo-app for the QA smoke scripts.

Everything the scripts do to the live app goes through `App`. It is read-only by
construction:

* only a short allow-list of commands is reachable (no `type`, `paste`, `drop`,
  `drag`, no raw `click --text`);
* clicks go through `click_node`, which refuses any button whose text, label or
  tooltip names an action with a side effect (Start, Send to agent, Open in
  Outlook, Ask Fred, Refresh picks, Retry ...);
* key events are limited to the five chords the scenarios need.

Standard library only.
"""
import json
import os
import subprocess

ALLOWED_COMMANDS = {"ping", "windows", "tree", "find", "click", "key", "hittest",
                    "screenshot", "activate", "restore"}

# Buttons that DO something beyond moving around the UI. Matched on the lower-cased
# text/label/tooltip with a trailing ellipsis removed: equal to, or followed by a space.
FORBIDDEN_BUTTONS = (
    "start", "send to agent", "send to fred", "open in outlook", "open in", "ask fred",
    "prep with fred", "refresh picks", "retry", "go to existing focus", "go to existing job",
    "create another", "cancel job", "escalate", "copy code", "choose", "reveal",
)

# (chars, sorted modifiers) the scripts may send. Return/Escape/undo only ever target the
# Send-to-agent sheet's instruction text view or the sheet itself (guarded in smoke.py).
ALLOWED_KEYS = {
    ("s", ("cmd", "shift")),   # open Send to agent for the selected item
    ("\r", ()),                # plain Return in the instruction view (inserts a newline)
    ("z", ("cmd",)),           # undo that newline
    ("\x7f", ()),              # fallback undo: delete it
    ("\x1b", ()),              # Escape: cancel the sheet
}


class AppError(Exception):
    """The app-control call failed (socket gone, error reply, bad JSON)."""


class RefusedError(AppError):
    """The script itself tried something outside the read-only allow-list."""


def _norm(s):
    return (s or "").strip().rstrip("…").rstrip(".").strip().lower()


def is_forbidden_button(node):
    cls = node.get("class", "")
    if "Button" not in cls:
        return False
    for raw in (node.get("text"), node.get("label"), node.get("tooltip")):
        t = _norm(raw)
        if not t:
            continue
        for bad in FORBIDDEN_BUTTONS:
            if t == bad or t.startswith(bad + " "):
                return True
    return False


class App:
    def __init__(self, binary, window_args=()):
        self.binary = binary
        self.window_args = list(window_args)

    # -- plumbing ---------------------------------------------------------------
    def _run(self, cmd, args=(), sheet=False, timeout=45):
        if cmd not in ALLOWED_COMMANDS:
            raise RefusedError(f"command {cmd!r} is not allowed in a read-only QA script")
        argv = [self.binary]
        if cmd not in ("ping", "windows", "restore"):
            argv += self.window_args
        if sheet:
            argv.append("--sheet")
        argv += [cmd, *args]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as e:
            raise AppError(f"{cmd}: no answer within {timeout}s (app parked in a mouse-tracking loop?)") from e
        except OSError as e:
            raise AppError(f"cannot run {self.binary}: {e}") from e
        if p.returncode != 0:
            msg = (p.stderr or p.stdout or "").strip().splitlines()
            raise AppError(f"{cmd}: {msg[0] if msg else 'exit ' + str(p.returncode)}")
        out = p.stdout.strip()
        if not out:
            return None
        try:
            return json.loads(out)
        except ValueError as e:
            raise AppError(f"{cmd}: reply is not JSON") from e

    # -- reads ------------------------------------------------------------------
    def ping(self):
        return self._run("ping")

    def windows(self):
        return self._run("windows")

    def tree(self, sheet=False, depth=40):
        return self._run("tree", ["--depth", str(depth)], sheet=sheet)

    def find(self, text, sheet=False):
        return self._run("find", [text], sheet=sheet)

    def hittest(self, x, y, sheet=False):
        return self._run("hittest", [str(x), str(y)], sheet=sheet)

    def screenshot(self, path):
        return self._run("screenshot", [path])

    # -- focus (the scripts take keyboard focus briefly and hand it back) -------------
    def activate(self):
        return self._run("activate")

    def restore(self):
        return self._run("restore")

    # -- UI-only input ---------------------------------------------------------------
    def click_node(self, node, sheet=False):
        """Click the centre of a tree/find node. Refuses side-effecting buttons."""
        if is_forbidden_button(node):
            what = node.get("text") or node.get("label") or node.get("tooltip")
            raise RefusedError(f"refusing to click a side-effecting control: {str(what)[:40]!r}")
        f = node["frame"]
        return self.click_xy(f["x"] + f["w"] / 2.0, f["y"] + f["h"] / 2.0, sheet=sheet)

    def click_xy(self, x, y, sheet=False):
        return self._run("click", [f"{x:.1f}", f"{y:.1f}"], sheet=sheet)

    def key(self, chars, mods=(), key_code=None, sheet=False):
        if (chars, tuple(sorted(mods))) not in ALLOWED_KEYS:
            raise RefusedError(f"key {chars!r} {sorted(mods)} is not in the read-only allow-list")
        args = [chars]
        if mods:
            args += ["--mod", ",".join(mods)]
        if key_code is not None:
            args += ["--key-code", str(key_code)]
        return self._run("key", args, sheet=sheet)
