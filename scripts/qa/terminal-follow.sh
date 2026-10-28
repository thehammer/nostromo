#!/usr/bin/env bash
# Live QA of agent follow in the Mac app (slice 3c) in the ISOLATED QA instance only: a worktree nostromd
# plus a com.hammer.nostromo.qa clone of the app, started and stopped by qa-instance.sh. Never the user's
# app, daemon or ~/.nostromo, and never real AWS (tests/fixtures/fake-aws behind a wrapper, fake ECS
# vocabulary). The QA daemon's sessions run the approvals fake CLI, so what the daemon delivers into a focus
# is visible as a collapsed 3e block in the transcript with no real agent.
#
#   scripts/qa/terminal-follow.sh [--skip-gate]
#
# (a) a local terminal: badge "Not shared"; invite the owning focus from the badge's popover; badge
#     "Followed by <focus>" (screenshots at a tiny split and in a second window); `seq 1 40`; the focus's
#     transcript gets ONE collapsed block "Output from local shell ..., 40 lines"; expanded it holds 1..40.
# (b) `printf 'DB_PASSWORD=hunter2fake\n'`: the block shows DB_PASSWORD=[redacted: secret-assignment].
# (c) Stop following; `echo AFTER-STOP`: no new block within 3 s.
# (d) invite again; `yes | head -200000`: badge "Paused, too much output"; Resume works.
# (e) select text, Send selection to the focus: exactly one "Selection from" block; the badge still says
#     "Not shared". app-control cannot select text, so this step is checked by hand (see the PR).
# (f) an agent's request for the fake ECS production shell, the sheet's follow box ticked: following starts
#     (audit follow_invited via "sheet"); the invite popover on that pane reads "Output from PRODUCTION will
#     be sent to ...".
# (g) the agent calls nostromo.request_follow: the decision sheet appears. With --no-synthetic (skipped by
#     --skip-gate) a synthesized click on Allow does nothing; in the relaxed instance Allow starts following.
# (h) the audit has follow_invited, delivery, follow_stopped, follow_paused, follow_resumed, selection_sent,
#     and none of the text that was delivered.
#
# Reading the app is by its accessibility tree: the badge's label is "Follow: <text>. <description>". The
# popover is a separate window; when app-control cannot reach its buttons the step says INCONCLUSIVE and the
# PR's manual list covers it. Needs a logged-in, awake display. Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE.
# Screenshots go to a private temp directory (printed; removed at the end unless KEEP=1).
# shellcheck disable=SC2329  # functions handed to poll / ok_if / the EXIT trap are not "called" by name
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"
qa_py="$here/lib/terminal_qa.py"
skip_gate=0
for a in "$@"; do [ "$a" = "--skip-gate" ] && skip_gate=1; done

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-follow-qa.XXXXXX")"
chmod 700 "$work"
echo "evidence directory: $work"
fails=0
inconclusive=0
root=""
sock=""
cleanup() {
  [ -z "$root" ] || "$instance" stop "$root" >/dev/null 2>&1 || true
  [ "${KEEP:-0}" = 1 ] || rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
inconc() { echo "INCONCLUSIVE: $*"; inconclusive=$((inconclusive + 1)); }

# The fake AWS (for the remote pane of step f): the same wrapper terminal-remote.sh uses.
aws_log="$work/aws.log"
: >"$aws_log"
cat >"$work/aws" <<EOF
#!/bin/sh
FAKE_AWS_MODE=ok FAKE_AWS_LOG="$aws_log" exec "$repo/tests/fixtures/fake-aws" "\$@"
EOF
chmod 700 "$work/aws"
export NOSTROMO_AWS_CLI="$work/aws"
export NOSTROMO_QA_ECS_FIXTURES="$repo/tests/fixtures/ecs"
export NOSTROMO_QA_REMOTE_SHELL_TIMEOUT_SECS=20

ctl() { "$app" --socket "$sock" "$@"; }
sctl() { ctl --sheet "$@"; }
shot() { ctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: screenshot $1 failed"; }
wshot() { ctl -w "$1" screenshot "$work/$2.png" >/dev/null 2>&1 && echo "screenshot: $work/$2.png" || echo "WARN: screenshot $2 failed"; }

start_instance() {
  local out
  out="$("$instance" start "$@")"
  echo "$out"
  root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
  [ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
  sock="$root/app-control.sock"
}
stop_instance() {
  if [ -n "$root" ]; then
    "$instance" stop "$root" || fail "isolation guard"
    root=""
  fi
}
require_visible() {
  local windows
  windows="$(ctl windows)"
  if grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows" || [ -z "$windows" ] || [ "$windows" = "[]" ]; then
    echo "INCONCLUSIVE: the QA window is not visible (display locked or asleep)"
    stop_instance
    echo "RESULT: INCONCLUSIVE"
    echo "Manual checklist: see the PR body."
    exit 3
  fi
}

# ── reading the app ──────────────────────────────────────────────────────────────────────────────────
tree_has() { ctl tree --depth 80 2>/dev/null | grep -q -- "$1"; }
sheet_has() { sctl tree --depth 40 2>/dev/null | grep -q -- "$1"; }
poll() { local tries="$1"; shift; for _ in $(seq 1 "$tries"); do "$@" && return 0; sleep 0.5; done; return 1; }
wait_tree() { poll 40 tree_has "$1"; }
wait_sheet() { poll 40 sheet_has "$1"; }
ok_if() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
ok_unless() { local label="$1"; shift; if "$@"; then fail "$label"; else pass "$label"; fi; }
screen_text() {
  ctl ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}
screen_has() { screen_text | grep -q -- "$1"; }
wait_screen() { poll 40 screen_has "$1"; }
# How many delivery blocks the transcript shows whose title contains $1 (a block is one tree line).
blocks() { ctl tree --depth 80 2>/dev/null | grep -c -- "$1" || true; }
audit_file() { echo "$root/home/.nostromo/audit/terminal.jsonl"; }
audit_has() { grep -q -- "$1" "$(audit_file)" 2>/dev/null; }

badge_is() { tree_has "Follow: $1"; }
wait_badge() { poll 40 badge_is "$1"; }

# Open the badge's popover and press $1 in it. The popover is its own window: when app-control cannot reach
# its button this returns 1 and the caller says INCONCLUSIVE.
popover_press() {
  ctl click --text "Follow:" >/dev/null 2>&1 || return 1
  sleep 0.7
  ctl click --text "$1" >/dev/null 2>&1 || return 1
}

terminal_id() {
  python3 -B "$qa_py" list-terminals "$root" mother 2>/dev/null | python3 -I -c 'import json,sys
try:
    ts = json.load(sys.stdin).get("terminals") or []
    print(ts[0]["terminal_id"] if ts else "")
except (ValueError, KeyError, IndexError):
    pass'
}

# ═════════════════════════════ (a)-(e), (h): a local terminal ═══════════════════════════════════════════

start_instance
require_visible
ctl activate >/dev/null 2>&1 || true
ctl click --text "Mother" >/dev/null 2>&1 || echo "note: could not click the Mother focus"
sleep 1

echo "== (a) a local terminal: Not shared, then invite =="
ctl key t --mod cmd >/dev/null
if wait_tree "TerminalPaneHostView"; then pass "Cmd-T opened a terminal"; else fail "no terminal pane"; fi
sleep 1.5
if wait_badge "Not shared"; then pass "the header says Not shared by default"; else fail "no Not shared badge (screenshot a0)"; fi
shot "a0-not-shared"
if popover_press "Invite"; then
  if wait_badge "Followed by"; then
    pass "Invite from the popover: the badge says Followed by <focus>"
  else
    fail "Invite pressed, but the badge never said Followed by"
  fi
else
  inconc "app-control could not press Invite in the popover: invite by hand (the PR's manual list)"
fi
shot "a1-followed"
tid="$(terminal_id)"
[ -n "$tid" ] || inconc "could not read the terminal id through nostromo.list_terminals"

if badge_is "Followed by"; then
  # Tiny split, then a second window: the badge is in both.
  pane_id="$(ctl tree --depth 80 2>/dev/null | grep -o 'terminal-[A-Za-z0-9-]*' | head -1 || true)"
  if [ -n "$pane_id" ] && python3 -B "$qa_py" set-pane-layout "$root" mother "{\"repl\": 0.97, \"$pane_id\": 0.03}" >/dev/null 2>&1; then
    sleep 1
    ok_if "the badge is still in the tree at a tiny split" tree_has "Follow: Followed by"
    shot "a2-tiny"
    python3 -B "$qa_py" set-pane-layout "$root" mother "{\"repl\": 0.5, \"$pane_id\": 0.5}" >/dev/null 2>&1 || true
  else
    inconc "could not shrink the split (no pane id or set_pane_layout refused)"
  fi
  ctl key n --mod ctrl,alt,cmd >/dev/null
  sleep 2
  if ctl -w 1 tree --depth 80 2>/dev/null | grep -q "Follow: Followed by"; then
    pass "the second window's header says Followed by too"
    wshot 1 "a3-mirror"
  else
    fail "the second window shows no Followed by badge"
  fi

  echo "== (a) seq 1 40: one collapsed block =="
  ctl -w 0 type $'seq 1 40\r' >/dev/null 2>&1 || ctl type $'seq 1 40\r' >/dev/null
  if poll 60 tree_has "Output from local shell"; then
    pass "a delivery block appeared in the focus's transcript"
    sleep 6   # the delivery window; a second block would show up by now
    n="$(blocks "Output from local shell")"
    if [ "$n" = 1 ]; then pass "exactly one block"; else fail "$n blocks, wanted exactly one"; fi
    ok_if "its title says 40 lines" tree_has "40 lines"
    ctl click --text "Output from local shell" >/dev/null 2>&1 || echo "note: could not expand the block"
    sleep 1
    ok_if "expanded, it holds line 40" tree_has "^40$|[[:space:]]40$|40\\\\n"
    shot "a4-block-expanded"
  else
    fail "no delivery block after seq 1 40 (screenshot a5)"
    shot "a5-no-block"
  fi

  echo "== (b) a secret is redacted in the block =="
  ctl type $'printf \'DB_PASSWORD=hunter2fake\\n\'\r' >/dev/null
  if poll 60 tree_has "secret-assignment"; then
    pass "the block shows [redacted: secret-assignment]"
    ok_unless "the secret itself is not in the app's tree" tree_has "hunter2fake\\n\\|=hunter2fake$"
  else
    fail "no [redacted: secret-assignment] marker"
  fi

  echo "== (c) Stop following takes effect at once =="
  before="$(blocks "Output from local shell")"
  if popover_press "Stop following"; then
    ok_unless "the badge no longer says Followed by" badge_is "Followed by"
    ctl type $'echo AFTER-STOP\r' >/dev/null
    wait_screen "AFTER-STOP" || true
    sleep 3
    after="$(blocks "Output from local shell")"
    if [ "$after" = "$before" ]; then pass "no new block within 3 s of the output"; else fail "a block appeared after Stop ($before -> $after)"; fi
  else
    inconc "app-control could not press Stop following"
  fi

  echo "== (d) a flood pauses; Resume works =="
  if popover_press "Invite"; then
    wait_badge "Followed by" || true
    ctl type $'yes | head -200000\r' >/dev/null
    if poll 80 badge_is "Paused, too much output"; then
      pass "the badge says Paused, too much output"
      shot "d1-paused"
      if popover_press "Resume"; then
        if poll 20 badge_is "Followed by"; then pass "Resume: Followed by again"; else fail "still paused after Resume"; fi
      else
        inconc "app-control could not press Resume"
      fi
    else
      fail "no pause after 200000 lines"
    fi
    popover_press "Stop following" || true
  else
    inconc "could not invite again for the flood step"
  fi

  echo "== (e) Send selection: one block, following does not start =="
  ok_if "the badge says Not shared again" wait_badge "Not shared"
  ctl type $'echo SEND-THIS-LINE\r' >/dev/null
  wait_screen "SEND-THIS-LINE" || true
  # app-control has no drag, triple-click or right-click, so it cannot select text or open the context
  # menu. The step checks what it can (following stayed off, nothing was delivered by itself) and leaves
  # the selection itself to the PR's manual list.
  sleep 3
  ok_if "following stayed off after Stop (Not shared)" badge_is "Not shared"
  ok_unless "no Selection from block appeared on its own" tree_has "Selection from"
  inconc "Send selection needs a text selection and a context menu app-control cannot make: do it by hand (the PR's manual list), then check for one Selection from block and Not shared"
else
  inconc "not following, so the rest of (a)-(e) was skipped"
fi

echo "== (h) the audit =="
for event in follow_invited delivery follow_stopped follow_paused follow_resumed selection_sent; do
  if audit_has "\"event\":\"$event\"" || audit_has "\"event\": \"$event\""; then
    pass "audit has $event"
  elif [ "$event" = selection_sent ]; then
    inconc "audit has no selection_sent (step e is done by hand)"
  else
    fail "audit has no $event"
  fi
done
for secret in hunter2fake SEND-THIS-LINE AFTER-STOP DB_PASSWORD; do
  ok_unless "the audit never holds delivered text ($secret)" audit_has "$secret"
done

# ═════════════════════════════ (f) the sheet's follow box, then the PRODUCTION warning ══════════════════

echo "== (f) agent's remote request, follow box ticked =="
(python3 -B "$qa_py" request-remote-shell "$root" mother admin-portal production scheduler shell "follow QA" 60 \
  >"$work/f1.json" 2>&1 || true) &
agent_pid=$!
if wait_sheet "Connect to PRODUCTION"; then
  ok_if "the sheet has the follow box" sheet_has "follow this shell"
  ok_unless "the box is not ticked by default" sheet_has "follow this shell.*checked"
  sctl click --text "follow this shell" >/dev/null 2>&1 || inconc "could not tick the follow box"
  ctl key tab >/dev/null
  ctl key space >/dev/null
  wait "$agent_pid" || true
  if wait_screen 'remote\$'; then
    pass "connected"
    if poll 20 badge_is "Followed by"; then pass "the new pane is followed from the start"; else fail "the ticked box did not start following"; fi
    if audit_has '"via":"sheet"' || audit_has '"via": "sheet"'; then pass "audit: follow_invited via sheet"; else fail "audit has no via sheet"; fi
    if popover_press "Move to"; then
      ok_if "the popover warns: Output from PRODUCTION will be sent to" tree_has "Output from PRODUCTION will be sent to"
      shot "f1-production-warning"
    else
      inconc "app-control could not open the popover's Move to… form"
    fi
  else
    fail "the remote shell never connected"
  fi
else
  fail "no sheet for the agent's remote request"
  wait "$agent_pid" || true
fi

# ═════════════════════════════ (g) nostromo.request_follow ═════════════════════════════════════════════

echo "== (g) request_follow raises a decision sheet; Allow starts following =="
popover_press "Stop following" || true
rtid="$(terminal_id)"
if [ -n "$rtid" ]; then
  (python3 -B "$qa_py" request-follow "$root" mother "$rtid" "QA wants the output" 60 >"$work/g1.json" 2>&1 || true) &
  agent_pid=$!
  if poll 40 tree_has "follow"; then
    pass "a request appeared in the app"
    shot "g1-request"
    ctl click --text "Allow" >/dev/null 2>&1 || inconc "could not click Allow"
    wait "$agent_pid" || true
    if poll 20 badge_is "Followed by"; then pass "Allow started following"; else fail "Allow did not start following"; fi
  else
    fail "no follow request in the app"
    wait "$agent_pid" || true
  fi
else
  inconc "no terminal id for the request_follow step"
fi
stop_instance

if [ "$skip_gate" = 0 ]; then
  echo "== (g) gate: --no-synthetic =="
  start_instance --no-synthetic
  require_visible
  ctl activate >/dev/null 2>&1 || true
  ctl click --text "Mother" >/dev/null 2>&1 || true
  ctl key t --mod cmd >/dev/null
  wait_tree "TerminalPaneHostView" || fail "no terminal in the gate run"
  sleep 1.5
  gtid="$(terminal_id)"
  if [ -n "$gtid" ]; then
    (python3 -B "$qa_py" request-follow "$root" mother "$gtid" "QA gate" 15 >"$work/g2.json" 2>&1 || true) &
    agent_pid=$!
    if poll 40 tree_has "follow"; then
      ctl click --text "Allow" >/dev/null 2>&1 || echo "note: the click could not be delivered"
      sleep 1.5
      ok_unless "a synthesized click on Allow did not start following" badge_is "Followed by"
      shot "g2-refused"
    else
      fail "no follow request in the gate run"
    fi
    wait "$agent_pid" || true
  else
    inconc "no terminal id in the gate run"
  fi
  stop_instance
fi

if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL"
elif [ "$inconclusive" -gt 0 ]; then
  echo "RESULT: PASS with $inconclusive INCONCLUSIVE check(s)"
else
  echo "RESULT: PASS"
fi
[ "$fails" -eq 0 ] || exit 1
[ "$inconclusive" -eq 0 ] || exit 3
exit 0
