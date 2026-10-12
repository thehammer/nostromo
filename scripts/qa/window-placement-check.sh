#!/usr/bin/env bash
# QA check (READ-ONLY): one fullscreen window per attached display, no two on the same display.
#
# Usage: scripts/qa/window-placement-check.sh
#   QA_PLACEMENT_LOG   window-placement log to read (default ~/.nostromo/logs/window-placement.log)
#
# Asks the running app for its windows (app-control `windows`: no focus change, no clicks) and, if
# the placement log exists, summarises the last launch's final window.screen per window and flags
# "gave up" / "retry exhausted" lines. Never writes the log. Exits 1 on a mismatch, 2 when the
# app-control socket is unreachable (it never enables it). See scripts/qa/README.md.
set -euo pipefail
# shellcheck source=lib/qa-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/qa-common.sh"
qa_setup
qa_require_socket
python3 -B -I "$QA_LIB_DIR/placement.py"
