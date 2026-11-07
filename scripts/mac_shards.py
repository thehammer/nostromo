#!/usr/bin/env python3
"""Shard the Mac test suite (`NostromoTests`) across parallel CI jobs.

    scripts/mac_shards.py args --shard N        # xcodebuild -only/-skip-testing args for shard N
    scripts/mac_shards.py validate              # config sanity: every listed class exists
    scripts/mac_shards.py report --shard N --log LOG --out shard-N.json
    scripts/mac_shards.py regenerate [--log macOS/build/mac-test-full.log | --from-source]

The assignment lives in macOS/ci/mac-shards.json. Shards that list `classes` run
exactly those (`-only-testing`); the `catch_all` shard runs everything the other
shards do not list (`-skip-testing` of their classes), so a new test class can
never be dropped: it lands in the catch-all automatically.

Standard library only; Python 3.9+.
"""

import argparse
import json
import os
import re
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_CONFIG = os.path.join(REPO_ROOT, "macOS", "ci", "mac-shards.json")
DEFAULT_TESTS_DIR = os.path.join(REPO_ROOT, "macOS", "NostromoTests")
TEST_TARGET = "NostromoTests"
SHARD_COUNT = 3

_CLASS_DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|open|final)\s+)*class\s+(\w+)\b")
_TEST_FUNC = re.compile(r"^\s*func\s+(test\w*)\s*\(")
_SUITE_PASSED = re.compile(r"^Test Suite '(\w+)' (?:passed|failed) at .*$")
_SUITE_TIMING = re.compile(r"Executed \d+ tests?, with .* in ([\d.]+) \(([\d.]+)\) seconds")
_EXECUTED = re.compile(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
)
_TOTAL_SECONDS = re.compile(r"in ([\d.]+) \(([\d.]+)\) seconds")


class ConfigError(Exception):
    pass


# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

def parse_class_durations(log_text):
    """{class name: seconds} from `Test Suite '<Class>' passed ...` + its `Executed ...` line.

    Only per-class suites count: the bundle ("NostromoTests.xctest"), "All tests" and
    "Selected tests" summaries are skipped (their names are not plain identifiers or are
    the known roll-ups).
    """
    durations = {}
    lines = log_text.splitlines()
    for i, line in enumerate(lines):
        m = _SUITE_PASSED.match(line)
        if not m or m.group(1) in ("All", "Selected"):
            continue
        for follow in lines[i + 1:i + 4]:
            t = _SUITE_TIMING.search(follow)
            if t:
                durations[m.group(1)] = durations.get(m.group(1), 0.0) + float(t.group(2))
                break
    return durations


def parse_executed(log_text):
    """(executed, failures) from the LAST `Executed N tests ...` line (the grand total)."""
    last = None
    for m in _EXECUTED.finditer(log_text):
        last = m
    if last is None:
        return None
    return int(last.group(1)), int(last.group(3))


def parse_total_seconds(log_text):
    last = None
    for line in log_text.splitlines():
        if _EXECUTED.search(line):
            t = _TOTAL_SECONDS.search(line)
            if t:
                last = float(t.group(2))
    return last


def balance(weights, bins=SHARD_COUNT):
    """Greedy longest-first assignment. Deterministic: ties go to the lowest bin and the
    lowest class name. Returns a list of `bins` sorted class-name lists."""
    loads = [0.0] * bins
    out = [[] for _ in range(bins)]
    for name, weight in sorted(weights.items(), key=lambda kv: (-kv[1], kv[0])):
        target = min(range(bins), key=lambda b: (loads[b], b))
        out[target].append(name)
        loads[target] += weight
    return [sorted(b) for b in out]


def shard_loads(assignment, weights):
    return [round(sum(weights.get(c, 0.0) for c in classes), 3) for classes in assignment]


def discover_classes(tests_dir):
    """{class name: number of `func test...` methods declared in it} for macOS/NostromoTests."""
    classes = {}
    for root, _dirs, files in os.walk(tests_dir):
        for fname in sorted(files):
            if not fname.endswith(".swift"):
                continue
            current = None
            with open(os.path.join(root, fname), encoding="utf-8") as f:
                for line in f:
                    m = _CLASS_DECL.match(line)
                    if m:
                        current = m.group(1)
                        classes.setdefault(current, 0)
                    elif current and _TEST_FUNC.match(line):
                        classes[current] += 1
    return classes


def load_config(path):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    shards = config.get("shards")
    if not isinstance(shards, list) or len(shards) != SHARD_COUNT:
        raise ConfigError("config must have exactly %d shards" % SHARD_COUNT)
    catch_alls = [i for i, s in enumerate(shards) if s.get("catch_all")]
    if catch_alls != [SHARD_COUNT - 1]:
        raise ConfigError("exactly the last shard must be the catch_all")
    for i, s in enumerate(shards[:-1]):
        if not s.get("classes"):
            raise ConfigError("shard %d lists no classes" % (i + 1))
    listed = [c for s in shards[:-1] for c in s["classes"]]
    dupes = sorted({c for c in listed if listed.count(c) > 1})
    if dupes:
        raise ConfigError("classes listed in more than one shard: %s" % ", ".join(dupes))
    if not isinstance(config.get("expected_min_executed"), int):
        raise ConfigError("expected_min_executed must be an integer")
    return config


