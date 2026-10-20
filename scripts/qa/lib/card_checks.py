"""Pure checks over `nostromo-app approvals list` / `find` JSON for scripts/qa/approvals-card.sh.

Standard library only. CLI (used by the script):
  card_checks.py pick  EXPECTED_FIRST_LINE        < approvals-list.json   -> request_id of the matching card
  card_checks.py state REQUEST_ID                 < approvals-list.json   -> ready|gated|waiting:<label>|missing
  card_checks.py stale                            < approvals-list.json   -> request_ids, one per line
  card_checks.py drawn REQUEST_ID                 < {"approvals":..., "find":[...]}  -> exit 0 drawn, 1 not
Text-drawn probe: `find` (views whose text contains the first 12 chars of the card's first line). `find` omits
hidden views and does not report alpha; if a hit does carry `hidden`/`alpha` they are enforced.
LIMITATION: `approvals list` carries no card frame, so a hit cannot be scoped to the card's view. If another view
(e.g. a rendered tool-use row in the transcript) shows the same first 12 chars, a blank card still reports
"drawn". The per-card screenshot (/tmp/qa-card-<fixture>.png) is the visual cross-check. When a card dict has a
"frame" key, hits are required to lie inside it.
"""
import json
import sys

GATED_LABEL = "Scroll to the end to allow"
PROBE_CHARS = 12


def cards(listing):
    return list((listing or {}).get("approvals") or [])


def first_line(card):
    return (card.get("input") or "").split("\n", 1)[0]


def pick_card(listing, expected_first_line):
    """The card whose input begins with the fixture's first line, else None (never positional)."""
    for c in cards(listing):
        if (c.get("input") or "").startswith(expected_first_line):
            return c
    return None


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
    """('ready'|'gated'|'waiting', label). Ready only when enabled:true."""
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


def probe_text(card):
    return first_line(card)[:PROBE_CHARS]


def _visible(hit):
    f = hit.get("frame") or {}
    if not (f.get("w", 0) > 0 and f.get("h", 0) > 0):
        return False
    if hit.get("hidden") is True:
        return False
    return hit.get("alpha", 1) > 0


def _inside(outer, hit, slop=1.0):
    a, b = outer, hit.get("frame") or {}
    return (b.get("x", 0) >= a["x"] - slop and b.get("y", 0) >= a["y"] - slop
            and b.get("x", 0) + b.get("w", 0) <= a["x"] + a["w"] + slop
            and b.get("y", 0) + b.get("h", 0) <= a["y"] + a["h"] + slop)


def text_drawn(card, hits):
    """(drawn, message). A hit must have a non-empty frame, not hidden, alpha > 0 (and inside card["frame"] if known)."""
    n = len(card.get("lines") or [])
    good = [h for h in hits or [] if _visible(h)]
    if card.get("frame"):
        good = [h for h in good if _inside(card["frame"], h)]
    if good:
        return True, f"text drawn ({len(good)} view(s) match {probe_text(card)!r})"
    return False, f"text not drawn (model has {n} lines)"


def _main(argv):
    cmd = argv[1]
    data = json.load(sys.stdin)
    if cmd == "pick":
        c = pick_card(data, argv[2])
        print(c["request_id"] if c else "")
        return 0 if c else 1
    if cmd == "state":
        st, label = allow_state(card_by_id(data, argv[2]))
        print(st if st in ("ready", "gated", "missing") else f"waiting:{label}")
        return 0
    if cmd == "stale":
        print("\n".join(stale_ids(data)))
        return 0
    if cmd == "drawn":
        c = card_by_id(data["approvals"], argv[2])
        if c is None:
            print("text not drawn (card missing)")
            return 1
        ok, msg = text_drawn(c, data["find"])
        print(msg)
        return 0 if ok else 1
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
