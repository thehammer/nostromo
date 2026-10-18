#!/usr/bin/env bash
# Proves the isolated QA instance works: start it, confirm a window rendered, confirm the user's
# app pid is unchanged, stop it (which runs the isolation guard). Records the synthetic-input mode.
#
#   scripts/qa/approvals-qa-smoke.sh [--no-synthetic]
#
# Exits 0 PASS, 1 FAIL, 3 INCONCLUSIVE (display locked/asleep: window not visible).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
instance="$here/qa-instance.sh"
app="$repo/bin/nostromo-app"
mode="synthetic input ON"
for a in "$@"; do [ "$a" = "--no-synthetic" ] && mode="synthetic input OFF (--no-synthetic)"; done
echo "mode: $mode"

# Pids of running Nostromo apps, skipping any whose command line is under $1 (the QA clone).
user_app_pids() {
  local pid
  for pid in $(pgrep -f '/Nostromo.app/Contents/MacOS/Nostromo' || true); do
    if [ -z "${1:-}" ] || ! ps -o command= -p "$pid" | grep -qF -- "$1"; then echo "$pid"; fi
  done | sort -n | tr '\n' ' '
}
before_pids="$(user_app_pids)"

out="$("$instance" start "$@")"
echo "$out"
root="$(sed -n 's/^QA_ROOT=//p' <<<"$out")"
[ -n "$root" ] || { echo "FAIL: no QA_ROOT printed"; exit 1; }
stopped=0
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { [ "$stopped" = 1 ] || KEEP="${KEEP:-}" "$instance" stop "$root" || true; }
trap cleanup EXIT
sock="$root/app-control.sock"

verdict=PASS
windows="$("$app" --socket "$sock" windows)"
echo "$windows"
if grep -Eq '"(alpha)": *0([^.0-9]|$)|"visible": *false' <<<"$windows"; then
  verdict=INCONCLUSIVE
  echo "INCONCLUSIVE: window not visible (display locked or asleep)"
elif [ -z "$windows" ] || [ "$windows" = "[]" ]; then
  verdict=FAIL; echo "FAIL: no window listed"
fi
shot="${TMPDIR:-/tmp}/nostromo-qa-smoke-$$.png"
if "$app" --socket "$sock" screenshot "$shot" >/dev/null 2>&1; then echo "screenshot: $shot"; else echo "WARN: screenshot failed"; fi

# The user's app pids must be the same set as before (the QA clone's own pid is under $root).
after_pids="$(user_app_pids "$root")"
echo "user app pids before: [$before_pids]"
echo "user app pids after (QA clone excluded): [$after_pids]"
for p in $before_pids; do
  case " $after_pids " in *" $p "*) ;; *) verdict=FAIL; echo "FAIL: user app pid $p is gone" ;; esac
done

stopped=1
if "$instance" stop "$root"; then :; else verdict=FAIL; echo "FAIL: isolation guard"; fi
echo "RESULT: $verdict ($mode)"
case "$verdict" in PASS) exit 0 ;; INCONCLUSIVE) exit 3 ;; *) exit 1 ;; esac
