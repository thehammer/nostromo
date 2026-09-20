.PHONY: build release install test python-test clean daemon install-daemon uninstall-daemon

build:
	cargo build

release:
	cargo build --release

install: release
	cargo install --path .
	@echo "nostromo installed to $$(which nostromo)"
	@# Restart the daemon if it's registered with launchd so the new binary takes effect.
	@launchctl kickstart -k "gui/$$(id -u)/com.hammer.nostromd" 2>/dev/null && echo "nostromd restarted" || echo "nostromd not registered with launchd (skipping restart)"

test:
	cargo test

## Run the Python tooling test suites (load-test report script, doctor, shell
## driver checks, iOS source-scanning policy checks). One command so CI and a
## local run cannot drift apart — these suites otherwise ran nowhere but a
## developer's shell, which for the report-script suite in particular is the
## same defect the suite is about: a check nobody executes is a check that
## always passes.
python-test:
	python3 -m unittest discover -s tests/transcript_load -v
	python3 -m unittest discover -s tests/doctor -v
	python3 -m unittest discover -s tests/ios_policy -v
	python3 -m unittest discover -s tests/launch_smoke -v
	python3 -m unittest discover -s tests/ci_policy -v

clean:
	cargo clean

# ── daemon targets ────────────────────────────────────────────────────────────

## Build the nostromd daemon binary (release).
daemon:
	cargo build --release --bin nostromd

## Install the daemon binary and register the launchd agent.
##
## Installs nostromd to $HOME/.local/bin/nostromd and loads it as a launchd
## user agent so it starts automatically at login.
install-daemon: daemon
	@mkdir -p "$(HOME)/.local/bin"
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@mkdir -p "$(HOME)/.cache/nostromd/log"
	cp target/release/nostromd "$(HOME)/.local/bin/nostromd"
	@echo "Installed nostromd to $(HOME)/.local/bin/nostromd"
	sed \
		-e 's|__PREFIX__|$(HOME)/.local|g' \
		-e 's|__HOME__|$(HOME)|g' \
		dist/launchd/com.hammer.nostromd.plist \
		> "$(HOME)/Library/LaunchAgents/com.hammer.nostromd.plist"
	@echo "Installed plist to $(HOME)/Library/LaunchAgents/com.hammer.nostromd.plist"
	@launchctl bootout "gui/$$(id -u)/com.hammer.nostromd" 2>/dev/null || true
	@# bootout is asynchronous — the service keeps tearing down after the command
	@# returns. Bootstrapping immediately races it and fails with "Input/output
	@# error" (5). Poll until the old instance is fully unloaded (max ~5s) first.
	@for i in $$(seq 1 20); do \
		launchctl print "gui/$$(id -u)/com.hammer.nostromd" >/dev/null 2>&1 || break; \
		sleep 0.25; \
	done
	launchctl bootstrap "gui/$$(id -u)" "$(HOME)/Library/LaunchAgents/com.hammer.nostromd.plist"
	@echo "nostromd loaded — check status with: launchctl print gui/$$(id -u)/com.hammer.nostromd"

## Unload and remove the nostromd launchd agent and binary.
uninstall-daemon:
	launchctl bootout "gui/$$(id -u)/com.hammer.nostromd" 2>/dev/null || true
	rm -f "$(HOME)/Library/LaunchAgents/com.hammer.nostromd.plist"
	rm -f "$(HOME)/.local/bin/nostromd"
	@echo "nostromd uninstalled"

# ── macOS GUI ──────────────────────────────────────────────────────────────────

APP_BUNDLE  = macOS/build/Build/Products/Debug/Nostromo.app

IOS_DEVICE_ID   ?= 195907F5-56CB-5334-B012-6F71CFA5EB21# Hammer's iPhone Pro
IPAD_DEVICE_ID  ?= BA38C738-E848-5694-B1C4-7D5DB4C631EE# Hammer's iPad Pro
IOS_APP_RELEASE  = iOS/build/Build/Products/Release-iphoneos/Nostromo.app

