#!/usr/bin/env bash
# Live QA of the remote-shell confirmation flow (slice 2c) in the ISOLATED QA instance only: a worktree
# nostromd plus a com.hammer.nostromo.qa clone of the app, started and stopped by qa-instance.sh. Never the
# user's app, daemon or ~/.nostromo, and never real AWS: the daemon's `aws` is tests/fixtures/fake-aws behind
# a tiny wrapper that reads its mode from a file, and its vocabulary is tests/fixtures/ecs (fake clusters).
#
#   scripts/qa/terminal-remote.sh [--skip-gate]
#
# (a) agent request: a Python JSON-RPC client on the QA daemon's MCP socket (Hello pty_id = a built-in focus
#     tag) calls nostromo.request_remote_shell. The "Connect to PRODUCTION" sheet appears over the key window
#     naming the reason, and the fake AWS log is still empty. Return cancels (the tool returns `cancelled`);
#     Escape cancels; no answer returns `timeout` (the QA daemon waits 10 s); Tab then Space connects:
#     "Connecting to production ..." then the fake shell's `remote$` prompt; `exit` closes the pane, and a toast
#     "... closed: remote session ended, exit 0" with Reconnect appears; Reconnect shows the sheet again, now
#     without a "Requested by" line (it is the user's own request).
#     Each agent request comes from a different focus: a denial starts a per-focus cooldown in the daemon.
# (b) user menu: Shift-Cmd-T opens the picker, preselected on the project of the focus, production, its
#     default service and `shell`; Submit shows the same sheet without "Requested by".
#     The popups' items are menu windows app-control cannot reach, so picking staging is in the PR's manual list.
# (c) failures: FAKE_AWS_MODE=expired, then plugin_missing: Connect shows the failure sheet with the reason and
#     the remedy (`aws sso login --sso-session ...`, `brew install --cask session-manager-plugin`) and no
#     TerminalPaneHostView is left in the tree.
# (d) gate (--no-synthetic instance; skipped with --skip-gate): a synthesized click on Connect does nothing, the
#     fake AWS log stays empty, the QA daemon's audit has `refused` with channel app_control and op connect, and
#     the agent's call later returns `timeout`.
#
# Needs a logged-in, awake display (the clone's windows must be on screen). Exits 0 PASS, 1 FAIL,
# 3 INCONCLUSIVE (locked or asleep display, or a check this machine cannot read). Screenshots go to a private
# temp directory (printed; removed at the end unless KEEP=1).
# shellcheck disable=SC2329  # functions handed to poll / ok_if / the EXIT trap are not "called" by name
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"
skip_gate=0
for a in "$@"; do [ "$a" = "--skip-gate" ] && skip_gate=1; done

work="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-remote-qa.XXXXXX")"
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

# ── the fake AWS: a wrapper whose mode is read from a file on every call ─────────────────────────────
mode_file="$work/aws-mode"
aws_log="$work/aws.log"
: >"$aws_log"
echo ok >"$mode_file"
cat >"$work/aws" <<EOF
#!/bin/sh
FAKE_AWS_MODE="\$(cat "$mode_file")" FAKE_AWS_LOG="$aws_log" exec "$repo/tests/fixtures/fake-aws" "\$@"
EOF
chmod 700 "$work/aws"
set_aws_mode() { echo "$1" >"$mode_file"; }
# The daemon reads these when it starts (qa-instance.sh passes them through / seeds its config.toml).
export NOSTROMO_AWS_CLI="$work/aws"
export NOSTROMO_QA_ECS_FIXTURES="$repo/tests/fixtures/ecs"
export NOSTROMO_QA_REMOTE_SHELL_TIMEOUT_SECS=10

ctl() { "$app" --socket "$sock" "$@"; }
sctl() { ctl --sheet "$@"; }

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
    echo "Manual checklist: see the PR body (staging first)."
    exit 3
  fi
}

