.DEFAULT_GOAL := help

SOCKET ?= /var/run/kompletekontrol-libusb.sock
DAEMON := .build/debug/ccd
DAEMON_RELEASE := .build/release/ccd
PROBE := .build/debug/KontrolProbe
PROBE_RELEASE := .build/release/KontrolProbe
SURFACE_DEMO := .build/debug/SurfaceDemo
SURFACE_DEMO_RELEASE := .build/release/SurfaceDemo
MK2_SURFACE_DEMO := .build/debug/MK2SurfaceDemo
MK2_SURFACE_DEMO_RELEASE := .build/release/MK2SurfaceDemo
MK2_WIDGET_LAB_DEMO := .build/debug/MK2WidgetLabDemo
MK2_WIDGET_LAB_DEMO_RELEASE := .build/release/MK2WidgetLabDemo
MK2_USB_SPY := .build/debug/MK2USBSpy
MK2_USB_SPY_SECONDS ?= 0
MK2_USB_SPY_PID ?=
MK2_USB_SPY_ARGS := $(if $(MK2_USB_SPY_PID),--pid $(MK2_USB_SPY_PID),) $(if $(filter-out 0,$(MK2_USB_SPY_SECONDS)),--seconds $(MK2_USB_SPY_SECONDS),)

.PHONY: help vendor-init build build-release surface surface-release SurfaceDemo mk2-surface-demo-build mk2-surface-demo-build-release mk2-surface-demo mk2-surface-demo-release mk2-widget-lab-demo-build mk2-widget-lab-demo-build-release mk2-widget-lab-demo mk2-widget-lab-demo-sim mk2-widget-lab-demo-release daemon-build daemon-build-release probe-build probe-build-release mk2-usb-spy-build mk2-usb-spy daemon-preflight daemon daemon-debug daemon-release run-simulator daemon-simulate install-daemon install-debug-daemon uninstall-daemon daemon-status daemon-start daemon-stop daemon-restart run run-release probe-run probe-run-release probe-ui kk-reset kk-stop kk-clean-socket kk-status

help: ## Show this help.
	@awk 'BEGIN { printf "KompleteKontrol-Swift developer targets\n\nUsage:\n  make <target>\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { split($$0, a, ":.*## "); printf "  %-24s %s\n", a[1], a[2] }' $(MAKEFILE_LIST)

vendor-init: ## Initialize pinned vendored dependencies.
	git submodule update --init --recursive Vendor/libusb

build: vendor-init ## Build the middleware SurfaceDemo.
	swift build --product SurfaceDemo

build-release: vendor-init ## Build optimized middleware SurfaceDemo.
	swift build -c release --product SurfaceDemo

SurfaceDemo: build ## Build the middleware SurfaceDemo product.

surface: run ## Run the middleware SurfaceDemo.

surface-release: run-release ## Run optimized middleware SurfaceDemo.

mk2-surface-demo-build: vendor-init ## Build the MK2 hardware-only SurfaceKit2 feature demo.
	swift build --product MK2SurfaceDemo

mk2-surface-demo-build-release: vendor-init ## Build optimized MK2 hardware-only SurfaceKit2 feature demo.
	swift build -c release --product MK2SurfaceDemo

mk2-widget-lab-demo-build: vendor-init ## Build the MK2 Widget Lab demo.
	swift build --product MK2WidgetLabDemo

mk2-widget-lab-demo-build-release: vendor-init ## Build optimized MK2 Widget Lab demo.
	swift build -c release --product MK2WidgetLabDemo

daemon-build: vendor-init ## Build the CompleteControl daemon.
	swift build -c debug --product ccd

daemon-build-release: vendor-init ## Build optimized CompleteControl daemon.
	swift build -c release --product ccd

probe-build: vendor-init ## Build the old KontrolProbe baseline.
	swift build --product KontrolProbe

probe-build-release: vendor-init ## Build optimized old KontrolProbe baseline.
	swift build -c release --product KontrolProbe

mk2-usb-spy-build: vendor-init ## Build the MK2 low-level USB descriptor/input spy.
	swift build --product MK2USBSpy

mk2-usb-spy: mk2-usb-spy-build ## Stop daemon and run MK2 USB descriptor/input spy (requires sudo).
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting MK2 USB spy. Press Ctrl-C to stop."
	sudo "$$(pwd)/$(MK2_USB_SPY)" $(MK2_USB_SPY_ARGS)

