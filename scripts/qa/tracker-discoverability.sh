#!/usr/bin/env bash
# Live discoverability eval for the agent tracker (PRD criteria 26 and 28). USER-RUN ONLY: never by CI or a job.
#
#   scripts/qa/tracker-discoverability.sh [--dry-run] [--runs N] [--model M] [--agents cody,claudia]
#
# Needs the isolated QA instance (`scripts/qa/qa-instance.sh start`, started with NOSTROMO_QA_CLAUDE_BIN=<real claude>
# and ANTHROPIC_MODEL=<cheap model> so the sessions are real). --dry-run prints the plan and starts nothing.
# See docs/mcp/tracker.md ("Discoverability").
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B -I "$here/lib/tracker_discoverability.py" "$@"
