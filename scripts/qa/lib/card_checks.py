"""Pure checks over `nostromo-app` JSON (approvals list, tree, find, hittest) and a window screenshot,
for scripts/qa/approvals-card.sh. Standard library only (zlib + struct through pngcontrast.py).

CLI (used by the script; JSON on stdin or in files, results on stdout):
  card_checks.py expected COMMAND                          -> the fixture's expected first line (ASCII prefix)
  card_checks.py pick COMMAND            < listing.json    -> request_id; exit 1 no card yet, 4 ambiguous
  card_checks.py state REQUEST_ID        < listing.json    -> ready|gated|waiting:<label>|missing
  card_checks.py label REQUEST_ID        < listing.json    -> the Allow once label
  card_checks.py stale                   < listing.json    -> request_ids, one per line
  card_checks.py probe REQUEST_ID        < listing.json    -> the `find` probe (may be empty)
  card_checks.py window REQUEST_ID       < listing.json    -> index of the first window showing the card
  card_checks.py present REQUEST_ID      < listing.json    -> exit 0 if the card is listed, 1 if gone
  card_checks.py locate REQUEST_ID LISTING TREE            -> JSON {"window", "text_area", "center", "buttons"}; exit 1 + reason
  card_checks.py button REQUEST_ID LABEL LISTING TREE      -> "X Y" of that button's centre inside the card
  card_checks.py prove REQUEST_ID LISTING TREE FIND PNG    -> verdict lines; exit 1 if the text is not drawn
  card_checks.py excerpt TREE                              -> the Approval* part of a tree, for a FAIL message
  card_checks.py responder < hittest.json                  -> class of the first responder
  card_checks.py composer < hittest.json                   -> exit 0 if the first responder is the chat composer (ChatTextView)
  card_checks.py fakelog ROOT FIXTURE [COMMAND]            -> the fake CLI's answer for the fixture; exit 0 allow
                                                              (input unchanged when COMMAND is given), 1 not (reason)
  card_checks.py survives < find.json                      -> exit 0 if the `find` result is non-empty (session row still there)

Why pixels: `find` matches NSTextView.string (the model text), accessibility labels, tooltips and class names,
never glyphs, and it is not scoped to the card; a card with line numbers and an empty text area passes it. The
proof of "text drawn" is therefore the screenshot: the card's text viewport (the NSClipView inside the card's
ApprovalInputView, which excludes the line-number gutter) is cropped out of the window PNG and must hold glyph
pixels (luminance far from the viewport's own background), overall and in the first line's band. `find` stays as
a secondary "text in view tree" check, scoped to the card's frame (a hit must overlap it).
"""
import json
import os
import re
import struct
import sys
import zlib
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngcontrast  # noqa: E402

GATED_LABEL = "Scroll to the end to allow"
PROBE_CHARS = 12
MIN_PREFIX = 4              # a shorter (or non-ASCII-leading) expected line selects by the full input instead
GLYPH_DELTA = 60            # luminance (0-255) distance from the background that counts as a glyph pixel
MIN_GLYPH_PIXELS = 40       # needed in the whole text viewport and in the first line's band
FIRST_LINE_BAND_PT = 22     # 6 pt text inset + one 12 pt monospaced line, from the viewport's top
MIN_AREA_PT = 8             # a text viewport narrower or shorter than this was not laid out


class AmbiguousCard(Exception):
    """More than one card matches the fixture: the script must not pick one by position."""


def cards(listing):
    return list((listing or {}).get("approvals") or [])


def first_line(card):
    return (card.get("input") or "").split("\n", 1)[0]


def ascii_prefix(text):
    """`text` up to the first non-ASCII or control character (the card shows those as tokens)."""
    out = []
    for ch in text:
        if ord(ch) > 126 or ord(ch) < 32:
            break
        out.append(ch)
    return "".join(out)


def expected_first_line(command):
    """What a card's input must start with: the fixture's first command line, cut at the first character
    the card renders as a token."""
    return ascii_prefix((command or "").split("\n", 1)[0])


def pick_card(listing, expected_first_line_text, full_input=None):
    """The one card for a fixture, else None. Never positional, never on an empty prefix.

    An expected line of at least MIN_PREFIX characters matches cards whose input starts with it. A shorter one
    (or none) falls back to exact equality of the whole input with `full_input` (trailing newlines ignored);
    with no `full_input` nothing matches. Two or more matches raise AmbiguousCard."""
    expected = expected_first_line_text or ""
    if len(expected) >= MIN_PREFIX:
        matches = [c for c in cards(listing) if (c.get("input") or "").startswith(expected)]
    elif (full_input or "").strip("\n"):
        want = full_input.rstrip("\n")
        matches = [c for c in cards(listing) if (c.get("input") or "").rstrip("\n") == want]
    else:
        matches = []
    if len(matches) > 1:
        raise AmbiguousCard("ambiguous card selection: %d cards match (%s)"
                            % (len(matches), ", ".join(str(c.get("request_id")) for c in matches)))
    return matches[0] if matches else None


