"""Behavioural tests for scripts/qa/lib/card_checks.py.

The checks behind scripts/qa/approvals-card.sh: pick the one approval card for a fixture, find its text viewport
in the window's view tree, and prove from the window screenshot that glyphs (not just line numbers, not just
model text) are drawn there.

Everything is fed through the public functions or the CLI (stdin and files). PNGs are generated here with an
independent encoder, so a decoder bug cannot hide behind a matching encoder bug.
"""
import contextlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts", "qa", "lib"))
import card_checks as cc  # noqa: E402

SCRIPT = os.path.abspath(os.path.join(HERE, "..", "..", "scripts", "qa", "lib", "card_checks.py"))
TOKEN_RLO = "⟨U+202E⟩"      # how the card renders U+202E


# ---------------------------------------------------------------- listing builders

def card(rid, inp, enabled=True, label="Allow once", lines=None, rendered=None, windows=None):
    """One entry of `approvals list`. `lines` = how many numbered lines the model has; each line's text is the
    input's line (the first one may be replaced with `rendered`, the way the card shows invisible characters)."""
    texts = inp.split("\n")
    if rendered is not None:
        texts[0] = rendered
    n = lines or len(texts)
    c = {"request_id": rid, "input": inp,
         "lines": [{"number": i + 1, "text": texts[i] if i < len(texts) else "line %d" % (i + 1)} for i in range(n)],
         "options": [{"id": "allow_once", "enabled": enabled, "label": label},
                     {"id": "deny", "enabled": True, "label": "Deny"}]}
    if windows is not None:
        c["windows"] = windows
    return c


OLD = card("old", "rm -rf /tmp/x/a")
NEW = card("new", "cat > /tmp/notes.txt <<'EOF'\nline2", enabled=False, label=cc.GATED_LABEL, lines=300)


def listing(*cards_):
    return {"approvals": list(cards_)}


# ---------------------------------------------------------------- view tree builders (points, window-content, top-left origin)

def rect(t):
    return {"x": t[0], "y": t[1], "w": t[2], "h": t[3]}


def N(cls, frame, text=None, children=None):
    n = {"class": cls, "frame": rect(frame)}
    if text is not None:
        n["text"] = text
    if children:
        n["children"] = list(children)
    return n


ROOT = (0, 0, 240, 160)               # the window content, in points
CARD_FRAME = (20, 20, 200, 140)
CLIP = (40, 40, 160, 80)              # the text viewport (excludes the line-number gutter at x < 40)
BUTTONS = (("Deny", (30, 130, 60, 20)), ("Deny & stop", (100, 130, 100, 20)),
           ("Allow once", (30, 105, 80, 20)), ("▾", (112, 105, 14, 20)))


def card_node(text, card_frame=CARD_FRAME, clip=CLIP, tv=None, buttons=BUTTONS,
              scroll=True, clip_view=True, text_view=True):
    tv_frame = tv if tv is not None else clip
    inner = [N("ApprovalTextView", tv_frame, text=text)] if text_view else []
    layer = [N("NSClipView", clip, children=inner)] if clip_view else inner
    kids = []
    if scroll:
        kids.append(N("ApprovalInputView", (card_frame[0], clip[1], card_frame[2], clip[3]), children=layer))
    kids += [N("ApprovalButton", f, text=t) for t, f in buttons]
    return N("ApprovalCardView", card_frame, children=kids)


def tree_with(*card_nodes, extra=()):
    host = N("ApprovalOverlayHost", ROOT, children=card_nodes)
    return N("NSView", ROOT, children=[*extra, host])


class TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="qa-card-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self._n = 0

    def path(self, name):
        return os.path.join(self.tmp, name)

    def write_json(self, name, obj):
        p = self.path(name)
        with open(p, "w") as f:
            json.dump(obj, f)
        return p

    def write_bytes(self, name, data):
        p = self.path(name)
        with open(p, "wb") as f:
            f.write(data)
        return p


# ---------------------------------------------------------------- PNG encoder (independent of the decoder)

CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def _filter_row(ftype, cur, prev, bpp):
    if ftype == 0:
        return bytes(cur)
    out = bytearray()
    for i, x in enumerate(cur):
        left = cur[i - bpp] if i >= bpp else 0
        up = prev[i]
        ul = prev[i - bpp] if i >= bpp else 0
        pred = (0, left, up, (left + up) // 2, _paeth(left, up, ul))[ftype]
        out.append((x - pred) & 255)
    return bytes(out)


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def ihdr(width, height, ctype=2, interlace=0):
    return chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, ctype, 0, 0, interlace))


