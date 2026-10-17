#!/usr/bin/env bash
# Install a signed operator app at <dest> without ever leaving <dest> half
# written: copy it to a temp directory beside <dest>, check the copy still
# verifies and has the same cdhash(es) as <src>, and only then swap it in by
# renaming. A failed copy or check leaves the old app (if any) in place.
#
# When <dest> exists the swap is ONE atomic `renamex_np(RENAME_SWAP)` (through
# python3's ctypes; the shell has no such tool), so <dest> never stops existing:
# a client connecting mid-install sees the old app or the new one. Without
# python3, or on a filesystem that cannot swap, it falls back to two renames,
# and then there is a gap of a few milliseconds in which <dest> does not exist
# (an operator app that connects then is refused as WrongPath and retries).
#
#   scripts/install-operator-app.sh <signed/Nostromo.app> </Applications/Nostromo.app>
#
# <src> must already be signed (scripts/sign-operator-app.sh) and pass the
# operator-app checks (scripts/lib/operator-app-checks.sh).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/operator-app-checks.sh
. "$here/lib/operator-app-checks.sh"

[ $# -eq 2 ] || { echo "usage: $0 <src-app> <dest-app>" >&2; exit 2; }
src=${1%/}
dest=${2%/}

assert_operator_app "$src"

# One "<arch> <cdhash>" line per architecture slice of <app>.
cdhashes() {
  local app=$1 arch
  for arch in $(operator_app_archs "$app"); do
    echo "$arch $(codesign -dvvv --arch "$arch" "$app" 2>&1 | sed -n 's/^CDHash=//p')"
  done
}

parent=$(dirname "$dest")
tmp=$(mktemp -d "$parent/.$(basename "$dest").install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cp -R "$src" "$tmp/new.app"
xattr -cr "$tmp/new.app" 2>/dev/null || true
assert_operator_app "$tmp/new.app"
want=$(cdhashes "$src")
have=$(cdhashes "$tmp/new.app")
[ -n "$want" ] && [ "$want" = "$have" ] \
  || operator_app_fail "the copy's cdhash differs from the build product's (want: $want; have: $have); $dest left as it was"

# swap_atomically <a> <b>: exchange two existing paths in one step.
swap_atomically() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -I -c '
import ctypes, sys
RENAME_SWAP = 2
libc = ctypes.CDLL(None, use_errno=True)
rc = libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), RENAME_SWAP)
sys.exit(0 if rc == 0 else 1)
' "$1" "$2" 2>/dev/null
}

if [ -e "$dest" ]; then
  # After a swap, $tmp/new.app holds the OLD app; the exit trap removes it with $tmp.
  if ! swap_atomically "$tmp/new.app" "$dest"; then
    mv "$dest" "$tmp/old.app"
    if ! mv "$tmp/new.app" "$dest"; then
      mv "$tmp/old.app" "$dest"
      operator_app_fail "could not move the new app into place; restored the old $dest"
    fi
  fi
else
  mv "$tmp/new.app" "$dest"
fi
echo "installed $src → $dest"
