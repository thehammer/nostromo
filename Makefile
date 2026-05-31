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

APP_DERIVED = $(HOME)/Library/Developer/Xcode/DerivedData/Nostromo-ciqaoqxunjzisvdagpitruomymcr
APP_BUNDLE  = $(APP_DERIVED)/Build/Products/Debug/Nostromo.app

.PHONY: mac mac-run mac-kill

## Build the macOS GUI app
mac:
	cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme Nostromo -configuration Debug build 2>&1 | grep -E "error:|warning:|BUILD"

## Kill any running Nostromo instance (handles debugserver wedge)
mac-kill:
	@pkill -9 -f "debugserver" 2>/dev/null || true
	@pkill -9 -f "Nostromo.app" 2>/dev/null || true
	@sleep 0.5

## Build and launch the macOS GUI app (kills any running instance first)
mac-run: mac mac-kill
	open -n "$(APP_BUNDLE)"
	@echo "Nostromo launched."
