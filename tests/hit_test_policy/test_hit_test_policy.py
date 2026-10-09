"""Policy: every `hitTest` override in the macOS app must treat its point as
being in the SUPERVIEW's coordinates.

`NSView.hitTest(_:)` receives its point in the superview's coordinate system.
Two overlays (activity ticker, toast banner) instead used it as local
coordinates, which shifted their hit region by their frame origin so they
swallowed clicks meant for the sidebar's "+" (fixed in #185). The fix is the
shared `OverlayHitTest.hit(in:at:)`; this test makes the next override either
use it or visibly convert from the superview, instead of repeating the bug.

Textual check, not a proof — same discipline as the other source-scanning suites.

Run with:  python3 -m unittest discover -s tests/hit_test_policy
"""
import os, re, unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "macOS", "Nostromo")
SAFE = ("OverlayHitTest.hit", "from: superview", "from: self.superview", "superview?.convert")


def hit_test_bodies():
    for dirpath, _, files in os.walk(ROOT):
        for f in files:
            if not f.endswith(".swift"):
                continue
            path = os.path.join(dirpath, f)
            if f == "OverlayHitTest.swift":
                continue
            src = open(path, encoding="utf-8").read()
            for m in re.finditer(r"func hitTest\(_ \w+: NSPoint\) -> NSView\? \{", src):
                depth, i = 1, m.end()
                while depth and i < len(src):
                    depth += {"{": 1, "}": -1}.get(src[i], 0)
                    i += 1
                yield path, src[m.end():i]


def passes_point_straight_to_super(body):
    """An override that never interprets the point itself — it only forwards it
    to `super.hitTest(point)`, which expects the same superview coordinates —
    cannot have the #185 bug (e.g. ChatTurnView completes a pending layout, then
    defers to super)."""
    return "super.hitTest(" in body and "point" not in body.replace("super.hitTest(point)", "")


class HitTestPolicy(unittest.TestCase):
    def test_every_override_is_found(self):
        # Guards the scanner itself: the two known overlays must be seen, or the
        # regex has silently stopped matching and the policy below is vacuous.
        names = {os.path.basename(p) for p, _ in hit_test_bodies()}
        self.assertTrue({"ActivityTickerView.swift", "ToastBannerView.swift"} <= names, names)

    def test_overrides_convert_from_the_superview(self):
        for path, body in hit_test_bodies():
            with self.subTest(file=os.path.basename(path)):
                self.assertTrue(any(s in body for s in SAFE) or passes_point_straight_to_super(body),
                                f"{path}: hitTest must use OverlayHitTest.hit or convert the point "
                                "from the superview — AppKit passes superview coordinates.")

    def test_pass_through_exemption_is_narrow(self):
        self.assertTrue(passes_point_straight_to_super("\n  layout()\n  return super.hitTest(point)\n}"))
        self.assertFalse(passes_point_straight_to_super("\n  return bounds.contains(point) ? self : nil\n}"))
        self.assertFalse(passes_point_straight_to_super("\n  let p = convert(point, from: self)\n  return super.hitTest(p)\n}"))

    def test_no_override_converts_the_point_from_self(self):
        for path, body in hit_test_bodies():
            with self.subTest(file=os.path.basename(path)):
                self.assertNotRegex(body, r"convert\(\s*point\s*,\s*from:\s*self\s*\)",
                                    f"{path}: converting the hitTest point from self is the #185 bug.")


if __name__ == "__main__":
    unittest.main()