def validate_config(config, known_classes):
    """List of problems; a listed class that does not exist would silently run zero tests."""
    problems = []
    for i, shard in enumerate(config["shards"][:-1]):
        for cls in shard["classes"]:
            if cls not in known_classes:
                problems.append(
                    "shard %d lists %s, which is not a class in %s" % (i + 1, cls, TEST_TARGET)
                )
    return problems


def xcodebuild_args(config, shard):
    """The test-selection arguments for shard number `shard` (1-based)."""
    if not 1 <= shard <= SHARD_COUNT:
        raise ConfigError("shard must be 1..%d" % SHARD_COUNT)
    shards = config["shards"]
    if shards[shard - 1].get("catch_all"):
        listed = sorted(c for s in shards[:-1] for c in s["classes"])
        return ["-skip-testing:%s/%s" % (TEST_TARGET, c) for c in listed]
    return ["-only-testing:%s/%s" % (TEST_TARGET, c) for c in sorted(shards[shard - 1]["classes"])]


def build_config(assignment, balanced_from, expected_min_executed):
    return {
        "shards": [{"classes": assignment[0]}, {"classes": assignment[1]}, {"catch_all": True}],
        "balanced_from": balanced_from,
        "expected_min_executed": expected_min_executed,
    }


def render_config(config):
    return json.dumps(config, indent=2, sort_keys=False) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _say(message, stream=sys.stdout):
    print(message, file=stream)


def _load_validated(args):
    config = load_config(args.config)
    problems = validate_config(config, discover_classes(args.tests_dir))
    if problems:
        for p in problems:
            _say("mac-shards: " + p, sys.stderr)
        raise ConfigError("%d invalid class reference(s)" % len(problems))
    return config


def _cmd_args(args):
    config = _load_validated(args)
    _say(" ".join(xcodebuild_args(config, args.shard)))
    return 0


def _cmd_validate(args):
    _load_validated(args)
    _say("mac-shards: config ok")
    return 0


def _cmd_report(args):
    with open(args.log, encoding="utf-8", errors="replace") as f:
        text = f.read()
    config = _load_validated(args)
    executed = parse_executed(text)
    report = {
        "shard": args.shard,
        "executed": executed[0] if executed else 0,
        "failures": executed[1] if executed else None,
        "seconds": parse_total_seconds(text),
        "classes_run": xcodebuild_args(config, args.shard),
        "constraint_cases_passed": len(
            re.findall(r"Test Case .*MotherDetailWidthConstraintTests.* passed", text)
        ),
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    _say("mac-shards: shard %d executed %d tests" % (args.shard, report["executed"]))
    return 0


def _cmd_regenerate(args):
    known = discover_classes(args.tests_dir)
    if args.log:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            text = f.read()
        weights = parse_class_durations(text)
        weights = {c: weights.get(c, 0.0) for c in known if c in weights}
        executed = parse_executed(text)
        floor = int((executed[0] if executed else 0) * 0.97)
        source = args.balanced_from or os.path.basename(args.log)
        # Classes absent from the log (new since the run) are left unlisted: the catch-all runs them.
        if not weights:
            raise ConfigError("no per-class durations found in %s" % args.log)
    else:
        weights = {c: float(n) for c, n in known.items() if n}
        floor = int(sum(weights.values()) * 0.97)
        source = args.balanced_from or "test-method-count estimate (no timing log yet)"
    assignment = balance(weights)
    config = build_config(assignment, source, floor)
    if args.floor:
        config["expected_min_executed"] = args.floor
    out = render_config(config)
    loads = shard_loads(assignment, weights)
    if args.write:
        with open(args.config, "w", encoding="utf-8") as f:
            f.write(out)
        _say("mac-shards: wrote %s" % args.config)
    else:
        sys.stdout.write(out)
    _say("mac-shards: balance (shards 1, 2, catch-all): %s" % loads, sys.stderr)
    return 0


def _parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--tests-dir", default=DEFAULT_TESTS_DIR)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("args")
    p.add_argument("--shard", type=int, required=True)
    sub.add_parser("validate")
    p = sub.add_parser("report")
    p.add_argument("--shard", type=int, required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("regenerate")
    p.add_argument("--log", help="mac-test-full.log from a green run")
    p.add_argument("--from-source", action="store_true", help="estimate from test-method counts")
    p.add_argument("--balanced-from", help="label recorded in the config (e.g. the run id)")
    p.add_argument("--floor", type=int, help="override expected_min_executed")
    p.add_argument("--write", action="store_true", help="write the config instead of printing it")
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse_args(argv)
    try:
        if args.command == "args":
            return _cmd_args(args)
        if args.command == "validate":
            return _cmd_validate(args)
        if args.command == "report":
            return _cmd_report(args)
        if not args.log and not args.from_source:
            raise ConfigError("regenerate needs --log <file> or --from-source")
        return _cmd_regenerate(args)
    except (ConfigError, OSError, ValueError) as err:
        _say("mac-shards: %s" % err, sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
