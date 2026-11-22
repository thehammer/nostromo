#!/usr/bin/env bash
# Run unittest suite directories in parallel and print each unit's output whole, in the order
# given, so a log is never interleaved. Usage: scripts/python-test-parallel.sh <suite-dir>...
#
# A suite directory with several test*.py files is split into one unit per file
# (`discover -s <dir> -p <file>`): the files are independent, and a directory such as
# scripts/qa/tests would otherwise be one 15-minute unit. PY_SPLIT=0 keeps a directory whole.
# PY_JOBS sets the worker count (default 4). Exit 1 if any unit fails. Every unit is the same
# `python3 -m unittest discover -s <dir> -v` that `make python-test` runs serially, restricted
# to a file; the files of a directory together are exactly what `discover` finds there.
set -u
jobs="${PY_JOBS:-4}"
[ "$#" -gt 0 ] || { echo "usage: $0 <suite-dir>..." >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/tmp}/pytest-par.XXXXXX")"
trap 'rm -rf "$out"' EXIT

units=()
for dir in "$@"; do
  files=()
  for f in "$dir"/test*.py; do [ -f "$f" ] && files+=("$(basename "$f")"); done
  if [ "${PY_SPLIT:-1}" = 0 ] || [ "${#files[@]}" -le 1 ]; then
    units+=("$dir|test*.py")
  else
    for f in "${files[@]}"; do units+=("$dir|$f"); done
  fi
done

# shellcheck disable=SC2329  # invoked through `bash -c` by xargs below
run_one() {
  local unit="$1" out="$2" dir pattern n start rc
  dir="${unit%%|*}"
  pattern="${unit#*|}"
  n="$(printf '%s' "$dir/$pattern" | tr '/*' '__')"
  start=$(date +%s)
  python3 -m unittest discover -s "$dir" -p "$pattern" -v >"$out/$n.log" 2>&1
  rc=$?
  echo "$rc $(( $(date +%s) - start ))" >"$out/$n.rc"
}
export -f run_one
# shellcheck disable=SC2016  # the single quotes are deliberate: the child bash expands $1 and $2
printf '%s\n' "${units[@]}" | xargs -P "$jobs" -I{} bash -c 'run_one "$1" "$2"' _ {} "$out"

status=0
for unit in "${units[@]}"; do
  dir="${unit%%|*}"; pattern="${unit#*|}"
  n="$(printf '%s' "$dir/$pattern" | tr '/*' '__')"
  echo "=== $dir ($pattern)"
  cat "$out/$n.log"
done
echo "=== summary"
for unit in "${units[@]}"; do
  dir="${unit%%|*}"; pattern="${unit#*|}"
  n="$(printf '%s' "$dir/$pattern" | tr '/*' '__')"
  # a unit whose wrapper died before writing its .rc file must read as failed, never inherit the last unit's result
  rc=missing; secs='?'
  read -r rc secs <"$out/$n.rc" 2>/dev/null || { rc=missing; secs='?'; }
  printf '%4ss  %s  %s (%s)\n' "$secs" "$([ "$rc" = 0 ] && echo ok || echo FAILED)" "$dir" "$pattern"
  [ "$rc" = 0 ] || status=1
done
exit "$status"