def pick_for_command(listing, command):
    """pick_card for a fixture's raw first-tool command."""
    return pick_card(listing, expected_first_line(command), command)


def card_by_id(listing, request_id):
    for c in cards(listing):
        if c.get("request_id") == request_id:
            return c
    return None


def allow_option(card):
    for o in card.get("options") or []:
        if o.get("id") == "allow_once":
            return o
    return None


def allow_state(card):
    """('ready'|'gated'|'waiting'|'missing', label). Ready only when enabled:true."""
    o = allow_option(card) if card else None
    if o is None:
        return "missing", ""
    label = o.get("label", "")
    if o.get("enabled") is True:
        return "ready", label
    if label == GATED_LABEL:
        return "gated", label
    return "waiting", label


def stale_ids(listing):
    return [c["request_id"] for c in cards(listing) if c.get("request_id")]


def rendered_first_line(card):
    """The first line as the card's text view shows it (tokens for invisible characters)."""
    lines = card.get("lines") or []
    if lines and lines[0].get("text"):
        return lines[0]["text"]
    return first_line(card)


def probe_text(card):
    """The `find` probe: up to 12 characters of the rendered first line, cut at the first non-ASCII or
    invisible character (the raw input's U+202E is a token on the card, so `find` would miss it). Empty when
    fewer than MIN_PREFIX characters remain."""
    probe = ascii_prefix(rendered_first_line(card))[:PROBE_CHARS]
    return probe if len(probe) >= MIN_PREFIX else ""


def card_windows(card):
    w = [i for i in (card or {}).get("windows") or [] if isinstance(i, int)]
    return w or [0]


COMPOSER_CLASS = "ChatTextView"     # the chat composer's NSTextView subclass (ReplInputBar.swift)


def is_composer(responder):
    return responder == COMPOSER_CLASS


# ---- the fake CLI's logs ----

def _read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def _cue_in(text, fixture):
    """The cue `FIXTURE:<fixture>` as a whole word: `FIXTURE:simple_rm` never matches `FIXTURE:simple_rm2`."""
    return re.search(r"FIXTURE:%s(?![A-Za-z0-9_])" % re.escape(fixture), text) is not None


def fake_cli_responses(root, fixture):
    """(directory, responses) of `fake_cli_select`, without the fallback flag."""
    d, responses, _ = fake_cli_select(root, fixture)
    return d, responses


def fake_cli_select(root, fixture):
    """(directory, responses, fallback) of the fake CLI process that served `fixture`.

    The daemon starts the fake CLI several times (a catalog probe, then the session), each in its own
    `fake-claude/<pid>/` directory, so the first `responses.jsonl` on disk may be the probe's empty one. Pick by
    content: the directory whose `stdin.jsonl` carries the cue `FIXTURE:<fixture>` (the newest such directory
    when several do); else the newest non-empty `responses.jsonl` (fallback=True); else (None, [], False)."""
    dirs = []
    for base, _, names in os.walk(root):
        if os.path.basename(os.path.dirname(base)) == "fake-claude" and (
                "stdin.jsonl" in names or "responses.jsonl" in names):
            dirs.append(base)
    cued = []
    for d in dirs:
        try:
            with open(os.path.join(d, "stdin.jsonl"), encoding="utf-8", errors="replace") as f:
                if _cue_in(f.read(), fixture):
                    cued.append(d)
        except OSError:
            pass
    newest = lambda ds: max(ds, key=lambda d: (_mtime(os.path.join(d, "responses.jsonl")), d))  # noqa: E731
    if cued:
        d = newest(cued)
        return d, _read_jsonl(os.path.join(d, "responses.jsonl")), False
    filled = [d for d in dirs if _read_jsonl(os.path.join(d, "responses.jsonl"))]
    if filled:
        d = newest(filled)
        return d, _read_jsonl(os.path.join(d, "responses.jsonl")), True
    return None, [], False


def _behaviors(responses):
    """Every permission answer in the log, wrapped or bare: dicts that carry a `behavior`."""
    out = []

    def visit(node):
        if isinstance(node, dict):
            if "behavior" in node:
                out.append(node)
            for v in node.values():
                visit(v)
        elif isinstance(node, list):
            for v in node:
                visit(v)
    visit(responses)
    return out


