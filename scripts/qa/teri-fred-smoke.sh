#!/usr/bin/env bash
# QA smoke (READ-ONLY): the Teri and Fred focuses in the real, running app.
#
# Usage: [QA_SCREEN=<display name>] scripts/qa/teri-fred-smoke.sh
#   QA_SCREEN            test the window on the display whose name contains this; default: the
#                        window showing Teri, wherever it is
#   QA_LOADING_TIMEOUT   seconds a tab may stay on "Loading" before it FAILs (default 20)
#   QA_ALLOW_TERI_SWITCH=1  switch to Teri when it is not the active focus. Off by default: Teri
#                        opens on the tab it was last left on, and if that is Picks the app may start
#                        a paid generation. Without it the Teri steps are skipped (Fred still runs).
#   QA_INCLUDE_SENTRY=1  also click the Sentry tab. Off by default: leaving it resets the
#                        "new since last viewed" markers, which cannot be put back.
#   The Picks tab is never clicked and no Picks row is ever selected.
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
# exec: a signal sent to this script (kill, Ctrl-C, hangup) lands on python, whose `finally` puts the focus,
# the tab and the keyboard back. exec drops the EXIT trap from qa_setup, so python removes the scratch
# directory itself (smoke.py remove_scratch).
exec python3 -B -I "$QA_LIB_DIR/smoke.py"
