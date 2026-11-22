#!/usr/bin/env python3
"""Probe: what does the real `claude` CLI do with a user frame written to stdin MID-TURN?

NOT run by CI and NOT part of any test: it starts a real `claude` (haiku) and SPENDS MODEL TOKENS, a handful of
short turns per scenario. A human runs it to answer the message-queue spike questions (docs/midturn-stdin-spike.md).

Each scenario starts `claude -p --model haiku --input-format stream-json --output-format stream-json --verbose
--replay-user-messages --session-id <fresh uuid> --tools Bash --allowedTools "Bash(sleep:*)" --permission-mode
dontAsk` in a temp directory (permissions are NOT bypassed; only `sleep` may run), asks the model to run
`sleep 4` three times and say "done", writes the scenario's mid-turn frame once the first `tool_use` appears on
stdout, and records every stdout line (monotonic timestamp) and every frame it wrote:

  a  text frame mid-turn
  b  text plus a small generated PNG mid-turn (asks for its colour)
  c  the mid-turn text frame, then 1 s later an interrupt control request
  d  control: no mid-turn frame
  e  `/context` typed mid-turn

Afterwards it reads the session file the CLI stored for that `--session-id` (~/.claude/projects/<slug>/<uuid>.jsonl),
summarises its user records, and deletes ONLY that file (and its slug directory, only if the probe created it and
it is now empty). A scenario where the model never calls a tool is INCONCLUSIVE (exit 3), never a pass.

    python3 scripts/probe-midturn-stdin.py [--claude PATH] [--timeout SECONDS] [--out DIR] [--only a,b,...]

It writes nothing outside a `tempfile.mkdtemp()` directory (or --out) except the stored session file it deletes,
and talks to nothing but the `claude` CLI you already use. It never touches ~/.nostromo or a running nostromd.
"""
import argparse
import base64
import glob
import json
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib

FIRST = ("Run the Bash command `sleep 4` three times, one Bash call at a time (never in parallel, never combined), "
         "then reply with the single word: done")
MIDTURN_TEXT = "MIDTURN-PING: also reply with the word banana when you finish."
MIDTURN_IMAGE_TEXT = "MIDTURN-IMAGE: what single colour is the attached image? Say the colour name when you finish."
SCENARIOS = {
    "a": "text frame mid-turn",
    "b": "text + PNG mid-turn",
    "c": "mid-turn frame, then interrupt 1 s later",
    "d": "control, no mid-turn frame",
    "e": "/context typed mid-turn",
}


def png_base64(rgb=(255, 0, 0), size=16):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * size
    raw = zlib.compress(row * size)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", raw) + chunk(b"IEND", b""))
    return base64.b64encode(png).decode()


