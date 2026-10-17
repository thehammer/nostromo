#!/usr/bin/env python3
"""Run Nostromo's GitHub CI on a pushed branch and report what failed.

    make ci-remote [BRANCH=<branch>] [ONLY=all|rust|python|swift|mac|kit|ios]
    make ci-remote RUN=<run id>       # attach to an existing run, no dispatch

Dispatches `.github/workflows/ci.yml` (`workflow_dispatch`, input `only`) on a
branch that is already pushed, waits for the run, and prints one
`FAILED <job>: <test or error>` line per failure, so a background job can
iterate against CI instead of running xcodebuild locally. See docs/ci.md.

Exit codes: 0 every job succeeded or was skipped; 1 a job failed, was cancelled
or timed out; 2 could not start (gh missing or unauthenticated, branch not
pushed, branch predates the dispatch trigger, bad arguments); 3 gave up waiting
or could not find the run. A run is never cancelled by this script; on a
timeout or Ctrl-C it prints how to reattach.

Standard library only; Python 3.9+.
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import time

WORKFLOW = "ci.yml"
ONLY_CHOICES = ("all", "rust", "python", "swift", "mac", "kit", "ios")
UNPARSED_TAG = "[unparsed] "
UNPARSED_TAIL_LINES = 30
GOOD_CONCLUSIONS = ("success", "skipped")
BAD_RUN_CONCLUSIONS = ("failure", "cancelled", "timed_out", "startup_failure")
SELECT_SLACK = datetime.timedelta(seconds=10)

# `gh run view --log-failed` renders ESC as the two characters `^[`; real ESC
# bytes are handled too.
_ANSI = re.compile(r"(?:\x1b|\^\[)\[[0-9;]*[A-Za-z]")
_TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
_CHECKOUT_PREFIX = re.compile(r"^/(?:Users|home)/runner/work/[^/]+/[^/]+/")

_XCTEST = re.compile(r"Test Case '-\[(\S+) (\S+)\]' failed")
_SWIFT_TESTING = re.compile(
    r'^\s*✘ Test (?:"([^"]+)"|(\S+)) (?:failed|recorded an issue)'
)
_CARGO_TEST = re.compile(r"^test (\S+) \.\.\. FAILED")
_RUSTC_ERROR = re.compile(r"^error(?:\[\w+\])?: (.+)$")
_RUSTC_ARROW = re.compile(r"^\s*--> (\S+?):(\d+):\d+")
_SWIFT_COMPILE = re.compile(r"^(\S.*?\.swift):(\d+):\d+: error: (.*)$")
_UNITTEST = re.compile(r"^(?:FAIL|ERROR): (\w+) \(([\w.]+)\)")
_ARROW_LOOKAHEAD = 3


# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

def parse_failed_log(text):
    """Map job name -> failed items found in `gh run view --log-failed` text."""
    result = {}
    for job, lines in _lines_by_job(text).items():
        items = _failures_in(lines)
        if not items:
            items = [UNPARSED_TAG + line for line in lines[-UNPARSED_TAIL_LINES:]]
        result[job] = items
    return result


def select_run(runs, head_sha, not_before):
    """Newest workflow_dispatch run of `head_sha` created at/after not_before - 10 s."""
    earliest = not_before - SELECT_SLACK
    candidates = [
        run for run in runs
        if run.get("event") == "workflow_dispatch"
        and run.get("headSha") == head_sha
        and _parse_time(run["createdAt"]) >= earliest
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda run: _parse_time(run["createdAt"]))


def summarize(run_json):
    """Return ({job name: conclusion or status}, exit code) for a run."""
    jobs = {
        job["name"]: job.get("conclusion") or job.get("status")
        for job in run_json.get("jobs", [])
    }
    ok = (
        all(state in GOOD_CONCLUSIONS for state in jobs.values())
        and run_json.get("conclusion") not in BAD_RUN_CONCLUSIONS
    )
    return jobs, 0 if ok else 1


def _lines_by_job(text):
    jobs = {}
    for raw in text.splitlines():
        parts = raw.lstrip("﻿").split("\t", 2)
        if len(parts) < 3:
            continue
        body = _TIMESTAMP.sub("", _ANSI.sub("", parts[2]), count=1)
        jobs.setdefault(parts[0], []).append(body.replace("﻿", ""))
    return jobs


def _failures_in(lines):
    items = []

    def add(item):
        if item not in items:
            items.append(item)

    for i, line in enumerate(lines):
        if m := _XCTEST.search(line):
            add("%s/%s" % (m.group(1), m.group(2)))
        elif m := _SWIFT_TESTING.match(line):
            add(m.group(1) or m.group(2))
        elif m := _CARGO_TEST.match(line):
            add(m.group(1))
        elif m := _UNITTEST.match(line):
            name, where = m.groups()
            add(where if where.endswith("." + name) else "%s.%s" % (where, name))
        elif m := _SWIFT_COMPILE.match(line):
            add("%s:%s %s" % (_CHECKOUT_PREFIX.sub("", m.group(1)), m.group(2), m.group(3)))
        elif m := _RUSTC_ERROR.match(line):
            arrow = _rustc_location(lines[i + 1:i + 1 + _ARROW_LOOKAHEAD])
            if arrow:
                add("%s %s" % (arrow, m.group(1)))
    return items


def _rustc_location(following):
    for line in following:
        if m := _RUSTC_ARROW.match(line):
            return "%s:%s" % (m.group(1), m.group(2))
    return None


def _parse_time(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


# ---------------------------------------------------------------------------
# gh / git plumbing
# ---------------------------------------------------------------------------

def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def _say(message, stream=sys.stdout):
    print(message, file=stream, flush=True)


def _gh_json(args):
    proc = _run(["gh"] + args)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return None


def _git_out(args):
    proc = _run(["git"] + args)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _check_gh():
    if shutil.which("gh") is None:
        _say("gh is not installed (https://cli.github.com).", sys.stderr)
        return False
    if _run(["gh", "auth", "status"]).returncode != 0:
        _say("gh is not authenticated: run `gh auth login` (scopes: repo, workflow).", sys.stderr)
        return False
    return True


def _pushed_head(branch):
    """Remote head sha of `branch`, or None (after saying why) if it can't be dispatched."""
    remote = _git_out(["ls-remote", "origin", "refs/heads/%s" % branch]).split("\t")[0]
    if not remote:
        _say("Branch %s is not on origin: push first." % branch, sys.stderr)
        return None
    if branch == _git_out(["rev-parse", "--abbrev-ref", "HEAD"]):
        local = _git_out(["rev-parse", "HEAD"])
    else:
        local = _git_out(["rev-parse", "--verify", "--quiet", "refs/heads/%s" % branch]) or remote
    if local != remote:
        _say(
            "Local %s (%s) differs from origin (%s): push first, CI only sees what is on origin."
            % (branch, local[:10], remote[:10]),
            sys.stderr,
        )
        return None
    return remote