daemon-preflight: ## Refuse stale or duplicate daemon state (queries the installed daemon's embedded revision; no local build needed). Caveat: two dirty builds of the same commit compare equal.
	@pids="$$(ps -axo pid=,command= | awk '/--kk-libusb-daemon|--libusb-daemon/ { if (index($$0, "kontrol-simulator-daemon.sock") > 0) next; command = $$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); split(command, argv, /[[:space:]]+/); n = split(argv[1], path, "/"); executable = path[n]; if (executable != "sudo" && executable != "sh" && executable != "zsh" && executable != "bash" && executable != "make" && executable != "awk" && executable != "env") print $$1 }')"; \
	count="$$(printf '%s\n' "$$pids" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	if [ "$$count" -gt 1 ]; then \
		echo "Refusing to run: multiple KompleteKontrol daemons are active:" >&2; \
		for pid in $$pids; do ps -o pid,user,command -p "$$pid" >&2; done; \
		echo "Run: make install-daemon" >&2; \
		exit 1; \
	fi; \
	foreground_daemon=0; \
	for pid in $$pids; do \
		command="$$(ps -o command= -p "$$pid")"; \
		case "$$command" in \
			/usr/local/bin/ccd" "--kk-libusb-daemon*|/usr/local/bin/ccd" "--libusb-daemon*) ;; \
			/usr/local/bin/KontrolProbe" "--kk-libusb-daemon*|/usr/local/bin/KontrolProbe" "--libusb-daemon*) ;; \
			*"/.build/debug/ccd "--kk-libusb-daemon*|*"/.build/debug/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/release/ccd "--kk-libusb-daemon*|*"/.build/release/ccd "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/debug/KontrolProbe "--kk-libusb-daemon*|*"/.build/debug/KontrolProbe "--libusb-daemon*) foreground_daemon=1 ;; \
			*"/.build/release/KontrolProbe "--kk-libusb-daemon*|*"/.build/release/KontrolProbe "--libusb-daemon*) foreground_daemon=1 ;; \
			*) \
				echo "Refusing to run: unexpected KompleteKontrol daemon is active:" >&2; \
				ps -o pid,user,command -p "$$pid" >&2; \
				echo "Run: make install-daemon" >&2; \
				exit 1; \
				;; \
		esac; \
	done; \
	if [ "$${CHECK_DAEMON_BINARY:-1}" != 0 ] && [ "$$foreground_daemon" -ne 1 ] && [ -x /usr/local/bin/ccd ]; then \
		installed_rev="$$(/usr/local/bin/ccd --revision 2>/dev/null || true)"; \
		workspace_count="$$(git rev-list --count HEAD 2>/dev/null || printf 'REV ?')"; \
		if ! git diff --quiet HEAD -- 2>/dev/null; then workspace_count="$$workspace_count+"; fi; \
		workspace_rev="$$workspace_count $$(git rev-parse --short HEAD 2>/dev/null || printf 'NO GIT')"; \
		if [ -z "$$installed_rev" ]; then \
			echo "Refusing to run: /usr/local/bin/ccd predates the --revision flag." >&2; \
			echo "Run: make install-daemon" >&2; \
			exit 1; \
		fi; \
		if [ "$$installed_rev" != "$$workspace_rev" ]; then \
			echo "Refusing to run: /usr/local/bin/ccd is stale (installed $$installed_rev, workspace $$workspace_rev)." >&2; \
			echo "Run: make install-daemon" >&2; \
			exit 1; \
		fi; \
	fi

daemon-debug: daemon-build ## Stop launchd daemon and run foreground daemon with structured stderr tracing.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon with structured stderr tracing. Press Ctrl-C to stop."
	sudo env KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon: daemon-build-release ## Stop launchd daemon and run quiet optimized foreground daemon.
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting quiet optimized foreground daemon. Press Ctrl-C to stop."
	@sudo "$$(pwd)/$(DAEMON_RELEASE)" --kk-libusb-daemon "$(SOCKET)"

SIM_SOCKET := /tmp/kontrol-simulator.sock

run-simulator: ## Build and run the KontrolSimulator panel app (virtual MK2 for hardware-free testing).
	swift build --product KontrolSimulator
	@echo "Launching the simulator window. Start 'make daemon-simulate' in another shell, then a client."
	.build/debug/KontrolSimulator

