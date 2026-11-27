.PHONY: doctor build release install daemon-restart-guard test fmt-check python-test python-test-fast python-test-slow python-test-fast-par python-test-slow-par python-test-par gates-fast qa-selftest ci-remote clean daemon install-daemon uninstall-daemon install-daemon-linux uninstall-daemon-linux

# Where cargo writes build output. If the dedicated build-scratch volume is mounted
# (/Volumes/Scratch: an APFS volume Time Machine excludes, so its churn never pins
# local snapshots on the system volume) builds go there, one directory per checkout so
# worktrees never share a target directory. Everywhere else (CI, other machines) nothing
# changes: cargo's default `target`. An explicit CARGO_TARGET_DIR always wins.
# Nothing here is read by the daemon: only builds.
ifeq ($(origin CARGO_TARGET_DIR),undefined)
ifneq ($(wildcard /Volumes/Scratch/.),)
export CARGO_TARGET_DIR := /Volumes/Scratch/cargo-target/$(notdir $(CURDIR))
endif
endif
NOSTROMO_TARGET_DIR := $(if $(CARGO_TARGET_DIR),$(CARGO_TARGET_DIR),target)

build:
	cargo build

release:
	cargo build --release

install: release
	@$(RESTART_GUARD)
	cargo install --path .
	@# `nostromo` is the device-management CLI. An old TUI binary of the same name may still sit in
	@# ~/.cargo/bin on this Mac; the install above overwrites it with the CLI.
	@echo "installed nostromd, nostromo (CLI), nostromo-mcp-bridge, nostromo-activity-hook, nostromo-guard, sensitive-text-scan, nostromo-google-auth to ~/.cargo/bin"
	@a=$$(readlink "$(HOME)/.local/bin/nostromo" 2>/dev/null || echo "$(HOME)/.local/bin/nostromo"); b="$(HOME)/.cargo/bin/nostromo"; \
	  if [ -e "$(HOME)/.local/bin/nostromo" ] && [ -e "$$b" ] && ! cmp -s "$$a" "$$b"; then \
	    echo "note: ~/.local/bin/nostromo and ~/.cargo/bin/nostromo differ; PATH resolves $$(command -v nostromo) first"; \
	  fi
	@# Restart the daemon if it's registered with launchd so the new binary takes effect.
	@launchctl kickstart -k "gui/$$(id -u)/com.hammer.nostromd" 2>/dev/null && echo "nostromd restarted" || echo "nostromd not registered with launchd (skipping restart)"

test:
	cargo test

## The formatting gate CI runs (`cargo fmt` fixes it). Run it in the RWX sandbox
## from a worktree that has one: `rwx sandbox exec -- cargo fmt --check`.
fmt-check:
	cargo fmt --check

## Run the Python tooling test suites (load-test report script, doctor, shell
## driver checks, iOS source-scanning policy checks). One command so CI and a
## local run cannot drift apart — these suites otherwise ran nowhere but a
## developer's shell, which for the report-script suite in particular is the
## same defect the suite is about: a check nobody executes is a check that
## always passes.
python-test:
	python3 -m unittest discover -s tests/transcript_load -v
	python3 -m unittest discover -s tests/doctor -v
	python3 -m unittest discover -s tests/doctor_preflight -v
	python3 -m unittest discover -s tests/ios_policy -v
	python3 -m unittest discover -s tests/fake_mother -v
	python3 -m unittest discover -s tests/fake_claude_perm -v
	python3 -m unittest discover -s tests/mother_contract -v
	python3 -m unittest discover -s tests/mother_policy -v
	python3 -m unittest discover -s tests/hit_test_policy -v
	python3 -m unittest discover -s tests/state_path_policy -v
	python3 -m unittest discover -s tests/app_control -v
	python3 -m unittest discover -s tests/qa_instance -v
	python3 -m unittest discover -s tests/launch_smoke -v
	python3 -m unittest discover -s tests/ci_policy -v
	python3 -m unittest discover -s tests/operator_pin -v
	python3 -m unittest discover -s tests/ci_remote -v
	python3 -m unittest discover -s tests/mac_shards -v
	python3 -m unittest discover -s scripts/qa/tests -v
	python3 -m unittest discover -s scripts/tracker/tests -v
	python3 -m unittest discover -s tests/gates -v
	python3 -m unittest discover -s tests/restart_guard -v

