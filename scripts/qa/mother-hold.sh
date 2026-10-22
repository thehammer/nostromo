#!/usr/bin/env bash
# QA scenario (the PRD's "gate-exhausted hold"): a held job shows Mother's four options with their
# consequences, and answering one with a real click reaches the broker as exactly one `answer`.
#
# Setup (the script does NOT do this — it relaunches nothing):
#   python3 bin/fake-mother-broker --sock /tmp/fmb-qa.sock --scenario crew_hold &
#   open --env MOTHER_BROKER_SOCK=/tmp/fmb-qa.sock <a QA build of Nostromo.app>
# Needs AppControlEnabled and a visible window. It TAKES keyboard focus for the run (clicks need a
# key window) and gives it back on exit.
#
# Two runs, because the answer buttons accept only a human gesture and app-control is not one:
#
#   QA_EXPECT_GATE=allowed   (default) the app was launched with NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT=1 (a QA
#                            bundle only: the user's app never honours it). The script types guidance, clicks
#                            "Resume with guidance", and asserts the broker got exactly one `answer`
#                            {job, option: resume_with_guidance, source: nostromo_app, text: <the guidance>}
#                            and that the job left AWAITING.
#   QA_EXPECT_GATE=refused   the app was launched WITHOUT that variable. The same click must send NOTHING:
#                            the broker has no `answer`, the job is still held, the options are still shown.
#                            This is the live proof that the gate is on. (The script cannot switch the
#                            variable on a running app; relaunch it between the two runs.)
#
# It reads the accessibility tree, so what it expects is each control's label and the consequence text.
#
# Env: QA_SCREEN (display to test, default Sceptre), QA_FMB_SOCK (fake broker socket, default
# /tmp/fmb-qa.sock), QA_SETTLE (seconds for the app to reconnect after the broker resets, default 4),
# QA_EXPECT_GATE (allowed|refused), QA_GUIDANCE (the guidance to type), QA_APP (the app-control CLI; the
# self-test points it at a fake).
set -euo pipefail
APP="${QA_APP:-$(dirname "$0")/../../bin/nostromo-app}"
SCREEN="${QA_SCREEN:-Sceptre}"
SOCK="${QA_FMB_SOCK:-/tmp/fmb-qa.sock}"
SETTLE="${QA_SETTLE:-4}"
EXPECT_GATE="${QA_EXPECT_GATE:-allowed}"
GUIDANCE="${QA_GUIDANCE:-Fix the seed data, then re-run the unit gate.}"
JOB="j-hold1"
TITLE="Backfill invoice totals"
export NOSTROMO_QA_SCREEN="$SCREEN"
case "$EXPECT_GATE" in allowed|refused) ;; *) echo "QA_EXPECT_GATE must be allowed or refused" >&2; exit 2 ;; esac
app() { "$APP" --screen "$SCREEN" "$@"; }
ctl() { python3 -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1] + ".ctl"); s.sendall((sys.argv[2] + "\n").encode())
r = json.loads(s.makefile().readline())
if not r.get("ok"):
    sys.exit("fake broker: %s" % r)
print(json.dumps(r.get("result")))' "$SOCK" "$1"; }

app activate >/dev/null
sleep 0.6   # let the window actually become key before the first click
trap 'app restore >/dev/null 2>&1 || true' EXIT

# Start from the scenario's jobs: dropping the clients makes the app reconnect and re-snapshot.
ctl '{"op":"reset"}' >/dev/null
sleep "$SETTLE"
app click --text "Mother"

# 1. the held job is in the queue; open it
app wait "$TITLE" --timeout 8
app click --text "$TITLE"

# 2. the four options, in Mother's order, each with its consequence visible
app wait "Resume with guidance" --timeout 8
app wait "Resumes the worker with your written guidance as its next instruction." --timeout 5
app wait "Escalate" --timeout 5
app wait "Re-runs the work one model tier higher than the attempt that just failed." --timeout 5
app wait "Open anyway" --timeout 5
app wait "Opens the PR for review even though these gates are red; the override is recorded on the PR." --timeout 5
app wait "Cancel" --timeout 5
app wait "Cancels the job; the branch and any commits already made are left in place." --timeout 5

# 3. guidance, then the click
app click --text "Guidance for the worker"
app type "$GUIDANCE"
app click --text "Resume with guidance"

# 4. what the broker was sent
python3 - "$SOCK" "$JOB" "$GUIDANCE" "$EXPECT_GATE" <<'PY'
import json, socket, sys, time

sock, job, guidance, expect = sys.argv[1:5]


def ctl(op):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock + ".ctl")
    s.sendall((json.dumps({"op": op}) + "\n").encode())
    r = json.loads(s.makefile().readline())
    s.close()
    return r["result"]


def answers():
    return [c for c in ctl("commands") if c["type"] == "answer"]


def state():
    return next(j["state"] for j in ctl("jobs") if j["id"] == job)


if expect == "allowed":
    deadline = time.time() + 10
    while not answers() and time.time() < deadline:
        time.sleep(0.2)
    got = answers()
    want = {"job": job, "option": "resume_with_guidance", "source": "nostromo_app", "text": guidance}
    if len(got) != 1 or got[0]["data"] != want:
        sys.exit("expected exactly one answer %s, the broker has: %s" % (want, got))
    deadline = time.time() + 10
    while state() == "awaiting" and time.time() < deadline:
        time.sleep(0.2)
    if state() == "awaiting":
        sys.exit("the job is still awaiting after the answer")
else:
    time.sleep(3)   # long enough for a click that was going to send to have sent
    if answers():
        sys.exit("the gate is NOT live: a click without the QA switch sent %s" % answers())
    if state() != "awaiting":
        sys.exit("the job left AWAITING without an answer: %s" % state())
PY

# 5. and the panel agrees
if [ "$EXPECT_GATE" = allowed ]; then
  app wait "Resumes the worker with your written guidance as its next instruction." --gone --timeout 10   # the options left with AWAITING
else
  app expect "Resume with guidance"                                                                     # still held, nothing was sent
fi

echo "mother-hold ($EXPECT_GATE): PASS"
