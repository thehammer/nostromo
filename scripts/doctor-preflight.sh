#!/bin/bash
# Xcode/build-environment preflight for `make mac-install` / `make mac-release`.
# Read-only: prints one OK/FAIL line per check, plus the command the human should
# run for each FAIL. Never runs sudo and never downloads anything.
# Exit 0 if every check passes, 1 if any fails.

failed=0

check() {
  local name="$1" next_step="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name"
    echo "     next step: $next_step"
    failed=1
  fi
}

check "Xcode license accepted" "sudo xcodebuild -license accept" \
  xcodebuild -license check
check "Xcode first-launch tasks done" "sudo xcodebuild -runFirstLaunch" \
  xcodebuild -checkFirstLaunchStatus
check "Metal toolchain present" "xcodebuild -downloadComponent MetalToolchain" \
  xcrun -f metal

exit "$failed"