## `python-test` is unchanged: every suite, serially, in this order (CI runs it, and
## tests/restart_guard reads this recipe). The lists below split the same suites into fast and
## slow for the extra targets; tests/gates/test_python_test_split.py fails if the recipe and the
## two lists ever disagree, so nothing can drop out. The `-par` targets run a list in parallel
## (scripts/python-test-parallel.sh, PY_JOBS=4 by default); each suite's output is printed whole.
PY_FAST_SUITES := tests/transcript_load tests/doctor tests/doctor_preflight tests/ios_policy tests/hit_test_policy tests/state_path_policy tests/app_control tests/launch_smoke scripts/tracker/tests tests/gates tests/restart_guard
PY_SLOW_SUITES := tests/fake_mother tests/fake_claude_perm tests/mother_contract tests/mother_policy tests/qa_instance tests/ci_policy tests/operator_pin tests/ci_remote tests/mac_shards scripts/qa/tests

python-test-fast:
	set -e; for d in $(PY_FAST_SUITES); do python3 -m unittest discover -s $$d -v; done

python-test-slow:
	set -e; for d in $(PY_SLOW_SUITES); do python3 -m unittest discover -s $$d -v; done

python-test-fast-par:
	scripts/python-test-parallel.sh $(PY_FAST_SUITES)

python-test-slow-par:
	scripts/python-test-parallel.sh $(PY_SLOW_SUITES)

python-test-par:
	scripts/python-test-parallel.sh $(PY_SLOW_SUITES) $(PY_FAST_SUITES)

## A quick local check (about 25-35 s, no Xcode, no cargo): the fast Python suites in parallel,
## shellcheck over the shell files this branch changed, and actionlint (advisory: it has findings on main). The slow suites and the Swift/Rust
## builds stay with `make python-test` and CI.
gates-fast: python-test-fast-par
	MOTHER_GATE_CHANGED_FILES="$$(git diff --name-only origin/main...HEAD; git diff --name-only HEAD)" scripts/gates/shellcheck-changed.sh
	-scripts/gates/actionlint.sh

## Self-test of the read-only QA scripts (scripts/qa) against a fake app-control CLI.
## Hermetic: never touches the running app. Also part of `make python-test` (so CI).
qa-selftest:
	python3 -m unittest discover -s scripts/qa/tests -v

## Run CI (.github/workflows/ci.yml) on a pushed branch and report the failing jobs and
## tests, instead of running xcodebuild locally. Dispatches a `workflow_dispatch` run,
## waits for it, and prints `FAILED <job>: <test>` lines. See docs/ci.md.
##   make ci-remote [BRANCH=<branch, default: current>] [ONLY=all|rust|python|swift|mac|kit|ios]
##   make ci-remote RUN=<run id>   # attach to an existing run (e.g. a PR's CI run); no dispatch
ci-remote:
	python3 scripts/ci_remote.py $(if $(BRANCH),--branch $(BRANCH)) $(if $(ONLY),--only $(ONLY)) $(if $(RUN),--run-id $(RUN))

clean:
	cargo clean

# ── daemon targets ────────────────────────────────────────────────────────────

## Refuse to restart the daemon while remote (ECS) shells are open: a restart ends
## them. `install`, `install-daemon` and `uninstall-daemon` run this first. Override
## with FORCE=1 (or NOSTROMO_FORCE_DAEMON_RESTART=1). Crashes and a raw SIGTERM still
## end shells; this guards only the controlled paths. See docs/terminal.md.
##
## Ordering: the guard is NOT a prerequisite of anything, so build-only targets
## (`make release`, `make daemon`) are never blocked by it, even order-only. The
## install targets run it as the first recipe line, i.e. after their build
## prerequisites finish (also under `make -j`); `uninstall-daemon` builds nothing.
RESTART_GUARD = FORCE="$(FORCE)" bin/nostromo-restart-guard

daemon-restart-guard:
	@$(RESTART_GUARD)