def encode_png(rows, ctype, filters=(0,)):
    bpp = CHANNELS[ctype]
    width = len(rows[0]) // bpp
    raw = bytearray()
    prev = bytes(len(rows[0]))
    for y, row in enumerate(rows):
        ft = filters[y % len(filters)]
        raw.append(ft)
        raw += _filter_row(ft, row, prev, bpp)
        prev = row
    return (b"\x89PNG\r\n\x1a\n" + ihdr(width, len(rows), ctype)
            + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


DARK = (30, 30, 30)
LIGHT = (230, 230, 230)


def pixel(rgb, ctype):
    if ctype == 0:
        return bytes([rgb[0]])
    if ctype == 6:
        return bytes(rgb) + b"\xff"
    return bytes(rgb)


def scene(blocks, scale=1, title_px=0, bg=DARK, fg=LIGHT, ctype=2, content=(240, 160), filters=(0,)):
    """PNG bytes of a window whose content is `content` points drawn at `scale`, below a `title_px` tall title bar.
    `blocks` are (x0, y0, x1, y1) glyph rectangles in content points."""
    w, h = content[0] * scale, content[1] * scale + title_px
    rows = [bytearray(pixel(bg, ctype) * w) for _ in range(h)]
    bpp = CHANNELS[ctype]
    for (x0, y0, x1, y1) in blocks:
        px0, px1 = int(x0 * scale), int(x1 * scale)
        py0, py1 = int(y0 * scale) + title_px, int(y1 * scale) + title_px
        for y in range(py0, py1):
            rows[y][px0 * bpp:px1 * bpp] = pixel(fg, ctype) * (px1 - px0)
    return encode_png([bytes(r) for r in rows], ctype, filters=filters)


# ---- areas and blocks, in points. AREA = CLIP (what locate_card hands text_drawn_in_png).
AREA = rect(CLIP)                      # x 40..200, y 40..120; first-line band = y 40..62
LINE_BLOCK = (50, 46, 110, 56)         # 60 x 10: a first line's worth of glyphs
LOWER_BLOCK = (50, 70, 110, 80)        # inside the area, below the first-line band
GUTTER_BLOCK = (0, 40, 36, 120)        # line numbers: left of the area, same rows
ELSEWHERE_BLOCKS = [GUTTER_BLOCK, (40, 125, 200, 150), (205, 40, 239, 120), (40, 0, 200, 36)]


class PngCase(TmpCase):
    def drawn(self, data, name="shot.png", content=(240, 160), area=AREA, lines=37):
        return cc.text_drawn_in_png(self.write_bytes(name, data), content, area, lines)

    def assertDrawn(self, data, **kw):
        ok, msg = self.drawn(data, **kw)
        self.assertTrue(ok, msg)
        return msg

    def assertNotDrawn(self, data, *needles, **kw):
        ok, msg = self.drawn(data, **kw)
        self.assertIs(ok, False, msg)
        for n in needles:
            self.assertIn(n, msg)
        return msg


# ================================================================ 1. the pixel proof

class TextDrawnInPngTests(PngCase):
    def test_a_blank_text_area_is_not_drawn_and_the_message_says_so_with_the_line_count(self):
        msg = self.assertNotDrawn(scene([]), "text not drawn", "text area is blank", "37", lines=37)
        self.assertNotIn("could not read", msg)

    def test_a_text_area_with_glyph_like_pixels_is_drawn(self):
        self.assertDrawn(scene([LINE_BLOCK]))

    def test_line_numbers_in_the_gutter_with_a_blank_text_area_are_not_drawn(self):
        # The regression: model text and line numbers present, glyphs absent from the viewport.
        self.assertNotDrawn(scene([GUTTER_BLOCK]), "text not drawn", "text area is blank")

    def test_glyphs_anywhere_else_in_the_window_do_not_count(self):
        for block in ELSEWHERE_BLOCKS:
            with self.subTest(block=block):
                self.assertNotDrawn(scene([block]), "text not drawn")

    def test_rgb_rgba_and_greyscale_screenshots_all_work(self):
        for ctype in (2, 6, 0):
            with self.subTest(colour_type=ctype):
                self.assertDrawn(scene([LINE_BLOCK], ctype=ctype))
                self.assertNotDrawn(scene([], ctype=ctype), "text area is blank")
                self.assertNotDrawn(scene([GUTTER_BLOCK], ctype=ctype), "text not drawn")

    def test_every_png_filter_type_decodes_to_the_same_verdict(self):
        self.assertDrawn(scene([LINE_BLOCK], filters=(0, 1, 2, 3, 4)))
        self.assertNotDrawn(scene([GUTTER_BLOCK], filters=(4, 3, 2, 1, 0)), "text not drawn")

    def test_glyphs_must_be_in_the_first_line_band_not_only_lower_down(self):
        msg = self.assertNotDrawn(scene([LOWER_BLOCK]), "text not drawn", "first line is blank", lines=12)
        self.assertNotIn("text area is blank", msg)
        self.assertIn("12", msg)

    def test_a_first_line_and_further_lines_is_drawn(self):
        self.assertDrawn(scene([LINE_BLOCK, LOWER_BLOCK]))

    def test_a_speck_of_fewer_than_forty_glyph_pixels_is_not_text(self):
        self.assertNotDrawn(scene([(50, 46, 56, 52)]), "text not drawn", "text area is blank")      # 36 px
        self.assertNotDrawn(scene([(50, 46, 51, 47), (80, 50, 81, 51)]), "text not drawn")         # 2 px

    def test_a_light_region_with_no_dark_glyphs_is_blank_because_the_modal_colour_is_the_background(self):
        light = (240, 240, 240)
        self.assertNotDrawn(scene([], bg=light), "text not drawn", "text area is blank")

    def test_dark_glyphs_on_a_light_background_are_drawn(self):
        self.assertDrawn(scene([LINE_BLOCK], bg=(240, 240, 240), fg=(20, 20, 20)))

    def test_a_barely_different_colour_is_not_glyph_like(self):
        self.assertNotDrawn(scene([LINE_BLOCK], fg=(50, 50, 50)), "text not drawn")

    # ---- points to pixels

    def test_a_screenshot_at_twice_the_content_size_maps_the_area_with_the_scale(self):
        self.assertDrawn(scene([LINE_BLOCK], scale=2))
        self.assertNotDrawn(scene([], scale=2), "text area is blank")

    def test_at_twice_the_density_glyphs_only_in_the_gutter_still_fail(self):
        # If the area were read in points instead of pixels, it would cover the left of the PNG and see the gutter.
        for block in ELSEWHERE_BLOCKS:
            with self.subTest(block=block):
                self.assertNotDrawn(scene([block], scale=2), "text not drawn")

    def test_a_title_bar_above_the_content_shifts_the_area_down(self):
        for scale, title in ((1, 28), (2, 56)):
            with self.subTest(scale=scale):
                self.assertDrawn(scene([LINE_BLOCK], scale=scale, title_px=title))

    def test_with_a_title_bar_glyphs_at_the_unshifted_rows_do_not_count(self):
        # LINE_BLOCK drawn without the title offset lands in the title bar / above the real area.
        data = scene([], title_px=28)
        rows_unshifted = scene([LINE_BLOCK], title_px=0, content=(240, 188))      # same pixel size, no offset
        self.assertNotDrawn(rows_unshifted, "text not drawn", content=(240, 160))
        self.assertNotDrawn(data, "text area is blank", content=(240, 160))

    def test_the_proof_reads_only_the_card_area_of_a_large_screenshot(self):
        # 2x of a bigger window; the card sits low and to the right.
        content = (480, 320)
        area = {"x": 200, "y": 150, "w": 220, "h": 100}
        good = scene([(210, 160, 270, 170)], scale=2, title_px=56, content=content)
        self.assertDrawn(good, content=content, area=area)
        gutter = scene([(150, 150, 195, 250)], scale=2, title_px=56, content=content)
        self.assertNotDrawn(gutter, "text not drawn", content=content, area=area)

    # ---- fail closed

    def assertUnreadable(self, path_or_data, content=(240, 160), area=AREA):
        path = path_or_data if isinstance(path_or_data, str) else self.write_bytes("bad.png", path_or_data)
        ok, msg = cc.text_drawn_in_png(path, content, area, 5)
        self.assertIs(ok, False, msg)
        self.assertIn("could not read screenshot", msg)

    def test_a_png_cut_off_in_the_middle_of_the_pixel_data_fails_closed(self):
        data = scene([LINE_BLOCK])
        self.assertUnreadable(data[:data.index(b"IDAT") + 12])

    def test_a_png_with_only_a_header_fails_closed(self):
        data = scene([LINE_BLOCK])
        self.assertUnreadable(data[:data.index(b"IDAT") - 4])

    def test_garbage_bytes_fail_closed(self):
        self.assertUnreadable(b"this is definitely not a png file\x00\xff" * 8)
        self.assertUnreadable(b"\x89PNG\r\n\x1a\n" + b"\x00" * 40)

    def test_a_zero_byte_file_fails_closed(self):
        self.assertUnreadable(b"")

    def test_a_missing_file_fails_closed(self):
        self.assertUnreadable(os.path.join(self.tmp, "no-such.png"))

    def test_a_valid_looking_idat_that_is_not_a_zlib_stream_fails_closed(self):
        data = (b"\x89PNG\r\n\x1a\n" + ihdr(240, 160) + chunk(b"IDAT", b"\x01garbage, not zlib at all" * 4)
                + chunk(b"IEND", b""))
        self.assertUnreadable(data)

    def test_pixel_data_shorter_than_the_header_promises_fails_closed(self):
        data = (b"\x89PNG\r\n\x1a\n" + ihdr(240, 160) + chunk(b"IDAT", zlib.compress(b"\x00" * 100))
                + chunk(b"IEND", b""))
        self.assertUnreadable(data)

    def test_an_interlaced_png_fails_closed(self):
        data = (b"\x89PNG\r\n\x1a\n" + ihdr(240, 160, interlace=1) + chunk(b"IDAT", zlib.compress(b"\x00" * 100))
                + chunk(b"IEND", b""))
        self.assertUnreadable(data)

    def test_an_area_outside_the_image_fails_closed(self):
        data = scene([LINE_BLOCK])
        for area in ({"x": 1000, "y": 40, "w": 160, "h": 80}, {"x": 40, "y": 900, "w": 160, "h": 80},
                     {"x": -400, "y": 40, "w": 160, "h": 80}):
            with self.subTest(area=area):
                self.assertUnreadable(self.write_bytes("ok.png", data), area=area)

    def test_a_window_with_no_content_size_fails_closed(self):
        path = self.write_bytes("ok.png", scene([LINE_BLOCK]))
        for content in ((0, 0), (240, 0), (0, 160)):
            with self.subTest(content=content):
                self.assertUnreadable(path, content=content)

    def test_an_unreadable_screenshot_never_reports_text_drawn(self):
        for data in (b"", b"junk", scene([LINE_BLOCK])[:60]):
            ok, _msg = cc.text_drawn_in_png(self.write_bytes("x.png", data), (240, 160), AREA, 3)
            self.assertIs(ok, False)


# ================================================================ 2. locating the card in the view tree

class LocateCardTests(TmpCase):
    def test_a_card_is_found_and_its_text_viewport_is_the_clip_view_frame(self):
        c = card("a", "echo alpha\nline2")
        info, why = cc.locate_card(tree_with(card_node("echo alpha\nline2")), c)
        self.assertIsNotNone(info, why)
        self.assertEqual({k: info["area"][k] for k in "xywh"}, rect(CLIP))

    def test_a_tall_scrolled_text_view_does_not_enlarge_the_viewport(self):
        # The text view is 900 pt tall and scrolled: its frame spills far above and below the clip view.
        tree = tree_with(card_node("echo alpha\nline2", tv=(40, -200, 160, 900)))
        info, why = cc.locate_card(tree, card("a", "echo alpha\nline2"))
        self.assertIsNotNone(info, why)
        self.assertEqual({k: info["area"][k] for k in "xywh"}, rect(CLIP))

    def test_a_text_view_narrower_than_the_clip_view_shrinks_the_viewport(self):
        tree = tree_with(card_node("echo alpha", tv=(40, 40, 100, 80)))
        info, why = cc.locate_card(tree, card("a", "echo alpha"))
        self.assertIsNotNone(info, why)
        self.assertEqual({k: info["area"][k] for k in "xywh"}, rect((40, 40, 100, 80)))

    def test_the_gutter_is_not_part_of_the_viewport(self):
        info, _ = cc.locate_card(tree_with(card_node("echo alpha")), card("a", "echo alpha"))
        self.assertGreaterEqual(info["area"]["x"], CLIP[0])

    def test_two_cards_are_told_apart_by_the_start_of_their_text_view(self):
        a_clip, b_clip = (40, 30, 160, 40), (40, 100, 160, 40)
        tree = tree_with(
            card_node("echo alpha\nmore", card_frame=(20, 20, 200, 60), clip=a_clip, buttons=()),
            card_node("echo beta\nmore", card_frame=(20, 90, 200, 60), clip=b_clip, buttons=()))
        a, why_a = cc.locate_card(tree, card("a", "echo alpha\nmore"))
        b, why_b = cc.locate_card(tree, card("b", "echo beta\nmore"))
        self.assertIsNotNone(a, why_a)
        self.assertIsNotNone(b, why_b)
        self.assertEqual({k: a["area"][k] for k in "xywh"}, rect(a_clip))
        self.assertEqual({k: b["area"][k] for k in "xywh"}, rect(b_clip))

    def test_a_transcript_view_with_the_same_text_outside_any_card_is_not_the_card(self):
        transcript = N("NSTextView", (0, 0, 240, 15), text="echo alpha")
        info, why = cc.locate_card(tree_with(card_node("echo alpha"), extra=[transcript]), card("a", "echo alpha"))
        self.assertIsNotNone(info, why)
        self.assertEqual({k: info["area"][k] for k in "xywh"}, rect(CLIP))

    def test_a_long_first_line_is_found_although_the_tree_truncates_its_text(self):
        long_line = "echo " + "a" * 300
        tree_text = long_line[:160] + "…"
        info, why = cc.locate_card(tree_with(card_node(tree_text)), card("a", long_line))
        self.assertIsNotNone(info, why)

    def test_the_card_is_matched_by_its_rendered_first_line_not_the_raw_input(self):
        raw = "echo ‮txt.exe ok"
        rendered = "echo " + TOKEN_RLO + "txt.exe ok"
        c = card("a", raw, rendered=rendered)
        info, why = cc.locate_card(tree_with(card_node(rendered)), c)
        self.assertIsNotNone(info, why)

    def test_no_card_view_in_the_tree_is_a_failure_with_a_reason(self):
        for tree in (N("NSView", ROOT), tree_with(), {}, None):
            with self.subTest(tree=tree):
                info, why = cc.locate_card(tree, card("a", "echo alpha"))
                self.assertIsNone(info)
                self.assertTrue(why)

    def test_a_card_view_without_a_text_view_cannot_be_located(self):
        for kw in ({"text_view": False}, {"clip_view": False, "text_view": False}, {"scroll": False}):
            with self.subTest(kw=kw):
                info, why = cc.locate_card(tree_with(card_node("echo alpha", **kw)), card("a", "echo alpha"))
                self.assertIsNone(info)
                self.assertTrue(why)

    def test_a_zero_size_or_unlaid_out_viewport_cannot_be_located(self):
        for clip in ((40, 40, 0, 80), (40, 40, 160, 0), (40, 40, 0, 0), (40, 40, 2, 80), (40, 40, 160, 2)):
            with self.subTest(clip=clip):
                info, why = cc.locate_card(tree_with(card_node("echo alpha", clip=clip)), card("a", "echo alpha"))
                self.assertIsNone(info)
                self.assertTrue(why)

    def test_a_text_view_outside_its_clip_view_has_an_empty_viewport_and_cannot_be_located(self):
        tree = tree_with(card_node("echo alpha", tv=(40, 500, 160, 80)))
        info, _ = cc.locate_card(tree, card("a", "echo alpha"))
        self.assertIsNone(info)

    def test_no_card_whose_text_starts_with_the_first_line_is_a_failure_not_a_guess(self):
        info, why = cc.locate_card(tree_with(card_node("something else entirely")), card("a", "echo alpha"))
        self.assertIsNone(info)
        self.assertTrue(why)

    def test_several_cards_showing_the_same_first_line_are_a_failure_not_a_guess(self):
        tree = tree_with(card_node("echo alpha", card_frame=(20, 20, 200, 60), clip=(40, 30, 160, 40), buttons=()),
                         card_node("echo alpha", card_frame=(20, 90, 200, 60), clip=(40, 100, 160, 40), buttons=()))
        info, why = cc.locate_card(tree, card("a", "echo alpha"))
        self.assertIsNone(info)
        self.assertTrue(why)

    def test_a_card_with_an_empty_first_line_is_never_located(self):
        info, why = cc.locate_card(tree_with(card_node("")), card("a", ""))
        self.assertIsNone(info)
        self.assertTrue(why)


class CardButtonsTests(TmpCase):
    def located(self, *card_nodes, text="echo alpha"):
        info, why = cc.locate_card(tree_with(*card_nodes), card("a", text))
        self.assertIsNotNone(info, why)
        return info

    def test_each_button_is_reported_at_its_centre_by_exact_title(self):
        b = cc.card_buttons(self.located(card_node("echo alpha")))
        self.assertEqual((b["Deny"]["x"], b["Deny"]["y"]), (60, 140))
        self.assertEqual((b["Deny & stop"]["x"], b["Deny & stop"]["y"]), (150, 140))
        self.assertEqual((b["Allow once"]["x"], b["Allow once"]["y"]), (70, 115))
        self.assertEqual((b["▾"]["x"], b["▾"]["y"]), (119, 115))

    def test_deny_is_not_confused_with_deny_and_stop(self):
        b = cc.card_buttons(self.located(card_node("echo alpha")))
        self.assertNotEqual((b["Deny"]["x"], b["Deny"]["y"]), (b["Deny & stop"]["x"], b["Deny & stop"]["y"]))
        self.assertNotIn("Den", b)
        self.assertNotIn("Stop", b)

    def test_only_buttons_inside_the_located_card_are_returned(self):
        mine = card_node("echo alpha", card_frame=(20, 20, 200, 60), clip=(40, 30, 160, 40),
                         buttons=(("Deny", (30, 60, 60, 15)),))
        other = card_node("echo beta", card_frame=(20, 90, 200, 60), clip=(40, 100, 160, 40),
                          buttons=(("Deny", (30, 130, 60, 15)), ("Always allow", (100, 130, 80, 15))))
        info = self.located(mine, other)
        b = cc.card_buttons(info)
        self.assertEqual((b["Deny"]["x"], b["Deny"]["y"]), (60, 67.5))
        self.assertNotIn("Always allow", b)

    def test_a_button_that_was_not_laid_out_is_not_offered(self):
        node = card_node("echo alpha", buttons=(("Deny", (30, 130, 0, 0)), ("Allow once", (30, 105, 80, 20))))
        b = cc.card_buttons(self.located(node))
        self.assertNotIn("Deny", b)
        self.assertIn("Allow once", b)

    def test_views_that_are_not_approval_buttons_are_not_buttons(self):
        node = card_node("echo alpha", buttons=())
        node["children"].append(N("NSButton", (30, 130, 60, 20), text="Deny"))
        self.assertEqual(cc.card_buttons(self.located(node)), {})


# ================================================================ 2b. locate / button / excerpt through files

class LocateCliTests(TmpCase):
    def run_main(self, argv, stdin=""):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(out):
            code = cc._main(["card_checks.py"] + argv)
        return code, out.getvalue()

    def files(self, listing_obj, tree_obj):
        return self.write_json("listing.json", listing_obj), self.write_json("tree.json", tree_obj)

    def test_locate_prints_window_text_area_centre_and_buttons(self):
        c = card("req1", "echo alpha\nline2", windows=[2, 5])
        lp, tp = self.files(listing(c), tree_with(card_node("echo alpha\nline2", tv=(40, -200, 160, 900))))
        code, out = self.run_main(["locate", "req1", lp, tp])
        self.assertEqual(code, 0, out)
        got = json.loads(out)
        self.assertEqual(got["window"], 2)
        self.assertEqual(got["text_area"], rect(CLIP))
        self.assertEqual(got["center"], {"x": 120, "y": 80})
        self.assertEqual(got["buttons"]["Deny"], {"x": 60, "y": 140})
        self.assertEqual(got["buttons"]["Deny & stop"], {"x": 150, "y": 140})

    def test_locate_defaults_to_window_zero(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), tree_with(card_node("echo alpha")))
        code, out = self.run_main(["locate", "req1", lp, tp])
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads(out)["window"], 0)

    def test_locate_fails_with_a_reason_when_the_card_is_not_in_the_tree(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), N("NSView", ROOT))
        code, out = self.run_main(["locate", "req1", lp, tp])
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("cannot locate the card text area"), out)

    def test_locate_fails_when_the_request_is_not_listed(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), tree_with(card_node("echo alpha")))
        for cmd in (["locate", "nope", lp, tp], ["button", "nope", "Deny", lp, tp]):
            with self.subTest(cmd=cmd[0]):
                code, out = self.run_main(cmd)
                self.assertEqual(code, 1)
                self.assertTrue(out.startswith("cannot locate the card text area"), out)

    def test_button_prints_the_centre_of_the_exact_title_inside_that_card(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), tree_with(card_node("echo alpha")))
        self.assertEqual(self.run_main(["button", "req1", "Deny", lp, tp]), (0, "60 140\n"))
        self.assertEqual(self.run_main(["button", "req1", "Deny & stop", lp, tp]), (0, "150 140\n"))
        self.assertEqual(self.run_main(["button", "req1", "Allow once", lp, tp]), (0, "70 115\n"))
        self.assertEqual(self.run_main(["button", "req1", "▾", lp, tp]), (0, "119 115\n"))

    def test_button_with_an_unknown_or_partial_title_exits_one(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), tree_with(card_node("echo alpha")))
        for title in ("Nope", "Den", "deny", "Deny & stop!", ""):
            with self.subTest(title=title):
                code, _ = self.run_main(["button", "req1", title, lp, tp])
                self.assertEqual(code, 1)

    def test_button_never_returns_a_button_that_belongs_to_another_card(self):
        mine = card_node("echo alpha", card_frame=(20, 20, 200, 60), clip=(40, 30, 160, 40),
                         buttons=(("Deny", (30, 60, 60, 15)),))
        other = card_node("echo beta", card_frame=(20, 90, 200, 60), clip=(40, 100, 160, 40),
                          buttons=(("Deny", (30, 130, 60, 15)), ("Always allow", (100, 130, 80, 15))))
        lp, tp = self.files(listing(card("a", "echo alpha"), card("b", "echo beta")), tree_with(mine, other))
        self.assertEqual(self.run_main(["button", "a", "Deny", lp, tp]), (0, "60 67.5\n"))
        self.assertEqual(self.run_main(["button", "b", "Deny", lp, tp]), (0, "60 137.5\n"))
        self.assertEqual(self.run_main(["button", "a", "Always allow", lp, tp])[0], 1)
        self.assertEqual(self.run_main(["button", "b", "Always allow", lp, tp])[0], 0)

    def test_button_fails_when_the_card_cannot_be_located(self):
        lp, tp = self.files(listing(card("req1", "echo alpha")), tree_with(card_node("another first line")))
        code, out = self.run_main(["button", "req1", "Deny", lp, tp])
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("cannot locate the card text area"), out)

    def test_excerpt_shows_the_approval_views_of_a_tree(self):
        tree = tree_with(card_node("echo alpha"), extra=[N("NSBox", (0, 0, 10, 10))])
        code, out = self.run_main(["excerpt", self.write_json("t.json", tree)])
        self.assertEqual(code, 0)
        for name in ("ApprovalOverlayHost", "ApprovalCardView", "ApprovalTextView", "ApprovalButton"):
            self.assertIn(name, out)
        self.assertNotIn("NSBox", out)

    def test_excerpt_of_a_tree_without_approval_views_still_says_something(self):
        code, out = self.run_main(["excerpt", self.write_json("t.json", N("NSView", ROOT))])
        self.assertEqual(code, 0)
        self.assertTrue(out.strip())


