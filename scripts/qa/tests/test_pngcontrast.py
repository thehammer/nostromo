"""Unit tests for scripts/qa/lib/pngcontrast.py (stdlib PNG decoding + WCAG contrast).

PNGs are generated here with an independent encoder (all five PNG filter types), so a decoder bug
cannot hide behind a matching encoder bug in the code under test.
"""
import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import pngcontrast as P   # noqa: E402

CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def _filter_row(ftype, cur, prev, bpp):
    out = bytearray()
    for i, x in enumerate(cur):
        left = cur[i - bpp] if i >= bpp else 0
        up = prev[i]
        ul = prev[i - bpp] if i >= bpp else 0
        pred = (0, left, up, (left + up) // 2, _paeth(left, up, ul))[ftype]
        out.append((x - pred) & 255)
    return bytes(out)


def encode_png(rows, ctype, depth=8, filters=(0,), interlace=0):
    """rows: list of bytes (raw scanlines, no filter byte). filters cycles per row."""
    width_bytes = len(rows[0])
    bpp = CHANNELS[ctype] * depth // 8
    width = width_bytes // bpp
    raw = bytearray()
    prev = bytes(width_bytes)
    for y, row in enumerate(rows):
        ft = filters[y % len(filters)]
        raw.append(ft)
        raw += _filter_row(ft, row, prev, bpp)
        prev = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, len(rows), depth, ctype, 0, 0, interlace))
            + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


def pattern_rows(w, h, channels, depth=8):
    """Deterministic, non-trivial pixel data (every filter type has something to predict)."""
    step = depth // 8
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            for c in range(channels):
                v = (x * 37 + y * 91 + c * 53 + (x * y) % 7 * 11) % 256
                row += bytes([v]) if step == 1 else bytes([v, (v * 3) % 256])
        rows.append(bytes(row))
    return rows


class PngCase(unittest.TestCase):
    def write(self, data, name="t.png"):
        d = tempfile.mkdtemp(prefix="qa-png-")
        self.addCleanup(__import__("shutil").rmtree, d, True)
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def png(self, rows, ctype, **kw):
        return self.write(encode_png(rows, ctype, **kw))


def expected_rgb(rows, ctype, x, y, depth=8):
    ch, step = CHANNELS[ctype], depth // 8
    row = rows[y]
    px = [row[(x * ch + c) * step] for c in range(ch)]   # high byte of each sample
    return (px[0], px[0], px[0]) if ctype in (0, 4) else (px[0], px[1], px[2])


class TestDecoding(PngCase):
    def assertPixels(self, img, rows, ctype, depth=8, w=None, h=None):
        for y in range(h if h is not None else len(rows)):
            for x in range(w if w is not None else img.width):
                self.assertEqual(img.rgb(x, y), expected_rgb(rows, ctype, x, y, depth), f"pixel ({x},{y})")

    def test_decodes_8_bit_rgb_greyscale_rgba_and_grey_alpha(self):
        for ctype in (2, 0, 6, 4):
            with self.subTest(colour_type=ctype):
                rows = pattern_rows(9, 6, CHANNELS[ctype])
                img = P.decode_png(self.png(rows, ctype))
                self.assertEqual((img.width, img.height), (9, 6))
                self.assertPixels(img, rows, ctype)

    def test_decodes_every_png_filter_type(self):
        names = {0: "None", 1: "Sub", 2: "Up", 3: "Average", 4: "Paeth"}
        for ctype in (2, 6, 0):
            for ft in range(5):
                with self.subTest(filter=names[ft], colour_type=ctype):
                    rows = pattern_rows(11, 8, CHANNELS[ctype])
                    img = P.decode_png(self.png(rows, ctype, filters=(ft,)))
                    self.assertPixels(img, rows, ctype)

    def test_decodes_images_that_mix_filter_types_row_by_row(self):
        rows = pattern_rows(13, 10, 3)
        img = P.decode_png(self.png(rows, 2, filters=(1, 4, 2, 3, 0, 4)))
        self.assertPixels(img, rows, 2)

    def test_decodes_16_bit_images_using_the_high_byte_of_each_sample(self):
        rows = pattern_rows(6, 5, 3, depth=16)
        img = P.decode_png(self.png(rows, 2, depth=16, filters=(4, 1, 3)))
        self.assertPixels(img, rows, 2, depth=16)

    def test_a_large_flat_image_decodes_correctly(self):
        rows = [bytes([30, 30, 30]) * 400 for _ in range(60)]
        img = P.decode_png(self.png(rows, 2, filters=(2,)))
        self.assertEqual((img.width, img.height), (400, 60))
        self.assertEqual(img.rgb(399, 59), (30, 30, 30))