## Build the nostromd daemon binary, its production-shell guard, the MCP bridge and the nostromo CLI (release).
daemon:
	cargo build --release --bin nostromd --bin nostromo-guard --bin nostromo-mcp-bridge --bin nostromo

## Install the daemon binary and register the launchd agent.
##
## Installs nostromd to $HOME/.local/bin/nostromd and loads it as a launchd
## user agent so it starts automatically at login.
ifeq ($(shell uname -s),Linux)
install-daemon: install-daemon-linux
uninstall-daemon: uninstall-daemon-linux
else
install-daemon: daemon
	@$(RESTART_GUARD)
	@mkdir -p "$(HOME)/.local/bin"
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@mkdir -p "$(HOME)/.cache/nostromd/log"
	@# Never overwrite the running binary in place: macOS caches the code signature per
	@# vnode, so an in-place `cp` over a signed binary (and ~/.local/bin/nostromd is often a
	@# symlink to ~/.cargo/bin/nostromd) makes launchd's next spawn die with
	@# OS_REASON_CODESIGNING and crash-loop the daemon. So each binary is copied to a new file
	@# (new inode) and re-signed there, and only then moved over the old one.
	@# nostromd looks for the production-shell guard (the PreToolUse hook every daemon session
	@# runs) beside its own symlink-resolved executable, so it goes next to the real nostromd.
	@# Both are staged and signed BEFORE either is replaced: a failed copy or codesign must not
	@# leave a new nostromd beside a missing or stale guard (missing, every agent tool call is
	@# blocked). The guard is moved into place BEFORE nostromd, so there is never a new daemon
	@# beside a stale guard.
	@# The MCP bridge (what agent sessions spawn to reach the daemon) is installed the same way,
	@# at the path ~/.local/bin/nostromo-mcp-bridge resolves to (a symlink into ~/.cargo/bin);
	@# if that file is missing it goes beside nostromd and the symlink is created.
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  guard="$$(dirname "$$real")/nostromo-guard"; \
	  bdest="$(HOME)/.local/bin/nostromo-mcp-bridge"; bridge=$$(readlink "$$bdest" 2>/dev/null || true); \
	  if [ -z "$$bridge" ]; then if [ -e "$$bdest" ]; then bridge="$$bdest"; else bridge="$$(dirname "$$real")/nostromo-mcp-bridge"; fi; fi; \
	  stage_daemon="$$real.new.$$$$"; stage_guard="$$guard.new.$$$$"; stage_bridge="$$bridge.new.$$$$"; \
	  rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	  if cp "$(NOSTROMO_TARGET_DIR)/release/nostromd" "$$stage_daemon" && codesign --force -s - --identifier nostromd "$$stage_daemon" \
	      && cp "$(NOSTROMO_TARGET_DIR)/release/nostromo-guard" "$$stage_guard" && codesign --force -s - --identifier nostromo-guard "$$stage_guard" \
	      && cp "$(NOSTROMO_TARGET_DIR)/release/nostromo-mcp-bridge" "$$stage_bridge" && codesign --force -s - --identifier nostromo-mcp-bridge "$$stage_bridge"; then :; \
	  else \
	    rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	    echo "install-daemon: could not copy and sign nostromd, nostromo-guard and nostromo-mcp-bridge; nothing was replaced" >&2; exit 1; \
	  fi; \
	  if rm -f "$$bridge" && mv "$$stage_bridge" "$$bridge" && { [ -e "$$bdest" ] || [ -L "$$bdest" ] || ln -s "$$bridge" "$$bdest"; } \
	      && rm -f "$$guard" && mv "$$stage_guard" "$$guard" && rm -f "$$real" && mv "$$stage_daemon" "$$real"; then :; \
	  else \
	    rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	    echo "install-daemon: could not move the new binaries into place; reinstall with make install-daemon" >&2; exit 1; \
	  fi; \
	  echo "Installed nostromd to $$real"; echo "Installed nostromo-guard to $$guard"; \
	  echo "Installed nostromo-mcp-bridge to $$bridge"; \
	  echo "Note: running agent sessions keep their old bridge until restarted; a session whose bridge is the new one reconnects across later daemon restarts."
	@# The `nostromo` CLI (`nostromo device ...`) is a fourth, independent binary: nothing the daemon
	@# runs depends on it, so it is not part of the all-or-nothing swap above. It is installed after
	@# nostromd, beside it, signed the same way; a failed copy only warns and leaves the daemon installed.
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  cli="$$(dirname "$$real")/nostromo"; cdest="$(HOME)/.local/bin/nostromo"; stage_cli="$$cli.new.$$$$"; \
	  rm -f "$$stage_cli"; \
	  if cp "$(NOSTROMO_TARGET_DIR)/release/nostromo" "$$stage_cli" && codesign --force -s - --identifier nostromo "$$stage_cli" \
	      && rm -f "$$cli" && mv "$$stage_cli" "$$cli" && { [ -e "$$cdest" ] || [ -L "$$cdest" ] || ln -s "$$cli" "$$cdest"; }; then \
	    echo "Installed nostromo to $$cli"; \
	  else \
	    rm -f "$$stage_cli"; \
	    echo "install-daemon: warning: could not install the nostromo CLI; the daemon is installed" >&2; \
	  fi
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
	@$(RESTART_GUARD)
	launchctl bootout "gui/$$(id -u)/com.hammer.nostromd" 2>/dev/null || true
	rm -f "$(HOME)/Library/LaunchAgents/com.hammer.nostromd.plist"
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  rm -f "$$(dirname "$$real")/nostromo-guard" "$$(dirname "$$real")/nostromo-mcp-bridge" "$$(dirname "$$real")/nostromo"; \
	  rm -f "$(HOME)/.local/bin/nostromo-mcp-bridge" "$(HOME)/.local/bin/nostromo"
	rm -f "$(HOME)/.local/bin/nostromd"
	@echo "nostromd uninstalled"
