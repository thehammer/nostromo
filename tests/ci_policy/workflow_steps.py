"""Shared reading of `uses:` steps for the workflow policy tests (stdlib only, no YAML parser).

Not a test module: `unittest discover -p 'test*.py'` does not collect it.
"""

import re

# A step starts at a `- key:` line; its block runs to the next step at the same indent or a dedent.
STEP_START = re.compile(r"^(?P<indent> *)- (?P<key>[A-Za-z-]+):")
USES = re.compile(r"^ *(?:- )?uses:[ \t]*(?P<value>\S+)(?:[ \t]+#[ \t]*(?P<comment>.*?))?[ \t]*$")
INPUT = re.compile(r"^(?P<indent> *)(?P<key>[A-Za-z0-9_-]+):[ \t]*(?P<value>.*?)[ \t]*(?:#.*)?$")


def step_blocks(text):
    """The text of every step (a `- key:` list item), comments inside a block kept."""
    blocks, current, indent = [], None, None
    for line in text.splitlines():
        m = STEP_START.match(line)
        if m and (current is None or len(m.group("indent")) <= indent):
            current, indent = [line], len(m.group("indent"))
            blocks.append(current)
        elif current is not None:
            if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) <= indent:
                current = None
            else:
                current.append(line)
    return ["\n".join(b) for b in blocks]


def with_inputs(block):
    """`{key: value}` of the simple scalars under the step's `with:` (empty if none)."""
    lines = block.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^( *)(?:- )?with:\s*$", line)
        if not m:
            continue
        base, out = len(m.group(1)), {}
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                continue
            if len(nxt) - len(nxt.lstrip()) <= base:
                break
            im = INPUT.match(nxt)
            if im and im.group("value") not in ("", "|", ">", "|-", ">-"):
                out[im.group("key")] = im.group("value").strip("'\"")
        return out
    return {}


def uses_steps(text):
    """`[{action, ref, comment, inputs, block}]` for every step that has a `uses:` line."""
    out = []
    for block in step_blocks(text):
        for line in block.splitlines():
            m = USES.match(line)
            if m:
                value = m.group("value")
                action, _, ref = value.partition("@")
                out.append({
                    "action": action,
                    "ref": ref,
                    "value": value,
                    "comment": m.group("comment"),
                    "inputs": with_inputs(block),
                    "block": block,
                })
                break
    return out
