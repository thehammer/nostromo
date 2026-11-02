#!/usr/bin/env python3
"""Pure helpers for scripts/qa/background-wake.sh: the expected texts and the checks on app-control replies.

Everything printed is a fixed string or a number; no transcript text, task output or id from a reply is ever
echoed (the script must not print content it did not put there itself).

  background_wake.py marker K                      -> the marker text group K (1..4) must show
  background_wake.py absent-names                   -> the names of the texts that must never be drawn
  background_wake.py absent NAME                   -> that text (a name from `absent-names`)
  background_wake.py anchor-before < anchor.json   -> exit 0 if the transcript follows the tail
  background_wake.py anchor-after  < anchor.json   -> exit 0 if it follows the tail and bottomOffsetPt == 0
  background_wake.py chip-running  < chip.json     -> exit 0 if the chip state is `running`
  background_wake.py has-task KIND DESC < list.json -> exit 0 if a task of that kind and description is listed
  background_wake.py window-open ID < list.json    -> prints true, false or missing
  background_wake.py found < find.json             -> exit 0 if the `find` reply is a non-empty list
"""
import json
import sys

MARKERS = {
    1: '⟲ Monitor: new output "qa-ticker"',
    2: '⟲ Shell: completed "qa-sleep 60"',
    3: "⟲ 2 background events",
    4: "⟲ 3 background events",
}
MARKER_AX_LABEL = "Background Monitor: new output, qa-ticker."
ROW_LABEL = "background task running"
# Raw notification text and the sentinels the fake CLI puts only inside <event>/<result>; none may be drawn.
# U+202E and U+3164 are in the shell-failed command of group 3 and must be stripped.
ABSENT_TEXTS = {
    "raw-notification": "<task-notification",
    "event-sentinel": "SECRET-OUTPUT-EVENT",
    "result-sentinel": "SECRET-OUTPUT-RESULT",
    "bidi-override": "‮",
    "hangul-filler": "ㅤ",
}
MONITOR_TASK_ID = "qa-mon1"


def anchor_following(anchor):
    return isinstance(anchor, dict) and anchor.get("following") is True


def anchor_at_bottom(anchor):
    """Following the tail with nothing below the viewport (bottomOffsetPt is exactly 0)."""
    if not anchor_following(anchor):
        return False
    bottom = anchor.get("bottomOffsetPt")
    return isinstance(bottom, (int, float)) and not isinstance(bottom, bool) and bottom == 0


def chip_running(chip):
    return isinstance(chip, dict) and chip.get("state") == "running"


def has_task(listing, kind, description):
    tasks = listing.get("tasks") if isinstance(listing, dict) else None
    return any(
        isinstance(t, dict) and t.get("kind") == kind and t.get("description") == description
        for t in tasks or []
    )


def window_open(listing, task_id):
    """True / False from `tasks list --all`, or None when the task is not listed or the field is unknown."""
    for t in (listing.get("tasks") if isinstance(listing, dict) else None) or []:
        if isinstance(t, dict) and t.get("id") == task_id:
            value = t.get("window_open")
            return value if isinstance(value, bool) else None
    return None


def found(reply):
    return isinstance(reply, list) and len(reply) > 0


def _main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "marker":
        print(MARKERS[int(argv[2])])
        return 0
    if cmd == "absent-names":
        print("\n".join(ABSENT_TEXTS))
        return 0
    if cmd == "absent":
        sys.stdout.write(ABSENT_TEXTS[argv[2]])
        return 0
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 2
    if cmd == "anchor-before":
        return 0 if anchor_following(data) else 1
    if cmd == "anchor-after":
        return 0 if anchor_at_bottom(data) else 1
    if cmd == "chip-running":
        return 0 if chip_running(data) else 1
    if cmd == "has-task":
        return 0 if has_task(data, argv[2], argv[3]) else 1
    if cmd == "window-open":
        state = window_open(data, argv[2])
        print("missing" if state is None else ("true" if state else "false"))
        return 0
    if cmd == "found":
        return 0 if found(data) else 1
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
