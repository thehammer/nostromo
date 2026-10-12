#!/usr/bin/env python3
"""Stand-in for bin/nostromo-app, used by the QA script tests (QA_APP points here).

Every invocation is its own process, so all state lives in files under $FAKE_APP_DIR:

  scenario.json   what the fake "app" looks like (see DEFAULTS; the tests override pieces)
  state.json      mutable UI state: focus / tab / selected row / sheet / key window, per window
  calls.log       one JSON array (argv, without the program name) per invocation
  forbidden.log   one JSON object per thing that must NEVER happen to a read-only QA run:
                  type/paste/drop/drag, a click on Start / Open in... / Send to agent... /
                  Open in Outlook / Ask Fred... / Prep with Fred / Refresh picks / Retry,
                  Return while the instruction view is not the first responder, any other key
  notes.log       benign oddities (a click ignored because the window was not key, ...)
  actions.log     one JSON object per UI action a click actually triggered ({"action": "tab:Jira",
                  "window": 0, "tab": <tab at that moment>, "focus": <focus at that moment>}); the
                  semantic record of "what was done to the app", independent of coordinates
  hanging         written (with the pid) when the `hang` scenario option makes a call block

The JSON shapes mirror macOS/Nostromo/AppControl/AppControlServer.swift (ping, windows, tree,
find, click, hittest, key, screenshot, activate, restore) and the CLI conventions of
bin/nostromo-app: global flags (-w N, --screen NAME, --sheet) come BEFORE the subcommand, the
result is printed with json.dumps(indent=2), errors go to stderr with exit 1.

Click resolution is geometric: the tree is laid out in window-content points (top-left origin)
and a click at X,Y lands on the deepest node whose frame contains it, so the scripts' real
coordinate clicks are exercised. Standard library only.
"""
import json
import os
import sys
import time

DIR = os.environ.get("FAKE_APP_DIR")
if not DIR:
    sys.exit("fake_nostromo_app: FAKE_APP_DIR is not set")

SIDEBAR_TOP = 100
ROW_H = 56

DEFAULTS = {
    "ping_fail": False,            # every command: "cannot reach ..." (exit 1)
    "ping_fail_after": None,       # N: the first N pings work, later pings (and only pings) fail
    "die_after_calls": None,       # N: from the (N+1)th invocation on, everything fails
    "pid": 4242,
    "content": {"w": 1400, "h": 900, "scale": 2, "title_bar": 0},
    "windows": [{"screen": "Built-in Retina Display", "focus": "Perri", "key": False}],
    "sidebar": ["Mother", "Perri", "Teri", "Fred"],
    "badges": {"Fred": "3", "Mother": "1"},
    "initial_tab": "Jira",
    "tabs": {"Picks": "Picks 3", "Todos": "Todos 2", "Jira": "Jira 2", "Sentry": "Sentry 2",
             "Repo docs": "Repo docs 2"},
    # {"Sentry": {"after_reads": 3, "final": "Sentry 4"}}: after the tab has been clicked, its
    # title is the one in "tabs" for the first after_reads-1 tree calls, then "final".
    # With "any_read": true the tab does not need to be clicked (reads are counted from the start).
    "tab_flip": {},
    "banners": [],                 # texts of SourceStateBanner views on the Teri surface
    "banner_retry": False,         # give the banner a "Retry" button
    "rows": {},                    # tab -> [titles]; default two generated titles per tab
    "toolbars": {"Todos": ["All", "Open", "Done"], "Jira": ["All", "Mine", "Blocked"],
                 "Sentry": ["All", "Unresolved"], "Repo docs": ["All", "Stale"]},
    "sheet": {
        "title": "Send to agent",
        "opens": True,             # does Cmd-Shift-S open it
        "escape_closes": True,
        "return_closes": False,    # plain Return confirms/closes (the bug the smoke must catch)
        "click_gives_focus": True,  # a click on the instruction view makes it first responder
        "undo_works": True,        # Cmd-Z undoes the inserted newline
        "seed_text": "",
        "preview_editable": False,
        "preopen": False,          # a sheet is already open when the run starts (the user's own)
    },
    "fred": {
        "inbox": ["Quarterly numbers", "Lunch?", "Re: contract"],
        "inbox_header_count": None,   # header count if it should differ from the row count
        "today": ["Standup", "1:1 with Sam"],
        "signin": False,
    },
    "colours": {"bg": "#1e1e1e", "pill": "#333333", "label": "#e6e6e6", "label_inactive": None,
                "label_by_class": {}},      # {"NSPopUpButton": "#2d2d2d"}: that class's labels use this colour
    "restore_keeps_key": False,    # `restore` leaves the window key (the app was already frontmost)
    # --- read-only-run scenarios ------------------------------------------------------------
    "preselected": {},             # {"Jira": 0}: that tab already has its first row selected (every window)
    "fred_preopen": None,          # ["inbox", 0]: FredDetailView is already open on that row
    "tab_pill": True,              # False: the selected tab is NOT painted as a filled pill (undetectable)
    "overlays": [],                # [{"class": "X", "frame": {x,y,w,h}}]: a top-most view that swallows clicks
    "row_marker_button": False,    # every WorkRowCellView has an NSButton (leaf: NSImageView) over its centre line
    # {"dx": 0, "dy": 30, "after_sheet_clicks": 0}: the LIVE sheet layout (hittest/click) is displaced by
    # (dx, dy) from what `tree --sheet` reports, once that many sheet clicks have been delivered.
    "sheet_drift": None,
    # {"cmd": "screenshot", "nth": 2, "sheet": false, "seconds": 120}: the nth call of that command (only
    # --sheet calls when "sheet" is true) writes app_dir/hanging (the pid) and blocks, killable.
    "hang": None,
    "chevron": False,              # screenshot: bright chevron at the right end of NSPopUpButton, bright icons on NSSearchField
    "bezel": False,                # screenshot: 2px bright bezel around every painted control
    "popup_label_child": False,    # the toolbar NSPopUpButton has an NSTextField child framing its label
}


