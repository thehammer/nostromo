#!/usr/bin/env bash
# Install a signed operator app at <dest> without ever leaving <dest> half
# written: copy it to a temp directory beside <dest>, check the copy still
# verifies and has the same cdhash(es) as <src>, and only then swap it in by
# renaming. A failed copy or check leaves the old app (if any) in place.
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

if [ -e "$dest" ]; then
  mv "$dest" "$tmp/old.app"
  if ! mv "$tmp/new.app" "$dest"; then
    mv "$tmp/old.app" "$dest"
    operator_app_fail "could not move the new app into place; restored the old $dest"
  fi
else
  mv "$tmp/new.app" "$dest"
fi
echo "installed $src → $dest"
