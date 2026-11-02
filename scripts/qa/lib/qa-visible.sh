# shellcheck shell=bash
# Shared by the terminal QA scripts. Sourced, not executed.
#
# A freshly launched QA window is briefly invisible (alpha 0) while the app places it, so ONE look right after
# `start` reports "display locked" on a perfectly good display. qa_wait_visible re-reads the caller's
# `ctl windows` for up to 45 s (90 x 0.5 s) and returns 0 once a window is listed and none is hidden, 1 if it
# never is. QA_SLEEP_SCALE=0 (the self-tests) shortens it to 2 tries with no sleep.
#
# Callers must define `ctl`. background-wake.sh and approvals-card.sh carry the same loop inline.
qa_windows_hidden() {
  grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$1" || [ -z "$1" ] || [ "$1" = "[]" ]
}

qa_wait_visible() {
  local windows tries=90
  [ "${QA_SLEEP_SCALE:-1}" != 0 ] || tries=2
  for _ in $(seq 1 "$tries"); do
    windows="$(ctl windows 2>/dev/null)" || windows=""
    qa_windows_hidden "$windows" || return 0
    [ "${QA_SLEEP_SCALE:-1}" = 0 ] || sleep 0.5
  done
  return 1
}