.PHONY: mac mac-test mac-load-test mac-run mac-kill mac-icon mac-release mac-install kit-test ios-build ios-install ios-install-ipad ios-install-all mac-smoke mac-smoke-validate

# Release build uses an explicit derived-data path so the product location is
# predictable (no DerivedData hash dependency). Ad-hoc signed so the arm64
# binary runs locally without a developer account.
APP_RELEASE = macOS/build/Build/Products/Release/Nostromo.app
INSTALLED   = /Applications/Nostromo.app

## Build the macOS GUI app (uses explicit derivedDataPath so worktree builds
## don't scatter extra .app copies into ~/Library/Developer/Xcode/DerivedData)
## `set -o pipefail` is not decoration. Without it the recipe's status is
## grep's, and grep succeeds precisely when the build printed `error:` — so a
## broken build exited 0 and every caller (CI, mother, a human) read it as
## green. NOT `.SHELLFLAGS`: macOS ships GNU Make 3.81 and `.SHELLFLAGS`
## arrived in 3.82, so setting it here is silently ignored. A per-recipe
## prefix works on 3.81, and needs no `SHELL` change — /bin/sh on macOS is
## bash and supports it.
mac:
	set -o pipefail; cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme Nostromo -configuration Debug \
	  -derivedDataPath build build 2>&1 | grep -E "error:|warning:|BUILD"

## Run the macOS logic test suite (standalone bundle, no test host).
## Same pipefail rationale as `mac`: this target reported success on a failing
## suite, which is the worst possible thing for a target whose entire job is to
## tell you whether the suite passed.
mac-test:
	set -o pipefail; cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme NostromoTests \
	  -destination 'platform=macOS' -derivedDataPath build test \
	  2>&1 | grep -E "error:|Executed [0-9]+ tests|failed|\*\* TEST"

## Measure the bounded-transcript acceptance criteria against a Release build.
## Takes several minutes; drives synthetic traffic through the real code path.
##   make mac-load-test                 # 5000 turns, 1 focus
##   make mac-load-test TURNS=40000 FOCUSES=8
TURNS   ?= 5000
FOCUSES ?= 1
mac-load-test:
	macOS/scripts/transcript-load-test.sh $(TURNS) $(FOCUSES)

## Kill any running Nostromo instance (handles debugserver wedge)
mac-kill:
	@pkill -9 -f "debugserver" 2>/dev/null || true
	@pkill -9 -f "Nostromo.app" 2>/dev/null || true
	@sleep 0.5

## Build and launch the macOS GUI app (kills any running instance first)
mac-run: mac mac-kill
	open -n "$(APP_BUNDLE)"
	@echo "Nostromo launched."

## Regenerate the app icon from macOS/icon/nostromo-icon.svg
mac-icon:
	macOS/icon/build-icon.sh
	@if [ -d macOS/Nostromo/Assets.xcassets ]; then \
	  rm -rf macOS/Nostromo/Assets.xcassets/AppIcon.appiconset; \
	  cp -R macOS/icon/AppIcon.appiconset macOS/Nostromo/Assets.xcassets/AppIcon.appiconset; \
	  echo "synced AppIcon.appiconset → Assets.xcassets"; \
	else \
	  echo "NOTE: Assets.xcassets not wired into the project yet — icon built, run again after wiring."; \
	fi

## Release build of the GUI (ad-hoc signed, predictable output path)
mac-release:
	cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme Nostromo \
	  -configuration Release -derivedDataPath build \
	  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build \
	  2>&1 | grep -E "error:|warning:|BUILD" || true
	@test -d "$(APP_RELEASE)" && echo "built → $(APP_RELEASE)" || { echo "release build failed"; exit 1; }

