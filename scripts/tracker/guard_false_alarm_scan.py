#!/usr/bin/env python3
"""Measure the sensitive-text guard's false-alarm rate on your own tracker/wip notes.

User-run, local only. Walks:

    ~/Code/*/.claude/wip/**/index.md
    ~/.claude/wip/**/index.md

feeds every line to the `sensitive-text-scan` binary (the same detector the
tracker uses), and prints, per class, how many lines it flagged and the rate
against all lines scanned. Those notes are real work text, so a flag is either
a false alarm to tune away or real sensitive text to scrub: look at it, then
fix the pattern or the note.

It never prints note text. The binary prints only `line_no<TAB>class`, and this
script prints only counts (and, with --list, `path:line  class`). It writes
nothing and commits nothing.

    python3 scripts/tracker/guard_false_alarm_scan.py
    python3 scripts/tracker/guard_false_alarm_scan.py --list
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from collections import Counter
from pathlib import Path

CLASSES = ("ssn", "card", "dob", "mrn", "phone", "personal_email", "secret", "oversize")
DEFAULT_SCAN_CMD = ["cargo", "run", "--quiet", "--bin", "sensitive-text-scan"]


def find_wip_files(home: Path) -> list[Path]:
    """Every wip index.md under ~/Code/*/.claude/wip and ~/.claude/wip."""
    roots = sorted(home.glob("Code/*/.claude/wip")) + [home / ".claude" / "wip"]
    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.rglob("index.md")))
    return files


def build_stream(files: list[Path]) -> tuple[bytes, list[tuple[Path, int, int]]]:
    """Concatenate the files, each ending in a newline.

    Returns the stream and, per file, (path, first_global_line, line_count) so
    a global line number can be mapped back to a file and its own line.
    """
    chunks: list[bytes] = []
    spans: list[tuple[Path, int, int]] = []
    next_line = 1
    for path in files:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if data and not data.endswith(b"\n"):
            data += b"\n"
        count = data.count(b"\n")
        if count == 0:
            continue
        chunks.append(data)
        spans.append((path, next_line, count))
        next_line += count
    return b"".join(chunks), spans


def parse_scan_output(output: str) -> list[tuple[int, str]]:
    """`line_no<TAB>class` rows into (line_no, class); malformed rows are skipped."""
    rows = []
    for raw in output.splitlines():
        parts = raw.split("\t")
        if len(parts) == 2 and parts[0].isdigit() and parts[1] in CLASSES:
            rows.append((int(parts[0]), parts[1]))
    return rows


def locate(spans: list[tuple[Path, int, int]], line_no: int) -> tuple[Path, int]:
    for path, first, count in spans:
        if first <= line_no < first + count:
            return path, line_no - first + 1
    raise ValueError(f"line {line_no} is outside the scanned stream")


def summarize(rows: list[tuple[int, str]], total_lines: int) -> dict:
    """Per-class flagged-line counts and rates, plus the any-class total.

    A line flagged twice for one class counts once for that class.
    """
    per_class: Counter[str] = Counter()
    flagged_lines = set()
    for line_no, cls in set(rows):
        per_class[cls] += 1
        flagged_lines.add(line_no)
    rate = (lambda n: n / total_lines) if total_lines else (lambda n: 0.0)
    return {
        "total_lines": total_lines,
        "flagged_lines": len(flagged_lines),
        "flagged_rate": rate(len(flagged_lines)),
        "classes": {c: (per_class[c], rate(per_class[c])) for c in CLASSES},
    }


def format_summary(files: int, summary: dict) -> str:
    out = [
        f"files scanned: {files}",
        f"lines scanned: {summary['total_lines']}",
        "",
        f"{'class':<16}{'lines':>8}{'rate':>10}",
    ]
    for cls in CLASSES:
        n, rate = summary["classes"][cls]
        out.append(f"{cls:<16}{n:>8}{rate:>10.2%}")
    out.append(
        f"{'any class':<16}{summary['flagged_lines']:>8}{summary['flagged_rate']:>10.2%}"
    )
    return "\n".join(out)


def main(argv: list[str] | None = None, home: Path | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--list", action="store_true", help="also print `path:line  class` per finding (no text)")
    parser.add_argument(
        "--scan-cmd",
        default=shlex.join(DEFAULT_SCAN_CMD),
        help="command (one quoted string) that reads lines on stdin and prints `line_no<TAB>class`; default runs the scan binary via cargo",
    )
    args = parser.parse_args(argv)

    files = find_wip_files(home or Path.home())
    stream, spans = build_stream(files)
    total_lines = sum(count for _, _, count in spans)
    if total_lines == 0:
        print("no wip index.md files found under ~/Code/*/.claude/wip or ~/.claude/wip")
        return 0

    result = subprocess.run(shlex.split(args.scan_cmd), input=stream, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        print(f"scan command failed with exit code {result.returncode}", file=sys.stderr)
        return 1

    rows = parse_scan_output(result.stdout.decode("utf-8", "replace"))
    print(format_summary(len(spans), summarize(rows, total_lines)))
    if args.list and rows:
        print()
        for line_no, cls in sorted(set(rows)):
            path, local = locate(spans, line_no)
            print(f"{path}:{local}  {cls}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