shot() { ctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: screenshot $1 failed"; }
sheet_shot() { sctl screenshot "$work/$1.png" >/dev/null 2>&1 && echo "screenshot: $work/$1.png" || echo "WARN: sheet screenshot $1 failed"; }

# ── reading the app ──────────────────────────────────────────────────────────────────────────────────
panes() { ctl tree --depth 60 2>/dev/null | grep -c 'TerminalPaneHostView' || true; }
tree_has() { ctl tree --depth 60 2>/dev/null | grep -q -- "$1"; }
sheet_has() { sctl tree --depth 40 2>/dev/null | grep -q -- "$1"; }
sheet_up() { sctl tree --depth 3 >/dev/null 2>&1; }

poll() { # poll TRIES COMMAND...: true once COMMAND succeeds
  local tries="$1"
  shift
  for _ in $(seq 1 "$tries"); do
    "$@" && return 0
    sleep 0.5
  done
  return 1
}
sheet_down() { ! sheet_up; }
wait_sheet() { poll 40 sheet_has "$1"; }
wait_tree() { poll 40 tree_has "$1"; }
wait_panes_eq() { # wait_panes_eq N
  local n
  for _ in $(seq 1 40); do
    n="$(panes)"
    [ "$n" -eq "$1" ] && return 0
    sleep 0.5
  done
  return 1
}
aws_calls() { wc -l <"$aws_log" | tr -d ' '; }
aws_untouched() { [ "$(aws_calls)" = 0 ]; }
no_panes() { [ "$(panes)" = 0 ]; }

ok_if() { # ok_if LABEL COMMAND...: PASS when the command succeeds
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}
ok_unless() { # ok_unless LABEL COMMAND...: PASS when the command fails
  local label="$1"
  shift
  if "$@"; then fail "$label"; else pass "$label"; fi
}

# The terminal's screen text (accessibility value): only a QA build that relaxes the synthetic gate has it.
screen_text() {
  ctl ax NostromoTerminalView 2>/dev/null | python3 -I -c 'import json,sys
try:
    print(json.load(sys.stdin).get("value") or "")
except ValueError:
    pass'
}
screen_has() { screen_text | grep -q -- "$1"; }
wait_screen() { poll 40 screen_has "$1"; }

# ── an agent's request, run in the background; its result lands in a file ───────────────────────────────
agent_request() { # agent_request FOCUS RESULT_FILE REASON
  (python3 -B "$here/lib/terminal_qa.py" request-remote-shell "$root" "$1" admin-portal production scheduler shell "$3" 60 \
    >"$2" 2>&1 || true) &
  agent_pid=$!
}
agent_outcome() { # the result's `outcome` or `error` word, once the call has returned
  python3 -I -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("error") or d.get("outcome") or "")
except (OSError, ValueError):
    print("")' "$1"
}
expect_outcome() { # expect_outcome FILE WANT LABEL
  local got
  got="$(agent_outcome "$1")"
  if [ "$got" = "$2" ]; then pass "$3: the agent's tool returned '$2'"; else fail "$3: the agent's tool returned '$got' ($(cat "$1" 2>/dev/null)), wanted '$2'"; fi
}
# The first focus tags are built-ins; each denial is a per-focus cooldown, so each request uses its own.
reason="Check stuck jobs on the scheduler"

# ═════════════════════════════ (a) agent request, (b) menu, (c) failures ═════════════════════════════════

start_instance
require_visible
ctl activate >/dev/null 2>&1 || true
ctl click --text "Mother" >/dev/null 2>&1 || echo "note: could not click the Mother focus"
sleep 1

echo "== (a) the sheet for an agent's request =="
agent_request perri "$work/a1.json" "$reason"
if wait_sheet "Connect to PRODUCTION"; then
  pass "the sheet appears and says Connect to PRODUCTION"
  ok_if "it names the agent's reason" sheet_has "$reason"
  ok_if "it has a Requested by line" sheet_has "Requested by"
  ok_if "the fake AWS log is empty before Connect" aws_untouched
  sheet_shot "a1-sheet"
  ctl key return >/dev/null
  wait "$agent_pid" || true
  expect_outcome "$work/a1.json" cancelled "Return"
  ok_if "Return cancelled: the sheet is gone" sheet_down
else
  fail "no sheet for the agent's request (screenshot a1)"
  shot "a1-missing"
  wait "$agent_pid" || true
fi

agent_request fred "$work/a2.json" "$reason"
if wait_sheet "Connect to PRODUCTION"; then
  ctl key escape >/dev/null
  wait "$agent_pid" || true
  expect_outcome "$work/a2.json" cancelled "Escape"
else
  fail "no sheet for the second request"
  wait "$agent_pid" || true
fi

agent_request teri "$work/a3.json" "$reason"
if wait_sheet "Connect to PRODUCTION"; then
  wait "$agent_pid" || true   # nobody answers: the QA daemon gives up after 10 s
  expect_outcome "$work/a3.json" timeout "no answer"
  if poll 20 sheet_down; then pass "the timeout closed the sheet"; else fail "the sheet is still up after the daemon timed out"; fi
  ok_if "nothing opened for Cancel, Escape or the timeout" no_panes
else
  fail "no sheet for the third request"
  wait "$agent_pid" || true
fi