# ================================================================ 3. prove: find check AND pixels

class ProveTests(PngCase):
    CARD = card("a", "echo alpha\nline2", lines=40)
    TREE = tree_with(card_node("echo alpha\nline2", tv=(40, -200, 160, 900)))
    GOOD_HIT = {"class": "ApprovalTextView", "frame": rect((40, 40, 160, 80)), "text": "echo alpha\nline2"}

    def png(self, blocks, **kw):
        return self.write_bytes("shot.png", scene(blocks, **kw))

    def prove(self, hits, png, card_=None, tree=None):
        return cc.prove(card_ or self.CARD, tree or self.TREE, hits, png)

    def test_text_in_the_view_tree_and_glyphs_on_screen_proves_it(self):
        ok, lines = self.prove([self.GOOD_HIT], self.png([LINE_BLOCK]))
        self.assertTrue(ok, lines)
        self.assertTrue(any("text in view tree" in l for l in lines), lines)
        self.assertTrue(any("text drawn" in l for l in lines), lines)

    def test_a_blank_text_area_fails_even_though_find_has_a_good_hit(self):
        ok, lines = self.prove([self.GOOD_HIT], self.png([GUTTER_BLOCK]))
        self.assertFalse(ok)
        self.assertTrue(any("text not drawn" in l for l in lines), lines)

    def test_glyphs_on_screen_but_no_find_hit_fails(self):
        ok, lines = self.prove([], self.png([LINE_BLOCK]))
        self.assertFalse(ok)
        self.assertTrue(any("text not in view tree" in l for l in lines), lines)

    def test_a_find_hit_outside_the_card_does_not_count(self):
        transcript = {"class": "NSTextView", "frame": rect((30, 2, 100, 12)), "text": "echo alpha"}
        ok, lines = self.prove([transcript], self.png([LINE_BLOCK]))
        self.assertFalse(ok)
        self.assertTrue(any("text not in view tree" in l for l in lines), lines)

    def test_a_tall_scrolled_text_view_hit_that_spills_out_of_the_card_still_counts(self):
        # find reports the text view's whole document frame (a 300-line input is far taller than the card).
        tall = {"class": "ApprovalTextView", "frame": rect((40, -200, 160, 900)), "text": "echo alpha\nline2"}
        ok, lines = self.prove([tall], self.png([LINE_BLOCK]))
        self.assertTrue(ok, lines)

    def test_a_find_hit_that_only_touches_the_cards_edge_does_not_count(self):
        beside = {"class": "NSTextView", "frame": rect((220, 40, 15, 80)), "text": "echo alpha"}
        above = {"class": "NSTextView", "frame": rect((40, 0, 160, 20)), "text": "echo alpha"}
        ok, lines = self.prove([beside, above], self.png([LINE_BLOCK]))
        self.assertFalse(ok)

    def test_a_find_hit_with_an_empty_frame_does_not_count(self):
        for frame in ((60, 60, 0, 0), (60, 60, 0, 10), (60, 60, 10, 0)):
            with self.subTest(frame=frame):
                ok, _ = self.prove([{"class": "ApprovalTextView", "frame": rect(frame)}], self.png([LINE_BLOCK]))
                self.assertFalse(ok)

    def test_one_good_hit_among_irrelevant_ones_is_enough(self):
        transcript = {"class": "NSTextView", "frame": rect((30, 2, 100, 12)), "text": "echo alpha"}
        ok, lines = self.prove([transcript, self.GOOD_HIT], self.png([LINE_BLOCK]))
        self.assertTrue(ok, lines)

    def test_both_failing_reports_both_reasons(self):
        ok, lines = self.prove([], self.png([]))
        self.assertFalse(ok)
        joined = "\n".join(lines)
        self.assertIn("text not in view tree", joined)
        self.assertIn("text not drawn", joined)

    def test_a_screenshot_at_twice_the_density_is_proved_with_the_same_tree(self):
        ok, lines = self.prove([self.GOOD_HIT], self.png([LINE_BLOCK], scale=2, title_px=56))
        self.assertTrue(ok, lines)
        ok, lines = self.prove([self.GOOD_HIT], self.png([GUTTER_BLOCK], scale=2, title_px=56))
        self.assertFalse(ok)

    def test_an_unreadable_screenshot_fails_with_could_not_read(self):
        bad = self.write_bytes("bad.png", b"not a png")
        ok, lines = self.prove([self.GOOD_HIT], bad)
        self.assertFalse(ok)
        self.assertTrue(any("could not read screenshot" in l for l in lines), lines)

    def test_an_unlocatable_card_never_passes_whatever_the_hits_and_pixels_say(self):
        glyphs = self.png([LINE_BLOCK])
        for tree in (N("NSView", ROOT), tree_with(card_node("some other card")), tree_with(card_node("echo alpha\nline2", text_view=False))):
            with self.subTest(tree=tree["children"][0]["class"] if tree.get("children") else "empty"):
                ok, lines = self.prove([self.GOOD_HIT], glyphs, tree=tree)
                self.assertFalse(ok)
                self.assertTrue(lines[0].startswith("cannot locate the card text area"), lines)

    def test_a_card_whose_first_line_starts_with_a_token_skips_the_tree_check_but_pixels_decide(self):
        rendered = TOKEN_RLO + "txt.exe ok"
        c = card("t", "‮txt.exe ok", rendered=rendered)
        tree = tree_with(card_node(rendered))
        self.assertEqual(cc.probe_text(c), "")
        ok, lines = cc.prove(c, tree, [], self.png([LINE_BLOCK]))
        self.assertTrue(ok, lines)
        ok, lines = cc.prove(c, tree, [], self.png([GUTTER_BLOCK]))
        self.assertFalse(ok)
        self.assertTrue(any("text not drawn" in l for l in lines), lines)
        ok, lines = cc.prove(c, tree, [self.GOOD_HIT], self.png([GUTTER_BLOCK]))
        self.assertFalse(ok)


