#!/usr/bin/env python3
"""Read-only live smoke for the Teri and Fred focuses (driven by teri-fred-smoke.sh).

Drives the REAL app through bin/nostromo-app (the app-control socket) with UI-only
input: focus switches, tab clicks, selecting a row, opening and cancelling the Send to
agent sheet. It never sends anything to an agent, creates a Mother job or focus, or
changes any external system. It also never clicks the Picks tab (the first open of the day
can start a paid generation) and never clicks Sentry unless asked (leaving it resets the
"new since last viewed" markers). See scripts/qa/README.md for what it touches and leaves.

Environment: QA_APP (nostromo-app path), QA_TMPDIR (scratch dir, removed here on exit),
QA_SCREEN, QA_LOADING_TIMEOUT, QA_ALLOW_TERI_SWITCH, QA_INCLUDE_SENTRY, QA_SLEEP_SCALE.
Standard library only.
"""
import os
import re
import shutil
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pngcontrast as P   # noqa: E402
import uitree as U        # noqa: E402
from report import Report   # noqa: E402
from appctl import App, AppError, DEFAULT_TABS, RefusedError   # noqa: E402

TABS = ["Picks", "Todos", "Jira", "Sentry", "Repo docs"]
SHEET_TITLE = "send to agent"
DISCONNECTED = "Disconnected from nostromd"
TOOLBAR_CLASSES = ("NSButton", "NSPopUpButton", "NSSearchField")
SKIP_TERI = ("Teri is not the active focus (switching may start a paid Picks generation; "
             "set QA_ALLOW_TERI_SWITCH=1 to allow it)")
SENTRY_NOT_CLICKED = ("not clicked (visiting it resets the 'new since last viewed' markers; "
                      "set QA_INCLUDE_SENTRY=1 to include)")
NO_SELECTION = "Select an item"   # the detail pane's placeholder while no row is selected
SOURCE_STATES = (("Coming soon", "coming_soon"), ("Loading", "loading"), ("Not set up", "not_set_up"),
                 ("Sign in", "sign_in"), ("Rate-limited", "rate_limited"), ("Error", "error"))


def clickable_tabs(include_sentry):
    """The tabs a run may click: Picks never, Sentry only when asked for."""
    return DEFAULT_TABS + (("Sentry",) if include_sentry else ())


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


SLEEP_SCALE = env_float("QA_SLEEP_SCALE", 1)


def settle(seconds):
    time.sleep(seconds * SLEEP_SCALE)


# ---------------------------------------------------------------------------- tree parsing

def parse_sidebar(tree):
    """The focus rows: name, label node, active flag, badge text."""
    items = []
    for n in U.find_all(tree, cls="NavTabItem"):
        kids = n.get("children", [])
        labels = [k for k in kids if k.get("class") == "NSTextField" and U.text_of(k).strip()]
        if not labels:
            continue
        height = n["frame"]["h"]
        active = any(k.get("class") == "NSView" and 1 <= k["frame"]["w"] <= 5 and k["frame"]["h"] >= height * 0.7
                     for k in kids)
        pill = None
        for k in kids:
            if k.get("class") == "NSView":
                for d in U.descendants(k):
                    if d.get("class") == "NSTextField" and U.text_of(d).strip():
                        pill = U.text_of(d).strip()
        items.append({"name": U.text_of(labels[0]).strip(), "label_node": labels[0], "node": n,
                      "active": active, "badge_label": n.get("label"), "pill": pill})
    return items


def sidebar_item(tree, name):
    for item in parse_sidebar(tree):
        if item["name"].lower() == name.lower():
            return item
    return None


def tab_buttons(surface):
    split = U.first(surface, cls="TeriSplitView")
    limit = split["frame"]["y"] + 2 if split else surface["frame"]["y"] + 60
    out = {}
    for n in U.find_all(surface, cls="NSButton"):
        t = U.text_of(n)
        if n["frame"]["y"] + n["frame"]["h"] > limit:
            continue
        for name in TABS:
            if t == name or t.startswith(name + " "):
                out.setdefault(name, n)
    return out


def tab_state(name, title):
    rest = title[len(name):].strip()
    if rest.isdigit():
        return "count", rest
    for needle, kind in SOURCE_STATES:
        if needle in rest:
            return kind, rest
    return ("empty" if not rest else "unknown"), rest


def banner_texts(surface):
    out = []
    for banner in U.find_all(surface, cls="SourceStateBanner"):
        out += U.texts(banner)
    return out


def list_pane(surface):
    return U.first(surface, cls="WorkListView"), U.first(surface, cls="TeriPicksView")


def toolbar_controls(container):
    """Controls above the scrolling list: filter chips, popups, search, sort."""
    scroll = U.first(container, cls="NSScrollView")
    limit = scroll["frame"]["y"] + 1 if scroll else None
    out = []
    for n in U.find_all(container, cls=TOOLBAR_CLASSES):
        if not U.nonzero(n):
            continue
        if limit is not None and n["frame"]["y"] + n["frame"]["h"] > limit:
            continue
        if n.get("class") == "NSButton" and not (U.text_of(n) or n.get("label")):
            continue
        out.append(n)
    return out


def signature(container):
    return tuple(sorted((n.get("class", ""), n.get("label") or "") for n in toolbar_controls(container)))


def detail_pane(surface):
    detail = U.first(surface, cls="WorkDetailView")
    if not detail:
        return None, "", None, None
    body = U.first(detail, cls="NSTextView", label="Item details") or U.first(detail, cls="NSTextView")
    open_btn = U.first(detail, cls="NSPopUpButton", pred=lambda n: "Open in" in (U.text_of(n) + (n.get("label") or "")))
    send_btn = U.first(detail, cls="NSButton", pred=lambda n: U.text_of(n).startswith(("Send to agent", "Preparing")))
    return detail, U.text_of(body) if body else "", open_btn, send_btn