endif

## Linux primary: install the daemon binaries and a `systemd --user` unit.
##
## Mirrors the macOS target (same three binaries, same stage-then-rename order:
## bridge, guard, daemon; same restart guard first) minus codesign and launchctl.
## After the first install run `loginctl enable-linger $USER` once so the daemon
## survives logout (the target tells you when that is still needed).
install-daemon-linux: daemon
	@$(RESTART_GUARD)
	@mkdir -p "$(HOME)/.local/bin" "$(HOME)/.config/systemd/user" "$(HOME)/.cache/nostromd/log"
	@# Never overwrite a running binary in place (ETXTBSY): each binary is copied to a new
	@# file and renamed over the old one. All are staged BEFORE any is replaced, and the
	@# guard moves before nostromd, so a new daemon never sits beside a stale guard.
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  guard="$$(dirname "$$real")/nostromo-guard"; \
	  bdest="$(HOME)/.local/bin/nostromo-mcp-bridge"; bridge=$$(readlink "$$bdest" 2>/dev/null || true); \
	  if [ -z "$$bridge" ]; then if [ -e "$$bdest" ]; then bridge="$$bdest"; else bridge="$$(dirname "$$real")/nostromo-mcp-bridge"; fi; fi; \
	  stage_daemon="$$real.new.$$$$"; stage_guard="$$guard.new.$$$$"; stage_bridge="$$bridge.new.$$$$"; \
	  rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	  if cp "$(NOSTROMO_TARGET_DIR)/release/nostromd" "$$stage_daemon" \
	      && cp "$(NOSTROMO_TARGET_DIR)/release/nostromo-guard" "$$stage_guard" \
	      && cp "$(NOSTROMO_TARGET_DIR)/release/nostromo-mcp-bridge" "$$stage_bridge"; then :; \
	  else \
	    rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	    echo "install-daemon-linux: could not copy nostromd, nostromo-guard and nostromo-mcp-bridge; nothing was replaced" >&2; exit 1; \
	  fi; \
	  if rm -f "$$bridge" && mv "$$stage_bridge" "$$bridge" && { [ -e "$$bdest" ] || [ -L "$$bdest" ] || ln -s "$$bridge" "$$bdest"; } \
	      && rm -f "$$guard" && mv "$$stage_guard" "$$guard" && rm -f "$$real" && mv "$$stage_daemon" "$$real"; then :; \
	  else \
	    rm -f "$$stage_daemon" "$$stage_guard" "$$stage_bridge"; \
	    echo "install-daemon-linux: could not move the new binaries into place; reinstall with make install-daemon-linux" >&2; exit 1; \
	  fi; \
	  echo "Installed nostromd to $$real"; echo "Installed nostromo-guard to $$guard"; \
	  echo "Installed nostromo-mcp-bridge to $$bridge"
	@# The `nostromo` CLI (`nostromo device ...`) is independent of the daemon, so it is not part of
	@# the all-or-nothing swap above; a failed copy only warns and leaves the daemon installed.
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  cli="$$(dirname "$$real")/nostromo"; cdest="$(HOME)/.local/bin/nostromo"; stage_cli="$$cli.new.$$$$"; \
	  rm -f "$$stage_cli"; \
	  if cp "$(NOSTROMO_TARGET_DIR)/release/nostromo" "$$stage_cli" \
	      && rm -f "$$cli" && mv "$$stage_cli" "$$cli" && { [ -e "$$cdest" ] || [ -L "$$cdest" ] || ln -s "$$cli" "$$cdest"; }; then \
	    echo "Installed nostromo to $$cli"; \
	  else \
	    rm -f "$$stage_cli"; \
	    echo "install-daemon-linux: warning: could not install the nostromo CLI; the daemon is installed" >&2; \
	  fi
	sed \
		-e 's|__PREFIX__|$(HOME)/.local|g' \
		-e 's|__HOME__|$(HOME)|g' \
		dist/systemd/nostromd.service \
		> "$(HOME)/.config/systemd/user/nostromd.service"
	@echo "Installed unit to $(HOME)/.config/systemd/user/nostromd.service"
	systemctl --user daemon-reload
	systemctl --user enable nostromd
	@# restart, not just --now: installing restarts a daemon that is already running
	systemctl --user restart nostromd
	@echo "nostromd running; check status with: systemctl --user status nostromd"
	@if [ "$$(loginctl show-user "$$USER" -p Linger 2>/dev/null)" != "Linger=yes" ]; then \
	  echo ""; \
	  echo "REQUIRED one-time step: run 'loginctl enable-linger $$USER' so nostromd survives logout."; \
	fi