class ProveCliTests(TmpCase):
    def setUp(self):
        super().setUp()
        self.listing = self.write_json("listing.json", listing(card("a", "echo alpha\nline2", lines=40)))
        self.tree = self.write_json("tree.json", tree_with(card_node("echo alpha\nline2")))
        self.hits = self.write_json("find.json", [{"class": "ApprovalTextView", "frame": rect((40, 40, 160, 80))}])
        self.no_hits = self.write_json("none.json", [])

    def run_cli(self, argv, stdin=""):
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        p = subprocess.run([sys.executable, SCRIPT] + argv, input=stdin, capture_output=True, text=True,
                           encoding="utf-8", env=env, cwd=self.tmp)
        return p.returncode, p.stdout

    def png(self, blocks, **kw):
        return self.write_bytes("shot.png", scene(blocks, **kw))

    def test_prove_exits_zero_and_prints_both_verdicts_when_text_is_in_the_tree_and_drawn(self):
        code, out = self.run_cli(["prove", "a", self.listing, self.tree, self.hits, self.png([LINE_BLOCK])])
        self.assertEqual(code, 0, out)
        self.assertIn("text in view tree", out)
        self.assertIn("text drawn", out)

    def test_prove_exits_one_for_a_blank_text_area_with_line_numbers_and_a_good_find_hit(self):
        code, out = self.run_cli(["prove", "a", self.listing, self.tree, self.hits, self.png([GUTTER_BLOCK])])
        self.assertEqual(code, 1)
        self.assertIn("text not drawn", out)

    def test_prove_exits_one_when_find_has_no_hit_in_the_card(self):
        code, out = self.run_cli(["prove", "a", self.listing, self.tree, self.no_hits, self.png([LINE_BLOCK])])
        self.assertEqual(code, 1)
        self.assertIn("text not in view tree", out)

    def test_prove_exits_one_when_the_card_cannot_be_located(self):
        bare = self.write_json("bare.json", N("NSView", ROOT))
        code, out = self.run_cli(["prove", "a", self.listing, bare, self.hits, self.png([LINE_BLOCK])])
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("cannot locate the card text area"), out)

    def test_prove_exits_one_when_the_request_is_not_listed(self):
        code, out = self.run_cli(["prove", "ghost", self.listing, self.tree, self.hits, self.png([LINE_BLOCK])])
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("cannot locate the card text area"), out)

    def test_prove_exits_one_for_a_garbage_screenshot(self):
        junk = self.write_bytes("junk.png", b"\x00" * 10)
        code, out = self.run_cli(["prove", "a", self.listing, self.tree, self.hits, junk])
        self.assertEqual(code, 1)
        self.assertIn("could not read screenshot", out)

    def test_locate_and_button_work_as_a_subprocess_on_files(self):
        code, out = self.run_cli(["locate", "a", self.listing, self.tree])
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads(out)["text_area"], rect(CLIP))
        self.assertEqual(self.run_cli(["button", "a", "Deny", self.listing, self.tree]), (0, "60 140\n"))
        self.assertEqual(self.run_cli(["button", "a", "Nope", self.listing, self.tree])[0], 1)