def deep_merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict) and k not in ("badges", "tab_flip"):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def path(name):
    return os.path.join(DIR, name)


def read_json(name, default=None):
    try:
        with open(path(name)) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(name, obj):
    with open(path(name), "w") as f:
        json.dump(obj, f)


def append(name, line):
    with open(path(name), "a") as f:
        f.write(line + "\n")


def forbid(reason, argv):
    append("forbidden.log", json.dumps({"reason": reason, "argv": argv}))


def note(text):
    append("notes.log", text)


def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def trunc(s):
    """AppControlServer.text(of:): at most 160 characters, then an ellipsis."""
    return s if len(s) <= 160 else s[:160] + "…"


# ------------------------------------------------------------------------------ scenario/state

def fresh_state(S):
    wins = []
    for w in S["windows"]:
        tab = w.get("tab", S["initial_tab"])
        sel = dict(S["preselected"])
        wins.append({"focus": w.get("focus", "Teri"), "tab": tab, "row": sel.get(tab), "sel": sel,
                     "sheet": bool(S["sheet"].get("preopen")), "instr": "", "instr_fr": False, "undo": [], "shared": False,
                     "key": bool(w.get("key", False)), "fred_row": S["fred_preopen"]})
    return {"calls": 0, "pings": 0, "reads": {}, "clicked": {}, "windows": wins,
            "app_active": any(w["key"] for w in wins)}


# ------------------------------------------------------------------------------ tree building

def N(cls, x, y, w, h, text=None, label=None, tooltip=None, children=None, **private):
    n = {"class": cls, "frame": {"x": x, "y": y, "w": w, "h": h}}
    if text:
        n["text"] = trunc(text)
    if tooltip:
        n["tooltip"] = tooltip
    if label:
        n["label"] = label
    if children:
        n["children"] = children
    for k, v in private.items():
        n["_" + k] = v
    return n


def strip(n):
    out = {k: v for k, v in n.items() if not k.startswith("_")}
    if "children" in out:
        out["children"] = [strip(c) for c in out["children"]]
    return out


def tab_title(S, st, name):
    flip = S["tab_flip"].get(name)
    if flip and (flip.get("any_read") or st["clicked"].get(name)) and st["reads"].get(name, 0) >= flip["after_reads"]:
        return flip["final"]
    return S["tabs"][name]


