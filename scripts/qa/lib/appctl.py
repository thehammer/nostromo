"""Read-only wrapper around bin/nostromo-app for the QA smoke scripts.

Everything the scripts do to the live app goes through `App`. It is read-only by
construction, as an ALLOW-list:

* only a short list of commands is reachable (no `type`, `paste`, `drop`, `drag`, no raw
  `click --text`), and `click` / `key` only through the guarded methods below;
* a click names its KIND (`CLICK_KINDS`: sidebar row, one of the allowed tabs, a list row, a Fred
  row, the Send sheet's "What will be shared" toggle, its instruction text view). Before it is sent
  the app is asked what is under the point (`hittest`, read-only) and the click goes out only when
  the hit chain (the hit view and every superview) is what that kind declares. Anything else,
  including a button the script never named, is refused: nothing is clicked by default;
* key events are limited to the chords the scenarios need, each tied to the Send sheet or not,
  and Return is sent only right after a fresh hit test proves the instruction text view has the
  keyboard (anywhere else in that sheet plain Return would confirm the send).

Standard library only.
"""
import json
import subprocess

ALLOWED_COMMANDS = {"ping", "windows", "tree", "find", "click", "key", "hittest",
                    "screenshot", "activate", "restore", "transcript-anchor"}
_GUARDED_COMMANDS = {"click", "key"}   # reachable only through App.click_node / click_at / key

# Tabs a script may click. Picks is never clickable (the first open of the day can start a paid
# generation) and Sentry only when the caller opts in (leaving it resets "new since last viewed").
DEFAULT_TABS = ("Todos", "Jira", "Repo docs")
NEVER_CLICKABLE_TABS = ("Picks",)
FRAME_SLOP = 2.0   # points: a hit view whose frame is this close to the node's frame IS that node

# What each kind of click may land on. `chain` is hit view first, then its superviews.
#   sheet:      True = only inside the Send sheet, False = only outside it
#   in_chain:   a class that must appear in the chain (the row/cell that makes this a safe target)
#   leaf:       allowed classes of the hit view itself (None: no constraint beyond the others)
#   no_button:  no class containing "Button" anywhere in the chain
#   same_view:  hit view must be the node (same class, frame within FRAME_SLOP); needs the node
#   node_class: allowed classes of the node itself (needs the node)
#   label:      the node's accessibility label that names the control (needs the node)
#   leaf_suffix / editable: the hit view's class must end with the suffix / the hit view must be editable
#               (for a text view that is the node itself, whatever its concrete subclass)
CLICK_KINDS = {
    "sidebar-row": {"sheet": False, "in_chain": ("NavTabItem",), "leaf": ("NSTextField", "NavTabItem"),
                    "no_button": True},
    "tab": {"sheet": False, "same_view": True, "node_class": ("NSButton",)},
    "list-row": {"sheet": False, "in_chain": ("WorkRowCellView",), "no_button": True},
    "fred-row": {"sheet": False, "in_chain": ("FredInboxCell", "FredTodayCell"), "no_button": True},
    "sheet-toggle": {"sheet": True, "same_view": True, "node_class": ("NSButton",),
                     "label": "What will be shared"},
    "sheet-text": {"sheet": True, "same_view": True, "label": "Instruction for the agent",
                   "leaf_suffix": "TextView", "editable": True},
}

# (chars, sorted modifiers) -> True when it must go to the Send sheet, False when it must not.
# Return/Escape/undo only ever target the sheet's instruction text view or the sheet itself.
ALLOWED_KEYS = {
    ("s", ("cmd", "shift")): False,   # open Send to agent for the selected item
    ("\r", ()): True,                 # plain Return in the instruction view (inserts a newline)
    ("z", ("cmd",)): True,            # undo that newline
    ("\x7f", ()): True,               # fallback undo: delete it
    ("\x1b", ()): True,               # Escape: cancel the sheet
}


class AppError(Exception):
    """The app-control call failed (socket gone, error reply, bad JSON)."""


class RefusedError(AppError):
    """The script itself tried something outside the read-only allow-list."""


def _name_matches(text, names):
    t = (text or "").strip()
    return any(t == n or t.startswith(n + " ") for n in names)


def _same_frame(a, b):
    return all(abs(a.get(k, 1e9) - b.get(k, -1e9)) <= FRAME_SLOP for k in ("x", "y", "w", "h"))