def control_enabled(node):
    """(enabled, how). The tree has no enabled flag today: use it when it appears, else infer."""
    if "enabled" in node:
        return bool(node["enabled"]), "reported"
    if "Open in" in (U.text_of(node) + (node.get("label") or "")):
        return not node.get("tooltip"), "inferred: the app sets the disabled reason as the tooltip"
    return U.text_of(node) == "Send to agent…", "inferred from the title (not Preparing…) with an item selected"


# ---------------------------------------------------------------------------- the run

class Smoke:
    def __init__(self, app, window_index, report, tmpdir):
        self.app = app
        self.win = window_index
        self.r = report
        self.tmp = tmpdir
        self.prev_focus = None
        self.prev_tab = None
        self.touched_tab = False
        self.allow_switch = os.environ.get("QA_ALLOW_TERI_SWITCH") == "1"
        self.include_sentry = os.environ.get("QA_INCLUDE_SENTRY") == "1"
        self.clickable_tabs = clickable_tabs(self.include_sentry)
        self.loading_timeout = env_float("QA_LOADING_TIMEOUT", 20)
        self.mode = None   # full | passive | readonly | skipped | failed: what the run may do to Teri
        self.activated = False
        self.left_changed = []   # UI state this run changed and could not put back (printed in the SUMMARY)
        self.previous_sig, self.sheet_done = None, False
        self.sheet_preexisting = False   # a sheet that was open before we started is never ours to close
        self.we_opened_sheet = False

    # -- small helpers
    def tree(self):
        return self.app.tree()

    def surface(self, tree=None):
        return U.first(tree or self.tree(), cls="TeriSurfaceView")

    def my_window(self):
        for w in self.app.windows():
            if w.get("index") == self.win:
                return w
        return {}

    def sheet_title(self):
        s = self.my_window().get("sheet")
        return s if isinstance(s, str) else None

    def wait_for(self, predicate, timeout, poll=0.5):
        end = time.time() + timeout * SLEEP_SCALE
        while True:
            value = predicate()
            if value:
                return value
            if time.time() >= end:
                return None
            settle(poll)

    def ensure_key(self):
        """Make the window key, once, right before the first click (AppKit ignores clicks on a window that is not
        key). Reads never need it, and activating can itself start things (Picks asks for its first-open when its
        window becomes key), so nothing activates until a click is about to be sent."""
        if not self.activated:
            self.activated = True
            self.app.activate()
            settle(0.6)

    def click_node(self, node, kind, sheet=False):
        if not sheet:
            self.ensure_key()
        return self.app.click_node(node, kind, sheet=sheet)

    def click_at(self, x, y, kind):
        self.ensure_key()
        return self.app.click_at(x, y, kind)

    def select_focus(self, name, expect_class):
        tree = self.tree()
        item = sidebar_item(tree, name)
        if not item:
            return None
        if not U.first(tree, cls=expect_class):
            if name.lower() == "teri" and not (self.allow_switch or (self.prev_focus or "").lower() == "teri"):
                raise RefusedError("refusing to switch to Teri: it is not the active focus and QA_ALLOW_TERI_SWITCH is not set")
            self.click_node(item["label_node"], "sidebar-row")
        return self.wait_for(lambda: U.first(self.tree(), cls=expect_class), 8)

    def survey(self):
        """Read only: which focus is active and whether a sheet is open. Nothing is activated or clicked yet."""
        tree = self.tree()
        active = [i for i in parse_sidebar(tree) if i["active"]]
        self.prev_focus = active[0]["name"] if active else None
        if self.prev_focus:
            self.r.info("b.focus", f"active focus before the run: {U.safe(self.prev_focus)} (restored on exit)")
        else:
            self.r.info("b.focus", "could not tell which focus is active; it will not be restored")
        if self.sheet_title():
            self.sheet_preexisting = True
            self.r.fail("a.focus", "a sheet is already open in this window (not ours): it blocks every click, so nothing "
                        "can be tested. Close it and run again; it was left alone")

    def run(self):
        self.guarded("a.focus", self.survey)
        if self.sheet_preexisting:
            return
        self.guarded("b.select-teri", self.step_b)
        if self.mode in ("full", "readonly", "passive") and self.surface():
            self.guarded("a.daemon", self.step_a_daemon)
            self.guarded("c.tabs", self.step_c)
            if self.mode == "full":
                self.guarded("d.legibility", self.step_d)
        if self.mode == "passive":
            self.r.info("g.fred", "not run in passive mode: switching away from Teri and back is a click this mode never sends")
        else:
            self.guarded("g.fred", self.step_g)
        self.guarded("h.badges", self.step_h)

    def guarded(self, step, fn):
        try:
            fn()
        except AppError as e:
            self.r.fail(step, f"app-control error: {U.safe(e, 120)}")
        except Exception as e:   # a bug in this script must not hide the other steps
            self.r.fail(step, f"internal error: {type(e).__name__}: {U.safe(e, 80)}")

    # -- a / b
    def step_a_daemon(self):
        surface = self.surface()
        banners = banner_texts(surface) if surface else []
        if any(DISCONNECTED in t for t in banners):
            self.r.fail("a.daemon", f"Teri shows '{DISCONNECTED}'")
        else:
            self.r.passed("a.daemon", "no 'Disconnected' banner on the Teri surface")

    def step_b(self):
        """Decide what this run may do to Teri, and (only if allowed) switch to it.

        Teri opens on the tab it was last left on. If that is Picks, merely showing it (or activating its
        window) can make the app start a paid generation; if it is Sentry, leaving it resets the "new since
        last viewed" markers. So Teri is only switched to when the caller says so, and a Teri that already
        shows Picks, Sentry or a tab nobody can identify is observed without a single click or activate."""
        tree = self.tree()
        surface = self.surface(tree)
        if surface:
            self.r.passed("b.select-teri", "Teri is the active focus (TeriSurfaceView on screen)")
        elif not self.allow_switch:
            self.mode = "skipped"
            self.r.skip("teri-fred", SKIP_TERI)
            return
        else:
            self.r.info("b.note", "switching to Teri opens the tab it was last left on (QA_ALLOW_TERI_SWITCH=1); "
                        "this script never clicks the Picks tab")
            surface = self.select_focus("Teri", "TeriSurfaceView")
            if not surface:
                item = sidebar_item(self.tree(), "Teri")
                why = "no 'Teri' row in the sidebar" if not item else "TeriSurfaceView did not appear within 8 s"
                self.mode = "failed"
                self.r.fail("b.select-teri", why)
                return
            self.r.passed("b.select-teri", "Teri focus selected (TeriSurfaceView on screen)")
        switched = (self.prev_focus or "").lower() != "teri"
        tab = self.stored_tab(self.surface())
        if tab in self.clickable_tabs:
            self.mode, self.prev_tab = "full", tab
            return
        shown = tab or "a tab it cannot identify"
        why = ("Picks: re-entering it can start a paid generation" if tab == "Picks" else
               "Sentry: leaving it resets its 'new since last viewed' markers" if tab == "Sentry" else
               "it might be Picks or Sentry")
        if switched:
            self.mode = "readonly"
            self.r.info("b.mode", f"Teri opened on {shown} ({why}): no tab is clicked and no row or sheet is tried; "
                        "Fred and the badges still run, then the previous focus comes back")
        else:
            self.mode = "passive"
            self.r.info("b.mode", f"passive mode: Teri is showing {shown} ({why}); nothing is clicked, nothing is activated, "
                        "the focus is not switched; only what can be read is checked")

    def stored_tab(self, surface):
        """The Teri tab on screen: Picks if its view is showing, else from the screenshot (None if unclear)."""
        _lst, picks = list_pane(surface)
        if picks:
            return "Picks"
        return self.detect_selected_tab(tab_buttons(surface))

    # -- c: tabs (+ e, f on the first tab with rows)
    def step_c(self):
        surface = self.surface()
        tabs = tab_buttons(surface)
        full = self.mode == "full"
        if full:
            self.r.info("c.tabs", f"tab selected before the run: {self.prev_tab} (restored after the tab checks)")
        else:
            self.r.info("c.tabs", "tabs are checked from their titles only: no tab is clicked in this mode")
        self.previous_sig, self.sheet_done = None, False
        for name in TABS:
            step = f"c.{name.lower().replace(' ', '-')}"
            try:
                self.check_tab(name, step, may_click=full and name in self.clickable_tabs)
            except Exception as e:   # one broken tab must not hide the others
                self.r.fail(step, f"{type(e).__name__}: {U.safe(e, 100)}")
        self.restore_tab()

    def check_tab(self, name, step, may_click):
        surface = self.surface()
        node = tab_buttons(surface).get(name) if surface else None
        if node is None:
            self.r.fail(step, "tab button not found in the tab strip")
            return
        title = U.text_of(node)
        kind, rest = tab_state(name, title)
        if kind == "coming_soon":
            more = " (Picks also says this until the daemon has sent a picks snapshot)" if name == "Picks" else ""
            self.r.fail(step, f"title is '{U.safe(title)}': the tab is still a placeholder{more}")
            return
        clicked = False
        if not may_click:
            if name == "Picks":
                self.r.info(step, "not clicked: opening Picks can start a paid generation (this script never clicks it)")
            elif name == "Sentry" and not self.include_sentry:
                self.r.info(step, SENTRY_NOT_CLICKED)
            else:
                self.r.info(step, "not clicked (no click is sent in this mode)")
        else:
            self.click_node(node, "tab")
            clicked = True
            self.touched_tab = True
            settle(0.6)
            surface = self.surface()
            node = tab_buttons(surface).get(name, node)
            title = U.text_of(node)
            kind, rest = tab_state(name, title)
        kind, rest, title = self.wait_out_loading(name, kind, rest, title)
        if kind == "loading":
            self.r.fail(step, f"title still '{U.safe(title)}' after {self.loading_timeout:g} s: stuck loading")
        elif kind in ("coming_soon", "empty", "unknown"):
            self.r.fail(step, f"title '{U.safe(title)}' is neither a count nor a known state")
        elif kind == "error":
            self.r.warn(step, f"title '{U.safe(title)}': the source reports an error")
        elif kind == "count":
            self.r.passed(step, f"title '{U.safe(title)}' (count {rest})")
        else:
            self.r.passed(step, f"title '{U.safe(title)}' (deliberate state: {rest})")
        for text in banner_texts(self.surface()):
            self.r.info(step, f"banner: {U.safe(text, 120)}")
        if not clicked:
            return
        sig = self.check_pane(step)
        if sig is not None and self.previous_sig is not None and sig == self.previous_sig:
            self.r.warn(step, "list toolbar identical to the previous tab's: tab selection not observable here")
        self.previous_sig = sig if sig is not None else self.previous_sig
        selected = self.guarded_select_row(step, name)
        if selected and not self.sheet_done:
            self.sheet_done = True
            self.guarded("f.sheet", self.step_f)

    def wait_out_loading(self, name, kind, rest, title):
        if kind != "loading":
            return kind, rest, title

        def done():
            s = self.surface()
            node = tab_buttons(s).get(name) if s else None
            if node is None:
                return None
            k, _ = tab_state(name, U.text_of(node))
            return node if k != "loading" else None
        node = self.wait_for(done, self.loading_timeout, poll=1.0)
        if node is None:
            return "loading", rest, title
        title = U.text_of(node)
        kind, rest = tab_state(name, title)
        return kind, rest, title

    def check_pane(self, step):
        surface = self.surface()
        lst, picks = list_pane(surface)
        if not lst or not U.nonzero(lst):
            self.r.fail(step, "list pane missing or zero-sized" if not picks else "still showing the Picks view")
            return None
        if picks:
            self.r.fail(step, "Picks view still on screen after selecting this tab")
        scroll = U.first(lst, cls="NSScrollView")
        if not scroll or not U.nonzero(scroll):
            self.r.fail(step, "list has no non-zero scroll area")
            return signature(lst)
        rows = U.find_all(lst, cls="WorkRowCellView")
        if rows:
            self.r.passed(step, f"list renders {len(rows)} visible row(s)")
        else:
            outside = [t for n in U.find_all(lst, cls="NSTextField") for t in [U.text_of(n)]
                       if t.strip() and not U.contains(scroll, n)]
            skeleton = U.first(lst, cls="WorkSkeletonView")
            if outside:
                self.r.passed(step, f"no rows; list says '{U.safe(outside[0], 80)}'")
            elif banner_texts(self.surface()):
                self.r.passed(step, "no rows; the source banner explains why")
            elif skeleton:
                self.r.info(step, "no rows; loading skeleton showing")
            else:
                self.r.fail(step, "no rows and no empty/error message at all")
        return signature(lst)

    # -- e: list -> detail
    def guarded_select_row(self, step, name):
        try:
            return self.step_e(step, name)
        except Exception as e:   # noqa: BLE001
            self.r.fail(step.replace("c.", "e.", 1), f"{type(e).__name__}: {U.safe(e, 100)}")
        return False

    def step_e(self, step, name):
        e_step = step.replace("c.", "e.", 1)
        surface = self.surface()
        lst, _ = list_pane(surface)
        rows = U.by_y(U.find_all(lst, cls="WorkRowCellView")) if lst else []
        if not rows:
            self.r.info(e_step, "no rows to select")
            return False
        scroll = U.first(lst, cls="NSScrollView")
        row = next((r for r in rows if scroll and U.contains(scroll, r)), None)
        if row is None:
            self.r.info(e_step, "no row fully inside the list's scroll area to select")
            return False
        candidates = sorted({U.text_of(n) for n in U.find_all(row, cls="NSTextField") if len(U.text_of(n)) >= 8},
                            key=len, reverse=True)
        title = candidates[0] if candidates else ""
        _d, body_now, _o, _s = detail_pane(surface)
        already = bool(body_now.strip()) and NO_SELECTION not in body_now
        if already:
            # A row was selected before the run: leave the selection exactly as it is and test what the detail shows.
            self.r.info(e_step, "a row is already selected: not clicking any row (the selection is left as it was)")
        else:
            if not self.click_row(e_step, row, scroll, "list-row"):
                return False
            self.left_changed.append(f"{name}: first row selected (none was; app-control cannot deselect)")
        settle(0.5)

        def shown():
            detail, body, open_btn, send_btn = detail_pane(self.surface())
            if detail and body and "Loading…" not in body:
                return detail, body, open_btn, send_btn
            return None
        got = self.wait_for(shown, 8)
        detail, body, open_btn, send_btn = got if got else detail_pane(self.surface())
        marker = "Couldn't load the details"
        if marker in body:   # the body starts with the item's title: print only what follows the marker
            self.r.fail(e_step, f"detail failed to load: {U.safe(body.split(marker, 1)[1], 60)}")
            return False
        if not got:
            self.r.fail(e_step, "detail pane still loading or empty after 8 s")
            return False
        flat = " ".join(body.split())
        if any(" ".join(c.split())[:40] in flat for c in candidates):
            self.r.passed(e_step, f"detail shows the selected item's title ('{U.safe(title)}')")
        elif already:
            self.r.passed(e_step, "detail shows an item (selected before the run; its row may be off screen)")
        else:
            self.r.fail(e_step, f"detail does not show the selected row's title ('{U.safe(title)}')")
        has_links = "Links" in body
        if name in ("Jira", "Sentry", "Repo docs"):
            enabled, how = control_enabled(open_btn) if open_btn else (False, "missing")
            if has_links or (open_btn and enabled):
                self.r.passed(e_step, f"Links section {'present' if has_links else 'absent'}, Open in… {'enabled' if enabled else 'disabled'} ({how})")
            else:
                self.r.fail(e_step, "neither a Links section nor an enabled Open in… control")
        for label, node in (("Open in…", open_btn), ("Send to agent…", send_btn)):
            if node is None:
                self.r.fail(e_step, f"'{label}' control not found in the detail pane")
                continue
            enabled, how = control_enabled(node)
            if enabled:
                self.r.passed(e_step, f"'{label}' present and enabled ({how})")
            elif label == "Open in…" and name == "Todos":
                self.r.info(e_step, f"'{label}' disabled for this item: {U.safe(node.get('tooltip'), 80)}")
            else:
                self.r.fail(e_step, f"'{label}' present but disabled ({how}): {U.safe(node.get('tooltip'), 80)}")
        return True

    def click_row(self, step, row, container, kind):
        """Click a row at a point that a read-only hit test says is the row, never a button on it
        (a row can carry a 'sent to ...' marker button that navigates away) and never outside `container`.
        The hit test and its refusal live in appctl: any button anywhere in the hit chain refuses the click."""
        f = row["frame"]
        for frac in (0.45, 0.25, 0.6):
            x, y = f["x"] + f["w"] * frac, f["y"] + f["h"] / 2.0
            c = container["frame"]
            if not (c["x"] <= x <= c["x"] + c["w"] and c["y"] <= y <= c["y"] + c["h"]):
                continue
            try:
                self.click_at(x, y, kind)
                return True
            except RefusedError:
                continue
        self.r.fail(step, "every candidate point on the first row is a button or outside the list; nothing was clicked")
        return False

    # -- f: the Send to agent sheet, cancel path only
    def step_f(self):
        step = "f.sheet"
        if self.sheet_preexisting or self.sheet_title():
            self.r.info(step, "skipped: a sheet is already open, and it is not ours to drive")
            return
        self.ensure_key()
        self.app.key("s", ("cmd", "shift"))
        title = self.wait_for(self.sheet_title, 10)
        if not title:
            self.r.fail(step, "no sheet appeared within 10 s of ⌘⇧S (selected row, surface focused?)")
            return
        if SHEET_TITLE not in title.lower():
            self.r.fail(step, f"an unexpected sheet is attached ('{U.safe(title)}'); leaving it alone")
            return
        self.we_opened_sheet = True
        for check in (lambda: self.check_sheet_controls(step, self.app.tree(sheet=True)),
                      lambda: self.check_return_newline(step, self.app.tree(sheet=True))):   # fresh: the preview toggle moved things
            try:
                check()
            except RefusedError as e:   # the layout moved or something else is there: nothing was clicked
                self.r.fail(step, U.safe(e, 140))
        # Cancel the sheet right away, whatever happened: an open sheet blocks every click that follows.
        self.app.key("\x1b", key_code=53, sheet=True)
        gone = self.wait_for(lambda: self.sheet_title() is None, 5)
        if gone:
            self.r.passed(step, "Escape closed the sheet; Start was never pressed")
        else:
            self.r.fail(step, "sheet still open 5 s after Escape: close it by hand (Cancel); nothing was sent")

    def check_sheet_controls(self, step, sheet):
        dest = U.first(sheet, label="Destination")
        instr = U.first(sheet, cls="NSTextView", label="Instruction for the agent")
        toggle = U.first(sheet, cls="NSButton", label="What will be shared")
        caption = any("What will be shared" in t for t in U.texts(sheet))
        start = U.first(sheet, cls="NSButton", pred=lambda n: U.text_of(n) in ("Start", "Go to existing focus", "Go to existing job"))
        cancel = U.first(sheet, cls="NSButton", text="Cancel")
        for label, node in (("destination control", dest), ("instruction text view", instr),
                            ("'What will be shared' toggle", toggle), ("Cancel button", cancel)):
            (self.r.passed if node else self.r.fail)(step, f"{label} {'present' if node else 'MISSING'}")
        (self.r.passed if caption else self.r.fail)(step, "'What will be shared (read-only)' caption " + ("present" if caption else "MISSING"))
        if start:
            self.r.passed(step, f"primary button '{U.text_of(start)}' present (not pressed; its enabled state is not in the tree)")
        else:
            self.r.fail(step, "primary button (Start / Go to existing …) MISSING")
        if toggle:
            self.check_shared_preview(step, toggle)

    def check_shared_preview(self, step, toggle):
        self.click_node(toggle, "sheet-toggle", sheet=True)
        settle(0.4)
        sheet = self.app.tree(sheet=True)   # the sheet grew: everything below the toggle moved
        view = U.first(sheet, cls="NSTextView", label="What will be shared with the agent, read only")
        if not view or not U.nonzero(view):
            self.r.fail(step, "expanding 'What will be shared' shows no preview text view")
        else:
            x, y = U.center(view)
            chain = self.app.hittest(x, y, sheet=True).get("chain", [])
            editable = any(c.get("class", "").endswith("TextView") and c.get("isEditable") for c in chain)
            has_text = bool(U.text_of(view).strip())
            ok = has_text and not editable
            (self.r.passed if ok else self.r.fail)(
                step, f"shared preview {'is read-only and non-empty' if ok else 'is empty or EDITABLE'} (text not printed)")
        # Collapse again, from a frame read AFTER the expand; appctl hit-tests it first and refuses unless it is still the toggle.
        again = U.first(sheet, cls="NSButton", label="What will be shared")
        if again is None:
            self.r.fail(step, "the 'What will be shared' toggle is gone after expanding; not collapsing it")
            return
        self.click_node(again, "sheet-toggle", sheet=True)
        settle(0.2)

    def check_return_newline(self, step, sheet):
        """Plain Return in the instruction view must add a newline, never start a send."""
        instr = U.first(sheet, cls="NSTextView", label="Instruction for the agent")
        if not instr:
            return
        x, y = U.center(instr)
        try:
            self.click_node(instr, "sheet-text", sheet=True)
        except RefusedError as e:
            self.r.fail(step, f"{U.safe(e, 120)}; not clicking the instruction view")
            return
        settle(0.3)
        before = self.instruction_text()
        # app-control cuts view text at 160 characters (plus "…"): a long seeded instruction cannot be compared.
        verifiable = len(before) < 150
        try:   # appctl hit-tests the view again right before the key and refuses unless it has the keyboard
            self.app.key("\r", key_code=36, sheet=True, return_target=(x, y))
        except RefusedError:
            self.r.fail(step, "cannot prove the instruction text view has the keyboard; NOT pressing Return "
                        "(outside a text view Return would confirm the send)")
            return
        settle(0.4)
        if not self.sheet_title():
            self.r.fail(step, "plain Return CLOSED the sheet: it may have started a send. Check Mother's queue and the sidebar NOW")
            return
        if not verifiable:
            self.r.passed(step, "plain Return left the sheet open (the instruction is too long for app-control to show, "
                          "so the newline itself is not verified)")
            self.app.key("z", ("cmd",), key_code=6, sheet=True)
            return
        changed = self.instruction_text() == before + "\n"
        (self.r.passed if changed else self.r.fail)(
            step, "plain Return inserted a newline and the sheet stayed open" if changed
            else "plain Return did not insert a newline (the keystroke went somewhere else)")
        self.app.key("z", ("cmd",), key_code=6, sheet=True)
        settle(0.3)
        if self.instruction_text() != before:
            self.app.key("\x7f", key_code=51, sheet=True)
            settle(0.3)
            if self.instruction_text() != before:
                self.r.warn(step, "could not undo the newline (the sheet is cancelled next, so nothing is kept)")

    def instruction_text(self):
        hits = [h for h in self.app.find("Instruction for the agent", sheet=True) if h.get("class", "").endswith("TextView")]
        return U.text_of(hits[0]) if hits else ""

    # -- d: legibility
    def step_d(self):
        self.ensure_key()   # the "active" pass needs the window key
        for state in ("active", "inactive"):
            step = f"d.legibility[{state}]"
            if state == "inactive":
                self.app.restore()
                settle(0.8)
                if self.my_window().get("key"):
                    self.r.warn(step, "window is still key after restore (the app was already frontmost): inactive state not measured")
                    continue
            try:
                self.measure_legibility(step, state)
            finally:
                if state == "inactive":
                    self.app.activate()
                    settle(0.6)

    def measure_legibility(self, step, state):
        tree = self.tree()
        surface = U.first(tree, cls="TeriSurfaceView")
        if not surface:
            self.r.fail(step, "Teri surface not on screen")
            return
        targets = [(f"tab '{n}'", node) for n, node in tab_buttons(surface).items()]
        lst, picks = list_pane(surface)
        container = lst or picks
        if container:
            for node in toolbar_controls(container):
                targets.append((f"toolbar {node['class']} '{U.safe(U.text_of(node) or node.get('label'), 30)}'", node))
        path = os.path.join(self.tmp, f"teri-{state}.png")
        shot = self.app.screenshot(path)
        scale = shot["width"] / float(tree["frame"]["w"])
        y_off = max(0.0, shot["height"] - tree["frame"]["h"] * scale)   # a title bar above the content view
        rects = []
        for label, node in targets:
            rects.append((label, node, self.label_pixels(node, scale, y_off)))
        max_x = int(max(r[2][2] for r in rects)) + 4 if rects else 1
        max_y = int(max(r[2][3] for r in rects)) + 4 if rects else 1
        try:
            img = P.decode_png(path, max_rows=max_y, max_cols=max_x)
        except (P.PngError, OSError, ValueError) as e:
            self.r.fail(step, f"cannot read the screenshot: {e}")
            return
        worst = None
        for label, _node, rect in rects:
            res = P.region_contrast(img, *rect)
            if res is None:
                self.r.warn(step, f"{label}: no pixels in the screenshot")
                continue
            ratio, bg, fg = res
            verdict = P.classify(ratio)
            if worst is None or ratio < worst[0]:
                worst = (ratio, label)
            if verdict != "PASS":
                (self.r.fail if verdict == "FAIL" else self.r.warn)(
                    step, f"{label}: contrast {ratio:.1f}:1 (label #{fg[0]:02x}{fg[1]:02x}{fg[2]:02x} on "
                          f"#{bg[0]:02x}{bg[1]:02x}{bg[2]:02x}); needs 3:1, 4.5:1 preferred")
        if worst and worst[0] >= P.FAIL_BELOW:
            self.r.passed(step, f"{len(rects)} labels measured; lowest contrast {worst[0]:.1f}:1 ({worst[1]})")
        elif not worst:
            self.r.fail(step, "no controls could be measured")

    @staticmethod
    def label_pixels(node, scale, y_off):
        """Pixel rectangle that can only hold the control's label: the frame of its own text field when the tree has
        one, else the control's frame minus its chrome (bezel, chevron, magnifier), see pngcontrast.label_rect."""
        def px(f):
            return (f["x"] * scale, y_off + f["y"] * scale, (f["x"] + f["w"]) * scale, y_off + (f["y"] + f["h"]) * scale)
        for child in U.descendants(node):
            if child.get("class") == "NSTextField" and U.text_of(child).strip() and U.nonzero(child):
                return px(child["frame"])
        return P.label_rect(px(node["frame"]), node.get("class", ""), scale)

    # -- selected tab (pixels): used to put the tab back where it was
    def detect_selected_tab(self, tabs):
        if len(tabs) < len(TABS):
            return None
        try:
            tree = self.tree()
            path = os.path.join(self.tmp, "teri-before.png")
            shot = self.app.screenshot(path)
            scale = shot["width"] / float(tree["frame"]["w"])
            y_off = max(0.0, shot["height"] - tree["frame"]["h"] * scale)
            rects = {}
            for name, n in tabs.items():
                f = n["frame"]
                rects[name] = (f["x"] * scale, y_off + f["y"] * scale, (f["x"] + f["w"]) * scale, y_off + (f["y"] + f["h"]) * scale)
            img = P.decode_png(path, max_rows=int(max(r[3] for r in rects.values())) + 2,
                               max_cols=int(max(r[2] for r in rects.values())) + 2)
            strip = (min(r[0] for r in rects.values()), min(r[1] for r in rects.values()),
                     max(r[2] for r in rects.values()), max(r[3] for r in rects.values()))
            bg = P.surface_colour(img, *strip)
            frac = sorted(((P.filled_fraction(img, *r, bg), n) for n, r in rects.items()), reverse=True)
        except (AppError, P.PngError, OSError, ValueError, KeyError):
            return None
        if frac[0][0] >= 0.4 and frac[0][0] - frac[1][0] >= 0.2:
            return frac[0][1]
        return None

    def restore_tab(self):
        if not self.touched_tab:
            return
        target = self.prev_tab
        self.touched_tab = False
        if not target:
            return
        surface = self.surface()
        node = tab_buttons(surface).get(target) if surface else None
        try:
            if not node:
                raise AppError("the Teri surface is not on screen")
            self.click_node(node, "tab")
        except AppError as e:   # includes a refused click (something is over the tab)
            self.r.warn("c.tabs", f"could not put the Teri tab back on {target}: {U.safe(e, 100)}")
            self.left_changed.append(f"Teri tab: not put back on {target}")
            return
        settle(0.4)
        self.r.info("c.tabs", f"selected tab put back on {target}")

    # -- g: Fred
    def step_g(self):
        row = sidebar_item(self.tree(), "Fred")
        pill = (row or {}).get("pill")
        if row and pill and not pill.strip().isdigit():
            # a non-numeric badge on the Fred row is its sign-in / unavailable state: do not even select Fred
            self.r.info("g.fred", f"Fred's sidebar badge says '{U.safe(pill, 30)}' (signed out or unavailable): "
                        "Fred is not selected and nothing in it is touched")
            return
        fred = self.select_focus("Fred", "FredSurfaceView")
        if not fred:
            if not sidebar_item(self.tree(), "Fred"):
                self.r.fail("g.fred", "no 'Fred' row in the sidebar")
            else:
                self.r.fail("g.fred", "FredSurfaceView did not appear within 8 s of selecting Fred")
            return
        settle(0.5)
        tree = self.tree()
        fred = U.first(tree, cls="FredSurfaceView")
        if any("Sign in to Microsoft 365" in t for pane in U.find_all(fred, cls="FredPane") for t in U.texts(pane)):
            self.r.info("g.fred", "Fred shows its Microsoft 365 sign-in prompt (signed out): nothing in it is clicked, "
                        "read or tested; the sign-in flow is yours to start")
            return
        already_open = U.first(fred, cls="FredDetailView") is not None   # before any click of ours
        panes = {}
        for pane in U.find_all(fred, cls="FredPane"):
            header = next((t for t in U.texts(pane) if t.startswith(("Inbox", "Today"))), None)
            if header:
                panes["Inbox" if header.startswith("Inbox") else "Today"] = (pane, header)
        pill = (sidebar_item(tree, "Fred") or {}).get("pill")
        for name, row_cls, empty in (("Inbox", "FredInboxCell", "No messages in your Inbox"),
                                     ("Today", "FredTodayCell", "No meetings today")):
            step = f"g.{name.lower()}"
            if name not in panes:
                self.r.fail(step, f"{name} pane not found")
                continue
            pane, header = panes[name]
            rows = U.by_y(U.find_all(pane, cls=row_cls))
            extra = [t for t in U.texts(pane) if t != header and not t.startswith(("Inbox", "Today"))]
            sign_in = any("Sign in to Microsoft 365" in t for t in extra)
            banners = [t for b in U.find_all(pane, cls="SourceStateBanner") for t in U.texts(b)]
            if rows:
                self.r.passed(step, f"pane renders {len(rows)} row(s); header '{U.safe(header)}'")
            elif any(empty in t for t in extra) or sign_in or banners:
                shown = empty if any(empty in t for t in extra) else ("sign-in prompt" if sign_in else U.safe(banners[0], 80))
                self.r.passed(step, f"no rows; deliberate state: {shown}")
            else:
                self.r.fail(step, f"pane shows no rows and no empty/sign-in/banner state (header '{U.safe(header)}')")
            for t in banners:
                self.r.info(step, f"banner: {U.safe(t, 120)}")
            self.check_fred_count(step, name, header, pill, len(rows))
            if rows and already_open:
                self.r.info(step, "a Fred detail was already open: no row is clicked (the view is left as it was)")
            elif rows:
                self.open_fred_detail(step, name, pane, rows[0])

    def check_fred_count(self, step, name, header, pill, shown_rows):
        m = re.search(r"·\s*(\d+)", header)
        if not m:
            self.r.info(step, f"header '{U.safe(header)}' carries no count (source not trusted yet or signed out)")
            return
        n = int(m.group(1))
        if name == "Inbox":
            if pill and pill.isdigit():
                (self.r.passed if int(pill) == n else self.r.fail)(
                    step, f"sidebar badge {pill} {'matches' if int(pill) == n else 'does NOT match'} the header's {n} unread")
            elif pill:
                self.r.info(step, f"sidebar badge '{U.safe(pill)}' (sign-in / unavailable) while the header says {n} unread")
            elif n == 0:
                self.r.passed(step, "0 unread and no sidebar pill, as designed")
            else:
                self.r.fail(step, f"header says {n} unread but the sidebar Fred row has no count pill")
        else:
            if n > 0 and shown_rows == 0:
                self.r.fail(step, f"header says {n} meeting(s) but no rows are drawn")
            elif shown_rows == n:
                self.r.passed(step, f"{n} meeting(s) in the header, {shown_rows} row(s) drawn")
            else:
                self.r.info(step, f"{n} meeting(s) in the header, {shown_rows} row(s) drawn (cancelled/all-day rows may differ)")

    def open_fred_detail(self, step, name, pane, row):
        if not self.click_row(step, row, pane, "fred-row"):
            return
        self.left_changed.append(f"Fred: {name} first row open in detail")
        settle(0.5)
        fred = U.first(self.tree(), cls="FredSurfaceView")
        detail = U.first(fred, cls="FredDetailView") if fred else None
        if not detail:
            self.r.fail(step, "clicking the first row did not open the detail view")
            return
        names = {U.text_of(n) for n in U.find_all(detail, cls="NSButton")}
        want = "Ask Fred…" if name == "Inbox" else "Prep with Fred"
        missing = [b for b in ("Open in Outlook", want) if b not in names]
        if missing:
            self.r.fail(step, f"detail view opened but lacks: {', '.join(missing)}")
        else:
            self.r.passed(step, f"detail view opens for the first row; 'Open in Outlook' and '{want}' present (not pressed)")

    # -- h: sidebar badges
    def step_h(self):
        tree = self.tree()
        for name in ("Fred", "Mother", "Perri", "Teri"):
            item = sidebar_item(tree, name)
            if not item:
                self.r.fail(f"h.{name.lower()}", "no such row in the sidebar")
                continue
            text = item["badge_label"] or item["pill"]
            if text is None:
                self.r.info(f"h.{name.lower()}", "no badge shown (the app publishes none when idle, empty or still loading)")
            elif not text.strip():
                self.r.fail(f"h.{name.lower()}", "badge element exists but is an empty string")
            else:
                self.r.passed(f"h.{name.lower()}", f"badge '{U.safe(text)}'")

    # -- exit: hand everything back
    def cleanup(self):
        try:
            if self.we_opened_sheet and SHEET_TITLE in (self.sheet_title() or "").lower():
                self.app.key("\x1b", key_code=53, sheet=True)   # Cancel: the only thing ever sent to a sheet on exit
                settle(0.5)
                if self.sheet_title():
                    self.r.warn("cleanup", "Send to agent sheet is still open: close it by hand (nothing was sent)")
        except Exception as e:   # noqa: BLE001: best effort
            self.r.warn("cleanup", f"could not check for an open sheet: {U.safe(e, 80)}")
        try:
            if self.activated and not self.my_window().get("key"):
                self.app.activate()   # an interrupted run may be between restore and activate: clicks need a key window
                settle(0.4)
            if self.touched_tab and self.prev_tab and not self.surface():
                self.select_focus("Teri", "TeriSurfaceView")   # an early exit left another focus showing
            self.restore_tab()
        except Exception as e:   # noqa: BLE001
            self.r.warn("cleanup", f"could not put the Teri tab back: {U.safe(e, 80)}")
            self.left_changed.append(f"Teri tab: not put back on {self.prev_tab}")
        try:
            if self.prev_focus:
                tree = self.tree()
                item = sidebar_item(tree, self.prev_focus)
                if item and not item["active"]:
                    self.click_node(item["label_node"], "sidebar-row")
                    settle(0.5)
                    self.r.info("b.focus", f"focus put back on {U.safe(self.prev_focus)}")
        except Exception as e:   # noqa: BLE001
            self.r.warn("cleanup", f"could not put the focus back: {U.safe(e, 80)}")
            self.left_changed.append(f"focus: not put back on {U.safe(self.prev_focus, 20)}")
        if self.activated:
            try:
                self.app.restore()
            except Exception:   # noqa: BLE001
                pass


