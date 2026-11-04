# shellcheck shell=bash
# Shared by the terminal QA scripts. Sourced, not executed.
#
# A freshly launched QA window is briefly invisible (alpha 0) while the app places it, so ONE look right after
# `start` reports "display locked" on a perfectly good display. qa_wait_visible re-reads the caller's
# `ctl windows` for up to 45 s (90 x 0.5 s) and returns 0 once a window is listed and none is hidden, 1 if it
# never is. QA_SLEEP_SCALE=0 (the self-tests) shortens it to 2 tries with no sleep.
#
# Callers must define `ctl`. If NO `ctl windows` call ever succeeds (the app or its socket is dead) it returns 2
# with a message, and callers print FAIL, not INCONCLUSIVE: the display is only suspect when the app answered.
qa_windows_hidden() {
  grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$1" || [ -z "$1" ] || [ "$1" = "[]" ]
}

qa_wait_visible() {
  local windows tries=90 answered=0
  [ "${QA_SLEEP_SCALE:-1}" != 0 ] || tries=2
  for _ in $(seq 1 "$tries"); do
    if windows="$(ctl windows 2>/dev/null)"; then answered=1; else windows=""; fi
    qa_windows_hidden "$windows" || return 0
    [ "${QA_SLEEP_SCALE:-1}" = 0 ] || sleep 0.5
  done
  if [ "$answered" = 0 ]; then
    echo "FAIL: app-control not answering (the QA app or its socket is dead)"
    return 2
  fi
  return 1
}

# ── Refusals that run before a script does anything (exit 2, nothing started, nothing printed on stdout) ──
# A script that promises no tokens and drives only the isolated QA instance calls these three right after
# sourcing this file. Each fails CLOSED: anything it cannot check is a refusal.

# The marker kinds a QA run leaves behind (the same list the isolation guard and approvals-card.sh use).
QA_MARKER_PATTERN='FIXTURE:|com\.hammer\.nostromo\.qa|nostromo-qa-|cody-qa-|qa-approvals'
QA_ROOT_MARKER=".nostromo-qa-root"

# NOSTROMO_QA_CLAUDE_BIN makes qa-instance.sh hand a real CLI to the QA daemon: tokens would be spent.
qa_refuse_real_model() {
  [ -z "${NOSTROMO_QA_CLAUDE_BIN:-}" ] && return 0
  echo "REFUSING TO RUN: NOSTROMO_QA_CLAUDE_BIN is set, so the QA session would run a real model and spend tokens." >&2
  echo "This script uses the fake CLI only. Unset NOSTROMO_QA_CLAUDE_BIN (it is for tracker-discoverability.sh)." >&2
  exit 2
}

# A real focuses.json that already carries a QA marker is the leftover of an earlier breach (the QA app once
# wrote into the user's own ~/.nostromo): starting on top of it would compound it. Refused by file name only
# (never the content). A file that cannot be read, or a missing HOME, is a refusal too.
qa_refuse_dirty_real_home() {
  local real_focuses rc=1
  if [ -z "${HOME:-}" ]; then
    echo "REFUSING TO RUN: HOME is not set, so the real ~/.nostromo cannot be checked for QA leftovers." >&2
    exit 2
  fi
  real_focuses="$HOME/.nostromo/focuses.json"
  [ -e "$real_focuses" ] || return 0
  grep -qE "$QA_MARKER_PATTERN" "$real_focuses" 2>/dev/null && rc=0 || rc=$?
  [ "$rc" = 1 ] && return 0
  if [ "$rc" = 0 ]; then
    echo "REFUSING TO RUN: $real_focuses already carries a QA marker (FIXTURE:, the QA bundle id, a QA root path, cody-qa-, qa-approvals)." >&2
    echo "A QA run once wrote into your real ~/.nostromo. Remove the QA entries from that file, then run again." >&2
  else
    echo "REFUSING TO RUN: $real_focuses could not be read, so it cannot be checked for QA leftovers." >&2
  fi
  exit 2
}

# A control socket that is not inside a QA root is the user's own app: never talk to it. The QA instance
# this script starts gets its own socket, so an inherited one is dropped once it has been shown to be a QA one.
qa_refuse_foreign_socket() {
  [ -n "${NOSTROMO_APP_CONTROL_SOCKET:-}" ] || return 0
  if [ ! -f "$(dirname "$NOSTROMO_APP_CONTROL_SOCKET")/$QA_ROOT_MARKER" ]; then
    echo "REFUSING TO RUN: NOSTROMO_APP_CONTROL_SOCKET points outside a QA root (no $QA_ROOT_MARKER beside it)." >&2
    echo "This script only talks to the socket of the QA instance it starts itself. Unset the variable." >&2
    exit 2
  fi
  unset NOSTROMO_APP_CONTROL_SOCKET
}

# All three, in the order a script should run them.
qa_refuse_unsafe_start() {
  qa_refuse_real_model
  qa_refuse_dirty_real_home
  qa_refuse_foreign_socket
}