def check_allow(root, fixture, command=None):
    """(ok, message): the fixture's fake CLI got `behavior: allow` and, when `command` is given, its
    `updatedInput.command` equals it (the card's input, unchanged)."""
    d, responses, fallback = fake_cli_select(root, fixture)
    if d is None:
        return False, "no fake CLI responses found under %s" % root
    if fallback:
        return False, ("fallback log used: no fake CLI stdin holds the cue FIXTURE:%s, so the newest non-empty log "
                       "(%s) cannot be tied to this fixture" % (fixture, d))
    answers = _behaviors(responses)
    if not answers:
        return False, "the fake CLI log %s has no permission answer" % d
    if answers[-1].get("behavior") != "allow":
        return False, "the LAST answer after the cue is %s, not allow (%s)" % (answers[-1].get("behavior"), d)
    allows = [answers[-1]]
    if command is None:
        return True, "allow (%s)" % d
    for a in allows:   # only the last answer counts
        got = (a.get("updatedInput") or {}).get("command")
        if got is not None and got.rstrip("\n") == command.rstrip("\n"):
            return True, "allow with the input unchanged (%s)" % d
    return False, "allow, but updatedInput.command is not the card's input (%s): %r" % (
        d, [(a.get("updatedInput") or {}).get("command") for a in allows])


# ---- view tree ----

def _walk(node):
    yield node
    for child in node.get("children") or ():
        yield from _walk(child)


def _frame(node):
    f = node.get("frame") or {}
    return {k: float(f.get(k, 0) or 0) for k in ("x", "y", "w", "h")}


def _intersect(a, b):
    x0, y0 = max(a["x"], b["x"]), max(a["y"], b["y"])
    x1, y1 = min(a["x"] + a["w"], b["x"] + b["w"]), min(a["y"] + a["h"], b["y"] + b["h"])
    return {"x": x0, "y": y0, "w": max(0.0, x1 - x0), "h": max(0.0, y1 - y0)}


def _card_candidates(tree):
    """One dict per visible ApprovalCardView in the tree: its node, its text view's text and the text viewport
    (the card's NSClipView frame clipped to the text view's frame)."""
    out = []
    for node in _walk(tree or {}):
        if node.get("class") != "ApprovalCardView":
            continue
        scroll = next((n for n in _walk(node) if n.get("class") == "ApprovalInputView"), None)
        clip = next((n for n in _walk(scroll) if n.get("class") == "NSClipView"), None) if scroll else None
        tv = next((n for n in _walk(clip) if n.get("class") == "ApprovalTextView"), None) if clip else None
        area = _intersect(_frame(clip), _frame(tv)) if tv else None
        out.append({"node": node, "text": (tv or {}).get("text") or "", "area": area})
    return out


def locate_card(tree, card):
    """(info, why). info = {"node", "area"} of the visible card whose text view starts with the card's first
    rendered line, else (None, reason). Never a fallback: no match is a failure to locate."""
    cands = _card_candidates(tree)
    if not cands:
        return None, "no visible ApprovalCardView in the window's view tree"
    want = rendered_first_line(card)[:150]
    if not want:
        return None, "the card's first line is empty, so its view cannot be matched"
    hit = [c for c in cands if c["text"].startswith(want)]
    if not hit:
        return None, "%d visible card(s) in the tree, none whose text view starts with %r" % (len(cands), want[:40])
    if len(hit) > 1:
        return None, "%d visible cards in the tree show that first line" % len(hit)
    info = hit[0]
    area = info["area"]
    if area is None:
        return None, "the card has no input scroll view / text view in the tree (searched to the tree's depth)"
    if area["w"] < MIN_AREA_PT or area["h"] < MIN_AREA_PT:
        return None, "the card's text viewport is %.0f x %.0f pt (not laid out)" % (area["w"], area["h"])
    return info, ""


def card_buttons(info):
    """{title: {"x","y"}} of the ApprovalButton views inside the card, by exact title, as window-content points."""
    out = {}
    for n in _walk(info["node"]):
        if n.get("class") == "ApprovalButton" and n.get("text"):
            f = _frame(n)
            if f["w"] > 0 and f["h"] > 0:
                out.setdefault(n["text"], {"x": f["x"] + f["w"] / 2.0, "y": f["y"] + f["h"] / 2.0})
    return out