def locate_window(binary, screen, report, allowed_tabs):
    """The window to test: by display name when asked, else the one showing Teri."""
    base = App(binary)
    wins = base.windows()
    if not wins:
        report.fail("a.window", "the app reports no windows")
        return None
    if screen:
        for w in wins:
            if screen.lower() in str(w.get("screen", "")).lower():
                report.info("a.window", f"window {w['index']} on display '{U.safe(w.get('screen'), 40)}' (QA_SCREEN)")
                return App(binary, ["--screen", screen], allowed_tabs), w["index"]
        report.fail("a.window", f"no window on a display named like '{U.safe(screen, 40)}'")
        return None
    for w in wins:
        app = App(binary, ["-w", str(w["index"])], allowed_tabs)
        if U.first(app.tree(), cls="TeriSurfaceView"):
            report.info("a.window", f"Teri is showing in window {w['index']} (display '{U.safe(w.get('screen'), 40)}')")
            return app, w["index"]
    w = next((x for x in wins if x.get("key")), wins[0])
    report.info("a.window", f"Teri is not showing anywhere; using window {w['index']} (display '{U.safe(w.get('screen'), 40)}')")
    return App(binary, ["-w", str(w["index"])], allowed_tabs), w["index"]


def remove_scratch(tmp):
    """The wrapper `exec`s this process (so a signal sent to it lands here and the clean-up still runs), which
    leaves no shell trap to remove the scratch directory (screenshots of the user's real data): do it here, but
    only for a directory the wrapper made."""
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    if os.path.basename(os.path.normpath(tmp)).startswith("nostromo-qa."):
        shutil.rmtree(tmp, ignore_errors=True)


