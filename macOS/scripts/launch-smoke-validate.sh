#!/usr/bin/env bash
# Validate bin/nostromo-launch-smoke against the bug it exists to catch.
#
# This is the PRD's load-bearing criterion: the only evidence that
# distinguishes a real gate from a green checkbox. It reproduces the
# 2026-09-03 RatioSplitView.layout() infinite-recursion crash exactly — by
# deleting the `!isApplyingProgrammatically` guard clause from
# macOS/Nostromo/UI/Views/DynamicFocusView.swift — in a scratch git worktree
# (the operator's working tree is never touched), builds it, and asserts the
# check reports FAIL. It then reverts the change, rebuilds, and asserts the
# check reports PASS. Both directions, on demand, by anyone, without
# hand-editing anything.
#
#   macOS/scripts/launch-smoke-validate.sh
#
# Exit 0 iff both directions came out as required (broken -> FAIL,
# fixed -> PASS). Prints both verdict reports and one summary line.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD_FILE="macOS/Nostromo/UI/Views/DynamicFocusView.swift"
GUARD_CLAUSE="!isApplyingProgrammatically,"
WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-launch-smoke-validate.XXXXXX")"

cleanup() {
  cd "$REPO_ROOT" || true
  git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT

echo "==> creating scratch worktree at HEAD: $WORKTREE_DIR"
git -C "$REPO_ROOT" worktree add --detach "$WORKTREE_DIR" HEAD >/dev/null || {
  echo "FAIL: could not create scratch worktree"
  exit 1
}

TARGET="$WORKTREE_DIR/$GUARD_FILE"
if [ ! -f "$TARGET" ]; then
  echo "FAIL: $GUARD_FILE not found in the scratch worktree"
  exit 1
fi

# Exact-count text transform, not a patch file: a patch rots against line
# drift and fails ambiguously; an exact-count check fails loudly and stays
# correct as the file moves.
COUNT=$(grep -c -F "$GUARD_CLAUSE" "$TARGET")
if [ "$COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly one occurrence of '$GUARD_CLAUSE' in $GUARD_FILE, found $COUNT"
  echo "      (the guard has moved or changed shape — update this script's transform)"
  exit 1
fi

echo "==> removing the reentrancy guard clause (reproducing the 2026-09-03 defect)"
# Delete the line containing the clause entirely (it is its own line in the
# `guard` statement — see DynamicFocusView.swift's RatioSplitView.layout()).
grep -v -F "$GUARD_CLAUSE" "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

echo "==> building the known-bad worktree (make mac)"
if ! make -C "$WORKTREE_DIR" mac >/tmp/nostromo-launch-smoke-validate-bad-build.log 2>&1; then
  echo "FAIL: known-bad build failed to compile — see /tmp/nostromo-launch-smoke-validate-bad-build.log"
  exit 1
fi

echo "==> running bin/nostromo-launch-smoke against the known-bad build"
BAD_REPORT="$("$WORKTREE_DIR/bin/nostromo-launch-smoke" --skip-build 2>&1)"
BAD_STATUS=$?
echo "$BAD_REPORT"
echo "known-bad exit code: $BAD_STATUS (expected 1 / FAIL)"

echo
echo "==> reverting the guard clause and rebuilding the known-good worktree"
git -C "$WORKTREE_DIR" checkout -- "$GUARD_FILE"
if ! make -C "$WORKTREE_DIR" mac >/tmp/nostromo-launch-smoke-validate-good-build.log 2>&1; then
  echo "FAIL: known-good (reverted) build failed to compile — see /tmp/nostromo-launch-smoke-validate-good-build.log"
  exit 1
fi

echo "==> running bin/nostromo-launch-smoke against the known-good build"
GOOD_REPORT="$("$WORKTREE_DIR/bin/nostromo-launch-smoke" --skip-build 2>&1)"
GOOD_STATUS=$?
echo "$GOOD_REPORT"
echo "known-good exit code: $GOOD_STATUS (expected 0 / PASS)"

echo
if [ "$BAD_STATUS" -eq 1 ] && [ "$GOOD_STATUS" -eq 0 ]; then
  echo "SUMMARY: PASS — known-bad build reported FAIL, known-good build reported PASS"
  exit 0
fi
echo "SUMMARY: FAIL — expected (bad=1, good=0), got (bad=$BAD_STATUS, good=$GOOD_STATUS)"
exit 1
