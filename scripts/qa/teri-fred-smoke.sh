#!/usr/bin/env bash
# QA smoke (READ-ONLY): the Teri and Fred focuses in the real, running app.
#
# Usage: [QA_SCREEN=<display name>] scripts/qa/teri-fred-smoke.sh
#   QA_SCREEN            test the window on the display whose name contains this; default: the
#                        window showing Teri, wherever it is
#   QA_LOADING_TIMEOUT   seconds a tab may stay on "Loading" before it FAILs (default 20)
#   QA_INCLUDE_PICKS=1   also click the Picks tab (first open of the day can start a paid
#                        picks generation, so it is off by default)
#
# Needs the app running with AppControlEnabled (docs/app-control.md); exits 2 with a message if
# the socket is missing and never enables it. UI-only input: it takes keyboard focus briefly
# (activate/restore), so run it when nobody is typing. It never sends to an agent, creates a Mother
# job or focus, or presses Start / Open / Ask Fred / Refresh. Prints PASS/FAIL/WARN/INFO per step
# and exits 1 if any step FAILed (2: app-control unreachable). See scripts/qa/README.md.
set -euo pipefail
# shellcheck source=lib/qa-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/qa-common.sh"
qa_setup
qa_require_socket
# Not exec: the EXIT trap in qa_setup must still remove the scratch directory.
python3 -B -I "$QA_LIB_DIR/smoke.py"