## Stop and remove the nostromd systemd user unit and binaries.
uninstall-daemon-linux:
	@$(RESTART_GUARD)
	systemctl --user disable --now nostromd 2>/dev/null || true
	rm -f "$(HOME)/.config/systemd/user/nostromd.service"
	systemctl --user daemon-reload 2>/dev/null || true
	@dest="$(HOME)/.local/bin/nostromd"; real=$$(readlink "$$dest" 2>/dev/null || echo "$$dest"); \
	  rm -f "$$(dirname "$$real")/nostromo-guard" "$$(dirname "$$real")/nostromo-mcp-bridge" "$$(dirname "$$real")/nostromo"; \
	  rm -f "$(HOME)/.local/bin/nostromo-mcp-bridge" "$(HOME)/.local/bin/nostromo"
	rm -f "$(HOME)/.local/bin/nostromd"
	@echo "nostromd uninstalled"

# ── macOS GUI ──────────────────────────────────────────────────────────────────

APP_BUNDLE  = macOS/build/Build/Products/Debug/Nostromo.app

IOS_DEVICE_ID   ?= 195907F5-56CB-5334-B012-6F71CFA5EB21# Hammer's iPhone Pro
IPAD_DEVICE_ID  ?= BA38C738-E848-5694-B1C4-7D5DB4C631EE# Hammer's iPad Pro
IOS_APP_RELEASE  = iOS/build/Build/Products/Release-iphoneos/Nostromo.app

# `make ios-test` (L5, docs/ios-verification.md). The simulator is named, not pinned by OS, so it
# follows whichever runtime the selected Xcode ships. `iPhone 17` exists on every iOS runtime of
# the macos-26 runner image (26.2, 26.4, 26.5); on another Mac list yours with
# `xcrun simctl list devices available` and pass IOS_SIM_NAME=<name>. Derived data goes on the
# scratch volume when it is mounted (docs/ci.md, "Local build scratch volume"), one directory per
# checkout, so a simulator build never fills the system volume; everywhere else (CI, other
# machines) it stays under the gitignored iOS/build/.
IOS_SIM_NAME ?= iPhone 17
ifneq ($(wildcard /Volumes/Scratch/.),)
IOS_TEST_DERIVED ?= /Volumes/Scratch/xcode-derived/ios-test/$(notdir $(CURDIR))
else
IOS_TEST_DERIVED ?= iOS/build/ios-test-derived
endif

