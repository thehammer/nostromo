#!/usr/bin/env bash
# Isolated QA instance: a worktree nostromd plus a cloned com.hammer.nostromo.qa app, with a temp
# HOME, its own sockets and the fake CLI. Never touches the user's app, daemon or ~/.nostromo.
#
#   scripts/qa/qa-instance.sh start [--no-synthetic]   build, launch, print QA_ROOT and the socket export
#   scripts/qa/qa-instance.sh env [ROOT]               print only the NOSTROMO_APP_CONTROL_SOCKET export
#   scripts/qa/qa-instance.sh status [ROOT]
#   scripts/qa/qa-instance.sh stop [ROOT]              kill only our pids, run the isolation guard, rm ROOT (KEEP=1 keeps it)
#
# ROOT defaults to $NOSTROMO_QA_ROOT. Needs a logged-in, awake display (not headless, not CI).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B -I "$here/lib/qa_instance.py" "$@"