def tab_rows(S, tab):
    if tab in S["rows"]:
        return S["rows"][tab]
    return [f"{tab} item one", f"{tab} item two"]


def sidebar_node(S, w):
    kids = []
    for i, name in enumerate(S["sidebar"]):
        y = SIDEBAR_TOP + 40 * i
        active = (name == w["focus"])
        c = []
        if active:
            c.append(N("NSView", 0, y, 3, 36))
        c.append(N("NSTextField", 16, y + 8, 120, 20, text=name, action="focus:" + name))
        badge = S["badges"].get(name)
        if badge:
            c.append(N("NSView", 150, y + 8, 40, 20,
                       children=[N("NSTextField", 154, y + 10, 32, 16, text=badge)]))
        kids.append(N("NavTabItem", 0, y, 200, 36, label=(f"{name}, {badge} unread" if badge else None),
                      children=c, action="focus:" + name))
    return N("NSView", 0, 0, 200, 900, children=kids)


def teri_node(S, st, w):
    tabs = []
    for i, name in enumerate(["Picks", "Todos", "Jira", "Sentry", "Repo docs"]):
        tabs.append(N("NSButton", 216 + 132 * i, 18, 124, 32, text=tab_title(S, st, name),
                      action="tab:" + name, paint=True, selected=(w["tab"] == name)))
    strip_node = N("NSStackView", 216, 16, 660, 36, children=tabs)
    column = [strip_node]
    for i, text in enumerate(S["banners"][:2]):
        kids = [N("NSTextField", 220, 54 + 22 * i, 700, 18, text=text)]
        if S["banner_retry"]:
            kids.append(N("NSButton", 930, 54 + 22 * i, 80, 18, text="Retry", forbidden="Retry"))
        column.append(N("SourceStateBanner", 216, 54 + 22 * i, 1170, 20, children=kids))

    if w["tab"] == "Picks":
        picks = [N("NSTextField", 216, 108, 300, 20, text="Generated 2h ago"),
                 N("NSButton", 520, 104, 170, 26, text="Refresh picks", forbidden="Refresh picks", paint=True)]
        for i in range(3):
            picks.append(N("PickRowView", 200, 140 + 60 * i, 500, 56,
                           children=[N("NSTextField", 216, 148 + 60 * i, 400, 20, text=f"Pick {i + 1}")]))
        left = N("TeriPicksView", 200, 100, 500, 800, children=picks)
    else:
        chips = S["toolbars"].get(w["tab"], ["All"])
        bar = []
        x = 208
        for chip in chips:
            bar.append(N("NSButton", x, 104, 56, 26, text=chip, label=f"Filter: {chip}", paint=True))
            x += 62
        popup_kids = None
        if S["popup_label_child"]:
            popup_kids = [N("NSTextField", x + 110 * 0.25, 104 + 26 * 0.3, 110 * 0.5, 26 * 0.4, text="Sort: Recent")]
        bar.append(N("NSPopUpButton", x, 104, 110, 26, text="Sort: Recent", paint=True, children=popup_kids))
        bar.append(N("NSSearchField", x + 116, 104, 90, 26, label="Search", paint=True))
        titles = tab_rows(S, w["tab"])
        rows = []
        for i, t in enumerate(titles):
            y = 140 + ROW_H * i
            row_kids = [N("NSTextField", 216, y + 8, 400, 20, text=t),
                        N("NSTextField", 216, y + 32, 300, 16, text=f"{w['tab'].upper()}-{i + 1} · Open")]
            if S["row_marker_button"]:   # a 'sent to ...' marker button: a non-Button leaf nested under an NSButton
                bf = (210, y + ROW_H // 2 - 4, 480, 8)
                row_kids.append(N("NSButton", *bf, label="Sent to Mother", forbidden="row marker button",
                                  children=[N("NSImageView", *bf)]))
            rows.append(N("WorkRowCellView", 200, y, 500, ROW_H, action=f"row:{i}", children=row_kids))
        scroll = N("NSScrollView", 200, 140, 500, 720, children=[N("WorkOutlineView", 200, 140, 500, 720, children=rows)])
        kids = bar + [scroll]
        if not titles:
            kids.append(N("NSTextField", 216, 864, 400, 20, text="Nothing here yet"))
        left = N("WorkListView", 200, 100, 500, 800, children=kids)

    # detail pane
    row = w["row"]
    if row is not None and w["tab"] != "Picks" and row < len(tab_rows(S, w["tab"])):
        title = tab_rows(S, w["tab"])[row]
        body = f"{title}\n\nStatus: Open\n"
        if w["tab"] != "Todos":
            body += "\nLinks\n- https://example.invalid/item\n"
        tip = "This todo has no link to open" if w["tab"] == "Todos" else None
    else:
        body, tip = "Select an item to see its details", "Select an item first"
    detail = N("WorkDetailView", 700, 100, 700, 800, children=[
        N("NSPopUpButton", 716, 108, 130, 26, text="Open in…", tooltip=tip, forbidden="Open in…"),
        N("NSButton", 852, 108, 150, 26, text="Send to agent…", forbidden="Send to agent…"),
        N("NSTextView", 716, 146, 670, 740, text=body, label="Item details")])
    split = N("TeriSplitView", 200, 100, 1200, 800,
              children=[N("NSView", 200, 100, 500, 800, children=[left]), detail])
    column.append(split)
    return N("TeriSurfaceView", 200, 0, 1200, 900, children=[N("NSStackView", 200, 0, 1200, 900, children=column)])


def fred_node(S, w):
    F = S["fred"]
    kids = []
    for pane, x, titles, cls, header, empty in (
            ("inbox", 200, F["inbox"], "FredInboxCell", "Inbox", "No messages in your Inbox"),
            ("today", 600, F["today"], "FredTodayCell", "Today", "No meetings today")):
        c = []
        if F["signin"]:
            c.append(N("NSTextField", x + 16, 16, 360, 20, text=header))
            c.append(N("NSTextField", x + 16, 60, 360, 20, text="Sign in to Microsoft 365"))
        else:
            count = len(titles)
            if pane == "inbox" and F["inbox_header_count"] is not None:
                count = F["inbox_header_count"]
            word = "unread" if pane == "inbox" else "meetings"
            c.append(N("NSTextField", x + 16, 16, 360, 20, text=f"{header} · {count} {word}"))
            for i, t in enumerate(titles):
                y = 48 + 60 * i
                c.append(N(cls, x, y, 400, 56, action=f"fredrow:{pane}:{i}", children=[
                    N("NSTextField", x + 16, y + 6, 300, 18, text="Sender"),
                    N("NSTextField", x + 16, y + 26, 360, 18, text=t)]))
            if not titles:
                c.append(N("NSTextField", x + 16, 60, 360, 20, text=empty))
        kids.append(N("FredPane", x, 0, 400, 900, children=c))
    if w["fred_row"]:
        pane, i = w["fred_row"]
        pool = F["inbox"] if pane == "inbox" else F["today"]
        second = "Ask Fred…" if pane == "inbox" else "Prep with Fred"
        kids.append(N("FredDetailView", 1000, 0, 400, 900, children=[
            N("NSTextField", 1016, 16, 360, 20, text=pool[i] if i < len(pool) else ""),
            N("NSButton", 1016, 52, 160, 26, text="Open in Outlook", forbidden="Open in Outlook"),
            N("NSButton", 1016, 88, 160, 26, text=second, forbidden=second)]))
    return N("FredSurfaceView", 200, 0, 1200, 900, children=kids)


def window_tree(S, st, wi):
    w = st["windows"][wi]
    C = S["content"]
    if w["focus"] == "Teri":
        surface = teri_node(S, st, w)
    elif w["focus"] == "Fred":
        surface = fred_node(S, w)
    else:
        surface = N(f"{w['focus']}SurfaceView", 200, 0, 1200, 900)
    overlays = [N(o["class"], o["frame"]["x"], o["frame"]["y"], o["frame"]["w"], o["frame"]["h"])
                for o in S["overlays"]]
    return N("MainLayout", 0, 0, C["w"], C["h"], children=[sidebar_node(S, w), surface] + overlays)


def sheet_tree(S, w):
    SH = S["sheet"]
    shared = w["shared"]
    shift = 120 if shared else 0
    kids = [
        N("NSTextField", 20, 16, 300, 20, text=SH["title"]),
        N("NSSegmentedControl", 20, 48, 360, 28, label="Destination"),
        N("NSScrollView", 20, 90, 560, 120, children=[
            N("NSTextView", 20, 90, 560, 120, text=w["instr"], label="Instruction for the agent", action="instr")]),
        N("NSButton", 20, 220, 18, 18, label="What will be shared", action="toggle"),
        N("NSTextField", 40, 222, 300, 16, text="What will be shared (read-only)"),
    ]
    if shared:
        kids.append(N("NSScrollView", 20, 244, 560, 100, children=[
            N("NSTextView", 20, 244, 560, 100, text="Jira item context: title, status, links",
              label="What will be shared with the agent, read only", editable=SH["preview_editable"])]))
    kids.append(N("NSButton", 400, 360 + shift, 80, 28, text="Start", tooltip="Start (⌘Return)", forbidden="Start"))
    kids.append(N("NSButton", 490, 360 + shift, 80, 28, text="Cancel", action="cancel"))
    return N("NSView", 0, 0, 600, 420 + shift, children=kids)


# ------------------------------------------------------------------------------ geometry

def chain_at(node, x, y):
    """[root, ..., deepest] of the nodes containing the point; later siblings are on top."""
    f = node["frame"]
    if not (f["x"] <= x < f["x"] + f["w"] and f["y"] <= y < f["y"] + f["h"]):
        return []
    for child in reversed(node.get("children", [])):
        sub = chain_at(child, x, y)
        if sub:
            return [node] + sub
    return [node]


def shifted(node, dx, dy):
    out = dict(node)
    f = node["frame"]
    out["frame"] = {"x": f["x"] + dx, "y": f["y"] + dy, "w": f["w"], "h": f["h"]}
    if "children" in node:
        out["children"] = [shifted(c, dx, dy) for c in node["children"]]
    return out


def live_sheet_root(S, st, w):
    """The geometry hittest/click see. With `sheet_drift` it is displaced from what `tree --sheet` reports."""
    root = sheet_tree(S, w)
    d = S["sheet_drift"]
    if d and st.get("sheet_clicks", 0) >= d.get("after_sheet_clicks", 0):
        root = shifted(root, d.get("dx", 0), d.get("dy", 0))
    return root


def walk(node):
    yield node
    for c in node.get("children", []):
        yield from walk(c)


# ------------------------------------------------------------------------------ screenshot

def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def write_png(out_path, width, height, mods, bg):
    import struct
    import zlib
    row_bg = bytes(bg) * width
    raw = bytearray()
    for y in range(height):
        raw += b"\x00"
        raw += mods.get(y, row_bg)

    def chunk(kind, body):
        c = struct.pack(">I", len(body)) + kind + body
        return c + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 1)) + chunk(b"IEND", b""))
    with open(out_path, "wb") as f:
        f.write(png)


