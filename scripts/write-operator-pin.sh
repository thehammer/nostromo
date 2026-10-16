#!/usr/bin/env bash
# Pin the installed operator app: write the identifier and one cdhash per
# architecture slice of <app> to <pin-file>, which the daemon reads on every
# connection that claims to be the Mac app (src/ipc/peer_verify.rs). Refuses an
# app that fails the operator-app checks (scripts/lib/operator-app-checks.sh).
#
#   scripts/write-operator-pin.sh <path/to/Nostromo.app> <pin-file>
#
# The pin is written atomically (a temp file in the same directory, mode 0600,
# then renamed), so a failure leaves any previous pin untouched.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/operator-app-checks.sh
. "$here/lib/operator-app-checks.sh"

[ $# -eq 2 ] || { echo "usage: $0 <app> <pin-file>" >&2; exit 2; }
app=$1
pin=$2

assert_operator_app "$app"
id=$(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')

lines=()
for arch in $(operator_app_archs "$app"); do
  cdhash=$(codesign -dvvv --arch "$arch" "$app" 2>&1 | sed -n 's/^CDHash=//p')
  [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || operator_app_fail "$app ($arch): no cdhash in codesign output"
  lines+=("cdhash $cdhash")
done

dir=$(dirname "$pin")
mkdir -p "$dir"
tmp=$(mktemp "$dir/.operator-app.pin.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
{
  echo "# Nostromo operator-app pin. Written by make mac-install. The daemon accepts decision"
  echo "# answers only from a running process whose code matches a cdhash below."
  echo "identifier $id"
  printf '%s\n' "${lines[@]}"
} >"$tmp"
mv -f "$tmp" "$pin"
trap - EXIT
echo "pinned $app ($id, ${#lines[@]} cdhash) → $pin"