# ================================================================ 4. the find probe

class ProbeTests(unittest.TestCase):
    def test_probe_is_the_first_12_characters_of_the_first_line(self):
        self.assertEqual(cc.probe_text(NEW), "cat > /tmp/n")

    def test_a_short_first_line_is_the_whole_probe(self):
        self.assertEqual(cc.probe_text(card("a", "echo hi")), "echo hi")

    def test_the_probe_comes_from_the_rendered_first_line(self):
        self.assertEqual(cc.probe_text(card("a", "raw input differs", rendered="shown text here")), "shown text h")

    def test_a_bidi_command_is_probed_up_to_the_token_so_find_can_see_it(self):
        raw = "echo ‮txt.exe ok"
        c = card("a", raw, rendered="echo " + TOKEN_RLO + "txt.exe ok")
        self.assertEqual(cc.probe_text(c), "echo ")
        self.assertNotIn("‮", cc.probe_text(c))

    def test_the_raw_override_character_never_reaches_the_probe(self):
        for c in (card("a", "echo ‮txt.exe ok"),                                    # no rendered line at all
                  card("b", "echo ‮txt.exe ok", rendered="echo ‮txt.exe ok")):  # even if it leaked through
            with self.subTest(card=c["request_id"]):
                self.assertNotIn("‮", cc.probe_text(c))

    def test_a_first_line_that_starts_with_a_token_has_no_probe(self):
        c = card("a", "‮txt.exe ok", rendered=TOKEN_RLO + "txt.exe ok")
        self.assertEqual(cc.probe_text(c), "")

    def test_a_first_line_with_fewer_than_four_ascii_characters_has_no_probe(self):
        self.assertEqual(cc.probe_text(card("a", "ls")), "")
        self.assertEqual(cc.probe_text(card("a", "abécdef")), "")

    def test_non_ascii_text_ends_the_probe(self):
        self.assertEqual(cc.probe_text(card("a", "café au lait")), "")
        self.assertEqual(cc.probe_text(card("a", "echo café au lait")), "echo caf")