.PHONY: mac mac-test mac-load-test mac-run mac-kill mac-icon mac-release mac-install mac-pin mac-verify-install kit-test ios-build ios-test ios-install ios-install-ipad ios-install-all mac-smoke mac-smoke-validate

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
## Per-test hang bound: a test that blocks longer than the allowance FAILS (and is
## named in the log) instead of wedging the run until the job timeout. The slowest
## legitimate tests take ~6 s, so 120 s is generous. The old filter's bare `failed`
## matched test NAMES containing "failed" (a_failed_full_screen_entry...), which made
## two innocent placement tests look like the hang site. The full log is kept in
## macOS/build/mac-test-full.log so the last started test can always be named.
MAC_TEST_ALLOWANCE     ?= 120
MAC_TEST_MAX_ALLOWANCE ?= 300
## SHARD=1|2|3 runs one third of the classes (CI runs the three in parallel jobs; the
## assignment is macOS/ci/mac-shards.json, see docs/ci.md). Without SHARD it runs everything.
## The selection args are computed first so a bad config fails the target.
mac-test:
	set -o pipefail; mkdir -p macOS/build; \
	shard_args=""; \
	if [ -n "$(SHARD)" ]; then shard_args=$$(python3 scripts/mac_shards.py args --shard "$(SHARD)") || exit 1; fi; \
	cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme NostromoTests \
	  -destination 'platform=macOS' -derivedDataPath build $$shard_args \
	  -test-timeouts-enabled YES -default-test-execution-time-allowance $(MAC_TEST_ALLOWANCE) \
	  -maximum-test-execution-time-allowance $(MAC_TEST_MAX_ALLOWANCE) test \
	  2>&1 | tee build/mac-test-full.log \
	  | grep --line-buffered -E "error:|Executed [0-9]+ tests|Test Case .* failed|\*\* TEST|MEMORY-CAPTURE-COST|exceeded its execution time"

## Measure the bounded-transcript acceptance criteria against a Release build.
## Takes several minutes; drives synthetic traffic through the real code path.
##   make mac-load-test                 # 5000 turns, 1 focus
##   make mac-load-test TURNS=40000 FOCUSES=8
##   make mac-load-test FIXTURE=benchmark   # open the benchmark transcript, print fixture-open ms
##   make mac-load-test FIXTURE=benchmark-focus   # the Focus view scenario turns, same report
TURNS   ?= 5000
FOCUSES ?= 1
FIXTURE ?=
mac-load-test:
	macOS/scripts/transcript-load-test.sh $(TURNS) $(FOCUSES) $(FIXTURE)

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

## Release build of the GUI (ad-hoc signed, predictable output path).
## The previous product is removed first and the build's own status decides
## (`pipefail`), so a failed build can never be signed, pinned and installed
## from a STALE product left by an earlier run.
## Xcode/build-environment preflight (read-only; prints fixes, never runs them).
## `SKIP_DOCTOR=1 make mac-install` bypasses it.
doctor:
	@scripts/doctor-preflight.sh

mac-release: $(if $(SKIP_DOCTOR),,doctor)
	@rm -rf "$(APP_RELEASE)"
	set -o pipefail; cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme Nostromo \
	  -configuration Release -derivedDataPath build \
	  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build \
	  2>&1 | grep -E "error:|warning:|BUILD"
	@test -d "$(APP_RELEASE)" && echo "built → $(APP_RELEASE)" || { echo "release build failed"; exit 1; }

## Run the shared NostromoKit logic test suite (SwiftPM, headless). This is
## the L1 layer of iOS's verification model (docs/ios-verification.md): the
## suite that runs with no paired iOS device and no simulator, because it's a
## plain `swift test` over pure value types, not an app target.
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