def tree_excerpt(tree, limit=60):
    """The Approval* nodes of a tree (indented, with frames); the first nodes when there are none."""
    lines = []

    def visit(node, depth, force):
        cls = node.get("class", "?")
        show = force or "Approval" in cls
        if show:
            f = _frame(node)
            txt = (node.get("text") or "")[:40].replace("\n", " ")
            lines.append("%s%s (%.0f,%.0f %.0fx%.0f)%s" % ("  " * depth, cls, f["x"], f["y"], f["w"], f["h"],
                                                           (" " + repr(txt)) if txt else ""))
        for c in node.get("children") or ():
            visit(c, depth + 1, show and "Approval" in cls)

    visit(tree or {}, 0, False)
    if not lines:
        lines.append("(no Approval* view in the tree; top of the tree:)")
        for i, n in enumerate(_walk(tree or {})):
            if i >= 15:
                break
            lines.append("  %s" % n.get("class", "?"))
    return lines[:limit]


# ---- text in view tree (secondary) ----

def text_in_tree(card, hits, card_frame):
    """(ok, message). Views `find` returned for the probe, restricted to those overlapping the card's frame."""
    probe = probe_text(card)
    if not probe:
        return True, "text in view tree: skipped (no ASCII probe: the first line starts with a token)"
    good = []
    for h in hits or []:
        f = _frame(h)
        # Overlap, not containment: a 300-line text view's frame is its whole document, taller than the card.
        if f["w"] > 0 and f["h"] > 0 and _intersect(card_frame, f)["w"] > 0 and _intersect(card_frame, f)["h"] > 0:
            good.append(h)
    n = len(card.get("lines") or [])
    if good:
        return True, "text in view tree: %d view(s) in the card match %r" % (len(good), probe)
    return False, "text not in view tree: no view in the card matches %r (model has %d lines)" % (probe, n)


# ---- pixels ----

def png_size(path):
    """(width, height) from the IHDR chunk; PngError if the file is not a readable PNG header."""
    with open(path, "rb") as f:
        head = f.read(33)
    if len(head) < 33 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise pngcontrast.PngError("not a PNG (bad signature or header)")
    width, height = struct.unpack(">II", head[16:24])
    if width <= 0 or height <= 0:
        raise pngcontrast.PngError("PNG with an empty size")
    return width, height


def _luma(rgb):
    return int(round(0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]))