# ================================================================ 5. selecting the card for a fixture

class ExpectedFirstLineTests(unittest.TestCase):
    def test_it_is_the_first_command_line(self):
        self.assertEqual(cc.expected_first_line("cat > /tmp/notes.txt <<'EOF'\nline2\nEOF"), "cat > /tmp/notes.txt <<'EOF'")

    def test_a_trailing_newline_is_not_part_of_it(self):
        self.assertEqual(cc.expected_first_line("echo hello\n"), "echo hello")

    def test_it_stops_at_the_first_non_ascii_character(self):
        self.assertEqual(cc.expected_first_line("echo ‮txt.exe ok"), "echo ")
        self.assertEqual(cc.expected_first_line("echo café"), "echo caf")
        self.assertEqual(cc.expected_first_line("‮txt.exe"), "")

    def test_it_is_empty_for_an_empty_command(self):
        self.assertEqual(cc.expected_first_line(""), "")
        self.assertEqual(cc.expected_first_line(None), "")
        self.assertEqual(cc.expected_first_line("\n\n"), "")


class PickTests(unittest.TestCase):
    def test_qsr1_old_pending_card_is_not_inherited(self):
        lst = listing(OLD, NEW)
        self.assertEqual(cc.pick_card(lst, "cat > /tmp/notes.txt <<'EOF'")["request_id"], "new")
        self.assertEqual(cc.pick_card(lst, "rm -rf /tmp/x/a")["request_id"], "old")

    def test_no_match_is_none_even_with_a_card_present(self):
        self.assertIsNone(cc.pick_card(listing(OLD), "cat > /tmp/notes.txt"))
        self.assertIsNone(cc.pick_card(listing(), "cat > /tmp/notes.txt"))
        self.assertIsNone(cc.pick_card({}, "cat > /tmp/notes.txt"))
        self.assertIsNone(cc.pick_card(None, "cat > /tmp/notes.txt"))

    def test_the_listing_order_does_not_decide(self):
        for lst in (listing(OLD, NEW), listing(NEW, OLD)):
            self.assertEqual(cc.pick_card(lst, "cat > /tmp/notes.txt <<'EOF'")["request_id"], "new")

    def test_checks_follow_the_request_id_not_position(self):
        lst = listing(OLD, NEW)
        self.assertEqual(cc.allow_state(cc.card_by_id(lst, "new"))[0], "gated")
        self.assertEqual(cc.allow_state(cc.card_by_id(lst, "old"))[0], "ready")
        self.assertIsNone(cc.card_by_id(lst, "missing"))

    def test_an_empty_expected_line_matches_no_card_even_with_cards_present(self):
        lst = listing(OLD, NEW, card("blank", ""))
        for expected in ("", None):
            with self.subTest(expected=expected):
                self.assertIsNone(cc.pick_card(lst, expected))
                self.assertIsNone(cc.pick_card(lst, expected, full_input=""))
                self.assertIsNone(cc.pick_card(lst, expected, full_input="\n"))
        self.assertIsNone(cc.pick_for_command(lst, ""))
        self.assertIsNone(cc.pick_for_command(lst, "\n"))

    def test_a_three_character_expected_line_does_not_match_by_prefix(self):
        lst = listing(card("long", "pwd -P"))
        self.assertIsNone(cc.pick_card(lst, "pwd"))
        self.assertIsNone(cc.pick_card(lst, "pwd", full_input="pwd\n"))
        self.assertIsNone(cc.pick_for_command(lst, "pwd"))

    def test_a_short_expected_line_falls_back_to_equality_of_the_whole_input(self):
        lst = listing(card("long", "pwd -P"), card("exact", "pwd"))
        self.assertEqual(cc.pick_card(lst, "pwd", full_input="pwd")["request_id"], "exact")
        self.assertEqual(cc.pick_for_command(lst, "pwd")["request_id"], "exact")

    def test_the_whole_input_comparison_ignores_a_trailing_newline_on_either_side(self):
        self.assertEqual(cc.pick_card(listing(card("a", "pwd\n")), "pwd", full_input="pwd")["request_id"], "a")
        self.assertEqual(cc.pick_card(listing(card("a", "pwd")), "pwd", full_input="pwd\n")["request_id"], "a")
        self.assertEqual(cc.pick_card(listing(card("a", "pwd\n")), "pwd", full_input="pwd\n\n")["request_id"], "a")

    def test_a_short_first_line_of_a_multiline_command_needs_the_whole_command(self):
        lst = listing(card("one", "ls\nfoo"), card("two", "ls\nbar"))
        self.assertEqual(cc.pick_for_command(lst, "ls\nfoo")["request_id"], "one")
        self.assertEqual(cc.pick_for_command(lst, "ls\nbar\n")["request_id"], "two")
        self.assertIsNone(cc.pick_for_command(lst, "ls\nbaz"))

    def test_a_short_expected_line_with_no_full_input_matches_nothing(self):
        lst = listing(card("exact", "pwd"), card("also", "ls"))
        self.assertIsNone(cc.pick_card(lst, "pwd"))
        self.assertIsNone(cc.pick_card(lst, "pwd", full_input=None))
        self.assertIsNone(cc.pick_card(lst, "ls", full_input=""))

    def test_two_cards_with_the_same_short_input_are_ambiguous(self):
        lst = listing(card("one", "pwd"), card("two", "pwd\n"))
        with self.assertRaises(cc.AmbiguousCard) as ctx:
            cc.pick_for_command(lst, "pwd")
        self.assertIn("ambiguous card selection", str(ctx.exception))

    def test_a_shared_short_prefix_of_different_cards_is_ambiguous_not_a_positional_pick(self):
        lst = listing(card("one", "echo hello"), card("two", "echo world"))
        with self.assertRaises(cc.AmbiguousCard) as ctx:
            cc.pick_card(lst, "echo ")
        self.assertIn("ambiguous card selection", str(ctx.exception))
        with self.assertRaises(cc.AmbiguousCard):
            cc.pick_for_command(lst, "echo ‮txt.exe")

    def test_two_cards_matching_a_long_prefix_are_ambiguous_and_both_are_named(self):
        first = "cat > /tmp/notes.txt <<'EOF'"
        lst = listing(card("r1", first + "\nA"), card("r2", first + "\nB"))
        with self.assertRaises(cc.AmbiguousCard) as ctx:
            cc.pick_card(lst, first)
        msg = str(ctx.exception)
        self.assertIn("ambiguous card selection", msg)
        self.assertIn("r1", msg)
        self.assertIn("r2", msg)

    def test_a_distinct_card_is_still_picked_when_others_share_a_different_prefix(self):
        lst = listing(card("one", "echo hello"), card("two", "echo world"), card("three", "git status"))
        self.assertEqual(cc.pick_card(lst, "git status")["request_id"], "three")
        self.assertEqual(cc.pick_card(lst, "echo hello")["request_id"], "one")

    def test_a_trailing_newline_in_the_fixture_command_still_picks_the_card(self):
        lst = listing(OLD, NEW)
        self.assertEqual(cc.pick_for_command(lst, "cat > /tmp/notes.txt <<'EOF'\nline2\n")["request_id"], "new")
        self.assertEqual(cc.pick_for_command(lst, "rm -rf /tmp/x/a\n")["request_id"], "old")

    def test_a_bidi_command_is_picked_by_its_ascii_lead_in(self):
        raw = "echo ‮txt.exe ok"
        lst = listing(OLD, card("bidi", raw, rendered="echo " + TOKEN_RLO + "txt.exe ok"))
        self.assertEqual(cc.expected_first_line(raw), "echo ")
        self.assertEqual(cc.pick_for_command(lst, raw)["request_id"], "bidi")

    def test_a_command_that_starts_with_a_token_is_picked_by_the_whole_input(self):
        raw = "‮txt.exe ok"
        lst = listing(card("bidi", raw), card("other", "‮other"))
        self.assertEqual(cc.pick_for_command(lst, raw)["request_id"], "bidi")
        self.assertIsNone(cc.pick_for_command(lst, "‮unknown"))


