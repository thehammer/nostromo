#!/usr/bin/env bash
# Sign the Nostromo app as the operator app: ad-hoc, hardened runtime, and the
# empty entitlements in macOS/signing/Nostromo.installed.entitlements. Then
# verify the signature and assert the result (scripts/lib/operator-app-checks.sh).
#
#   scripts/sign-operator-app.sh <path/to/Nostromo.app>
#
# `make mac-install` runs this on the Release build product BEFORE copying it to
# /Applications: re-signing in place would rewrite a file that may be running.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/operator-app-checks.sh
. "$here/lib/operator-app-checks.sh"

[ $# -eq 1 ] || { echo "usage: $0 <app>" >&2; exit 2; }
app=$1
entitlements="$here/../macOS/signing/Nostromo.installed.entitlements"

[ -d "$app" ] || operator_app_fail "$app is not an app bundle"
codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
assert_operator_app "$app"
echo "signed $app (ad-hoc, hardened runtime, no entitlements)"