def user_frame(text, images=()):
    """Same shape as Nostromo's `write_user_frame`: a string, or text block + one image block per image."""
    if not images:
        content = text
    else:
        content = [{"type": "text", "text": text}] + [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": d}} for d in images]
    return {"type": "user", "message": {"role": "user", "content": content}}


def interrupt_frame():
    return {"type": "control_request", "request_id": "interrupt-%d" % int(time.time() * 1000),
            "request": {"subtype": "interrupt"}}


def midturn_frames(scn):
    if scn in ("a", "c"):
        return [user_frame(MIDTURN_TEXT)]
    if scn == "b":
        return [user_frame(MIDTURN_IMAGE_TEXT, [png_base64()])]
    if scn == "e":
        return [user_frame("/context")]
    return []


def reader(stream, out):
    for line in stream:
        out.put((time.monotonic(), line))
    out.put((time.monotonic(), None))


def has_tool_use(msg):
    content = (msg.get("message") or {}).get("content")
    return msg.get("type") == "assistant" and isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_use" for b in content)


def stored_user_records(session_id):
    """(path, summaries) of the stored session file for this id, or (None, []).

    Keeps user records, queue-operation records and the `queued_command` attachment (the other attachments are
    hook/environment noise: they stay in the raw copy only).
    """
    hits = glob.glob(os.path.join(os.path.expanduser("~/.claude/projects"), "*", session_id + ".jsonl"))
    if not hits:
        return None, []
    out = []
    with open(hits[0]) as f:
        for raw in f:
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            kind = rec.get("type")
            att = rec.get("attachment") if isinstance(rec.get("attachment"), dict) else {}
            if kind not in ("user", "queue-operation", "attachment"):
                continue
            if kind == "attachment" and att.get("type") != "queued_command":
                continue
            content = (rec.get("message") or {}).get("content", rec.get("content"))
            if kind == "attachment":
                content = att.get("prompt")
            shape = ("string" if isinstance(content, str) else
                     [b.get("type") if isinstance(b, dict) else type(b).__name__ for b in content]
                     if isinstance(content, list) else None)
            text = content if isinstance(content, str) else " ".join(
                b.get("text", "") or str(b.get("content", ""))[:80] for b in content if isinstance(b, dict)
            ) if isinstance(content, list) else ""
            summary = {k: rec.get(k) for k in ("type", "operation", "reason", "promptSource", "turnOrigin", "origin",
                                               "isMeta", "timestamp") if k in rec}
            summary.update({"content_shape": shape, "text": text[:110]})
            if kind == "attachment":
                summary.update({"attachment_type": att.get("type"), "commandMode": att.get("commandMode"),
                                "renderedRole": rec.get("renderedRole")})
                if rec.get("rendered"):
                    summary["rendered"] = json.dumps(rec["rendered"])[:400]
            out.append(summary)
    return hits[0], out


def delete_stored(path, slug_preexisted):
    if not path:
        return
    os.remove(path)
    slug = os.path.dirname(path)
    if slug_preexisted:
        return
    # The CLI also leaves an empty `memory/` directory next to the session file: rmdir (never rmtree) removes
    # empty directories only, so nothing with content is ever deleted.
    for name in os.listdir(slug):
        try:
            os.rmdir(os.path.join(slug, name))
        except OSError:
            pass
    try:
        os.rmdir(slug)
    except OSError:
        pass


def run_scenario(args, scn, run_no, out_dir):
    work = tempfile.mkdtemp(prefix="probe-midturn-")
    session_id = str(uuid.uuid4())
    argv = [args.claude, "-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--replay-user-messages", "--session-id", session_id,
            "--tools", "Bash", "--allowedTools", "Bash(sleep:*)", "--permission-mode", "dontAsk"]
    projects = os.path.expanduser("~/.claude/projects")
    before = set(os.listdir(projects)) if os.path.isdir(projects) else set()
    log = []  # {"t": seconds since start, "dir": "out"|"in", "frame": ...}
    t0 = time.monotonic()
    first_tool = None
    wrote_mid = None
    wrote_interrupt = None
    results = []
    proc = None
    try:
        proc = subprocess.Popen(argv, cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        lines = queue.Queue()
        threading.Thread(target=reader, args=(proc.stdout, lines), daemon=True).start()

        def write(frame):
            now = time.monotonic()
            log.append({"t": round(now - t0, 3), "dir": "in", "frame": frame})
            proc.stdin.write(json.dumps(frame) + "\n")
            proc.stdin.flush()
            return now

        write(user_frame(FIRST))
        mid = midturn_frames(scn)
        deadline = time.monotonic() + args.timeout
        # After the first result: wait briefly for a second result (a queued frame may start a new turn).
        grace_until = None
        while time.monotonic() < deadline:
            try:
                ts, line = lines.get(timeout=0.5)
            except queue.Empty:
                if grace_until and time.monotonic() > grace_until:
                    break
                if scn == "c" and wrote_mid and not wrote_interrupt and time.monotonic() - wrote_mid >= 1.0:
                    wrote_interrupt = write(interrupt_frame())
                continue
            if line is None:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                msg = {"unparsed": line[:200]}
            log.append({"t": round(ts - t0, 3), "dir": "out", "frame": msg})
            if first_tool is None and has_tool_use(msg):
                first_tool = ts
                if mid:
                    for frame in mid:
                        wrote_mid = write(frame)
            if scn == "c" and wrote_mid and not wrote_interrupt and time.monotonic() - wrote_mid >= 1.0:
                wrote_interrupt = write(interrupt_frame())
            if msg.get("type") == "result":
                results.append(msg)
                # Control and (c) end at the first result; others linger to see a follow-on turn.
                grace_until = time.monotonic() + (90 if scn == "c" else 3 if scn == "d" else 12)
                if scn == "c" and len(results) >= 2:
                    break
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        alive_after_interrupt = None
    finally:
        if proc and proc.poll() is None:
            proc.kill()
        shutil.rmtree(work, ignore_errors=True)

    path, stored = stored_user_records(session_id)
    slug_preexisted = bool(path) and os.path.basename(os.path.dirname(path)) in before
    stored_copy = None
    if path:
        stored_copy = os.path.join(out_dir, "%s%d.stored.jsonl" % (scn, run_no))
        shutil.copyfile(path, stored_copy)
    delete_stored(path, slug_preexisted)

    rel = (lambda t: None if first_tool is None else round(t - (first_tool - t0), 3))
    for entry in log:
        entry["t_rel_first_tool_use"] = rel(entry["t"])
    with open(os.path.join(out_dir, "%s%d.log.json" % (scn, run_no)), "w") as f:
        json.dump({"argv": [a if a != session_id else "<session-id>" for a in argv], "session_id": session_id,
                   "log": log, "stored_user_records": stored}, f, indent=1)
    return {"scn": scn, "run": run_no, "tool_use_seen": first_tool is not None, "results": results, "log": log,
            "stored": stored, "wrote_mid": wrote_mid is not None, "wrote_interrupt": wrote_interrupt is not None}


def summarise(r):
    print("--- scenario %s run %d: %s" % (r["scn"], r["run"], SCENARIOS[r["scn"]]))
    if not r["tool_use_seen"]:
        print("INCONCLUSIVE: the model never called a tool")
        return 3
    for e in r["log"]:
        f = e["frame"]
        kind = f.get("type")
        if e["dir"] == "out" and kind in ("stream_event", "rate_limit_event"):
            continue
        label = kind
        if kind == "system":
            label += "/" + str(f.get("subtype"))
        extra = ""
        if kind == "user":
            c = (f.get("message") or {}).get("content")
            extra = " replay=%s content=%s" % (f.get("isReplay"), json.dumps(c)[:140])
        elif kind == "assistant":
            c = (f.get("message") or {}).get("content") or []
            extra = " " + json.dumps([{b.get("type"): (b.get("name") or b.get("text", "")[:80])} for b in c])
        elif kind == "result":
            extra = " subtype=%s cost=%s turns=%s result=%s" % (f.get("subtype"), f.get("total_cost_usd"),
                                                                 f.get("num_turns"), json.dumps(f.get("result"))[:100])
        elif kind == "control_response":
            extra = " " + json.dumps(f.get("response"))[:100]
        print("%7.2fs %-3s %s%s" % (e["t_rel_first_tool_use"], e["dir"], label, extra))
    print("stored user records:")
    for rec in r["stored"]:
        print("  ", json.dumps(rec))
    print("cost_usd (sum of result frames): %s" % sum((x.get("total_cost_usd") or 0) for x in r["results"]))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claude", default=shutil.which("claude") or "claude")
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--out", help="directory for raw logs (default: a temp directory, printed)")
    ap.add_argument("--only", default=",".join(SCENARIOS), help="comma-separated scenarios, default all")
    ap.add_argument("--runs", type=int, default=1, help="repeat each scenario this many times")
    args = ap.parse_args()

    print("claude version:", subprocess.run([args.claude, "--version"], capture_output=True, text=True).stdout.strip())
    out_dir = args.out or tempfile.mkdtemp(prefix="probe-midturn-out-")
    os.makedirs(out_dir, exist_ok=True)
    print("raw logs in:", out_dir)
    rc = 0
    for scn in [s.strip() for s in args.only.split(",") if s.strip()]:
        for run_no in range(1, args.runs + 1):
            rc = max(rc, summarise(run_scenario(args, scn, run_no, out_dir)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