class AllowStateTests(unittest.TestCase):
    def test_qsr2_disabled_non_gated_label_is_waiting_with_label(self):
        self.assertEqual(cc.allow_state(card("a", "x", enabled=False, label="Allow once")), ("waiting", "Allow once"))

    def test_enabled_is_ready_and_gated_label_is_gated(self):
        self.assertEqual(cc.allow_state(card("a", "x"))[0], "ready")
        self.assertEqual(cc.allow_state(NEW)[0], "gated")

    def test_only_an_enabled_true_option_is_ready(self):
        for enabled in (False, None, "true", 1, 0):
            with self.subTest(enabled=enabled):
                self.assertNotEqual(cc.allow_state(card("a", "x", enabled=enabled))[0], "ready")

    def test_a_card_without_an_allow_once_option_is_missing(self):
        self.assertEqual(cc.allow_state({"request_id": "a", "options": [{"id": "deny"}]})[0], "missing")
        self.assertEqual(cc.allow_state({"request_id": "a"})[0], "missing")

    def test_missing(self):
        self.assertEqual(cc.allow_state(None)[0], "missing")


class StaleTests(unittest.TestCase):
    def test_qsr4_all_pending_ids_are_returned(self):
        self.assertEqual(cc.stale_ids(listing(OLD, NEW)), ["old", "new"])
        self.assertEqual(cc.stale_ids(listing()), [])

    def test_entries_without_a_request_id_are_skipped(self):
        self.assertEqual(cc.stale_ids(listing({"input": "x"}, OLD)), ["old"])


# ================================================================ 6. the CLI end to end

