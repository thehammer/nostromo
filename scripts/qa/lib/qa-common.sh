# shellcheck shell=bash
# Shared plumbing for the read-only QA scripts. Sourced, not executed.
#
# QA_APP overrides the app-control CLI (the stub tests point it at a fake).

QA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_ROOT="$(cd "$QA_LIB_DIR/../../.." && pwd)"

qa_setup() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
  QA_APP="${QA_APP:-$QA_ROOT/bin/nostromo-app}"
  [ -x "$QA_APP" ] || { echo "app-control CLI not found or not executable: $QA_APP" >&2; exit 2; }
  export QA_APP
  # Scratch space (screenshots may show the user's real data): removed on exit.
  QA_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/nostromo-qa.XXXXXX")"
  export QA_TMPDIR
  trap 'rm -rf "$QA_TMPDIR"' EXIT
}

# The control socket is opt-in and can click anything: detect it missing, say how to enable it, and
# stop. These scripts never enable it themselves.
qa_require_socket() {
  local err
  if ! err="$("$QA_APP" ping 2>&1 >/dev/null)"; then
    {
      echo "app-control is not reachable, so there is nothing to test."
      echo "  ${err%%$'\n'*}"
      echo "The socket is opt-in; this script will not turn it on. To enable it yourself:"
      echo "  defaults write com.hammer.nostromo AppControlEnabled -bool true   # then relaunch Nostromo"
      echo "(see docs/app-control.md)"
    } >&2
    exit 2
  fi
}