def glyph_pixels(img, x0, y0, x1, y1, delta=GLYPH_DELTA):
    """(count, background luminance, pixels): pixels in the pixel rectangle whose luminance is further than
    `delta` from the rectangle's modal luminance. Only decoded pixels are read."""
    avail_w = min(img.width, len(img.rows[0]) // img.bpp) if img.rows else 0
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(avail_w, int(x1)), min(len(img.rows), int(y1))
    if x1 <= x0 or y1 <= y0:
        return 0, None, 0
    lums = [_luma(img.rgb(x, y)) for y in range(y0, y1) for x in range(x0, x1)]
    bg = Counter(lums).most_common(1)[0][0]
    return sum(1 for v in lums if abs(v - bg) > delta), bg, len(lums)


def text_drawn_in_png(png_path, content_size, area, line_count):
    """(ok, message): glyph pixels in the card's text viewport of the window screenshot.

    `content_size` = (w, h) of the window content in points (the tree root's frame), `area` = the viewport's
    frame in those points (top-left origin). Points to pixels: scale = PNG width / content width; a title bar
    above the content view shifts y by (PNG height - content height * scale), as in smoke.py. Any problem
    reading the PNG fails closed with "could not read screenshot"."""
    try:
        width, height = png_size(png_path)
        cw, ch = float(content_size[0]), float(content_size[1])
        if cw <= 0 or ch <= 0:
            raise pngcontrast.PngError("window content has no size")
        scale = width / cw
        y_off = max(0.0, height - ch * scale)
        x0, y0 = area["x"] * scale, y_off + area["y"] * scale
        x1, y1 = x0 + area["w"] * scale, y0 + area["h"] * scale
        if x1 <= 0 or y1 <= 0 or x0 >= width or y0 >= height:
            raise pngcontrast.PngError("the card's text area lies outside the screenshot")
        img = pngcontrast.decode_png(png_path, max_rows=int(y1) + 1, max_cols=int(x1) + 1)
    except (pngcontrast.PngError, zlib.error, struct.error, OSError, ValueError, IndexError, KeyError,
            TypeError, OverflowError, EOFError) as e:
        return False, "could not read screenshot: %s: %s" % (type(e).__name__, e)
    count, bg, total = glyph_pixels(img, x0, y0, x1, y1)
    if total == 0:
        return False, "could not read screenshot: the card's text area has no pixels in it"
    detail = "%d glyph pixel(s) of %d, scale %.2gx" % (count, total, scale)
    if count < MIN_GLYPH_PIXELS:
        return False, ("text not drawn: the card's text area is blank (model has %d lines; %s, need %d)"
                       % (line_count, detail, MIN_GLYPH_PIXELS))
    band_h = FIRST_LINE_BAND_PT * scale
    band, _, _ = glyph_pixels(img, x0, y0, x1, min(y1, y0 + band_h))
    if band < MIN_GLYPH_PIXELS:
        return False, ("text not drawn: the card's first line is blank (model has %d lines; first line band has "
                       "%d glyph pixel(s), need %d; text area: %s)" % (line_count, band, MIN_GLYPH_PIXELS, detail))
    return True, "text drawn: %s; first line band %d" % (detail, band)


def prove(card, tree, hits, png_path):
    """(ok, lines): the secondary find check and the pixel proof for one card."""
    if card.get("display_failed"):
        return False, ["display failed: the card reports display_failed (its text could not be laid out); "
                       "Allow once is withheld"]
    info, why = locate_card(tree, card)
    if info is None:
        return False, ["cannot locate the card text area: " + why]
    root = _frame(tree)
    n = len(card.get("lines") or [])
    ok_tree, msg_tree = text_in_tree(card, hits, _frame(info["node"]))
    ok_px, msg_px = text_drawn_in_png(png_path, (root["w"], root["h"]), info["area"], n)
    return ok_tree and ok_px, [msg_tree, msg_px]


# ---- CLI ----

def _load(path):
    with open(path) as f:
        return json.load(f)


_STDIN_COMMANDS = ("pick", "state", "label", "stale", "probe", "window", "present", "responder", "survives",
                   "composer")


def _main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "expected":
        print(expected_first_line(argv[2]))
        return 0
    if cmd == "fakelog":
        ok, msg = check_allow(argv[2], argv[3], argv[4] if len(argv) > 4 else None)
        print(msg)
        return 0 if ok else 1
    if cmd == "excerpt":
        print("\n".join(tree_excerpt(_load(argv[2]))))
        return 0
    if cmd in ("locate", "button", "prove"):
        rid = argv[2]
        listing_path, tree_path = (argv[3], argv[4]) if cmd != "button" else (argv[4], argv[5])
        listing = _load(listing_path)
        card = card_by_id(listing, rid)
        if card is None:
            print("cannot locate the card text area: request %s is not in the approvals list" % rid)
            return 1
        tree = _load(tree_path)
        if cmd == "prove":
            hits = _load(argv[5])
            ok, lines = prove(card, tree, hits, argv[6])
            print("\n".join(lines))
            return 0 if ok else 1
        info, why = locate_card(tree, card)
        if info is None:
            print("cannot locate the card text area: " + why)
            return 1
        if cmd == "locate":
            a = info["area"]
            print(json.dumps({"window": card_windows(card)[0], "text_area": a,
                              "center": {"x": a["x"] + a["w"] / 2.0, "y": a["y"] + a["h"] / 2.0},
                              "buttons": card_buttons(info)}))
            return 0
        b = card_buttons(info).get(argv[3])
        if b is None:
            print("no button titled %r inside the card (have: %s)" % (argv[3], ", ".join(sorted(card_buttons(info)))))
            return 1
        print("%g %g" % (b["x"], b["y"]))
        return 0
    if cmd not in _STDIN_COMMANDS:
        return 2
    data = json.load(sys.stdin)
    if cmd == "pick":
        try:
            c = pick_for_command(data, argv[2])
        except AmbiguousCard as e:
            print(e)
            return 4
        print(c["request_id"] if c else "")
        return 0 if c else 1
    if cmd == "state":
        st, label = allow_state(card_by_id(data, argv[2]))
        print(st if st in ("ready", "gated", "missing") else "waiting:%s" % label)
        return 0
    if cmd == "label":
        print(allow_state(card_by_id(data, argv[2]))[1])
        return 0
    if cmd == "stale":
        print("\n".join(stale_ids(data)))
        return 0
    if cmd == "probe":
        c = card_by_id(data, argv[2])
        print(probe_text(c) if c else "")
        return 0
    if cmd == "window":
        print(card_windows(card_by_id(data, argv[2]))[0])
        return 0
    if cmd == "present":
        return 0 if card_by_id(data, argv[2]) else 1
    if cmd == "responder":
        print((data.get("window") or {}).get("firstResponder") or "none")
        return 0
    if cmd == "composer":
        return 0 if is_composer((data.get("window") or {}).get("firstResponder")) else 1
    if cmd == "survives":
        return 0 if isinstance(data, list) and data else 1
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