class FakeCliLogTests(TmpCase):
    """The fake CLI runs several times (catalog probe, session), each in fake-claude/<pid>/."""

    def proc(self, pid, stdin_lines, responses, mtime=None):
        d = os.path.join(self.tmp, "home", ".nostromo", "fake-claude", pid)
        os.makedirs(d)
        with open(os.path.join(d, "stdin.jsonl"), "w") as f:
            f.write("".join(json.dumps(x) + "\n" for x in stdin_lines))
        rp = os.path.join(d, "responses.jsonl")
        with open(rp, "w") as f:
            f.write("".join(json.dumps(x) + "\n" for x in responses))
        if mtime is not None:
            os.utime(rp, (mtime, mtime))
        return d

    ALLOW = {"behavior": "allow", "updatedInput": {"command": "rm -rf /tmp/x/a", "description": "d"}}

    def session_tree(self, answer):
        self.proc("42432", [{"type": "initialize"}], [])                       # probe: empty, sorts first
        return self.proc("43012", [{"type": "initialize"}, {"text": "FIXTURE:simple_rm"}], [answer])

    def test_the_session_dir_is_chosen_over_the_empty_probe_dir(self):
        d = self.session_tree(self.ALLOW)
        got, responses = cc.fake_cli_responses(self.tmp, "simple_rm")
        self.assertEqual(got, d)
        self.assertEqual(responses, [self.ALLOW])
        ok, msg = cc.check_allow(self.tmp, "simple_rm", "rm -rf /tmp/x/a\n")
        self.assertTrue(ok, msg)

    def test_wrapped_control_responses_are_found(self):
        self.session_tree({"type": "control_response", "response": {"response": self.ALLOW}})
        self.assertTrue(cc.check_allow(self.tmp, "simple_rm", "rm -rf /tmp/x/a")[0])

    def test_a_deny_is_not_an_allow(self):
        self.session_tree({"behavior": "deny", "message": "no"})
        ok, msg = cc.check_allow(self.tmp, "simple_rm", "rm -rf /tmp/x/a")
        self.assertFalse(ok)
        self.assertIn("deny", msg)

    def test_an_allow_with_a_changed_command_fails(self):
        self.session_tree({"behavior": "allow", "updatedInput": {"command": "rm -rf /"}})
        ok, msg = cc.check_allow(self.tmp, "simple_rm", "rm -rf /tmp/x/a")
        self.assertFalse(ok)
        self.assertIn("not the card's input", msg)

    def test_no_fake_cli_dir_at_all_fails(self):
        ok, msg = cc.check_allow(self.tmp, "simple_rm", "rm -rf /tmp/x/a")
        self.assertFalse(ok)
        self.assertIn("no fake CLI", msg)

    def test_only_a_probe_dir_with_no_answers_fails(self):
        self.proc("42432", [{"type": "initialize"}], [])
        self.assertFalse(cc.check_allow(self.tmp, "simple_rm", "x")[0])

    def test_without_the_cue_the_newest_non_empty_log_is_the_fallback(self):
        self.proc("1", [], [self.ALLOW], mtime=1000)
        newer = self.proc("2", [], [self.ALLOW], mtime=2000)
        self.proc("3", [], [], mtime=3000)
        self.assertEqual(cc.fake_cli_responses(self.tmp, "simple_rm")[0], newer)

    def test_the_dir_with_the_fixtures_own_cue_wins_over_a_newer_other_dir(self):
        mine = self.proc("1", [{"t": "FIXTURE:simple_rm"}], [self.ALLOW], mtime=1000)
        self.proc("2", [{"t": "FIXTURE:heredoc_300"}], [{"behavior": "deny"}], mtime=2000)
        self.assertEqual(cc.fake_cli_responses(self.tmp, "simple_rm")[0], mine)

    def test_the_cli_exits_zero_for_an_allow_and_one_otherwise(self):
        self.session_tree(self.ALLOW)
        p = subprocess.run([sys.executable, SCRIPT, "fakelog", self.tmp, "simple_rm", "rm -rf /tmp/x/a"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        p = subprocess.run([sys.executable, SCRIPT, "fakelog", self.tmp, "simple_rm", "other"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)


class ComposerFocusTests(unittest.TestCase):
    def hit(self, resp):
        return {"window": {"firstResponder": resp}}

    def run_cli(self, payload):
        return subprocess.run([sys.executable, SCRIPT, "composer"], input=json.dumps(payload),
                              capture_output=True, text=True).returncode

    def test_only_the_chat_composer_counts(self):
        self.assertEqual(self.run_cli(self.hit("ChatTextView")), 0)
        for other in ("NostromoWindow", "ApprovalTextView", "NSTextView", None):
            with self.subTest(responder=other):
                self.assertEqual(self.run_cli(self.hit(other)), 1)
        self.assertEqual(self.run_cli({}), 1)


class Bidi(unittest.TestCase):
    def test_the_bidi_fixtures_expected_first_line_is_its_ascii_prefix(self):
        path = os.path.join(HERE, "..", "fixtures", "approvals", "bidi.json")
        with open(path) as f:
            command = json.load(f)["tool_uses"][0]["input"]["command"]
        self.assertEqual(cc.expected_first_line(command), "echo ")


class CliTests(TmpCase):
    """Each stdin command is run both in a subprocess (python3 card_checks.py ...) and by calling _main with a
    patched stdin; the two must agree."""

    def run_direct(self, argv, stdin):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(out):
            code = cc._main(["card_checks.py"] + argv)
        return code, out.getvalue()

    def run_sub(self, argv, stdin):
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        p = subprocess.run([sys.executable, SCRIPT] + argv, input=stdin, capture_output=True, text=True,
                           encoding="utf-8", env=env, cwd=self.tmp)
        return p.returncode, p.stdout

    def cli(self, argv, stdin="{}"):
        if not isinstance(stdin, str):
            stdin = json.dumps(stdin)
        direct, sub = self.run_direct(argv, stdin), self.run_sub(argv, stdin)
        self.assertEqual(direct, sub, "in-process and subprocess results differ for %s" % argv)
        return direct

    # ---- pick

    def test_pick_prints_the_request_id_and_exits_zero(self):
        lst = listing(OLD, NEW)
        self.assertEqual(self.cli(["pick", "cat > /tmp/notes.txt <<'EOF'\nline2"], lst), (0, "new\n"))
        self.assertEqual(self.cli(["pick", "rm -rf /tmp/x/a\n"], lst), (0, "old\n"))

    def test_pick_exits_one_with_empty_output_when_no_card_matches_yet(self):
        self.assertEqual(self.cli(["pick", "cat > /tmp/notes.txt"], listing(OLD)), (1, "\n"))
        self.assertEqual(self.cli(["pick", "cat > /tmp/notes.txt"], listing()), (1, "\n"))
        self.assertEqual(self.cli(["pick", ""], listing(OLD)), (1, "\n"))

    def test_pick_exits_four_and_explains_when_the_choice_is_ambiguous(self):
        code, out = self.cli(["pick", "echo "], listing(card("one", "echo hello"), card("two", "echo world")))
        self.assertEqual(code, 4)
        self.assertIn("ambiguous card selection", out)

    def test_pick_of_a_short_command_uses_the_whole_input(self):
        lst = listing(card("long", "pwd -P"), card("exact", "pwd"))
        self.assertEqual(self.cli(["pick", "pwd"], lst), (0, "exact\n"))
        self.assertEqual(self.cli(["pick", "pw"], lst), (1, "\n"))

    # ---- expected

    def test_expected_prints_the_ascii_first_line(self):
        self.assertEqual(self.cli(["expected", "cat > /tmp/notes.txt <<'EOF'\nline2\n"]), (0, "cat > /tmp/notes.txt <<'EOF'\n"))
        self.assertEqual(self.cli(["expected", "echo ‮txt.exe ok"]), (0, "echo \n"))
        self.assertEqual(self.cli(["expected", ""]), (0, "\n"))

    # ---- state / label

    def test_state_reports_ready_gated_waiting_and_missing(self):
        lst = listing(OLD, NEW, card("w", "x", enabled=False, label="Allow once"), {"request_id": "bare"})
        self.assertEqual(self.cli(["state", "old"], lst), (0, "ready\n"))
        self.assertEqual(self.cli(["state", "new"], lst), (0, "gated\n"))
        self.assertEqual(self.cli(["state", "w"], lst), (0, "waiting:Allow once\n"))
        self.assertEqual(self.cli(["state", "bare"], lst), (0, "missing\n"))
        self.assertEqual(self.cli(["state", "ghost"], lst), (0, "missing\n"))

    def test_label_prints_the_allow_once_label(self):
        lst = listing(OLD, NEW)
        self.assertEqual(self.cli(["label", "old"], lst), (0, "Allow once\n"))
        self.assertEqual(self.cli(["label", "new"], lst), (0, cc.GATED_LABEL + "\n"))
        self.assertEqual(self.cli(["label", "ghost"], lst), (0, "\n"))

    # ---- stale

    def test_stale_prints_one_request_id_per_line(self):
        self.assertEqual(self.cli(["stale"], listing(OLD, NEW)), (0, "old\nnew\n"))
        self.assertEqual(self.cli(["stale"], listing()), (0, "\n"))

    # ---- probe

    def test_probe_prints_the_find_probe_or_nothing(self):
        bidi = card("bidi", "echo ‮txt.exe ok", rendered="echo " + TOKEN_RLO + "txt.exe ok")
        token = card("tok", "‮txt", rendered=TOKEN_RLO + "txt")
        lst = listing(NEW, bidi, token)
        self.assertEqual(self.cli(["probe", "new"], lst), (0, "cat > /tmp/n\n"))
        self.assertEqual(self.cli(["probe", "bidi"], lst), (0, "echo \n"))
        self.assertEqual(self.cli(["probe", "tok"], lst), (0, "\n"))
        self.assertEqual(self.cli(["probe", "ghost"], lst), (0, "\n"))

    # ---- window / present

    def test_window_is_the_first_window_showing_the_card_default_zero(self):
        lst = listing(card("multi", "echo a1", windows=[3, 1]), card("none", "echo b2"), card("empty", "echo c3", windows=[]))
        self.assertEqual(self.cli(["window", "multi"], lst), (0, "3\n"))
        self.assertEqual(self.cli(["window", "none"], lst), (0, "0\n"))
        self.assertEqual(self.cli(["window", "empty"], lst), (0, "0\n"))
        self.assertEqual(self.cli(["window", "ghost"], lst), (0, "0\n"))

    def test_present_exits_zero_while_the_card_is_listed_and_one_when_gone(self):
        lst = listing(OLD)
        self.assertEqual(self.cli(["present", "old"], lst), (0, ""))
        self.assertEqual(self.cli(["present", "new"], lst), (1, ""))
        self.assertEqual(self.cli(["present", "old"], listing()), (1, ""))

    # ---- responder / survives

    def test_responder_prints_the_first_responder_class(self):
        hit = {"window": {"firstResponder": "ApprovalTextView"}}
        self.assertEqual(self.cli(["responder"], hit), (0, "ApprovalTextView\n"))

    def test_responder_prints_none_when_there_is_no_first_responder(self):
        for payload in ({"window": {}}, {"window": {"firstResponder": None}}, {}):
            with self.subTest(payload=payload):
                self.assertEqual(self.cli(["responder"], payload), (0, "none\n"))

    def test_survives_exits_zero_for_a_non_empty_find_result_and_one_for_an_empty_one(self):
        self.assertEqual(self.cli(["survives"], [{"class": "NSTextField"}])[0], 0)
        self.assertEqual(self.cli(["survives"], [])[0], 1)
        self.assertEqual(self.cli(["survives"], {})[0], 1)

    # ---- unknown

    def test_an_unknown_command_exits_two(self):
        self.assertEqual(self.cli(["frobnicate"], {})[0], 2)
        self.assertEqual(self.cli(["frobnicate", "x"], listing(OLD))[0], 2)


if __name__ == "__main__":
    unittest.main()
