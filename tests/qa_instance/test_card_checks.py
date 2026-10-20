"""Unit tests for scripts/qa/lib/card_checks.py (fake `approvals list` / `find` JSON)."""
import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "qa", "lib"))
import card_checks as cc  # noqa: E402


def card(rid, inp, enabled=True, label="Allow once", lines=1):
    return {"request_id": rid, "input": inp, "lines": [{"number": i + 1, "text": "x"} for i in range(lines)],
            "options": [{"id": "allow_once", "enabled": enabled, "label": label}, {"id": "deny", "enabled": True, "label": "Deny"}]}


OLD = card("old", "rm -rf /tmp/x/a")
NEW = card("new", "cat > /tmp/notes.txt <<'EOF'\nline2", enabled=False, label=cc.GATED_LABEL, lines=300)
HIT = {"class": "NSTextView", "frame": {"x": 1, "y": 2, "w": 100, "h": 20}}


class PickTests(unittest.TestCase):
    def test_qsr1_old_pending_card_is_not_inherited(self):
        listing = {"approvals": [OLD, NEW]}
        self.assertEqual(cc.pick_card(listing, "cat > /tmp/notes.txt <<'EOF'")["request_id"], "new")
        self.assertEqual(cc.pick_card(listing, "rm -rf /tmp/x/a")["request_id"], "old")

    def test_no_match_is_none_even_with_a_card_present(self):
        self.assertIsNone(cc.pick_card({"approvals": [OLD]}, "cat > /tmp/notes.txt"))

    def test_checks_follow_the_request_id_not_position(self):
        listing = {"approvals": [OLD, NEW]}
        self.assertEqual(cc.allow_state(cc.card_by_id(listing, "new"))[0], "gated")
        self.assertEqual(cc.allow_state(cc.card_by_id(listing, "old"))[0], "ready")


class AllowStateTests(unittest.TestCase):
    def test_qsr2_disabled_non_gated_label_is_waiting_with_label(self):
        self.assertEqual(cc.allow_state(card("a", "x", enabled=False, label="Allow once")), ("waiting", "Allow once"))

    def test_enabled_is_ready_and_gated_label_is_gated(self):
        self.assertEqual(cc.allow_state(card("a", "x"))[0], "ready")
        self.assertEqual(cc.allow_state(NEW)[0], "gated")

    def test_missing(self):
        self.assertEqual(cc.allow_state(None)[0], "missing")


class StaleTests(unittest.TestCase):
    def test_qsr4_all_pending_ids_are_returned(self):
        self.assertEqual(cc.stale_ids({"approvals": [OLD, NEW]}), ["old", "new"])
        self.assertEqual(cc.stale_ids({"approvals": []}), [])


class DrawnTests(unittest.TestCase):
    def test_qsr3_drawn(self):
        self.assertTrue(cc.text_drawn(OLD, [HIT])[0])

    def test_qsr3_not_drawn_when_no_hits(self):
        ok, msg = cc.text_drawn(NEW, [])
        self.assertFalse(ok)
        self.assertEqual(msg, "text not drawn (model has 300 lines)")

    def test_not_drawn_for_empty_hidden_or_transparent_hits(self):
        for bad in ({"frame": {"w": 0, "h": 5}}, dict(HIT, hidden=True), dict(HIT, alpha=0)):
            with self.subTest(bad=bad):
                self.assertFalse(cc.text_drawn(OLD, [bad])[0])

    def test_hit_outside_known_card_frame_is_not_drawn(self):
        framed = dict(OLD, frame={"x": 0, "y": 100, "w": 200, "h": 50})
        self.assertFalse(cc.text_drawn(framed, [HIT])[0])  # e.g. the transcript row showing the same text
        self.assertTrue(cc.text_drawn(framed, [dict(HIT, frame={"x": 5, "y": 110, "w": 50, "h": 10})])[0])

    def test_documented_limit_unscoped_hit_passes_without_card_frame(self):
        # Without a card frame (approvals list has none) any visible hit counts; the screenshot is the cross-check.
        self.assertTrue(cc.text_drawn(OLD, [dict(HIT, frame={"x": 900, "y": 900, "w": 5, "h": 5})])[0])

    def test_probe_is_first_12_chars_of_first_line(self):
        self.assertEqual(cc.probe_text(NEW), "cat > /tmp/n")


if __name__ == "__main__":
    unittest.main()