def screenshot(S, st, wi, out_path):
    C = S["content"]
    scale, bar = C["scale"], C["title_bar"]
    W, H = C["w"] * scale, (C["h"] + bar) * scale
    col = S["colours"]
    w = st["windows"][wi]
    label = hex_rgb((col["label"] if w["key"] or not col["label_inactive"] else col["label_inactive"]))
    bg, pill = hex_rgb(col["bg"]), hex_rgb(col["pill"])
    row_bg = bytes(bg) * W
    mods = {}

    def paint(x0, y0, x1, y1, rgb):
        x0, x1 = max(0, int(x0)), min(W, int(x1))
        for y in range(max(0, int(y0)), min(H, int(y1))):
            r = mods.get(y)
            if r is None:
                r = mods[y] = bytearray(row_bg)
            r[x0 * 3:x1 * 3] = bytes(rgb) * (x1 - x0)

    bright = (255, 255, 255)
    by_class = {k: hex_rgb(v) for k, v in col.get("label_by_class", {}).items()}
    for n in walk(window_tree(S, st, wi)):
        if not n.get("_paint"):
            continue
        f = n["frame"]
        cls = n["class"]
        x0, y0 = f["x"] * scale, (bar + f["y"]) * scale
        x1, y1 = (f["x"] + f["w"]) * scale, (bar + f["y"] + f["h"]) * scale
        if n.get("_selected") and S["tab_pill"]:
            paint(x0, y0, x1, y1, pill)
        bw, bh = x1 - x0, y1 - y0
        if S["bezel"]:
            paint(x0, y0, x1, y0 + 2, bright)
            paint(x0, y1 - 2, x1, y1, bright)
            paint(x0, y0, x0 + 2, y1, bright)
            paint(x1 - 2, y0, x1, y1, bright)
        paint(x0 + bw * 0.25, y0 + bh * 0.3, x0 + bw * 0.75, y0 + bh * 0.7, by_class.get(cls, label))
        if S["chevron"] and cls == "NSPopUpButton":   # the pop-up's chevron, in the last 22pt
            paint(x1 - 16 * scale, y0 + bh * 0.3, x1 - 6 * scale, y0 + bh * 0.7, bright)
        if S["chevron"] and cls == "NSSearchField":   # magnifier on the left, cancel button on the right
            paint(x0 + 6 * scale, y0 + bh * 0.3, x0 + 16 * scale, y0 + bh * 0.7, bright)
            paint(x1 - 16 * scale, y0 + bh * 0.3, x1 - 6 * scale, y0 + bh * 0.7, bright)
    write_png(out_path, W, H, mods, bg)
    return {"path": out_path, "width": W, "height": H, "windowNumber": 100 + wi, "method": "cgwindow"}


