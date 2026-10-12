"""Decode an 8/16-bit PNG with zlib only and measure text contrast in rectangles.

Why: the Light-mode bug left tab labels almost invisible on the dark surface while every
assertion on view text and frames still passed. This reads the pixels the user sees.

Only the top-left part of the image is unfiltered (rows up to the lowest rectangle, columns
up to the right-most one): the strips we measure are near the top, and a full 5K screenshot
unfiltered in pure Python would take far too long.
"""
import struct
import zlib
from collections import Counter

FAIL_BELOW = 3.0
WARN_BELOW = 4.5


class PngError(Exception):
    pass


class Image:
    def __init__(self, width, height, channels, bpp, step, rows):
        self.width, self.height = width, height
        self.channels, self.bpp, self.step = channels, bpp, step
        self.rows = rows   # rows[y][x*bpp + c*step]: only the decoded top-left part

    def rgb(self, x, y):
        row = self.rows[y]
        i = x * self.bpp
        if self.channels in (1, 2):
            g = row[i]
            return g, g, g
        return row[i], row[i + self.step], row[i + 2 * self.step]


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def decode_png(path, max_rows=None, max_cols=None):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise PngError("not a PNG")
    pos, idat, header = 8, [], None
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if not header or not idat:
        raise PngError("truncated PNG")
    width, height, depth, ctype, _comp, _filt, interlace = header
    if interlace:
        raise PngError("interlaced PNG is not supported")
    if depth not in (8, 16) or ctype not in (0, 2, 4, 6):
        raise PngError(f"unsupported PNG format (depth {depth}, colour type {ctype})")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    step = depth // 8
    bpp = channels * step
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat))
    if len(raw) < (stride + 1) * height:
        raise PngError("truncated PNG data")
    rows_needed = height if max_rows is None else min(height, max_rows)
    cols_bytes = stride if max_cols is None else min(stride, max_cols * bpp)
    rows, prev = [], bytearray(cols_bytes)
    for y in range(rows_needed):
        off = y * (stride + 1)
        ft = raw[off]
        line = raw[off + 1:off + 1 + cols_bytes]
        cur = bytearray(line)
        if ft == 1:
            for i in range(bpp, cols_bytes):
                cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif ft == 2:
            for i in range(cols_bytes):
                cur[i] = (cur[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(cols_bytes):
                left = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(cols_bytes):
                left = cur[i - bpp] if i >= bpp else 0
                ul = prev[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + _paeth(left, prev[i], ul)) & 255
        elif ft != 0:
            raise PngError(f"bad PNG filter {ft}")
        rows.append(cur)
        prev = cur
    return Image(width, height, channels, bpp, step, rows)


def _lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)


def contrast_ratio(rgb1, rgb2):
    a, b = luminance(rgb1), luminance(rgb2)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def region_contrast(img, x0, y0, x1, y1, inset=2, specks=4):
    """Contrast of a control's label against its own surface, from its pixels.

    Surface = the most common colour in the rectangle (a button's fill, or the strip
    behind a plain label). Label = the `specks`-th most contrasting pixel: ignores a lone
    bezel highlight but still sees a label, which is many pixels. Returns
    (ratio, surface_rgb, label_rgb) or None when the rectangle has no pixels in the image.
    """
    avail_w = min(img.width, len(img.rows[0]) // img.bpp) if img.rows else 0
    avail_h = len(img.rows)
    x0, y0 = max(0, int(x0) + inset), max(0, int(y0) + inset)
    x1, y1 = min(avail_w, int(x1) - inset), min(avail_h, int(y1) - inset)
    if x1 <= x0 or y1 <= y0:
        return None
    pixels = [img.rgb(x, y) for y in range(y0, y1) for x in range(x0, x1)]
    bg = Counter(pixels).most_common(1)[0][0]
    scored = sorted(((contrast_ratio(bg, p), p) for p in set(pixels)), reverse=True)
    counts = Counter(pixels)
    seen, label = 0, scored[-1]
    for ratio, p in scored:
        seen += counts[p]
        if seen >= specks:
            label = (ratio, p)
            break
    return label[0], bg, label[1]


def classify(ratio):
    if ratio < FAIL_BELOW:
        return "FAIL"
    if ratio < WARN_BELOW:
        return "WARN"
    return "PASS"


def filled_fraction(img, x0, y0, x1, y1, bg, min_ratio=1.15):
    """Share of the rectangle's pixels that differ visibly from `bg`: a selected
    (pressed) tab is a filled pill, an unselected one is just its label."""
    pixels = [img.rgb(x, y)
              for y in range(max(0, int(y0)), min(len(img.rows), int(y1)))
              for x in range(max(0, int(x0)), min(img.width, len(img.rows[0]) // img.bpp, int(x1)))]
    if not pixels:
        return 0.0
    return sum(1 for p in pixels if contrast_ratio(bg, p) >= min_ratio) / len(pixels)


def surface_colour(img, x0, y0, x1, y1):
    """The most common colour in a rectangle (the surface behind a strip of controls)."""
    pixels = [img.rgb(x, y)
              for y in range(max(0, int(y0)), min(len(img.rows), int(y1)))
              for x in range(max(0, int(x0)), min(img.width, len(img.rows[0]) // img.bpp, int(x1)))]
    return Counter(pixels).most_common(1)[0][0] if pixels else (0, 0, 0)