def _dispatch(branch, only, head_sha, args):
    """Start the run; return (run, exit code on failure)."""
    not_before = datetime.datetime.now(datetime.timezone.utc)
    proc = _run(["gh", "workflow", "run", WORKFLOW, "--ref", branch, "-f", "only=%s" % only])
    if proc.returncode != 0:
        output = (proc.stderr + proc.stdout).strip()
        _say(output, sys.stderr)
        if "workflow_dispatch" in output:
            _say(
                "Branch predates the dispatch trigger: rebase onto main "
                "(and the trigger must be on main for GitHub to offer it).",
                sys.stderr,
            )
        return None, 2
    deadline = time.monotonic() + args.discover_timeout_s
    while True:
        runs = _gh_json([
            "run", "list", "--workflow", WORKFLOW, "--branch", branch,
            "--event", "workflow_dispatch", "--limit", "10",
            "--json", "databaseId,headSha,createdAt,url,event",
        ]) or []
        run = select_run(runs, head_sha, not_before)
        if run:
            return run, 0
        if time.monotonic() >= deadline:
            _say(
                "Dispatched, but could not find the run. Look for it with "
                "`gh run list --workflow %s --event workflow_dispatch`, then "
                "`make ci-remote RUN=<id>`." % WORKFLOW,
                sys.stderr,
            )
            return None, 3
        time.sleep(args.discover_interval_s)


def _wait(run_id, args):
    """Poll until the run completes; return (final run JSON or None on timeout, run url)."""
    deadline = time.monotonic() + args.timeout_min * 60
    url = None
    last_state = {}
    while True:
        run = _gh_json(["run", "view", str(run_id), "--json", "status,conclusion,jobs,url"])
        if run is not None:
            if url is None:
                url = run.get("url", str(run_id))
                _say("Run: %s" % url)
            for job, state in summarize(run)[0].items():
                if last_state.get(job) != state:
                    last_state[job] = state
                    _say("  %s: %s" % (job, state))
            if run.get("status") == "completed":
                return run, url
        if time.monotonic() >= deadline:
            return None, url
        time.sleep(args.interval_s)


def _report_failures(run_id, jobs):
    proc = _run(["gh", "run", "view", str(run_id), "--log-failed"])
    parsed = parse_failed_log(proc.stdout) if proc.returncode == 0 else {}
    for job, items in parsed.items():
        for item in items:
            _say("FAILED %s: %s" % (job, item))
    for job, state in jobs.items():
        if state not in GOOD_CONCLUSIONS and job not in parsed:
            _say("FAILED %s: %s (no failed-step log available)" % (job, state))


def _reattach_hint(run_id, url):
    _say("Run %s is still going: %s" % (run_id, url or ""))
    _say("Reattach with: make ci-remote RUN=%s" % run_id)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--branch", help="pushed branch to run CI on (default: current branch)")
    parser.add_argument("--only", choices=ONLY_CHOICES, default="all", help="which jobs to run")
    parser.add_argument("--run-id", help="attach to this run instead of dispatching")
    parser.add_argument("--timeout-min", type=float, default=50,
                        help="give up waiting after this long (default 50, above the Mac job's 45)")
    parser.add_argument("--interval-s", type=float, default=30, help="poll interval")
    parser.add_argument("--discover-interval-s", type=float, default=3)
    parser.add_argument("--discover-timeout-s", type=float, default=60)
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse_args(argv)
    if not _check_gh():
        return 2

    run_id = args.run_id
    url = None
    if not run_id:
        branch = args.branch or _git_out(["rev-parse", "--abbrev-ref", "HEAD"])
        if not branch or branch == "HEAD":
            _say("No branch to run CI on (detached HEAD?): pass BRANCH=<branch>.", sys.stderr)
            return 2
        head_sha = _pushed_head(branch)
        if head_sha is None:
            return 2
        run, code = _dispatch(branch, args.only, head_sha, args)
        if run is None:
            return code
        run_id, url = run["databaseId"], run.get("url")

    try:
        final, url = _wait(run_id, args)
    except KeyboardInterrupt:
        _reattach_hint(run_id, url)
        return 3
    if final is None:
        _reattach_hint(run_id, url)
        return 3

    jobs, code = summarize(final)
    _say("CI run %s: %s" % (run_id, final.get("conclusion")))
    if code != 0:
        _report_failures(run_id, jobs)
    return code


if __name__ == "__main__":
    sys.exit(main())
