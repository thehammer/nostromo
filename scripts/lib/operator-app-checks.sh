# shellcheck shell=bash
# Checks shared by scripts/sign-operator-app.sh and scripts/write-operator-pin.sh.
# Source it; it defines functions only.
#
# An operator app is the one Nostromo.app the daemon lets answer an agent's
# decision (docs/operator-app-trust.md). It must be signed with the hardened
# runtime, carry none of the entitlements that reopen it to a debugger or to
# library injection, and have the Nostromo identifier.

# Entitlements that must never be on the operator app.
OPERATOR_APP_FORBIDDEN_ENTITLEMENTS=(
  com.apple.security.get-task-allow
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.disable-library-validation
)

operator_app_fail() {
  echo "error: $*" >&2
  exit 1
}

# The executable inside the signed bundle <app>.
operator_app_executable() {
  codesign -dv "$1" 2>&1 | sed -n 's/^Executable=//p'
}

# The architectures of <app>'s executable, space-separated (`lipo -archs`).
operator_app_archs() {
  local exe
  exe=$(operator_app_executable "$1")
  [ -n "$exe" ] || operator_app_fail "$1: cannot find the signed executable"
  lipo -archs "$exe"
}

# Exit non-zero unless <app>'s signature verifies (`codesign --verify --strict`)
# and every architecture slice of it is signed with the
# hardened runtime, carries no forbidden entitlement, and has the identifier
# com.hammer.nostromo or com.hammer.nostromo.qa.
assert_operator_app() {
  local app=$1 info ents id arch archs ent
  [ -d "$app" ] || operator_app_fail "$app is not an app bundle"
  info=$(codesign --verify --strict "$app" 2>&1) || operator_app_fail "$app does not verify: $info"
  info=$(codesign -dv "$app" 2>&1) || operator_app_fail "$app is not signed: $info"
  id=$(sed -n 's/^Identifier=//p' <<<"$info")
  case "$id" in
    com.hammer.nostromo | com.hammer.nostromo.qa) ;;
    *) operator_app_fail "$app has identifier '$id', not com.hammer.nostromo or com.hammer.nostromo.qa" ;;
  esac
  archs=$(operator_app_archs "$app")
  [ -n "$archs" ] || operator_app_fail "$app: lipo reports no architectures"
  for arch in $archs; do
    info=$(codesign -dv --arch "$arch" "$app" 2>&1) || operator_app_fail "$app ($arch) is not signed: $info"
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$info" \
      || operator_app_fail "$app ($arch) is not signed with the hardened runtime: $(grep '^CodeDirectory' <<<"$info")"
    ents=$(codesign -d --entitlements - --xml --arch "$arch" "$app" 2>/dev/null) \
      || operator_app_fail "$app ($arch): cannot read entitlements"
    for ent in "${OPERATOR_APP_FORBIDDEN_ENTITLEMENTS[@]}"; do
      if grep -qF "$ent" <<<"$ents"; then
        operator_app_fail "$app ($arch) carries the entitlement $ent"
      fi
    done
  done
}
