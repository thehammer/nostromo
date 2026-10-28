#!/usr/bin/env bash
# CI entry point for the Mac app's logic tests (the `NostromoTests` scheme):
# the same suite as `make mac-test`, run in two phases so most of it can use
# XCTest's parallel testing without parallelising the layout golden tests.
#
#   1. build-for-testing  (one build, shared by both phases)
#   2. every class NOT in SERIAL_CLASSES, with parallel testing on
#   3. the classes in SERIAL_CLASSES, one process, in order
#
# The two class selections are exact complements (`-skip-testing` vs
# `-only-testing` over the same list), so every test runs exactly once.
#
# SERIAL_CLASSES stay on one process, on purpose:
#   * the layout goldens: classes that pin rendered heights or layout against
#     goldens recorded on a single process with Fira Code;
#   * real-window layout tests that wait on wall-clock budgets (the Mother
#     detail rig, window overflow, oversized-child splits): measured on the
#     3-core runner, MotherDetailScrollTests failed in 1 of 5 parallel runs
#     (and in a 6-worker run) because a test that pumps a real window for a
#     fixed time slice is a flake under CPU contention, not a verdict;
#   * MotherBrokerClientTests, which failed once in a 4-worker run for the
#     same reason (timer-driven, 15 s budget).
# A class goes on this list when it records goldens or waits on wall-clock
# time against real windows; it comes off only with 5 consecutive green
# parallel runs on the runner.
#
# `make mac-test` is unchanged and stays fully serial: it is what a developer
# runs, and a serial failure is the reference for a CI failure.
#
# Env: WORKERS (parallel worker count, default 3 = the runner's cores).
set -euo pipefail

cd "$(dirname "$0")/.."   # macOS/

WORKERS="${WORKERS:-3}"
SERIAL_CLASSES=(
  ChatTurnViewLayoutTests
  TurnHeightEstimatorTests
  TurnHeightEstimatorFoldTests
  TrackerPaneViewTests
  TrackerRowLayoutTests
  TrackerLargeBoardTests
  TrackerHostileTextTests
  TrackerPaneClockTests
  AppControlTrackerTests
  MarkdownCodeBlockTests
  MotherDetailScrollTests
  MotherDetailVerticalOverflowTests
  MotherOverviewAndCrewOverflowTests
  FocusSplitOversizedChildTests
  WindowContentOverflowTests
  MotherBrokerClientTests
)

BASE=(-project Nostromo.xcodeproj -scheme NostromoTests -destination 'platform=macOS' -derivedDataPath build)
LOG_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
SKIPS=()
ONLYS=()

# A class that was renamed or deleted would make -only-testing select nothing
# and the serial phase pass vacuously: fail loudly instead.
for c in "${SERIAL_CLASSES[@]}"; do
  if ! grep -rqE "^(final )?class ${c}\b" NostromoTests; then
    echo "::error::serial test class ${c} (macOS/scripts/mac-test-ci.sh) no longer exists in NostromoTests"
    exit 1
  fi
  SKIPS+=("-skip-testing:NostromoTests/${c}")
  ONLYS+=("-only-testing:NostromoTests/${c}")
done

# The exit status is the verdict; this is a second, independent reading of the
# same output. (Not `error:`: passing tests print that text.)
assert_no_failures() {
  if grep -qE "^Test case .* failed|\*\* TEST [A-Z ]*FAILED" "$1"; then
    echo "::error::failures reported in $1"
    grep -E "^Test case .* failed|\*\* TEST [A-Z ]*FAILED" "$1" | head -50
    exit 1
  fi
}

echo "== build-for-testing"
xcodebuild "${BASE[@]}" build-for-testing 2>&1 | tee "$LOG_DIR/mac-build.log" | grep -E "error:|\*\* TEST BUILD"

echo "== parallel phase (workers=${WORKERS})"
set +e
xcodebuild "${BASE[@]}" test-without-building \
  -parallel-testing-enabled YES -parallel-testing-worker-count "$WORKERS" \
  "${SKIPS[@]}" > "$LOG_DIR/mac-parallel.log" 2>&1
parallel_status=$?
set -e
grep -E "error:|failed|\*\* TEST" "$LOG_DIR/mac-parallel.log" | head -100 || true
[ "$parallel_status" -eq 0 ] || { echo "::error::parallel phase exited $parallel_status"; exit 1; }
assert_no_failures "$LOG_DIR/mac-parallel.log"

echo "== serial phase (${#SERIAL_CLASSES[@]} classes)"
set +e
xcodebuild "${BASE[@]}" test-without-building \
  -parallel-testing-enabled NO "${ONLYS[@]}" > "$LOG_DIR/mac-serial.log" 2>&1
serial_status=$?
set -e
grep -E "error:|Executed [0-9]+ tests|failed|\*\* TEST" "$LOG_DIR/mac-serial.log" | head -100 || true
[ "$serial_status" -eq 0 ] || { echo "::error::serial phase exited $serial_status"; exit 1; }
assert_no_failures "$LOG_DIR/mac-serial.log"

# Every serial class must really have run (a typo in -only-testing runs nothing).
for c in "${SERIAL_CLASSES[@]}"; do
  if ! grep -qE "^Test Suite '${c}' passed" "$LOG_DIR/mac-serial.log"; then
    echo "::error::serial class ${c} did not run in the serial phase"
    exit 1
  fi
done

echo "Mac tests passed: parallel phase + ${#SERIAL_CLASSES[@]} serial classes"