# ------------------------------------------------------------------------------ commands

def parse_args(argv):
    opts = {"window": 0, "screen": None, "sheet": False}
    i = 0
    while i < len(argv) and argv[i].startswith("-") and argv[i] not in ("-",):
        a = argv[i]
        if a in ("-w", "--window"):
            opts["window"] = int(argv[i + 1])
            i += 2
        elif a == "--screen":
            opts["screen"] = argv[i + 1]
            i += 2
        elif a == "--sheet":
            opts["sheet"] = True
            i += 1
        else:
            die(f"fake: unknown global flag {a}", 2)
    if i >= len(argv):
        die("fake: no subcommand", 2)
    return opts, argv[i], argv[i + 1:]


def pick_window(S, st, opts):
    i = opts["window"]
    if opts["screen"]:
        needle = opts["screen"].lower()
        hits = [k for k, w in enumerate(S["windows"]) if needle in w["screen"].lower()]
        if not hits:
            die(f'error: no window on a display named like "{needle}"')
        i = hits[0]
    if not 0 <= i < len(st["windows"]):
        die(f"error: no window at index {i}")
    return i


def window_info(S, st, i):
    w, cfg = st["windows"][i], S["windows"][i]
    frame = cfg.get("frame") or {"x": 0 if i == 0 else 1710, "y": 0, "w": 1710 if i == 0 else 2560,
                                 "h": 1073 if i == 0 else 1440}
    return {"index": i, "title": cfg.get("title", "Nostromo"), "frame": frame,
            "fullscreen": cfg.get("fullscreen", True), "key": w["key"], "screen": cfg["screen"],
            "alpha": cfg.get("alpha", 1.0), "visible": cfg.get("visible", True), "windowNumber": 100 + i,
            "sheet": S["sheet"]["title"] if w["sheet"] else None,
            "firstResponder": "NSTextView" if (w["sheet"] and w["instr_fr"]) else "NSView"}