## Run the shared NostromoKit logic test suite (SwiftPM, headless). This is
## the L1 layer of iOS's three-layer verification model
## (docs/ios-verification.md): the suite that runs with no paired iOS device
## and no simulator, because it's a plain `swift test` over pure value types,
## not an app target.
kit-test:
	swift test --package-path Shared/NostromoKit

## Build the iOS app for a paired device (release, device code signing).
## Override the target device with: make ios-install IOS_DEVICE_ID=<uuid>
## `set -o pipefail` — same rationale as `mac`/`mac-test` above: without it
## the recipe's exit status is grep's, so a build that failed for a reason
## grep's pattern doesn't happen to print (or a build that hung and was
## killed) can still exit 0. The `@test -d` product check below catches a
## missing product but not a failed build that left a stale product in
## iOS/build from a previous successful run — pipefail is what makes the
## recipe itself trustworthy rather than relying on that check alone.
ios-build:
	set -o pipefail; cd iOS && xcodebuild \
	  -project Nostromo.xcodeproj \
	  -scheme Nostromo \
	  -configuration Release \
	  -destination "id=$(IOS_DEVICE_ID)" \
	  -derivedDataPath build \
	  build 2>&1 | grep -E "error:|warning:|BUILD|SUCCEEDED|FAILED"
	@test -d "$(IOS_APP_RELEASE)" || { echo "iOS build failed — .app not found"; exit 1; }
	@echo "built → $(IOS_APP_RELEASE)"

## Build and install to the paired iPhone.
ios-install: ios-build
	xcrun devicectl device install app \
	  --device "$(IOS_DEVICE_ID)" \
	  "$(IOS_APP_RELEASE)"
	@echo "installed → iPhone ($(IOS_DEVICE_ID))"

## Install the already-built app to the paired iPad (no rebuild).
ios-install-ipad: ios-build
	xcrun devicectl device install app \
	  --device "$(IPAD_DEVICE_ID)" \
	  "$(IOS_APP_RELEASE)"
	@echo "installed → iPad ($(IPAD_DEVICE_ID))"

## Build once, install to both iPhone and iPad.
ios-install-all: ios-build
	xcrun devicectl device install app \
	  --device "$(IOS_DEVICE_ID)" \
	  "$(IOS_APP_RELEASE)"
	@echo "installed → iPhone ($(IOS_DEVICE_ID))"
	xcrun devicectl device install app \
	  --device "$(IPAD_DEVICE_ID)" \
	  "$(IOS_APP_RELEASE)"
	@echo "installed → iPad ($(IPAD_DEVICE_ID))"

## Install the Release build into /Applications (run at milestones).
mac-install: mac-release
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP_RELEASE)" "$(INSTALLED)"
	@xattr -cr "$(INSTALLED)" 2>/dev/null || true
	@echo "installed → $(INSTALLED)  (launch from Spotlight/Launchpad like any app)"

## Launch smoke test (L4 — docs/ios-verification.md): build the Debug app,
## launch it against a fixture daemon, and assert it reaches a real
## multi-pane AppKit layout. The identical command a developer runs locally
## and (from W2 on) what CI runs — see bin/nostromo-launch-smoke for the
## full design (it does its own build; no `mac`/`mac-release` prerequisite
## here, so `RELEASE=1` doesn't waste time on an unwanted Debug build first).
## Debug is the default: it's what `make mac`/`mac-run` produce and the
## fastest warm loop. `make mac-smoke RELEASE=1` uses the Release bundle.
RELEASE ?=
mac-smoke:
	bin/nostromo-launch-smoke $(if $(RELEASE),--release,)

## Validate the launch smoke check against the bug it exists to catch: the
## 2026-09-03 RatioSplitView.layout() infinite-recursion crash. Builds a
## scratch worktree with the reentrancy guard removed and asserts FAIL, then
## reverts and asserts PASS. Never touches this working tree.
mac-smoke-validate:
	macOS/scripts/launch-smoke-validate.sh