class TestPartialDecode(PngCase):
    def test_max_rows_and_max_cols_decode_only_the_top_left_part(self):
        rows = pattern_rows(20, 30, 3)
        path = self.png(rows, 2, filters=(1, 2, 3, 4))
        img = P.decode_png(path, max_rows=7, max_cols=9)
        self.assertEqual((img.width, img.height), (20, 30), "the reported size is the whole image's")
        self.assertEqual(len(img.rows), 7)
        self.assertTrue(all(len(r) == 9 * 3 for r in img.rows))

    def test_the_partial_region_is_pixel_identical_to_the_full_decode_for_every_filter(self):
        for ft in range(5):
            with self.subTest(filter=ft):
                rows = pattern_rows(24, 16, 4)
                path = self.png(rows, 6, filters=(ft,))
                full = P.decode_png(path)
                part = P.decode_png(path, max_rows=6, max_cols=10)
                for y in range(6):
                    for x in range(10):
                        self.assertEqual(part.rgb(x, y), full.rgb(x, y), (x, y))

    def test_limits_larger_than_the_image_are_clamped(self):
        rows = pattern_rows(5, 4, 3)
        img = P.decode_png(self.png(rows, 2), max_rows=100, max_cols=100)
        self.assertEqual(len(img.rows), 4)
        self.assertEqual(img.rgb(4, 3), expected_rgb(rows, 2, 4, 3))


class TestBadInput(PngCase):
    def test_a_file_that_is_not_a_png_is_rejected(self):
        with self.assertRaises(P.PngError):
            P.decode_png(self.write(b"GIF89a not a png"))

    def test_interlaced_png_is_rejected_clearly(self):
        with self.assertRaises(P.PngError):
            P.decode_png(self.png(pattern_rows(4, 4, 3), 2, interlace=1))

    def test_palette_png_is_rejected_clearly(self):
        data = encode_png([bytes(4)] * 4, 0)
        header_idx = data.index(b"IHDR") + 4
        ihdr = bytearray(data[header_idx:header_idx + 13])
        ihdr[9] = 3   # colour type 3 (palette)
        body = bytes(ihdr)
        patched = data[:header_idx] + body + struct.pack(">I", zlib.crc32(b"IHDR" + body) & 0xFFFFFFFF) + data[header_idx + 17:]
        with self.assertRaises(P.PngError):
            P.decode_png(self.write(patched))

    def test_a_truncated_png_is_rejected(self):
        data = encode_png(pattern_rows(8, 8, 3), 2)
        cut = data[:data.index(b"IDAT") - 4]   # header only, no pixel data
        with self.assertRaises(P.PngError):
            P.decode_png(self.write(cut))


