"""Helpers over the JSON that `nostromo-app tree` returns.

A node is a dict: class, frame {x,y,w,h} (window-content points, top-left origin),
and optionally text, label, tooltip, hidden, children. Hidden views are already
omitted by the app. Standard library only.
"""

MAX_TEXT = 60   # item titles are the user's real Jira/Sentry data: never print more than this


def safe(s, n=MAX_TEXT):
    """Truncate text that may come from the user's own data before it is printed."""
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def walk(node, _depth=0):
    yield node, _depth
    for child in node.get("children", ()):
        yield from walk(child, _depth + 1)


def descendants(node):
    for n, d in walk(node):
        if d:
            yield n


def find_all(node, cls=None, text=None, label=None, pred=None):
    """Nodes (including `node`) matching every given condition. `cls` is exact or a tuple."""
    out = []
    classes = (cls,) if isinstance(cls, str) else cls
    for n, _ in walk(node):
        if classes and n.get("class") not in classes:
            continue
        if text is not None and n.get("text", "") != text:
            continue
        if label is not None and n.get("label", "") != label:
            continue
        if pred and not pred(n):
            continue
        out.append(n)
    return out


def first(node, **kw):
    hits = find_all(node, **kw)
    return hits[0] if hits else None


def text_of(node):
    return node.get("text", "") or ""


def center(node):
    f = node["frame"]
    return f["x"] + f["w"] / 2.0, f["y"] + f["h"] / 2.0


def nonzero(node):
    f = node["frame"]
    return f["w"] > 0 and f["h"] > 0


def contains(outer, inner, slop=1.0):
    a, b = outer["frame"], inner["frame"]
    return (b["x"] >= a["x"] - slop and b["y"] >= a["y"] - slop
            and b["x"] + b["w"] <= a["x"] + a["w"] + slop and b["y"] + b["h"] <= a["y"] + a["h"] + slop)


def texts(node, cls="NSTextField"):
    """Non-empty text of every `cls` view under `node`, in tree order."""
    return [text_of(n) for n, _ in walk(node) if n.get("class") == cls and text_of(n).strip()]


def by_y(nodes):
    return sorted(nodes, key=lambda n: (n["frame"]["y"], n["frame"]["x"]))
