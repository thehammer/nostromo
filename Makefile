.PHONY: build release install test clean daemon install-daemon uninstall-daemon

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

.PHONY: mac mac-run mac-kill mac-icon mac-release mac-install ios-build ios-install ios-install-ipad ios-install-all

# Release build uses an explicit derived-data path so the product location is
# predictable (no DerivedData hash dependency). Ad-hoc signed so the arm64
# binary runs locally without a developer account.
APP_RELEASE = macOS/build/Build/Products/Release/Nostromo.app
INSTALLED   = /Applications/Nostromo.app

## Build the macOS GUI app (uses explicit derivedDataPath so worktree builds
## don't scatter extra .app copies into ~/Library/Developer/Xcode/DerivedData)
mac:
	cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme Nostromo -configuration Debug \
	  -derivedDataPath build build 2>&1 | grep -E "error:|warning:|BUILD"

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

## Build the iOS app for a paired device (release, device code signing).
## Override the target device with: make ios-install IOS_DEVICE_ID=<uuid>
ios-build:
	cd iOS && xcodebuild \
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