def run_smoke(binary, tmp, report):
    base = App(binary)
    try:
        pong = base.ping() or {}
    except AppError as e:
        report.fail("a.ping", f"app-control not reachable: {U.safe(e, 120)}")
        report.summary()
        return 2
    report.passed("a.ping", f"app-control reachable (pid {pong.get('pid', '?')})")

    smoke = None
    try:
        tabs = clickable_tabs(os.environ.get("QA_INCLUDE_SENTRY") == "1")
        located = locate_window(binary, os.environ.get("QA_SCREEN"), report, tabs)
        if not located:
            report.summary()
            return 1
        app, index = located
        smoke = Smoke(app, index, report, tmp)
        smoke.run()
    except KeyboardInterrupt as e:
        report.fail("run", f"interrupted ({e}); cleaning up")
    except AppError as e:
        report.fail("run", f"app-control error: {U.safe(e, 120)}")
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)   # a second Ctrl-C must not abort the clean-up
        if smoke:
            smoke.cleanup()
    return report.summary(smoke.left_changed if smoke else None)


def main():
    binary = os.environ.get("QA_APP")
    tmp = os.environ.get("QA_TMPDIR")
    if not binary or not tmp:
        sys.exit("smoke.py is run by teri-fred-smoke.sh (QA_APP and QA_TMPDIR must be set)")

    def bail(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, bail)

    report = Report()
    try:
        return run_smoke(binary, tmp, report)
    except KeyboardInterrupt:   # a signal during the very first calls, before there was anything to put back
        report.fail("run", "interrupted before the run started")
        return report.summary()
    finally:
        remove_scratch(tmp)


if __name__ == "__main__":
    sys.exit(main())