def close_sheet(w):
    w.update(sheet=False, instr_fr=False, undo=[], shared=False, instr="")


def do_action(S, st, wi, action):
    w = st["windows"][wi]
    kind, _, rest = action.partition(":")
    append("actions.log", json.dumps({"action": action, "window": wi, "tab": w["tab"], "focus": w["focus"]}))
    if kind == "focus":
        w["focus"] = rest
    elif kind == "tab":
        w["tab"] = rest
        w["row"] = w["sel"].get(rest)   # the app keeps one selection per tab
        st["clicked"][rest] = True
        st["reads"][rest] = 0
    elif kind == "row":
        w["sel"][w["tab"]] = int(rest)
        w["row"] = int(rest)
    elif kind == "fredrow":
        pane, _, i = rest.partition(":")
        w["fred_row"] = [pane, int(i)]
    elif kind == "toggle":
        w["shared"] = not w["shared"]
    elif kind == "instr":
        w["instr_fr"] = bool(S["sheet"]["click_gives_focus"])
    elif kind == "cancel":
        close_sheet(w)


def cmd_click(S, st, wi, opts, rest, argv):
    if any(a.startswith("--") for a in rest):
        forbid("click with --text/--count/--mod flags", argv)
        die("error: refused by the fake")
    try:
        x, y = float(rest[0]), float(rest[1])
    except (IndexError, ValueError):
        die("error: click needs X Y", 2)
    w = st["windows"][wi]
    if opts["sheet"]:
        if not w["sheet"]:
            die(f"error: window {wi} has no sheet")
        root = live_sheet_root(S, st, w)
        st["sheet_clicks"] = st.get("sheet_clicks", 0) + 1
    else:
        root = window_tree(S, st, wi)
    chain = chain_at(root, x, y)
    cls = chain[-1]["class"] if chain else "none"
    for n in chain:
        if n.get("_forbidden"):
            forbid(f"click on {n['_forbidden']!r} at {x},{y}", argv)
            return {"hit": cls}
    if w["sheet"] and not opts["sheet"]:
        note("click ignored: a sheet is attached and the click was not sent to it")
        return {"hit": cls}
    if not w["key"]:
        note("click ignored: window is not key")
        return {"hit": cls}
    for n in reversed(chain):
        if n.get("_action"):
            do_action(S, st, wi, n["_action"])
            break
    return {"hit": cls}