class App:
    def __init__(self, binary, window_args=(), allowed_tabs=DEFAULT_TABS):
        self.binary = binary
        self.window_args = list(window_args)
        self.allowed_tabs = tuple(t for t in allowed_tabs if t not in NEVER_CLICKABLE_TABS)

    # -- plumbing ---------------------------------------------------------------
    def _run(self, cmd, args=(), sheet=False, timeout=45, _guarded=False):
        if cmd not in ALLOWED_COMMANDS:
            raise RefusedError(f"refusing command {cmd!r}: not allowed in a read-only QA script")
        if cmd in _GUARDED_COMMANDS and not _guarded:
            raise RefusedError(f"refusing {cmd!r}: it is only reachable through the guarded click/key methods")
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
    def click_node(self, node, kind, sheet=False):
        """Click the centre of a tree/find node, after a hit test says it is what `kind` allows."""
        f = node["frame"]
        return self.click_at(f["x"] + f["w"] / 2.0, f["y"] + f["h"] / 2.0, kind, node=node, sheet=sheet)

    def click_at(self, x, y, kind, node=None, sheet=False):
        """Hit-test the point, then click it only if the hit chain satisfies the rule for `kind`."""
        rule = CLICK_KINDS.get(kind)
        if rule is None:
            raise RefusedError(f"refusing click: {kind!r} is not a declared kind of click")
        if rule["sheet"] != bool(sheet):
            raise RefusedError(f"refusing {kind} click: it is only for " + ("the Send sheet" if rule["sheet"] else "the window, not a sheet"))
        point = [f"{x:.1f}", f"{y:.1f}"]
        problem = self._click_problem(rule, kind, self._hit_chain(point, sheet), node)
        if problem:
            raise RefusedError(f"refusing {kind} click at {point[0]},{point[1]}: {problem}")
        return self._run("click", point, sheet=sheet, _guarded=True)

    def _hit_chain(self, point, sheet):
        """The views under a point (formatted coordinates), hit view first; empty when there is none."""
        return (self._run("hittest", point, sheet=sheet) or {}).get("chain") or []

    def _click_problem(self, rule, kind, chain, node):
        """Why a click on this hit chain is not allowed, or None. The checks run in a fixed order:
        the hit chain, then the node the click was aimed at, then the hit view against that node."""
        if not chain:
            return "the hit test found no view there"
        top = chain[0].get("class", "")
        classes = [c.get("class", "") for c in chain]
        if rule.get("no_button") and any("Button" in c for c in classes):
            return f"a button is in the way ({next(c for c in classes if 'Button' in c)})"
        if rule.get("in_chain") and not any(c in rule["in_chain"] for c in classes):
            return f"the point is on {top}, not on a {'/'.join(rule['in_chain'])}"
        if rule.get("leaf") and top not in rule["leaf"]:
            return f"the point is on {top}"
        if rule.get("same_view") or rule.get("label") or rule.get("node_class"):
            problem = self._node_problem(rule, kind, node)
            if problem:
                return problem
        if rule.get("same_view"):
            if top != node.get("class") and not (rule.get("leaf_suffix") and top.endswith(rule["leaf_suffix"])):
                return f"the point is on {top}, not on the {node.get('class')} it was aimed at"
            if not _same_frame(chain[0].get("frame", {}), node.get("frame", {})):
                return f"the view there is not the {node.get('class')} that was aimed at (the layout moved?)"
        if rule.get("leaf_suffix") and not top.endswith(rule["leaf_suffix"]):
            return f"the point is on {top}"
        if rule.get("editable") and chain[0].get("isEditable") is not True:
            return "the view is not editable"
        return None

    def _node_problem(self, rule, kind, node):
        """Why the node a click was aimed at is not an acceptable target for this kind, or None."""
        if node is None:
            return "this kind needs the node it is aimed at"
        if rule.get("node_class") and node.get("class") not in rule["node_class"]:
            return f"the node is a {node.get('class')}"
        if kind == "tab":
            if not _name_matches(node.get("text"), self.allowed_tabs):
                return f"{(node.get('text') or '')[:30]!r} is not one of the allowed tabs {', '.join(self.allowed_tabs)}"
        elif rule.get("label") and node.get("label") != rule["label"]:
            return f"the node is not the {rule['label']!r} control"
        return None

    def key(self, chars, mods=(), key_code=None, sheet=False, return_target=None):
        chord = (chars, tuple(sorted(mods)))
        if chord not in ALLOWED_KEYS:
            raise RefusedError(f"refusing key {chars!r} {sorted(mods)}: not in the read-only allow-list")
        if ALLOWED_KEYS[chord] != bool(sheet):
            raise RefusedError(f"refusing key {chars!r} {sorted(mods)}: " + ("it is only for the Send sheet" if ALLOWED_KEYS[chord] else "it must not go to a sheet"))
        if chars == "\r":
            self._prove_return_target(return_target)
        args = [chars]
        if mods:
            args += ["--mod", ",".join(mods)]
        if key_code is not None:
            args += ["--key-code", str(key_code)]
        return self._run("key", args, sheet=sheet, _guarded=True)

    def _prove_return_target(self, target):
        """Plain Return confirms the send unless a text view is eating it: prove, right now, that it is."""
        if target is None:
            raise RefusedError("refusing Return: no instruction text view to prove it against")
        x, y = target
        chain = self._hit_chain([f"{x:.1f}", f"{y:.1f}"], sheet=True)
        top = chain[0] if chain else {}
        if not (top.get("class", "").endswith("TextView") and top.get("isFirstResponder") is True
                and top.get("isEditable") is True and top.get("isFieldEditor") is not True):
            raise RefusedError("refusing Return: cannot prove the instruction text view has the keyboard "
                               "(outside a text view Return would confirm the send)")