class TestContrastMaths(unittest.TestCase):
    def test_white_on_black_is_21_to_1_in_either_order(self):
        self.assertAlmostEqual(P.contrast_ratio((255, 255, 255), (0, 0, 0)), 21.0, places=6)
        self.assertAlmostEqual(P.contrast_ratio((0, 0, 0), (255, 255, 255)), 21.0, places=6)

    def test_identical_colours_are_1_to_1(self):
        self.assertAlmostEqual(P.contrast_ratio((30, 30, 30), (30, 30, 30)), 1.0, places=9)

    def test_luminance_endpoints(self):
        self.assertAlmostEqual(P.luminance((0, 0, 0)), 0.0, places=9)
        self.assertAlmostEqual(P.luminance((255, 255, 255)), 1.0, places=6)

    def test_luminance_weights_green_most_and_blue_least(self):
        self.assertAlmostEqual(P.luminance((255, 0, 0)), 0.2126, places=4)
        self.assertAlmostEqual(P.luminance((0, 255, 0)), 0.7152, places=4)
        self.assertAlmostEqual(P.luminance((0, 0, 255)), 0.0722, places=4)

    def test_known_wcag_reference_values(self):
        # #767676 is the lightest grey that reaches 4.5:1 on white; #777777 just misses.
        self.assertAlmostEqual(P.contrast_ratio((0x76, 0x76, 0x76), (255, 255, 255)), 4.54, delta=0.01)
        self.assertAlmostEqual(P.contrast_ratio((0x77, 0x77, 0x77), (255, 255, 255)), 4.48, delta=0.01)

    def test_the_light_mode_bug_colours_are_far_below_the_failure_threshold(self):
        ratio = P.contrast_ratio((0x2d, 0x2d, 0x2d), (0x1e, 0x1e, 0x1e))
        self.assertLess(ratio, 1.5)
        self.assertEqual(P.classify(ratio), "FAIL")


class TestClassify(unittest.TestCase):
    def test_thresholds(self):
        cases = [(1.0, "FAIL"), (2.99, "FAIL"), (3.0, "WARN"), (3.5, "WARN"), (4.49, "WARN"),
                 (4.5, "PASS"), (7.0, "PASS"), (21.0, "PASS")]
        for ratio, verdict in cases:
            with self.subTest(ratio=ratio):
                self.assertEqual(P.classify(ratio), verdict)


def solid(w, h, bg):
    return [bytes(bg) * w for _ in range(h)]


def paint(rows, x0, y0, x1, y1, rgb):
    for y in range(y0, y1):
        r = bytearray(rows[y])
        r[x0 * 3:x1 * 3] = bytes(rgb) * (x1 - x0)
        rows[y] = bytes(r)