def cmd_key(S, st, wi, opts, rest, argv):
    chars = rest[0]
    mods = []
    if "--mod" in rest:
        mods = sorted(m for m in rest[rest.index("--mod") + 1].split(",") if m)
    w = st["windows"][wi]
    SH = S["sheet"]
    if chars == "s" and mods == ["cmd", "shift"]:
        if SH["opens"] and w["focus"] == "Teri" and w["row"] is not None and not w["sheet"]:
            w.update(sheet=True, instr=SH["seed_text"], instr_fr=False, undo=[], shared=False)
        return {"sent": chars}
    if chars == "\r" and not mods:
        if not (w["sheet"] and w["instr_fr"]):
            forbid("Return while the instruction text view is not the first responder", argv)
            return {"sent": chars}
        if SH["return_closes"]:
            close_sheet(w)
        else:
            w["undo"].append(w["instr"])
            w["instr"] += "\n"
        return {"sent": chars}
    if chars == "z" and mods == ["cmd"]:
        if w["sheet"] and w["instr_fr"] and SH["undo_works"] and w["undo"]:
            w["instr"] = w["undo"].pop()
        return {"sent": chars}
    if chars == "\x7f" and not mods:
        if w["sheet"] and w["instr_fr"] and w["instr"]:
            w["instr"] = w["instr"][:-1]
        return {"sent": chars}
    if chars == "\x1b" and not mods:
        if w["sheet"] and SH["escape_closes"]:
            close_sheet(w)
        return {"sent": chars}
    forbid(f"unexpected key {chars!r} {mods}", argv)
    return {"sent": chars}


def cmd_hittest(S, st, wi, opts, rest):
    x, y = float(rest[0]), float(rest[1])
    w = st["windows"][wi]
    if opts["sheet"]:
        if not w["sheet"]:
            die(f"error: window {wi} has no sheet")
        root = live_sheet_root(S, st, w)
    else:
        root = window_tree(S, st, wi)
    chain = []
    for n in reversed(chain_at(root, x, y)):
        d = {"class": n["class"], "frame": n["frame"], "isHidden": False, "alphaValue": 1.0,
             "acceptsFirstResponder": n["class"] == "NSTextView", "needsLayout": False}
        if n["class"] == "NSTextView":
            editable = n["_editable"] if "_editable" in n else (n.get("label") == "Instruction for the agent")
            d.update(isSelectable=True, isEditable=bool(editable), isFieldEditor=False,
                     selectedRange={"location": 0, "length": 0},
                     isFirstResponder=bool(w["instr_fr"] and n.get("label") == "Instruction for the agent"))
        chain.append(d)
    return {"hit": chain[0]["class"] if chain else "none", "chain": chain,
            "window": {"isKeyWindow": w["key"], "appIsActive": st["app_active"],
                       "firstResponder": window_info(S, st, wi)["firstResponder"]}}


