#!/usr/bin/env python3
"""Decide the verdict of the `Swift tests (Mac app)` aggregate check.

    scripts/ci_mac_aggregate.py --swift <true|false|...> --shards-result <result> \
        [--reports DIR] [--config macOS/ci/mac-shards.json]

Fails (exit 1) unless the Mac test shards verifiably ran and passed:

* `--swift false` (the path classifier proved nothing Swift changed): success, as the
  single job did before the split.
* anything else: every shard job must have `success` (failure, cancelled and skipped
  all fail; a skipped required check counts as passing on GitHub, so it must be turned
  into a failure here), each shard must have reported at least one executed test with
  zero failures, and the total executed must reach `expected_min_executed`.

Standard library only; Python 3.9+.
"""

import argparse
import glob
import json
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_CONFIG = os.path.join(REPO_ROOT, "macOS", "ci", "mac-shards.json")
SHARD_COUNT = 3


def decide(swift, shards_result, reports, expected_min_executed):
    """(ok, [reasons]). `reports` is {shard number: report dict}."""
    if swift == "false":
        return True, ["swift=false: no Swift paths changed, nothing to aggregate"]
    problems = []
    if swift != "true":
        problems.append("path classifier output is %r, expected 'true' or 'false'" % swift)
    if shards_result != "success":
        problems.append("shard jobs result is %r, expected 'success'" % shards_result)
    for n in range(1, SHARD_COUNT + 1):
        report = reports.get(n)
        if report is None:
            problems.append("shard %d uploaded no report" % n)
            continue
        executed = report.get("executed")
        if not isinstance(executed, int) or executed < 1:
            problems.append("shard %d executed %r tests, expected at least 1" % (n, executed))
        if report.get("failures") != 0:
            problems.append("shard %d reported failures=%r" % (n, report.get("failures")))
    total = sum(
        r["executed"] for r in reports.values() if isinstance(r.get("executed"), int)
    )
    if total < expected_min_executed:
        problems.append(
            "executed %d tests across shards, below the floor of %d (a class was dropped?)"
            % (total, expected_min_executed)
        )
    # The constraint-conflict class must have run (and passed) in some shard: the per-shard
    # step only rejects skips, and a class dropped from every shard would otherwise go unseen.
    if sum(r.get("constraint_cases_passed") or 0 for r in reports.values()) < 1:
        problems.append("no shard reported a passing MotherDetailWidthConstraintTests case")
    if problems:
        return False, problems
    return True, ["all %d shards passed; %d tests executed (floor %d)" % (SHARD_COUNT, total, expected_min_executed)]


def load_reports(directory):
    reports = {}
    for path in glob.glob(os.path.join(directory, "**", "shard-*.json"), recursive=True):
        with open(path, encoding="utf-8") as f:
            report = json.load(f)
        reports[int(report["shard"])] = report
    return reports


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--swift", required=True)
    parser.add_argument("--shards-result", required=True)
    parser.add_argument("--reports", default="shard-reports")
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    args = parser.parse_args(argv)
    try:
        with open(args.config, encoding="utf-8") as f:
            floor = int(json.load(f)["expected_min_executed"])
        reports = load_reports(args.reports) if os.path.isdir(args.reports) else {}
    except (OSError, ValueError, KeyError) as err:
        print("Swift tests (Mac app): cannot read inputs: %s" % err, file=sys.stderr)
        return 1
    ok, reasons = decide(args.swift, args.shards_result, reports, floor)
    for reason in reasons:
        print(("ok: " if ok else "FAIL: ") + reason)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
