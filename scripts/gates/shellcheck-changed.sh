#!/usr/bin/env bash
# Mother gate: shellcheck the shell files changed on this branch.
# Reads MOTHER_GATE_CHANGED_FILES (newline-separated paths). Exit 0 when nothing
# to check or clean, 1 on findings, 2 when shellcheck is not installed.
set -u

tool=""
if command -v shellcheck >/dev/null 2>&1; then
  tool="$(command -v shellcheck)"
else
  # MOTHER_GATE_FALLBACK_DIRS exists so tests can hide the host's real tools.
  for dir in ${MOTHER_GATE_FALLBACK_DIRS-/opt/homebrew/bin /usr/local/bin}; do
    if [ -x "$dir/shellcheck" ]; then tool="$dir/shellcheck"; break; fi
  done
fi
if [ -z "$tool" ]; then
  echo "shellcheck not installed (brew install shellcheck)"
  exit 2
fi

files=()
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case "$f" in
    *.sh) files+=("$f"); continue ;;
  esac
  first=""
  IFS= read -r first < "$f" || true
  case "$first" in
    '#!'*bash* | '#!'*/sh | '#!'*'env sh'* | '#!'*'/sh '*) files+=("$f") ;;
  esac
done <<< "${MOTHER_GATE_CHANGED_FILES:-}"

if [ "${#files[@]}" -eq 0 ]; then
  echo "no shell files changed"
  exit 0
fi

echo "shellcheck -x on:"
printf '  %s\n' "${files[@]}"
exec "$tool" -x "${files[@]}"