agent_request mother "$work/a4.json" "$reason"
if wait_sheet "Connect to PRODUCTION"; then
  ctl key tab >/dev/null
  ctl key space >/dev/null
  if poll 20 tree_has "Connecting to production"; then
    pass "the pane says Connecting to production while it connects"
    shot "a4-connecting"
  else
    inconc "the connecting state was gone before it could be read (the fake connects at once)"
  fi
  wait "$agent_pid" || true
  expect_outcome "$work/a4.json" connected "Tab then Space"
  if wait_screen 'remote\$'; then pass "the fake shell's prompt is on screen"; else fail "no remote\$ prompt on the terminal"; fi
  shot "a4-running"
  ctl type $'exit\r' >/dev/null
  if wait_panes_eq 0; then pass "exit closed the pane"; else fail "the pane is still there after exit"; fi
  if wait_tree "remote session ended"; then
    pass "the closed toast names the reason"
    ok_if "the toast has the exit status" tree_has "exit 0"
    ok_if "the toast offers Reconnect" tree_has "Reconnect"
    shot "a4-closed-toast"
    ctl click --text "Reconnect" >/dev/null 2>&1 || fail "could not click Reconnect"
    if wait_sheet "Connect to PRODUCTION"; then
      pass "Reconnect shows the sheet again"
      ok_unless "it has no Requested by line (the user's own request)" sheet_has "Requested by"
      ok_if "nothing reconnected by itself" no_panes
      ctl key return >/dev/null
    else
      fail "Reconnect did not show the sheet"
    fi
  else
    fail "no closed toast (screenshot a4-no-toast)"
    shot "a4-no-toast"
  fi
else
  fail "no sheet for the fourth request"
  wait "$agent_pid" || true
fi

echo "== (b) Terminal > New Remote Shell... =="
ctl key t --mod cmd,shift >/dev/null
if poll 40 sheet_has "New Remote Shell"; then
  pass "Shift-Cmd-T opens the picker"
  sheet_shot "b1-picker"
  ctl key return >/dev/null   # Submit
  if wait_sheet "Connect to PRODUCTION"; then
    pass "Submit leads to the confirmation sheet"
    ok_unless "it has no Requested by line" sheet_has "Requested by"
    sheet_shot "b2-sheet"
  else
    fail "Submit did not lead to the confirmation sheet"
  fi
else
  fail "Shift-Cmd-T did not open the picker"
fi

echo "== (c) failures =="
fail_case() { # fail_case MODE REASON_TEXT REMEDY_TEXT SHOT
  set_aws_mode "$1"
  if ! sheet_has "Connect to PRODUCTION"; then
    ctl key t --mod cmd,shift >/dev/null
    poll 40 sheet_has "New Remote Shell" || { fail "$1: no picker"; return; }
    ctl key return >/dev/null
    wait_sheet "Connect to PRODUCTION" || { fail "$1: no confirmation sheet"; return; }
  fi
  ctl key tab >/dev/null
  ctl key space >/dev/null
  if poll 60 sheet_has "Couldn't connect to PRODUCTION"; then
    pass "$1: the failure sheet appears"
    ok_if "$1: it says '$2'" sheet_has "$2"
    ok_if "$1: it shows the remedy '$3'" sheet_has "$3"
    sheet_shot "$4"
    ctl key return >/dev/null   # OK
    poll 20 sheet_down || fail "$1: the failure sheet did not close"
    ok_if "$1: no TerminalPaneHostView is left" no_panes
  else
    fail "$1: no failure sheet"
    shot "$4-missing"
  fi
}
fail_case expired "AWS SSO session expired" "aws sso login --sso-session fake-sso-session" "c1-expired"
fail_case plugin_missing "Session Manager plugin" "brew install --cask session-manager-plugin" "c2-plugin-missing"
set_aws_mode ok

stop_instance

# ═════════════════════════════ (d) the gate ═════════════════════════════════════════════════════════════

if [ "$skip_gate" = 0 ]; then
  echo "== (d) gate: --no-synthetic =="
  : >"$aws_log"
  start_instance --no-synthetic
  require_visible
  ctl activate >/dev/null 2>&1 || true
  agent_request mother "$work/d1.json" "$reason"
  if wait_sheet "Connect to PRODUCTION"; then
    sctl click --text "ConnectButton" >/dev/null 2>&1 || echo "note: the click could not be delivered"
    sleep 1.5
    ok_if "a synthesized click on Connect left the sheet up" sheet_has "Connect to PRODUCTION"
    ok_if "the fake AWS log is still empty" aws_untouched
    ok_if "no pane opened" no_panes
    sheet_shot "d1-refused"
    audit="$root/home/.nostromo/audit/terminal.jsonl"
    if [ -f "$audit" ] && grep '"refused"' "$audit" | grep 'app_control' | grep -q 'connect'; then
      pass "the daemon audit has refused {channel: app_control, op: connect}"
    else
      fail "no refused/app_control/connect line in $audit"
    fi
    wait "$agent_pid" || true   # nobody answers: the daemon gives up after 10 s
    expect_outcome "$work/d1.json" timeout "the gate"
  else
    fail "no sheet in the gate run"
    wait "$agent_pid" || true
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