daemon-simulate: daemon-build ## Stop launchd daemon and run the foreground daemon in simulation mode (needs run-simulator).
	@echo "Stopping installed/foreground daemons..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	@echo "Starting foreground daemon in SIMULATION mode (device = $(SIM_SOCKET)). Launch 'make run-simulator' first. Ctrl-C to stop."
	sudo env CCD_SIMULATE=$(SIM_SOCKET) KK_DAEMON_DEBUG=1 LOGLEVEL=INFO "$$(pwd)/$(DAEMON)" --kk-libusb-daemon "$(SOCKET)"

daemon-release: daemon ## Alias for daemon.

install-daemon: daemon-build-release ## Install optimized daemon as launchd service (requires sudo).
	sudo env KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON_RELEASE)" KK_INSTALL_DAEMON_CONFIGURATION=release ./install-daemon.sh

install-debug-daemon: daemon-build ## Install daemon as launchd service with trace logging enabled.
	sudo env KK_INSTALL_DEBUG_DAEMON=1 KK_INSTALL_DAEMON_EXECUTABLE="$$(pwd)/$(DAEMON)" KK_INSTALL_DAEMON_CONFIGURATION=debug ./install-daemon.sh

uninstall-daemon: ## Uninstall daemon launchd service (requires sudo).
	@echo "Stopping and removing daemon service..."
	-sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist 2>/dev/null || true
	-sudo rm -f /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist
	-sudo rm -f /usr/local/bin/ccd
	-sudo rm -f /usr/local/bin/KontrolProbe
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock
	-sudo rm -f /tmp/media.vanille.kompletekontrol-libusb.stdout.log /tmp/media.vanille.kompletekontrol-libusb.stderr.log
	@echo "Daemon service uninstalled."

daemon-status: ## Show daemon status.
	@sudo launchctl list | grep kompletekontrol || echo "Daemon not running or not installed."

daemon-start: ## Start daemon via launchctl.
	@sudo launchctl bootstrap system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-stop: ## Stop daemon via launchctl.
	@sudo launchctl bootout system /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

daemon-restart: ## Restart daemon via launchctl.
	@sudo launchctl kickstart -k system/media.vanille.kompletekontrol-libusb

run: build probe-build ## Run the middleware SurfaceDemo.
	@$(MAKE) daemon-preflight
	$(SURFACE_DEMO)

run-release: build-release probe-build-release ## Run optimized middleware SurfaceDemo.
	@$(MAKE) daemon-preflight
	$(SURFACE_DEMO_RELEASE)

mk2-surface-demo: mk2-surface-demo-build ## Run the MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO)

mk2-surface-demo-release: mk2-surface-demo-build-release ## Run optimized MK2 hardware-only SurfaceKit2 feature demo.
	@$(MAKE) daemon-preflight
	$(MK2_SURFACE_DEMO_RELEASE)

mk2-widget-lab-demo: mk2-widget-lab-demo-build ## Run the MK2 Widget Lab demo.
	@$(MAKE) daemon-preflight
	$(MK2_WIDGET_LAB_DEMO)

mk2-widget-lab-demo-sim: mk2-widget-lab-demo-build ## Run the MK2 Widget Lab demo against the simulator daemon (start it from the KontrolSimulator Daemon menu; no sudo).
	KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock $(MK2_WIDGET_LAB_DEMO)

mk2-widget-lab-demo-release: mk2-widget-lab-demo-build-release ## Run optimized MK2 Widget Lab demo.
	@$(MAKE) daemon-preflight
	$(MK2_WIDGET_LAB_DEMO_RELEASE)

probe-run: probe-build daemon-preflight ## Run the old KontrolProbe REPL baseline.
	$(PROBE)

probe-run-release: probe-build-release ## Run optimized old KontrolProbe for benchmarks.
	@$(MAKE) daemon-preflight
	$(PROBE_RELEASE)

probe-ui: probe-build ## Run the old KontrolProbe S25 photo-overlay test UI.
	$(PROBE) --test-ui

kk-reset: kk-stop kk-clean-socket ## Stop foreground daemon leftovers and remove stale socket.

kk-stop: ## Stop any foreground KK libusb daemon process.
	-sudo pkill -f 'kk-libusb-daemon' 2>/dev/null || true

kk-clean-socket: ## Remove the daemon socket.
	-sudo rm -f $(SOCKET) /var/run/kompletekontrol-libusb.lock

kk-status: ## Show running SidStudio/KontrolProbe KK processes.
	@pgrep -fl 'SidStudio|KontrolProbe|ccd|--kk-libusb-daemon' || true
