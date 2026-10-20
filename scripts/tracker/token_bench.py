#!/usr/bin/env python3
"""Measure the tracker's token cost with Claude's real tokenizer (user-run).

Never run by CI or by jobs: it needs ANTHROPIC_API_KEY and calls the network.

    cargo test --test tracker_token_bench -- --ignored dump
    ANTHROPIC_API_KEY=... python3 scripts/tracker/token_bench.py [dir]

`dump` writes every request and response of the benchmark session to
`target/tracker-bench/*.json`, each `{"label", "kind", "text"}`. This sends each
one to the Messages count-tokens endpoint as a user message and subtracts the
per-request framing (an empty-message baseline), then prints measured vs the
PRD 30 targets. The hermetic test asserts the same targets against
`ceil(utf8_len / 2.5)`, which over-counts.

Environment:
  ANTHROPIC_API_KEY     required
  TRACKER_BENCH_MODEL   model whose tokenizer to use (default claude-sonnet-4-5)
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

URL = "https://api.anthropic.com/v1/messages/count_tokens"
MODEL = os.environ.get("TRACKER_BENCH_MODEL", "claude-sonnet-4-5")


def count(text: str, key: str) -> int:
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": text}]}).encode()
    req = urllib.request.Request(
        URL,
        data=body,
        headers={
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["input_tokens"]


def main() -> int:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        print("ANTHROPIC_API_KEY is not set", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("target/tracker-bench")
    files = sorted(root.glob("*.json"))
    if not files:
        print(f"no dump files in {root}; run the `dump` test first", file=sys.stderr)
        return 2

    # The framing every request pays: a one-token message, minus that token.
    baseline = count(".", key) - 1
    records = []
    for path in files:
        record = json.loads(path.read_text())
        record["tokens"] = max(count(record["text"], key) - baseline, 0)
        records.append(record)

    def of(label: str, kind: str) -> int:
        return next((r["tokens"] for r in records if r["label"] == label and r["kind"] == kind), 0)

    def biggest(pattern: str, kind: str) -> int:
        return max(
            (r["tokens"] for r in records if re.fullmatch(pattern, r["label"]) and r["kind"] == kind),
            default=0,
        )

    tracker = sum(r["tokens"] for r in records if r["label"].startswith("tracker/"))
    base = sum(r["tokens"] for r in records if r["label"].startswith("baseline/"))
    rows = [
        ("status request (max)", biggest(r"tracker/status-\d+", "request"), 80),
        ("status response (max)", biggest(r"tracker/status-\d+", "response"), 50),
        ("tracker session total", tracker, int(base * 0.15)),
        ("descriptor", of("descriptor/nostromo.tracker", "request"), 1500),
    ]
    reads = sorted(
        (r for r in records if re.fullmatch(r"tracker/read-\d+", r["label"]) and r["kind"] == "response"),
        key=lambda r: r["label"],
    )
    rows += [(f"{r['label']} response", r["tokens"], None) for r in reads]

    print(f"model {MODEL}; baseline (full-board set_pane_content calls): {base} tokens")
    print(f"{'measure':32} {'measured':>9} {'target':>9}")
    failed = False
    for name, measured, target in rows:
        shown = "" if target is None else str(target)
        mark = ""
        if target is not None and measured > target:
            mark, failed = "  OVER", True
        print(f"{name:32} {measured:9d} {shown:>9}{mark}")
    if base:
        print(f"tracker session is {100 * tracker / base:.1f}% of the baseline (target <= 15%)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