class TestRegionContrast(PngCase):
    BG = (0x1e, 0x1e, 0x1e)

    def image(self, label, *, extra=None):
        rows = solid(100, 40, self.BG)
        paint(rows, 30, 12, 70, 28, label)        # a label-sized block inside the 10..90 x 5..35 rect
        for args in extra or ():
            paint(rows, *args)
        return P.decode_png(self.png(rows, 2, filters=(0, 1, 2, 3, 4)))

    def test_dark_on_dark_labels_measure_as_a_failure(self):
        img = self.image((0x2d, 0x2d, 0x2d))
        ratio, bg, fg = P.region_contrast(img, 10, 5, 90, 35)
        self.assertEqual(bg, self.BG)
        self.assertEqual(fg, (0x2d, 0x2d, 0x2d))
        self.assertLess(ratio, 1.5)
        self.assertEqual(P.classify(ratio), "FAIL")

    def test_light_labels_on_the_dark_surface_measure_as_a_pass(self):
        img = self.image((0xe6, 0xe6, 0xe6))
        ratio, bg, fg = P.region_contrast(img, 10, 5, 90, 35)
        self.assertEqual((bg, fg), (self.BG, (0xe6, 0xe6, 0xe6)))
        self.assertGreater(ratio, 10)
        self.assertEqual(P.classify(ratio), "PASS")

    def test_a_lone_bright_pixel_is_not_mistaken_for_a_label(self):
        # a one-pixel bezel highlight on an otherwise dark-on-dark label must still be a FAIL
        img = self.image((0x2d, 0x2d, 0x2d), extra=[(50, 8, 51, 9, (255, 255, 255))])
        ratio, _bg, _fg = P.region_contrast(img, 10, 5, 90, 35)
        self.assertEqual(P.classify(ratio), "FAIL")

    def test_a_plain_surface_with_no_label_is_1_to_1(self):
        img = P.decode_png(self.png(solid(60, 30, self.BG), 2))
        ratio, bg, fg = P.region_contrast(img, 5, 5, 55, 25)
        self.assertAlmostEqual(ratio, 1.0, places=6)
        self.assertEqual(bg, fg)

    def test_the_surface_is_the_most_common_colour_even_when_the_control_has_a_fill(self):
        rows = solid(100, 40, self.BG)
        paint(rows, 10, 5, 90, 35, (0x33, 0x33, 0x33))    # a filled (selected) control
        paint(rows, 40, 15, 60, 25, (0xe6, 0xe6, 0xe6))   # its label
        img = P.decode_png(self.png(rows, 2))
        ratio, bg, fg = P.region_contrast(img, 10, 5, 90, 35)
        self.assertEqual((bg, fg), ((0x33, 0x33, 0x33), (0xe6, 0xe6, 0xe6)))
        self.assertGreater(ratio, 8)

    def test_a_rectangle_outside_the_image_has_no_pixels(self):
        img = self.image((0xe6, 0xe6, 0xe6))
        self.assertIsNone(P.region_contrast(img, 500, 500, 600, 600))
        self.assertIsNone(P.region_contrast(img, 10, 5, 12, 7), "a rectangle thinner than its inset has no pixels")

    def test_a_rectangle_hanging_off_the_decoded_part_is_clipped_not_an_error(self):
        rows = solid(100, 40, self.BG)
        paint(rows, 30, 12, 70, 28, (0xe6, 0xe6, 0xe6))
        img = P.decode_png(self.png(rows, 2), max_rows=30, max_cols=80)
        res = P.region_contrast(img, 10, 5, 200, 100)
        self.assertIsNotNone(res)
        self.assertGreater(res[0], 10)


class TestFilledFractionAndSurface(PngCase):
    def test_a_filled_pill_is_detected_and_a_bare_label_is_not(self):
        bg = (0x1e, 0x1e, 0x1e)
        rows = solid(200, 40, bg)
        paint(rows, 10, 5, 90, 35, (0x4a, 0x4a, 0x4a))          # selected tab: filled pill
        paint(rows, 40, 15, 60, 25, (0xe6, 0xe6, 0xe6))         # its label
        paint(rows, 140, 15, 160, 25, (0xe6, 0xe6, 0xe6))       # another tab: label only
        img = P.decode_png(self.png(rows, 2))
        pill = P.filled_fraction(img, 10, 5, 90, 35, bg)
        bare = P.filled_fraction(img, 110, 5, 190, 35, bg)
        self.assertGreater(pill, 0.9)
        self.assertLess(bare, 0.2)

    def test_surface_colour_is_the_most_common_colour_in_the_strip(self):
        bg = (0x1e, 0x1e, 0x1e)
        rows = solid(100, 40, bg)
        paint(rows, 10, 10, 30, 20, (0xe6, 0xe6, 0xe6))
        img = P.decode_png(self.png(rows, 2))
        self.assertEqual(P.surface_colour(img, 0, 0, 100, 40), bg)

    def test_a_subtle_fill_below_the_visibility_threshold_does_not_count(self):
        bg = (0x1e, 0x1e, 0x1e)
        rows = solid(60, 30, bg)
        paint(rows, 5, 5, 55, 25, (0x1f, 0x1f, 0x1f))
        img = P.decode_png(self.png(rows, 2))
        self.assertEqual(P.filled_fraction(img, 5, 5, 55, 25, bg), 0.0)


if __name__ == "__main__":
    unittest.main()
