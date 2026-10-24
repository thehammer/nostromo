#!/usr/bin/env python3
"""Live discoverability eval for `nostromo.tracker` (PRD criteria 26 and 28). USER-RUN ONLY.

    scripts/qa/tracker-discoverability.sh [--dry-run] [--runs N] [--model M] [--agents a,b]

Against the isolated QA instance (`qa-instance.sh start`, with `NOSTROMO_QA_CLAUDE_BIN` pointing at a
real `claude` for that start), for each agent (a generic one and Claudia) it creates N fresh disposable
`qa-tracker-<n>` focuses, sends "keep a tracker of what we're doing", waits for the turn, and checks:

  * a board exists under the focus's `.claude/wip/*/index.md`;
  * the session's stored transcript has at most one ToolSearch call before the tracker call.

It prints `n/N` per agent (the PRD target is 9 of 10). Never run by CI or a job: it spends model tokens.
`--dry-run` prints the plan and starts nothing. Stdlib only; run with `python3 -I`.
"""
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

AGENTS = ("cody", "claudia")
PROMPT = "keep a tracker of what we're doing"
DEFAULT_RUNS = 10
DEFAULT_MODEL = "haiku"
TURN_TIMEOUT = 180
TRACKER_TOOL = "mcp__nostromo__nostromo_tracker"
PASS_TARGET = 9


def focus_label(n):
    return f"qa-tracker-{n}"


def parse_args(argv):
    opts = {"dry_run": False, "runs": DEFAULT_RUNS, "model": DEFAULT_MODEL, "agents": list(AGENTS)}
    it = iter(argv)
    for a in it:
        if a == "--dry-run":
            opts["dry_run"] = True
        elif a == "--runs":
            opts["runs"] = int(next(it))
        elif a == "--model":
            opts["model"] = next(it)
        elif a == "--agents":
            opts["agents"] = next(it).split(",")
        else:
            raise SystemExit(f"unknown argument {a!r}\nusage: tracker-discoverability.sh [--dry-run] [--runs N] [--model M] [--agents a,b]")
    if opts["runs"] < 1:
        raise SystemExit("--runs must be at least 1")
    return opts


def plan_lines(opts):
    lines = [
        "tracker discoverability eval (dry run: nothing is started)" if opts["dry_run"] else "tracker discoverability eval",
        f"model: {opts['model']}   runs per agent: {opts['runs']}   pass target: {PASS_TARGET}/10",
        f"prompt: {PROMPT!r}",
    ]
    for agent in opts["agents"]:
        lines.append(f"agent {agent}:")
        for n in range(1, opts["runs"] + 1):
            lines.append(f"  {focus_label(n)}: create focus, send prompt, wait up to {TURN_TIMEOUT}s, "
                         "check board file and ToolSearch count")
    lines.append("check: <focus cwd>/.claude/wip/*/index.md exists; <= 1 ToolSearch call before the tracker call")
    lines.append("cleanup: remove the QA focuses' working directories")
    return lines


def tool_calls(transcript_path):
    """Names of the tool_use blocks in a Claude Code JSONL transcript, in order."""
    names = []
    try:
        with open(transcript_path, encoding="utf-8") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, list):
                    names.extend(b.get("name", "") for b in content if isinstance(b, dict) and b.get("type") == "tool_use")
    except OSError:
        pass
    return names


def tool_searches_before_tracker(names):
    """ToolSearch calls before the first tracker call; None if the tracker was never called."""
    searches = 0
    for name in names:
        if name == TRACKER_TOOL:
            return searches
        if name == "ToolSearch":
            searches += 1
    return None


def run_passes(board_exists, names):
    """(passed, reason) for one run."""
    if not board_exists:
        return False, "no board file"
    before = tool_searches_before_tracker(names)
    if before is None:
        return False, "no tracker call in the transcript"
    if before > 1:
        return False, f"{before} ToolSearch calls before the tracker call"
    return True, "ok"


def board_exists(cwd):
    return bool(glob.glob(os.path.join(cwd, ".claude", "wip", "*", "index.md")))


def transcript_for(qa_root, cwd):
    """Newest stored transcript of a session whose cwd is `cwd` (under the QA HOME's ~/.claude/projects)."""
    slug = os.path.realpath(cwd).replace("/", "-").replace(".", "-")
    files = glob.glob(os.path.join(qa_root, "home", ".claude", "projects", slug, "*.jsonl"))
    return max(files, key=os.path.getmtime) if files else None


def live_run(opts):
    import qa_instance as qi  # lazy: a dry run must not need the QA machinery

    qa_root = qi.resolve_root(None)
    ctl_sock = os.path.join(qa_root, "app-control.sock")
    ctl = [os.path.join(qi.REPO, "bin", "nostromo-app"), "--socket", ctl_sock]
    results = {}
    for agent in opts["agents"]:
        passed = 0
        for n in range(1, opts["runs"] + 1):
            label = focus_label(n) if agent == opts["agents"][0] else f"{focus_label(n)}-{agent}"
            cwd = os.path.join(qa_root, "tracker-eval", f"{agent}-{n}")
            os.makedirs(cwd, exist_ok=True)
            os.system(f"git -C '{cwd}' init -q")
            try:
                qi.mcp_create_focus(qa_root, cwd, label=label, title=label, agent=agent)
            except (ValueError, RuntimeError, OSError) as e:
                print(f"{agent} {label}: FAIL could not create the focus: {e}")
                continue
            ok, why = False, "turn did not finish"
            if (qi.run(ctl + ["wait", label, "--timeout", "30"]).returncode == 0
                    and qi.run(ctl + ["click", "--text", label]).returncode == 0
                    and qi.run(ctl + ["wait", "Message…", "--timeout", "15"]).returncode == 0):
                qi.run(ctl + ["click", "--text", "Message…"])
                qi.run(ctl + ["type", PROMPT])
                qi.run(ctl + ["key", "\r", "--key-code", "36"])
                deadline = time.time() + TURN_TIMEOUT
                while time.time() < deadline:
                    t = transcript_for(qa_root, cwd)
                    if board_exists(cwd) and t and TRACKER_TOOL in tool_calls(t):
                        break
                    time.sleep(3)
                t = transcript_for(qa_root, cwd)
                ok, why = run_passes(board_exists(cwd), tool_calls(t) if t else [])
            else:
                why = "could not reach the composer"
            passed += ok
            print(f"{agent} {label}: {'PASS' if ok else 'FAIL'} ({why})")
        results[agent] = passed
    for agent, passed in results.items():
        print(f"{agent}: {passed}/{opts['runs']}")
    print("cleanup: removing eval working directories; the focuses end with `scripts/qa/qa-instance.sh stop`")
    import shutil
    shutil.rmtree(os.path.join(qa_root, "tracker-eval"), ignore_errors=True)
    return 0 if all(p >= PASS_TARGET * opts["runs"] // 10 for p in results.values()) else 1


def main(argv):
    opts = parse_args(argv)
    if opts["dry_run"]:
        print("\n".join(plan_lines(opts)))
        return 0
    print("\n".join(plan_lines(opts)[:3]))
    return live_run(opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
