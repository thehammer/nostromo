#!/usr/bin/env bash
# Mother gate: actionlint over the GitHub workflows (advisory).
# Exit 0 when clean, non-zero on findings, 2 when actionlint is not installed.
set -u

tool=""
if command -v actionlint >/dev/null 2>&1; then
  tool="$(command -v actionlint)"
else
  # MOTHER_GATE_FALLBACK_DIRS exists so tests can hide the host's real tools.
  for dir in ${MOTHER_GATE_FALLBACK_DIRS-/opt/homebrew/bin /usr/local/bin}; do
    if [ -x "$dir/actionlint" ]; then tool="$dir/actionlint"; break; fi
  done
fi
if [ -z "$tool" ]; then
  echo "actionlint not installed (brew install actionlint)"
  exit 2
fi

cd "$(dirname "$0")/../.." || exit 2
shopt -s nullglob
files=(.github/workflows/*.yml)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no workflows"
  exit 0
fi
exec "$tool" "${files[@]}"
