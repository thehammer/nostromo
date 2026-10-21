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
unchecked=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # `git diff --name-only` quotes odd paths (non-ASCII, quotes, tabs) as "...": such a name can never be
  # opened with -f, so it would silently pass. Count it and fail loudly at the end instead.
  case "$f" in
    \"*\") unchecked=$((unchecked + 1)); continue ;;
  esac
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) files+=("$f"); continue ;;
  esac
  first=""
  IFS= read -r first < "$f" || true
  case "$first" in
    '#!'*bash* | '#!'*/sh | '#!'*'env sh'* | '#!'*'/sh '*) files+=("$f") ;;
  esac
done <<< "${MOTHER_GATE_CHANGED_FILES:-}"

if [ "$unchecked" -gt 0 ]; then
  echo "$unchecked changed path(s) have a name git prints quoted and could not be checked; rename them or run shellcheck by hand" >&2
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no shell files changed"
  [ "$unchecked" -eq 0 ] || exit 1
  exit 0
fi

echo "shellcheck -x on:"
printf '  %s\n' "${files[@]}"
# `--` so a changed file named -x.sh is a file, not an option.
"$tool" -x -- "${files[@]}"
rc=$?
if [ "$rc" -eq 0 ] && [ "$unchecked" -gt 0 ]; then exit 1; fi
exit "$rc"
