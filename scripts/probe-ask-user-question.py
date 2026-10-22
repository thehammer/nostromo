#!/usr/bin/env python3
"""Probe: what does the real `claude` CLI do with an `AskUserQuestion` answer?

NOT run by CI and NOT part of any test: it starts a real `claude` and spends model tokens. A human runs it once
to verify the reply shape Nostromo's approval card (AP2c) sends:

    allow, with updatedInput = <original input> plus answers = {"<question text>": "<answer string>"}

What it does: starts `claude -p --input-format stream-json --output-format stream-json
--permission-prompt-tool stdio` in a temp directory, asks the model to call AskUserQuestion with one single-select
and one multi-select question, answers the resulting `can_use_tool` control request with an allow whose
`updatedInput.answers` picks the first option of the first question and the first two of the second (with
`--other`, a typed free-text answer for the first instead), then prints the tool_result the CLI produced.
PASS means the tool_result text quotes every answer as "<question>"="<answer>", the shape the CLI's own tool
code reads. INCONCLUSIVE (exit 3) means the model never called the tool.

    python3 scripts/probe-ask-user-question.py [--claude PATH] [--other] [--timeout SECONDS]

It writes nothing outside a `tempfile.mkdtemp()` directory (removed at the end) and talks to nothing but the
`claude` CLI you already use. It never touches ~/.nostromo or a running nostromd.
"""
import argparse
import json
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PROMPT = (
    "Call the AskUserQuestion tool exactly once with two questions, then stop. "
    "Question 1: 'Which database should we use?' (header 'Database', single select, options "
    "'Postgres' - relational, and 'SQLite' - embedded). "
    "Question 2: 'Which features do you want to enable?' (header 'Features', multiSelect true, options "
    "'Caching', 'Metrics', 'Tracing', each with a one-line description). "
    "After the tool result arrives, repeat the answers you received in one sentence."
)


def reader(stream, out):
    for line in stream:
        out.put(line)
    out.put(None)


def answers_for(questions, other):
    """First option of question 1 (or typed text), the first two options of question 2."""
    first = questions[0]
    answers = {first["question"]: "Mongo (typed)" if other else first["options"][0]["label"]}
    if len(questions) > 1:
        labels = [o["label"] for o in questions[1]["options"][:2]]
        answers[questions[1]["question"]] = ", ".join(labels)
    return answers


def allow_reply(request_id, original, answers):
    updated = dict(original)
    updated["answers"] = answers
    return {"type": "control_response",
            "response": {"subtype": "success", "request_id": request_id,
                         "response": {"behavior": "allow", "updatedInput": updated}}}


def tool_result_text(msg):
    for block in (msg.get("message") or {}).get("content") or []:
        if isinstance(block, dict) and block.get("type") == "tool_result":
            content = block.get("content")
            if isinstance(content, list):
                content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
            return content
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claude", default=shutil.which("claude") or "claude")
    ap.add_argument("--other", action="store_true", help="answer question 1 with free text instead of an option")
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="probe-ask-")
    try:
        proc = subprocess.Popen(
            [args.claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--dangerously-skip-permissions", "--permission-prompt-tool", "stdio"],
            cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        lines = queue.Queue()
        threading.Thread(target=reader, args=(proc.stdout, lines), daemon=True).start()
        proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": PROMPT}}) + "\n")
        proc.stdin.flush()

        deadline = time.time() + args.timeout
        answers = None
        tool_result = None
        while time.time() < deadline:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            req = msg.get("request") if msg.get("type") == "control_request" else None
            if req and req.get("subtype") == "can_use_tool" and req.get("tool_name") == "AskUserQuestion":
                answers = answers_for(req["input"]["questions"], args.other)
                print("request input:", json.dumps(req["input"]))
                print("sending answers:", json.dumps(answers))
                proc.stdin.write(json.dumps(allow_reply(msg["request_id"], req["input"], answers)) + "\n")
                proc.stdin.flush()
            elif answers is not None and msg.get("type") == "user":
                tool_result = tool_result_text(msg) or tool_result
            elif answers is not None and msg.get("type") == "result":
                break
        proc.stdin.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

        print("tool_result:", tool_result)
        if answers is None:
            print("INCONCLUSIVE: the model never called AskUserQuestion (no can_use_tool request seen)")
            return 3
        ok = bool(tool_result) and all(('"%s"="%s"' % (q, a)) in tool_result for q, a in answers.items())
        print("PASS: the tool_result quotes every answer" if ok else "FAIL: the tool_result does not quote the answers we sent")
        return 0 if ok else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