## L5 (docs/ios-verification.md): the hosted NostromoTests bundle, run inside the Nostromo app on
## an iOS Simulator. Only for what needs an iOS process; everything else is L1 (`make kit-test`)
## or L2 (`make python-test`). Needs an installed iOS Simulator runtime (Xcode > Settings >
## Components); the macos-26 CI image has them. `set -o pipefail` for the same reason as
## `ios-build`. The full log is kept in iOS/build/ios-test-full.log. The final check fails the
## target when no test executed: a hosted run whose bundle silently lost its tests prints
## `Executed 0 tests` and `** TEST SUCCEEDED **`, which the grep filter alone would pass.
## Signing is ad hoc (`CODE_SIGN_IDENTITY=-`, no team, no profile), not off: an unsigned host has no
## entitlements, so every Keychain call fails with errSecMissingEntitlement (-34018) and the
## Keychain L5 tests could not run.
ios-test:
	set -o pipefail; mkdir -p iOS/build; \
	xcodebuild test -project iOS/Nostromo.xcodeproj -scheme Nostromo \
	  -destination 'platform=iOS Simulator,name=$(IOS_SIM_NAME)' \
	  -derivedDataPath "$(IOS_TEST_DERIVED)" \
	  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
	  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES 2>&1 | tee iOS/build/ios-test-full.log \
	  | grep --line-buffered -E "error:|Executed [0-9]+ tests|Test Case .* failed|\*\* TEST|exceeded its execution time"
	@grep -Eq "Executed [1-9][0-9]* tests?" iOS/build/ios-test-full.log || { echo "ios-test: no tests executed (see iOS/build/ios-test-full.log)"; exit 1; }

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

## Install the Release build into /Applications (run at milestones), as the
## operator app: the only app the daemon lets answer an agent's decision
## (docs/operator-app-trust.md).
##
## 1. Sign the build product (ad-hoc, hardened runtime, no entitlements) BEFORE
##    copying it: re-signing in /Applications would rewrite a file that may be
##    running (the same vnode concern as `install-daemon`).
## 2. Copy it into /Applications: to a temp dir beside it, verify the copy,
##    then swap by rename (scripts/install-operator-app.sh), so a failed copy
##    leaves the old app in place.
## 3. Pin it: write its identifier and cdhashes to $(OPERATOR_PIN). The daemon
##    reads the pin on every connection, so it needs no restart.
##
## Deploy app and daemon together: `make mac-install`, `make install-daemon`,
## then relaunch the app.
OPERATOR_PIN = $(HOME)/.nostromo/operator-app.pin
mac-install: $(if $(SKIP_DOCTOR),,doctor) mac-release
	scripts/sign-operator-app.sh "$(APP_RELEASE)"
	scripts/install-operator-app.sh "$(APP_RELEASE)" "$(INSTALLED)"
	scripts/write-operator-pin.sh "$(INSTALLED)" "$(OPERATOR_PIN)"
	@echo "installed → $(INSTALLED)  (launch from Spotlight/Launchpad like any app)"
	@echo "relaunch Nostromo; restart is not needed for the daemon (it reads the pin per connection)"

## Re-pin the installed app only (no build, no copy).
mac-pin:
	scripts/write-operator-pin.sh "$(INSTALLED)" "$(OPERATOR_PIN)"

## Show how the installed app is signed and pinned, and fail unless the pin
## matches it.
mac-verify-install:
	@codesign -dv "$(INSTALLED)" 2>&1 | grep -E '^(Identifier|CodeDirectory|Signature)'
	@echo "entitlements:"; codesign -d --entitlements - --xml "$(INSTALLED)" 2>/dev/null; echo
	@echo "pin ($(OPERATOR_PIN)):"; cat "$(OPERATOR_PIN)"
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	  scripts/write-operator-pin.sh "$(INSTALLED)" "$$tmp/expected.pin" >/dev/null && \
	  grep -v '^#' "$$tmp/expected.pin" | sort > "$$tmp/want" && \
	  grep -v '^#' "$(OPERATOR_PIN)" | sort > "$$tmp/have" && \
	  if cmp -s "$$tmp/want" "$$tmp/have"; then echo "OK: the pin matches $(INSTALLED)"; \
	  else echo "MISMATCH: the pin does not match $(INSTALLED); run make mac-pin"; exit 1; fi

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