def cmd_find(S, st, wi, opts, rest):
    needle = rest[0].lower()
    w = st["windows"][wi]
    if opts["sheet"]:
        if not w["sheet"]:
            die(f"error: window {wi} has no sheet")
        root = sheet_tree(S, w)
    else:
        root = window_tree(S, st, wi)
    out = []
    for n in walk(root):
        hay = [n.get("text"), n.get("tooltip"), n.get("label"), n["class"]]
        if any(h and needle in h.lower() for h in hay):
            f = n["frame"]
            d = {"class": n["class"], "frame": f, "center": {"x": f["x"] + f["w"] / 2, "y": f["y"] + f["h"] / 2}}
            if n.get("text"):
                d["text"] = n["text"]
            out.append(d)
    return out


def main():
    argv = sys.argv[1:]
    S = deep_merge(DEFAULTS, read_json("scenario.json", {}))
    st = read_json("state.json") or fresh_state(S)
    st["calls"] += 1
    append("calls.log", json.dumps(argv))

    opts, cmd, rest = parse_args(argv)
    dead = S["ping_fail"] or (S["die_after_calls"] is not None and st["calls"] > S["die_after_calls"])
    if cmd == "ping":
        st["pings"] += 1
        if S["ping_fail_after"] is not None and st["pings"] > S["ping_fail_after"]:
            dead = True
    if dead:
        write_json("state.json", st)
        die("cannot reach /nonexistent/app-control.sock: [Errno 2] No such file or directory\n"
            "Is the app running with AppControlEnabled (see --help)?")

    hang = S["hang"]
    if hang and cmd == hang["cmd"] and (opts["sheet"] or not hang.get("sheet")):
        st["hang_seen"] = st.get("hang_seen", 0) + 1
        if st["hang_seen"] == hang["nth"]:
            write_json("state.json", st)
            with open(path("hanging"), "w") as f:
                f.write(str(os.getpid()))
            time.sleep(hang.get("seconds", 120))
            die("fake: hang timed out")

    if cmd in ("type", "paste", "drop", "drag"):
        forbid(f"command {cmd}", argv)
        write_json("state.json", st)
        die("error: refused by the fake")

    result = None
    if cmd == "ping":
        result = {"pid": S["pid"]}
    elif cmd == "windows":
        result = [window_info(S, st, i) for i in range(len(st["windows"]))]
    elif cmd == "restore":
        if not S["restore_keeps_key"]:
            for w in st["windows"]:
                w["key"] = False
            st["app_active"] = False
        result = {"restored": True}
    else:
        wi = pick_window(S, st, opts)
        w = st["windows"][wi]
        if cmd == "activate":
            for k, other in enumerate(st["windows"]):
                other["key"] = (k == wi)
            st["app_active"] = True
            result = {"active": True}
        elif cmd == "tree":
            if opts["sheet"]:
                if not w["sheet"]:
                    die(f"error: window {wi} has no sheet")
                result = strip(sheet_tree(S, w))
            else:
                for name, flip in S["tab_flip"].items():
                    if flip.get("any_read") or st["clicked"].get(name):
                        st["reads"][name] = st["reads"].get(name, 0) + 1
                result = strip(window_tree(S, st, wi))
        elif cmd == "find":
            result = cmd_find(S, st, wi, opts, rest)
        elif cmd == "click":
            result = cmd_click(S, st, wi, opts, rest, argv)
        elif cmd == "hittest":
            result = cmd_hittest(S, st, wi, opts, rest)
        elif cmd == "key":
            result = cmd_key(S, st, wi, opts, rest, argv)
        elif cmd == "screenshot":
            out = os.path.abspath(rest[0]) if rest else os.path.join(DIR, f"shot-{wi}.png")
            result = screenshot(S, st, wi, out)
        else:
            write_json("state.json", st)
            die(f"fake: unsupported command {cmd}", 2)
    write_json("state.json", st)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
